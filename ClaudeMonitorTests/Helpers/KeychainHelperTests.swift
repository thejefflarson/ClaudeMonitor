import XCTest
@testable import ClaudeMonitor

final class KeychainHelperTests: XCTestCase {
    // Use unique key per test run to avoid cross-test pollution
    let testKey = "test-claude-monitor-\(UUID().uuidString)"

    override func tearDown() {
        KeychainHelper.delete(key: testKey)
    }

    func testSaveAndLoad() {
        KeychainHelper.save(key: testKey, value: "sk-ant-admin-test")
        XCTAssertEqual(KeychainHelper.load(key: testKey), "sk-ant-admin-test")
    }

    func testLoadMissing() {
        XCTAssertNil(KeychainHelper.load(key: "definitely-not-\(UUID().uuidString)"))
    }

    func testDelete() {
        KeychainHelper.save(key: testKey, value: "sk-ant-admin-test")
        KeychainHelper.delete(key: testKey)
        XCTAssertNil(KeychainHelper.load(key: testKey))
    }
}
