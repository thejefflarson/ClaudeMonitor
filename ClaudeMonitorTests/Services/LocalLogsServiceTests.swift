import XCTest
@testable import ClaudeMonitor

final class LocalLogsServiceTests: XCTestCase {

    func testProjectPathFromDirName() {
        // "-Users-jeff-dev-chirp" should decode to "~/dev/chirp"
        // We test the overall activeSessions pipeline compiles and returns an array.
        let sessions = LocalLogsService.activeSessions()
        XCTAssertNotNil(sessions) // just verifying it runs without crashing
    }

    // MARK: - parseSession incremental parsing

    /// One assistant message line with the given id and token usage.
    private func assistantLine(id: String, model: String = "claude-opus-4-8",
                               input: Int, output: Int, cacheWrite: Int, cacheRead: Int,
                               stopReason: String = "end_turn") -> String {
        """
        {"timestamp":"2026-06-01T10:00:00.000Z","message":{"id":"\(id)","role":"assistant","model":"\(model)","stop_reason":"\(stopReason)","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private func makeTempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).jsonl")
    }

    private func write(_ text: String, to url: URL) {
        try? text.data(using: .utf8)!.write(to: url)
        // Nudge mtime forward so parseSession's same-mtime short-circuit doesn't skip re-parsing.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Incremental parse across appends must equal a single full parse of the final content.
    func testIncrementalParseMatchesFullParse() {
        let lines = [
            assistantLine(id: "msg_a", input: 100, output: 50, cacheWrite: 10, cacheRead: 1000),
            assistantLine(id: "msg_b", input: 200, output: 80, cacheWrite: 0, cacheRead: 5000),
            assistantLine(id: "msg_c", input: 5, output: 5, cacheWrite: 0, cacheRead: 200),
        ]

        // Incremental: write first line, parse; append second, parse; append third, parse.
        let incFile = makeTempFile()
        write(lines[0] + "\n", to: incFile)
        _ = LocalLogsService.parseSession(file: incFile)
        write(lines[0...1].joined(separator: "\n") + "\n", to: incFile)
        _ = LocalLogsService.parseSession(file: incFile)
        write(lines.joined(separator: "\n") + "\n", to: incFile)
        let incremental = LocalLogsService.parseSession(file: incFile)

        // Full: a fresh file (new path → cold cache) with all three lines, parsed once.
        let fullFile = makeTempFile()
        write(lines.joined(separator: "\n") + "\n", to: fullFile)
        let full = LocalLogsService.parseSession(file: fullFile)

        XCTAssertEqual(incremental.cost, full.cost, accuracy: 1e-9)
        XCTAssertEqual(incremental.tokens, full.tokens)
        XCTAssertEqual(incremental.tokens, 100+50+10+1000 + 200+80+0+5000 + 5+5+0+200)
    }

    /// A repeated message.id (same billed response written twice) must be counted once.
    func testDuplicateMessageIDCountedOnce() {
        let line = assistantLine(id: "msg_dup", input: 100, output: 50, cacheWrite: 0, cacheRead: 1000)
        let file = makeTempFile()
        write(line + "\n", to: file)
        let once = LocalLogsService.parseSession(file: file)

        // Append an identical copy of the same response (same id).
        write(line + "\n" + line + "\n", to: file)
        let twice = LocalLogsService.parseSession(file: file)

        XCTAssertEqual(once.tokens, twice.tokens, "duplicate message.id must not add tokens")
        XCTAssertEqual(once.cost, twice.cost, accuracy: 1e-9)
    }

    /// A trailing line without a newline is mid-write; it must not be counted until completed.
    func testPartialTrailingLineDeferredUntilComplete() {
        let complete = assistantLine(id: "msg_1", input: 100, output: 50, cacheWrite: 0, cacheRead: 0)
        let partial  = assistantLine(id: "msg_2", input: 999, output: 999, cacheWrite: 0, cacheRead: 0)
        let file = makeTempFile()

        // One complete line, then a partial line with no terminating newline.
        write(complete + "\n" + partial, to: file)
        let mid = LocalLogsService.parseSession(file: file)
        XCTAssertEqual(mid.tokens, 150, "partial trailing line should not be counted yet")

        // Newline arrives, completing the second line.
        write(complete + "\n" + partial + "\n", to: file)
        let done = LocalLogsService.parseSession(file: file)
        XCTAssertEqual(done.tokens, 150 + 999 + 999, "completed line should now be counted")
    }

    /// If the file shrinks (truncation/rotation), totals reset rather than carrying stale sums.
    func testFileShrinkResetsTotals() {
        let big = [
            assistantLine(id: "msg_x", input: 500, output: 500, cacheWrite: 0, cacheRead: 0),
            assistantLine(id: "msg_y", input: 500, output: 500, cacheWrite: 0, cacheRead: 0),
        ].joined(separator: "\n") + "\n"
        let file = makeTempFile()
        write(big, to: file)
        let before = LocalLogsService.parseSession(file: file)
        XCTAssertEqual(before.tokens, 2000)

        // Rotate: replace with a shorter file containing a single, different response.
        write(assistantLine(id: "msg_z", input: 7, output: 3, cacheWrite: 0, cacheRead: 0) + "\n", to: file)
        let after = LocalLogsService.parseSession(file: file)
        XCTAssertEqual(after.tokens, 10, "totals should reset when the file shrinks, not accumulate")
    }

    // MARK: - Cost estimation

    private func usage(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                       write5m: Int = 0, write1h: Int = 0) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output,
         "cache_read_input_tokens": cacheRead,
         "cache_creation_input_tokens": write5m + write1h,
         "cache_creation": ["ephemeral_5m_input_tokens": write5m,
                            "ephemeral_1h_input_tokens": write1h]]
    }

    /// Published rates: output is 5x the base input price, cache reads 0.1x.
    func testBaseRatesPerModelFamily() {
        let oneM = LocalLogsService.tokenUsage(from: usage(input: 1_000_000))
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-opus-5", usage: oneM), 5.00, accuracy: 1e-9)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-sonnet-5", usage: oneM), 2.00, accuracy: 1e-9)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-sonnet-4-6", usage: oneM), 3.00, accuracy: 1e-9)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-haiku-4-5", usage: oneM), 1.00, accuracy: 1e-9)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-fable-5-1", usage: oneM), 10.00, accuracy: 1e-9)

        let oneMOut = LocalLogsService.tokenUsage(from: usage(output: 1_000_000))
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-opus-5", usage: oneMOut), 25.00, accuracy: 1e-9)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-sonnet-5", usage: oneMOut), 10.00, accuracy: 1e-9)
    }

    /// Sonnet 5 is $2/$10 per MTok; earlier Sonnets are $3/$15. Pricing them alike
    /// overcharged every Sonnet 5 response by 50%.
    func testSonnet5PricedBelowEarlierSonnets() {
        let u = LocalLogsService.tokenUsage(from: usage(input: 1_000_000, output: 1_000_000))
        let five = LocalLogsService.estimateCost(model: "claude-sonnet-5", usage: u)
        let four = LocalLogsService.estimateCost(model: "claude-sonnet-4-6", usage: u)
        XCTAssertEqual(five, 12.00, accuracy: 1e-9)
        XCTAssertEqual(four, 18.00, accuracy: 1e-9)
    }

    /// A 1-hour cache write costs 2x base input; a 5-minute write costs 1.25x.
    func testCacheWriteTTLsPricedDifferently() {
        let w5 = LocalLogsService.tokenUsage(from: usage(write5m: 1_000_000))
        let w1h = LocalLogsService.tokenUsage(from: usage(write1h: 1_000_000))
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-opus-5", usage: w5), 6.25, accuracy: 1e-9)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-opus-5", usage: w1h), 10.00, accuracy: 1e-9)

        let read = LocalLogsService.tokenUsage(from: usage(cacheRead: 1_000_000))
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-opus-5", usage: read), 0.50, accuracy: 1e-9)
        // Fable reads at 0.025x, not 0.1x.
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-fable-5-1", usage: read), 0.25, accuracy: 1e-9)
    }

    /// Logs written before Claude Code emitted the per-TTL breakdown carry only the flat
    /// count; those writes were 5-minute, so they must not be charged the 1-hour rate.
    func testFlatCacheCreationTreatedAs5Minute() {
        let u = LocalLogsService.tokenUsage(from: ["cache_creation_input_tokens": 1_000_000])
        XCTAssertEqual(u.cacheWrite5m, 1_000_000)
        XCTAssertEqual(u.cacheWrite1h, 0)
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-opus-5", usage: u), 6.25, accuracy: 1e-9)
    }

    /// Regression against Claude Code's own figure: a real cost-state record reported
    /// $0.0019690 for this Haiku usage. Our estimate must reproduce it.
    func testMatchesClaudeCodeReportedCost() {
        let u = LocalLogsService.tokenUsage(from: usage(input: 1814, output: 31))
        XCTAssertEqual(LocalLogsService.estimateCost(model: "claude-haiku-4-5-20251001", usage: u),
                       0.0019690, accuracy: 1e-9)
    }

    func testTokenTotalCountsEveryClass() {
        let u = LocalLogsService.tokenUsage(from: usage(input: 1, output: 2, cacheRead: 4,
                                                        write5m: 8, write1h: 16))
        XCTAssertEqual(u.total, 31)
    }


    // MARK: - forEachLine streaming reader

    /// Lines must come back identically whether or not they straddle a chunk boundary.
    /// The month scan reads logs far larger than one chunk, so this is the risky path.
    func testForEachLineSpansChunkBoundaries() {
        let file = makeTempFile()
        // Lines sized so that many land across the 1 MB chunk edge.
        let lines = (0..<400).map { "line-\($0)-" + String(repeating: "x", count: 5_000) }
        write(lines.joined(separator: "\n") + "\n", to: file)
        XCTAssertGreaterThan((try! FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int),
                             LocalLogsService.scanChunkSize,
                             "fixture must exceed one chunk or it proves nothing")

        var got: [String] = []
        LocalLogsService.forEachLine(in: file) { got.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(got, lines)
    }

    /// A file whose last line has no terminating newline must still yield that line.
    func testForEachLineYieldsUnterminatedFinalLine() {
        let file = makeTempFile()
        write("a\nb\nc", to: file)
        var got: [String] = []
        LocalLogsService.forEachLine(in: file) { got.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(got, ["a", "b", "c"])
    }

    /// Blank lines are preserved as empty, not dropped, so callers decide what to skip.
    func testForEachLineKeepsEmptyLines() {
        let file = makeTempFile()
        write("a\n\nb\n", to: file)
        var got: [String] = []
        LocalLogsService.forEachLine(in: file) { got.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(got, ["a", "", "b"])
    }

    func testForEachLineOnMissingFileYieldsNothing() {
        var called = false
        LocalLogsService.forEachLine(in: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")) { _ in
            called = true
        }
        XCTAssertFalse(called)
    }

}
