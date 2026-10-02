// The plain-words state of the phone's connection, for Settings → Connection: is the sign-in alive, is the
// registry socket up, and what has each device's last beat said. Pure values and formatting, so the screen is
// a thin list and the wording is unit-tested. It holds no tokens — only expiry times and outcomes.

import Foundation

struct ConnectionReport: Equatable {
    struct Device: Equatable {
        var name: String
        var isThisPhone: Bool
        var status: HostStatus
        /// Seconds since the last beat from this device arrived; nil = none heard this session.
        var beatAgeSeconds: Int?
    }

    var auth: AppConfig.AuthDiagnostics?
    var registryConnected: Bool
    var registrySynced: Bool
    /// Seconds until the next redial while disconnected; nil when connected or unknown.
    var retryInSeconds: Int?
    var devices: [Device]

    /// "5s", "3 min", "2 h" — coarse on purpose; this is a status line, not a stopwatch.
    static func span(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60) min" }
        return "\(s / 3_600) h"
    }

    var signIn: String {
        guard let auth else { return "No account" }
        if auth.rejected { return "Signed out — sign in again" }
        return auth.signedIn ? "Signed in" : "Signed out"
    }

    func accessToken(now: Date) -> String {
        guard let expires = auth?.accessExpiresAt else { return "—" }
        let seconds = Int(expires.timeIntervalSince(now))
        return seconds >= 0 ? "Renews in \(Self.span(seconds))" : "Expired \(Self.span(-seconds)) ago"
    }

    func lastRefresh(now: Date) -> String {
        guard let at = auth?.lastRefreshAt, let outcome = auth?.lastRefreshOutcome else { return "None this session" }
        return "\(outcome.prefix(1).uppercased() + outcome.dropFirst()), \(Self.span(Int(now.timeIntervalSince(at)))) ago"
    }

    var registry: String {
        if registryConnected { return "Connected" }
        if let retryInSeconds { return "Reconnecting in \(retryInSeconds)s" }
        return registrySynced ? "Offline — using the last sync" : "Connecting…"
    }

    static func deviceLine(_ device: Device) -> String {
        let status: String
        switch device.status {
        case .online: status = "Online"
        case .offline: status = "Offline"
        case .unknown: status = "Not confirmed"
        }
        guard let age = device.beatAgeSeconds else { return "\(status) · no beat yet" }
        return "\(status) · last beat \(span(age)) ago"
    }

    /// The same facts as one block of text, for the Copy button.
    func text(now: Date = Date()) -> String {
        var lines = ["Sign-in: \(signIn)",
                     "Access token: \(accessToken(now: now))",
                     "Last refresh: \(lastRefresh(now: now))",
                     "Registry: \(registry)"]
        lines += devices.map { "\($0.isThisPhone ? "This phone" : $0.name): \(Self.deviceLine($0))" }
        return lines.joined(separator: "\n")
    }
}
