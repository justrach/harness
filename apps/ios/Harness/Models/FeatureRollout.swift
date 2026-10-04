// Staged rollouts of new features: each install is put in a feature's "on" or "off" half by a random seed kept on
// the phone, the same answer every launch. No account, device or session id is involved, so the half says nothing
// about who someone is. A launch argument (`-rollout.<feature> on|off`) pins the half for tests and screenshots.
//
// Usage is counted on the phone per feature and half. The counts are plain numbers with fixed names, in the spirit
// of the anonymous performance batch (PerfUpload.swift); they are not sent anywhere until the stats service learns
// to accept them.

import Foundation

enum RolloutFeature: String, CaseIterable {
    /// The stacked phone split's drag handle (fold the list away, bring it back).
    case stackedSplitDrag = "stackedSplitDrag"

    /// Share of installs in the "on" half, 0...100.
    var percentOn: Int {
        switch self {
        case .stackedSplitDrag: return 50
        }
    }
}

enum FeatureRollout {
    private static let seedKey = "rollout.seed"

    /// This install's random seed, made on first use.
    static func seed(_ defaults: UserDefaults = .standard) -> String {
        if let seed = defaults.string(forKey: seedKey), !seed.isEmpty { return seed }
        let seed = UUID().uuidString.lowercased()
        defaults.set(seed, forKey: seedKey)
        return seed
    }

    /// Whether this install has the feature. A `-rollout.<feature> on|off` launch argument wins.
    static func isOn(_ feature: RolloutFeature, defaults: UserDefaults = .standard) -> Bool {
        switch defaults.string(forKey: "rollout.\(feature.rawValue)") {
        case "on": return true
        case "off": return false
        default: return isOn(feature, seed: seed(defaults))
        }
    }

    /// The pure rule: a stable hash of seed and feature, so one install can land in different halves of
    /// different features. `String.hashValue` is randomized per launch, so this is FNV-1a over the UTF-8 bytes.
    static func isOn(_ feature: RolloutFeature, seed: String) -> Bool {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(feature.rawValue):\(seed)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % 100) < feature.percentOn
    }
}

/// One-time introductions to a feature, shown only to installs that have it.
enum FeatureOnboarding {
    static func hasSeen(_ feature: RolloutFeature, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "onboarding.\(feature.rawValue).seen")
    }

    static func markSeen(_ feature: RolloutFeature, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: "onboarding.\(feature.rawValue).seen")
    }
}

/// Fixed usage events per feature. Counts only: never what was in the session, or which one.
enum FeatureUsageEvent: String, CaseIterable {
    /// A stacked split appeared (counted for both halves, so the halves can be compared).
    case splitShown = "split_shown"
    case folded = "folded"
    case unfolded = "unfolded"
    case onboardingShown = "onboarding_shown"
    case onboardingDismissed = "onboarding_dismissed"
}

enum FeatureUsage {
    /// `usage.<feature>.<on|off>.<event>`: the half is part of the key, so counts from before a pinned
    /// override never mix into the other half.
    static func key(_ feature: RolloutFeature, on: Bool, _ event: FeatureUsageEvent) -> String {
        "usage.\(feature.rawValue).\(on ? "on" : "off").\(event.rawValue)"
    }

    static func record(_ event: FeatureUsageEvent, for feature: RolloutFeature,
                       defaults: UserDefaults = .standard) {
        let key = key(feature, on: FeatureRollout.isOn(feature, defaults: defaults), event)
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    static func count(_ event: FeatureUsageEvent, for feature: RolloutFeature, on: Bool,
                      defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: key(feature, on: on, event))
    }
}
