#![cfg(unix)]

//! graff ends a turn it started itself (a peer message or background subagent
//! waking the parent) with an ACP v1 `gui_turn_end` update. No `session/prompt`
//! of ours is outstanding for that turn, so the update is its only end (#276).

use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls, SteerMessage};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel};
use tokio::sync::{mpsc, oneshot};

const FAKE_GRAFF: &str = r#"#!/usr/bin/env python3
import json, sys, time

def emit(value):
    print(json.dumps(value), flush=True)

def update(value):
    emit({'jsonrpc':'2.0', 'method':'session/update',
          'params':{'sessionId':'parent', 'update':value}})

def text(t):
    update({'sessionUpdate':'agent_message_chunk', 'content':{'type':'text', 'text':t}})

def turn_end():
    update({'sessionUpdate':'gui_turn_end', 'stopReason':'end_turn'})

prompts = 0
for line in sys.stdin:
    req = json.loads(line)
    if 'id' not in req:
        continue
    method = req['method']
    if method == 'initialize':
        result = {'protocolVersion':1, 'agentCapabilities':{}}
    elif method == 'session/new':
        result = {'sessionId':'parent'}
    elif method == 'session/prompt':
        prompts += 1
        if prompts == 1:
            text('answer')
            emit({'jsonrpc':'2.0', 'id':req['id'], 'result':{'stopReason':'end_turn'}})
            time.sleep(0.3)
            # A stray end with no agent-started output before it.
            turn_end()
            time.sleep(0.3)
            # Peer wake 1: its tool row never resolves (a producer-side bug).
            text('peer one')
            update({'sessionUpdate':'tool_call', 'toolCallId':'peer-1', 'kind':'other',
                    'title':'Check inbox', 'status':'pending', 'rawInput':{}})
            turn_end()
            time.sleep(0.3)
            # Peer wake 2.
            text('peer two')
            turn_end()
            continue
        # The queued message: graff closes a self-continued turn while it is
        # outstanding, then answers it. Only the response may settle it.
        text('fresh answer')
        turn_end()
        emit({'jsonrpc':'2.0', 'id':req['id'], 'result':{'stopReason':'end_turn'}})
        sys.exit(0)
    else:
        result = {}
    emit({'jsonrpc':'2.0', 'id':req['id'], 'result':result})
"#;

#[tokio::test]
async fn agent_started_turns_end_on_gui_turn_end() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("graff");
    std::fs::write(&executable, FAKE_GRAFF).unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();

    let harness = AcpHarness::graff().with_executable(executable);
    let (steering_tx, steering) = mpsc::channel(1);
    let controls = RunControls {
        origin: None,
        request_input: Box::new(|_| {
            let (tx, rx) = oneshot::channel();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering,
        interrupt: CancellationToken::new(),
    };
    let request = RunRequest {
        prompt: "Fix it".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: dir.path().display().to_string(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    };
    let mut stream = harness.run(request, controls).await.unwrap();
    let events = tokio::time::timeout(Duration::from_secs(15), async {
        let mut events = Vec::new();
        let mut dones = 0;
        while let Some(event) = stream.next().await {
            let event = event.unwrap();
            if matches!(event, AgentEvent::Done { .. }) {
                dones += 1;
                // Both peer wakes settled: the queued message goes out.
                if dones == 3 {
                    steering_tx
                        .send(SteerMessage {
                            prompt: "next".into(),
                            message_id: None,
                            attachments: Vec::new(),
                        })
                        .await
                        .unwrap();
                }
            }
            events.push(event);
        }
        events
    })
    .await
    .expect("every turn settled without a watchdog");

    // One Done per turn, in order: the human turn, each peer wake, and the
    // queued message. The stray end and the end that arrived while the
    // queued prompt was outstanding settle nothing.
    let marks: Vec<&str> = events
        .iter()
        .filter_map(|event| match event {
            AgentEvent::TextDelta { text } => Some(text.as_str()),
            AgentEvent::Done { status, .. } => {
                assert_eq!(*status, DoneStatus::Completed, "{events:?}");
                Some("Done")
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        marks,
        [
            "answer",
            "Done",
            "peer one",
            "Done",
            "peer two",
            "Done",
            "fresh answer",
            "Done"
        ],
        "{events:?}"
    );
}
