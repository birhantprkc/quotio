import SwiftUI
import QuotioMobile

/// One quota window: label, reset countdown, colored percent and a thin bar.
struct QuotaTile: View {
    let label: String
    /// Remaining percent from the host, or nil when the window has no value.
    let remaining: Double?
    var resetsAt: Date?
    var resetHint: DisplayNames.ResetHint?
    var now = Date()
    var showUsed = false
    var stale = false

    @Environment(\.density) private var density
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { stale ? DS.Palette.muted : DS.Palette.level(QuotaFormat.level(remaining: remaining)) }

    private var percentText: String {
        guard let remaining else { return "—" }
        return QuotaFormat.percentText(remaining: remaining, showUsed: showUsed, locale: locale)
    }

    private var resetText: String? {
        if let resetsAt { return QuotaFormat.countdown(to: resetsAt, from: now, locale: locale) }
        return resetHint.flatMap { DisplayNames.shortReset($0, locale: locale) }
    }

    var body: some View {
        let accessible = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let header = accessible
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xxs))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DS.Space.xs))
            header {
                Text(label)
                    .font(DS.Typography.tileLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(accessible ? 3 : 1)
                if !accessible { Spacer(minLength: DS.Space.xs) }
                if let resetText {
                    Text(resetText)
                        .font(DS.Typography.countdown)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: DS.Space.s) {
                Text(percentText)
                    .font(DS.Typography.percent)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
                    .privacySensitive()
                QuotaBar(fraction: remaining.map { Double(QuotaFormat.displayPercent(remaining: $0, showUsed: showUsed)) / 100 }, color: color)
            }
        }
        .padding(DS.Layout.of(density).tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tileSurface()
        .animation(DS.Motion.standard(reduceMotion: reduceMotion), value: remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel))
    }

    private var spokenLabel: String {
        var parts = [label]
        if let remaining {
            let value = QuotaFormat.displayPercent(remaining: remaining, showUsed: showUsed)
            parts.append(showUsed ? String(localized: "\(value) percent used") : String(localized: "\(value) percent remaining"))
        } else {
            parts.append(String(localized: "No data"))
        }
        if stale { parts.append(String(localized: "Outdated")) }
        if let resetsAt, let spoken = QuotaFormat.spokenCountdown(to: resetsAt, from: now, locale: locale) {
            parts.append(String(localized: "resets in \(spoken)"))
        } else if let resetHint {
            parts.append(DisplayNames.longReset(resetHint, locale: locale))
        }
        return parts.joined(separator: ", ")
    }
}

extension QuotaTile {
    init(metric: MobileSnapshot.Metric, now: Date, showUsed: Bool, stale: Bool) {
        let remaining: Double? = if case .percent(let value) = metric.content { value } else { nil }
        self.init(label: metric.label, remaining: remaining, resetsAt: metric.resetsAt, resetHint: metric.resetHint,
                  now: now, showUsed: showUsed, stale: stale)
    }
}

#if DEBUG
#Preview("States", traits: .sizeThatFitsLayout) {
    let now = Date()
    Grid(horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.s) {
        GridRow {
            QuotaTile(label: "Weekly", remaining: 74, resetsAt: now.addingTimeInterval(75 * 3600), now: now)
            QuotaTile(label: "Weekly", remaining: 45, resetsAt: now.addingTimeInterval(4 * 3600 + 22 * 60), now: now)
        }
        GridRow {
            QuotaTile(label: "Session", remaining: 12, resetsAt: now.addingTimeInterval(20 * 60), now: now)
            QuotaTile(label: "Weekly", remaining: 0, resetsAt: now.addingTimeInterval(27 * 3600), now: now)
        }
        GridRow {
            QuotaTile(label: "Premium requests", remaining: 100, now: now, stale: true)
            QuotaTile(label: "Monthly", remaining: nil, now: now)
        }
        GridRow {
            QuotaTile(label: "Orb usage", remaining: 47.6, resetHint: .renewal(DateComponents(day: 18)), now: now)
            QuotaTile(label: "Weekly", remaining: 74, now: now, showUsed: true)
        }
        GridRow {
            QuotaTile(label: "Claude and GPT · Weekly with an extra long label", remaining: 100, resetsAt: now.addingTimeInterval(167 * 3600), now: now)
                .gridCellColumns(2)
        }
    }
    .padding()
    .frame(width: 390)
}

#Preview("Variants", traits: .sizeThatFitsLayout) {
    PreviewMatrix {
        QuotaTile(label: "Weekly", remaining: 45, resetsAt: .now.addingTimeInterval(75 * 3600))
            .frame(width: 180)
    }
}
#endif
