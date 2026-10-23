import SwiftUI

/// Re-reads the login item's status each time it appears, since it can be
/// switched off in System Settings behind the app's back.
public struct LoginItemToggle: View {
    @StateObject private var loginItem = LoginItem()
    private let font: Font
    private let detailFont: Font
    private let controlSize: ControlSize

    public init(font: Font = .callout, detailFont: Font = .caption, controlSize: ControlSize = .small) {
        self.font = font
        self.detailFont = detailFont
        self.controlSize = controlSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled)) {
                Text("Start at login")
                    .font(font)
            }
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .help(loginItem.explanation)
            .accessibilityHint(loginItem.explanation)

            if loginItem.needsApproval || loginItem.lastError != nil {
                Text(loginItem.lastError ?? loginItem.explanation)
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items…") { loginItem.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(detailFont)
            }
        }
        .onAppear { loginItem.refresh() }
    }
}
