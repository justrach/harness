//! In-chat ChatGPT reconnect: one recovery per execution host and route, shared by every
//! transcript that shows a typed sign-in error for it.
//!
//! The engine coalesces explicit recoveries per host, route and account, so a second chat (or the
//! phone) attaches to the approval already waiting instead of cancelling it. This side keeps the
//! matching phase so every card for that host and route shows the same step. Only an explicit
//! Cancel ends a pending approval; switching chats or panes only stops showing it.
//!
//! Nothing here replays a failed prompt or a tool. After the host verifies the sign-in, the card
//! that asked offers "Resume conversation": a new turn in the same chat, sent only when clicked.

use std::collections::{HashMap, HashSet};

use harness_proto::{AgentLoginMode, AgentLoginStart, HarnessId, ReauthProvider};

/// What the user asked a card to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReauthAction {
    /// Start the recovery, or attach to the one already waiting on that host.
    Reconnect,
    /// End the pending approval for everyone waiting on it.
    Cancel,
    /// Start again after a failure.
    Retry,
    /// Continue the same chat with a new turn, once reconnected.
    Resume,
}

/// One recovery: the chat's execution host and the sign-in route.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ReauthKey {
    pub host: String,
    pub provider: ReauthProvider,
}

/// One error row: the chat and the row's stable id.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ReauthRow {
    pub chat_id: String,
    pub row_id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RecoveryPhase {
    Starting,
    Waiting {
        start: AgentLoginStart,
        /// The host's latest progress line, when it sends one.
        message: Option<String>,
    },
    Failed(String),
    /// The host verified the renewed sign-in.
    Reconnected,
}

/// Recoveries in this window, plus the rows they resolved. Memory only: a restart shows the card's
/// first step again, and the engine attaches to any approval still waiting.
#[derive(Debug, Default)]
pub struct ReauthRecoveries {
    pub phases: HashMap<ReauthKey, RecoveryPhase>,
    /// The rows that asked for each recovery: all of them resolve when it succeeds.
    pub requesters: HashMap<ReauthKey, HashSet<ReauthRow>>,
    /// Rows whose recovery succeeded.
    pub resolved: HashSet<ReauthRow>,
    /// Rows whose Resume was sent (or is being sent), so a second click does nothing.
    pub resumed: HashSet<ReauthRow>,
    /// Start attempts per recovery, so a start that returns after Cancel (or after a newer attempt)
    /// knows it is no longer the current one.
    pub attempts: HashMap<ReauthKey, u64>,
    /// Bumped on every change, so transcripts remeasure their recovery rows.
    pub generation: u64,
}

impl ReauthRecoveries {
    pub fn phase(&self, key: &ReauthKey) -> Option<&RecoveryPhase> {
        self.phases.get(key)
    }

    /// A new demand for `key` from `row`. `true` when a recovery has to start; `false` when one is
    /// already starting or waiting (the row attaches to it).
    pub fn request(&mut self, key: &ReauthKey, row: ReauthRow) -> bool {
        self.requesters.entry(key.clone()).or_default().insert(row);
        let starts = !matches!(
            self.phases.get(key),
            Some(RecoveryPhase::Starting | RecoveryPhase::Waiting { .. })
        );
        if starts {
            self.phases.insert(key.clone(), RecoveryPhase::Starting);
            *self.attempts.entry(key.clone()).or_default() += 1;
        }
        self.generation += 1;
        starts
    }

    /// The current start attempt for `key`.
    pub fn attempt(&self, key: &ReauthKey) -> u64 {
        self.attempts.get(key).copied().unwrap_or(0)
    }

    /// Still the current start for `key`: nobody cancelled it and no newer attempt replaced it.
    pub fn starting(&self, key: &ReauthKey, attempt: u64) -> bool {
        self.attempt(key) == attempt && self.phases.get(key) == Some(&RecoveryPhase::Starting)
    }

    /// Reconnected resolves exactly the rows that asked, then clears the host's phase: a sign-in
    /// error that arrives later for the same host is a new failure, not an already fixed one.
    pub fn set(&mut self, key: &ReauthKey, phase: RecoveryPhase) {
        if phase == RecoveryPhase::Reconnected {
            if let Some(rows) = self.requesters.remove(key) {
                self.resolved.extend(rows);
            }
            self.phases.remove(key);
        } else {
            self.phases.insert(key.clone(), phase);
        }
        self.generation += 1;
    }

    /// Cancel or a failed start: the cards go back to their first step.
    pub fn clear(&mut self, key: &ReauthKey) {
        self.phases.remove(key);
        self.requesters.remove(key);
        self.generation += 1;
    }

    /// The pending login for `key`, for Cancel and polling.
    pub fn login_id(&self, key: &ReauthKey) -> Option<String> {
        match self.phases.get(key) {
            Some(RecoveryPhase::Waiting { start, .. }) => Some(start.login_id.clone()),
            _ => None,
        }
    }

    /// Reconnected: this row asked for a recovery that the host verified. Exactly the rows
    /// `card_step` offers Resume on.
    pub fn reconnected(&self, row: &ReauthRow) -> bool {
        self.resolved.contains(row)
    }

    /// Claim a row's one Resume. `false` when the row isn't reconnected or was already claimed.
    pub fn claim_resume(&mut self, row: &ReauthRow) -> bool {
        if !self.reconnected(row) || !self.resumed.insert(row.clone()) {
            return false;
        }
        self.generation += 1;
        true
    }

    /// A Resume that could not be sent: the row offers it again.
    pub fn release_resume(&mut self, row: &ReauthRow) {
        if self.resumed.remove(row) {
            self.generation += 1;
        }
    }
}

/// The StartAgentLogin call for a recovery route: Codex device authorization (approvable from a
/// phone) or the ChatGPT route's host-browser sign-in.
pub fn route(provider: ReauthProvider) -> (HarnessId, Option<&'static str>) {
    match provider {
        ReauthProvider::ChatgptNew => (HarnessId::Graff, Some("chatgpt-new")),
        ReauthProvider::Codex => (HarnessId::Codex, None),
    }
}

pub fn start_params(provider: ReauthProvider, host: &str) -> serde_json::Value {
    let (harness, sign_in) = route(provider);
    let mut params = serde_json::json!({
        "harness": harness,
        "reauthenticate": true,
        "targetDeviceId": host,
    });
    if harness == HarnessId::Codex {
        params["deviceAuth"] = serde_json::json!(true);
    }
    if let Some(sign_in) = sign_in {
        params["provider"] = serde_json::json!(sign_in);
    }
    params
}

/// Only the two shapes recovery supports: a safe device code for Codex, and an empty host-browser
/// start for the ChatGPT route (its URL and callback stay on the host). Anything else is an older
/// or different host, and its start is cancelled.
pub fn start_supported(provider: ReauthProvider, start: &AgentLoginStart) -> bool {
    match provider {
        ReauthProvider::Codex => start.is_safe_device_code(),
        ReauthProvider::ChatgptNew => {
            start.mode == AgentLoginMode::HostBrowser
                && start.url.is_empty()
                && start.code.is_none()
                && !start.login_id.is_empty()
        }
    }
}

/// The new turn Resume sends: a continuation, never the failed prompt.
pub const RESUME_PROMPT: &str = "Continue where you left off. The previous turn stopped because \
ChatGPT needed reconnecting; it is connected again now.";

/// Shown with the first steps. Harness has no signal for either case, so it never says one applies,
/// and it never suggests turning account security off.
pub const ACCOUNT_SECURITY_NOTE: &str = "If you recently reset your password or enrolled in \
Advanced Account Security (including Daybreak), ChatGPT may ask you to sign in again.";

/// What a card shows.
#[derive(Debug, Clone, PartialEq)]
pub enum CardStep {
    /// Reconnect ChatGPT on the host.
    Offer,
    Starting,
    /// Waiting for approval: a device code to enter, or the host's own browser.
    Waiting {
        code: Option<String>,
        url: String,
        message: Option<String>,
    },
    Failed(String),
    /// Reconnected. `resume` says what the Resume button can do.
    Reconnected {
        resume: ResumeState,
    },
    /// An error from earlier in the conversation: the chat has moved on, so no action.
    Earlier,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumeState {
    Ready,
    /// A turn is running in this chat.
    Busy,
    /// The chat has no stored agent and model, so resuming could fall back to a default one.
    Unavailable,
    Sent,
}

/// Pure: the step a card shows. `later_activity` = the chat has a message after this error, so the
/// error is history (that is also how a sent Resume stops being offered again). `has_config` = the
/// chat has a stored agent AND model, so a resume never falls back to a default.
pub fn card_step(
    recoveries: &ReauthRecoveries,
    key: &ReauthKey,
    row: &ReauthRow,
    later_activity: bool,
    running: bool,
    has_config: bool,
) -> CardStep {
    if recoveries.reconnected(row) {
        let resume = if recoveries.resumed.contains(row) || later_activity {
            ResumeState::Sent
        } else if !has_config {
            ResumeState::Unavailable
        } else if running {
            ResumeState::Busy
        } else {
            ResumeState::Ready
        };
        return CardStep::Reconnected { resume };
    }
    if later_activity {
        return CardStep::Earlier;
    }
    match recoveries.phase(key) {
        None => CardStep::Offer,
        Some(RecoveryPhase::Starting) => CardStep::Starting,
        Some(RecoveryPhase::Waiting { start, message }) => CardStep::Waiting {
            code: start.code.clone(),
            url: start.url.clone(),
            message: message.clone(),
        },
        Some(RecoveryPhase::Failed(message)) => CardStep::Failed(message.clone()),
        // Never stored (see `set`); a row that did not ask starts its own recovery.
        Some(RecoveryPhase::Reconnected) => CardStep::Offer,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(host: &str) -> ReauthKey {
        ReauthKey {
            host: host.into(),
            provider: ReauthProvider::ChatgptNew,
        }
    }

    fn row(chat: &str) -> ReauthRow {
        ReauthRow {
            chat_id: chat.into(),
            row_id: format!("{chat}-error"),
        }
    }

    fn waiting() -> RecoveryPhase {
        RecoveryPhase::Waiting {
            start: AgentLoginStart {
                login_id: "login-1".into(),
                url: String::new(),
                mode: AgentLoginMode::HostBrowser,
                code: None,
            },
            message: None,
        }
    }

    #[test]
    fn a_second_demand_attaches_instead_of_starting_again() {
        let mut r = ReauthRecoveries::default();
        assert!(
            r.request(&key("studio"), row("a")),
            "the first demand starts"
        );
        r.set(&key("studio"), waiting());
        assert!(
            !r.request(&key("studio"), row("b")),
            "another chat attaches"
        );
        assert!(
            !r.request(&key("studio"), row("a")),
            "a double click attaches"
        );
        assert_eq!(r.login_id(&key("studio")).as_deref(), Some("login-1"));
        assert!(
            r.request(&key("laptop"), row("c")),
            "another host is its own recovery"
        );
    }

    #[test]
    fn success_resolves_every_row_that_asked_and_resume_is_claimed_once() {
        let mut r = ReauthRecoveries::default();
        r.request(&key("studio"), row("a"));
        r.request(&key("studio"), row("b"));
        r.set(&key("studio"), RecoveryPhase::Reconnected);
        for chat in ["a", "b"] {
            assert_eq!(
                card_step(&r, &key("studio"), &row(chat), false, false, true),
                CardStep::Reconnected {
                    resume: ResumeState::Ready
                }
            );
        }
        assert!(r.claim_resume(&row("a")));
        assert!(!r.claim_resume(&row("a")), "a second click sends nothing");
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, false, true),
            CardStep::Reconnected {
                resume: ResumeState::Sent
            }
        );
        r.release_resume(&row("a"));
        assert!(r.claim_resume(&row("a")), "a failed send can be retried");
        // A row that never asked is not offered Resume (its click could do nothing), and a sign-in
        // error that arrives later for this host is a new failure, not an already fixed one.
        assert_eq!(
            card_step(&r, &key("studio"), &row("z"), false, false, true),
            CardStep::Offer
        );
        assert!(!r.claim_resume(&row("z")));
    }

    #[test]
    fn resume_waits_for_a_running_turn_and_never_guesses_an_agent() {
        let mut r = ReauthRecoveries::default();
        r.request(&key("studio"), row("a"));
        r.set(&key("studio"), RecoveryPhase::Reconnected);
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, true, true),
            CardStep::Reconnected {
                resume: ResumeState::Busy
            }
        );
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, false, false),
            CardStep::Reconnected {
                resume: ResumeState::Unavailable
            }
        );
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), true, false, true),
            CardStep::Reconnected {
                resume: ResumeState::Sent
            },
            "a message after the error means the conversation already moved on"
        );
    }

    #[test]
    fn earlier_errors_offer_nothing_and_cancel_returns_to_the_first_step() {
        let mut r = ReauthRecoveries::default();
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), true, false, true),
            CardStep::Earlier
        );
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, false, true),
            CardStep::Offer
        );
        r.request(&key("studio"), row("a"));
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, false, true),
            CardStep::Starting
        );
        r.set(&key("studio"), waiting());
        assert!(matches!(
            card_step(&r, &key("studio"), &row("a"), false, false, true),
            CardStep::Waiting { code: None, .. }
        ));
        r.set(
            &key("studio"),
            RecoveryPhase::Failed("Sign-in timed out".into()),
        );
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, false, true),
            CardStep::Failed("Sign-in timed out".into())
        );
        let before = r.attempt(&key("studio"));
        assert!(r.request(&key("studio"), row("a")), "Retry starts again");
        let attempt = r.attempt(&key("studio"));
        assert_eq!(attempt, before + 1);
        assert!(r.starting(&key("studio"), attempt));
        r.clear(&key("studio"));
        assert!(
            !r.starting(&key("studio"), attempt),
            "a start that returns after Cancel knows it was cancelled"
        );
        assert!(r.request(&key("studio"), row("a")));
        assert!(
            !r.starting(&key("studio"), attempt),
            "and a newer attempt replaces it"
        );
        r.clear(&key("studio"));
        assert_eq!(
            card_step(&r, &key("studio"), &row("a"), false, false, true),
            CardStep::Offer
        );
    }

    #[test]
    fn routes_and_supported_starts() {
        assert_eq!(
            start_params(ReauthProvider::ChatgptNew, "studio"),
            serde_json::json!({"harness": "graff", "provider": "chatgpt-new",
                "reauthenticate": true, "targetDeviceId": "studio"})
        );
        assert_eq!(
            start_params(ReauthProvider::Codex, "studio"),
            serde_json::json!({"harness": "codex", "reauthenticate": true,
                "deviceAuth": true, "targetDeviceId": "studio"})
        );
        let host_browser = AgentLoginStart {
            login_id: "l".into(),
            url: String::new(),
            mode: AgentLoginMode::HostBrowser,
            code: None,
        };
        assert!(start_supported(ReauthProvider::ChatgptNew, &host_browser));
        assert!(
            !start_supported(ReauthProvider::Codex, &host_browser),
            "Codex recovery needs a device code"
        );
        let leaks_url = AgentLoginStart {
            url: "https://auth.example/authorize?id_token_hint=x".into(),
            ..host_browser
        };
        assert!(
            !start_supported(ReauthProvider::ChatgptNew, &leaks_url),
            "the ChatGPT route keeps its URL on the host"
        );
    }
}
