import Foundation

enum LocalLogsService {
    private static let claudeDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
    private static let claudeProjectsDir = claudeDir.appendingPathComponent("projects")
    private static let claudeTasksDir    = claudeDir.appendingPathComponent("tasks")

    // MARK: - Public API

    /// Sums token usage and estimated cost for the current calendar month from local JSONL logs.
    static func monthlyUsage() -> UsageData {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return UsageData() }

        var totalTokens = 0
        var totalCost = 0.0

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        for dir in projectDirs where dir.hasDirectoryPath {
            guard modDate(dir) > monthStart else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.pathExtension == "jsonl" }) else { continue }

            for file in files {
                guard modDate(file) > monthStart,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

                for line in text.components(separatedBy: "\n") {
                    guard !line.isEmpty,
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let tsStr = obj["timestamp"] as? String,
                          let ts = isoFull.date(from: tsStr) ?? isoBasic.date(from: tsStr),
                          ts >= monthStart,
                          let msg = obj["message"] as? [String: Any],
                          msg["role"] as? String == "assistant",
                          let usage = msg["usage"] as? [String: Any]
                    else { continue }

                    let model = msg["model"] as? String ?? ""
                    let input  = usage["input_tokens"] as? Int ?? 0
                    let output = usage["output_tokens"] as? Int ?? 0
                    let cWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cRead  = usage["cache_read_input_tokens"] as? Int ?? 0

                    totalTokens += input + output + cWrite + cRead
                    totalCost   += estimateCost(model: model, input: input, output: output,
                                                cacheWrite: cWrite, cacheRead: cRead)
                }
            }
        }

        var result = UsageData()
        result.tokensUsed  = totalTokens
        result.costUSD     = totalCost
        result.periodStart = monthStart
        result.lastFetched = now
        return result
    }

    /// Returns sessions whose JSONL was modified within `withinSeconds`, with the last user message as status.
    static func activeSessions(withinSeconds: TimeInterval = 300) -> [SessionInfo] {
        let cutoff = Date().addingTimeInterval(-withinSeconds)
        var sessions: [SessionInfo] = []

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.pathExtension == "jsonl" }) else { continue }

            for file in jsonlFiles {
                let lastActivity = modDate(file)
                guard lastActivity > cutoff else { continue }

                let sessionId = file.deletingPathExtension().lastPathComponent
                let projectPath = projectPathFromDir(dir)
                let processing = isProcessing(in: file)
                let status = processing ? lastUserMessage(in: file) : nil
                let tasks = processing ? readTasks(sessionId: sessionId) : []
                sessions.append(SessionInfo(
                    projectPath: projectPath,
                    lastActivity: lastActivity,
                    currentStatus: status,
                    inProgressTasks: tasks,
                    isProcessing: processing
                ))
            }
        }

        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Private helpers

    /// Reads task state directly from ~/.claude/tasks/{sessionId}/*.json
    private static func readTasks(sessionId: String) -> [TaskItem] {
        let dir = claudeTasksDir.appendingPathComponent(sessionId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }) else { return [] }

        return files.compactMap { file -> TaskItem? in
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let subject = obj["subject"] as? String,
                  let status = obj["status"] as? String,
                  status != "completed", status != "deleted"
            else { return nil }
            return TaskItem(id: id, subject: subject)
        }.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    /// Returns true if the last conversation turn in the file is a user message
    /// (meaning Claude hasn't responded yet and is actively processing).
    private static func isProcessing(in file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = obj["type"] as? String,
                  type_ == "user" || type_ == "assistant"
            else { continue }
            return type_ == "user"
        }
        return false
    }

    /// Reads the last user-typed message from a JSONL session file.
    private static func lastUserMessage(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  msg["role"] as? String == "user"
            else { continue }

            let content = msg["content"]
            if let text = content as? String, !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let blocks = content as? [[String: Any]] {
                for block in blocks {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String, !text.isEmpty {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return nil
    }

    /// Derives a display path from the project directory name (e.g. "-Users-jeff-dev-chirp" → "~/dev/chirp").
    private static func projectPathFromDir(_ dir: URL) -> String {
        let encoded = dir.lastPathComponent          // e.g. "-Users-jeff-dev-chirp"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Convert "-Users-jeff-dev-chirp" → "/Users/jeff/dev/chirp"
        let abs = "/" + encoded.replacingOccurrences(of: "-", with: "/").dropFirst()
        return abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Approximate cost in USD based on published per-million-token prices.
    private static func estimateCost(model: String, input: Int, output: Int,
                                     cacheWrite: Int, cacheRead: Int) -> Double {
        let (ip, op, cw, cr): (Double, Double, Double, Double)
        if model.contains("opus") {
            (ip, op, cw, cr) = (15.0, 75.0, 18.75, 1.50)
        } else if model.contains("haiku") {
            (ip, op, cw, cr) = (0.80,  4.0,  1.00, 0.08)
        } else {
            (ip, op, cw, cr) = (3.0,  15.0,  3.75, 0.30) // sonnet (default)
        }
        let M = 1_000_000.0
        return (Double(input) * ip + Double(output) * op +
                Double(cacheWrite) * cw + Double(cacheRead) * cr) / M
    }
}
