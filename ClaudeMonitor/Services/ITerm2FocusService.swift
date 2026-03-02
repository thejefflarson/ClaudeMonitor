import Foundation

enum ITerm2FocusService {
    static func focusSession(projectPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let absPath = projectPath.hasPrefix("~")
            ? home + projectPath.dropFirst()
            : projectPath

        // Escape any `"` in the path using AppleScript's quote constant so the
        // string literal is never broken by a path containing a double-quote.
        let escapedPath = absPath.replacingOccurrences(of: "\"", with: "\" & quote & \"")
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set p to ""
                        try
                            tell s
                                set p to variable named "session.path"
                            end tell
                        end try
                        if p is "\(escapedPath)" then
                            tell s to select
                            tell w to select
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
