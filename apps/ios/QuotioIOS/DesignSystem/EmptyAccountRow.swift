import SwiftUI

/// One muted line for an account the host has no quota data for.
struct EmptyAccountRow: View {
    let title: String?
    let reason: String?
    var blurAccountName = false
    var accountNameToggleEnabled = false
    var toggleAccountName: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s) { content }
            VStack(alignment: .leading, spacing: DS.Space.xxs) { content }
        }
        .font(DS.Typography.valueLabel)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s + DS.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if accountNameToggleEnabled, title != nil {
                Button(blurAccountName ? "Show account name" : "Hide account name", action: toggleAccountName)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let title {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .blur(radius: blurAccountName ? DS.Space.xs : 0)
                .privacySensitive()
                .accessibilityHidden(blurAccountName)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded(toggleAccountName),
                                     including: accountNameToggleEnabled ? .all : .none)
        }
        Text("No quota data").foregroundStyle(.secondary)
        if let reason {
            Text(reason).foregroundStyle(.tertiary)
        }
    }

    private var accessibilityText: Text {
        let parts = [title.map { blurAccountName ? String(localized: "Account hidden") : $0 },
                     String(localized: "No quota data"), reason].compactMap { $0 }
        return Text(verbatim: parts.joined(separator: ", "))
    }
}

#if DEBUG
#Preview("States", traits: .sizeThatFitsLayout) {
    VStack(spacing: DS.Space.s) {
        EmptyAccountRow(title: nil, reason: "Not loaded yet")
        EmptyAccountRow(title: "person@example.test", reason: "Signed out")
        EmptyAccountRow(title: "person@example.test", reason: "Signed out", blurAccountName: true)
        EmptyAccountRow(title: "a.really.long.email.address@some-company.example.com", reason: "Keychain access needed on your Mac")
        EmptyAccountRow(title: nil, reason: nil)
    }
    .padding()
    .frame(width: 390)
}

#Preview("Variants", traits: .sizeThatFitsLayout) {
    PreviewMatrix { EmptyAccountRow(title: "person@example.test", reason: "Signed out") }.frame(width: 390)
}
#endif
