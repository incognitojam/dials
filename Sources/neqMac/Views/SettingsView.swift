import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Pane = .routing

    enum Pane: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case activity = "Activity"
        case about = "About"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .routing: "arrow.triangle.branch"
            case .activity: "clock.arrow.circlepath"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Pane.allCases) { pane in
                    SidebarButton(
                        pane: pane,
                        isSelected: selection == pane
                    ) {
                        selection = pane
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 168)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch selection {
                case .routing: RoutingSettingsView()
                case .activity: ActivityView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 600)
    }
}

private struct SidebarButton: View {
    let pane: SettingsView.Pane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                Text(pane.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

// MARK: - Routing

private struct RoutingSettingsView: View {
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

private struct PaneHeader: View {
    let title: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityAddTraits(.isHeader)
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

// MARK: - Priority list

private struct DeviceRulesSection: View {
    @EnvironmentObject private var model: AppModel
    let direction: DeviceDirection

    private var rules: [DeviceRule] { model.rules(for: direction) }
    private var tint: Color { RouteStyle.tint(for: direction) }

    private var overrideUID: String? {
        direction == .output ? model.manualOutputOverrideUID : model.manualInputOverrideUID
    }

    /// Index of the row where the signal chain stops.
    private var activeIndex: Int? {
        rules.firstIndex { model.isCurrent($0) }
    }

    private var allowedConnectedCount: Int {
        rules.filter { !$0.isExcluded && model.device(for: $0) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: direction.systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(direction.title)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                if rules.isEmpty {
                    ContentUnavailableView(
                        "No \(direction.rawValue) devices",
                        systemImage: direction.systemImage,
                        description: Text("Connect a \(direction.rawValue) device and it will appear here, ready to be ordered.")
                    )
                    .frame(height: 150)
                } else {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        DeviceRuleRow(
                            rule: rule,
                            rank: index + 1,
                            isFirst: index == 0,
                            isLast: index == rules.count - 1,
                            isLiveAbove: activeIndex.map { index <= $0 } ?? false,
                            isLiveBelow: activeIndex.map { index < $0 } ?? false,
                            isPinned: overrideUID == rule.uid,
                            tint: tint
                        )

                        if index < rules.count - 1 {
                            Divider().padding(.leading, RouteStyle.railWidth + 24)
                        }
                    }
                }

                if !model.policy.automationEnabled, !rules.isEmpty {
                    Divider()
                    footerNote(
                        symbol: "pause.circle",
                        text: "Automatic routing is paused, so this order is not being enforced right now."
                    )
                } else if overrideUID != nil {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("A pinned \(direction.rawValue) is overriding this order until it disconnects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Return to Priority Order") {
                            model.clearManualOverride(for: direction)
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                } else if allowedConnectedCount == 0, !rules.isEmpty {
                    Divider()
                    footerNote(
                        symbol: "exclamationmark.triangle",
                        text: "Nothing here is both connected and allowed, so macOS keeps whatever it last chose."
                    )
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

    private func footerNote(symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct DeviceRuleRow: View {
    @EnvironmentObject private var model: AppModel
    let rule: DeviceRule
    let rank: Int
    let isFirst: Bool
    let isLast: Bool
    let isLiveAbove: Bool
    let isLiveBelow: Bool
    let isPinned: Bool
    let tint: Color

    private var state: RouteSlotState {
        RouteSlotState(
            isConnected: model.device(for: rule) != nil,
            isCurrent: model.isCurrent(rule),
            isExcluded: rule.isExcluded
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            rail

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .fontWeight(state.isCurrent ? .semibold : .regular)
                    .foregroundStyle(state.isExcluded ? Color.secondary : Color.primary)
                    .strikethrough(state.isExcluded, color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                HStack(spacing: 6) {
                    Text(state.isCurrent ? rule.transportLabel : "\(rule.transportLabel) · \(state.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if state.isCurrent {
                        StatusBadge(text: "In use", systemImage: "checkmark", tint: tint, prominent: true)
                    }
                    if isPinned {
                        StatusBadge(text: "Pinned", systemImage: "pin.fill", tint: .orange, prominent: true)
                    }
                }
            }
            // Vertical padding lives here, not on the row, so the chain rail
            // runs unbroken from one device to the next.
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 2) {
                Button {
                    model.moveRule(direction: rule.direction, id: rule.id, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isFirst)
                .help("Move \(rule.name) up the \(rule.direction.rawValue) priority order")
                .accessibilityLabel("Increase priority of \(rule.name)")

                Button {
                    model.moveRule(direction: rule.direction, id: rule.id, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isLast)
                .help("Move \(rule.name) down the \(rule.direction.rawValue) priority order")
                .accessibilityLabel("Decrease priority of \(rule.name)")
            }

            Toggle("Never use", isOn: Binding(
                get: { rule.isExcluded },
                set: { model.setExcluded($0, ruleID: rule.id) }
            ))
            .toggleStyle(.checkbox)
            .fixedSize()
            .help(neverUseHelp)
            .accessibilityLabel("Never use \(rule.name)")
            .accessibilityHint(neverUseHelp)

            Button("Use now") {
                model.useNow(rule)
            }
            .fixedSize()
            .disabled(!state.isSelectable || state.isCurrent)
            .help(useNowHelp)
            .accessibilityLabel("Use \(rule.name) now")
        }
        .padding(.trailing, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.name), priority \(rank), \(state.title)\(isPinned ? ", pinned" : "")")
    }

    private var useNowHelp: String {
        if rule.isExcluded { return "Excluded devices cannot be selected. Turn off Never use first." }
        if model.device(for: rule) == nil { return "\(rule.name) is not connected." }
        if state.isCurrent { return "\(rule.name) is already in use." }
        return "Switch to \(rule.name) now and pin it until it disconnects."
    }

    private var neverUseHelp: String {
        if rule.direction == .input {
            return "Prevent neqMac from selecting this microphone. Excluding a Bluetooth headset microphone can preserve high-quality headphone audio."
        }
        return "Prevent neqMac from selecting this output."
    }

    // MARK: The signal chain rail

    private var rail: some View {
        HStack(spacing: 2) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .trailing)
                .accessibilityHidden(true)

            // The chain is solid down to the device that actually won, then
            // dashed: you can see exactly where the signal stopped.
            VStack(spacing: 3) {
                RailStroke(isLive: isLiveAbove, tint: tint)
                    .frame(maxHeight: .infinity)
                    .opacity(isFirst ? 0 : 1)

                StatePip(state: state, tint: tint)

                RailStroke(isLive: isLiveBelow, tint: tint)
                    .frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 18)
            .frame(maxHeight: .infinity)
        }
        .frame(width: RouteStyle.railWidth)
        .frame(maxHeight: .infinity)
        .padding(.leading, 12)
        .help(state.title)
    }
}

// MARK: - Activity

private struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(
                    title: "Activity",
                    blurb: "A local timeline of device and policy changes, newest first. Nothing leaves your Mac."
                )

                if model.events.isEmpty {
                    ContentUnavailableView(
                        "No activity yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Connect or disconnect a device, or change your priority order, and it will be logged here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                            EventRow(
                                event: event,
                                isFirst: index == 0,
                                isLast: index == model.events.count - 1
                            )
                        }
                    }
                    .padding(.vertical, 6)
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
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct EventRow: View {
    let event: RoutingEvent
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Same rail motif, used here as a timeline spine.
            VStack(spacing: 3) {
                RailStroke(isLive: false, tint: .secondary)
                    .frame(height: 6)
                    .opacity(isFirst ? 0 : 1)

                Image(systemName: event.level.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(event.level.color)

                RailStroke(isLive: false, tint: .secondary)
                    .frame(height: 24)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 18)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.date, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 5)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(event.level.spokenLabel): \(event.message), \(event.date.formatted(date: .omitted, time: .standard))"
        )
    }
}

private extension RoutingEvent.Level {
    var icon: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        }
    }

    var spokenLabel: String {
        switch self {
        case .info: "Note"
        case .success: "Done"
        case .warning: "Warning"
        }
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    ChainMark()
                        .frame(width: 72, height: 84)
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("neqMac")
                            .font(.system(size: 28, weight: .bold))
                        Text("A quieter, more predictable audio device guardian for macOS.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        StatusBadge(text: "Proof of concept", systemImage: "hammer.fill")
                        StatusBadge(text: "Routing only", systemImage: "arrow.triangle.branch")
                    }

                    Text("This milestone covers ordering, pinning and excluding audio inputs and outputs. EQ profiles are not part of this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(geometry.size.height - 80, 0))
                .padding(40)
            }
            .defaultScrollAnchor(.center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The app mark: the signal chain, solid until it lands, dashed after.
private struct ChainMark: View {
    var body: some View {
        VStack(spacing: 0) {
            RailStroke(isLive: true, tint: .accentColor)
                .frame(height: 22)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            RailStroke(isLive: false, tint: .accentColor)
                .frame(height: 22)
            Image(systemName: "circle.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
    }
}
