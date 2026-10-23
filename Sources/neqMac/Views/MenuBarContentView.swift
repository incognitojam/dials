import AppKit
import DialsKit
import SwiftUI

// MARK: - Shared design vocabulary
//
// neqMac draws routing as a "signal chain": an ordered rail that runs down a
// priority list, drawn solid until the device that actually won, then dashed.
// The same pips, badges and tints are reused in the popover and in preferences
// so a state means the same thing everywhere.

enum RouteStyle {
    /// Output and input are never distinguished by colour alone: they also carry
    /// distinct glyphs, an uppercase direction word, and a leading edge bar.
    static func tint(for direction: DeviceDirection) -> Color {
        switch direction {
        case .output: .accentColor
        case .input: .teal
        }
    }

    /// Output pushes sound away from the Mac, input pulls it in. The arrows
    /// give the two lists a directional identity that survives colour blindness
    /// and greyscale screenshots.
    static func flowSymbol(for direction: DeviceDirection) -> String {
        switch direction {
        case .output: "arrow.right.to.line"
        case .input: "arrow.left.to.line"
        }
    }

    static func transportSymbol(for transport: String) -> String {
        switch transport {
        case "Built-in": "laptopcomputer"
        case "Bluetooth": "wave.3.right"
        case "USB": "cable.connector"
        case "HDMI", "DisplayPort": "display"
        case "AirPlay": "airplayaudio"
        case "Virtual": "waveform"
        case "Aggregate": "square.stack.3d.up"
        default: "hifispeaker"
        }
    }

    static let cardCorner: CGFloat = 12
    static let railWidth: CGFloat = 18
}

/// Every state a device can be in, resolved once so the wording stays identical
/// across the popover, the priority lists and the accessibility layer.
enum RouteSlotState: Equatable {
    case current
    case ready
    case offline
    case excludedConnected
    case excludedOffline

    init(isConnected: Bool, isCurrent: Bool, isExcluded: Bool) {
        if isExcluded {
            self = isConnected ? .excludedConnected : .excludedOffline
        } else if isCurrent {
            self = .current
        } else if isConnected {
            self = .ready
        } else {
            self = .offline
        }
    }

    var title: String {
        switch self {
        case .current: "In use"
        case .ready: "Connected"
        case .offline: "Not connected"
        case .excludedConnected: "Excluded · Connected"
        case .excludedOffline: "Excluded · Not Connected"
        }
    }

    /// Shape carries the meaning; colour only reinforces it.
    var symbol: String {
        switch self {
        case .current: "checkmark.circle.fill"
        case .ready: "circle"
        case .offline: "circle.dashed"
        case .excludedConnected, .excludedOffline: "nosign"
        }
    }

    var isCurrent: Bool { self == .current }

    var isExcluded: Bool {
        self == .excludedConnected || self == .excludedOffline
    }

    var isConnected: Bool {
        self == .current || self == .ready || self == .excludedConnected
    }

    var isSelectable: Bool { isConnected && !isExcluded }
}

/// The state pip used at the head of every device row.
struct StatePip: View {
    let state: RouteSlotState
    let tint: Color
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .current: tint
        case .ready: .secondary
        case .offline: Color.secondary.opacity(0.5)
        case .excludedConnected, .excludedOffline: .secondary
        }
    }
}

/// Small pill used for "In use", "Pinned", "Auto", "Excluded" and friends.
struct StatusBadge: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
        }
        // Keep small labels legible over glass; tint belongs to the pill's
        // background and border rather than its text.
        .foregroundStyle(prominent ? Color.primary : Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(prominent ? tint.opacity(0.13) : Color.secondary.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    prominent ? tint.opacity(0.35) : Color.secondary.opacity(0.22),
                    lineWidth: 0.75
                )
        )
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

/// A single vertical stroke of the signal chain. Solid means "signal reaches
/// here", dashed means "the chain already stopped above".
struct RailStroke: View {
    let isLive: Bool
    let tint: Color

    var body: some View {
        RailPath()
            .stroke(
                isLive ? tint.opacity(0.7) : Color.secondary.opacity(0.35),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    lineCap: .round,
                    dash: isLive ? [] : [1.5, 3]
                )
            )
            .frame(width: 2)
            .accessibilityHidden(true)
    }
}

struct RailPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// How a device is attached, as a glyph followed by the transport word.
struct TransportText: View {
    let transport: String
    var detail: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: RouteStyle.transportSymbol(for: transport))
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(detail.map { "\(transport) · \($0)" } ?? transport)
        }
        .lineLimit(1)
    }
}

/// The direction header: glyph + uppercase word + flow arrow. Readable without
/// colour, and immediately different between input and output.
struct DirectionTag: View {
    let direction: DeviceDirection

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: direction.systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(direction.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
            Image(systemName: RouteStyle.flowSymbol(for: direction))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .accessibilityElement()
        .accessibilityLabel(direction.title)
    }
}

// MARK: - Menu bar popover

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loginItem = LoginItem()
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

            loginItemRow

            footer
        }
        .padding(14)
        .frame(width: 356)
        // The item can be switched off in System Settings behind the app's back,
        // so the real status is re-read every time the popover opens.
        .onAppear { loginItem.refresh() }
    }

    // MARK: Login item

    private var loginItemRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled)) {
                Text("Start at login")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(loginItem.explanation)
            .accessibilityHint(loginItem.explanation)

            if loginItem.needsApproval || loginItem.lastError != nil {
                Text(loginItem.lastError ?? loginItem.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items…") { loginItem.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 8)
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
        if model.manualOutputOverrideUID != nil || model.manualInputOverrideUID != nil {
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
        direction == .output ? model.currentOutput : model.currentInput
    }

    private var overrideUID: String? {
        direction == .output ? model.manualOutputOverrideUID : model.manualInputOverrideUID
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
