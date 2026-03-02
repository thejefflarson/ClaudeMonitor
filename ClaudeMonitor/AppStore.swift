import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var usage = UsageData()
    @Published var sessions: [SessionInfo] = []
    @Published var isLoadingUsage = true

    private var usageTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    private let socketListener = UnixSocketListener()

    init() {
        UserDefaults.standard.register(defaults: ["iterm2FocusEnabled": true])
        HookInstaller.installIfNeeded()

        socketListener.onStop = { [weak self] event in
            self?.handleStopEvent(event)
        }
        socketListener.onCompact = { [weak self] (event: CompactEvent) in
            self?.handleCompactEvent(event)
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
        for i in result.indices {
            if let prev = sessions.first(where: { $0.id == result[i].id }), prev.isCompacting {
                result[i].isCompacting = true
            }
        }
        sessions = result
    }

    /// Called immediately when a PreCompact hook fires — Claude is about to compact context.
    private func handleCompactEvent(_ event: CompactEvent) {
        if let idx = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            sessions[idx].isCompacting = true
            sessions[idx].isProcessing = false
            sessions[idx].currentStatus = nil
        }
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
        guard let path = session?.projectPath else { return }
        Task.detached { ITerm2FocusService.focusSession(projectPath: path) }
    }

    private func projectPathFromCwd(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}
