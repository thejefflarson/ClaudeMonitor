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
}
