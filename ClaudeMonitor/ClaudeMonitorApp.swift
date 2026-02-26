import SwiftUI

@main
struct ClaudeMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("$—", systemImage: "cpu") {
            Text("Loading…").padding()
        }
    }
}
