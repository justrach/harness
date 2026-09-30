//! Live check of the empty-first-turn recovery against the real `claude` CLI.
//!
//! Ignored by default: it needs Claude Code installed and signed in, and it
//! spends a few cents on a small model. It replays the flow that made a prompt
//! vanish in practice: a turn that started a background command, Stop pressed
//! mid-turn, then a new prompt on a fresh run that resumes the session.
//!
//! ```text
//! # with the recovery (the default): the prompt is answered
//! cargo test -p harness-engine --test empty_first_turn_live -- --ignored --nocapture
//! # with it switched off: the prompt is swallowed, as it used to be
//! HARNESS_EMPTY_TURN_RETRY=0 \
//!   cargo test -p harness-engine --test empty_first_turn_live -- --ignored --nocapture
//! ```

use std::sync::Arc;
use std::time::{Duration, Instant};

use harness_doc::{MessagePart, MessageRole};
use harness_engine::{EngineCore, default_registry};
use harness_proto::{HarnessId, RunRequest, SandboxLevel, SessionStatus};

const CHAT: &str = "chat-live-empty-turn";

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

fn assistant_text(core: &EngineCore) -> String {
    core.doc_host
        .open(CHAT)
        .ok()
        .and_then(|h| h.doc().read_entries().ok())
        .unwrap_or_default()
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

fn status(core: &EngineCore) -> Option<SessionStatus> {
    core.sessions.session_status(CHAT).map(|s| s.status)
}

async fn until(what: &str, limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + limit;
    while Instant::now() < end {
        if done() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    eprintln!("(timed out waiting for {what})");
    false
}

#[tokio::test]
#[ignore = "needs a signed-in Claude Code CLI and spends a few cents"]
async fn a_prompt_after_a_resume_with_a_lingering_background_task_is_answered() {
    let recovery_off = std::env::var("HARNESS_EMPTY_TURN_RETRY")
        .is_ok_and(|v| matches!(v.trim(), "0" | "off" | "false" | "no"));
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

    // 1. Start a background command, keep the turn going, then press Stop
    //    mid-turn — the command is left with no completion record.
    core.sessions
        .dispatch(
            CHAT,
            HarnessId::ClaudeCode,
            request(
                "Use the Bash tool with run_in_background true to run: sleep 120 . \
                 After it has started, write a 600 word story about a lighthouse keeper.",
                &cwd,
            ),
            None,
        )
        .await
        .expect("first dispatch");
    assert!(
        until(
            "the story to start streaming",
            Duration::from_secs(90),
            || {
                status(&core) == Some(SessionStatus::Working) && assistant_text(&core).len() > 60
            }
        )
        .await,
        "the first turn never got going: {:?}",
        assistant_text(&core)
    );
    core.sessions.interrupt(CHAT).await.expect("press Stop");
    assert!(
        until("the run to end", Duration::from_secs(20), || {
            status(&core) != Some(SessionStatus::Working)
        })
        .await
    );

    // 2. A new prompt: a fresh run that resumes the session.
    let before = assistant_text(&core);
    let sent = Instant::now();
    core.sessions
        .dispatch(
            CHAT,
            HarnessId::ClaudeCode,
            request("Reply with exactly the single word: pong", &cwd),
            None,
        )
        .await
        .expect("second dispatch");
    let answered = until("the answer", Duration::from_secs(60), || {
        assistant_text(&core)[before.len()..].contains("pong")
    })
    .await;
    println!(
        "recovery {}: prompt after resume was {} ({:.1}s)",
        if recovery_off { "OFF" } else { "ON" },
        if answered { "ANSWERED" } else { "SWALLOWED" },
        sent.elapsed().as_secs_f32()
    );
    core.sessions.shutdown().await;

    assert_eq!(
        answered, !recovery_off,
        "recovery_off={recovery_off}: answered={answered}"
    );
}
