// What a failed run's error means for the person reading it: the agent's
// provider needs a sign-in, its usage limit was reached, the API key it fell
// back to was rejected, or something else.
// The desktop reads the same text the same way (harness-proto `run_errors`);
// apps/parity/vectors/run-errors.json pins the cases both must agree on.
//
// This only labels plain error text. A host-typed failure
// (`AgentReauthProvider`) keeps its own reconnect controls, and no sign-in
// route is ever taken from the message.
import Foundation

enum ProviderProblem: String, Equatable, Sendable {
    /// Not signed in, signed out, or an expired or rejected login.
    case signedOut
    /// The account's usage or rate limit was hit (another account helps).
    case limitReached
    /// The provider rejected an API key (graff's own, or the one it fell back
    /// to after a plan ran out). The sign-in is fine; the key needs replacing.
    case keyRejected

    /// The error card's label.
    var label: String {
        switch self {
        case .signedOut: return "Signed out"
        case .limitReached: return "Limit reached"
        case .keyRejected: return "API key rejected"
        }
    }

    /// The desktop's button that fixes it (the phone can't start these
    /// sign-ins or edit keys; see `hint`).
    var actionLabel: String {
        switch self {
        case .signedOut, .limitReached: return "Log in"
        case .keyRejected: return "Update key"
        }
    }

    /// Where the fix is. The phone has no general agent sign-in: its only one
    /// is the host-typed ChatGPT and Codex reconnect.
    func hint(hostName: String) -> String {
        switch self {
        case .signedOut:
            return "Log in on \(hostName), in Harness's Settings → Accounts."
        case .limitReached:
            return "Wait for the limit to reset, or add another account on \(hostName) in Harness's Settings → Accounts."
        case .keyRejected:
            return "Replace or remove the API key on \(hostName) (graff key set), or, if it came from the Console sign-in, run `graff login console` there again. Your sign-in is not affected."
        }
    }
}

enum RunErrors {
    /// graff's own words for a rejected API key. Checked first, before
    /// `notTheProvider` too. graff's older generic "sign in again or check the
    /// API key" can't say which credential failed and stays `signedOut`.
    private static let keyRejected = [
        "api key was rejected",
        "fallback api key",
        "sign-in is not affected",
    ]

    private static let signedOut = [
        "isn't signed in",
        "is not signed in",
        "not signed in",
        "not logged in",
        "please run /login",
        "run `claude login`",
        "run codex login",
        "authentication failed",
        "authentication_error",
        "sign in to claude again",
        "please sign in again",
        "sign in again",
        "log in again",
        "invalid api key",
        "invalid x-api-key",
        "oauth token has expired",
        "token has expired",
        "token expired",
        "unauthorized",
        "http 401",
        "status 401",
        "(401)",
        "401 ",
        "logged out",
    ]

    private static let limitReached = [
        "usage limit",
        "limit reached",
        "rate limit",
        "rate-limit",
        "you've hit your",
        "you have hit your",
        "hit your limit",
        "quota",
        "http 429",
        "status 429",
        "(429)",
        "too many requests",
    ]

    /// Read like a sign-in or a limit, but signing in to the agent's provider
    /// doesn't fix them: hosted credit, GitHub's own API, Harness's own account.
    private static let notTheProvider = ["credit", "github", "graphql:", "harness login"]

    /// The problem `message` reports, if the agent's provider account (its sign-in or API key) can fix it.
    static func providerProblem(_ message: String) -> ProviderProblem? {
        // ASCII-only lowercasing, like the desktop; a curly apostrophe reads as a straight one.
        var scalars = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            switch scalar.value {
            case 0x2019: scalars.append("'")
            case 0x41...0x5A: scalars.append(Unicode.Scalar(scalar.value + 32)!)
            default: scalars.append(scalar)
            }
        }
        let text = String(scalars)
        if keyRejected.contains(where: { text.contains($0) }) { return .keyRejected }
        if notTheProvider.contains(where: { text.contains($0) }) { return nil }
        if signedOut.contains(where: { text.contains($0) }) { return .signedOut }
        if limitReached.contains(where: { text.contains($0) }) { return .limitReached }
        return nil
    }
}
