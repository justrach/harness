import XCTest
@testable import Harness

@MainActor
final class TranscriptPresentationTests: XCTestCase {
    func testReattachedStreamingTextStartsVisibleAndOnlyNewTextFades() {
        let registry = VeilStore()
        let first = registry.veil(for: "row", seededLength: 80)
        XCTAssertTrue(first.segments(totalLength: 80).allSatisfy { $0.alpha == 1 })
        first.noteLength(100)
        XCTAssertEqual(first.segments(totalLength: 100).first?.alpha, 1)
        XCTAssertTrue(first.isFading)
        let reattached = VeilStore().veil(for: "row", seededLength: 100)
        XCTAssertTrue(reattached.segments(totalLength: 100).allSatisfy { $0.alpha == 1 })
        XCTAssertFalse(reattached.isFading)
    }

    func testNewSuffixIsRegisteredBeforeItsFirstRender() {
        let registry = VeilStore()
        let initial = registry.veil(for: "row", seededLength: 5)
        let updated = registry.veil(for: "row", seededLength: 10)
        XCTAssertTrue(initial === updated)
        let segments = updated.segments(totalLength: 10)
        XCTAssertEqual(segments.first?.range, 0..<5)
        XCTAssertEqual(segments.first?.alpha, 1)
        XCTAssertEqual(segments.last?.range, 5..<10)
        XCTAssertLessThan(segments.last!.alpha, 0.1)
        XCTAssertTrue(registry.veil(for: "row", seededLength: 10) === updated)
    }

    func testVisibleSuffixNeverDimsAcrossBurstsOrMarkdownLengthChanges() {
        var now: Double = 1000
        let veil = RowVeil(seededLength: 5, clock: { now })
        veil.noteLength(10)
        var alpha: Double = 0
        for length in [10, 15, 13, 18, 25, 24, 30] {
            now += 40
            veil.noteLength(length)
            let next = veil.segments(totalLength: length).first { $0.range.contains(7) }!.alpha
            XCTAssertGreaterThanOrEqual(next, alpha)
            alpha = next
        }
        now += 2000
        XCTAssertFalse(veil.isFading)
        XCTAssertTrue(veil.segments(totalLength: 30).allSatisfy { $0.alpha == 1 })
    }

    func testSubagentControlChipsHideWorkerNumbers() {
        let cases = [
            ("Wait for agent 1", "Waiting on"),
            ("Wait for agent 7: Audit login", "Waiting on"),
            ("Wait for agents", "Waiting on"),
            ("agent_output", "Waiting on"),
            ("Message agent 2", "Message"),
            ("Message agent 2: Audit login", "Message"),
            ("Message agent", "Message"),
            ("Send agent message", "Message"),
            ("agent_message", "Message"),
            ("Resume agent", "Resume"),
            ("Resume agent 3", "Resume"),
            ("subagent_resume", "Resume"),
            ("Close agent", "Close"),
            ("Close agent 4", "Close"),
        ]
        for (name, label) in cases {
            let call = RenderToolCall(tag: "unknown", fields: ["name": name])
            XCTAssertEqual(call.chipLabel, label, name)
            XCTAssertEqual(call.chipDetail, "subagent", name)
            XCTAssertEqual(call.string("name"), name)
        }
        let ordinary = RenderToolCall(tag: "unknown", fields: ["name": "Message agentic service"])
        XCTAssertEqual(ordinary.chipLabel, "Tool")
        XCTAssertEqual(ordinary.chipDetail, "Message agentic service")
    }

    func testRestartNoticesMatchTheSharedPresentationVector() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("apps/parity/vectors/restart-notices.json"))
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let labels = try XCTUnwrap(vector["labels"] as? [String: String])
        for item in try XCTUnwrap(vector["cases"] as? [[String: Any]]) {
            let message = try XCTUnwrap(item["message"] as? String)
            let expected = item["expect"] as? String
            let notice = RunErrors.restartNotice(message)
            XCTAssertEqual(notice?.rawValue, expected, message)
            let chip = ErrorChipView(message: message)
            XCTAssertEqual(chip.isNotice, expected != nil, message)
            XCTAssertEqual(chip.label, expected.flatMap { labels[$0] } ?? "Error", message)
            if let notice { XCTAssertEqual(notice.label, labels[notice.rawValue], message) }
        }
    }

    func testTypedAuthenticationFailuresKeepTheirErrorPresentation() {
        let message = "Harness updated to v0.2.190 — picking this run back up"
        let typed = ErrorChipView(message: message, allowNotice: false)
        XCTAssertFalse(typed.isNotice)
        XCTAssertEqual(typed.label, "Error")
        let auth = ErrorChipView(message: "Authentication failed", problem: .signedOut)
        XCTAssertFalse(auth.isNotice)
        XCTAssertEqual(auth.label, "Signed out")
    }

    func testDesktopUserMessageCollapseThresholds() {
        XCTAssertFalse(UserBubble.needsCollapse("A short prompt."))
        XCTAssertFalse(UserBubble.needsCollapse(String(repeating: "x", count: 400)))
        XCTAssertTrue(UserBubble.needsCollapse(String(repeating: "x", count: 401)))
        XCTAssertTrue(UserBubble.needsCollapse((1...6).map(String.init).joined(separator: "\n")))
    }
}
