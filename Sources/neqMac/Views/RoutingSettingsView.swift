import SwiftUI

struct RoutingSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(
                    title: "Routing",
                    blurb: "neqMac uses the first connected device not marked Never use; Use now temporarily overrides the order."
                )

                automationCard

                DeviceRulesSection(direction: .output)

                DeviceRulesSection(direction: .input)
            }
            .padding(26)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var automationCard: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Automatic routing",
                detail: "Keep macOS on the highest-priority device that is connected and allowed.",
                symbolOn: "arrow.triangle.branch",
                symbolOff: "pause.circle",
                isOn: Binding(
                    get: { model.policy.automationEnabled },
                    set: model.setAutomationEnabled
                )
            )

            Divider().padding(.leading, 48)

            SettingsToggleRow(
                title: "System sounds follow the output",
                detail: "Send alerts and interface sounds to the same device as everything else.",
                symbolOn: "bell.badge.fill",
                symbolOff: "bell.slash",
                isOn: Binding(
                    get: { model.policy.includeSystemSounds },
                    set: model.setIncludeSystemSounds
                )
            )

            if let error = model.lastError {
                Divider().padding(.leading, 48)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Core Audio reported a problem")
                            .fontWeight(.medium)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Rescan") { model.refreshHardwareState() }
                        .help("Ask Core Audio for the current device list again.")
                }
                .padding(12)
                .accessibilityElement(children: .contain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let symbolOn: String
    let symbolOff: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isOn ? symbolOn : symbolOff)
                .font(.title3)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .help(detail)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}
