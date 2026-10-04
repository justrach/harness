import XCTest
@testable import Harness

final class FeatureRolloutTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "rollout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAnInstallKeepsItsHalf() {
        let defaults = freshDefaults()
        let first = FeatureRollout.isOn(.stackedSplitDrag, defaults: defaults)
        for _ in 0..<20 { XCTAssertEqual(FeatureRollout.isOn(.stackedSplitDrag, defaults: defaults), first) }
        XCTAssertEqual(FeatureRollout.seed(defaults), FeatureRollout.seed(defaults), "the seed is made once")
    }

    func testInstallsSplitRoughlyInHalf() {
        let on = (0..<10_000).filter { FeatureRollout.isOn(.stackedSplitDrag, seed: "seed-\($0)") }.count
        XCTAssertTrue((4_700...5_300).contains(on), "\(on) of 10000 installs were on")
    }

    func testALaunchArgumentPinsTheHalf() {
        let defaults = freshDefaults()
        defaults.set("on", forKey: "rollout.stackedSplitDrag")
        XCTAssertTrue(FeatureRollout.isOn(.stackedSplitDrag, defaults: defaults))
        defaults.set("off", forKey: "rollout.stackedSplitDrag")
        XCTAssertFalse(FeatureRollout.isOn(.stackedSplitDrag, defaults: defaults))
    }

    func testUsageIsCountedPerHalfAndOnboardingOnce() {
        let defaults = freshDefaults()
        defaults.set("on", forKey: "rollout.stackedSplitDrag")
        FeatureUsage.record(.folded, for: .stackedSplitDrag, defaults: defaults)
        FeatureUsage.record(.folded, for: .stackedSplitDrag, defaults: defaults)
        defaults.set("off", forKey: "rollout.stackedSplitDrag")
        FeatureUsage.record(.splitShown, for: .stackedSplitDrag, defaults: defaults)
        XCTAssertEqual(FeatureUsage.count(.folded, for: .stackedSplitDrag, on: true, defaults: defaults), 2)
        XCTAssertEqual(FeatureUsage.count(.folded, for: .stackedSplitDrag, on: false, defaults: defaults), 0)
        XCTAssertEqual(FeatureUsage.count(.splitShown, for: .stackedSplitDrag, on: false, defaults: defaults), 1)
        XCTAssertFalse(FeatureOnboarding.hasSeen(.stackedSplitDrag, defaults: defaults))
        FeatureOnboarding.markSeen(.stackedSplitDrag, defaults: defaults)
        XCTAssertTrue(FeatureOnboarding.hasSeen(.stackedSplitDrag, defaults: defaults))
    }
}
