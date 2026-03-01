import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var usage = UsageData()
    @Published var sessions: [SessionInfo] = []
    @Published var isLoadingUsage = true

    private var usageTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?

    init() {
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
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshUsage() async {
        usage = LocalLogsService.monthlyUsage()
        isLoadingUsage = false
    }

    private func refreshSessions() async {
        sessions = LocalLogsService.activeSessions(withinSeconds: 1800)
    }
}
