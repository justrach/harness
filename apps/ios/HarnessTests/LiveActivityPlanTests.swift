import XCTest
@testable import Harness

final class LiveActivityPlanTests: XCTestCase {
    private typealias Phase = SessionActivityAttributes.ContentState.Phase

    private func session(_ id: String, _ phase: Phase?, startedAt: TimeInterval = 0) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            attributes: SessionActivityAttributes(chatId: id, title: id, project: "harness", device: "mac",
                                                  projectTint: 0, harness: "claude-code"),
            phase: phase,
            startedAt: Date(timeIntervalSince1970: startedAt))
    }

    private func shown(_ phase: Phase, startedAt: TimeInterval = 0) -> SessionActivityAttributes.ContentState {
        .init(phase: phase, startedAt: Date(timeIntervalSince1970: startedAt), detail: nil)
    }

    func testIndicatorsMapToPhases() {
        XCTAssertEqual(LiveActivityPlan.phase(for: .working), .working)
        XCTAssertEqual(LiveActivityPlan.phase(for: .awaitingInput), .waiting)
        XCTAssertEqual(LiveActivityPlan.phase(for: .completed), .done)
        XCTAssertEqual(LiveActivityPlan.phase(for: .errored), .failed)
        XCTAssertNil(LiveActivityPlan.phase(for: .idle))
    }

    func testStartsOnlyRunningOrWaitingSessionsNewestFirstUpToTheCap() {
        let sessions = [
            session("old", .working, startedAt: 1),
            session("waiting", .waiting, startedAt: 4),
            session("newest", .working, startedAt: 5),
            session("mid", .working, startedAt: 3),
            session("finished", .done, startedAt: 9),
            session("idle", nil, startedAt: 9),
        ]
        XCTAssertEqual(LiveActivityPlan.steps(showing: [:], sessions: sessions),
                       [.start(chatId: "newest"), .start(chatId: "waiting"), .start(chatId: "mid")])
    }

    func testUpdatesOnChangeFinishesOnDoneAndRemovesWhenIdle() {
        let showing = [
            "run": shown(.working),
            "asks": shown(.working),
            "ends": shown(.working),
            "seen": shown(.done),
        ]
        let sessions = [
            session("run", .working),          // unchanged: nothing to do
            session("asks", .waiting),         // now needs input
            session("ends", .failed),          // settled
            session("seen", nil),              // opened and read
        ]
        XCTAssertEqual(LiveActivityPlan.steps(showing: showing, sessions: sessions),
                       [.update(chatId: "asks"), .finish(chatId: "ends"), .remove(chatId: "seen")])
    }

    func testFinishedActivitiesFreeTheirSlotForNewRuns() {
        let showing = ["a": shown(.working), "b": shown(.working), "c": shown(.working)]
        let sessions = [
            session("a", .working), session("b", .working), session("c", .done),
            session("d", .working, startedAt: 10),
        ]
        XCTAssertEqual(LiveActivityPlan.steps(showing: showing, sessions: sessions),
                       [.finish(chatId: "c"), .start(chatId: "d")])
    }

    func testDetailIsOneShortLine() {
        XCTAssertNil(LiveActivityPlan.detail(nil))
        XCTAssertNil(LiveActivityPlan.detail("  \n \n"))
        XCTAssertEqual(LiveActivityPlan.detail("Running tests\n\n  cargo test -p ui "), "Running tests cargo test -p ui")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(LiveActivityPlan.detail(long)?.count, 140)
    }

    func testCurrentTaskIsTheFirstUnfinishedOneFromTheLatestTodoCall() {
        func todo(_ id: String, _ items: [TaskItem]) -> MessagePart {
            .tool(id: id, call: RenderToolCall(tag: "todo", fields: ["items": items]), isError: false, resolved: true)
        }
        let entries = [
            MessageEntry(id: "1", role: .assistant, parts: [todo("a", [TaskItem(text: "old", done: false)])],
                         createdAt: 1, deviceId: "mac"),
            MessageEntry(id: "2", role: .assistant, parts: [
                todo("b", [TaskItem(text: "Read the code", done: true),
                           TaskItem(text: "Write the fix", done: false),
                           TaskItem(text: "Run the tests", done: false)]),
                .text(id: "t", text: "Working on it"),
            ], createdAt: 2, deviceId: "mac"),
        ]
        let tasks = LiveActivityPlan.tasks(in: entries)
        XCTAssertEqual(tasks?.map(\.text), ["Read the code", "Write the fix", "Run the tests"])

        var snapshot = session("s", .working)
        snapshot.tasks = tasks
        XCTAssertEqual(snapshot.state?.task, "Write the fix")
        XCTAssertEqual(snapshot.state?.tasksDone, 1)
        XCTAssertEqual(snapshot.state?.tasksTotal, 3)

        snapshot.tasks = tasks?.map { TaskItem(text: $0.text, done: true) }
        XCTAssertNil(snapshot.state?.task)
        XCTAssertEqual(snapshot.state?.tasksDone, 3)
        XCTAssertNil(LiveActivityPlan.tasks(in: []))
    }
}
