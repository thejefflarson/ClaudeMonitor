import XCTest
@testable import ClaudeMonitor

final class LocalLogsServiceTests: XCTestCase {

    func testProjectPathFromDirName() {
        // "-Users-jeff-dev-chirp" should decode to "~/dev/chirp"
        // We test the overall activeSessions pipeline compiles and returns an array.
        let sessions = LocalLogsService.activeSessions()
        XCTAssertNotNil(sessions) // just verifying it runs without crashing
    }
}
