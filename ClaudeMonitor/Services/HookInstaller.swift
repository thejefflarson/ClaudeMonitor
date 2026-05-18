import Foundation

/// Installs the ClaudeMonitorHook binary and registers it as a Claude Code Stop hook.
/// Idempotent — safe to call on every launch.
enum HookInstaller {
    /// Where we install the hook helper on the user's system.
    static var helperPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/monitor/notify"
    }

    static func installIfNeeded() {
        copyHelperBinary()
        let candidates = claudeSettingsPaths()
        for url in candidates { installHook(in: url) }
    }

    // MARK: - Private

    private static func copyHelperBinary() {
        let bundleURL = Bundle.main.bundleURL.standardized
        let src = bundleURL.appendingPathComponent("Contents/MacOS/ClaudeMonitorHook").standardized
        // Verify the resolved source path is inside the app bundle to prevent
        // symlink-based path traversal outside the bundle. (insecure-design, integrity-failures)
        guard src.path.hasPrefix(bundleURL.path + "/") else { return }
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = URL(fileURLWithPath: helperPath)
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
    }

    private static func claudeSettingsPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/settings.json"),
                home.appendingPathComponent(".config/claude/settings.json")]
            .filter { isExistingDir($0.deletingLastPathComponent()) }
    }

    private static func installHook(in url: URL) {
        var settings: [String: Any] = [:]
        // File-size guard: reject implausibly large settings files before parsing. (insecure-design)
        if let data = try? Data(contentsOf: url),
           data.count < 10 * 1_048_576,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Install our binary for Stop, PreCompact, and Notification events.
        for eventName in ["Stop", "PreCompact", "Notification"] {
            var groups = hooks[eventName] as? [[String: Any]] ?? []

            // Remove any previous hook from us (old shell-script style or binary style).
            let ours: (String) -> Bool = { cmd in
                cmd.contains(UnixSocketListener.socketPath) || cmd.contains("/.claude/monitor/notify")
            }
            groups = groups.compactMap { group -> [String: Any]? in
                guard var hs = group["hooks"] as? [[String: Any]] else { return group }
                hs = hs.filter { !ours($0["command"] as? String ?? "") }
                if hs.isEmpty { return nil }
                var g = group; g["hooks"] = hs; return g
            }

            let alreadyPresent = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? [])
                    .contains { $0["command"] as? String == helperPath }
            }
            if !alreadyPresent {
                groups.append(["hooks": [["type": "command", "command": helperPath]]])
            }
            hooks[eventName] = groups
        }

        settings["hooks"] = hooks
        save(settings, to: url)
    }

    private static func save(_ settings: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        // .atomic writes to a temp file then renames, so a crash mid-write cannot
        // leave settings.json empty or partially written. (race-condition)
        try? data.write(to: url, options: .atomic)
    }

    private static func isExistingDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
