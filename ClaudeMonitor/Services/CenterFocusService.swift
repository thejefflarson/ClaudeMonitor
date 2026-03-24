import AppKit

enum CenterFocusService {
    /// Returns the 1-based AppleScript window index of the visible window owned by
    /// `appName` whose center is closest to the center of the main screen.
    /// Uses CGWindowListCopyWindowInfo — no special entitlements required.
    static func centerWindowIndex(for appName: String) -> Int? {
        guard let screen = NSScreen.main else { return nil }

        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        // CGWindowList: Quartz coords, origin = top-left of main screen, Y increases down.
        // NSScreen: Cocoa coords, origin = bottom-left, Y increases up.
        let screenCX = Double(screen.frame.midX)
        let screenCY = Double(screen.frame.height) - Double(screen.frame.midY)

        // Windows are returned front-to-back; count per-app to get AppleScript window index.
        var appIdx = 0
        var best: (dist: Double, idx: Int)?

        for win in list {
            guard (win[kCGWindowOwnerName as String] as? String) == appName,
                  (win[kCGWindowLayer as String] as? Int32) == 0 else { continue }
            appIdx += 1

            guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 0, h > 0 else { continue }

            let cx = Double(x) + Double(w) / 2
            let cy = Double(y) + Double(h) / 2
            let dist = hypot(cx - screenCX, cy - screenCY)

            if best == nil || dist < best!.dist {
                best = (dist: dist, idx: appIdx)
            }
        }

        return best?.idx
    }

    /// Brings the iTerm2 window closest to screen center to the front and
    /// returns its current session path (for Mosaic to navigate to).
    @discardableResult
    static func focusCenterITerm2() -> String? {
        guard let idx = centerWindowIndex(for: "iTerm2") else { return nil }

        let script = """
        tell application "iTerm2"
            activate
            tell window \(idx)
                select
                set p to ""
                try
                    tell current session of current tab
                        set p to variable named "session.path"
                    end tell
                end try
                return p
            end tell
        end tell
        """
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
}
