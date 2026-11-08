import XCTest
@testable import DeepseekUsageTracker

final class KeychainTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(
            service: "com.deepseekusage.tracker.tests.\(UUID().uuidString)")
        defer { try? store.delete(.apiKey) }

        XCTAssertFalse(store.has(.apiKey))
        try store.save("sk-test-123", for: .apiKey)
        XCTAssertEqual(store.read(.apiKey), "sk-test-123")
        XCTAssertTrue(store.has(.apiKey))

        try store.delete(.apiKey)
        XCTAssertNil(store.read(.apiKey))
        XCTAssertFalse(store.has(.apiKey))
    }

    func testEmptyValueRemovesItem() throws {
        let store = KeychainStore(
            service: "com.deepseekusage.tracker.tests.\(UUID().uuidString)")
        defer { try? store.delete(.usageToken) }

        try store.save("token", for: .usageToken)
        XCTAssertEqual(store.read(.usageToken), "token")
        try store.save("   ", for: .usageToken)
        XCTAssertNil(store.read(.usageToken))
    }
}
