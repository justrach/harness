import XCTest
@testable import Harness

final class TokenRefreshTests: XCTestCase {
    private let tokens = AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")

    private func counter() -> Counter { Counter() }

    func testRejectionIsOnlyWhatTheEdgeTurnsDown() {
        XCTAssertTrue(AuthError.http(401, "").isRejection)
        XCTAssertTrue(AuthError.http(403, "").isRejection)
        XCTAssertTrue(AuthError.http(400, "").isRejection)
        XCTAssertFalse(AuthError.http(503, "").isRejection)
        XCTAssertFalse(AuthError.http(429, "").isRejection)
        XCTAssertFalse(AuthError.http(500, "").isRejection)
        XCTAssertFalse(AuthError.invalidResponse.isRejection)
    }

    func testSuccessNeedsNoRetry() async {
        let calls = counter()
        let outcome = await TokenRefresh.run(retryDelays: [0, 0]) {
            calls.bump()
            return self.tokens
        }
        XCTAssertEqual(outcome, .refreshed(tokens))
        XCTAssertEqual(calls.value, 1)
    }

    func testAnOfflineBlipIsRetriedWithTheSameCredential() async {
        let calls = counter()
        let outcome = await TokenRefresh.run(retryDelays: [0, 0]) {
            calls.bump()
            if calls.value < 3 { throw URLError(.notConnectedToInternet) }
            return self.tokens
        }
        XCTAssertEqual(outcome, .refreshed(tokens))
        XCTAssertEqual(calls.value, 3)
    }

    func testAServerHavingABadMomentIsNotASignOut() async {
        let calls = counter()
        let outcome = await TokenRefresh.run(retryDelays: [0, 0]) {
            calls.bump()
            throw AuthError.http(503, "{\"retryable\":true}")
        }
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(calls.value, 3)  // tried, gave up, kept the credential
    }

    func testARejectedCredentialStopsAtOnce() async {
        let calls = counter()
        let outcome = await TokenRefresh.run(retryDelays: [0, 0]) {
            calls.bump()
            throw AuthError.http(401, "invalid refresh credential")
        }
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(calls.value, 1)  // replaying a spent token only invites a family revocation
    }

    func testARejectionAfterABlipStillCounts() async {
        let calls = counter()
        let outcome = await TokenRefresh.run(retryDelays: [0, 0]) {
            calls.bump()
            if calls.value == 1 { throw URLError(.timedOut) }
            throw AuthError.http(401, "")
        }
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(calls.value, 2)
    }

    func testKeychainUpdatesInPlaceAndKeepsBothHalves() {
        let key = "testToken-\(UUID().uuidString)"
        defer { Keychain.delete(key: key) }
        Keychain.save("one", key: key)
        Keychain.save("two", key: key)
        XCTAssertEqual(Keychain.load(key: key), "two")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
