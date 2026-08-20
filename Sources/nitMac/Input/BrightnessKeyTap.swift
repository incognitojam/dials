import AppKit
import CoreGraphics

/// Intercepts the physical brightness keys so they drive DDC instead of macOS's
/// own brightness control.
///
/// The keys arrive as `NX_SYSDEFINED` events rather than ordinary key presses, so
/// this needs a session event tap and the Accessibility permission. A handled key
/// is swallowed; otherwise the event is passed through untouched, which keeps the
/// built-in display working normally when there is no DDC monitor to talk to.
final class BrightnessKeyTap {
    typealias Handler = @MainActor (BrightnessDirection, NSEvent.ModifierFlags) -> Bool

    var handler: Handler?

    var isRunning: Bool { tap != nil }

    /// The system disables a tap whose callback was too slow to answer, and the
    /// event that trips it is swallowed. Recovering only from the disable
    /// callback means a tap can stay dead, so its state is also polled.
    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let systemDefinedType = CGEventType(rawValue: 14)!  // NX_SYSDEFINED
    private static let systemDefinedSubtype: Int16 = 8
    private static let brightnessUp = 2                                // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown = 3                              // NX_KEYTYPE_BRIGHTNESS_DOWN

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// A key-up is only swallowed when its key-down was, so macOS never observes
    /// half a key press.
    private var swallowedKeyCodes: Set<Int> = []

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << Self.systemDefinedType.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        swallowedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // A tap that is slow to answer, or that the user disabled, is switched
        // off by the system and has to be re-armed rather than recreated.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard type == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == Self.systemDefinedSubtype
        else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let keyFlags = nsEvent.data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        let direction: BrightnessDirection
        switch keyCode {
        case Self.brightnessUp: direction = .up
        case Self.brightnessDown: direction = .down
        default: return Unmanaged.passUnretained(event)
        }

        guard isKeyDown else {
            return swallowedKeyCodes.remove(keyCode) != nil ? nil : Unmanaged.passUnretained(event)
        }

        // The tap is serviced on the main run loop, so the handler is already
        // where it needs to be.
        let handled = MainActor.assumeIsolated {
            handler?(direction, nsEvent.modifierFlags) ?? false
        }
        guard handled else { return Unmanaged.passUnretained(event) }

        swallowedKeyCodes.insert(keyCode)
        return nil
    }
}
