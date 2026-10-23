import SwiftUI

struct DeviceRulesSection: View {
    @EnvironmentObject private var model: AppModel
    let direction: DeviceDirection

    /// Stands in for the Never use divider among the row IDs, so dragging can
    /// treat it like any other item and a drop on either side of it decides
    /// whether a device is allowed.
    private static let dividerID = "never-use"

    private var rules: [DeviceRule] { model.rules(for: direction) }
    private var allowedRules: [DeviceRule] { rules.filter { !$0.isExcluded } }
    private var excludedRules: [DeviceRule] { rules.filter(\.isExcluded) }
    private var items: [String] { allowedRules.map(\.id) + [Self.dividerID] + excludedRules.map(\.id) }
    private var tint: Color { RouteStyle.tint(for: direction) }

    private var overrideUID: String? {
        model.manualOverrideUID(for: direction)
    }

    /// Index of the allowed row where the signal chain stops.
    private var activeIndex: Int? {
        allowedRules.firstIndex { model.isCurrent($0) }
    }

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var draggingID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var itemFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allowedConnectedCount: Int {
        allowedRules.filter { model.device(for: $0) != nil }.count
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

                if isEditing {
                    editActions
                }

                if !rules.isEmpty {
                    Button(isEditing ? "Done" : "Edit") {
                        isEditing.toggle()
                        selectedIDs = []
                    }
                    .controlSize(.small)
                    .keyboardShortcut(isEditing ? .defaultAction : nil)
                    .help(isEditing ? "Finish editing." : "Select \(direction.rawValue) devices to exclude or remove.")
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
                    ForEach(Array(items.enumerated()), id: \.element) { index, id in
                        let isDragging = draggingID == id

                        Group {
                            if id == Self.dividerID {
                                NeverUseDivider(direction: direction, isEmpty: excludedRules.isEmpty)
                            } else if let rule = rules.first(where: { $0.id == id }) {
                                VStack(spacing: 0) {
                                    if index > 0, items[index - 1] != Self.dividerID {
                                        Divider()
                                            .padding(.leading, RouteStyle.railWidth + 24)
                                            .opacity(isDragging ? 0 : 1)
                                    }
                                    row(for: rule, isDragging: isDragging)
                                }
                                .gesture(reorderGesture(for: rule), including: isEditing ? .subviews : .all)
                            }
                        }
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: RowFramesKey.self,
                                    value: [id: geometry.frame(in: .named(coordinateSpace))]
                                )
                            }
                        }
                        .offset(y: offset(at: index))
                        .animation(isDragging || reduceMotion ? nil : .snappy(duration: 0.15), value: dropIndex)
                        .zIndex(isDragging ? 1 : 0)
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
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(RowFramesKey.self) { frames in
                if draggingID == nil { itemFrames = frames }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func row(for rule: DeviceRule, isDragging: Bool) -> some View {
        let group = rule.isExcluded ? excludedRules : allowedRules
        let groupIndex = group.firstIndex { $0.id == rule.id } ?? 0

        return DeviceRuleRow(
            rule: rule,
            rank: groupIndex + 1,
            isFirst: groupIndex == 0,
            isLast: groupIndex == group.count - 1,
            isLiveAbove: !rule.isExcluded && (activeIndex.map { groupIndex <= $0 } ?? false),
            isLiveBelow: !rule.isExcluded && (activeIndex.map { groupIndex < $0 } ?? false),
            isPinned: overrideUID == rule.uid,
            isDragging: isDragging,
            isEditing: isEditing,
            isSelected: Binding(
                get: { selectedIDs.contains(rule.id) },
                set: { selected in
                    if selected { selectedIDs.insert(rule.id) } else { selectedIDs.remove(rule.id) }
                }
            ),
            tint: tint,
            move: { move(rule.id, $0) },
            setExcluded: { setExcluded([rule.id], $0) }
        )
    }

    // MARK: Arranging

    private func move(_ id: String, _ move: RowMove) {
        var allowed = allowedRules.map(\.id)
        guard let index = allowed.firstIndex(of: id) else { return }
        let destination = switch move {
        case .top: 0
        case .up: max(index - 1, 0)
        case .down: min(index + 1, allowed.count - 1)
        case .bottom: allowed.count - 1
        }
        allowed.remove(at: index)
        allowed.insert(id, at: destination)
        model.arrange(direction: direction, allowed: allowed, excluded: excludedRules.map(\.id))
    }

    /// Newly excluded devices go to the top of Never use and newly allowed ones
    /// to the bottom of the priority order, so they land next to the divider.
    private func setExcluded(_ ids: Set<String>, _ excluded: Bool) {
        let allowed = allowedRules.map(\.id).filter { !ids.contains($0) }
        let excludedIDs = excludedRules.map(\.id).filter { !ids.contains($0) }
        let moving = rules.map(\.id).filter { ids.contains($0) }
        model.arrange(
            direction: direction,
            allowed: excluded ? allowed : allowed + moving,
            excluded: excluded ? moving + excludedIDs : excludedIDs
        )
    }

    // MARK: Editing

    private var disconnectedIDs: Set<String> {
        Set(rules.filter { model.device(for: $0) == nil }.map(\.id))
    }

    @ViewBuilder
    private var editActions: some View {
        let removable = selectedIDs.intersection(disconnectedIDs)
        let selectedAllowed = selectedIDs.intersection(allowedRules.map(\.id))

        Button("Select Disconnected") { selectedIDs = disconnectedIDs }
            .controlSize(.small)
            .disabled(disconnectedIDs.isEmpty || selectedIDs == disconnectedIDs)

        Button(selectedIDs.isEmpty || !selectedAllowed.isEmpty ? "Never Use" : "Allow") {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                setExcluded(selectedIDs, !selectedAllowed.isEmpty)
            }
            selectedIDs = []
        }
        .controlSize(.small)
        .disabled(selectedIDs.isEmpty)
        .help(selectedAllowed.isEmpty
              ? "Let neqMac select the chosen devices again."
              : "Move the chosen devices below Never use.")

        Button(removable.isEmpty ? "Remove" : "Remove \(removable.count)", role: .destructive) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                model.removeRules(direction: direction, ids: removable)
            }
            selectedIDs = []
            if model.rules(for: direction).isEmpty { isEditing = false }
        }
        .controlSize(.small)
        .disabled(removable.isEmpty)
        .help("Remove the chosen disconnected devices. A removed device is added back if it reconnects.")
    }

    // MARK: Drag to reorder

    private var coordinateSpace: String { "rules-\(direction.rawValue)" }

    private var draggedFrame: CGRect? { draggingID.flatMap { itemFrames[$0] } }

    private var sourceIndex: Int? { items.firstIndex { $0 == draggingID } }

    private var clampedTranslation: CGFloat {
        guard let draggedFrame,
              let top = items.first.flatMap({ itemFrames[$0] }),
              let bottom = items.last.flatMap({ itemFrames[$0] }) else { return 0 }
        return min(max(dragTranslation, top.minY - draggedFrame.minY), bottom.maxY - draggedFrame.maxY)
    }

    /// Items above the source stay above until the dragged row's top edge
    /// passes their middle; items below move up once its bottom edge does.
    private var dropIndex: Int? {
        guard let draggedFrame, let sourceIndex else { return nil }
        let top = draggedFrame.minY + clampedTranslation
        let bottom = draggedFrame.maxY + clampedTranslation
        return items.enumerated().filter { index, id in
            guard index != sourceIndex, let frame = itemFrames[id] else { return false }
            return frame.midY < (index < sourceIndex ? top : bottom)
        }.count
    }

    private func offset(at index: Int) -> CGFloat {
        guard let draggedFrame, let sourceIndex, let dropIndex else { return 0 }
        if index == sourceIndex { return clampedTranslation }
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
                var reordered = items
                if let sourceIndex, let dropIndex {
                    reordered.remove(at: sourceIndex)
                    reordered.insert(rule.id, at: dropIndex)
                }
                let divider = reordered.firstIndex(of: Self.dividerID) ?? reordered.count
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    model.arrange(
                        direction: direction,
                        allowed: Array(reordered[..<divider]),
                        excluded: Array(reordered[divider...].dropFirst())
                    )
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

private enum RowMove {
    case top, up, down, bottom
}

/// Separates the priority order from devices neqMac must never select.
private struct NeverUseDivider: View {
    let direction: DeviceDirection
    let isEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "nosign")
                    .font(.system(size: 9, weight: .bold))
                Text("NEVER USE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityAddTraits(.isHeader)

            if isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    private var hint: String {
        if direction == .input {
            return "Drag a microphone here so neqMac never selects it. Excluding a Bluetooth headset microphone keeps headphone audio at full quality."
        }
        return "Drag an output here so neqMac never selects it."
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
    let move: (RowMove) -> Void
    let setExcluded: (Bool) -> Void

    @State private var isHovering = false

    private var state: RouteSlotState {
        RouteSlotState(
            isConnected: model.device(for: rule) != nil,
            isCurrent: model.isCurrent(rule),
            isExcluded: rule.isExcluded
        )
    }

    private var canUseNow: Bool { state.isSelectable && !state.isCurrent }

    /// Rows already sit under the Never use divider, so the caption only needs
    /// to say whether the device is connected.
    private var detail: String? {
        if state.isCurrent { return nil }
        return state.isConnected ? "Connected" : "Not connected"
    }

    var body: some View {
        HStack(spacing: 12) {
            rail

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .fontWeight(state.isCurrent ? .semibold : .regular)
                    .foregroundStyle(state.isExcluded ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                HStack(spacing: 6) {
                    TransportText(transport: rule.displayTransport, detail: detail)
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
                Toggle("Select \(rule.name)", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.trailing, 6)
            } else {
                Button("Use Now") { model.useNow(rule) }
                    .controlSize(.small)
                    .fixedSize()
                    .opacity(isHovering && canUseNow ? 1 : 0)
                    .allowsHitTesting(isHovering && canUseNow)
                    .disabled(!canUseNow)
                    .help("Switch to \(rule.name) now and pin it until it disconnects.")
                    .accessibilityLabel("Use \(rule.name) now")

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDragging ? .secondary : .tertiary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
                    .help("Drag to change the priority of \(rule.name), or below Never use to exclude it.")
                    .accessibilityHidden(true)
            }
        }
        .padding(.trailing, 8)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            } else if isHovering, !isEditing {
                Color.primary.opacity(0.03)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if isEditing {
                isSelected.toggle()
            } else if canUseNow {
                model.useNow(rule)
            }
        })
        .contextMenu {
            Button("Use Now") { model.useNow(rule) }
                .disabled(!canUseNow)
            Divider()
            if !rule.isExcluded {
                Button("Move to Top") { move(.top) }.disabled(isFirst)
                Button("Move Up") { move(.up) }.disabled(isFirst)
                Button("Move Down") { move(.down) }.disabled(isLast)
                Button("Move to Bottom") { move(.bottom) }.disabled(isLast)
                Divider()
            }
            Button(rule.isExcluded ? "Allow" : "Never Use") { setExcluded(!rule.isExcluded) }
            Button("Remove from List", role: .destructive) {
                model.removeRules(direction: rule.direction, ids: [rule.id])
            }
            .disabled(state.isConnected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: rule.isExcluded ? "Allow" : "Never use") { setExcluded(!rule.isExcluded) }
        .accessibilityActions {
            if !rule.isExcluded {
                Button("Increase priority") { move(.up) }
                Button("Decrease priority") { move(.down) }
                Button("Move to top") { move(.top) }
                Button("Move to bottom") { move(.bottom) }
            }
        }
    }

    private var accessibilityLabel: String {
        let position = rule.isExcluded ? "never used" : "priority \(rank)"
        return "\(rule.name), \(position), \(state.title)\(isPinned ? ", pinned" : "")"
    }

    // MARK: The signal chain rail

    private var rail: some View {
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
