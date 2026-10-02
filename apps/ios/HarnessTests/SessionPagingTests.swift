import XCTest
@testable import Harness

final class SessionPagingTests: XCTestCase {
    private typealias E = SessionPaging.Entry

    func testPagesThroughActiveSessionsAndSkipsIdleOnes() {
        let entries = [E(id: "a", active: true), E(id: "idle", active: false),
                       E(id: "b", active: true), E(id: "c", active: true)]
        let b = SessionPaging.neighbors(of: "b", in: entries)
        XCTAssertEqual(b.previous, "a")
        XCTAssertEqual(b.next, "c")
        XCTAssertNil(SessionPaging.neighbors(of: "a", in: entries).previous)
        XCTAssertNil(SessionPaging.neighbors(of: "c", in: entries).next)
    }

    func testTheOpenSessionStaysInThePageSetEvenWhenIdle() {
        // Finishing and being read must not strand you: the idle open session
        // still sits between its active neighbours.
        let entries = [E(id: "a", active: true), E(id: "open", active: false),
                       E(id: "b", active: true)]
        let n = SessionPaging.neighbors(of: "open", in: entries)
        XCTAssertEqual(n.previous, "a")
        XCTAssertEqual(n.next, "b")
    }

    func testFallsBackToEverySessionWhenNothingElseIsActive() {
        let entries = [E(id: "a", active: false), E(id: "b", active: false),
                       E(id: "c", active: false)]
        let n = SessionPaging.neighbors(of: "b", in: entries)
        XCTAssertEqual(n.previous, "a")
        XCTAssertEqual(n.next, "c")
    }

    func testNoNeighboursForAnUnknownOrLoneSession() {
        XCTAssertNil(SessionPaging.neighbors(of: "x", in: [E(id: "a", active: true)]).next)
        let lone = SessionPaging.neighbors(of: "a", in: [E(id: "a", active: true)])
        XCTAssertNil(lone.previous)
        XCTAssertNil(lone.next)
        XCTAssertNil(SessionPaging.position(of: "a", in: [E(id: "a", active: true)]))
    }

    func testPositionCountsThePageSet() {
        let entries = [E(id: "a", active: true), E(id: "idle", active: false),
                       E(id: "b", active: true)]
        let p = SessionPaging.position(of: "b", in: entries)
        XCTAssertEqual(p?.index, 2)
        XCTAssertEqual(p?.count, 2)
    }
}
