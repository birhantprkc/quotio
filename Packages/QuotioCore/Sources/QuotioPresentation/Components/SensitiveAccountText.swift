import SwiftUI

struct SensitiveAccountText: View {
    let value: String
    let isSensitive: Bool

    @State private var isRevealed = false

    private var isBlurred: Bool { isSensitive && !isRevealed }

    var body: some View {
        Text(value)
            .blur(radius: isBlurred ? 4 : 0)
            .privacySensitive()
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded { isRevealed.toggle() },
                including: isSensitive ? .all : .none
            )
            .accessibilityLabel(isBlurred ? Text("privacy.accountHidden".localized()) : Text(verbatim: value))
            .accessibilityActions {
                if isSensitive {
                    Button((isBlurred ? "action.showAccountName" : "action.hideAccountName").localized()) {
                        isRevealed.toggle()
                    }
                }
            }
            .onChange(of: isSensitive) { _, _ in isRevealed = false }
            .onDisappear { isRevealed = false }
    }
}
