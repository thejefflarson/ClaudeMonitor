import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var usage = UsageData()
    @Published var sessions: [SessionInfo] = []
    @Published var isLoadingUsage = true
    @Published var updateAvailable: URL? = nil
    /// Path of the most recently focused terminal — drives the minimap highlight.
    @Published var focusedPath: String? = nil

    private var usageTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    private let socketListener = UnixSocketListener()

    /// Tracks the last time iTerm2 was focused per session, to debounce rapid re-fires.
    private var lastFocused: [String: Date] = [:]

    init() {
        UserDefaults.standard.register(defaults: ["terminalFocusApp": "iTerm2"])
        HookInstaller.installIfNeeded()

        socketListener.onStop = { [weak self] event in
            self?.handleStopEvent(event)
        }
        socketListener.onCompact = { [weak self] (event: CompactEvent) in
            self?.handleCompactEvent(event)
        }
        socketListener.onNotification = { [weak self] event in
            self?.handleNotificationEvent(event)
        }
        socketListener.start()

        startPolling()
        Task { updateAvailable = await UpdateService.checkForUpdate() }
    }

    var trayLabel: String {
        guard !isLoadingUsage else { return "$…" }
        let stale = usage.lastFetched.map { Date().timeIntervalSince($0) > 900 } ?? false
        let fmt = String(format: "$%.2f", usage.costUSD)
        return stale ? "⚠ \(fmt)" : fmt
    }

    // MARK: - Private

    private func startPolling() {
        usageTask?.cancel()
        logsTask?.cancel()

        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUsage()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        logsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSessions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshUsage() async {
        let result = await Task.detached(priority: .utility) {
            LocalLogsService.monthlyUsage()
        }.value
        usage = result
        isLoadingUsage = false
    }

    private func refreshSessions() async {
        var result = await Task.detached(priority: .utility) {
            LocalLogsService.activeSessions()
        }.value
        // Preserve isCompacting — it's set by socket event, not derived from JSONL.
        // But if Claude is actively processing, compaction is done — clear it.
        for i in result.indices {
            if let prev = sessions.first(where: { $0.id == result[i].id }),
               prev.isCompacting, !result[i].isProcessing {
                result[i].isCompacting = true
            }
        }
        sessions = result
    }

    private func maybeFireFocus(for sessionId: String, path: String) {
        let now = Date()
        if let last = lastFocused[sessionId], now.timeIntervalSince(last) < 5 { return }
        lastFocused[sessionId] = now
        let app = UserDefaults.standard.string(forKey: "terminalFocusApp") ?? "iTerm2"
        let followsCenter = UserDefaults.standard.bool(forKey: "focusFollowsCenter")

        switch app {
        case "iTerm2":
            if followsCenter {
                Task.detached { [weak self] in
                    let focused = CenterFocusService.focusCenterITerm2()
                    let p = focused ?? path
                    let s = self
                    await MainActor.run { s?.focusedPath = p }
                }
            } else {
                focusedPath = path
                Task.detached { ITerm2FocusService.focusSession(projectPath: path) }
            }
        case "Mosaic":
            if followsCenter {
                Task.detached { [weak self] in
                    // Focus center iTerm2 window, get its path, then navigate Mosaic there.
                    let centerPath = CenterFocusService.focusCenterITerm2() ?? path
                    MosaicFocusService.focusSession(projectPath: centerPath)
                    let s = self
                    await MainActor.run { s?.focusedPath = centerPath }
                }
            } else {
                focusedPath = path
                Task.detached { MosaicFocusService.focusSession(projectPath: path) }
            }
        default: break
        }
    }

    /// Called when the user manually clicks a session row — updates the minimap highlight.
    func userFocused(path: String) {
        focusedPath = path
    }

    /// Called immediately when a PreCompact hook fires — Claude is about to compact context.
    private func handleCompactEvent(_ event: CompactEvent) {
        if let idx = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            sessions[idx].isCompacting = true
            sessions[idx].isProcessing = false
            sessions[idx].currentStatus = nil
        }
    }

    /// Called when a Notification hook fires — covers permission_prompt and idle_prompt.
    private func handleNotificationEvent(_ event: NotificationEvent) {
        guard (UserDefaults.standard.string(forKey: "terminalFocusApp") ?? "iTerm2") != "disabled" else { return }
        guard event.notificationType == "permission_prompt" || event.notificationType == "idle_prompt"
        else { return }
        let session = sessions.first { $0.id == event.sessionId }
        guard let session else { return }
        maybeFireFocus(for: session.id, path: session.projectPath)
    }

    /// Called immediately when a Stop hook fires via Unix socket.
    private func handleStopEvent(_ event: StopEvent) {
        // Clear spinner, compacting flag, and status on the matched session right away.
        if let idx = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            sessions[idx].isProcessing = false
            sessions[idx].isCompacting = false
            sessions[idx].currentStatus = nil
        }

        guard (UserDefaults.standard.string(forKey: "terminalFocusApp") ?? "iTerm2") != "disabled" else { return }
        let session = sessions.first { $0.id == event.sessionId }
            ?? sessions.first { $0.projectPath == event.cwd.map(projectPathFromCwd) }
        guard let session else { return }
        maybeFireFocus(for: session.id, path: session.projectPath)
    }

    private func projectPathFromCwd(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}
