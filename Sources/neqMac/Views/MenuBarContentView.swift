import AppKit
import DialsKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            RouteCard(direction: .output)
            RouteCard(direction: .input)

            if let error = model.lastError {
                errorBanner(error)
            }

            Divider()

            LoginItemToggle(font: .system(size: 11, weight: .medium), detailFont: .system(size: 10), controlSize: .mini)
                .padding(.horizontal, 8)

            footer
        }
        .padding(14)
        .frame(width: 356)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.28))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.75)
                    }
                Image(systemName: "waveform.path")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("neqMac")
                    .font(.system(size: 15, weight: .semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("Automatic routing", isOn: Binding(
                get: { model.policy.automationEnabled },
                set: model.setAutomationEnabled
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(model.policy.automationEnabled
                  ? "Automatic routing is on. Turn it off to keep the current devices."
                  : "Automatic routing is paused. Turn it on to follow your priority order.")
            .accessibilityLabel("Automatic routing")
        }
    }

    private var statusText: String {
        if !model.policy.automationEnabled { return "Automation paused" }
        if !model.manualOverrideUIDs.isEmpty {
            return "Auto-routing · manual pin active"
        }
        return "Auto-routing your devices"
    }

    // MARK: Error

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Rescan devices") { model.refreshHardwareState() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Ask Core Audio for the current device list again.")
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.75)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Routing problem: \(message)")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            PopoverActionButton(
                title: "Routing Preferences…",
                systemImage: "slider.horizontal.3"
            ) {
                dismiss()
                openWindow(id: "routing")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)

            Spacer(minLength: 0)

            PopoverActionButton(
                title: "Quit",
                systemImage: "power",
                isSubdued: true
            ) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Route card

private struct RouteCard: View {
    @EnvironmentObject private var model: AppModel
    let direction: DeviceDirection

    private var tint: Color { RouteStyle.tint(for: direction) }
    private var rules: [DeviceRule] { model.rules(for: direction) }

    private var currentDevice: AudioDevice? {
        model.currentDevice(for: direction)
    }

    private var overrideUID: String? {
        model.manualOverrideUID(for: direction)
    }

    private var currentState: RouteSlotState {
        guard currentDevice != nil else { return .offline }
        let rule = rules.first { model.isCurrent($0) }
        return RouteSlotState(
            isConnected: true,
            isCurrent: true,
            isExcluded: rule?.isExcluded ?? false
        )
    }

    /// The device that would take over if the current one vanished — the whole
    /// point of the app, so it is shown up front rather than buried.
    private var fallback: DeviceRule? {
        rules.first { rule in
            !rule.isExcluded
                && model.device(for: rule) != nil
                && !model.isCurrent(rule)
        }
    }

    private var systemOutputName: String? {
        guard direction == .output, !model.policy.includeSystemSounds else { return nil }
        guard let device = model.outputDevices.first(where: { $0.audioObjectID == model.systemOutputID }),
              device.audioObjectID != model.defaultOutputID else { return nil }
        return device.name
    }

    var body: some View {
        HStack(spacing: 0) {
            // Leading edge bar: the signal chain motif, continued into the popover.
            Capsule(style: .continuous)
                .fill(tint.opacity(0.55))
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    DirectionTag(direction: direction)
                    Spacer(minLength: 4)
                    modeBadge
                }

                devicePicker

                footnotes
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: RouteStyle.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RouteStyle.cardCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: RouteStyle.cardCorner, style: .continuous))
    }

    @ViewBuilder
    private var modeBadge: some View {
        if overrideUID != nil {
            StatusBadge(text: "Pinned", systemImage: "pin.fill", tint: .orange, prominent: true)
                .help("You chose this \(direction.rawValue) manually. It stays until the device disconnects.")
        } else if model.policy.automationEnabled {
            StatusBadge(text: "Auto", systemImage: "arrow.triangle.branch", tint: tint, prominent: true)
                .help("Following your \(direction.rawValue) priority order.")
        } else {
            StatusBadge(text: "Paused", systemImage: "pause.fill")
                .help("Automatic routing is off, so this \(direction.rawValue) will not change on its own.")
        }
    }

    // MARK: Picker

    private var devicePicker: some View {
        Menu {
            if rules.isEmpty {
                Button("No \(direction.rawValue) devices found") {}
                    .disabled(true)
            } else {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    Button {
                        model.useNow(rule)
                    } label: {
                        Text("\(index + 1). \(rule.name) — \(state(for: rule).title)")
                    }
                    .disabled(!state(for: rule).isSelectable || state(for: rule).isCurrent)
                }
            }

            if overrideUID != nil {
                Divider()
                Button("Return to Priority Order") {
                    model.clearManualOverride(for: direction)
                }
            }
        } label: {
            HStack(spacing: 9) {
                StatePip(state: currentState, tint: tint, size: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentDevice?.name ?? "No \(direction.rawValue) device")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Group {
                        if let currentDevice {
                            TransportText(transport: currentDevice.transportLabel)
                        } else {
                            Text("Nothing available to route to")
                        }
                    }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(rules.isEmpty)
        .help("Choose the \(direction.rawValue) device to use right now.")
        .accessibilityLabel("Current \(direction.rawValue)")
        .accessibilityValue(
            currentDevice.map { "\($0.name), \(currentState.title)" }
                ?? "No \(direction.rawValue) device"
        )
    }

    // MARK: Footnotes

    @ViewBuilder
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(fallbackText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement()
            .accessibilityLabel(fallbackText)

            if let systemOutputName {
                HStack(spacing: 5) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Alerts stay on \(systemOutputName)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if overrideUID != nil {
                Button("Return to priority order") {
                    model.clearManualOverride(for: direction)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Hand this \(direction.rawValue) back to automatic routing.")
            }
        }
    }

    private var fallbackText: String {
        if rules.isEmpty { return "No \(direction.rawValue) devices detected" }
        if let fallback { return "Falls back to \(fallback.name)" }
        return "No fallback \(direction.rawValue) available"
    }

    private func state(for rule: DeviceRule) -> RouteSlotState {
        RouteSlotState(
            isConnected: model.device(for: rule) != nil,
            isCurrent: model.isCurrent(rule),
            isExcluded: rule.isExcluded
        )
    }
}

// MARK: - Footer button

private struct PopoverActionButton: View {
    let title: String
    let systemImage: String
    var isSubdued: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSubdued && !isHovering ? Color.secondary : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
        .accessibilityLabel(title)
    }
}
