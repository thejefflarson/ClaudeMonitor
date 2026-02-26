import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var usage = UsageData()
    @Published var sessions: [SessionInfo] = []
    @Published var apiKey: String?
    @Published var isLoadingUsage = true
    @Published var usageError = false

    private var usageTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?

    init() {
        apiKey = KeychainHelper.load(key: "anthropic-admin-key")
        startPolling()
    }

    func saveApiKey(_ key: String) {
        KeychainHelper.save(key: "anthropic-admin-key", value: key)
        apiKey = key
        startPolling()
    }

    var trayLabel: String {
        guard !isLoadingUsage else { return "$…" }
        guard !usageError, apiKey != nil else { return "$—" }
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
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refreshUsage() async {
        guard let key = apiKey else { isLoadingUsage = false; return }
        do {
            usage = try await AnthropicService.fetchUsage(apiKey: key)
            usageError = false
        } catch {
            usageError = true
        }
        isLoadingUsage = false
    }

    private func refreshSessions() async {
        sessions = LocalLogsService.activeSessions()
    }
}
