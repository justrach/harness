#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, atomic::AtomicBool};
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel, ToolCall};
use tokio::sync::{mpsc, oneshot};

#[tokio::test]
async fn background_child_events_arrive_after_parent_prompt_done() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("graff");
    std::fs::write(
        &executable,
        r#"#!/usr/bin/env python3
import json, sys, time

def emit(value):
    print(json.dumps(value), flush=True)

def update(value):
    emit({'jsonrpc':'2.0', 'method':'session/update',
          'params':{'sessionId':'parent', 'update':value}})

def child(seq, event):
    emit({'jsonrpc':'2.0', 'method':'graff/subagent_event', 'params':{
        'parentSessionId':'parent', 'subagentSessionId':'child',
        'parentToolCallId':'tool-1', 'seq':seq, 'event':event}})

for line in sys.stdin:
    req = json.loads(line)
    if 'id' not in req:
        continue
    method = req['method']
    if method == 'initialize':
        assert req['params']['clientCapabilities']['_meta']['graff/backgroundSubagents'] is True
        result = {'protocolVersion':1, 'agentCapabilities':{
            '_meta':{'graff/backgroundSubagents':True}}}
    elif method == 'session/new':
        result = {'sessionId':'parent'}
    elif method == 'session/prompt':
        update({'sessionUpdate':'tool_call', 'toolCallId':'tool-1',
                'kind':'other', 'title':'Inspect',
                'rawInput':{'description':'Inspect', 'prompt':'Inspect'},
                '_meta':{'graff/toolName':'subagent'}})
        emit({'jsonrpc':'2.0', 'id':req['id'], 'result':{'stopReason':'end_turn'}})
        time.sleep(0.25)
        child(0, {'type':'spawn', 'name':'Explore', 'task':'Inspect'})
        child(1, {'type':'update', 'update':{'sessionUpdate':'agent_message_chunk',
                 'content':{'type':'text', 'text':'Child is still working'}}})
        child(2, {'type':'terminal', 'state':'cancelled'})
        continue
    else:
        result = {}
    emit({'jsonrpc':'2.0', 'id':req['id'], 'result':result})
"#,
    )
    .unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();

    let harness = AcpHarness::graff()
        .with_executable(executable)
        .with_graff_draft_subagents(Arc::new(AtomicBool::new(true)));
    let (steering_tx, steering) = mpsc::channel(1);
    let controls = RunControls {
        request_input: Box::new(|_| {
            let (tx, rx) = oneshot::channel();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering,
        interrupt: CancellationToken::new(),
        mcp_servers: Vec::new(),
    };
    let request = RunRequest {
        prompt: "Inspect".into(),
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
    let mut events = harness.run(request, controls).await.unwrap();
    let observed = tokio::time::timeout(Duration::from_secs(10), async {
        let mut all = Vec::new();
        while let Some(result) = events.next().await {
            let event = result.unwrap();
            let child_cancelled = matches!(&event, AgentEvent::Subagent { parent_tool_use_id, event }
                if parent_tool_use_id == "tool-1" && matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Cancelled, .. }));
            all.push(event);
            if child_cancelled { return all; }
        }
        panic!("ACP stream closed before background child terminal event")
    }).await.expect("background event after parent Done");
    let parent_done = observed.iter().position(|event| matches!(event,
        AgentEvent::Done { status: DoneStatus::Completed, session_id: Some(id), .. } if id == "parent"
    )).expect("parent prompt Done");
    let child_text = observed.iter().position(|event| matches!(event,
        AgentEvent::Subagent { parent_tool_use_id, event }
            if parent_tool_use_id == "tool-1" && matches!(event.as_ref(), AgentEvent::TextDelta { text } if text == "Child is still working")
    )).expect("background child transcript update");
    let child_terminal = observed.len() - 1;
    assert!(
        parent_done < child_text && child_text < child_terminal,
        "{observed:?}"
    );
    assert!(
        observed.iter().any(|event| matches!(event,
            AgentEvent::ToolCall { id, call: ToolCall::Unknown { name, .. } }
                if id == "tool-1" && name.starts_with("Agent")
        )),
        "{observed:?}"
    );
    drop(steering_tx);
}
