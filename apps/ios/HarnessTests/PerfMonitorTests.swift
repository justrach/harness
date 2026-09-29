import XCTest
@testable import Harness

final class PerfMonitorTests: XCTestCase {
    func testPercentilesUseNearestRank() {
        let r = PerfRecorder()
        for i in 1...100 { r.record("op", ms: Double(i)) }
        let s = r.stats()[0]
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.p50, 50)
        XCTAssertEqual(s.p95, 95)
        XCTAssertEqual(s.max, 100)
    }

    func testWindowKeepsOnlyTheLatestRunsButCountsAll() {
        let r = PerfRecorder(capacity: 4)
        for ms in [100.0, 1, 2, 3, 4] { r.record("op", ms: ms) }
        let s = r.stats()[0]
        XCTAssertEqual(s.count, 5)
        // The 100 fell out of the window, so it no longer lifts the 95th; it stays in max and total.
        XCTAssertEqual(s.p95, 4)
        XCTAssertEqual(s.max, 100)
        XCTAssertEqual(s.totalMs, 110)
    }

    func testOverBudgetRunsAreCounted() {
        let r = PerfRecorder()
        r.record("op", ms: 3, budgetMs: 4)
        r.record("op", ms: 9, budgetMs: 4)
        r.record("op", ms: 4, budgetMs: 4)
        XCTAssertEqual(r.stats()[0].overBudget, 1)
    }

    func testCostliestOperationComesFirst() {
        let r = PerfRecorder()
        r.record("cheap", ms: 1)
        r.record("costly", ms: 50)
        XCTAssertEqual(r.stats().map(\.name), ["costly", "cheap"])
    }

    func testEmptyRecorderHasNoStats() {
        XCTAssertTrue(PerfRecorder().stats().isEmpty)
        XCTAssertEqual(PerfRecorder.percentile([], 0.5), 0)
    }

    func testResetClears() {
        let r = PerfRecorder()
        r.record("op", ms: 1)
        r.reset()
        XCTAssertTrue(r.stats().isEmpty)
    }

    func testSlowAndFrozenTurnsAreCountedSeparately() {
        let t = MainThreadTally()
        for ms in [2.0, 5, 24, 800] { t.add(ms: ms) }
        let s = t.snapshot()
        XCTAssertEqual(s.turns, 4)
        XCTAssertEqual(s.slow, 2)
        XCTAssertEqual(s.frozen, 1)
        XCTAssertEqual(s.slowPercent, 50)
    }

    func testTheProcessStartTimeIsKnownAndInThePast() throws {
        let start = try XCTUnwrap(Perf.processStart())
        let age = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(age, 0)
        XCTAssertLessThan(age, 3600)
    }

    func testMeasureRecordsUnderTheOperationName() {
        Perf.shared.reset()
        let value = Perf.measure(PerfSpan.homeGroup) { 21 * 2 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(Perf.shared.recorder.stats().first { $0.name == PerfSpan.homeGroup }?.count, 1)
    }

    func testAnInteractionRecordsOnceWhenItFinishes() {
        Perf.shared.reset()
        Perf.shared.startInteraction(PerfSpan.navigationOpen)
        Perf.shared.finishInteraction(PerfSpan.navigationOpen)
        Perf.shared.finishInteraction(PerfSpan.navigationOpen)  // no second start, so nothing more to record
        let done = expectation(description: "recorded")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(Perf.shared.recorder.stats().first { $0.name == PerfSpan.navigationOpen }?.count, 1)
    }
}
