//! What the phone may say about another device, from the presence beats it has received: a port of the iOS
//! `PresenceRule` (workspace_host.rs dial-gate constants). Beats arrive every 15 s and are timed from receipt (the
//! sender's wall clock is never trusted for freshness). Three answers, because two would lie:
//!
//! - online: a beat arrived in the last 45 s;
//! - offline: positive evidence of absence, meaning a joined, warmed-up registry room and nothing heard for 5 min;
//! - unknown: everything else (a phone that just launched, a socket that is redialing, a gap of a minute).
//!
//! "Unknown" is never shown as "offline": a running host would read as offline until its next beat.

pub const LIVE_FRESH_MS: i64 = 45_000;
pub const DARK_MS: i64 = 5 * 60_000;
pub const WARMUP_MS: i64 = 60_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HostStatus {
    Online,
    Unknown,
    Offline,
}

/// The dial gate's verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PeerLivenessRecord {
    Live,
    Dark,
    Unknown,
}

/// What the rule needs to know about one device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PresenceInput {
    pub now: i64,
    /// When this session last received a beat from the device.
    pub received: Option<i64>,
    /// The registry room is joined.
    pub connected: bool,
    /// When the registry room (re)joined.
    pub joined_at: Option<i64>,
    /// The device row's own `lastSeenAt`.
    pub row_last_seen: Option<i64>,
}

/// `dark` needs a connected, warmed-up registry room; every ambiguity stays `unknown`, so a rows-down/relay-up
/// incident can never park the relay.
#[uniffi::export]
pub fn presence_liveness(input: PresenceInput) -> PeerLivenessRecord {
    let PresenceInput {
        now,
        received,
        connected,
        joined_at,
        row_last_seen,
    } = input;
    let Some(joined_at) = joined_at.filter(|_| connected) else {
        return PeerLivenessRecord::Unknown;
    };
    if let Some(received) = received {
        if now - received < LIVE_FRESH_MS {
            return PeerLivenessRecord::Live;
        }
        if now - received >= DARK_MS {
            return PeerLivenessRecord::Dark;
        }
        return PeerLivenessRecord::Unknown;
    }
    // Never heard this session: only a warmed-up room may consult the durable row's own stamp.
    if now - joined_at < WARMUP_MS {
        return PeerLivenessRecord::Unknown;
    }
    if row_last_seen.is_some_and(|seen| now - seen >= DARK_MS) {
        return PeerLivenessRecord::Dark;
    }
    PeerLivenessRecord::Unknown
}

/// What the screens show. A beat in the last 45 s is online whether or not the socket is up right now; offline is
/// only ever the dial gate's dark.
#[uniffi::export]
pub fn presence_status(input: PresenceInput) -> HostStatus {
    if input
        .received
        .is_some_and(|received| input.now - received < LIVE_FRESH_MS)
    {
        return HostStatus::Online;
    }
    if presence_liveness(input) == PeerLivenessRecord::Dark {
        HostStatus::Offline
    } else {
        HostStatus::Unknown
    }
}

/// The next instant at which the status can change by the clock alone, so one wake-up at that time replaces a
/// ticking timer. None when only a new beat or a reconnect could change it.
#[uniffi::export]
pub fn presence_next_change(input: PresenceInput) -> Option<i64> {
    let mut candidates = Vec::new();
    if let Some(received) = input.received {
        candidates.push(received + LIVE_FRESH_MS);
        if input.connected && input.joined_at.is_some() {
            candidates.push(received + DARK_MS);
        }
    } else if let (true, Some(joined_at)) = (input.connected, input.joined_at) {
        candidates.push(joined_at + WARMUP_MS);
        if let Some(seen) = input.row_last_seen {
            candidates.push(seen + DARK_MS);
        }
    }
    candidates.into_iter().filter(|&at| at > input.now).min()
}
