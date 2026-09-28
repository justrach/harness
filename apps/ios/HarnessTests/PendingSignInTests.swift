import XCTest
@testable import Harness

final class PendingSignInTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_000_000)
    private lazy var pending = PendingSignIn(state: "state-1", verifier: String(repeating: "v", count: 64),
                                             startedAt: started)

    private func callback(_ query: String) -> URL { URL(string: "harness://callback?\(query)")! }

    func testAcceptsItsOwnCallbackFromTheSheetOrSafari() throws {
        XCTAssertEqual(try pending.code(from: callback("code=abc&state=state-1"), now: started), "abc")
        XCTAssertTrue(PendingSignIn.isCallback(callback("code=abc&state=state-1")))
        XCTAssertFalse(PendingSignIn.isCallback(URL(string: "harness://chat/abc")!))
    }

    func testRefusesAnotherAttemptsLink() {
        XCTAssertThrowsError(try pending.code(from: callback("code=abc&state=someone-else"), now: started)) {
            XCTAssertEqual($0 as? PendingSignIn.CallbackError, .stateMismatch)
        }
    }

    func testRefusesALinkThatArrivesTooLate() {
        let late = started.addingTimeInterval(PendingSignIn.lifetime + 1)
        XCTAssertThrowsError(try pending.code(from: callback("code=abc&state=state-1"), now: late)) {
            XCTAssertEqual($0 as? PendingSignIn.CallbackError, .expired)
        }
    }

    func testReportsADeniedSignIn() {
        XCTAssertThrowsError(try pending.code(from: callback("error=access_denied&state=state-1"), now: started)) {
            XCTAssertEqual($0 as? PendingSignIn.CallbackError, .denied("access_denied"))
        }
        XCTAssertThrowsError(try pending.code(from: callback("state=state-1"), now: started)) {
            XCTAssertEqual($0 as? PendingSignIn.CallbackError, .missingCode)
        }
    }

    func testChallengeIsTheUnpaddedURLSafeHashOfTheVerifier() {
        let fresh = PendingSignIn.start(now: started)
        XCTAssertEqual(fresh.verifier.count, 64)
        XCTAssertFalse(fresh.challenge.contains("="))
        XCTAssertFalse(fresh.challenge.contains("+"))
        XCTAssertFalse(fresh.challenge.contains("/"))
        XCTAssertEqual(fresh.challenge.count, 43)
    }
}
