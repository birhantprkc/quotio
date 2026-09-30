import SwiftUI

/// Label and right-aligned value for non-percentage data such as credits.
struct ValueRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DS.Space.s))
        layout {
            Text(label).font(DS.Typography.valueLabel).foregroundStyle(.secondary)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: DS.Space.s) }
            Text(value)
                .font(DS.Typography.value)
                .foregroundStyle(.primary)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One label (not label + value) so the text survives when a parent button merges children.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label), \(value)"))
    }
}

#if DEBUG
#Preview("States", traits: .sizeThatFitsLayout) {
    VStack(spacing: DS.Space.s) {
        ValueRow(label: "Individual credits", value: "$136.57")
        ValueRow(label: "Workspace bytrong credits", value: "$0")
        ValueRow(label: "Extra usage", value: "62,500 credits")
        ValueRow(label: "A very long provider value label that should wrap gracefully", value: "Unlimited")
    }
    .padding()
}

#Preview("Variants", traits: .sizeThatFitsLayout) {
    PreviewMatrix { ValueRow(label: "Individual credits", value: "$136.57") }
}
#endif
