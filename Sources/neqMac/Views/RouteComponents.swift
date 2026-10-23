import SwiftUI

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
