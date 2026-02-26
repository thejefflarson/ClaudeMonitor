import XCTest
@testable import ClaudeMonitor

final class LocalLogsServiceTests: XCTestCase {

    func testParseInProgressTasks() throws {
        let fixture = Bundle(for: LocalLogsServiceTests.self)
            .url(forResource: "sample_session", withExtension: "jsonl")!
        let tasks = try LocalLogsService.parseInProgressTasks(from: fixture)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, "2")
        XCTAssertEqual(tasks[0].subject, "Write tests")
    }

    func testParseProjectPath() throws {
        let fixture = Bundle(for: LocalLogsServiceTests.self)
            .url(forResource: "sample_session", withExtension: "jsonl")!
        let path = try LocalLogsService.readProjectPath(from: fixture)
        XCTAssertEqual(path, "~/dev/myapp")
    }
}
