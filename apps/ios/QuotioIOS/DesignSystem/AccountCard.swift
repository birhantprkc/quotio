import SwiftUI
import QuotioMobile

/// Account summary: identity row, grouped quota tiles, value rows and freshness.
struct AccountCard: View {
    let account: MobileSnapshot.Account
    /// Account name; nil when it adds nothing (single account without identity).
    let title: String?
    var blurAccountName = false
    var showUsed = false
    var accountNameToggleEnabled = false
    var toggleAccountName: () -> Void = {}

    @Environment(\.density) private var density
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = DS.Layout.of(density)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = account.isStale(at: context.date)
            VStack(alignment: .leading, spacing: layout.cardSpacing) {
                header(now: context.date)
                ForEach(account.tileGroups) { group in
                    if let name = group.name {
                        Text(DisplayNames.group(name))
                            .font(DS.Typography.groupTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    tileGrid(group.metrics, now: context.date, stale: stale, spacing: layout.gridSpacing)
                }
                if !account.valueMetrics.isEmpty {
                    VStack(spacing: DS.Space.xs) {
                        ForEach(account.valueMetrics) { metric in
                            ValueRow(label: metric.label, value: metric.valueText(locale: locale))
                        }
                    }
                    .padding(.horizontal, layout.tilePadding)
                }
            }
            .padding(layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    /// Spoken once per card; tiles follow with their own window, percent and reset.
    private func spokenHeader(now: Date) -> String {
        var parts = [account.providerName]
        if let title { parts.append(blurAccountName ? String(localized: "Account hidden") : title) }
        if let plan = account.planBadge { parts.append(String(localized: "Plan \(plan)")) }
        if let fetchedAt = account.fetchedAt {
            let age = min(fetchedAt, now).formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: locale))
            parts.append(account.isOld(at: now) ? String(localized: "Outdated, updated \(age)") : String(localized: "Updated \(age)"))
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func header(now: Date) -> some View {
        let accessible = dynamicTypeSize.isAccessibilitySize
        let stack = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs))
            : AnyLayout(HStackLayout(spacing: DS.Space.s))
        stack {
            HStack(spacing: DS.Space.s) {
                ProviderIcon(providerID: account.providerID).foregroundStyle(.secondary)
                if let title {
                    Text(title)
                        .font(DS.Typography.accountTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .blur(radius: blurAccountName ? DS.Space.xs : 0)
                        .privacySensitive()
                        .accessibilityHidden(blurAccountName)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded(toggleAccountName),
                                             including: accountNameToggleEnabled ? .all : .none)
                }
                if let plan = account.planBadge { PlanBadge(text: plan).layoutPriority(1) }
            }
            if !accessible { Spacer(minLength: DS.Space.xs) }
            FreshnessLabel(date: account.fetchedAt, isOld: account.isOld(at: now)).layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenHeader(now: now)))
        .accessibilityActions {
            if accountNameToggleEnabled, title != nil {
                Button(blurAccountName ? "Show account name" : "Hide account name", action: toggleAccountName)
            }
        }
    }

    @ViewBuilder private func tileGrid(_ metrics: [MobileSnapshot.Metric], now: Date, stale: Bool, spacing: CGFloat) -> some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Self.rows(metrics, columns: columns), id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { metric in
                        QuotaTile(metric: metric, now: now, showUsed: showUsed, stale: stale)
                            .gridCellColumns(row.count == 1 ? columns : 1)
                    }
                }
            }
        }
    }

    /// Pairs tiles into rows. A tile spans the full row when its label is long or it has no partner.
    static func rows(_ metrics: [MobileSnapshot.Metric], columns: Int) -> [[MobileSnapshot.Metric]] {
        guard columns > 1 else { return metrics.map { [$0] } }
        var rows: [[MobileSnapshot.Metric]] = []
        var pending: MobileSnapshot.Metric?
        for metric in metrics {
            if metric.label.count > DS.Size.longLabel {
                if let waiting = pending { rows.append([waiting]); pending = nil }
                rows.append([metric])
            } else if let waiting = pending {
                rows.append([waiting, metric]); pending = nil
            } else {
                pending = metric
            }
        }
        if let pending { rows.append([pending]) }
        return rows
    }
}

extension MobileSnapshot.Metric {
    /// Text for value rows. Tiles never call this.
    func valueText(locale: Locale) -> String {
        switch content(locale: locale) {
        case .amount(let text), .spent(let text), .status(let text): text
        case .percent, .noData: "—"
        }
    }
}

#if DEBUG
#Preview("States", traits: .sizeThatFitsLayout) {
    ScrollView {
        VStack(spacing: DS.Space.m) {
            AccountCard(account: PreviewFixtures.codex, title: PreviewFixtures.codex.name)
            AccountCard(account: PreviewFixtures.low, title: PreviewFixtures.low.name)
            AccountCard(account: PreviewFixtures.amp, title: PreviewFixtures.amp.name)
            AccountCard(account: PreviewFixtures.factory, title: PreviewFixtures.factory.name)
            AccountCard(account: PreviewFixtures.antigravity, title: PreviewFixtures.antigravity.name)
            AccountCard(account: PreviewFixtures.stale, title: PreviewFixtures.stale.name)
            AccountCard(account: PreviewFixtures.longEmail, title: PreviewFixtures.longEmail.name)
            AccountCard(account: PreviewFixtures.codex, title: PreviewFixtures.codex.name, blurAccountName: true)
            AccountCard(account: PreviewFixtures.codex, title: PreviewFixtures.codex.name, showUsed: true)
        }
        .padding()
    }
    .background(DS.Palette.background)
    .frame(width: 393)
}

#Preview("Compact density", traits: .sizeThatFitsLayout) {
    VStack(spacing: DS.Space.s) {
        AccountCard(account: PreviewFixtures.amp, title: PreviewFixtures.amp.name)
        AccountCard(account: PreviewFixtures.antigravity, title: PreviewFixtures.antigravity.name)
    }
    .padding()
    .environment(\.density, .compact)
    .frame(width: 393)
}

#Preview("Variants", traits: .sizeThatFitsLayout) {
    PreviewMatrix { AccountCard(account: PreviewFixtures.amp, title: PreviewFixtures.amp.name) }.frame(width: 393)
}
#endif
