import XCTest
@testable import Harness

/// The thresholds behind "online / not confirmed / offline", with no socket and no clock.
final class PresenceRuleTests: XCTestCase {
    private let now: Int64 = 10_000_000
    private let joined: Int64 = 9_000_000  // joined 1000s ago, well past warm-up

    private func status(received: Int64? = nil, connected: Bool = true, joinedAt: Int64? = nil,
                        rowLastSeen: Int64? = nil, at time: Int64? = nil) -> HostStatus {
        PresenceRule.status(now: time ?? now, received: received, connected: connected,
                            joinedAt: joinedAt ?? (connected ? joined : nil), rowLastSeen: rowLastSeen)
    }

    func testABeatInTheLastFortyFiveSecondsIsOnline() {
        XCTAssertEqual(status(received: now - 1_000), .online)
        XCTAssertEqual(status(received: now - 44_999), .online)
    }

    func testOnlineDoesNotNeedTheSocketThatMomentBecauseTheBeatIsTheEvidence() {
        XCTAssertEqual(status(received: now - 10_000, connected: false), .online)
    }

    func testAnOldBeatIsNotConfirmedUntilFiveQuietMinutesThenOffline() {
        XCTAssertEqual(status(received: now - 45_000), .unknown)
        XCTAssertEqual(status(received: now - 299_999), .unknown)
        XCTAssertEqual(status(received: now - 300_000), .offline)
    }

    func testNoBeatYetIsNeverOfflineJustBecausePhoneJustConnected() {
        // The screenshot case: a running host whose next beat has not arrived.
        XCTAssertEqual(status(received: nil, joinedAt: now - 5_000), .unknown)
        XCTAssertEqual(status(received: nil, joinedAt: now - 59_000, rowLastSeen: 0), .unknown)
    }

    func testNoBeatIsOfflineOnlyOnceWarmedUpAndTheDeviceRowIsStale() {
        XCTAssertEqual(status(received: nil, rowLastSeen: now - 300_000), .offline)
        XCTAssertEqual(status(received: nil, rowLastSeen: now - 60_000), .unknown)
        XCTAssertEqual(status(received: nil, rowLastSeen: nil), .unknown)
    }

    func testADisconnectedPhoneNeverClaimsOffline() {
        XCTAssertEqual(status(received: now - 3_600_000, connected: false), .unknown)
        XCTAssertEqual(status(received: nil, connected: false, rowLastSeen: 0), .unknown)
    }

    func testLivenessKeepsTheDialGateVerdicts() {
        func verdict(_ received: Int64?, connected: Bool = true) -> PeerLiveness {
            PresenceRule.liveness(now: now, received: received, connected: connected,
                                  joinedAt: connected ? joined : nil, rowLastSeen: nil)
        }
        XCTAssertEqual(verdict(now - 1_000), .live)
        XCTAssertEqual(verdict(now - 100_000), .unknown)
        XCTAssertEqual(verdict(now - 300_000), .dark)
        XCTAssertEqual(verdict(now - 1_000, connected: false), .unknown, "registry down is never live or dark")
    }

    // MARK: the one wake-up

    private func next(received: Int64? = nil, connected: Bool = true, joinedAt: Int64? = nil,
                      rowLastSeen: Int64? = nil) -> Int64? {
        PresenceRule.nextChange(after: now, received: received, connected: connected,
                                joinedAt: joinedAt ?? (connected ? joined : nil), rowLastSeen: rowLastSeen)
    }

    func testAFreshBeatWakesWhenItAgesOutOfOnline() {
        XCTAssertEqual(next(received: now - 10_000), now - 10_000 + 45_000)
    }

    func testAnAgedBeatWakesNextWhenItBecomesOffline() {
        XCTAssertEqual(next(received: now - 100_000), now - 100_000 + 300_000)
    }

    func testAnOfflineHostNeedsNoFurtherWakeUps() {
        XCTAssertNil(next(received: now - 400_000))
    }

    func testADisconnectedPhoneSchedulesNothingPastTheOnlineEdge() {
        XCTAssertNil(next(received: now - 100_000, connected: false))
        XCTAssertEqual(next(received: now - 10_000, connected: false), now - 10_000 + 45_000)
    }

    func testAJustConnectedPhoneWakesOnceWhenWarmUpEnds() {
        XCTAssertEqual(next(received: nil, joinedAt: now - 10_000), now - 10_000 + 60_000)
    }

    func testStatusNeverChangesBeforeTheScheduledWakeUp() throws {
        let received = now - 10_000
        let wake = try XCTUnwrap(next(received: received))
        XCTAssertEqual(status(received: received, at: wake - 1), .online)
        XCTAssertNotEqual(status(received: received, at: wake), .online)
    }
}
