// How a token refresh is judged and retried. Pure Foundation, so it is unit-testable without a device.
//
// CodeGraff refresh tokens are single use. That makes one distinction matter more than any other:
//   - the edge TURNED THE CREDENTIAL DOWN (400/401/403): it is spent or revoked, nothing will revive it,
//     and the person has to sign in again;
//   - the edge was UNREACHABLE or having a bad moment (offline, timeout, 5xx, 429): nothing was
//     decided, and the same credential must be kept and tried again.
// Treating the second like the first signs people out over a bad train tunnel; treating the first like
// the second leaves a dead token redialing forever behind a quiet "connecting" spinner.

import Foundation

extension AuthError {
    /// The edge refused the credential itself (as opposed to failing to answer).
    var isRejection: Bool {
        if case .http(let code, _) = self { return code == 400 || code == 401 || code == 403 }
        return false
    }
}

enum RefreshOutcome: Equatable {
    case refreshed(AuthTokens)
    /// The credential is no good: sign in again.
    case rejected
    /// Undecided: keep the credential, try again later.
    case unavailable
}

enum TokenRefresh {
    /// Waits between attempts of one refresh round (so up to three tries). Repeating a request is safe:
    /// the edge answers a repeat of a refresh it already served with the same result for a couple of
    /// minutes, so a reply lost on the way back does not spend the token twice.
    static let retryDelays: [UInt64] = [1_000_000_000, 3_000_000_000]

    static func classify(_ error: Error) -> RefreshOutcome {
        if let auth = error as? AuthError, auth.isRejection { return .rejected }
        return .unavailable
    }

    /// One refresh round: retry `.unavailable` after each delay, stop at the first definite answer.
    static func run(
        retryDelays: [UInt64] = TokenRefresh.retryDelays,
        send: () async throws -> AuthTokens
    ) async -> RefreshOutcome {
        var attempt = 0
        while true {
            do {
                return .refreshed(try await send())
            } catch {
                if error is CancellationError { return .unavailable }
                let outcome = classify(error)
                guard outcome == .unavailable, attempt < retryDelays.count else { return outcome }
                try? await Task.sleep(nanoseconds: retryDelays[attempt])
                attempt += 1
            }
        }
    }
}
