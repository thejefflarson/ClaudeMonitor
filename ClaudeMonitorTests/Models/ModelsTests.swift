import XCTest
@testable import ClaudeMonitor

final class ModelsTests: XCTestCase {
    func testUsageDataDefaults() {
        let u = UsageData()
        XCTAssertEqual(u.tokensUsed, 0)
        XCTAssertEqual(u.costUSD, 0.0, accuracy: 0.001)
        XCTAssertNil(u.lastFetched)
    }

    func testTaskItemEquality() {
        let a = TaskItem(id: "1", subject: "Do something")
        let b = TaskItem(id: "1", subject: "Do something")
        XCTAssertEqual(a, b)
    }

    func testSessionInfoHasNoTasksByDefault() {
        let s = SessionInfo(id: "abc", projectPath: "~/dev/foo", lastActivity: Date())
        XCTAssertTrue(s.inProgressTasks.isEmpty)
    }
}
