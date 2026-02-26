import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra(store.trayLabel, systemImage: "cpu") {
            MenuView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}
