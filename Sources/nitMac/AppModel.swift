import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct DisplayState: Identifiable, Equatable {
        let id: String
        let name: String
        var percent: Int

        var fraction: Double { Double(percent) / 100 }
    }

    @Published private(set) var displays: [DisplayState] = []
    @Published private(set) var hasAccessibilityAccess = AXIsProcessTrusted()

    /// True once nitMac can do its one job: a display it can drive, and
    /// permission to hear the keys.
    var isReady: Bool { hasAccessibilityAccess && !displays.isEmpty }

    private static let rediscoveryDelay: Duration = .milliseconds(1500)
    private static let permissionPollInterval: TimeInterval = 2

    private let tap = BrightnessKeyTap()
    private let hud = BrightnessHUD()
    private var connections: [String: BrightnessDisplay] = [:]
    private var rediscoveryTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    init() {
        tap.handler = { [weak self] direction, modifiers in
            self?.adjust(direction: direction, modifiers: modifiers) ?? false
        }

        discover()
        startTap()
        observeScreenChanges()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Brightness

    /// Returns false when there is nothing to control, which lets the key tap
    /// hand the press back to macOS rather than swallowing it.
    @discardableResult
    func adjust(direction: BrightnessDirection, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !displays.isEmpty else { return false }

        let fine = modifiers.contains(.shift) && modifiers.contains(.option)

        for index in displays.indices {
            guard let display = connections[displays[index].id] else { continue }
            let current = display.percent() ?? displays[index].percent
            let next = BrightnessStep.next(percent: current, direction: direction, fine: fine)
            display.setPercent(next)
            displays[index].percent = next
        }

        if let leading = displays.first {
            // The system indicator titles itself with the device it is acting on,
            // which only makes sense here while one display is being moved.
            let title = displays.count == 1 ? leading.name : "Brightness"
            hud.show(fraction: leading.fraction, title: title, on: NSScreen.main)
        }
        return true
    }

    func setPercent(_ percent: Int, for id: String) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        connections[id]?.setPercent(percent)
        displays[index].percent = min(100, max(0, percent))
    }

    // MARK: - Displays

    func discover() {
        let found = BrightnessDisplay.discover()
        connections = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        displays = found.map {
            DisplayState(id: $0.id, name: $0.name, percent: $0.percent() ?? 100)
        }
    }

    /// Cheap enough to run whenever the panel is opened, which is the only time
    /// the stored value is looked at rather than read fresh.
    func refresh() {
        for index in displays.indices {
            guard let percent = connections[displays[index].id]?.percent() else { continue }
            displays[index].percent = percent
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRediscovery() }
        }
    }

    /// A display change arrives before the display pipeline has settled, and it
    /// usually arrives several times, so rediscovery waits for the flurry to end.
    private func scheduleRediscovery() {
        rediscoveryTask?.cancel()
        rediscoveryTask = Task { @MainActor in
            try? await Task.sleep(for: Self.rediscoveryDelay)
            guard !Task.isCancelled else { return }
            discover()
        }
    }

    // MARK: - Permission

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        pollForPermission()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startTap() {
        hasAccessibilityAccess = AXIsProcessTrusted()
        if tap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else {
            pollForPermission()
        }
    }

    /// Granting Accessibility does not notify the app, so the only way to pick the
    /// permission up without a relaunch is to keep asking.
    private func pollForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.tap.isRunning else { return }
                self.startTap()
            }
        }
    }
}
