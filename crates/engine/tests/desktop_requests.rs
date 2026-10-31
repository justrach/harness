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
        let params = serde_json::to_string(&case["params"])
            .unwrap()
            .replace("$DEVICE", &core.device_id)
            .replace("$DIR", &project_dir);
        let params: Value = serde_json::from_str(&params).unwrap();
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
