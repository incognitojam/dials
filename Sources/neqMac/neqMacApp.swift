import SwiftUI

@main
struct NeqMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            Label("neqMac", systemImage: model.policy.automationEnabled ? "waveform.badge.checkmark" : "waveform")
        }
        .menuBarExtraStyle(.window)

        Window("neqMac Routing", id: "routing") {
            SettingsView()
                .environmentObject(model)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 620)
        }
    }
}
