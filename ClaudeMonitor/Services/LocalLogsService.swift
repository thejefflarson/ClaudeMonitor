import Foundation

enum LocalLogsService {
    private static let claudeProjectsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    // MARK: - Public API

    /// Returns sessions with JSONL files modified within the last `withinSeconds`.
    static func activeSessions(withinSeconds: TimeInterval = 120) -> [SessionInfo] {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [SessionInfo] = []
        let cutoff = Date().addingTimeInterval(-withinSeconds)

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.pathExtension == "jsonl" }) else { continue }

            // Find files modified recently
            let recent = jsonlFiles.filter { url in
                let mod = modDate(url)
                return mod > cutoff
            }
            guard let latest = recent.max(by: { modDate($0) < modDate($1) }) else { continue }

            let projectPath = (try? readProjectPath(from: latest)) ?? dir.lastPathComponent
            let tasks = (try? parseInProgressTasks(from: latest)) ?? []

            sessions.append(SessionInfo(
                projectPath: projectPath,
                lastActivity: modDate(latest),
                inProgressTasks: tasks
            ))
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Reads the `cwd` field from the first line of a JSONL session file
    /// and converts it to a ~/... relative path.
    static func readProjectPath(from url: URL) throws -> String {
        let firstLine = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .first(where: { !$0.isEmpty }) ?? ""
        guard let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = json["cwd"] as? String else { return url.lastPathComponent }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// Parses a JSONL session file and returns tasks currently in_progress.
    /// Strategy:
    ///   1. Collect TaskCreate tool_use entries (tool_use_id → subject)
    ///   2. Match tool results to assign sequential IDs ("Task #N created successfully")
    ///   3. Track TaskUpdate status changes
    ///   4. Return tasks whose final status is "in_progress"
    static func parseInProgressTasks(from url: URL) throws -> [TaskItem] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        // toolUseId → subject (pending assignment of numeric ID)
        var pendingCreates: [String: String] = [:]
        // numeric task ID → subject
        var subjects: [String: String] = [:]
        // numeric task ID → latest status
        var statuses: [String: String] = [:]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = json["message"] as? [String: Any],
                  let contentArr = msg["content"] as? [[String: Any]] else { continue }

            for item in contentArr {
                let itemType = item["type"] as? String

                if itemType == "tool_use",
                   let name = item["name"] as? String,
                   let toolId = item["id"] as? String,
                   let input = item["input"] as? [String: Any] {

                    if name == "TaskCreate", let subject = input["subject"] as? String {
                        pendingCreates[toolId] = subject
                    } else if name == "TaskUpdate",
                              let taskId = input["taskId"] as? String,
                              let status = input["status"] as? String {
                        statuses[taskId] = status
                    }

                } else if itemType == "tool_result",
                          let toolId = item["tool_use_id"] as? String,
                          let subject = pendingCreates[toolId],
                          let content = item["content"] as? String,
                          let taskId = extractTaskId(from: content) {

                    subjects[taskId] = subject
                    statuses[taskId] = statuses[taskId] ?? "pending"
                    pendingCreates.removeValue(forKey: toolId)
                }
            }
        }

        return subjects.compactMap { (id, subject) in
            guard statuses[id] == "in_progress" else { return nil }
            return TaskItem(id: id, subject: subject)
        }.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    // MARK: - Private helpers

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Extracts task ID from "Task #3 created successfully: subject"
    private static func extractTaskId(from content: String) -> String? {
        guard content.hasPrefix("Task #"),
              let spaceIdx = content.firstIndex(of: " ", after: content.index(content.startIndex, offsetBy: 5)) else {
            return nil
        }
        let idPart = content[content.index(content.startIndex, offsetBy: 6)..<spaceIdx]
        return String(idPart)
    }
}

private extension String {
    func firstIndex(of char: Character, after start: String.Index) -> String.Index? {
        var idx = start
        while idx < endIndex {
            if self[idx] == char { return idx }
            formIndex(after: &idx)
        }
        return nil
    }
}
