import XCTest
@testable import Harness

final class FeatureRolloutTests: XCTestCase {
    private let example = RolloutFeature(rawValue: "example", percentOn: 50)

    private func freshDefaults() -> UserDefaults {
        let name = "rollout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAnInstallKeepsItsHalf() {
        let defaults = freshDefaults()
        let first = FeatureRollout.isOn(example, defaults: defaults)
        for _ in 0..<20 { XCTAssertEqual(FeatureRollout.isOn(example, defaults: defaults), first) }
        XCTAssertEqual(FeatureRollout.seed(defaults), FeatureRollout.seed(defaults), "the seed is made once")
    }

    func testInstallsAreOnInTheFeaturesShare() {
        for percent in [0, 30, 50, 100] {
            let feature = RolloutFeature(rawValue: "example\(percent)", percentOn: percent)
            let on = (0..<10_000).filter { FeatureRollout.isOn(feature, seed: "seed-\($0)") }.count
            let expected = feature.percentOn * 100
            XCTAssertTrue((expected - 300...expected + 300).contains(on), "\(on) of 10000 installs were on")
        }
    }

    func testALaunchArgumentPinsTheHalf() {
        let defaults = freshDefaults()
        defaults.set("on", forKey: "rollout.example")
        XCTAssertTrue(FeatureRollout.isOn(example, defaults: defaults))
        defaults.set("off", forKey: "rollout.example")
        XCTAssertFalse(FeatureRollout.isOn(example, defaults: defaults))
    }

    func testUsageIsCountedPerHalfAndOnboardingOnce() {
        let defaults = freshDefaults()
        defaults.set("on", forKey: "rollout.example")
        FeatureUsage.record(.onboardingShown, for: example, defaults: defaults)
        FeatureUsage.record(.onboardingShown, for: example, defaults: defaults)
        defaults.set("off", forKey: "rollout.example")
        FeatureUsage.record(.onboardingDismissed, for: example, defaults: defaults)
        XCTAssertEqual(FeatureUsage.count(.onboardingShown, for: example, on: true, defaults: defaults), 2)
        XCTAssertEqual(FeatureUsage.count(.onboardingShown, for: example, on: false, defaults: defaults), 0)
        XCTAssertEqual(FeatureUsage.count(.onboardingDismissed, for: example, on: false, defaults: defaults), 1)
        XCTAssertFalse(FeatureOnboarding.hasSeen(example, defaults: defaults))
        FeatureOnboarding.markSeen(example, defaults: defaults)
        XCTAssertTrue(FeatureOnboarding.hasSeen(example, defaults: defaults))
    }
}
