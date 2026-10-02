import XCTest
@testable import Harness

/// The idle wake-up work: rooms and loops that used to tick every second (or every 20s) for nothing now wake
/// for a reason. These pin the cadence and the new wait-for-change plumbing.
final class LivenessScheduleTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000
    private let quiet: UInt64 = 900 * 1_000_000_000  // the rooms' 15 minute quiet probe

    func testAPendingDeadlineKeepsTheOriginalOneSecondLook() {
        XCTAssertEqual(LivenessSchedule.waitNs(pending: true, joined: true, quietForNs: 0, probeQuietNs: quiet), s)
        XCTAssertEqual(LivenessSchedule.waitNs(pending: true, joined: false, quietForNs: 0, probeQuietNs: quiet), s)
    }

    func testAnIdleJoinedRoomSleepsAMinuteNotASecond() {
        XCTAssertEqual(LivenessSchedule.waitNs(pending: false, joined: true, quietForNs: 5 * s, probeQuietNs: quiet),
                       60 * s)
    }

    func testAnIdleUnjoinedRoomSleepsTheSafetyCap() {
        XCTAssertEqual(LivenessSchedule.waitNs(pending: false, joined: false, quietForNs: 0, probeQuietNs: quiet),
                       60 * s)
    }

    func testTheQuietProbeIsNeverSleptPast() {
        // 20s before the probe is due, the loop wakes in 20s — not after the 60s cap.
        XCTAssertEqual(LivenessSchedule.waitNs(pending: false, joined: true, quietForNs: quiet - 20 * s,
                                               probeQuietNs: quiet), 20 * s)
    }

    func testAnOverdueOrImminentProbeIsLookedAtWithinASecond() {
        XCTAssertEqual(LivenessSchedule.waitNs(pending: false, joined: true, quietForNs: quiet - s / 2,
                                               probeQuietNs: quiet), s)
        XCTAssertEqual(LivenessSchedule.waitNs(pending: false, joined: true, quietForNs: quiet + 10 * s,
                                               probeQuietNs: quiet), s)
    }
}

@MainActor
final class IdleWakeupTests: XCTestCase {
    private var appConfig: AppConfig {
        AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                  userId: "wakeup-tests", orgId: "tests", deviceId: "ios-test",
                  deviceName: "Test phone", devBearer: "wakeup-tests@tests")
    }

    private func liveModel() -> (AppModel, WorkspaceStore) {
        let store = WorkspaceStore(config: appConfig, doc: RegistryDoc(deviceId: "ios-test"))
        let model = AppModel()
        model.workspace = store
        return (model, store)
    }

    private func sessionRow(_ chatId: String, status: String) -> RegistryRow {
        RegistryRow(kind: "sessions", id: chatId, seq: 1, deleted: false, delHlc: nil,
                    fields: ["chatId": .string(chatId), "deviceId": .string("host"),
                             "status": .string(status), "updatedAt": .int(1)],
                    clocks: [:])
    }

    // MARK: waiting for a session change (the Live Activities loop)

    func testTheWaitEndsWhenASessionRowChanges() async {
        let (model, store) = liveModel()
        let woke = expectation(description: "woke on a session row")
        let waiter = Task { await model.untilSessionsChange(); woke.fulfill() }
        try? await Task.sleep(for: .milliseconds(100))  // let it park
        store.handle(.state(seq: 1, full: true, gcFloor: 0, rows: [sessionRow("chat-1", status: "working")],
                            presence: [:]))
        await fulfillment(of: [woke], timeout: 3)
        waiter.cancel()
    }

    func testTheWaitStaysParkedWhileNothingChanges() async {
        let (model, _) = liveModel()
        var woke = false
        let waiter = Task { await model.untilSessionsChange(); woke = true }
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(woke, "no session changed, so nothing should have woken")
        waiter.cancel()
        await waiter.value
    }

    func testTheWaitEndsWhenItsTaskIsCancelled() async {
        let (model, _) = liveModel()
        let done = expectation(description: "returned after cancel")
        let waiter = Task { await model.untilSessionsChange(); done.fulfill() }
        try? await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await fulfillment(of: [done], timeout: 3)
    }

    func testAQuietAppDoesNotNeedSampling() {
        let (model, _) = liveModel()
        XCTAssertFalse(model.liveActivitiesNeedSampling)
    }

    func testResumeOnceResumesExactlyOnceInEitherOrder() async {
        let early = ResumeOnce()
        early.fire()
        await withCheckedContinuation { early.install($0) }  // fired first: resumes at once

        let late = ResumeOnce()
        Task { try? await Task.sleep(for: .milliseconds(50)); late.fire(); late.fire() }
        await withCheckedContinuation { late.install($0) }  // a second fire must not trap
    }

    // MARK: connectivity cadence

    func testAHealthyIdleAppDoesNotPulse() async {
        let center = ConnectivityCenter()
        center.registryConnected = { true }
        center.chatRooms = { [] }
        center.registryRetryAt = { nil }
        center.hasPendingSends = { false }
        center.start()
        try? await Task.sleep(for: .milliseconds(1_500))
        center.stop()
        XCTAssertEqual(center.pulse, 0)
        XCTAssertEqual(center.state, .connected)
    }

    func testALostPathDropsStraightToTheBusyCadenceInsteadOfWaitingOutAnIdleSleep() async {
        let center = ConnectivityCenter()
        center.registryConnected = { true }
        center.chatRooms = { [] }
        center.registryRetryAt = { nil }
        center.hasPendingSends = { false }
        center.start()
        try? await Task.sleep(for: .milliseconds(200))  // idle: next look is 5s away
        center.setPathOffline(true)
        try? await Task.sleep(for: .milliseconds(2_300))
        center.stop()
        XCTAssertGreaterThanOrEqual(center.pulse, 2, "busy samples every second, not every 5s")
    }
}
