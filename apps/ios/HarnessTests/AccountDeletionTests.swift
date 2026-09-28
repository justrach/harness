import XCTest
@testable import Harness

final class AccountDeletionTests: XCTestCase {
    private let rotated = AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")

    private func answer(_ status: Int, _ json: String) -> AccountDeletion {
        AccountDeletion(status: status, data: Data(json.utf8))
    }

    private func refusal(_ status: Int, _ json: String) -> (String, AuthTokens?)? {
        guard case .refused(let message, let tokens) = answer(status, json) else { return nil }
        return (message, tokens)
    }

    func testDeletedOnlyWhenTheEdgeSaysSo() {
        XCTAssertEqual(answer(200, #"{"deleted":true}"#), .deleted)
        XCTAssertNotEqual(answer(200, #"{}"#), .deleted)
        XCTAssertNotEqual(answer(500, #"{"deleted":true}"#), .deleted)
    }

    func testABlockerIsShownInCodegraffsWords() throws {
        let (message, tokens) = try XCTUnwrap(refusal(409, """
            {"error":"active_subscription","message":"Cancel your plan first.",
             "tokens":{"accessToken":"access-2","refreshToken":"refresh-2"}}
            """))
        XCTAssertEqual(message, "Cancel your plan first.")
        XCTAssertEqual(tokens, rotated)
    }

    func testRefusalsKeepTheRotatedTokens() throws {
        for (status, error) in [(501, "account_deletion_unavailable"), (503, "rooms_unavailable"),
                                (502, "codegraff_unavailable"), (401, "signed_out")] {
            let json = #"{"error":"\#(error)","tokens":{"accessToken":"access-2","refreshToken":"refresh-2"}}"#
            let (message, tokens) = try XCTUnwrap(refusal(status, json), error)
            XCTAssertFalse(message.isEmpty, error)
            XCTAssertEqual(tokens, rotated, error)
        }
    }

    func testUnavailableSaysNothingWasDeleted() throws {
        let (message, _) = try XCTUnwrap(refusal(501, #"{"error":"account_deletion_unavailable"}"#))
        XCTAssertTrue(message.contains("Nothing was deleted"))
    }

    func testRefusalsBeforeTheEdgeSpendsTheTokenCarryNone() throws {
        let (_, tokens) = try XCTUnwrap(refusal(403, #"{"error":"wrong_account"}"#))
        XCTAssertNil(tokens)
        let (message, noTokens) = try XCTUnwrap(refusal(502, "Bad gateway"))
        XCTAssertNil(noTokens)
        XCTAssertTrue(message.contains("502"))
    }
}
