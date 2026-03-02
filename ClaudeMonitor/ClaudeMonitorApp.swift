import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Text(store.trayLabel)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
        }
    }
}
