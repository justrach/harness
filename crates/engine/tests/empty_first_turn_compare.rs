//! Side-by-side of the empty-first-turn recovery against the real `claude` CLI.
//!
//! Ignored by default: it needs a signed-in Claude Code CLI and spends a few
//! cents on a small model per trial. Every trial gets its own engine and
//! scratch directory, runs one scenario, and measures what the user would see.
//! The engine's own log says which trials actually hit the bug (the first turn
//! ended with no output), so results are also reported among those trials only.
//!
//! ```text
//! COMPARE_TRIALS=20 COMPARE_CASES=bug-off,bug-on \
//!   cargo test -p harness-engine --test empty_first_turn_compare -- --ignored --nocapture
//! ```
//!
//! Scenarios
//! - `bug`: a turn starts a background command (the trial is discarded if it
//!   never did), Stop is pressed mid-turn, then a new prompt arrives on a fresh
//!   run that resumes the session. This is the state in which Claude Code can
//!   swallow the prompt.
//! - `control`: the same without the background command, to show the recovery
//!   costs nothing when nothing goes wrong.
//!
//! Setups
//! - `off`: recovery off, the user does nothing
//! - `off-resend`: recovery off, the user sends the prompt again after 5s
//! - `on`: recovery on
//!
//! `COMPARE_CASES` picks `scenario-setup` pairs (default: all five), so several
//! processes can run different setups at once.

use std::io::Write;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use harness_doc::{MessagePart, MessageRole};
use harness_engine::{EngineCore, default_registry};
use harness_proto::{HarnessId, RunRequest, SandboxLevel, SessionStatus};

const CHAT: &str = "chat-compare";
const PONG: &str = "Reply with exactly the single word: pong";

fn request(prompt: &str, cwd: &str) -> RunRequest {
    RunRequest {
        prompt: prompt.into(),
        harness: None,
        model: Some("claude-haiku-4-5".into()),
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Scenario {
    Bug,
    Control,
}

#[derive(Clone, Copy, PartialEq)]
enum Setup {
    Off,
    OffResend,
    On,
}

struct Trial {
    /// The engine saw the first turn end with no output (the bug fired).
    triggered: bool,
    answered: bool,
    /// Seconds from sending the prompt to the first "pong".
    secs: f32,
    /// Seconds the chat read Idle ("completed", nothing happening) before the
    /// answer: the stretch in which a user sees no sign their message landed.
    idle_secs: f32,
    /// "pong" replies in the transcript: more than one is a double answer.
    pongs: usize,
    /// The engine had to send the prompt again itself (nothing followed the empty turn).
    engine_resent: bool,
    user_bubbles: usize,
}

/// The engine's warnings, captured so each trial can be labelled.
fn log() -> &'static Arc<Mutex<Vec<u8>>> {
    static LOG: OnceLock<Arc<Mutex<Vec<u8>>>> = OnceLock::new();
    LOG.get_or_init(|| {
        #[derive(Clone)]
        struct Sink(Arc<Mutex<Vec<u8>>>);
        impl Write for Sink {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(buf);
                Ok(buf.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Sink {
            type Writer = Sink;
            fn make_writer(&'a self) -> Sink {
                self.clone()
            }
        }
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let _ = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::WARN)
            .with_ansi(false)
            .with_writer(Sink(buffer.clone()))
            .try_init();
        buffer
    })
}

fn entries(core: &EngineCore) -> Vec<harness_doc::SessionMessageEntry> {
    core.doc_host
        .open(CHAT)
        .ok()
        .and_then(|h| h.doc().read_entries().ok())
        .unwrap_or_default()
}

fn assistant_text(core: &EngineCore) -> String {
    entries(core)
        .into_iter()
        .filter(|e| e.role == MessageRole::Assistant)
        .flat_map(|e| e.parts)
        .filter_map(|p| match p {
            MessagePart::Text { text, .. } => Some(text),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("")
}

/// A tool call has finished: in the bug scenario, the background command was
/// started before Stop was pressed (otherwise there is nothing to leave behind).
fn tool_finished(core: &EngineCore) -> bool {
    entries(core)
        .into_iter()
        .flat_map(|e| e.parts)
        .any(|p| matches!(p, MessagePart::Tool { resolved: true, .. }))
}

fn status(core: &EngineCore) -> Option<SessionStatus> {
    core.sessions.session_status(CHAT).map(|s| s.status)
}

async fn until(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + limit;
    while Instant::now() < end {
        if done() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    false
}

async fn trial(scenario: Scenario, setup: Setup) -> Option<Trial> {
    let off = setup != Setup::On;
    // SAFETY: one trial at a time per process; the engine reads the switch when a run starts.
    unsafe { std::env::set_var("HARNESS_EMPTY_TURN_RETRY", if off { "0" } else { "1" }) };
    log().lock().unwrap().clear();

    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let cwd = cwd.to_string_lossy().into_owned();
    let core = EngineCore::assemble(
        &dir.path().join("engine"),
        Arc::new(default_registry()),
        HarnessId::ClaudeCode,
        None,
    )
    .expect("engine core assembles");

    let first = match scenario {
        Scenario::Bug => {
            "Use the Bash tool with run_in_background true to run: sleep 120 . \
             After it has started, write a 600 word story about a lighthouse keeper."
        }
        Scenario::Control => "Write a 600 word story about a lighthouse keeper.",
    };
    core.sessions
        .dispatch(CHAT, HarnessId::ClaudeCode, request(first, &cwd), None)
        .await
        .ok()?;
    let streaming = until(Duration::from_secs(90), || {
        status(&core) == Some(SessionStatus::Working)
            && assistant_text(&core).len() > 60
            && (scenario == Scenario::Control || tool_finished(&core))
    })
    .await;
    if !streaming {
        core.sessions.shutdown().await;
        return None; // the setup never reached its trigger; not a measurement
    }
    core.sessions.interrupt(CHAT).await.ok()?;
    until(Duration::from_secs(20), || {
        status(&core) != Some(SessionStatus::Working)
    })
    .await;
    // Only the second prompt's behavior is being measured.
    log().lock().unwrap().clear();

    let before = assistant_text(&core).len();
    let pongs = |core: &EngineCore| {
        assistant_text(core)[before..]
            .to_lowercase()
            .matches("pong")
            .count()
    };
    let sent = Instant::now();
    core.sessions
        .dispatch(CHAT, HarnessId::ClaudeCode, request(PONG, &cwd), None)
        .await
        .ok()?;
    // Watch the chat like a user would: when does it read Idle, and when does
    // the answer arrive? Keep watching a while after the answer for a second one.
    let give_up = match setup {
        Setup::Off => Duration::from_secs(20),
        _ => Duration::from_secs(45),
    };
    let mut resent = false;
    let mut idle_ticks = 0u32;
    let mut t_answer: Option<f32> = None;
    let mut answered_at: Option<Instant> = None;
    loop {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let now = sent.elapsed();
        if t_answer.is_none() {
            if pongs(&core) > 0 {
                t_answer = Some(now.as_secs_f32());
                answered_at = Some(Instant::now());
            } else if status(&core) == Some(SessionStatus::Idle) {
                idle_ticks += 1;
            }
        }
        if setup == Setup::OffResend
            && !resent
            && t_answer.is_none()
            && now >= Duration::from_secs(5)
        {
            // The user waits, sees nothing, and sends it again.
            core.sessions
                .dispatch(CHAT, HarnessId::ClaudeCode, request(PONG, &cwd), None)
                .await
                .ok()?;
            resent = true;
        }
        match answered_at {
            Some(at) if at.elapsed() >= Duration::from_secs(8) => break,
            None if now >= give_up => break,
            _ => {}
        }
    }
    let user_bubbles = entries(&core)
        .iter()
        .filter(|e| e.role == MessageRole::User)
        .flat_map(|e| e.parts.iter())
        .filter(|p| matches!(p, MessagePart::Text { text, .. } if text == PONG))
        .count();
    let pong_count = pongs(&core);
    core.sessions.shutdown().await;
    let captured = String::from_utf8_lossy(&log().lock().unwrap()).into_owned();
    Some(Trial {
        triggered: captured.contains("first turn ended with no output"),
        answered: t_answer.is_some(),
        secs: t_answer.unwrap_or(0.0),
        idle_secs: idle_ticks as f32 * 0.05,
        pongs: pong_count,
        engine_resent: captured.contains("re-sent the prompt once"),
        user_bubbles,
    })
}

fn median(values: &mut [f32]) -> Option<f32> {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    values.get(values.len().checked_sub(1)? / 2).copied()
}

#[tokio::test]
#[ignore = "needs a signed-in Claude Code CLI and spends a few cents per trial"]
async fn compare_the_recovery_against_the_old_behavior() {
    let trials: usize = std::env::var("COMPARE_TRIALS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(6);
    let wanted = std::env::var("COMPARE_CASES")
        .unwrap_or_else(|_| "bug-off,bug-off-resend,bug-on,control-off,control-on".into());
    let cases = [
        ("bug-off", Scenario::Bug, Setup::Off),
        ("bug-off-resend", Scenario::Bug, Setup::OffResend),
        ("bug-on", Scenario::Bug, Setup::On),
        ("control-off", Scenario::Control, Setup::Off),
        ("control-on", Scenario::Control, Setup::On),
    ];
    for (name, scenario, setup) in cases {
        if !wanted.split(',').any(|w| w.trim() == name) {
            continue;
        }
        let mut all: Vec<Trial> = vec![];
        for _ in 0..trials {
            if let Some(t) = trial(scenario, setup).await {
                all.push(t);
            }
        }
        let n = all.len();
        let hit = all.iter().filter(|t| t.triggered).count();
        let answered = all.iter().filter(|t| t.answered).count();
        let doubles = all.iter().filter(|t| t.pongs > 1).count();
        let resent = all.iter().filter(|t| t.engine_resent).count();
        let gap = all.iter().filter(|t| t.idle_secs >= 1.0).count();
        let secs: Vec<f32> = all.iter().filter(|t| t.answered).map(|t| t.secs).collect();
        let mut idle: Vec<f32> = all.iter().map(|t| t.idle_secs).collect();
        let bubbles = all.iter().map(|t| t.user_bubbles).sum::<usize>() as f32 / n.max(1) as f32;
        let fmt = |v: Option<f32>| v.map_or("-".to_string(), |v| format!("{v:.1}s"));
        println!(
            "RESULT {name:<15} trials={n:<3} bug_hit={hit:<3} unanswered={:<2} engine_resent={resent:<2} double_answers={doubles:<2} \
             idle_gap>=1s={gap:<2} | answer median={} max={} | idle median={} max={} | user_bubbles={bubbles:.2}",
            n - answered,
            fmt(median(&mut secs.clone())),
            fmt(secs.iter().copied().reduce(f32::max)),
            fmt(median(&mut idle)),
            fmt(idle.iter().copied().reduce(f32::max)),
        );
    }
}
