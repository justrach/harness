//! A bot's run against a real engine. graff is canned (one made-up bot,
//! `notes`, working in a temporary project); the chats are the engine's own.
//! The unit tests in `src/bots_tests.rs` check what the bot module asks for;
//! this checks the engine accepts it: the chat exists afterwards, titled and
//! in the bot's project, and the next run goes into the same one.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use harness_adapters::mock::MockHarness;
use harness_engine::bots::{BotCli, Bots, RunBotParams};
use harness_engine::{EngineCore, EngineError, HarnessRegistry};
use harness_proto::HarnessId;
use harness_rpc::{RpcReply, RpcService, methods};
use serde_json::{Value, json};

struct Canned {
    project: String,
    chat: Mutex<String>,
}

#[async_trait]
impl BotCli for Canned {
    async fn run(&self, args: Vec<String>) -> Result<String, EngineError> {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        Ok(match args.as_slice() {
            ["state", "--json"] => json!({ "bots": [{
                "name": "notes", "job": "Draft release notes", "project": self.project,
                "chat": *self.chat.lock().unwrap(),
                "routines": [{ "id": "r1", "instruction": "draft", "message": "[routine r1] draft" }]
            }]})
            .to_string(),
            ["prompt", "notes"] => "You are notes, a graff Bot.".into(),
            ["set", "notes", "chat", id] => {
                *self.chat.lock().unwrap() = (*id).to_owned();
                String::new()
            }
            ["missed", "clear", "notes", "r1"] => String::new(),
            other => return Err(EngineError::Other(format!("unexpected: {}", other.join(" ")))),
        })
    }

    fn enabled(&self) -> bool {
        true
    }
}

async fn chats(rpc: &dyn RpcService) -> Vec<Value> {
    match rpc.handle(methods::WATCH_CHATS, json!({})).await.unwrap() {
        RpcReply::Stream(mut stream) => stream.next().await.unwrap().as_array().unwrap().clone(),
        RpcReply::Value(value) => value.as_array().unwrap().clone(),
    }
}

/// The chat `id`, once the engine's chat list has it.
async fn chat(rpc: &dyn RpcService, id: &str) -> Value {
    for _ in 0..100 {
        if let Some(found) = chats(rpc).await.into_iter().find(|c| c["id"] == id) {
            return found;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the engine never listed chat {id}");
}

fn params(value: Value) -> RunBotParams {
    serde_json::from_value(value).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bots_run_is_a_titled_chat_in_its_project_and_later_runs_reuse_it() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("comet");
    std::fs::create_dir_all(&project).unwrap();
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
    let project_dir = project.to_str().unwrap().to_owned();
    rpc.handle(
        methods::MUTATE,
        json!({ "op": "createSpace", "spaceId": "space-comet", "deviceId": core.device_id,
                "path": project_dir, "gitDetected": false }),
    )
    .await
    .expect("the project is created");

    let cli = Arc::new(Canned {
        project: project_dir.clone(),
        chat: Mutex::new(String::new()),
    });
    let bots = Bots::with_cli(cli.clone());
    let ran = bots
        .run(
            rpc.as_ref(),
            params(json!({ "bot": "notes", "message": "draft 0.4" })),
        )
        .await
        .expect("the first run starts");
    let chat_id = ran["chatId"].as_str().unwrap().to_owned();
    assert_eq!(
        *cli.chat.lock().unwrap(),
        chat_id,
        "graff was told the chat"
    );
    let made = chat(rpc.as_ref(), &chat_id).await;
    assert_eq!(made["title"], "notes");
    assert_eq!(made["spaceId"], "space-comet");
    assert_eq!(made["config"]["harness"], "graff");
    assert_eq!(made["archived"], false);

    // A routine, then a message: the same chat, and no second one.
    for request in [
        json!({ "bot": "notes", "routine": "r1" }),
        json!({ "bot": "notes", "message": "shorter" }),
    ] {
        let again = bots
            .run(rpc.as_ref(), params(request))
            .await
            .expect("a later run starts");
        assert_eq!(again["chatId"], chat_id);
    }
    assert_eq!(chats(rpc.as_ref()).await.len(), 1);
}
