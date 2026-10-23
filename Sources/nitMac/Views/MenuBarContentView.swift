import AppKit
import DialsKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.displays.isEmpty {
                noDisplaySection
            } else {
                ForEach(model.displays) { display in
                    displaySection(display)
                }
            }

            if !model.hasAccessibilityAccess {
                Divider()
                permissionSection
            }

            Divider()

            LoginItemToggle()

            Divider()

            HStack {
                Button("Refresh displays") { model.discover() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { model.panelDidAppear() }
        .onDisappear { model.panelDidDisappear() }
    }

    private func displaySection(_ display: AppModel.DisplayState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(display.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(display.percent)%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Same glyphs, size and ink as the indicator and as Control Center's
            // Display card, so the two surfaces read as one app.
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill")
                Slider(
                    value: Binding(
                        get: { Double(display.percent) },
                        set: { model.setPercent(Int($0.rounded()), for: display.id) }
                    ),
                    in: 0...100
                )
                Image(systemName: "sun.max.fill")
            }
            .font(.system(size: 15.5))
            .accessibilityLabel("\(display.name) brightness")
        }
    }

    private var noDisplaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No controllable display", systemImage: "display.trianglebadge.exclamationmark")
                .font(.headline)
            Text("nitMac drives external monitors macOS reports as adjustable. Built-in and AirPlay displays stay with macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Brightness keys are not connected", systemImage: "keyboard.badge.exclamationmark")
                .font(.headline)
            Text("Accessibility access lets nitMac see the brightness keys. The slider above works without it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant access…") { model.requestAccessibilityAccess() }
                Button("Open Settings") { model.openAccessibilitySettings() }
            }
            .font(.callout)
        }
    }
}
