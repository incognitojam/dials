import AppKit
import CoreGraphics

/// One external display macOS is willing to control, addressed in whole percent.
///
/// Reads cost about 0.1 ms and a write lands in time to be read straight back, so
/// nothing here is cached or paced: the display itself is the source of truth.
final class BrightnessDisplay: Identifiable, Sendable {
    let id: String
    let name: String

    private let displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID, name: String) {
        self.id = "display-\(displayID)"
        self.name = name
        self.displayID = displayID
    }

    /// Every external display macOS will let nitMac drive. Built-in and AirPlay
    /// panels are left alone; so is any monitor DisplayServices declines, which in
    /// practice means one that only answers raw DDC/CI.
    @MainActor
    static func discover() -> [BrightnessDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(displayID) == 0,
                  DisplayServices.canChangeBrightness(displayID)
            else {
                return nil
            }
            return BrightnessDisplay(displayID: displayID, name: screen.localizedName)
        }
    }

    func percent() -> Int? {
        guard let value = DisplayServices.brightness(of: displayID) else { return nil }
        return Int((value * 100).rounded())
    }

    func setPercent(_ percent: Int) {
        let clamped = min(100, max(0, percent))
        DisplayServices.setBrightness(Float(clamped) / 100, for: displayID)
    }
}
