// What the phone may say about another device, from the presence beats it has received. Pure Foundation, so
// every threshold is unit-testable without a socket or a clock.
//
// Beats arrive every 15s and are timed from RECEIPT (they carry the sender's wall clock, which is never
// trusted for freshness). Three answers, because two would lie:
//   - online:  a beat arrived in the last 45s.
//   - offline: POSITIVE evidence of absence: a joined, warmed-up registry room and nothing heard for 5 min.
//   - unknown: everything else: a phone that just launched, a socket that is redialling, a gap of a minute.
// "Unknown" must never be shown as "offline": a running host reads as offline until its next beat otherwise.

import Foundation

enum HostStatus: Equatable, Sendable {
    case online
    case unknown
    case offline
}

enum PresenceRule {
    /// workspace_host.rs PRESENCE_FRESH_MS / DIAL_GATE_DARK_MS / DIAL_GATE_WARMUP_MS (PR #168).
    static let liveFreshMs: Int64 = 45_000
    static let darkMs: Int64 = 5 * 60_000
    static let warmupMs: Int64 = 60_000

    /// The dial-gate verdict. `dark` needs a connected, warmed-up registry room; every ambiguity stays
    /// `unknown`, so a rows-down/relay-up incident can never park the relay.
    static func liveness(now: Int64, received: Int64?, connected: Bool, joinedAt: Int64?,
                         rowLastSeen: Int64?) -> PeerLiveness {
        guard connected, let joinedAt else { return .unknown }
        if let received {
            if now - received < liveFreshMs { return .live }
            if now - received >= darkMs { return .dark }
            return .unknown
        }
        // Never heard this session: only a warmed-up room may consult the durable device row's own stamp.
        guard now - joinedAt >= warmupMs else { return .unknown }
        if let rowLastSeen, now - rowLastSeen >= darkMs { return .dark }
        return .unknown
    }

    /// What the screens show. A beat in the last 45s is online whether or not the socket is up right now
    /// (the beat is the evidence); `offline` is only ever the dial gate's `dark`.
    static func status(now: Int64, received: Int64?, connected: Bool, joinedAt: Int64?,
                       rowLastSeen: Int64?) -> HostStatus {
        if let received, now - received < liveFreshMs { return .online }
        let verdict = liveness(now: now, received: received, connected: connected, joinedAt: joinedAt,
                               rowLastSeen: rowLastSeen)
        return verdict == .dark ? .offline : .unknown
    }

    /// The next instant at which `status` can change by the clock alone, so a screen needs ONE wake-up at
    /// that time instead of a ticking timer. nil when only a new beat or a reconnect could change it.
    static func nextChange(after now: Int64, received: Int64?, connected: Bool, joinedAt: Int64?,
                           rowLastSeen: Int64?) -> Int64? {
        var candidates: [Int64] = []
        if let received {
            candidates.append(received + liveFreshMs)
            if connected, joinedAt != nil { candidates.append(received + darkMs) }
        } else if connected, let joinedAt {
            candidates.append(joinedAt + warmupMs)
            if let rowLastSeen { candidates.append(rowLastSeen + darkMs) }
        }
        return candidates.filter { $0 > now }.min()
    }
}
