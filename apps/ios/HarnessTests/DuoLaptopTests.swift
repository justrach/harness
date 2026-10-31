import XCTest
@testable import Harness

/// iPhone Duo half open like a laptop: what the quick actions may do and what they send.
final class DuoLaptopTests: XCTestCase {
    func testRunningTurnCanOnlyBeStopped() {
        let on = QuickAction.allCases.filter {
            QuickActions.enabled($0, running: true, approvable: false, hasPrompt: true)
        }
        XCTAssertEqual(on, [.stop])
    }

    func testIdleTurnRetriesAndRunsTests() {
        let on = QuickAction.allCases.filter {
            QuickActions.enabled($0, running: false, approvable: false, hasPrompt: true)
        }
        XCTAssertEqual(on, [.retry, .runTests])
        XCTAssertFalse(QuickActions.enabled(.retry, running: false, approvable: false, hasPrompt: false),
                       "nothing to retry before the first message")
    }

    func testApproveAnswersEachSingleChoiceWithItsFirstOption() {
        let questions = [
            UserInputQuestion(id: "q1", header: "Apply", question: "Apply the patch?", options: ["Yes", "No"]),
            UserInputQuestion(id: "q2", header: "Push", question: "Push it?", options: ["Push", "Hold"]),
        ]
        XCTAssertEqual(QuickActions.approval(questions), [
            UserInputAnswer(questionId: "q1", labels: ["Yes"]),
            UserInputAnswer(questionId: "q2", labels: ["Push"]),
        ])
    }

    func testApproveStepsAsideForOpenOrMultipleChoiceQuestions() {
        XCTAssertNil(QuickActions.approval([]))
        XCTAssertNil(QuickActions.approval([
            UserInputQuestion(id: "q1", header: "Name", question: "What name?", options: []),
        ]))
        XCTAssertNil(QuickActions.approval([
            UserInputQuestion(id: "q1", header: "Pick", question: "Which?", options: ["a", "b"], multiSelect: true),
        ]))
    }

    func testRetrySendsTheNewestPromptText() {
        let entries = [
            MessageEntry(id: "u1", role: .user, parts: [.text(id: "p1", text: "first")], createdAt: 0, deviceId: "d"),
            MessageEntry(id: "a1", role: .assistant, parts: [.text(id: "p2", text: "reply")], createdAt: 1, deviceId: "d"),
            MessageEntry(id: "u2", role: .user, parts: [.text(id: "p3", text: "  fix the header  ")], createdAt: 2, deviceId: "d"),
            MessageEntry(id: "a2", role: .assistant, parts: [.text(id: "p4", text: "done")], createdAt: 3, deviceId: "d"),
        ]
        XCTAssertEqual(QuickActions.lastPrompt(entries), "fix the header")
        XCTAssertNil(QuickActions.lastPrompt([entries[1]]))
    }
}
