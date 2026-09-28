// A CodeGraff sign-in that has started but not finished: the OAuth state and
// PKCE verifier the callback must match.
//
// Sign-in normally finishes in the app's own browser sheet, but not always: a
// magic link from Mail opens in Safari, which finishes the sign-in there and
// hands `harness://callback?code=&state=` back to the app. So the pending
// sign-in lives in the Keychain, not in the sheet, and either path completes
// it — even after iOS has killed the app while the person was reading mail.

import CryptoKit
import Foundation

struct PendingSignIn: Codable, Equatable {
    let state: String
    let verifier: String
    let startedAt: Date

    /// How long a started sign-in waits for its callback (a magic link can take
    /// a few minutes to arrive).
    static let lifetime: TimeInterval = 30 * 60
    private static let key = "pendingSignIn"

    static func start(now: Date = Date()) -> PendingSignIn {
        let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return PendingSignIn(state: UUID().uuidString, verifier: verifier, startedAt: now)
    }

    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func expired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) > Self.lifetime
    }

    enum CallbackError: LocalizedError, Equatable {
        case denied(String)
        case missingCode
        case stateMismatch
        case expired

        var errorDescription: String? {
            switch self {
            case .denied(let reason): "Sign-in was not completed (\(reason))."
            case .missingCode: "The sign-in link was missing its code. Try again."
            case .stateMismatch: "That sign-in link belongs to a different attempt. Start sign-in again."
            case .expired: "That sign-in took too long. Start sign-in again."
            }
        }
    }

    /// The authorization code from a `harness://callback` URL, if it answers
    /// this sign-in.
    func code(from callback: URL, now: Date = Date()) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { throw CallbackError.denied(value("error_description") ?? error) }
        guard value("state") == state else { throw CallbackError.stateMismatch }
        guard !expired(now: now) else { throw CallbackError.expired }
        guard let code = value("code"), !code.isEmpty else { throw CallbackError.missingCode }
        return code
    }

    static func isCallback(_ url: URL) -> Bool {
        url.scheme == Endpoints.callbackScheme && url.host == "callback"
    }

    // MARK: Keychain

    func save() {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return }
        Keychain.save(text, key: Self.key)
    }

    static func load() -> PendingSignIn? {
        guard let text = Keychain.load(key: key) else { return nil }
        return try? JSONDecoder().decode(PendingSignIn.self, from: Data(text.utf8))
    }

    /// One use: a callback consumes the sign-in whether it succeeds or not.
    static func clear() {
        Keychain.delete(key: key)
    }
}
