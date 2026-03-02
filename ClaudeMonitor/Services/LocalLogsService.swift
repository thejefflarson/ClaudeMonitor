import Foundation

enum LocalLogsService {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// All existing Claude config roots (~/.claude and/or ~/.config/claude).
    private static var claudeRoots: [URL] {
        [home.appendingPathComponent(".claude"),
         home.appendingPathComponent(".config/claude")]
            .filter { isDir($0) }
    }

    private static var projectsDirs: [URL] { claudeRoots.map { $0.appendingPathComponent("projects") }.filter { isDir($0) } }
    private static var tasksDirs:    [URL] { claudeRoots.map { $0.appendingPathComponent("tasks")    }.filter { isDir($0) } }

    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    // MARK: - Public API

    /// Sums token usage and estimated cost for the current calendar month from local JSONL logs.
    static func monthlyUsage() -> UsageData {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!

        var totalTokens = 0
        var totalCost = 0.0

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        let allProjectDirs = projectsDirs.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }

        for dir in allProjectDirs where dir.hasDirectoryPath {
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

    /// Returns one SessionInfo per running claude process, augmented with JSONL data.
    static func activeSessions() -> [SessionInfo] {
        // Build JSONL index: sessionId → (file, projectPath, lastActivity)
        // Also reverse-index: absProjectPath → [(sessionId, file, lastActivity)]
        var sessionFiles:  [String: (file: URL, projectPath: String, lastActivity: Date)] = [:]
        var cwdToSessions: [String: [(sessionId: String, file: URL, lastActivity: Date)]] = [:]

        let allProjectDirs = projectsDirs.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        for dir in allProjectDirs where dir.hasDirectoryPath {
            guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.pathExtension == "jsonl" }) else { continue }

            let projectPath = projectPathFromDir(dir)
            let decodedCwd = decodedPath(dir)
            for file in jsonlFiles {
                let sessionId = file.deletingPathExtension().lastPathComponent
                let lastActivity = modDate(file)
                sessionFiles[sessionId] = (file, projectPath, lastActivity)
                cwdToSessions[decodedCwd, default: []].append((sessionId, file, lastActivity))
            }
        }

        // Resolve running claude processes → session IDs
        let liveSessionIds = runningClaudeSessionIds(cwdToSessions: cwdToSessions)

        var seen = Set<String>()
        var sessions: [SessionInfo] = []

        for sessionId in liveSessionIds {
            guard seen.insert(sessionId).inserted,
                  let entry = sessionFiles[sessionId] else { continue }
            let processing = isAwaitingResponse(in: entry.file)
            sessions.append(SessionInfo(
                id: sessionId,
                projectPath: entry.projectPath,
                lastActivity: entry.lastActivity,
                currentStatus: processing ? lastMessage(in: entry.file) : nil,
                inProgressTasks: readTasks(sessionId: sessionId),
                isProcessing: processing
            ))
        }

        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Returns session IDs of all running `claude` processes using native kernel APIs.
    /// Always uses CWD-based matching and picks the most recently modified JSONL in the
    /// project dir — --resume points to the pre-compaction session, not the live one.
    private static func runningClaudeSessionIds(
        cwdToSessions: [String: [(sessionId: String, file: URL, lastActivity: Date)]]
    ) -> [String] {
        var pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount) + 16)
        pidCount = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))

        var result: [String] = []
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<Int(pidCount) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 else { continue }
            let execPath = String(cString: pathBuf)
            guard execPath.contains("/claude/versions/") || execPath.hasSuffix("/claude") else { continue }

            if let cwd = processCwd(pid: pid),
               let newest = cwdToSessions[cwd]?.max(by: { $0.lastActivity < $1.lastActivity }) {
                result.append(newest.sessionId)
            }
        }
        return result
    }

    /// Returns the working directory of a process via proc_pidinfo PROC_PIDVNODEPATHINFO.
    /// Buffer layout: vnode_info (152 bytes) + char[1024] for cwd path.
    private static func processCwd(pid: pid_t) -> String? {
        let bufSize = 2352   // sizeof(proc_vnodepathinfo): 2 × (152 + 1024)
        var buf = [UInt8](repeating: 0, count: bufSize)
        let ret = proc_pidinfo(pid, 9 /* PROC_PIDVNODEPATHINFO */, 0, &buf, Int32(bufSize))
        guard ret > 0 else { return nil }
        // pvi_cdir.vip_path starts at offset sizeof(vnode_info) = 152
        return buf.withUnsafeBufferPointer { ptr in
            let s = String(cString: ptr.baseAddress! + 152)
            return s.isEmpty ? nil : s
        }
    }

    // MARK: - Private helpers

    /// Reads task state from {tasksDir}/{sessionId}/*.json across all config roots.
    private static func readTasks(sessionId: String) -> [TaskItem] {
        let dirs = tasksDirs.map { $0.appendingPathComponent(sessionId) }
        guard let dir = dirs.first(where: { isDir($0) }) else { return [] }
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

    /// True when Claude is actively working — either waiting to respond or mid-tool-execution.
    /// Skips tool_result lines (user-role but not human input).
    /// Only returns false when we see a definitive assistant completion (end_turn / stop_sequence).
    private static func isAwaitingResponse(in file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        for line in text.components(separatedBy: "\n").reversed() {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let role = msg["role"] as? String
            else { continue }
            if role == "user" {
                // Skip tool_result entries — they're user-role but not human input
                if let blocks = msg["content"] as? [[String: Any]],
                   blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) { continue }
                // Skip CLI-injected slash command outputs (not human prompts)
                if let text = msg["content"] as? String,
                   text.hasPrefix("<local-command") || text.hasPrefix("<command-name>") { continue }
                return true
            }
            if role == "assistant" {
                let stopReason = msg["stop_reason"] as? String
                // tool_use → Claude is still running tools; nil → mid-stream write; both = active.
                // Only end_turn / stop_sequence mean Claude has truly finished.
                return stopReason == "tool_use" || stopReason == nil
            }
        }
        return false
    }

    /// Returns the text of the most recent message (user or assistant) from a JSONL session file.
    private static func lastMessage(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any]
            else { continue }

            let content = msg["content"]
            if let text = content as? String, !text.isEmpty {
                // Skip CLI-injected slash command outputs
                if text.hasPrefix("<local-command") || text.hasPrefix("<command-name>") { continue }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let blocks = content as? [[String: Any]] {
                for block in blocks {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String, !text.isEmpty {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // If no text block, show tool name (assistant working)
                for block in blocks {
                    if block["type"] as? String == "tool_use",
                       let name = block["name"] as? String {
                        return "[\(name)]"
                    }
                }
            }
        }
        return nil
    }

    /// Absolute decoded path for cwd matching (e.g. "-Users-jeff-dev-chirp" → "/Users/jeff/dev/chirp").
    private static func decodedPath(_ dir: URL) -> String {
        let encoded = dir.lastPathComponent
        return "/" + encoded.replacingOccurrences(of: "-", with: "/").dropFirst()
    }

    /// Display path relative to home (e.g. "-Users-jeff-dev-chirp" → "~/dev/chirp").
    private static func projectPathFromDir(_ dir: URL) -> String {
        let abs = decodedPath(dir)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Approximate cost in USD based on published per-million-token prices.
    private static func estimateCost(model: String, input: Int, output: Int,
                                     cacheWrite: Int, cacheRead: Int) -> Double {
        let (ip, op, cw, cr): (Double, Double, Double, Double)
        if model.contains("claude-3-opus") {
            (ip, op, cw, cr) = (15.0, 75.0, 18.75, 1.50)   // legacy Opus 3
        } else if model.contains("opus") {
            (ip, op, cw, cr) = (5.0, 25.0, 6.25, 0.50)     // Opus 4.x+
        } else if model.contains("claude-3-haiku-2024") {
            (ip, op, cw, cr) = (0.25, 1.25, 0.30, 0.03)    // legacy Haiku 3
        } else if model.contains("haiku") {
            (ip, op, cw, cr) = (1.0, 5.0, 1.25, 0.10)      // Haiku 3.5 / 4.x
        } else {
            (ip, op, cw, cr) = (3.0, 15.0, 3.75, 0.30)     // sonnet (default, all gens ~same)
        }
        let M = 1_000_000.0
        return (Double(input) * ip + Double(output) * op +
                Double(cacheWrite) * cw + Double(cacheRead) * cr) / M
    }
}
