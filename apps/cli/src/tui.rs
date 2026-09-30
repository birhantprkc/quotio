use crate::{
    cli::TuiArgs,
    contract::{Account, Freshness, Metric, Snapshot, Usage},
    domain::Quota,
    usage,
};
use crossterm::{
    cursor::{Hide, Show},
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::{
    Frame, Terminal,
    backend::CrosstermBackend,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap},
};
use std::{io, io::IsTerminal, time::Duration};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

struct App {
    snapshot: Option<Snapshot>,
    selected: usize,
    scroll: u16,
    status: String,
    refreshing: bool,
    help: bool,
    colors: bool,
    exit_code: u8,
}

impl App {
    fn new(colors: bool) -> Self {
        Self {
            snapshot: None,
            selected: 0,
            scroll: 0,
            status: "Loading usage…".into(),
            refreshing: true,
            help: false,
            colors,
            exit_code: 0,
        }
    }

    fn accounts_len(&self) -> usize {
        self.snapshot
            .as_ref()
            .map_or(0, |snapshot| snapshot.accounts.len())
    }

    fn move_selection(&mut self, delta: isize) {
        let len = self.accounts_len();
        if len == 0 {
            return;
        }
        self.selected = (self.selected as isize + delta).rem_euclid(len as isize) as usize;
        self.scroll = 0;
    }

    fn apply(&mut self, result: Result<usage::Collected, usage::Error>) {
        self.refreshing = false;
        match result {
            Ok(collected) => {
                self.exit_code = collected.exit_code;
                self.snapshot = Some(collected.snapshot);
                self.selected = self.selected.min(self.accounts_len().saturating_sub(1));
                self.scroll = 0;
                self.status = if self.accounts_len() == 0 {
                    collected
                        .diagnostics
                        .lines()
                        .next()
                        .unwrap_or("No provider returned usage.")
                        .into()
                } else if collected.exit_code == 0 {
                    "Updated".into()
                } else {
                    "Updated with provider issues".into()
                };
            }
            Err(error) => {
                self.exit_code = error.exit_code;
                self.status = format!("Refresh failed: {}", error.message);
            }
        }
    }
}

struct RestoreTerminal;

impl Drop for RestoreTerminal {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), Show, LeaveAlternateScreen);
    }
}

pub async fn run(args: TuiArgs) -> Result<u8, String> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err("TUI requires an interactive terminal.".into());
    }
    let colors = !args.no_color && std::env::var_os("NO_COLOR").is_none();
    let request = usage::Request {
        force: false,
        providers: args.provider,
        timeout: args.timeout,
        config: args.config,
        no_saved_accounts: args.no_saved_accounts,
        account: args.account,
    };
    enable_raw_mode().map_err(|_| "Could not enable terminal raw mode.")?;
    let _restore = RestoreTerminal;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, Hide)
        .map_err(|_| "Could not initialize terminal display.")?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend).map_err(|_| "Could not initialize terminal.")?;
    terminal.clear().map_err(|_| "Could not clear terminal.")?;

    let mut app = App::new(colors);
    let mut refresh = Some(tokio::spawn(usage::collect(request.clone())));
    loop {
        if refresh
            .as_ref()
            .is_some_and(tokio::task::JoinHandle::is_finished)
        {
            let result = refresh
                .take()
                .expect("refresh task")
                .await
                .map_err(|_| usage::Error {
                    message: "refresh task stopped unexpectedly".into(),
                    exit_code: 3,
                });
            app.apply(result.and_then(|result| result));
        }
        terminal
            .draw(|frame| render(frame, &app))
            .map_err(|_| "Could not draw terminal display.")?;
        if !event::poll(Duration::from_millis(100)).map_err(|_| "Could not read terminal input.")? {
            continue;
        }
        let Event::Key(key) = event::read().map_err(|_| "Could not read terminal input.")? else {
            continue;
        };
        if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
            continue;
        }
        if should_quit(key) && !(app.help && key.code == KeyCode::Esc) {
            if let Some(task) = refresh.take() {
                task.abort();
            }
            return Ok(app.exit_code);
        }
        if app.help {
            if matches!(key.code, KeyCode::Esc | KeyCode::Char('?')) {
                app.help = false;
            }
            continue;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') | KeyCode::Left => app.move_selection(-1),
            KeyCode::Down | KeyCode::Char('j') | KeyCode::Right => app.move_selection(1),
            KeyCode::PageUp => app.scroll = app.scroll.saturating_sub(5),
            KeyCode::PageDown => app.scroll = app.scroll.saturating_add(5),
            KeyCode::Char('?') => app.help = true,
            KeyCode::Char('r') if refresh.is_none() => {
                app.refreshing = true;
                app.status = "Refreshing…".into();
                let mut forced = request.clone();
                forced.force = true;
                refresh = Some(tokio::spawn(usage::collect(forced)));
            }
            _ => {}
        }
    }
}

fn should_quit(key: KeyEvent) -> bool {
    matches!(key.code, KeyCode::Esc | KeyCode::Char('q'))
        || key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL)
}

fn render(frame: &mut Frame<'_>, app: &App) {
    let area = frame.area();
    if area.width < 50 || area.height < 14 {
        frame.render_widget(
            Paragraph::new("Terminal too small\nMinimum: 50 × 14")
                .alignment(Alignment::Center)
                .block(Block::default().title(" Quotio ").borders(Borders::ALL)),
            area,
        );
        return;
    }
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(1),
        ])
        .split(area);
    render_header(frame, rows[0], app);
    if area.width >= 88 {
        let columns = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(32), Constraint::Min(40)])
            .split(rows[1]);
        render_accounts(frame, columns[0], app);
        render_detail(frame, columns[1], app);
    } else {
        render_detail(frame, rows[1], app);
    }
    frame.render_widget(
        Paragraph::new("↑↓/jk select   PgUp/PgDn scroll   r refresh   ? help   q quit")
            .alignment(Alignment::Center)
            .style(dim(app.colors)),
        rows[2],
    );
    if app.help {
        render_help(frame, area, app.colors);
    }
}

fn render_header(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let count = app.accounts_len();
    let position = if count == 0 {
        "0/0".into()
    } else {
        format!("{}/{}", app.selected + 1, count)
    };
    let status = if app.refreshing {
        format!("{}  ⟳", app.status)
    } else {
        app.status.clone()
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("Quotio", accent(app.colors)),
            Span::raw(format!("  {position}  ")),
            Span::styled(status, dim(app.colors)),
        ]))
        .block(Block::default().borders(Borders::ALL)),
        area,
    );
}

fn render_accounts(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let Some(snapshot) = &app.snapshot else {
        frame.render_widget(
            Paragraph::new("Discovering accounts…")
                .block(Block::default().title(" Accounts ").borders(Borders::ALL)),
            area,
        );
        return;
    };
    let items: Vec<_> = snapshot
        .accounts
        .iter()
        .map(|account| {
            let usage = usage_for(snapshot, account);
            let issue = account.sources.iter().any(|source| source.issue.is_some())
                || usage.and_then(|value| value.issue.as_ref()).is_some();
            let symbol = if issue { "!" } else { "●" };
            ListItem::new(vec![
                Line::from(format!("{symbol} {}", safe(&account.display_name))),
                Line::styled(
                    format!("  {} · {}", account.provider_id, account_summary(usage)),
                    dim(app.colors),
                ),
            ])
        })
        .collect();
    let mut state = ListState::default().with_selected((!items.is_empty()).then_some(app.selected));
    frame.render_stateful_widget(
        List::new(items)
            .block(Block::default().title(" Accounts ").borders(Borders::ALL))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED | Modifier::BOLD)),
        area,
        &mut state,
    );
}

fn render_detail(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let Some(snapshot) = &app.snapshot else {
        frame.render_widget(
            Paragraph::new("Collecting provider usage…")
                .alignment(Alignment::Center)
                .block(Block::default().title(" Usage ").borders(Borders::ALL)),
            area,
        );
        return;
    };
    let Some(account) = snapshot.accounts.get(app.selected) else {
        frame.render_widget(
            Paragraph::new("No accounts found.\nSign in or select a provider explicitly.")
                .alignment(Alignment::Center)
                .block(Block::default().title(" Usage ").borders(Borders::ALL)),
            area,
        );
        return;
    };
    let usage = usage_for(snapshot, account);
    let mut lines = vec![
        Line::from(vec![
            Span::styled(safe(&account.provider_id), accent(app.colors)),
            Span::raw(
                usage
                    .and_then(|value| value.plan.as_deref())
                    .map(|plan| format!(" · {}", safe(plan)))
                    .unwrap_or_default(),
            ),
            Span::styled(
                format!(
                    " · {}",
                    usage.map_or("not loaded", |value| freshness(value.freshness))
                ),
                dim(app.colors),
            ),
        ]),
        Line::raw(""),
    ];
    if let Some(issue) = usage.and_then(|value| value.issue.as_ref()) {
        lines.push(Line::styled(
            format!("! {}", safe(&issue.code)),
            warning(app.colors),
        ));
        lines.push(Line::raw(""));
    }
    if let Some(usage) = usage {
        if usage.metrics.is_empty() {
            lines.push(Line::raw("No quota metrics returned."));
        }
        let bar_width = (area.width as usize).saturating_sub(20).clamp(8, 32);
        for metric in &usage.metrics {
            metric_lines(&mut lines, metric, bar_width, app.colors);
        }
    } else {
        lines.push(Line::raw("Usage has not been loaded."));
    }
    frame.render_widget(
        Paragraph::new(lines)
            .scroll((app.scroll, 0))
            .wrap(Wrap { trim: true })
            .block(
                Block::default()
                    .title(format!(" {} ", safe(&account.display_name)))
                    .borders(Borders::ALL),
            ),
        area,
    );
}

fn metric_lines(lines: &mut Vec<Line<'static>>, metric: &Metric, width: usize, colors: bool) {
    lines.push(Line::styled(
        safe(&metric.display_name),
        Style::default().add_modifier(Modifier::BOLD),
    ));
    match metric.quota {
        Quota::Available {
            remaining_percent, ..
        }
        | Quota::Exhausted {
            remaining_percent, ..
        } => lines.push(Line::styled(
            format!(
                "{}  {:>5.1}% left",
                bar(remaining_percent, width),
                remaining_percent
            ),
            quota_style(colors, remaining_percent),
        )),
        Quota::Limit { amount, ref unit } => {
            lines.push(Line::raw(format!("Limit {amount:.2} {}", safe(unit))))
        }
        Quota::Unlimited => lines.push(Line::raw(metric.consumption.as_ref().map_or_else(
            || "Unlimited".into(),
            |value| format!("Unlimited · used {:.2} {}", value.used, safe(&value.unit)),
        ))),
        Quota::Disabled => lines.push(Line::styled("Disabled", warning(colors))),
        Quota::Unknown => lines.push(Line::raw(metric.amounts.as_ref().map_or_else(
            || {
                metric.consumption.as_ref().map_or_else(
                    || "Usage unknown".into(),
                    |value| format!("Used {:.2} {}", value.used, safe(&value.unit)),
                )
            },
            |value| format!("Balance {:.2} {}", value.remaining, safe(&value.unit)),
        ))),
    }
    if let Some(amounts) = &metric.amounts
        && !matches!(metric.quota, Quota::Unknown)
    {
        lines.push(Line::styled(
            amounts.limit.map_or_else(
                || format!("{:.2} {} remaining", amounts.remaining, safe(&amounts.unit)),
                |limit| {
                    format!(
                        "{:.2} / {limit:.2} {} remaining",
                        amounts.remaining,
                        safe(&amounts.unit)
                    )
                },
            ),
            dim(colors),
        ));
    }
    let reset = metric
        .resets_at
        .map(reset_text)
        .or_else(|| metric.reset_description.as_deref().map(safe));
    if let Some(reset) = reset {
        lines.push(Line::styled(format!("Reset {reset}"), dim(colors)));
    }
    lines.push(Line::raw(""));
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
        at.format(&Rfc3339).unwrap_or_else(|_| "soon".into())
    }
}

fn safe(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .collect()
}

fn accent(colors: bool) -> Style {
    if colors {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().add_modifier(Modifier::BOLD)
    }
}

fn dim(colors: bool) -> Style {
    if colors {
        Style::default().fg(Color::DarkGray)
    } else {
        Style::default().add_modifier(Modifier::DIM)
    }
}

fn warning(colors: bool) -> Style {
    if colors {
        Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
    } else {
        Style::default().add_modifier(Modifier::BOLD)
    }
}

fn quota_style(colors: bool, remaining: f64) -> Style {
    if !colors {
        return Style::default();
    }
    Style::default().fg(if remaining <= 20.0 {
        Color::Red
    } else if remaining <= 50.0 {
        Color::Yellow
    } else {
        Color::Green
    })
}

fn render_help(frame: &mut Frame<'_>, area: Rect, colors: bool) {
    let width = area.width.min(54);
    let height = area.height.min(12);
    let popup = Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, popup);
    frame.render_widget(
        Paragraph::new(vec![
            Line::raw("↑ ↓ / j k / ← →   Select account"),
            Line::raw("PgUp / PgDn       Scroll metrics"),
            Line::raw("r                 Refresh now"),
            Line::raw("q / Ctrl-C         Quit"),
            Line::raw("Esc / ?            Close help"),
        ])
        .style(dim(colors))
        .block(Block::default().title(" Keys ").borders(Borders::ALL)),
        popup,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use serde_json::json;

    fn snapshot() -> Snapshot {
        serde_json::from_value(json!({
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
                "expires_at":null,"plan":"Pro","metrics":[{
                    "id":"session","display_name":"Session","quota":{"state":"available","used_percent":22.0,"remaining_percent":78.0},
                    "amounts":null,"consumption":null,"resets_at":null,"reset_description":"in 2 hours",
                    "fetched_at":"2026-01-01T00:00:00Z","provenance":{"source":"mock","confidence":"exact"}
                }],"summary":{"session_only":{"lowest":78.0,"average":78.0},"combined":{"lowest":78.0,"average":78.0},"pair":[]},"issue":null
            }],
            "provider_issues":{},"account_redirects":{}
        }))
        .unwrap()
    }

    fn screen(width: u16, height: u16) -> String {
        let backend = TestBackend::new(width, height);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut app = App::new(false);
        app.snapshot = Some(snapshot());
        app.refreshing = false;
        app.status = "Updated".into();
        terminal.draw(|frame| render(frame, &app)).unwrap();
        let buffer = terminal.backend().buffer();
        (0..height)
            .flat_map(|y| (0..width).map(move |x| buffer[(x, y)].symbol()))
            .collect()
    }

    #[test]
    fn renders_wide_and_compact_layouts() {
        let wide = screen(120, 30);
        assert!(wide.contains("Accounts"));
        assert!(wide.contains("Session"));
        assert!(wide.contains("78.0% left"));

        let compact = screen(70, 24);
        assert!(!compact.contains("Accounts"));
        assert!(compact.contains("Personal"));
        assert!(compact.contains("Session"));
    }
}
