//! Provider-neutral projection of collected observations onto resolved accounts.
use super::*;
use crate::domain::{AccountRef, ProviderUsage, UsageReport};
use crate::error::ProviderError;

pub(crate) fn external_id(provider: &str, reference: Option<&AccountRef>) -> String {
    format!(
        "external-{}",
        crate::cache::fingerprint(&[provider, reference.map_or("local", |r| r.id.as_str())])
    )
}

pub(crate) fn external_refresh_source<'a>(
    report: &'a UsageReport,
    provider: &str,
    id: &str,
) -> Option<&'a str> {
    report
        .providers
        .iter()
        .map(|usage| (&usage.provider, usage.account_ref.as_ref()))
        .chain(
            report
                .failures
                .iter()
                .map(|failure| (&failure.provider, failure.account_ref.as_ref())),
        )
        .find_map(|(provider_id, reference)| {
            (provider_id.0 == provider
                && reference.is_none_or(|r| {
                    r.id == "local" || r.origin == Some(AccountOrigin::BorrowedProxy)
                })
                && external_id(provider, reference) == id)
                .then(|| reference.map_or("local", |r| r.id.as_str()))
        })
}

fn reference_matches(provider: &str, reference: Option<&AccountRef>, source: &str) -> bool {
    reference.is_some_and(|reference| reference.id == source)
        || external_id(provider, reference) == source
}

fn same_provider_account(left: &ProviderUsage, right: &ProviderUsage) -> bool {
    if left.provider != right.provider {
        return false;
    }
    match (&left.account.verified, &right.account.verified) {
        (Some(left), Some(right)) => left == right,
        _ => !left.account.id.trim().is_empty() && left.account.id == right.account.id,
    }
}

fn external_source(id: String, reference: Option<&AccountRef>) -> Source {
    let borrowed_proxy = reference.is_some_and(|r| r.origin == Some(AccountOrigin::BorrowedProxy));
    Source {
        id,
        origin: reference
            .and_then(|reference| reference.origin)
            .unwrap_or(AccountOrigin::BorrowedNative),
        kind: if borrowed_proxy {
            "cli_proxy_auth_file"
        } else {
            "external_observation"
        }
        .into(),
        location: None,
        keychain_account: None,
        enabled: true,
        selected: false,
        state: ConnectionState::NotChecked,
        refresh_owner: if borrowed_proxy {
            RefreshOwner::ProviderTool
        } else {
            RefreshOwner::None
        },
        issue: None,
        actions: Vec::new(),
    }
}

fn include_external(accounts: &mut Vec<Account>, report: &UsageReport) {
    for value in &report.providers {
        let provider = value.provider.0.as_str();
        let reference = value.account_ref.as_ref();
        if accounts.iter().any(|account| {
            account.provider_id == provider
                && account
                    .sources
                    .iter()
                    .any(|source| reference_matches(provider, reference, &source.id))
        }) {
            continue;
        }
        let registered = report.providers.iter().find_map(|candidate| {
            let reference = candidate.account_ref.as_ref()?;
            if reference.id == "local"
                || reference.origin == Some(AccountOrigin::BorrowedProxy)
                || !same_provider_account(value, candidate)
            {
                return None;
            }
            accounts.iter().position(|account| {
                account.provider_id == provider
                    && account
                        .sources
                        .iter()
                        .any(|source| reference_matches(provider, Some(reference), &source.id))
            })
        });
        let id = external_id(provider, reference);
        if let Some(index) = registered {
            accounts[index].sources.push(external_source(id, reference));
            continue;
        }
        // Registered source IDs absent from the current vault were unlinked. A late report
        // must not turn them back into unregistered accounts.
        if reference.is_some_and(|reference| {
            reference.id != "local" && reference.origin != Some(AccountOrigin::BorrowedProxy)
        }) {
            continue;
        }
        accounts.push(Account {
            id: id.clone(),
            provider_id: provider.into(),
            display_name: Some(value.account.label.as_str())
                .filter(|label| !label.trim().is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| format!("{provider} account")),
            user_label: None,
            identity: Identity {
                evidence: IdentityEvidence::Unknown,
                username: None,
                email: None,
            },
            enabled: true,
            active: false,
            state: ConnectionState::NotChecked,
            sources: vec![external_source(id, reference)],
            actions: Vec::new(),
        });
    }
    // These references came from discovered files/keys, not failed native login probes.
    for failure in &report.failures {
        let Some(reference) = failure
            .account_ref
            .as_ref()
            .filter(|reference| reference.origin == Some(AccountOrigin::BorrowedProxy))
        else {
            continue;
        };
        if accounts.iter().any(|account| {
            account.provider_id == failure.provider.0
                && account.sources.iter().any(|source| {
                    reference_matches(&failure.provider.0, Some(reference), &source.id)
                })
        }) {
            continue;
        }
        let id = external_id(&failure.provider.0, Some(reference));
        let enabled = failure.code != ProviderError::SourceDisabled;
        let mut source = external_source(id.clone(), Some(reference));
        source.enabled = enabled;
        accounts.push(Account {
            id,
            provider_id: failure.provider.0.clone(),
            display_name: reference.label.clone(),
            user_label: None,
            identity: Identity {
                evidence: IdentityEvidence::Unknown,
                username: None,
                email: None,
            },
            enabled,
            active: false,
            state: ConnectionState::NotChecked,
            sources: vec![source],
            actions: Vec::new(),
        });
    }
}

fn issue(code: ProviderError) -> Issue {
    let action = match code {
        ProviderError::Authentication => Some("sign_in"),
        ProviderError::OwnerRefreshRequired => Some("refresh_in_source_app"),
        ProviderError::CredentialStorage | ProviderError::LocalCredentialStorage => {
            Some("authorize")
        }
        ProviderError::Timeout
        | ProviderError::Transient
        | ProviderError::RateLimited
        | ProviderError::Cancelled => Some("retry"),
        _ => None,
    };
    Issue {
        code: serde_json::to_value(code)
            .expect("error code")
            .as_str()
            .expect("string code")
            .into(),
        retryable: matches!(
            code,
            ProviderError::Timeout
                | ProviderError::Transient
                | ProviderError::RateLimited
                | ProviderError::Cancelled
        ),
        action: action.map(|kind| Action {
            kind: kind.into(),
            available: true,
            reason: None,
            interaction: if kind == "retry" {
                InteractionLocation::Host
            } else {
                InteractionLocation::HostUser
            },
        }),
    }
}

fn state(code: ProviderError) -> ConnectionState {
    match code {
        ProviderError::Authentication | ProviderError::OwnerRefreshRequired => {
            ConnectionState::NeedsLogin
        }
        ProviderError::CredentialStorage | ProviderError::LocalCredentialStorage => {
            ConnectionState::NeedsAuthorization
        }
        ProviderError::SourceDisabled => ConnectionState::Disabled,
        _ => ConnectionState::Unavailable,
    }
}

pub(crate) fn metric_id(window: &crate::domain::QuotaWindow) -> String {
    window
        .metric_id
        .as_ref()
        .filter(|id| valid_id(id))
        .cloned()
        .unwrap_or_else(|| {
            crate::cache::fingerprint(&[
                "metric",
                window.metric_id.as_deref().unwrap_or(&window.label),
            ])
        })
}

fn plan_display_name(provider: &str, raw: &str) -> String {
    let normalized = raw.to_ascii_lowercase();
    let label = match (provider, normalized.as_str()) {
        ("codex", "pro") => "Pro 20x",
        ("codex", "prolite" | "pro_lite" | "pro-lite" | "pro lite") => "Pro 5x",
        ("openrouter", "openrouter-free") => "Free Tier",
        ("openrouter", "openrouter-pay-as-you-go") => "Pay as You Go",
        (_, "guest") => "Guest",
        (_, "free") => "Free",
        (_, "go") => "Go",
        (_, "plus") => "Plus",
        (_, "pro") => "Pro",
        (_, "free_workspace") => "Free Workspace",
        (_, "team") => "Team",
        (_, "business") => "Business",
        (_, "education") => "Education",
        (_, "quorum") => "Quorum",
        (_, "k12") => "K-12",
        (_, "enterprise") => "Enterprise",
        (_, "edu") => "Edu",
        _ => raw,
    };
    label.into()
}

fn observation(
    account_id: &str,
    value: &ProviderUsage,
    report: &UsageReport,
    now: OffsetDateTime,
    ttl: time::Duration,
    failure: Option<ProviderError>,
) -> Usage {
    // Plan-only successes are never cached. Their collection timestamp is the observation time.
    let fetched = value
        .windows
        .iter()
        .map(|window| window.fetched_at)
        .min()
        .unwrap_or(report.generated_at);
    let expires = fetched.checked_add(ttl);
    let stale = failure.is_some() || now < fetched || expires.is_none_or(|at| now >= at);
    Usage {
        account_id: account_id.into(),
        freshness: if stale {
            Freshness::Stale
        } else {
            Freshness::Fresh
        },
        fetched_at: Some(fetched),
        expires_at: expires,
        plan: value
            .account
            .plan
            .as_deref()
            .map(|plan| plan_display_name(&value.provider.0, plan)),
        subscription_status: value.account.subscription_status.clone(),
        reset_credits: value
            .reset_credits
            .clone()
            .filter(|credits| !stale && credits.valid_at(now)),
        antigravity_subscription: value.antigravity_subscription.clone(),
        codex_profile: value.codex_profile.clone(),
        codex_reset_credits: value.codex_reset_credits.clone().filter(|_| !stale),
        summary: Some(super::summary::project(value)),
        metrics: value
            .windows
            .iter()
            .map(|window| Metric {
                id: metric_id(window),
                group: metric_group(&value.provider.0, window).map(|(group, _)| group.into()),
                display_name: metric_group(&value.provider.0, window)
                    .map_or_else(|| window.label.clone(), |(_, name)| name.into()),
                note: window.note.clone(),
                quota: window.quota.clone(),
                amounts: window.amounts.clone(),
                consumption: window.consumption.clone(),
                resets_at: window.resets_at,
                reset_description: window.reset_description.clone(),
                fetched_at: window.fetched_at,
                provenance: window.provenance.clone(),
            })
            .collect(),
        issue: failure
            .or_else(|| value.diagnostics.first().map(|diagnostic| diagnostic.code))
            .map(issue),
    }
}

fn metric_group(
    provider: &str,
    window: &crate::domain::QuotaWindow,
) -> Option<(&'static str, &'static str)> {
    if provider != "factory" {
        return None;
    }
    let id = window.metric_id.as_deref()?;
    let (group, period) = if let Some(period) = id.strip_prefix("factory-standard-") {
        ("Standard", period)
    } else {
        ("Core", id.strip_prefix("factory-core-")?)
    };
    let name = match period {
        "five-hour" => "5 hours",
        "weekly" => "Weekly",
        "monthly" => "Monthly",
        _ => return None,
    };
    Some((group, name))
}

/// Resolve source health and choose one usable observation without combining quota balances.
/// Callers must fence the report against concurrent mutations before invoking this projection.
pub fn project(
    accounts: AccountList,
    report: &UsageReport,
    now: OffsetDateTime,
    ttl: time::Duration,
) -> Result<Snapshot, &'static str> {
    let mut snapshot = Snapshot {
        schema_version: 2,
        host: accounts.host,
        revision: accounts.revision,
        generated_at: now,
        accounts: accounts.accounts,
        usage: Vec::new(),
        provider_issues: BTreeMap::new(),
        account_redirects: accounts.account_redirects,
    };
    include_external(&mut snapshot.accounts, report);
    for failure in &report.failures {
        let reference = failure.account_ref.as_ref();
        if reference.is_none_or(|reference| {
            reference.id == "local" || reference.origin == Some(AccountOrigin::BorrowedProxy)
        }) && !snapshot.accounts.iter().any(|account| {
            account.provider_id == failure.provider.0
                && account
                    .sources
                    .iter()
                    .any(|source| reference_matches(&failure.provider.0, reference, &source.id))
        }) {
            snapshot
                .provider_issues
                .entry(failure.provider.0.clone())
                .or_insert_with(|| issue(failure.code));
        }
    }
    for account in &mut snapshot.accounts {
        let mut choices = Vec::new();
        for source in &mut account.sources {
            source.selected = false;
            if !account.enabled || !source.enabled {
                source.state = ConnectionState::Disabled;
                source.issue = None;
                continue;
            }
            let value = report.providers.iter().find(|value| {
                value.provider.0 == account.provider_id
                    && reference_matches(
                        &account.provider_id,
                        value.account_ref.as_ref(),
                        &source.id,
                    )
            });
            let failure = report
                .failures
                .iter()
                .find(|failure| {
                    failure.provider.0 == account.provider_id
                        && reference_matches(
                            &account.provider_id,
                            failure.account_ref.as_ref(),
                            &source.id,
                        )
                        && !value.is_some_and(|value| {
                            value
                                .diagnostics
                                .iter()
                                .any(|diagnostic| diagnostic.code == failure.code)
                        })
                })
                .map(|failure| failure.code);
            source.issue = failure
                .or_else(|| {
                    value.and_then(|value| {
                        value.diagnostics.first().map(|diagnostic| diagnostic.code)
                    })
                })
                .map(issue);
            source.state = failure.map(state).unwrap_or(if value.is_some() {
                ConnectionState::Ready
            } else {
                ConnectionState::NotChecked
            });
            if let Some(value) = value {
                choices.push((
                    source.id.clone(),
                    source.origin,
                    observation(&account.id, value, report, now, ttl, failure),
                ));
            }
        }
        choices.sort_by(|a, b| {
            let rank = |entry: &(String, AccountOrigin, Usage)| {
                (
                    entry.2.freshness != Freshness::Fresh,
                    entry.2.issue.is_some(),
                    entry.1 != AccountOrigin::Owned,
                )
            };
            rank(a)
                .cmp(&rank(b))
                .then_with(|| b.2.fetched_at.cmp(&a.2.fetched_at))
                .then_with(|| a.0.cmp(&b.0))
        });
        if let Some((selected, _, usage)) = choices.into_iter().next() {
            let source = account
                .sources
                .iter_mut()
                .find(|source| source.id == selected)
                .expect("projected source");
            source.selected = true;
            account.state = source.state;
            snapshot.usage.push(usage);
        } else {
            account.state = if !account.enabled {
                ConnectionState::Disabled
            } else {
                account
                    .sources
                    .iter()
                    .filter(|source| source.enabled)
                    .find(|source| source.issue.is_some())
                    .map_or(ConnectionState::NotChecked, |source| source.state)
            };
            let source_issue = account
                .sources
                .iter()
                .filter(|source| source.enabled)
                .find_map(|source| source.issue.clone());
            snapshot.usage.push(Usage {
                account_id: account.id.clone(),
                freshness: if source_issue.is_some() {
                    Freshness::Unavailable
                } else {
                    Freshness::NotLoaded
                },
                fetched_at: None,
                expires_at: None,
                plan: None,
                subscription_status: None,
                reset_credits: None,
                antigravity_subscription: None,
                codex_profile: None,
                codex_reset_credits: None,
                metrics: Vec::new(),
                summary: None,
                issue: source_issue,
            });
        }
    }
    snapshot.validate()?;
    Ok(snapshot)
}

pub fn digest(snapshot: &Snapshot) -> Result<String, crate::accounts::AccountError> {
    let content = serde_json::to_string(&(
        &snapshot.host,
        &snapshot.accounts,
        &snapshot.usage,
        &snapshot.provider_issues,
        &snapshot.account_redirects,
    ))
    .map_err(|_| crate::accounts::AccountError::Snapshot)?;
    Ok(crate::cache::fingerprint(&[&content]))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn factory_limits_have_host_groups_and_short_period_names() {
        let report: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/fixtures/contracts/usage-v1.json"))
                .unwrap();
        let mut parsed: crate::domain::QuotaWindow =
            serde_json::from_value(report["providers"][0]["windows"][0].clone()).unwrap();
        let window = &mut parsed;
        for (pool, group) in [("standard", "Standard"), ("core", "Core")] {
            for (period, name) in [
                ("five-hour", "5 hours"),
                ("weekly", "Weekly"),
                ("monthly", "Monthly"),
            ] {
                window.metric_id = Some(format!("factory-{pool}-{period}"));
                assert_eq!(metric_group("factory", window), Some((group, name)));
                assert_eq!(metric_group("future", window), None);
            }
        }
        window.metric_id = Some("factory-extra-balance".into());
        assert_eq!(metric_group("factory", window), None);
    }
    #[test]
    fn plan_labels_preserve_provider_specific_and_unknown_names() {
        for (provider, raw, expected) in [
            ("codex", "pro", "Pro 20x"),
            ("codex", "pro_lite", "Pro 5x"),
            ("claude", "pro", "Pro"),
            ("openrouter", "openrouter-free", "Free Tier"),
            ("future", "Custom CBP Plan 2x", "Custom CBP Plan 2x"),
            ("factory", "standard", "standard"),
        ] {
            assert_eq!(plan_display_name(provider, raw), expected);
        }
    }
}
