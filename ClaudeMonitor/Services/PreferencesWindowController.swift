import AppKit
import SwiftUI

enum PreferencesWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: PreferencesView())
            hosting.sizingOptions = .preferredContentSize
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Preferences"
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: w,
                queue: .main
            ) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
