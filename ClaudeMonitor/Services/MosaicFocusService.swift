import Foundation

enum MosaicFocusService {
    static func focusSession(projectPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let absPath = projectPath.hasPrefix("~")
            ? home + projectPath.dropFirst()
            : projectPath

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
