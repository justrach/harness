//! Sends every request in `protocol/desktop/requests.json` to a real engine.
//!
//! harness-nano (apps/nano) writes that file from the functions it builds
//! its requests with, and checks they still produce it. Here each one goes,
//! in order, to the engine's RPC service: a request whose params the engine
//! can't read, or whose method it doesn't know, fails the test. Anything else
//! (a queued row that isn't there, an action that can't run) is the engine
//! understanding the request and answering it.

use std::sync::Arc;

use harness_adapters::mock::MockHarness;
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::HarnessId;
use harness_rpc::{RpcError, RpcService};
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/desktop/requests.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn request_params(params: &Value, device: &str, project_dir: &str) -> Value {
    match params {
        Value::String(text) => {
            Value::String(text.replace("$DEVICE", device).replace("$DIR", project_dir))
        }
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| request_params(item, device, project_dir))
                .collect(),
        ),
        Value::Object(fields) => Value::Object(
            fields
                .iter()
                .map(|(key, value)| (key.clone(), request_params(value, device, project_dir)))
                .collect(),
        ),
        _ => params.clone(),
    }
}

#[test]
fn request_placeholders_preserve_windows_paths_and_json_types() {
    for project_dir in [
        r#"C:\synthetic\O'Brien "quoted"\日本語"#,
        r#"/synthetic/O'Brien "quoted"/日本語"#,
    ] {
        let params = serde_json::json!({
            "path": "$DIR",
            "nested": { "device": "$DEVICE", "command": "cd $DIR" },
            "values": ["$DIR", "$DEVICE", 7, true, null],
        });
        assert_eq!(
            request_params(&params, "synthetic-device", project_dir),
            serde_json::json!({
                "path": project_dir,
                "nested": { "device": "synthetic-device", "command": format!("cd {project_dir}") },
                "values": [project_dir, "synthetic-device", 7, true, null],
            })
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_engine_understands_every_request_harness_nano_sends() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("README.md"), "# Parity\n").unwrap();
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(MockHarness { script: vec![] }));
    let core = EngineCore::assemble(
        &dir.path().join("data"),
        Arc::new(registry),
        HarnessId::Mock,
        None,
    )
    .expect("engine core assembles");
    let rpc = core.rpc_service();
    let project_dir = project.to_str().unwrap().to_string();

    let mut refused = Vec::new();
    for case in vectors()["requests"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let method = case["method"].as_str().unwrap();
        let params = request_params(&case["params"], &core.device_id, &project_dir);
        eprintln!("→ {name}");
        let reply = tokio::time::timeout(
            std::time::Duration::from_secs(20),
            rpc.handle(method, params),
        )
        .await
        .unwrap_or_else(|_| panic!("{name}: {method} didn't answer"));
        match reply {
            Err(RpcError::BadParams(e)) => {
                refused.push(format!("{name}: {method}: bad params: {e}"))
            }
            Err(RpcError::UnknownMethod(m)) => refused.push(format!("{name}: unknown method {m}")),
            // A stream started, or a call answered (an error included): the
            // request was understood.
            _ => {}
        }
    }
    assert!(
        refused.is_empty(),
        "the engine refused:\n{}",
        refused.join("\n")
    );
}
