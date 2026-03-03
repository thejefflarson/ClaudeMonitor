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
        .transaction { $0.animation = nil }
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
                    let utcStyle = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).day()
                    Text("\(start.formatted(utcStyle)) – \(Date().formatted(utcStyle)) UTC")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }

                if !store.usage.dailyCosts.isEmpty {
                    DailySparkline(dailyCosts: store.usage.dailyCosts)
                        .padding(.top, 4)
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
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                }
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: 0) {
            ActionButton(label: "Open Anthropic Console", icon: "arrow.up.right.square") {
                NSWorkspace.shared.open(URL(string: "https://console.anthropic.com")!)
            }
            if #available(macOS 14.0, *) {
                SettingsLink {
                    ActionButtonContent(label: "Preferences…", icon: "gearshape")
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    ActionButtonContent(label: "Preferences…", icon: "gearshape")
                }
                .buttonStyle(.plain)
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

private struct SessionRow: View {
    let session: SessionInfo
    @State private var isHovered = false

    var body: some View {
        Button {
            Task.detached { ITerm2FocusService.focusSession(projectPath: session.projectPath) }
            // Dismiss the menu bar popover
            NSApp.keyWindow?.close()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(session.projectPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if session.isCompacting {
                        Text("Compacting…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .italic()
                    } else if session.isProcessing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    if session.sessionCost > 0 {
                        Text(String(format: "$%.2f", session.sessionCost))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(session.lastActivity.relativeShort)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                if let status = session.currentStatus, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(2)
                        .padding(.leading, 20)
                }

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
            .background(isHovered ? Color.primary.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct DailySparkline: View {
    let dailyCosts: [DailyCost]
    @State private var hoveredDay: Date?

    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let tipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")!
        return f
    }()

    private var captionText: String {
        guard let day = hoveredDay, let entry = dailyCosts.first(where: { $0.date == day }) else {
            return " " // non-empty to preserve line height
        }
        return "\(Self.tipFormatter.string(from: day)): $\(String(format: "%.2f", entry.cost))"
    }

    var body: some View {
        let maxCost = dailyCosts.map(\.cost).max() ?? 1
        let barMax = max(maxCost, 0.01)
        let today = Self.utcCal.startOfDay(for: Date())

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(dailyCosts) { entry in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(entry.date == today ? Color.accentColor :
                              entry.date == hoveredDay ? Color.secondary.opacity(0.55) :
                              Color.secondary.opacity(0.35))
                        .frame(height: max(1, CGFloat(entry.cost / barMax) * 32))
                        .onHover { inside in hoveredDay = inside ? entry.date : nil }
                }
            }
            .frame(height: 36, alignment: .bottom)

            Text(captionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .invisible(hoveredDay == nil)
        }
    }
}

private struct ActionButtonContent: View {
    let label: String
    let icon: String

    @State private var isHovered = false

    var body: some View {
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
        .onHover { isHovered = $0 }
    }
}

private struct ActionButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionButtonContent(label: label, icon: icon)
        }
        .buttonStyle(.plain)
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

    /// Hides visually but preserves layout space.
    func invisible(_ hidden: Bool) -> some View {
        self.opacity(hidden ? 0 : 1)
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
