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

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var draggingID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allowedConnectedCount: Int {
        rules.filter { !$0.isExcluded && model.device(for: $0) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: direction.systemImage)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(direction.title)
                }
                .font(.headline)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                if !rules.isEmpty {
                    Button(isEditing ? "Done" : "Edit") {
                        isEditing.toggle()
                        selectedIDs = []
                    }
                    .controlSize(.small)
                    .help(isEditing ? "Finish removing devices." : "Remove \(direction.rawValue) devices you no longer use.")
                }
            }

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
                        let isDragging = draggingID == rule.id

                        VStack(spacing: 0) {
                            if index > 0 {
                                Divider()
                                    .padding(.leading, RouteStyle.railWidth + 24)
                                    .opacity(isDragging ? 0 : 1)
                            }

                            DeviceRuleRow(
                                rule: rule,
                                rank: index + 1,
                                isFirst: index == 0,
                                isLast: index == rules.count - 1,
                                isLiveAbove: activeIndex.map { index <= $0 } ?? false,
                                isLiveBelow: activeIndex.map { index < $0 } ?? false,
                                isPinned: overrideUID == rule.uid,
                                isDragging: isDragging,
                                isEditing: isEditing,
                                isSelected: Binding(
                                    get: { selectedIDs.contains(rule.id) },
                                    set: { selected in
                                        if selected { selectedIDs.insert(rule.id) } else { selectedIDs.remove(rule.id) }
                                    }
                                ),
                                tint: tint
                            )
                        }
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: RowFramesKey.self,
                                    value: [rule.id: geometry.frame(in: .named(coordinateSpace))]
                                )
                            }
                        }
                        .offset(y: offset(for: rule, at: index))
                        .animation(isDragging || reduceMotion ? nil : .snappy(duration: 0.15), value: dropIndex)
                        .zIndex(isDragging ? 1 : 0)
                        .gesture(reorderGesture(for: rule), including: isEditing ? .subviews : .all)
                    }
                }

                if isEditing {
                    Divider()
                    editFooter
                } else if !model.policy.automationEnabled, !rules.isEmpty {
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
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(RowFramesKey.self) { frames in
                if draggingID == nil { rowFrames = frames }
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

    // MARK: Removing devices

    private var disconnectedIDs: Set<String> {
        Set(rules.filter { model.device(for: $0) == nil }.map(\.id))
    }

    private var editFooter: some View {
        let removable = selectedIDs.intersection(disconnectedIDs)

        return HStack(spacing: 8) {
            Text("Removed devices are added back if they reconnect.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Select Disconnected") { selectedIDs = disconnectedIDs }
                .controlSize(.small)
                .disabled(disconnectedIDs.isEmpty || removable == disconnectedIDs)
            Button(removable.isEmpty ? "Remove" : "Remove \(removable.count)", role: .destructive) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    model.removeRules(direction: direction, ids: removable)
                }
                selectedIDs = []
                if model.rules(for: direction).isEmpty { isEditing = false }
            }
            .controlSize(.small)
            .disabled(removable.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Drag to reorder

    private var coordinateSpace: String { "rules-\(direction.rawValue)" }

    private var draggedFrame: CGRect? { draggingID.flatMap { rowFrames[$0] } }

    private var sourceIndex: Int? { rules.firstIndex { $0.id == draggingID } }

    private var clampedTranslation: CGFloat {
        guard let draggedFrame,
              let top = rules.first.flatMap({ rowFrames[$0.id] }),
              let bottom = rules.last.flatMap({ rowFrames[$0.id] }) else { return 0 }
        return min(max(dragTranslation, top.minY - draggedFrame.minY), bottom.maxY - draggedFrame.maxY)
    }

    /// Rows above the source stay above until the dragged row's top edge
    /// passes their middle; rows below move up once its bottom edge does.
    private var dropIndex: Int? {
        guard let draggedFrame, let sourceIndex else { return nil }
        let top = draggedFrame.minY + clampedTranslation
        let bottom = draggedFrame.maxY + clampedTranslation
        return rules.enumerated().filter { index, rule in
            guard index != sourceIndex, let frame = rowFrames[rule.id] else { return false }
            return frame.midY < (index < sourceIndex ? top : bottom)
        }.count
    }

    private func offset(for rule: DeviceRule, at index: Int) -> CGFloat {
        guard let draggedFrame, let sourceIndex, let dropIndex else { return 0 }
        if rule.id == draggingID { return clampedTranslation }
        if sourceIndex < dropIndex, (sourceIndex + 1...dropIndex).contains(index) { return -draggedFrame.height }
        if dropIndex < sourceIndex, (dropIndex..<sourceIndex).contains(index) { return draggedFrame.height }
        return 0
    }

    private func reorderGesture(for rule: DeviceRule) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                if draggingID == nil { draggingID = rule.id }
                guard draggingID == rule.id else { return }
                NSCursor.closedHand.set()
                dragTranslation = value.translation.height
            }
            .onEnded { _ in
                guard draggingID == rule.id else { return }
                NSCursor.arrow.set()
                let target = dropIndex
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if let target {
                        model.moveRule(direction: direction, id: rule.id, to: target)
                    }
                    draggingID = nil
                    dragTranslation = 0
                }
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
    let isDragging: Bool
    let isEditing: Bool
    @Binding var isSelected: Bool
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
                    TransportText(transport: rule.displayTransport, detail: state.isCurrent ? nil : state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

            if isEditing {
                Toggle("Remove \(rule.name)", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(state.isConnected)
                    .help(state.isConnected
                          ? "\(rule.name) is connected, so it would be added straight back."
                          : "Select \(rule.name) to remove it from the list.")
                    .padding(.trailing, 6)
            } else {
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

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDragging ? .secondary : .tertiary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
                    .help("Drag to change the priority of \(rule.name).")
                    .accessibilityHidden(true)
            }
        }
        .padding(.trailing, 8)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move to Top") { model.moveRule(direction: rule.direction, id: rule.id, to: .first) }
                .disabled(isFirst)
            Button("Move Up") { model.moveRule(direction: rule.direction, id: rule.id, offset: -1) }
                .disabled(isFirst)
            Button("Move Down") { model.moveRule(direction: rule.direction, id: rule.id, offset: 1) }
                .disabled(isLast)
            Button("Move to Bottom") { model.moveRule(direction: rule.direction, id: rule.id, to: .last) }
                .disabled(isLast)
            Divider()
            Button("Remove from List", role: .destructive) {
                model.removeRules(direction: rule.direction, ids: [rule.id])
            }
            .disabled(state.isConnected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.name), priority \(rank), \(state.title)\(isPinned ? ", pinned" : "")")
        .accessibilityAction(named: "Increase priority") {
            model.moveRule(direction: rule.direction, id: rule.id, offset: -1)
        }
        .accessibilityAction(named: "Decrease priority") {
            model.moveRule(direction: rule.direction, id: rule.id, offset: 1)
        }
        .accessibilityAction(named: "Move to top") {
            model.moveRule(direction: rule.direction, id: rule.id, to: .first)
        }
        .accessibilityAction(named: "Move to bottom") {
            model.moveRule(direction: rule.direction, id: rule.id, to: .last)
        }
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

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
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
