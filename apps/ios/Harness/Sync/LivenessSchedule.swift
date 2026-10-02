// How long a room's liveness loop may sleep before it has to look again. Pure Foundation, so the cadence is
// unit-tested without a socket.
//
// The loop polices hard deadlines (hello 15s, probe 10s, backfill) and sends a probe after 15 quiet minutes.
// Deadlines need about a second of resolution, but only while one is actually pending. A healthy idle room has
// none, so it used to wake every second for nothing, once per open room. Now it sleeps until the quiet-probe
// time (capped at a minute as a safety net), and the room re-arms the loop the moment it sets a deadline.

import Foundation

enum LivenessSchedule {
    /// Resolution while a deadline is pending: exactly the cadence the loop always had.
    static let pendingTickNs: UInt64 = 1_000_000_000
    /// The longest an idle room sleeps. A safety net only: every deadline re-arms the loop itself.
    static let idleCapNs: UInt64 = 60_000_000_000

    static func waitNs(pending: Bool, joined: Bool, quietForNs: UInt64, probeQuietNs: UInt64) -> UInt64 {
        if pending { return pendingTickNs }
        guard joined else { return idleCapNs }
        let untilQuiet = probeQuietNs > quietForNs ? probeQuietNs - quietForNs : pendingTickNs
        return min(max(untilQuiet, pendingTickNs), idleCapNs)
    }
}
