// First-run setup (OnboardingView): four questions and a ready screen, each
// answer setting a real default. Shown once after a fresh sign-in; Settings
// replays it. Existing installs that never pass through sign-in keep every
// default they had.

import Foundation

/// How much an agent may do without asking: the engine's device-wide
/// `GetAutonomy` / `SetAutonomy` setting. The engine keeps full access until
/// someone picks, so nothing changes for a computer nobody set up.
enum Autonomy: String, CaseIterable, Identifiable, Decodable {
    case readOnly = "read-only"
    case workspace
    case fullAccess = "full-access"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .readOnly: "Read only"
        case .workspace: "Workspace"
        case .fullAccess: "Full access"
        }
    }

    var blurb: String {
        switch self {
        case .readOnly: "Reads and plans. Asks before it changes anything."
        case .workspace: "Edits this project. Asks before anything else."
        case .fullAccess: "Runs anything without asking."
        }
    }

    /// The four things the setting decides, in the order the setup shows them.
    static let capabilities = [
        "Read files and run searches",
        "Edit files in this project",
        "Run commands outside it",
        "Approve its own requests",
    ]

    /// Which of [capabilities] this level allows without asking.
    var allows: [Bool] {
        switch self {
        case .readOnly: [true, false, false, false]
        case .workspace: [true, true, false, false]
        case .fullAccess: [true, true, true, true]
        }
    }
}

/// The engine's answer to `GetAutonomy` / `SetAutonomy`.
struct AutonomySetting: Decodable, Equatable {
    var autonomy: Autonomy
    /// False until someone picked a level on that computer.
    var chosen: Bool
}

enum Onboarding {
    static let doneKey = "onboarding.v1.done"
    static let pendingKey = "onboarding.v1.pending"

    private static var defaults: UserDefaults { .standard }

    /// A fresh sign-in: show the setup once, unless it already ran here.
    static func signedInFresh() {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: pendingKey)
    }

    static var isPending: Bool {
        defaults.bool(forKey: pendingKey) && !defaults.bool(forKey: doneKey)
    }

    static func finish() {
        defaults.set(true, forKey: doneKey)
        defaults.set(false, forKey: pendingKey)
    }

    /// What the effort dial says about each step of the ladder.
    static func effortBlurb(_ level: String) -> String {
        switch level {
        case "minimal", "none": "Answers straight away."
        case "low": "Quick answers and light edits."
        case "medium": "Balanced for everyday changes."
        case "high": "Thinks before it edits. The default for real work."
        case "xhigh": "Longer reasoning for tricky bugs."
        case "max": "Its hardest thinking."
        case "ultracode": "Maximum effort for big code changes."
        case "ultrathink": "Deep thinking before every step."
        default: "How long it reasons before acting."
        }
    }

    /// The ladder the dial shows when the model reports none.
    static let fallbackLadder = ["low", "medium", "high", "xhigh", "max", "ultracode", "ultrathink"]

    /// Starter prompts on the ready screen.
    static let starters = [
        ("Tour this project", "Give me a tour of this project: what it does, how it is laid out, and where to start."),
        ("Build something new", "Let's build something new. Ask me what I have in mind first."),
    ]
}
