import XCTest
@testable import Harness

@MainActor
final class TranscriptFollowTests: XCTestCase {
    private func sample(_ offset: CGFloat, bottom: CGFloat = 0, height: CGFloat = 2000,
                        viewport: CGFloat = 600) -> TranscriptGeometry {
        TranscriptGeometry(contentHeight: height, viewportHeight: viewport,
                           offset: offset, bottom: bottom)
    }

    func testStreamGrowthAndKeyboardResizeDoNotReleaseFollow() {
        let state = ScrollState()
        state.observe(old: sample(1400), new: sample(1400, bottom: 180, height: 2180))
        XCTAssertTrue(state.pinned)
        state.observe(old: sample(1400, bottom: 180),
                      new: sample(1400, bottom: 480, viewport: 300))
        XCTAssertTrue(state.pinned)
        XCTAssertFalse(state.showJump)
    }

    func testTouchWithoutMovementDuringGrowthPreservesFollow() {
        let state = ScrollState()
        state.userScrolling = true
        state.observe(old: sample(1400), new: sample(1100, bottom: 300, height: 2300))
        state.endGesture()
        XCTAssertTrue(state.pinned)
    }

    func testReadingHistoryStaysReleasedDuringStreamingAndResize() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(900, bottom: 500))
        state.endGesture()
        XCTAssertFalse(state.pinned)
        XCTAssertTrue(state.showJump)
        state.observe(old: sample(900, bottom: 500), new: sample(900, bottom: 800, height: 2300))
        state.observe(old: sample(900, bottom: 800), new: sample(900, bottom: 1100, viewport: 300))
        XCTAssertFalse(state.pinned)
    }

    func testMovingUpInsideReengageBandStillReleases() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(1380, bottom: 20))
        state.endGesture()
        XCTAssertFalse(state.pinned)
        XCTAssertFalse(state.showJump)
    }

    func testMovingTowardBottomReengagesAndContinuesFollowing() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(900, bottom: 500))
        state.observe(old: sample(900, bottom: 500), new: sample(1350, bottom: 50))
        state.endGesture()
        XCTAssertTrue(state.pinned)
        XCTAssertFalse(state.showJump)
    }

    func testStreamRemeasureNearBottomDoesNotRecaptureHistoryReader() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(1380, bottom: 20))
        XCTAssertFalse(state.pinned)
        // A self-sizing streaming row changes both content size and offset.
        // This is not a finger reversing toward the bottom.
        state.observe(old: sample(1380, bottom: 20),
                      new: sample(1390, bottom: 40, height: 2030))
        XCTAssertFalse(state.pinned, "Streaming layout must not take scroll ownership back")
        state.endGesture()
        XCTAssertFalse(state.pinned)
    }

    func testEndingAwayGestureAtLayoutAdjustedBottomDoesNotRearm() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(1380, bottom: 20))
        state.observe(old: sample(1380, bottom: 20),
                      new: sample(1380, bottom: 0, height: 1980))
        state.endGesture()
        XCTAssertFalse(state.pinned, "Only a bottom-directed gesture, jump or send restores follow")
    }

    func testFingerMovingUpReleasesEvenWhenStreamLayoutMovesOffsetDown() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(1420, bottom: 30, height: 2050), dragDelta: -20)
        XCTAssertFalse(state.pinned)
        state.observe(old: sample(1420, bottom: 30, height: 2050),
                      new: sample(1430, bottom: 40, height: 2070), dragDelta: 0)
        state.endGesture()
        XCTAssertFalse(state.pinned)
    }

    func testBottomRubberBandRecoveryPreservesFollow() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(1440, bottom: -40), dragDelta: 40)
        state.userDragging = false // Finger lifted; UIKit owns the elastic return.
        state.observe(old: sample(1440, bottom: -40), new: sample(1420, bottom: -20), dragDelta: 0)
        XCTAssertTrue(state.pinned)
        state.observe(old: sample(1420, bottom: -20), new: sample(1400), dragDelta: 0)
        state.endGesture()
        XCTAssertTrue(state.pinned)
    }

    func testBottomDirectedFlickCanRearmWhenDecelerationReachesBottom() {
        let state = ScrollState()
        state.pinned = false
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(900, bottom: 500), new: sample(1000, bottom: 400), dragDelta: 100)
        XCTAssertFalse(state.pinned)
        state.userDragging = false
        state.observe(old: sample(1000, bottom: 400), new: sample(1400), dragDelta: 0)
        state.endGesture()
        XCTAssertTrue(state.pinned)
    }

    func testExplicitJumpRearmsEvenAfterLargeHistoryScroll() {
        let state = ScrollState()
        state.userScrolling = true
        state.userDragging = true
        state.observe(old: sample(1400), new: sample(100, bottom: 1300))
        state.endGesture()
        state.arm()
        XCTAssertTrue(state.pinned)
        XCTAssertFalse(state.showJump)
    }
}
