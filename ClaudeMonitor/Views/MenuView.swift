import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageSection
            Divider().padding(.horizontal, 12)
            sessionsSection
            Divider().padding(.horizontal, 12)
            actionsSection
        }
        .frame(width: 320)
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("This Month", systemImage: "chart.bar.fill")
                .sectionHeaderStyle()

            if store.isLoadingUsage {
                Text("Calculating…")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "$%.2f", store.usage.costUSD))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("· \(formatTokens(store.usage.tokensUsed)) tokens")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let start = store.usage.periodStart {
                    Text("\(start.formatted(.dateTime.month(.wide).day())) – \(Date().formatted(.dateTime.month(.wide).day()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Active Sessions", systemImage: "terminal.fill")
                .sectionHeaderStyle()
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if store.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                ForEach(Array(store.sessions.enumerated()), id: \.offset) { _, session in
                    sessionRow(session)
                }
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Session header: project name + time
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(session.projectPath.components(separatedBy: "/").last ?? session.projectPath)
                    .lineLimit(1)
                Spacer()
                Text(session.lastActivity.relativeShort)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            // Current status (last user message)
            if let status = session.currentStatus, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
                    .padding(.leading, 20)
            }

            // In-progress tasks as sub-items
            ForEach(session.inProgressTasks, id: \.id) { task in
                HStack(spacing: 4) {
                    Text("↳")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(task.subject)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: 0) {
            ActionButton(label: "Open Anthropic Console", icon: "arrow.up.right.square") {
                NSWorkspace.shared.open(URL(string: "https://console.anthropic.com")!)
            }
            Divider().padding(.horizontal, 12)
            ActionButton(label: "Quit Claude Monitor", icon: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Components

private struct ActionButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(label)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isHovered ? Color.primary.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Extensions

private extension View {
    func sectionHeaderStyle() -> some View {
        self
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }
}

private extension Date {
    var relativeShort: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
