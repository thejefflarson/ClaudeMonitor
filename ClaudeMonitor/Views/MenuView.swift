import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: AppStore
    @State private var showPreferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageSection
            Divider()
            sessionsSection
            Divider()
            tasksSection
            Divider()
            actionsSection
        }
        .frame(minWidth: 300)
        .sheet(isPresented: $showPreferences) {
            PreferencesView().environmentObject(store)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var usageSection: some View {
        SectionHeader("This Month")
        if store.apiKey == nil {
            Button("Add Admin API Key…") { showPreferences = true }
                .menuRowStyle()
        } else if store.usageError {
            Text("Usage unavailable").menuRowStyle().foregroundStyle(.secondary)
        } else {
            Text(usageSummary).menuRowStyle()
            if let start = store.usage.periodStart {
                Text("Period: \(start.formatted(.dateTime.month().day())) – \(Date().formatted(.dateTime.month().day()))")
                    .font(.caption).foregroundStyle(.secondary).menuRowStyle()
            }
        }
        Spacer().frame(height: 6)
    }

    private var usageSummary: String {
        let cost = String(format: "$%.2f used", store.usage.costUSD)
        let tokens = formatTokens(store.usage.tokensUsed)
        return "\(cost) · \(tokens) tokens"
    }

    @ViewBuilder
    private var sessionsSection: some View {
        SectionHeader("Active Sessions (\(store.sessions.count))")
        if store.sessions.isEmpty {
            Text("No active sessions").menuRowStyle().foregroundStyle(.secondary)
        } else {
            ForEach(store.sessions, id: \.projectPath) { session in
                HStack {
                    Text(session.projectPath).lineLimit(1)
                    Spacer()
                    Text(session.lastActivity.relativeShort)
                        .font(.caption).foregroundStyle(.secondary)
                }.menuRowStyle()
            }
        }
        Spacer().frame(height: 6)
    }

    @ViewBuilder
    private var tasksSection: some View {
        let all: [(proj: String, task: TaskItem)] = store.sessions.flatMap { s in
            let short = s.projectPath.components(separatedBy: "/").last ?? s.projectPath
            return s.inProgressTasks.map { (short, $0) }
        }
        SectionHeader("In-Progress Tasks (\(all.count))")
        if all.isEmpty {
            Text("No tasks in progress").menuRowStyle().foregroundStyle(.secondary)
        } else {
            ForEach(all, id: \.task.id) { item in
                HStack(alignment: .top) {
                    Text("[\(item.proj)]")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(item.task.subject).lineLimit(1)
                }.menuRowStyle()
            }
        }
        Spacer().frame(height: 6)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Button("Open Anthropic Console ↗") {
            NSWorkspace.shared.open(URL(string: "https://console.anthropic.com")!)
        }.menuRowStyle()
        Button("Preferences…") { showPreferences = true }.menuRowStyle()
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.menuRowStyle()
        Spacer().frame(height: 4)
    }

    // MARK: - Helpers

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Small reusable components

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.headline).menuRowStyle().padding(.top, 6)
    }
}

private extension View {
    func menuRowStyle() -> some View {
        self.padding(.horizontal, 12).padding(.vertical, 2)
    }
}

private extension Date {
    var relativeShort: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h ago"
    }
}
