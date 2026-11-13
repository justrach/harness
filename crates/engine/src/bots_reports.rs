//! The main bot hears back from the work it started.
//!
//! The main bot starts a piece of work as a chat in the project it belongs
//! to, and ends its turn. Nothing in a chat tells the chat that started it
//! what happened, so the engine does: when a chat the main bot's thread
//! started finishes a turn nobody typed, stops on a question, or fails, one
//! message goes into the main bot's thread saying which chat, where, and
//! what it last said. The main bot reports that to the user.
//!
//! What is reported is read from the live session rows, which already say
//! which turn last completed and whether a person or another chat asked for
//! it. A turn the user typed in that chat themselves is theirs and is not
//! reported. Only memory is kept: an engine that restarts reports nothing
//! from before it started, and the app's catch-up still shows it.
//!
//! A report starts a turn of the main bot, and that turn can start more
//! work, whose report starts another. Three rules keep that from running on
//! by itself: a chat started while the main bot was answering a report is a
//! step further from what the user asked, and past [`MAX_STEPS`] it is not
//! reported; one chat is reported at most [`REPORTS_PER_HOUR`] times an
//! hour; and at most [`BURST`] reports go out in ten minutes.

use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use super::*;

/// A change older than this is not news: a session row can reappear with
/// an old marker when its chat is opened again.
const FRESH_SECS: i64 = 120;
/// At most this many reports about one chat in an hour. Two models that
/// keep answering each other stop here.
pub const REPORTS_PER_HOUR: usize = 4;
const HOUR: Duration = Duration::from_secs(3600);
/// Work the user asked for is step 1. Work started while the main bot was
/// answering a report about step n is step n + 1. Past this, nothing is
/// reported: a main bot that starts new work on every report stops here.
pub const MAX_STEPS: u32 = 3;
/// How long after a report a new chat counts as started in answer to it.
const ANSWER_SECS: i64 = 600;
/// At most this many reports in ten minutes, whatever they are about.
pub const BURST: usize = 20;
const BURST_SECS: i64 = 600;
/// How much of a chat's last words a report carries; `read_chat` has the rest.
const PREVIEW_CAP: usize = 600;

/// How a chat's session looked the last time it was looked at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Marker {
    pub turn: Option<String>,
    pub status: SessionStatus,
}

impl Marker {
    fn of(session: &Session) -> Self {
        Self {
            turn: session.last_completed_turn.clone(),
            status: session.status,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Finished,
    Waiting,
    Failed,
}

/// What changed in one session that the chat's starter should hear, if
/// anything. `before` is None for a session not seen yet.
pub fn outcome(
    before: Option<&Marker>,
    session: &Session,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<Outcome> {
    if now - session.updated_at > chrono::Duration::seconds(FRESH_SECS) {
        return None;
    }
    let was = before.map(|b| b.status);
    match session.status {
        SessionStatus::AwaitingInput if was != Some(SessionStatus::AwaitingInput) => {
            Some(Outcome::Waiting)
        }
        SessionStatus::Errored if was != Some(SessionStatus::Errored) => Some(Outcome::Failed),
        SessionStatus::AwaitingInput | SessionStatus::Errored => None,
        SessionStatus::Idle | SessionStatus::Working => {
            let turn = session.last_completed_turn.as_ref()?;
            let new = before.is_none_or(|b| b.turn.as_ref() != Some(turn));
            // A turn a person typed there is theirs to read, not the main bot's.
            (new && session.last_completed_peer_only).then_some(Outcome::Finished)
        }
    }
}

/// What the reporter remembers between looks.
#[derive(Default)]
pub struct Reports {
    /// False until the first look: what was already so is not news.
    primed: bool,
    seen: HashMap<(String, String), Marker>,
    sent: HashMap<String, VecDeque<Instant>>,
    /// The reports of the last hour: when, and which step each was about.
    log: VecDeque<(chrono::DateTime<chrono::Utc>, u32)>,
}

impl Reports {
    /// The sessions that changed in a way worth reporting since the last
    /// look, and remember how they all look now.
    pub fn changed(
        &mut self,
        sessions: &[Session],
        now: chrono::DateTime<chrono::Utc>,
    ) -> Vec<(String, Outcome)> {
        let mut out = Vec::new();
        for session in sessions {
            let key = (session.chat_id.clone(), session.device_id.clone());
            if self.primed
                && let Some(what) = outcome(self.seen.get(&key), session, now)
            {
                out.push((session.chat_id.clone(), what));
            }
            self.seen.insert(key, Marker::of(session));
        }
        self.primed = true;
        out
    }

    /// The step a chat created at `created` is: one past the furthest
    /// report it could have been started in answer to, else the first.
    pub fn step_of(&self, created: chrono::DateTime<chrono::Utc>) -> u32 {
        let answered = self
            .log
            .iter()
            .filter(|(at, _)| {
                created >= *at && created - *at <= chrono::Duration::seconds(ANSWER_SECS)
            })
            .map(|(_, step)| *step)
            .max();
        1 + answered.unwrap_or(0)
    }

    /// Whether another report fits in the last ten minutes.
    pub fn burst_ok(&self, now: chrono::DateTime<chrono::Utc>) -> bool {
        let recent = self
            .log
            .iter()
            .filter(|(at, _)| now - *at <= chrono::Duration::seconds(BURST_SECS))
            .count();
        recent < BURST
    }

    /// A report went out now about a chat at `step`.
    pub fn sent(&mut self, now: chrono::DateTime<chrono::Utc>, step: u32) {
        while self
            .log
            .front()
            .is_some_and(|(at, _)| now - *at > chrono::Duration::hours(1))
        {
            self.log.pop_front();
        }
        self.log.push_back((now, step));
    }

    /// Whether one more report about `chat` is within the hour's allowance,
    /// counting it when it is.
    pub fn allow(&mut self, chat: &str, at: Instant) -> bool {
        let sent = self.sent.entry(chat.to_owned()).or_default();
        while sent.front().is_some_and(|t| at.duration_since(*t) >= HOUR) {
            sent.pop_front();
        }
        if sent.len() >= REPORTS_PER_HOUR {
            return false;
        }
        sent.push_back(at);
        true
    }
}

/// The message that goes into the main bot's thread.
pub fn report_text(chat: &Chat, project: &str, what: Outcome, step: u32) -> String {
    let title = chat
        .title
        .as_deref()
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .unwrap_or("A chat");
    let place = if project.is_empty() {
        String::new()
    } else {
        format!(" in {project}")
    };
    let happened = match what {
        Outcome::Finished => "finished its turn",
        Outcome::Waiting => "stopped on a question and is waiting for an answer",
        Outcome::Failed => "failed",
    };
    let mut text = format!(
        "[Harness: work you started has stopped. This is not a message from the user.]\n\
         \"{title}\"{place} (chat {}) {happened}.",
        chat.id
    );
    let said = chat
        .last_message_preview
        .as_deref()
        .map(str::trim)
        .unwrap_or_default();
    if !said.is_empty() {
        let cut: String = said.chars().take(PREVIEW_CAP).collect();
        text.push_str(&format!("\nIts last words: {cut}"));
    }
    text.push_str(
        "\n`read_chat` shows the rest. Tell the user what came back in a few lines. \
         Start nothing new unless what they asked for needs it.",
    );
    if step >= MAX_STEPS {
        text.push_str(
            "\nThis is the last report in this chain: work you start now is not reported here. \
             Say so if you start any.",
        );
    }
    text
}

impl Bots {
    /// Look at the live sessions once: for each chat the main bot's thread
    /// started that just finished, asked or failed, tell the main bot.
    /// Returns how many reports were sent.
    pub async fn hear(
        &self,
        rpc: &dyn RpcService,
        reports: &mut Reports,
        sessions: &[Session],
    ) -> Result<usize, EngineError> {
        let changed = reports.changed(sessions, chrono::Utc::now());
        // Bots off, or nothing happened: no process, no lists.
        if changed.is_empty() || !self.cli.enabled() {
            return Ok(0);
        }
        let state = self.state().await?;
        let Some(main_chat) = state
            .bots
            .iter()
            .find(|b| b.primary)
            .map(|b| b.chat.clone())
            .filter(|c| !c.is_empty())
        else {
            return Ok(0);
        };
        let chats: Vec<Chat> = snapshot(rpc, methods::WATCH_CHATS).await?;
        let Some(thread) = chats.iter().find(|c| c.id == main_chat && !c.archived) else {
            return Ok(0);
        };
        let spaces: Vec<Space> = snapshot(rpc, methods::WATCH_SPACES).await?;
        let mut sent = 0;
        for (chat_id, what) in changed {
            let Some(chat) = chats.iter().find(|c| c.id == chat_id && !c.archived) else {
                continue;
            };
            if chat.parent_chat_id.as_deref() != Some(main_chat.as_str()) {
                continue;
            }
            let now = chrono::Utc::now();
            let step = reports.step_of(chat.created_at);
            if step > MAX_STEPS || !reports.burst_ok(now) {
                tracing::warn!(chat = %chat.id, step, "work the main bot started in answer to reports was not reported: the chain stops here");
                continue;
            }
            if !reports.allow(&chat.id, Instant::now()) {
                tracing::warn!(chat = %chat.id, "more than {REPORTS_PER_HOUR} reports to the main bot in an hour; not sent");
                continue;
            }
            let project = chat
                .space_id
                .as_deref()
                .and_then(|id| spaces.iter().find(|s| s.id == id))
                .map(Space::display_name)
                .unwrap_or_default();
            send_into(rpc, thread, &spaces, report_text(chat, project, what, step)).await?;
            reports.sent(now, step);
            sent += 1;
        }
        Ok(sent)
    }
}

/// Follow the live sessions for as long as the engine runs.
pub async fn follow(rpc: Arc<dyn RpcService>, bots: Bots) {
    let mut reports = Reports::default();
    loop {
        if let Ok(reply) = rpc.handle(methods::WATCH_SESSIONS, json!({})).await
            && let Ok(mut stream) = reply.into_stream()
        {
            while let Some(item) = stream.next().await {
                let Ok(sessions) = serde_json::from_value::<Vec<Session>>(item) else {
                    continue;
                };
                if let Err(err) = bots.hear(rpc.as_ref(), &mut reports, &sessions).await {
                    tracing::warn!("the main bot was not told about finished work: {err}");
                }
            }
        }
        // The watch ended (the engine is shutting down, or it was replaced).
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(
        status: SessionStatus,
        turn: Option<&str>,
        peer_only: bool,
        age_secs: i64,
    ) -> Session {
        Session {
            last_completed_turn: turn.map(str::to_owned),
            last_completed_peer_only: peer_only,
            chat_id: "w1".into(),
            device_id: "dev-local".into(),
            status,
            started_at: None,
            updated_at: chrono::Utc::now() - chrono::Duration::seconds(age_secs),
        }
    }

    #[test]
    fn only_a_turn_nobody_typed_a_question_or_a_failure_is_news() {
        let now = chrono::Utc::now();
        let idle = Marker {
            turn: None,
            status: SessionStatus::Idle,
        };
        let working = Marker {
            turn: Some("t1".into()),
            status: SessionStatus::Working,
        };
        // The turn the main bot asked for ended.
        let done = session(SessionStatus::Idle, Some("t1"), true, 1);
        assert_eq!(outcome(Some(&idle), &done, now), Some(Outcome::Finished));
        assert_eq!(outcome(None, &done, now), Some(Outcome::Finished));
        // The same turn again, and a turn the user typed there, are not.
        assert_eq!(outcome(Some(&Marker::of(&done)), &done, now), None);
        let typed = session(SessionStatus::Idle, Some("t2"), false, 1);
        assert_eq!(outcome(Some(&Marker::of(&done)), &typed, now), None);
        // Still working on the next turn: nothing yet.
        assert_eq!(
            outcome(
                Some(&working),
                &session(SessionStatus::Working, Some("t1"), true, 1),
                now
            ),
            None
        );
        // A question and a failure, once each.
        let asked = session(SessionStatus::AwaitingInput, Some("t1"), true, 1);
        assert_eq!(outcome(Some(&working), &asked, now), Some(Outcome::Waiting));
        assert_eq!(outcome(Some(&Marker::of(&asked)), &asked, now), None);
        let failed = session(SessionStatus::Errored, None, false, 1);
        assert_eq!(outcome(Some(&idle), &failed, now), Some(Outcome::Failed));
        assert_eq!(outcome(Some(&Marker::of(&failed)), &failed, now), None);
        // A row that comes back with an old marker is not news.
        assert_eq!(
            outcome(
                None,
                &session(SessionStatus::Idle, Some("t9"), true, 600),
                now
            ),
            None
        );
    }

    #[test]
    fn the_first_look_is_not_news_and_an_hour_allows_four_reports_a_chat() {
        let now = chrono::Utc::now();
        let mut reports = Reports::default();
        let done = session(SessionStatus::Idle, Some("t1"), true, 1);
        // What was already so when the engine started is not reported.
        assert!(reports.changed(std::slice::from_ref(&done), now).is_empty());
        assert!(reports.changed(std::slice::from_ref(&done), now).is_empty());
        let next = session(SessionStatus::Idle, Some("t2"), true, 1);
        assert_eq!(
            reports.changed(&[next], now),
            [("w1".to_owned(), Outcome::Finished)]
        );

        let start = Instant::now();
        for _ in 0..REPORTS_PER_HOUR {
            assert!(reports.allow("w1", start));
        }
        assert!(!reports.allow("w1", start + Duration::from_secs(60)));
        // Another chat has its own allowance, and the hour moves on.
        assert!(reports.allow("w2", start));
        assert!(reports.allow("w1", start + HOUR));
    }

    #[test]
    fn a_report_names_the_chat_where_it_is_and_what_it_said() {
        let chat: Chat = serde_json::from_value(json!({
            "id": "w1", "deviceId": "dev-local", "title": " Bump deps ", "archived": false,
            "lastMessagePreview": "Bumped two. One needs a major version; left it.",
            "createdAt": "2026-09-01T00:00:00Z"
        }))
        .unwrap();
        let text = report_text(&chat, "atlas", Outcome::Finished, 1);
        assert!(text.starts_with(
            "[Harness: work you started has stopped. This is not a message from the user.]"
        ));
        assert!(text.contains("\"Bump deps\" in atlas (chat w1) finished its turn."));
        assert!(text.contains("Its last words: Bumped two."));
        assert!(!text.contains("last report in this chain"));
        let asked = report_text(&chat, "", Outcome::Waiting, MAX_STEPS);
        assert!(asked.contains("\"Bump deps\" (chat w1) stopped on a question"));
        assert!(asked.contains("This is the last report in this chain"));
    }

    #[test]
    fn work_started_in_answer_to_a_report_is_a_step_further_and_the_chain_ends() {
        let t0 = chrono::Utc::now();
        let secs = chrono::Duration::seconds;
        let mut reports = Reports::default();
        // Asked for by the user: nothing was reported before it was made.
        assert_eq!(reports.step_of(t0), 1);
        reports.sent(t0 + secs(60), 1);
        // Made before that report, or long after it: still the user's.
        assert_eq!(reports.step_of(t0 + secs(30)), 1);
        assert_eq!(reports.step_of(t0 + secs(60 + ANSWER_SECS + 1)), 1);
        // Made while the main bot was answering it: a step further.
        assert_eq!(reports.step_of(t0 + secs(70)), 2);
        reports.sent(t0 + secs(80), 2);
        assert_eq!(reports.step_of(t0 + secs(90)), 3);
        reports.sent(t0 + secs(100), 3);
        // A main bot that starts work on every report is past the end here.
        assert!(reports.step_of(t0 + secs(110)) > MAX_STEPS);

        // And however they chain, only so many go out in ten minutes.
        let mut burst = Reports::default();
        for _ in 0..BURST {
            assert!(burst.burst_ok(t0));
            burst.sent(t0, 1);
        }
        assert!(!burst.burst_ok(t0 + secs(BURST_SECS - 1)));
        assert!(burst.burst_ok(t0 + secs(BURST_SECS + 1)));
    }
}
