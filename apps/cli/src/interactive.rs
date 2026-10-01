use crate::{
    contract::{Account, Freshness, Metric, Snapshot, Usage},
    domain::Quota,
    usage,
};
use std::{
    fmt::Write as _,
    io::{self, IsTerminal, Write},
};
use time::OffsetDateTime;

pub async fn run() -> Result<u8, (String, u8)> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(("Interactive mode requires a terminal.".into(), 3));
    }
    #[cfg(target_os = "macos")]
    let vault = crate::accounts::vault::Vault::system().map_err(|error| (error.to_string(), 2))?;
    #[cfg(target_os = "macos")]
    vault
        .authorize_interactively()
        .await
        .map_err(|error| (error.to_string(), 2))?;
    #[cfg(target_os = "linux")]
    let no_saved_accounts = std::env::var_os("QUOTIO_VAULT_KEY_FILE").is_none()
        && std::env::var_os("QUOTIO_VAULT_KEY_FD").is_none();
    #[cfg(not(target_os = "linux"))]
    let no_saved_accounts = false;
    let request = usage::Request {
        force: false,
        providers: Vec::new(),
        timeout: 10,
        config: None,
        no_saved_accounts,
        account: None,
    };
    let mut force = false;
    let mut selected_id = None;
    println!("Quotio\n");
    loop {
        println!(
            "{}",
            if force {
                "Refreshing usage…"
            } else {
                "Checking providers…"
            }
        );
        let mut current = request.clone();
        current.force = force;
        let collected = usage::collect(current)
            .await
            .map_err(|error| (error.message, error.exit_code))?;
        if !collected.diagnostics.is_empty() {
            println!("{}", collected.diagnostics.trim_end());
        }
        if collected.snapshot.accounts.is_empty() {
            return Ok(collected.exit_code);
        }
        let mut selected = selected_id
            .as_deref()
            .and_then(|id| {
                collected
                    .snapshot
                    .accounts
                    .iter()
                    .position(|account| account.id == id)
            })
            .unwrap_or(0);
        if collected.snapshot.accounts.len() > 1 {
            let Some(choice) = choose_account(&collected.snapshot, selected)? else {
                return Ok(collected.exit_code);
            };
            selected = choice;
        }
        loop {
            selected_id = Some(collected.snapshot.accounts[selected].id.clone());
            println!("\n{}", render_account(&collected.snapshot, selected));
            match prompt("Action  [r] refresh  [a] accounts  [q] quit\n> ")?
                .to_ascii_lowercase()
                .as_str()
            {
                "q" => return Ok(collected.exit_code),
                "r" => {
                    force = true;
                    break;
                }
                "a" if collected.snapshot.accounts.len() > 1 => {
                    let Some(choice) = choose_account(&collected.snapshot, selected)? else {
                        return Ok(collected.exit_code);
                    };
                    selected = choice;
                }
                "a" => println!("Only one account is available."),
                _ => println!("Choose r, a, or q."),
            }
        }
    }
}

fn choose_account(snapshot: &Snapshot, current: usize) -> Result<Option<usize>, (String, u8)> {
    println!("\nAccounts");
    for (index, account) in snapshot.accounts.iter().enumerate() {
        println!(
            "  {}. {} · {} · {}",
            index + 1,
            safe(&account.display_name),
            safe(&account.provider_id),
            account_summary(usage_for(snapshot, account))
        );
    }
    loop {
        let answer = prompt(&format!(
            "Select 1–{} [default {}, q to quit]\n> ",
            snapshot.accounts.len(),
            current + 1
        ))?;
        if answer.is_empty() {
            return Ok(Some(current));
        }
        if answer.eq_ignore_ascii_case("q") {
            return Ok(None);
        }
        if let Ok(value) = answer.parse::<usize>()
            && (1..=snapshot.accounts.len()).contains(&value)
        {
            return Ok(Some(value - 1));
        }
        println!("Enter an account number or q.");
    }
}

fn prompt(message: &str) -> Result<String, (String, u8)> {
    print!("{message}");
    io::stdout()
        .flush()
        .map_err(|_| ("Could not write prompt.".to_string(), 3))?;
    let mut input = String::new();
    if io::stdin()
        .read_line(&mut input)
        .map_err(|_| ("Could not read input.".to_string(), 3))?
        == 0
    {
        return Err(("Input closed.".into(), 3));
    }
    Ok(input.trim().to_string())
}

fn render_account(snapshot: &Snapshot, selected: usize) -> String {
    let account = &snapshot.accounts[selected];
    let usage = usage_for(snapshot, account);
    let mut text = format!(
        "{} · {}\n{}",
        safe(&account.display_name),
        safe(&account.provider_id),
        account_summary(usage)
    );
    if let Some(plan) = usage.and_then(|value| value.plan.as_deref()) {
        let _ = write!(text, " · {}", safe(plan));
    }
    text.push('\n');
    for source in &account.sources {
        if let Some(issue) = &source.issue {
            let _ = writeln!(text, "! {}", safe(&issue.code));
        }
    }
    let Some(usage) = usage else {
        text.push_str("\nUsage has not been loaded.\n");
        return text;
    };
    if let Some(issue) = &usage.issue {
        let _ = writeln!(text, "! {}", safe(&issue.code));
    }
    if usage.metrics.is_empty() {
        text.push_str("\nNo quota metrics returned.\n");
    }
    for metric in &usage.metrics {
        metric_text(&mut text, metric);
    }
    text
}

fn metric_text(text: &mut String, metric: &Metric) {
    let _ = write!(text, "\n{}\n", safe(&metric.display_name));
    match metric.quota {
        Quota::Available {
            remaining_percent, ..
        }
        | Quota::Exhausted {
            remaining_percent, ..
        } => {
            let _ = writeln!(
                text,
                "{}  {:.1}% left",
                bar(remaining_percent, 24),
                remaining_percent
            );
        }
        Quota::Limit { amount, ref unit } => {
            let _ = writeln!(text, "Limit {amount:.2} {}", safe(unit));
        }
        Quota::Unlimited => {
            let value = metric.consumption.as_ref().map_or_else(
                || "Unlimited".into(),
                |amount| format!("Unlimited · used {:.2} {}", amount.used, safe(&amount.unit)),
            );
            let _ = writeln!(text, "{value}");
        }
        Quota::Disabled => text.push_str("Disabled\n"),
        Quota::Unknown => {
            let value = metric.amounts.as_ref().map_or_else(
                || {
                    metric.consumption.as_ref().map_or_else(
                        || "Usage unknown".into(),
                        |amount| format!("Used {:.2} {}", amount.used, safe(&amount.unit)),
                    )
                },
                |amount| format!("Balance {:.2} {}", amount.remaining, safe(&amount.unit)),
            );
            let _ = writeln!(text, "{value}");
        }
    }
    if let Some(amounts) = &metric.amounts
        && !matches!(metric.quota, Quota::Unknown)
    {
        let value = amounts.limit.map_or_else(
            || format!("{:.2} {} remaining", amounts.remaining, safe(&amounts.unit)),
            |limit| {
                format!(
                    "{:.2} / {limit:.2} {} remaining",
                    amounts.remaining,
                    safe(&amounts.unit)
                )
            },
        );
        let _ = writeln!(text, "{value}");
    }
    if let Some(reset) = metric
        .resets_at
        .map(reset_text)
        .or_else(|| metric.reset_description.as_deref().map(safe))
    {
        let _ = writeln!(text, "Reset {reset}");
    }
}

fn usage_for<'a>(snapshot: &'a Snapshot, account: &Account) -> Option<&'a Usage> {
    snapshot
        .usage
        .iter()
        .find(|usage| usage.account_id == account.id)
}

fn account_summary(usage: Option<&Usage>) -> String {
    let Some(usage) = usage else {
        return "not loaded".into();
    };
    let remaining = usage
        .summary
        .as_ref()
        .and_then(|summary| summary.combined.lowest)
        .map(|value| format!("lowest {value:.0}% · "))
        .unwrap_or_default();
    format!("{remaining}{}", freshness(usage.freshness))
}

fn freshness(value: Freshness) -> &'static str {
    match value {
        Freshness::NotLoaded => "not loaded",
        Freshness::Fresh => "fresh",
        Freshness::Stale => "stale",
        Freshness::Unavailable => "unavailable",
    }
}

fn bar(percent: f64, width: usize) -> String {
    let filled = ((percent.clamp(0.0, 100.0) / 100.0) * width as f64).round() as usize;
    format!("{}{}", "█".repeat(filled), "░".repeat(width - filled))
}

fn reset_text(at: OffsetDateTime) -> String {
    let remaining = at - OffsetDateTime::now_utc();
    if remaining.is_negative() {
        return "due".into();
    }
    if remaining.whole_days() > 0 {
        format!(
            "in {}d {}h",
            remaining.whole_days(),
            remaining.whole_hours() % 24
        )
    } else if remaining.whole_hours() > 0 {
        format!(
            "in {}h {}m",
            remaining.whole_hours(),
            remaining.whole_minutes() % 60
        )
    } else if remaining.whole_minutes() > 0 {
        format!("in {}m", remaining.whole_minutes())
    } else {
        "soon".into()
    }
}

fn safe(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn renders_account_quota_without_inventing_unknown_usage() {
        let snapshot: Snapshot = serde_json::from_value(json!({
            "schema_version": 2,
            "host": {"id":"test","platform":"linux","api_versions":[2],"capabilities":{}},
            "revision": 1,
            "generated_at": "2026-01-01T00:00:00Z",
            "accounts": [{
                "id":"codex-demo","provider_id":"codex","display_name":"Personal",
                "user_label":null,"identity":{"evidence":"verified","username":null,"email":"demo@example.com"},
                "enabled":true,"active":true,"state":"ready","sources":[],"actions":[]
            }],
            "usage": [{
                "account_id":"codex-demo","freshness":"fresh","fetched_at":"2026-01-01T00:00:00Z",
                "expires_at":null,"plan":"Pro","metrics":[
                    {"id":"session","display_name":"Session","quota":{"state":"available","used_percent":22.0,"remaining_percent":78.0},"amounts":null,"consumption":null,"resets_at":null,"reset_description":"in 2 hours","fetched_at":"2026-01-01T00:00:00Z","provenance":{"source":"mock","confidence":"exact"}},
                    {"id":"monthly","display_name":"Monthly","quota":{"state":"unknown"},"amounts":null,"consumption":null,"resets_at":null,"reset_description":null,"fetched_at":"2026-01-01T00:00:00Z","provenance":{"source":"mock","confidence":"exact"}}
                ],"summary":{"session_only":{"lowest":78.0,"average":78.0},"combined":{"lowest":78.0,"average":78.0},"pair":[]},"issue":null
            }],
            "provider_issues":{},"account_redirects":{}
        })).unwrap();
        let output = render_account(&snapshot, 0);
        assert!(output.contains("Personal · codex\nlowest 78% · fresh · Pro"));
        assert!(output.contains("78.0% left"));
        assert!(output.contains("Monthly\nUsage unknown"));
    }
}
