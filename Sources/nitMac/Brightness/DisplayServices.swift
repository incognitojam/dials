import CoreGraphics
import Foundation

/// The private framework macOS drives display brightness with.
///
/// It is worth preferring over raw DDC wherever it answers: it addresses a
/// display by `CGDirectDisplayID` rather than by guessing which I2C bus belongs
/// to which screen, it reads back reliably, and it is the same channel the system
/// brightness slider uses, so nitMac and System Settings never disagree.
enum DisplayServices {
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )
    private static let canChange: CanChange? = symbol("DisplayServicesCanChangeBrightness")
    private static let getBrightness: GetBrightness? = symbol("DisplayServicesGetBrightness")
    private static let setBrightness: SetBrightness? = symbol("DisplayServicesSetBrightness")

    static func canChangeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        guard let canChange, getBrightness != nil, setBrightness != nil else { return false }
        return canChange(displayID)
    }

    static func brightness(of displayID: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        return setBrightness(displayID, min(1, max(0, value))) == 0
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
