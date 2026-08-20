import AppKit
import Combine
import ServiceManagement

/// Registers the running app with macOS so it starts at login.
///
/// `SMAppService.mainApp` registers the bundle by its path, so an app that is
/// moved after registering leaves a stale login item behind and no longer
/// starts. `refresh()` re-reads the real status rather than trusting a stored
/// flag, which keeps the toggle honest when that happens or when the item is
/// switched off in System Settings.
@MainActor
public final class LoginItem: ObservableObject {
    @Published public private(set) var status: SMAppService.Status
    /// Set when a register or unregister call fails, cleared on the next success.
    @Published public private(set) var lastError: String?

    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
        self.status = service.status
    }

    public var isEnabled: Bool { status == .enabled }

    /// macOS 13 and later can hold a registration until the user approves it in
    /// System Settings, in which case the app is registered but will not launch.
    public var needsApproval: Bool { status == .requiresApproval }

    public var explanation: String { LoginItem.explanation(for: status) }

    public func refresh() {
        status = service.status
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                // Registering an already-registered app throws rather than being
                // a no-op, and the state we want is already true.
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    public func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Kept separate from the service so the wording can be tested directly.
    public nonisolated static func explanation(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            "Starts automatically when you log in."
        case .requiresApproval:
            "Waiting for approval in System Settings › General › Login Items."
        case .notRegistered:
            "Not set to start at login."
        case .notFound:
            "macOS cannot find this app where it was registered. Move it to its final location and turn this on again."
        @unknown default:
            "Login status unavailable."
        }
    }
}
