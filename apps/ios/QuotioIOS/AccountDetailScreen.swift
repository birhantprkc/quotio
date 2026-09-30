import SwiftUI
import Charts
import QuotioMobile

/// Everything the host reports for one account, with absolute and relative reset times.
struct AccountDetailScreen: View {
    let account: MobileSnapshot.Account
    let blurAccountName: Bool
    let showUsed: Bool
    let pinned: Bool
    let togglePin: () -> Void

    @Environment(\.locale) private var locale
    @State private var accountNameRevealed = false

    private var shouldBlurAccountName: Bool { blurAccountName && !accountNameRevealed }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    summary
                    ForEach(account.tileGroups) { group in
                        section(group.name.map(DisplayNames.group) ?? String(localized: "Quota")) {
                            ForEach(Array(group.metrics.enumerated()), id: \.element.id) { index, metric in
                                if index > 0 { Divider() }
                                quotaRow(metric, now: context.date)
                            }
                        }
                    }
                    if !account.valueMetrics.isEmpty {
                        section(String(localized: "Balances")) {
                            ForEach(account.valueMetrics) { metric in
                                ValueRow(label: metric.label, value: metric.valueText(locale: locale))
                            }
                        }
                    }
                    if let count = account.availableResets(at: context.date) {
                        section(String(localized: "Rate limit resets")) {
                            ValueRow(label: String(localized: "Available"), value: count.formatted(.number.locale(locale)))
                        }
                    }
                    if let analytics = account.analytics {
                        section(String(localized: "Activity")) { AnalyticsSummary(analytics: analytics) }
                    }
                    section(String(localized: "Data")) {
                        ValueRow(label: String(localized: "Status"), value: freshnessText(at: context.date))
                        if let fetchedAt = account.fetchedAt {
                            ValueRow(label: String(localized: "Updated"),
                                     value: fetchedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale)))
                        }
                        if let issue = account.issue {
                            ValueRow(label: String(localized: "Last error"), value: DisplayNames.issue(issue))
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.xl)
            }
        }
        .background(DS.Palette.background)
        .onDisappear { accountNameRevealed = false }
        .navigationTitle(account.providerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(pinned ? "Unpin account" : "Pin account", systemImage: pinned ? "pin.slash" : "pin", action: togglePin)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                ProviderIcon(providerID: account.providerID, size: DS.Space.xl).foregroundStyle(.secondary)
                Text(account.name)
                    .font(DS.Typography.detailTitle)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .blur(radius: shouldBlurAccountName ? DS.Space.xs : 0)
                    .privacySensitive()
                    .accessibilityLabel(shouldBlurAccountName ? Text("Account hidden") : Text(verbatim: account.name))
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { accountNameRevealed.toggle() },
                                         including: blurAccountName ? .all : .none)
                    .accessibilityActions {
                        if blurAccountName {
                            Button(shouldBlurAccountName ? "Show account name" : "Hide account name") {
                                accountNameRevealed.toggle()
                            }
                        }
                    }
            }
            if let plan = account.planBadge { ValueRow(label: String(localized: "Plan"), value: plan) }
            ValueRow(label: String(localized: "Account"), value: account.enabled ? DisplayNames.accountState(account.state) : String(localized: "Disabled on your Mac"))
            if let status = account.subscriptionStatus {
                ValueRow(label: String(localized: "Subscription"), value: DisplayNames.subscriptionStatus(status))
            }
        }
        .padding(DS.Space.m)
        .cardSurface()
        .padding(.top, DS.Space.s)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(DS.Typography.sectionTitle).foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.Space.s) { content() }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
    }

    private func quotaRow(_ metric: MobileSnapshot.Metric, now: Date) -> some View {
        let remaining: Double? = if case .percent(let value) = metric.content { value } else { nil }
        let stale = account.isStale(at: now)
        let color = stale ? DS.Palette.muted : DS.Palette.level(QuotaFormat.level(remaining: remaining))
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label).font(DS.Typography.valueLabel)
                Spacer()
                Text(remaining.map { QuotaFormat.percentText(remaining: $0, showUsed: showUsed, locale: locale) } ?? "—")
                    .font(DS.Typography.detailPercent)
                    .foregroundStyle(color)
                    .privacySensitive()
                Text(showUsed ? "used" : "left").font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            QuotaBar(fraction: remaining.map { Double(QuotaFormat.displayPercent(remaining: $0, showUsed: showUsed)) / 100 }, color: color)
            if let reset = resetText(metric, now: now) {
                Text(reset).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            if let amounts = metric.amounts, let limit = amounts.limit {
                Text("\(QuotaFormat.amount(amounts.remaining, unit: amounts.unit, locale: locale)) of \(QuotaFormat.amount(limit, unit: amounts.unit, locale: locale)) left")
                    .font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            if let note = metric.note {
                Text(note).font(DS.Typography.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func resetText(_ metric: MobileSnapshot.Metric, now: Date) -> String? {
        if let date = metric.resetsAt {
            let absolute = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().locale(locale))
            guard let countdown = QuotaFormat.countdown(to: date, from: now, locale: locale) else {
                return String(localized: "Reset \(absolute)")
            }
            return String(localized: "Resets in \(countdown) · \(absolute)")
        }
        return metric.resetHint.map { DisplayNames.longReset($0, locale: locale) }
    }

    private func freshnessText(at now: Date) -> String {
        if account.isStale(at: now) { return String(localized: "Outdated") }
        return switch account.freshness {
        case "fresh": String(localized: "Up to date")
        case "not_loaded": String(localized: "Not loaded yet")
        default: String(localized: "Unavailable")
        }
    }
}

/// Codex account activity: 30-day token chart and profile statistics.
private struct AnalyticsSummary: View {
    let analytics: MobileSnapshot.Analytics
    @Environment(\.locale) private var locale

    var body: some View {
        ValueRow(label: String(localized: "Tokens, 30 reported days"), value: analytics.latest30BucketsTokens.formatted(.number.notation(.compactName).locale(locale)))
        Chart(Array(analytics.days.suffix(30))) { day in
            BarMark(x: .value("Reported day", day.date), y: .value("Tokens", day.tokens))
                .foregroundStyle(DS.Palette.accent)
                .cornerRadius(DS.Space.xxs)
                .accessibilityLabel(day.date)
                .accessibilityValue(Text("\(day.tokens) tokens"))
        }
        .chartXAxis(.hidden)
        .frame(height: DS.Size.chart)
        statistic("Lifetime tokens", analytics.lifetimeTokens)
        statistic("Peak day", analytics.peakDailyTokens)
        if let seconds = analytics.longestRunningTurnSeconds {
            ValueRow(label: String(localized: "Longest turn"),
                     value: Duration.seconds(Int(seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2).locale(locale)))
        }
        if let days = analytics.currentStreakDays { ValueRow(label: String(localized: "Current streak"), value: String(localized: "\(days) days")) }
        if let days = analytics.longestStreakDays { ValueRow(label: String(localized: "Longest streak"), value: String(localized: "\(days) days")) }
    }

    @ViewBuilder private func statistic(_ label: String.LocalizationValue, _ value: UInt64?) -> some View {
        if let value {
            ValueRow(label: String(localized: label), value: value.formatted(.number.notation(.compactName).locale(locale)))
        }
    }
}

#if DEBUG
#Preview("Amp") {
    NavigationStack {
        AccountDetailScreen(account: PreviewFixtures.amp, blurAccountName: false, showUsed: false, pinned: false, togglePin: {})
    }
}

#Preview("Factory · VI · Dark") {
    NavigationStack {
        AccountDetailScreen(account: PreviewFixtures.factory, blurAccountName: false, showUsed: false, pinned: true, togglePin: {})
    }
    .environment(\.locale, Locale(identifier: "vi"))
    .preferredColorScheme(.dark)
}

#Preview("Hidden · AX5") {
    NavigationStack {
        AccountDetailScreen(account: PreviewFixtures.codex, blurAccountName: true, showUsed: false, pinned: false, togglePin: {})
    }
    .dynamicTypeSize(.accessibility5)
}
#endif
