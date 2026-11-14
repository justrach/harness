// Connectivity truth — the iOS port of the engine's compute_connectivity +
// DegradeGrace (crates/engine/src/doc_host.rs, PRs #168/#170) and the UI's
// send-status derivations (crates/ui/src/state.rs).
//
// One graced stream feeds every consumer (home pill, composer notice, row
// Queued/Failed badges): a source must be RAW-degraded for 4s continuously
// before it reports degraded — sub-second blips (room joins on navigation,
// idle-link wakes) never flash the UI — while recovery reports instantly
// (hide-fast, show-slow). Sources are independent: the OS path, the registry
// room, and each open chat room keep their own timers.

import Foundation
import Observation

enum ConnectivityState: Equatable {
    /// The OS path is definitively down (graced): sends are saved locally.
    case offline
    /// The registry room is down (graced) while the path looks fine.
    case reconnecting
    case connected
}

/// A pending send's user-visible truth (state.rs send_pending/send_queued/
/// send_undelivered).
enum SendState {
    case sending
    case queued
    /// Unadopted past the grace, but its command is still pending in the doc
    /// and can run whenever the host picks it up (#413). Not a failure.
    case waiting
    /// No command for the send can run any more: the host rejected or
    /// expired it, or it outlived its TTL. Retry re-issues it.
    case failed

    /// `failed` needs the doc's word that the send can't run; the grace
    /// alone only turns Sending into Waiting. A degraded path reads Queued.
    static func of(oldestStarted: Int64, undeliverable: Bool, degraded: Bool,
                   now: Int64) -> SendState {
        if undeliverable { return .failed }
        if degraded { return .queued }
        if now - oldestStarted > undeliveredGraceMs { return .waiting }
        return .sending
    }

    /// Distinguishes phone-side offline ("Phone is offline — waiting for connection")
    /// from host-side offline / waiting for pickup.
    static func waitingStatusCopy(
        hostName: String,
        phoneOnline: Bool,
        hostOffline: Bool = false,
        hasAttachments: Bool = false
    ) -> String {
        if !phoneOnline {
            return "Phone is offline — waiting for connection"
        }
        if hostOffline {
            return "\(hostName) is offline — will send when it reconnects"
        }
        return hasAttachments
            ? "Attachments still on their way to \(hostName)"
            : "Waiting for \(hostName) to start it"
    }
}

/// state.rs UNDELIVERED_GRACE_MS: a send unadopted past this stops reading
/// "Sending…" and says it is waiting for the host, never a forever-spinner.
let undeliveredGraceMs: Int64 = 120_000

/// transcript.rs TURN_WAIT_SHOWN_SECS / turn_wait_secs: how long the running
/// turn's prompt waited before the turn began, when it is worth showing. The
/// timer counts the run only; nil unless the last user entry started the turn.
let turnWaitShownSecs: Int64 = 60

func turnWaitSecs(entries: [MessageEntry], turnStartedAt: Int64?) -> Int64? {
    guard let started = turnStartedAt,
          let prompt = entries.lastIndex(where: { $0.role == .user }) else { return nil }
    if entries[(prompt + 1)...].contains(where: { $0.createdAt < started }) { return nil }
    let waited = (started - entries[prompt].createdAt) / 1000
    return waited >= turnWaitShownSecs ? waited : nil
}

@MainActor
@Observable
final class ConnectivityCenter {
    /// doc_host.rs DEGRADE_GRACE (PR #170).
    static let degradeGraceMs: Int64 = 4_000

    private(set) var state: ConnectivityState = .connected
    /// Chat ids whose room is graced-degraded (only rooms that have dialed).
    private(set) var degradedChats: Set<String> = []
    private(set) var retryAt: Date?
    /// 1Hz pulse, bumped only while something is degraded or a send is
    /// pending — views showing elapsed-based send states read it to
    /// subscribe; a healthy idle app never repaints on it.
    private(set) var pulse: UInt64 = 0

    /// Raw-source providers, wired by AppModel (poll-based, mirroring the
    /// engine's 1s recompute over in-memory stats).
    @ObservationIgnored var registryConnected: (() -> Bool)?
    @ObservationIgnored var chatRooms: (() -> [(id: String, connected: Bool, retryAt: Date?)])?
    @ObservationIgnored var registryRetryAt: (() -> Date?)?
    @ObservationIgnored var hasPendingSends: (() -> Bool)?

    @ObservationIgnored private var pathOffline = false
    /// Source key → when it first sampled raw-degraded (ms). Absent = healthy.
    @ObservationIgnored private var degradedSince: [String: Int64] = [:]
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// Sampling cadence. While anything is degraded, graced or pending the 4s grace and the elapsed-based
    /// send states need the original 1s samples. A healthy idle app has nothing to time, so it looks every
    /// 5s: a drop is noticed up to 5s later, and the pill still only shows after the 4s grace.
    static let busyTick: Duration = .seconds(1)
    static let idleTick: Duration = .seconds(5)

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.recompute()
                try? await Task.sleep(for: busy ? Self.busyTick : Self.idleTick,
                                      tolerance: busy ? .milliseconds(200) : .seconds(1))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// The OS path flipped: sample now and drop to the busy cadence if that made anything degraded, instead
    /// of waiting out an idle sleep.
    func setPathOffline(_ offline: Bool) {
        pathOffline = offline
        if tickTask != nil {
            stop()
            start()
        } else {
            recompute()
        }
    }

    /// DegradeGrace: report degraded only once the raw state has persisted
    /// ≥ 4s; one healthy sample clears instantly.
    private func graced(_ key: String, raw: Bool, now: Int64) -> Bool {
        guard raw else {
            degradedSince[key] = nil
            return false
        }
        guard let since = degradedSince[key] else {
            degradedSince[key] = now
            return false
        }
        return now - since >= Self.degradeGraceMs
    }

    /// Returns whether anything still needs the 1s cadence (see `busyTick`).
    @discardableResult
    private func recompute() -> Bool {
        let now = nowMs()
        let offline = graced("os", raw: pathOffline, now: now)
        let registryDown = graced("registry", raw: !(registryConnected?() ?? true), now: now)

        var chats: Set<String> = []
        var liveKeys: Set<String> = ["os", "registry"]
        var nextRetryAt = registryRetryAt?()
        for room in chatRooms?() ?? [] {
            let key = "chat:\(room.id)"
            liveKeys.insert(key)
            if graced(key, raw: !room.connected, now: now) {
                chats.insert(room.id)
            }
            if let retryAt = room.retryAt, nextRetryAt.map({ retryAt < $0 }) ?? true {
                nextRetryAt = retryAt
            }
        }
        // Drop timers for rooms that closed (doc_host.rs retain_chats).
        if degradedSince.count > liveKeys.count {
            degradedSince = degradedSince.filter { liveKeys.contains($0.key) }
        }

        let newState: ConnectivityState = offline ? .offline
            : registryDown ? .reconnecting
            : .connected
        // Publish only on change — an idle connected app never invalidates.
        if newState != state { state = newState }
        if chats != degradedChats { degradedChats = chats }
        if retryAt != nextRetryAt { retryAt = nextRetryAt }
        let busy = newState != .connected || !chats.isEmpty || !degradedSince.isEmpty
            || (hasPendingSends?() ?? false)
        if busy {
            pulse &+= 1
        }
        return busy
    }
}
