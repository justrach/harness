import XCTest
@testable import Harness

final class LiveActivityPlanTests: XCTestCase {
    private typealias Phase = SessionActivityAttributes.ContentState.Phase

    private func session(_ id: String, _ phase: Phase?, startedAt: TimeInterval = 0) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            attributes: SessionActivityAttributes(chatId: id, title: id, location: "harness @ mac", projectTint: 0),
            phase: phase,
            startedAt: Date(timeIntervalSince1970: startedAt))
    }

    private func shown(_ phase: Phase, startedAt: TimeInterval = 0) -> SessionActivityAttributes.ContentState {
        .init(phase: phase, startedAt: Date(timeIntervalSince1970: startedAt))
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
}
