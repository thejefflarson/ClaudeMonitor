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
        let todayStart = cal.startOfDay(for: now)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let sparklineStart = cal.date(byAdding: .day, value: -29, to: todayStart)!
        let scanCutoff = min(monthStart, sparklineStart)

        var totalTokens = 0
        var totalCost = 0.0
        var costByDay: [Date: Double] = [:]   // keyed by day-start (midnight UTC)
        var tokensByDay: [Date: Int] = [:]
        // Claude Code re-writes the same assistant response (same message.id, identical
        // usage) multiple times within a session's JSONL. Each copy carries a non-null
        // stop_reason, so the stop_reason filter doesn't catch them. A msg_… id is billed
        // exactly once, so dedupe on it to avoid double-counting (was ~2× inflated).
        var seenMessageIDs = Set<String>()

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        // Cap the number of project directories and skip symlinks to prevent
        // unbounded scanning and symlink-based escapes outside ~/.claude/. (insecure-design, model-dos)
        let allProjectDirs = projectsDirs.flatMap {
            ((try? FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])) ?? [])
                .filter { !isSymlink($0) }
                .prefix(1000)
        }

        for dir in allProjectDirs where dir.hasDirectoryPath {
            guard modDate(dir) > scanCutoff else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]
            ).filter({ $0.pathExtension == "jsonl" && !isSymlink($0) }) else { continue }

            for file in files {
                guard modDate(file) > scanCutoff else { continue }

                forEachLine(in: file) { line in
                    // Only assistant usage lines can contribute, and a line without the
                    // `"usage"` key cannot have message.usage — a byte scan for it is far
                    // cheaper than parsing every line's JSON.
                    guard line.range(of: usageKey) != nil else { return }

                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let tsStr = obj["timestamp"] as? String,
                          let ts = isoFull.date(from: tsStr) ?? isoBasic.date(from: tsStr),
                          ts >= scanCutoff,
                          let msg = obj["message"] as? [String: Any],
                          msg["role"] as? String == "assistant",
                          msg["stop_reason"] as? String != nil,
                          let usage = msg["usage"] as? [String: Any]
                    else { return }

                    // Skip repeated copies of an already-counted billed response.
                    if let id = msg["id"] as? String, !seenMessageIDs.insert(id).inserted {
                        return
                    }

                    let model = msg["model"] as? String ?? ""
                    let tokens = tokenUsage(from: usage)

                    let lineCost = estimateCost(model: model, usage: tokens)

                    // Billing totals: only current month
                    if ts >= monthStart {
                        totalTokens += tokens.total
                        totalCost   += lineCost
                    }

                    let lineTokens = tokens.total

                    // Sparkline buckets: last 30 days
                    if ts >= sparklineStart {
                        let dayStart = cal.startOfDay(for: ts)
                        costByDay[dayStart, default: 0] += lineCost
                        tokensByDay[dayStart, default: 0] += lineTokens
                    }
                }
            }
        }

        let dailyCosts = (0..<30).map { offset -> DailyCost in
            let day = cal.date(byAdding: .day, value: offset, to: sparklineStart)!
            return DailyCost(date: day, cost: costByDay[day] ?? 0, tokens: tokensByDay[day] ?? 0)
        }

        var result = UsageData()
        result.tokensUsed  = totalTokens
        result.costUSD     = totalCost
        result.dailyCosts  = dailyCosts
        result.periodStart = monthStart
        result.lastFetched = now
        return result
    }

    /// Returns one SessionInfo per running claude process, augmented with JSONL data.
    static func activeSessions() -> [SessionInfo] {
        // Build JSONL index: sessionId → (file, projectPath, lastActivity)
        // Also reverse-index: absProjectPath → [(sessionId, file, lastActivity)]
        var sessionFiles:  [String: (file: URL, projectPath: String, lastActivity: Date)] = [:]
        // Keyed by encoded directory name (e.g. "-Users-jeff-dev-hvac-research") to avoid
        // lossy decoding — hyphens in project names are indistinguishable from path separators.
        var slugToSessions: [String: [(sessionId: String, file: URL, lastActivity: Date)]] = [:]

        let allProjectDirs = projectsDirs.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        for dir in allProjectDirs where dir.hasDirectoryPath {
            guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.pathExtension == "jsonl" }) else { continue }

            let projectPath = projectPathFromDir(dir)
            let slug = dir.lastPathComponent
            for file in jsonlFiles {
                let sessionId = file.deletingPathExtension().lastPathComponent
                let lastActivity = modDate(file)
                sessionFiles[sessionId] = (file, projectPath, lastActivity)
                slugToSessions[slug, default: []].append((sessionId, file, lastActivity))
            }
        }

        // Resolve running claude processes → session IDs + real CWDs
        let liveEntries = runningClaudeSessions(slugToSessions: slugToSessions)

        var seen = Set<String>()
        var sessions: [SessionInfo] = []
        let homePath = home.path

        for (sessionId, cwd) in liveEntries {
            guard seen.insert(sessionId).inserted,
                  let entry = sessionFiles[sessionId] else { continue }
            // Use real CWD for display — avoids lossy slug decoding (e.g. "hvac-research")
            let displayPath = cwd.hasPrefix(homePath) ? "~" + cwd.dropFirst(homePath.count) : cwd
            let parsed = parseSession(file: entry.file)
            sessions.append(SessionInfo(
                id: sessionId,
                projectPath: displayPath,
                lastActivity: entry.lastActivity,
                currentStatus: parsed.isProcessing ? parsed.lastMessage : nil,
                inProgressTasks: readTasks(sessionId: sessionId),
                isProcessing: parsed.isProcessing,
                sessionCost: parsed.cost,
                sessionTokens: parsed.tokens
            ))
        }

        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Returns (sessionId, cwd) pairs for all running `claude` processes using native kernel APIs.
    /// Matches process CWD to JSONL files by encoding the CWD as a slug (replacing "/" with "-")
    /// which is how Claude Code names its project directories. This avoids lossy decoding of
    /// slugs that contain hyphens in the original path (e.g. "hvac-research").
    private static func runningClaudeSessions(
        slugToSessions: [String: [(sessionId: String, file: URL, lastActivity: Date)]]
    ) -> [(sessionId: String, cwd: String)] {
        var pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount) + 16)
        pidCount = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))

        var result: [(sessionId: String, cwd: String)] = []
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<Int(pidCount) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 else { continue }
            let execPath = String(cString: pathBuf)
            guard execPath.contains("/claude/versions/") || execPath.hasSuffix("/claude") else { continue }

            if let cwd = processCwd(pid: pid) {
                let slug = cwd.replacingOccurrences(of: "/", with: "-")
                if let newest = slugToSessions[slug]?.max(by: { $0.lastActivity < $1.lastActivity }) {
                    result.append((newest.sessionId, cwd))
                }
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

    struct SessionParseResult {
        var isProcessing: Bool
        var lastMessage: String?
        var cost: Double
        var tokens: Int
    }

    private struct CacheEntry {
        var mtime: Date
        var offset: UInt64          // bytes consumed for cost/tokens, aligned to a line boundary
        var totalCost: Double
        var totalTokens: Int
        var seenIDs: Set<String>    // message.ids already counted, to survive across incremental reads
        var result: SessionParseResult
    }

    // Keyed by file path string to avoid URL equality pitfalls.
    private static var parseCache: [String: CacheEntry] = [:]

    // Bytes read from the file's tail for the reverse pass. Bounds that pass to O(1)
    // regardless of file size; must comfortably exceed the largest single JSONL line.
    private static let tailWindow: UInt64 = 1_048_576

    /// Bytes read per `forEachLine` chunk — caps the month scan's memory use.
    static let scanChunkSize = 1_048_576

    /// `"usage"` as bytes — the cheap pre-filter for scan lines worth parsing.
    private static let usageKey = Data(#""usage""#.utf8)

    /// Incremental parse of a session JSONL file: derives processing state, last message,
    /// lifetime cost, and token count. Active sessions are append-only, so cost/tokens
    /// resume from a saved byte offset and only newly appended lines are parsed; the
    /// reverse pass reads a bounded tail. This keeps per-poll work proportional to bytes
    /// appended, not total file size (active logs reach 100+ MB and are re-read every poll).
    /// Unchanged files (same mtime) short-circuit with no I/O.
    static func parseSession(file: URL) -> SessionParseResult {
        let mtime = modDate(file)
        let key = file.path
        let cached = parseCache[key]
        if let cached, cached.mtime == mtime {
            return cached.result
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return SessionParseResult(isProcessing: false, lastMessage: nil, cost: 0, tokens: 0)
        }
        defer { try? handle.close() }

        // Read the true size from the open handle. URL.resourceValues(.fileSizeKey) caches
        // on the URL and returns a stale size on a growing file, which would freeze the
        // incremental read (and thus the session's cost) after the first poll.
        let fileSize = (try? handle.seekToEnd()) ?? 0

        // Resume the running totals unless the file shrank (truncation/rotation), in which
        // case start fresh — a shorter file can't be an append to what we already counted.
        var offset: UInt64 = 0
        var totalCost = 0.0
        var totalTokens = 0
        var seenMessageIDs = Set<String>()   // dedupe repeated assistant responses (see monthlyUsage)
        if let cached, fileSize >= cached.offset {
            offset = cached.offset
            totalCost = cached.totalCost
            totalTokens = cached.totalTokens
            seenMessageIDs = cached.seenIDs
        }

        // Forward pass: read only [offset, EOF) and parse up to the last complete line.
        // A trailing partial line (mid-write) is left unconsumed and re-read next poll.
        if offset < fileSize {
            try? handle.seek(toOffset: offset)
            let appended = (try? handle.readToEnd()) ?? Data()
            if let lastNL = appended.lastIndex(of: 0x0A) {
                let complete = appended[...lastNL]
                offset += UInt64(complete.count)
                for line in String(decoding: complete, as: UTF8.self).components(separatedBy: "\n") {
                    guard !line.isEmpty,
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let msg = obj["message"] as? [String: Any],
                          msg["role"] as? String == "assistant",
                          msg["stop_reason"] as? String != nil,
                          let usage = msg["usage"] as? [String: Any]
                    else { continue }

                    if let id = msg["id"] as? String, !seenMessageIDs.insert(id).inserted { continue }

                    let model  = msg["model"] as? String ?? ""
                    let tokens = tokenUsage(from: usage)
                    totalCost += estimateCost(model: model, usage: tokens)
                    totalTokens += tokens.total
                }
            }
        }

        // Reverse pass: processing state + last message live in the file's tail, so read a
        // bounded window from the end rather than the whole file.
        let tailStart = fileSize > tailWindow ? fileSize - tailWindow : 0
        try? handle.seek(toOffset: tailStart)
        let tailData = (try? handle.readToEnd()) ?? Data()
        var tailLines = String(decoding: tailData, as: UTF8.self).components(separatedBy: "\n")
        if tailStart > 0 && !tailLines.isEmpty { tailLines.removeFirst() }  // drop partial leading line

        var isProcessing = false
        var lastMsg: String? = nil
        for line in tailLines.reversed() {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if obj["type"] as? String == "system",
               obj["subtype"] as? String == "stop_hook_summary" {
                isProcessing = false
                break
            }

            guard let msg = obj["message"] as? [String: Any],
                  let role = msg["role"] as? String
            else { continue }

            if role == "user" {
                if let blocks = msg["content"] as? [[String: Any]],
                   blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) { continue }
                if let t = msg["content"] as? String,
                   t.hasPrefix("<local-command") || t.hasPrefix("<command-name>") { continue }
                isProcessing = true
                break
            }
            if role == "assistant" {
                let stopReason = msg["stop_reason"] as? String
                isProcessing = stopReason == "tool_use" || stopReason == nil

                if lastMsg == nil {
                    let content = msg["content"]
                    if let t = content as? String, !t.isEmpty {
                        lastMsg = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let blocks = content as? [[String: Any]] {
                        for block in blocks {
                            if block["type"] as? String == "text",
                               let t = block["text"] as? String, !t.isEmpty {
                                lastMsg = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                        if lastMsg == nil {
                            for block in blocks {
                                if block["type"] as? String == "tool_use",
                                   let name = block["name"] as? String {
                                    lastMsg = "[\(name)]"
                                    break
                                }
                            }
                        }
                    }
                }
                break
            }
        }

        let result = SessionParseResult(isProcessing: isProcessing, lastMessage: lastMsg,
                                        cost: totalCost, tokens: totalTokens)
        parseCache[key] = CacheEntry(mtime: mtime, offset: offset, totalCost: totalCost,
                                     totalTokens: totalTokens, seenIDs: seenMessageIDs,
                                     result: result)
        return result
    }

    /// Reads task state from {tasksDir}/{sessionId}/*.json across all config roots.
    private static func readTasks(sessionId: String) -> [TaskItem] {
        // Validate sessionId is a UUID before appending to the tasks path. A non-UUID value
        // (e.g. "../../../etc") supplied by a malicious socket peer would cause path traversal. (insecure-design)
        guard UUID(uuidString: sessionId) != nil else { return [] }
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

    /// Absolute decoded path for cwd matching (e.g. "-Users-jeff-dev-chirp" → "/Users/jeff/dev/chirp").
    private static func decodedPath(_ dir: URL) -> String {
        let encoded = dir.lastPathComponent
        let raw = "/" + encoded.replacingOccurrences(of: "-", with: "/").dropFirst()
        // Normalize to remove any ".." traversal components introduced by a crafted directory name. (path-traversal)
        return URL(fileURLWithPath: raw).standardized.path
    }

    /// Display path relative to home (e.g. "-Users-jeff-dev-chirp" → "~/dev/chirp").
    private static func projectPathFromDir(_ dir: URL) -> String {
        let abs = decodedPath(dir)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs
    }

    /// Calls `body` once per line of a file, reading in bounded chunks.
    ///
    /// The month scan used to read each JSONL with `String(contentsOf:)` and skip anything
    /// over 100 MB so a huge log couldn't exhaust memory. Active sessions routinely pass
    /// that — four did in one month — and every skipped file silently dropped its whole
    /// cost from the total. Streaming bounds memory by the chunk size instead of the file
    /// size, so no session has to be excluded.
    ///
    /// Lines are handed over as `Data`, not `String`: the scan feeds them straight to
    /// `JSONSerialization`, so materializing a String per line would be pure overhead on
    /// the millions of lines a month's logs contain.
    static func forEachLine(in file: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        var remainder = Data()
        while let chunk = try? handle.read(upToCount: scanChunkSize), !chunk.isEmpty {
            remainder.append(chunk)
            // One pool per chunk: the JSON parse below autoreleases, and without a pool
            // inside the loop nothing drains until the whole scan finishes.
            autoreleasepool {
                while let nl = remainder.firstIndex(of: 0x0A) {
                    body(remainder[remainder.startIndex..<nl])
                    remainder = remainder[remainder.index(after: nl)...]
                }
                // Re-base so the slice doesn't keep referencing the consumed buffer.
                remainder = Data(remainder)
            }
        }
        if !remainder.isEmpty { autoreleasepool { body(remainder) } }
    }


    private static func modDate(_ url: URL) -> Date {
        // Stat the path rather than asking the URL: URL.resourceValues caches on the URL
        // instance, so a reused URL keeps reporting the mtime it saw first — which would
        // freeze parseSession's mtime short-circuit on a file that is still growing.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            ?? .distantPast
    }

    /// True if the URL is a symlink — used to avoid following links outside ~/.claude/.
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// Token counts for one billed response. Cache writes are split by TTL because
    /// the two are priced differently (see `estimateCost`).
    struct TokenUsage {
        var input = 0
        var output = 0
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        var cacheRead = 0
        var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
    }

    /// Pulls the billed token counts out of a `message.usage` object.
    /// `cache_creation` carries the per-TTL breakdown; logs written before Claude Code
    /// emitted it only have the flat `cache_creation_input_tokens`, which was 5-minute.
    static func tokenUsage(from usage: [String: Any]) -> TokenUsage {
        var u = TokenUsage()
        u.input     = usage["input_tokens"] as? Int ?? 0
        u.output    = usage["output_tokens"] as? Int ?? 0
        u.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        if let split = usage["cache_creation"] as? [String: Any] {
            u.cacheWrite5m = split["ephemeral_5m_input_tokens"] as? Int ?? 0
            u.cacheWrite1h = split["ephemeral_1h_input_tokens"] as? Int ?? 0
        } else {
            u.cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
        }
        return u
    }

    /// Base input price per million tokens, and the cache-read multiplier, per model family.
    /// Every other rate is a fixed multiple of the base price, so one number per family
    /// covers input, output, and both cache-write TTLs.
    private static func pricing(for model: String) -> (base: Double, cacheRead: Double) {
        if model.contains("claude-3-opus")        { return (15.00, 0.1) }    // legacy Opus 3
        if model.contains("fable") ||
           model.contains("mythos")               { return (10.00, 0.025) }  // Fable/Mythos read at 0.025x
        if model.contains("opus")                 { return (5.00, 0.1) }     // Opus 4.x / 5
        if model.contains("claude-3-haiku-2024")  { return (0.25, 0.1) }     // legacy Haiku 3
        if model.contains("haiku")                { return (1.00, 0.1) }     // Haiku 3.5 / 4.x
        if model.contains("sonnet-5")             { return (2.00, 0.1) }     // Sonnet 5 is cheaper
        return (3.00, 0.1)                                                   // Sonnet 4.6 and earlier
    }

    /// Cost in USD from published per-million-token prices. Rates are multiples of each
    /// model's base input price: output 5x, cache read 0.1x (0.025x on Fable/Mythos),
    /// 5-minute cache write 1.25x, 1-hour cache write 2x.
    ///
    /// The two cache-write TTLs must stay separate: Claude Code writes almost all of its
    /// cache at the 1-hour TTL, and charging those at the 5-minute rate understated the
    /// monthly figure by about 15%.
    static func estimateCost(model: String, usage u: TokenUsage) -> Double {
        let (base, readMultiplier) = pricing(for: model)
        let millions = (Double(u.input)
                        + Double(u.output) * 5.0
                        + Double(u.cacheWrite5m) * 1.25
                        + Double(u.cacheWrite1h) * 2.0
                        + Double(u.cacheRead) * readMultiplier) / 1_000_000.0
        return millions * base
    }
}
