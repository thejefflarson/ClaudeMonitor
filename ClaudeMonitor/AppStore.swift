import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var usage = UsageData()
    @Published var sessions: [SessionInfo] = []
    @Published var isLoadingUsage = true

    private var usageTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    private let socketListener = UnixSocketListener()

    /// Tracks the last time iTerm2 was focused per session, to debounce rapid re-fires.
    private var lastFocused: [String: Date] = [:]

    init() {
        UserDefaults.standard.register(defaults: ["iterm2FocusEnabled": true])
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
        usage = LocalLogsService.monthlyUsage()
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
        Task.detached { ITerm2FocusService.focusSession(projectPath: path) }
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
        guard UserDefaults.standard.bool(forKey: "iterm2FocusEnabled") else { return }
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

        guard UserDefaults.standard.bool(forKey: "iterm2FocusEnabled") else { return }
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
