#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls};
use harness_proto::{
    AgentEvent, DoneStatus, ReasoningLevel, RunRequest, SandboxLevel, UserInputAnswer,
};
use tokio::sync::{mpsc, oneshot};

fn fake_agent(root: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = root.join("graff");
    std::fs::write(&path, r#"#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).parent
if '--version' in sys.argv:
    print('graff 0.0.1')
    sys.exit(0)
mode = (root / 'mode').read_text().strip() if (root / 'mode').exists() else ''
with (root / 'wire.jsonl').open('a') as log:
    log.write(json.dumps({'argv':sys.argv[1:]}) + '\n')
if 'route' in sys.argv:
    print('session default: p1/shared · auth: login')
    print('provider auth billing models')
    print('p1 login metered shared')
    print()
    sys.exit(0)
if '--schema' in sys.argv:
    print(json.dumps({'models':[{'provider':'p1','name':'shared'}]}))
    sys.exit(0)
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    method = request['method']
    with (root / 'wire.jsonl').open('a') as log:
        log.write(json.dumps(request) + '\n')
    option = {'id':'effort','name':'Thought level','category':'thought_level','type':'select',
              'currentValue':'low','options':[{'value':'low','name':'Low'},
                                            {'value':'high','name':'High'}]}
    if mode == 'no-id': option.pop('id')
    if method == 'initialize':
        result = {'protocolVersion':0 if mode == 'bad-version' else 1,
                  'agentCapabilities':{'loadSession':True}}
    elif method == 'session/new':
        result = {'sessionId':'fixture','configOptions':[option]}
    elif method == 'session/load':
        result = {'sessionId':'fixture','configOptions':[option]}
    elif method == 'graff/models':
        if mode == 'old-agent':
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],
                              'error':{'code':-32601,'message':'method not found'}}),flush=True)
            continue
        result = {'current':{'provider':'p1','model':'shared','effort':'low'},'models':[
            {'provider':'p1','name':'shared','authenticated':True,'effortLevels':['low','high']},
            {'provider':'p2','name':'shared','authenticated':True,'effortLevels':['medium']},
            {'provider':'p3','name':'closed','authenticated':False,'effortLevels':['high']}]}
        if mode == 'no-auth': result['models'] = []
    elif method == 'session/set_config_option':
        if mode == 'reject':
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],
                              'error':{'code':-32602,'message':'rejected'}}),flush=True)
            continue
        option['currentValue'] = request['params']['value'] if mode != 'ignored' else 'low'
        result = {'configOptions':[option]}
    elif method == 'session/prompt':
        if mode == 'slash-low':
            print(json.dumps({'method':'session/update','params':{'sessionId':'other',
                  'update':{'sessionUpdate':'config_option_update','configOptions':[]}}}),flush=True)
            print(json.dumps({'method':'session/update','params':{'sessionId':'fixture',
                  'update':{'sessionUpdate':'config_option_update','configOptions':[option]}}}),flush=True)
        if mode == 'remove-effort':
            print(json.dumps({'method':'session/update','params':{'sessionId':'fixture',
                  'update':{'sessionUpdate':'config_option_update','configOptions':[]}}}),flush=True)
        result = {'stopReason':'end_turn'}
    else:
        result = {}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
"#).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn controls() -> RunControls {
    let (_, rx) = mpsc::channel(8);
    RunControls {
        request_input: Box::new(|_: Vec<_>| {
            let (tx, rx) = oneshot::channel::<Vec<UserInputAnswer>>();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering: rx,
        interrupt: CancellationToken::new(),
    }
}

fn request(root: &Path, level: ReasoningLevel) -> RunRequest {
    RunRequest {
        prompt: "hello".into(),
        harness: None,
        model: Some("p1/shared".into()),
        reasoning: Some(level),
        model_options: serde_json::Map::new(),
        cwd: root.display().to_string(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    }
}

fn wire(root: &Path) -> Vec<serde_json::Value> {
    std::fs::read_to_string(root.join("wire.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

async fn run(root: &Path, level: ReasoningLevel) -> Vec<AgentEvent> {
    let harness = AcpHarness::graff().with_executable(root.join("graff"));
    let events = harness.run(request(root, level), controls()).await.unwrap();
    tokio::time::timeout(
        Duration::from_secs(10),
        events.map(Result::unwrap).collect(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn catalog_has_per_provider_efforts_without_inference_then_run_sets_picked_effort() {
    let root = tempfile::tempdir().unwrap();
    fake_agent(root.path());
    let harness = AcpHarness::graff().with_executable(root.path().join("graff"));
    let catalog = harness.model_catalog(true).await.unwrap();
    assert_eq!(catalog.models.len(), 2);
    assert_eq!(catalog.models[0].id, "p1/shared");
    assert_eq!(
        catalog.models[0].reasoning_levels,
        vec![ReasoningLevel::Low, ReasoningLevel::High]
    );
    assert_eq!(catalog.models[1].id, "p2/shared");
    assert_eq!(
        catalog.models[1].reasoning_levels,
        vec![ReasoningLevel::Medium]
    );
    assert!(
        !wire(root.path())
            .iter()
            .any(|entry| entry["method"] == "session/prompt")
    );

    let events = run(root.path(), ReasoningLevel::High).await;
    assert!(
        events.iter().any(|event| matches!(
            event,
            AgentEvent::Done {
                status: DoneStatus::Completed,
                ..
            }
        )),
        "{events:?}"
    );
    let entries = wire(root.path());
    assert!(
        entries
            .iter()
            .any(|entry| entry["argv"] == serde_json::json!(["acp", "--model", "p1/shared"]))
    );
    let set = entries
        .iter()
        .position(|entry| entry["method"] == "session/set_config_option")
        .unwrap();
    let prompt = entries
        .iter()
        .position(|entry| entry["method"] == "session/prompt")
        .unwrap();
    assert!(set < prompt);
    assert_eq!(entries[set]["params"]["value"], "high");
}

#[tokio::test]
async fn unsupported_or_unconfirmed_effort_never_reaches_prompt() {
    for (mode, effort) in [
        ("", ReasoningLevel::Ultra),
        ("no-id", ReasoningLevel::High),
        ("reject", ReasoningLevel::High),
        ("ignored", ReasoningLevel::High),
    ] {
        let root = tempfile::tempdir().unwrap();
        fake_agent(root.path());
        std::fs::write(root.path().join("mode"), mode).unwrap();
        let events = run(root.path(), effort).await;
        assert!(
            events.iter().any(|event| matches!(
                event,
                AgentEvent::Done {
                    status: DoneStatus::Errored,
                    ..
                }
            )),
            "{mode}: {events:?}"
        );
        assert!(
            !wire(root.path())
                .iter()
                .any(|entry| entry["method"] == "session/prompt"),
            "{mode}"
        );
    }
}

#[tokio::test]
async fn unauthenticated_catalog_is_an_error() {
    let root = tempfile::tempdir().unwrap();
    fake_agent(root.path());
    std::fs::write(root.path().join("mode"), "no-auth").unwrap();
    let harness = AcpHarness::graff().with_executable(root.path().join("graff"));
    let error = harness.models().await.unwrap_err();
    assert_eq!(
        harness_adapters::CatalogFailure::classify(&error),
        harness_adapters::CatalogFailureCode::AuthRequired
    );
    assert_eq!(
        harness_adapters::CatalogFailure::classify(&harness.model_catalog(true).await.unwrap_err()),
        harness_adapters::CatalogFailureCode::AuthRequired
    );
}

#[tokio::test]
async fn authenticated_rows_are_not_served_after_account_changes() {
    let root = tempfile::tempdir().unwrap();
    fake_agent(root.path());
    let harness = AcpHarness::graff().with_executable(root.path().join("graff"));
    assert_eq!(harness.model_catalog(true).await.unwrap().models.len(), 2);
    std::fs::write(root.path().join("mode"), "no-auth").unwrap();
    let error = harness.model_catalog(false).await.unwrap_err();
    assert_eq!(
        harness_adapters::CatalogFailure::classify(&error),
        harness_adapters::CatalogFailureCode::AuthRequired
    );
}

#[tokio::test]
async fn live_effort_update_is_session_scoped_and_removed_option_clears_picker() {
    for (mode, expected) in [
        ("slash-low", Some(ReasoningLevel::Low)),
        ("remove-effort", None),
    ] {
        let root = tempfile::tempdir().unwrap();
        fake_agent(root.path());
        std::fs::write(root.path().join("mode"), mode).unwrap();
        let events = run(root.path(), ReasoningLevel::High).await;
        let updates: Vec<_> = events
            .iter()
            .filter_map(|event| match event {
                AgentEvent::ReasoningChanged { reasoning } => Some(*reasoning),
                _ => None,
            })
            .collect();
        assert_eq!(updates, vec![expected], "{mode}: {events:?}");
    }
}

#[tokio::test]
async fn incompatible_init_stops_before_session_and_unknown_extension_uses_legacy_catalog() {
    let root = tempfile::tempdir().unwrap();
    fake_agent(root.path());
    std::fs::write(root.path().join("mode"), "bad-version").unwrap();
    let harness = AcpHarness::graff().with_executable(root.path().join("graff"));
    assert!(harness.model_catalog(true).await.is_err());
    assert!(
        !wire(root.path())
            .iter()
            .any(|entry| entry["method"] == "session/new")
    );

    let old = tempfile::tempdir().unwrap();
    fake_agent(old.path());
    std::fs::write(old.path().join("mode"), "old-agent").unwrap();
    let harness = AcpHarness::graff().with_executable(old.path().join("graff"));
    let catalog = harness.model_catalog(true).await.unwrap();
    assert_eq!(catalog.models[0].id, "shared");
    assert!(catalog.models[0].reasoning_levels.is_empty());
    assert!(
        wire(old.path())
            .iter()
            .any(|entry| entry["argv"] == serde_json::json!(["route"]))
    );
}
