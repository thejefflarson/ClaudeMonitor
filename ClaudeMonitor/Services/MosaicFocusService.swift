import Foundation

enum MosaicFocusService {
    static func focusSession(projectPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let absPath = projectPath.hasPrefix("~")
            ? home + projectPath.dropFirst()
            : projectPath

        // Guard against AppleScript injection: newlines break out of the string literal. (injection)
        guard !absPath.contains("\n"), !absPath.contains("\r") else { return }
        let escapedPath = absPath.replacingOccurrences(of: "\"", with: "\" & quote & \"")
        let script = """
        tell application "Mosaic"
            navigate to "\(escapedPath)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
