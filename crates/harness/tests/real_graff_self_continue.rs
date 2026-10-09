//! Real graff regression: messages that arrive while graff works on its own
//! (a background subagent running, then the parent turn that subagent's
//! completion wakes) must reach graff without cancelling that work.
//! Requires an authenticated `graff` on PATH (or GRAFF_EXECUTABLE).
//! GRAFF_TEST_MODEL picks the model (default chatgpt-new/gpt-6.1-sol).
//! cargo test -p harness-adapters --test real_graff_self_continue -- --ignored --nocapture

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, atomic::AtomicBool};
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls, SteerMessage};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel};
use tokio::sync::{mpsc, oneshot};

fn steer(prompt: &str) -> SteerMessage {
    SteerMessage {
        prompt: prompt.into(),
        message_id: None,
        attachments: Vec::new(),
    }
}

#[tokio::test]
#[ignore = "calls an authenticated real model through graff"]
async fn real_graff_messages_during_background_work_do_not_cancel_it() {
    let cwd = tempfile::tempdir().unwrap();
    let (steer_tx, steering) = mpsc::channel(8);
    let controls = RunControls {
        origin: None,
        steering,
        interrupt: CancellationToken::new(),
        request_input: Box::new(|_| {
            let (tx, rx) = oneshot::channel();
            let _ = tx.send(Vec::new());
            rx
        }),
    };
    let request = RunRequest {
        prompt: "Start ONE background subagent (do not wait for it) whose job is: run the \
                 shell command `sleep 25 && echo BG-DONE` and report its output in one line. \
                 As soon as it is started, reply exactly STARTED and end your turn. When it \
                 finishes, tell me what it reported in one short sentence."
            .into(),
        harness: None,
        model: Some(
            std::env::var("GRAFF_TEST_MODEL").unwrap_or_else(|_| "chatgpt-new/gpt-6.1-sol".into()),
        ),
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.path().display().to_string(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    };
    // Record the wire: a cancel of graff's own turn surfaces only there (the
    // `session/cancel` sent, and `gui_turn_end` with stopReason cancelled).
    let graff = std::env::var("GRAFF_EXECUTABLE").unwrap_or_else(|_| {
        let out = std::process::Command::new("sh")
            .args(["-c", "command -v graff"])
            .output()
            .expect("locate graff");
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    });
    assert!(!graff.is_empty(), "graff not found on PATH");
    let wire_in = cwd.path().join("wire-in.jsonl");
    let wire_out = cwd.path().join("wire-out.jsonl");
    let wrapper = cwd.path().join("graff-recorded");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\ntee '{}' | '{graff}' \"$@\" | tee '{}'\n",
            wire_in.display(),
            wire_out.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut stream = AcpHarness::graff()
        .with_executable(wrapper)
        .with_graff_draft_subagents(Arc::new(AtomicBool::new(true)))
        .run(request, controls)
        .await
        .expect("real graff must start");

    #[derive(PartialEq, Debug)]
    enum Phase {
        FirstTurn,
        ChildRunning,
        AwaitingWake,
        Woken,
    }
    let mut phase = Phase::FirstTurn;
    let mut text = String::new();
    let mut events = Vec::new();
    let mut child_done_at = None;
    let mut a_answered_at = None;
    let started = tokio::time::Instant::now();
    let outcome = tokio::time::timeout(Duration::from_secs(300), async {
        while let Some(event) = stream.next().await {
            let event = event.expect("event");
            let at = started.elapsed();
            match &event {
                AgentEvent::Done { status, .. } => {
                    eprintln!("{at:>6.1?} Done {status:?}");
                    assert_eq!(
                        *status,
                        DoneStatus::Completed,
                        "a parent turn ended {status:?}: work was cancelled"
                    );
                    if phase == Phase::FirstTurn {
                        phase = Phase::ChildRunning;
                        // Message A lands while the background subagent runs.
                        tokio::time::sleep(Duration::from_secs(3)).await;
                        eprintln!("{:>6.1?} -> message A (child running)", started.elapsed());
                        steer_tx
                            .send(steer("Reply exactly A-OK. Do not call any tools."))
                            .await
                            .unwrap();
                    }
                }
                AgentEvent::Subagent { event: inner, .. } => {
                    if let AgentEvent::Done { status, .. } = inner.as_ref() {
                        eprintln!("{at:>6.1?} child Done {status:?}");
                        assert_eq!(*status, DoneStatus::Completed, "background child cancelled");
                        child_done_at = Some(at);
                        if phase == Phase::ChildRunning {
                            phase = Phase::AwaitingWake;
                        }
                    }
                }
                AgentEvent::TextDelta { text: delta } => {
                    text.push_str(delta);
                    if a_answered_at.is_none() && text.contains("A-OK") {
                        a_answered_at = Some(at);
                        eprintln!("{at:>6.1?} A answered");
                    }
                }
                AgentEvent::ToolCall { .. } => {}
                _ => {}
            }
            // The child's completion wakes the parent: message B goes INTO
            // that self-continued turn, the exact case that used to cancel.
            if phase == Phase::AwaitingWake
                && matches!(
                    event,
                    AgentEvent::TextDelta { .. } | AgentEvent::ToolCall { .. }
                )
            {
                phase = Phase::Woken;
                eprintln!("{at:>6.1?} -> message B (into self-continued turn)");
                steer_tx
                    .send(steer("Reply exactly B-OK. Do not call any tools."))
                    .await
                    .unwrap();
            }
            let done = matches!(event, AgentEvent::Done { .. });
            events.push(event);
            if done && text.contains("B-OK") {
                return;
            }
        }
        panic!("stream ended early: {text}");
    })
    .await;
    assert!(outcome.is_ok(), "timed out; text so far: {text}");
    let a_at = a_answered_at.expect("message A answered");
    let child_at = child_done_at.expect("background child finished");
    assert!(
        a_at < child_at,
        "message A must go out while the child runs, not wait for it ({a_at:?} vs {child_at:?})"
    );
    drop(steer_tx);
    drop(stream);
    let sent = std::fs::read_to_string(&wire_in).unwrap_or_default();
    let received = std::fs::read_to_string(&wire_out).unwrap_or_default();
    let cancels = sent
        .lines()
        .filter(|l| l.contains("\"session/cancel\""))
        .count();
    let cancelled_turns = received
        .lines()
        .filter(|l| l.contains("gui_turn_end") && l.contains("cancelled"))
        .count();
    assert_eq!(cancels, 0, "harness sent session/cancel into graff's work");
    assert_eq!(cancelled_turns, 0, "a graff turn ended cancelled");
    assert!(
        received.contains("gui_turn_end"),
        "graff's self-continued turn ran to its end"
    );
}
