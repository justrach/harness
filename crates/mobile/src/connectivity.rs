//! Connectivity truth, a port of the iOS `ConnectivityCenter` (itself the engine's `compute_connectivity` plus
//! `DegradeGrace`). One graced stream feeds every screen: a source must be degraded for 4 s without a break before it
//! reports degraded, so sub-second blips (a room joining on navigation, an idle link waking) never flash the UI, while
//! recovery reports at once. The sources keep their own timers: the OS network path, the registry room, and each chat
//! room that has dialed.

use std::collections::{HashMap, HashSet};

/// doc_host.rs DEGRADE_GRACE.
pub const DEGRADE_GRACE_MS: i64 = 4_000;
/// Sampling cadence while anything is degraded, graced or pending: the grace and elapsed-based states need it.
pub const BUSY_TICK_MS: u64 = 1_000;
/// A healthy idle app has nothing to time; a drop is noticed up to 5 s later and still shows only after the grace.
pub const IDLE_TICK_MS: u64 = 5_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectivityState {
    /// The OS network path is definitively down: sends are saved locally.
    Offline,
    /// The registry room is down while the path looks fine.
    Reconnecting,
    Connected,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConnectivitySnapshot {
    pub state: ConnectivityState,
    /// Chats whose room is degraded past the grace (only rooms that have dialed).
    pub degraded_chats: Vec<String>,
    /// The soonest redial among the registry and the open rooms, epoch ms.
    pub retry_at_ms: Option<i64>,
}

/// One sample of every raw source.
pub struct Sample {
    pub now: i64,
    pub path_offline: bool,
    pub registry_connected: bool,
    pub registry_retry_at: Option<i64>,
    /// (chat id, room connected, its next redial) for every room that has dialed.
    pub rooms: Vec<(String, bool, Option<i64>)>,
    pub pending_sends: bool,
}

#[derive(Default)]
pub struct Connectivity {
    /// Source key to when it first sampled degraded. Absent means healthy.
    degraded_since: HashMap<String, i64>,
}

impl Connectivity {
    fn graced(&mut self, key: &str, raw: bool, now: i64) -> bool {
        if !raw {
            self.degraded_since.remove(key);
            return false;
        }
        match self.degraded_since.get(key) {
            None => {
                self.degraded_since.insert(key.to_owned(), now);
                false
            }
            Some(since) => now - since >= DEGRADE_GRACE_MS,
        }
    }

    /// The graced state for this sample, and whether anything still needs the busy cadence.
    pub fn recompute(&mut self, sample: &Sample) -> (ConnectivitySnapshot, bool) {
        let now = sample.now;
        let offline = self.graced("os", sample.path_offline, now);
        let registry_down = self.graced("registry", !sample.registry_connected, now);
        let mut live: HashSet<String> = ["os".to_owned(), "registry".to_owned()].into();
        let mut degraded = Vec::new();
        let mut retry_at = sample.registry_retry_at;
        for (id, connected, room_retry) in &sample.rooms {
            let key = format!("chat:{id}");
            if self.graced(&key, !connected, now) {
                degraded.push(id.clone());
            }
            live.insert(key);
            if let Some(at) = room_retry
                && retry_at.is_none_or(|current| *at < current)
            {
                retry_at = Some(*at);
            }
        }
        // Rooms that closed take their timers with them.
        self.degraded_since.retain(|key, _| live.contains(key));
        degraded.sort();
        let state = if offline {
            ConnectivityState::Offline
        } else if registry_down {
            ConnectivityState::Reconnecting
        } else {
            ConnectivityState::Connected
        };
        let busy = state != ConnectivityState::Connected
            || !degraded.is_empty()
            || !self.degraded_since.is_empty()
            || sample.pending_sends;
        (
            ConnectivitySnapshot {
                state,
                degraded_chats: degraded,
                retry_at_ms: retry_at,
            },
            busy,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(now: i64, path_offline: bool, registry: bool, rooms: Vec<(&str, bool)>) -> Sample {
        Sample {
            now,
            path_offline,
            registry_connected: registry,
            registry_retry_at: None,
            rooms: rooms
                .into_iter()
                .map(|(id, c)| (id.to_owned(), c, None))
                .collect(),
            pending_sends: false,
        }
    }

    #[test]
    fn a_blip_shorter_than_the_grace_never_shows() {
        let mut c = Connectivity::default();
        assert_eq!(
            c.recompute(&sample(0, false, false, vec![])).0.state,
            ConnectivityState::Connected
        );
        assert_eq!(
            c.recompute(&sample(3_999, false, false, vec![])).0.state,
            ConnectivityState::Connected
        );
        assert_eq!(
            c.recompute(&sample(4_500, false, true, vec![])).0.state,
            ConnectivityState::Connected
        );
    }

    #[test]
    fn a_registry_down_past_the_grace_reads_reconnecting_and_recovery_is_instant() {
        let mut c = Connectivity::default();
        c.recompute(&sample(0, false, false, vec![]));
        let (snapshot, busy) = c.recompute(&sample(4_000, false, false, vec![]));
        assert_eq!(snapshot.state, ConnectivityState::Reconnecting);
        assert!(busy);
        let (snapshot, busy) = c.recompute(&sample(4_100, false, true, vec![]));
        assert_eq!(snapshot.state, ConnectivityState::Connected);
        assert!(!busy, "a healthy idle app drops to the idle cadence");
    }

    #[test]
    fn an_offline_path_wins_over_a_down_registry() {
        let mut c = Connectivity::default();
        c.recompute(&sample(0, true, false, vec![]));
        assert_eq!(
            c.recompute(&sample(5_000, true, false, vec![])).0.state,
            ConnectivityState::Offline
        );
    }

    #[test]
    fn each_room_keeps_its_own_timer_and_a_closed_room_forgets_it() {
        let mut c = Connectivity::default();
        c.recompute(&sample(0, false, true, vec![("a", false)]));
        c.recompute(&sample(
            2_000,
            false,
            true,
            vec![("a", false), ("b", false)],
        ));
        let (snapshot, _) = c.recompute(&sample(
            4_000,
            false,
            true,
            vec![("a", false), ("b", false)],
        ));
        assert_eq!(snapshot.degraded_chats, vec!["a"]);
        assert_eq!(
            snapshot.state,
            ConnectivityState::Connected,
            "a room alone never changes the app state"
        );
        c.recompute(&sample(5_000, false, true, vec![("b", false)]));
        let (snapshot, _) = c.recompute(&sample(
            9_000,
            false,
            true,
            vec![("a", false), ("b", false)],
        ));
        assert_eq!(
            snapshot.degraded_chats,
            vec!["b"],
            "a reopened room starts a fresh grace"
        );
    }

    #[test]
    fn the_soonest_redial_is_reported() {
        let mut c = Connectivity::default();
        let mut s = sample(0, false, false, vec![]);
        s.registry_retry_at = Some(900);
        s.rooms = vec![
            ("a".into(), false, Some(500)),
            ("b".into(), false, Some(700)),
        ];
        assert_eq!(c.recompute(&s).0.retry_at_ms, Some(500));
    }
}
