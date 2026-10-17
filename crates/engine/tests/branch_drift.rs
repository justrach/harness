//! A chat whose checkout changed branch since its last turn does not silently
//! continue there (#354): the send is held behind a question, and each answer
//! (continue on the new branch, switch back, don't send) does what it says,
//! including after an engine restart.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, SessionCommandPayload};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode, UserInputAnswer, UserInputQuestion,
};

const CHAT: &str = "chat-branch-drift";

struct FakeAgent {
    prompts: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl Harness for FakeAgent {
    fn id(&self) -> HarnessId {
        HarnessId::Graff
    }
    fn display_name(&self) -> &str {
        "Graff"
    }
    fn supports_steering(&self) -> bool {
        false
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::TurnBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[ReasoningLevel::Medium]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let turn = {
            let mut prompts = self.prompts.lock().unwrap();
            prompts.push(request.prompt.clone());
            prompts.len()
        };
        let events: Vec<Result<AgentEvent, HarnessError>> = vec![
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Graff,
                model: "test-model".into(),
                tools: vec![],
                cwd: request.cwd.clone(),
                session_id: "sess-drift".into(),
                assistant_message_id: format!("a-{turn}"),
            }),
            Ok(AgentEvent::TextDelta { text: "ok".into() }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some("sess-drift".into()),
            }),
        ];
        Ok(futures::stream::iter(events).boxed())
    }
}

fn git(cwd: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn engine(data: &Path) -> (EngineCore, Arc<Mutex<Vec<String>>>) {
    let prompts = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FakeAgent {
        prompts: prompts.clone(),
    }));
    let core = EngineCore::assemble(data, Arc::new(registry), HarnessId::Graff, None)
        .expect("engine core assembles");
    (core, prompts)
}

async fn wait_for(mut predicate: impl FnMut() -> bool, what: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

fn send(core: &EngineCore, id: &str, text: &str, cwd: &str) {
    let payload = SessionCommandPayload::Run {
        request: RunRequest {
            prompt: text.into(),
            harness: Some(HarnessId::Graff),
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: cwd.into(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments: Vec::new(),
            resume: None,
            worktree: None,
        },
        message_id: id.into(),
    };
    core.doc_host
        .queue_command(CHAT, payload)
        .expect("queue run");
}

fn answer(core: &EngineCore, request_id: &str, label: &str) {
    let payload = SessionCommandPayload::RespondInput {
        request_id: request_id.into(),
        answers: vec![UserInputAnswer {
            question_id: "branch".into(),
            labels: vec![label.into()],
        }],
    };
    core.doc_host
        .queue_command(CHAT, payload)
        .expect("queue answer");
}

fn open_question(core: &EngineCore) -> Option<(String, UserInputQuestion)> {
    let entries = core.doc_host.open(CHAT).ok()?.doc().read_entries().ok()?;
    entries.iter().rev().find_map(|entry| {
        entry.parts.iter().find_map(|part| match part {
            MessagePart::Input {
                request_id,
                questions,
                resolved: false,
                ..
            } if request_id.starts_with("branch-drift-") => {
                Some((request_id.clone(), questions[0].clone()))
            }
            _ => None,
        })
    })
}

async fn wait_question(core: &EngineCore) -> (String, UserInputQuestion) {
    let mut found = None;
    wait_for(
        || {
            found = open_question(core);
            found.is_some()
        },
        "the branch drift question",
    )
    .await;
    found.unwrap()
}

fn context_branch(core: &EngineCore) -> String {
    let chat = core.workspace.chat(CHAT).unwrap().expect("chat row");
    chat.source_context.expect("source context").branch
}

#[tokio::test(flavor = "multi_thread")]
async fn a_drifted_checkout_asks_before_the_chat_continues() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-b", "alpha"]);
    git(&repo, &["commit", "--allow-empty", "-m", "initial"]);
    let cwd = repo.to_string_lossy().into_owned();
    let data = root.join("data");

    let (core, prompts) = engine(&data);
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, Some(cwd.clone()))
        .unwrap();
    core.workspace.rename_chat(CHAT, "Pre-titled").unwrap();
    let turns = |n: usize| {
        let prompts = prompts.clone();
        move || prompts.lock().unwrap().len() == n
    };

    send(&core, "m1", "first", &cwd);
    wait_for(turns(1), "first turn").await;
    assert_eq!(context_branch(&core), "alpha");

    // A commit on the same branch is the task progressing, not drift.
    git(&repo, &["commit", "--allow-empty", "-m", "progress"]);
    send(&core, "m2", "second", &cwd);
    wait_for(turns(2), "second turn").await;
    assert!(open_question(&core).is_none());

    // Another branch: the send waits behind a question.
    git(&repo, &["switch", "-c", "beta"]);
    send(&core, "m3", "third", &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_eq!(
        question.options,
        ["Continue on beta", "Switch back to alpha", "Don't send"]
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(prompts.lock().unwrap().len(), 2, "nothing ran on beta yet");
    assert_eq!(
        context_branch(&core),
        "alpha",
        "the accepted context is kept"
    );

    // Continue: the agent runs on beta and is told the branch moved.
    answer(&core, &request_id, "Continue on beta");
    wait_for(turns(3), "the continued turn").await;
    let continued = prompts.lock().unwrap()[2].clone();
    assert!(continued.ends_with("third"), "{continued}");
    assert!(
        continued.contains("now on `beta`") && continued.contains("ran on `alpha`"),
        "{continued}"
    );
    assert_eq!(context_branch(&core), "beta");
    assert!(open_question(&core).is_none());

    // Switch back: the checkout returns to beta and the turn runs there.
    git(&repo, &["switch", "-c", "gamma"]);
    send(&core, "m4", "fourth", &cwd);
    let (request_id, _) = wait_question(&core).await;
    answer(&core, &request_id, "Switch back to beta");
    wait_for(turns(4), "the turn after switching back").await;
    assert_eq!(git(&repo, &["branch", "--show-current"]), "beta");
    assert_eq!(prompts.lock().unwrap()[3], "fourth");

    // Uncommitted work: switching back is not offered, and dismissing sends
    // nothing.
    std::fs::write(repo.join("scratch.txt"), "wip").unwrap();
    git(&repo, &["switch", "-c", "delta"]);
    send(&core, "m5", "fifth", &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_eq!(question.options, ["Continue on delta", "Don't send"]);
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::DismissInput {
                request_id: request_id.clone(),
            },
        )
        .unwrap();
    wait_for(|| open_question(&core).is_none(), "dismissal").await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        prompts.lock().unwrap().len(),
        4,
        "a dismissed send never runs"
    );
    assert_eq!(context_branch(&core), "beta");

    // Switched back outside Harness: the next send takes the held one with
    // it and the question closes.
    send(&core, "m6", "sixth", &cwd);
    wait_question(&core).await;
    git(&repo, &["switch", "beta"]);
    send(&core, "m7", "seventh", &cwd);
    wait_for(turns(5), "the turn after an outside switch back").await;
    assert_eq!(prompts.lock().unwrap()[4], "sixth\n\nseventh");
    assert!(open_question(&core).is_none());

    // Typed text instead of a choice is another message, not a decision.
    git(&repo, &["switch", "-c", "epsilon"]);
    send(&core, "m8", "eighth", &cwd);
    let (first, _) = wait_question(&core).await;
    answer(&core, &first, "also check the docs");
    let mut second = None;
    wait_for(
        || {
            second = open_question(&core)
                .map(|(id, _)| id)
                .filter(|id| *id != first);
            second.is_some()
        },
        "the question asked again",
    )
    .await;
    let second = second.unwrap();
    assert_eq!(prompts.lock().unwrap().len(), 5);
    answer(&core, &second, "Continue on epsilon");
    wait_for(turns(6), "the turn after a typed answer").await;
    let both = prompts.lock().unwrap()[5].clone();
    assert!(both.ends_with("eighth\n\nalso check the docs"), "{both}");

    // A question left open across a restart still sends its message.
    git(&repo, &["switch", "-c", "zeta"]);
    send(&core, "m9", "ninth", &cwd);
    let (request_id, _) = wait_question(&core).await;
    // Sent while the question waits: held with it, after it in the transcript.
    send(&core, "m10", "tenth", &cwd);
    wait_for(
        || {
            let handle = core.doc_host.open(CHAT).unwrap();
            handle
                .doc()
                .read_entries()
                .unwrap()
                .iter()
                .any(|e| e.id == "m10")
        },
        "the second held message",
    )
    .await;
    core.shutdown().await;
    drop(core);

    let (core, prompts) = engine(&data);
    answer(&core, &request_id, "Continue on zeta");
    wait_for(
        || prompts.lock().unwrap().len() == 1,
        "the turn after restart",
    )
    .await;
    let resumed = prompts.lock().unwrap()[0].clone();
    assert!(resumed.ends_with("ninth\n\ntenth"), "{resumed}");
    assert!(!resumed.contains("eighth"), "{resumed}");
    assert_eq!(context_branch(&core), "zeta");
    core.shutdown().await;
}
