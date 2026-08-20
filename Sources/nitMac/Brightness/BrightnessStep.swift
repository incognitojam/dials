import Foundation

enum BrightnessDirection {
    case up
    case down
}

/// Brightness moves in the sixteen steps macOS uses for its own, spread evenly
/// across the range so that both ends are stops rather than an awkward remainder.
///
/// A press finds the next stop past wherever the display actually sits, so a value
/// set from System Settings or another app is joined rather than jumped from.
enum BrightnessStep {
    static let divisions = 16

    static let stops: [Int] = (0...divisions).map {
        Int((Double($0) * 100 / Double(divisions)).rounded())
    }

    static func next(percent: Int, direction: BrightnessDirection, fine: Bool) -> Int {
        let value = clamp(percent)

        // Shift-option is the same fine-adjustment gesture macOS uses for its own
        // brightness and volume keys.
        guard !fine else {
            return clamp(value + (direction == .up ? 1 : -1))
        }

        switch direction {
        case .up: return stops.first { $0 > value } ?? 100
        case .down: return stops.last { $0 < value } ?? 0
        }
    }

    private static func clamp(_ percent: Int) -> Int {
        min(100, max(0, percent))
    }
}
