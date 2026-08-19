import SwiftUI

@main
struct NitMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            Label("nitMac", systemImage: model.isReady ? "sun.max" : "sun.max.trianglebadge.exclamationmark")
        }
        .menuBarExtraStyle(.window)
    }
}
