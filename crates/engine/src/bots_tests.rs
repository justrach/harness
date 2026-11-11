//! Bots against a recording engine and canned graff output: made-up bots
//! `ada`, `notes` and `triage` working in a made-up project `/repo/comet`.

use std::sync::Mutex;

use super::*;
use harness_rpc::RpcError;

/// Stands in for `graff bot --user`. Records each command.
struct FakeCli {
    /// The user's switch: `enable` and `disable` flip it.
    on: std::sync::atomic::AtomicBool,
    /// Whether `ada` is primary. Off: the store has no main bot.
    primary: std::sync::atomic::AtomicBool,
    /// The main bot's thread, as graff has it on record.
    ada_chat: Mutex<String>,
    /// The chat graff has on record for `notes`, changed by `set notes chat`.
    notes_chat: Mutex<String>,
    due: Value,
    calls: Mutex<Vec<String>>,
}

impl FakeCli {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            on: std::sync::atomic::AtomicBool::new(true),
            primary: std::sync::atomic::AtomicBool::new(true),
            ada_chat: Mutex::new(String::new()),
            notes_chat: Mutex::new(String::new()),
            due: json!([]),
            calls: Mutex::new(Vec::new()),
        })
    }

    fn said(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl BotCli for FakeCli {
    async fn run(&self, args: Vec<String>) -> Result<String, EngineError> {
        self.calls.lock().unwrap().push(args.join(" "));
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        Ok(match args.as_slice() {
            ["state", "--json"] => json!({
                "now_ms": 9, "last_check_ms": 7, "about": "Alex.",
                "bots": [
                    { "name": "ada", "job": "Coordinate.", "chat": *self.ada_chat.lock().unwrap(),
                      "primary": self.primary.load(std::sync::atomic::Ordering::SeqCst) },
                    { "name": "notes", "job": "Draft release notes", "model": "made-up-model", "yolo": true,
                      "project": "/repo/comet/", "chat": *self.notes_chat.lock().unwrap(),
                      "routines": [
                        { "id": "r1", "instruction": "draft", "missed_open": 1, "message": "[routine r1] draft" },
                        { "id": "r2", "instruction": "tidy", "message": "[routine r2] tidy" }
                      ] }
                ]
            })
            .to_string(),
            ["show", "notes", "--json"] => {
                json!({ "bot": {}, "memory": "- No adjectives.", "log": "- 22:10 chat: Draft is ready", "routines": [] })
                    .to_string()
            }
            ["prompt", name] => format!("You are {name}, a graff Bot.\n"),
            ["due", "--claim", "--json", "--stale-after", "300"] => self.due.to_string(),
            ["set", name, "chat", id] => {
                if *name == "notes" {
                    *self.notes_chat.lock().unwrap() = (*id).to_owned();
                }
                String::new()
            }
            ["enable"] | ["disable"] => {
                self.on
                    .store(args[0] == "enable", std::sync::atomic::Ordering::SeqCst);
                String::new()
            }
            ["missed", "clear", ..] | ["rm", ..] | ["create", ..] | ["about", ..] => String::new(),
            other => return Err(EngineError::Other(format!("unexpected: {}", other.join(" ")))),
        })
    }

    fn enabled(&self) -> bool {
        self.on.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// A little workspace: this device, the comet project, and whatever chats
/// and sessions a test adds. Writes are recorded.
#[derive(Default)]
struct World {
    chats: Mutex<Vec<Value>>,
    sessions: Mutex<Vec<Value>>,
    writes: Mutex<Vec<(String, Value)>>,
}

fn stream(item: Value) -> RpcReply {
    RpcReply::Stream(futures::stream::iter(vec![item]).boxed())
}

#[async_trait]
impl RpcService for World {
    async fn handle(&self, method: &str, params: Value) -> Result<RpcReply, RpcError> {
        Ok(match method {
            methods::LOCAL_DEVICE => RpcReply::Value(json!({ "deviceId": "dev-local" })),
            methods::WATCH_SPACES => stream(json!([
                { "id": "space-far", "deviceId": "dev-studio", "path": "/repo/comet",
                  "createdAt": "2026-09-01T00:00:00Z" },
                { "id": "space-1", "deviceId": "dev-local", "path": "/repo/comet",
                  "createdAt": "2026-09-01T00:00:00Z" }
            ])),
            methods::WATCH_CHATS => stream(json!(*self.chats.lock().unwrap())),
            methods::WATCH_SESSIONS => stream(json!(*self.sessions.lock().unwrap())),
            methods::LIST_MODELS => RpcReply::Value(json!([{ "id": "sonnet", "label": "Sonnet" }])),
            methods::MUTATE | methods::QUEUE_COMMAND | methods::QUEUE_MESSAGE => {
                self.writes
                    .lock()
                    .unwrap()
                    .push((method.to_owned(), params));
                RpcReply::Value(json!({ "ok": true }))
            }
            other => return Err(RpcError::UnknownMethod(other.into())),
        })
    }
}

impl World {
    fn add_chat(&self, id: &str, archived: bool) {
        self.chats.lock().unwrap().push(json!({
            "id": id, "deviceId": "dev-local", "title": "notes", "archived": archived, "spaceId": "space-1",
            "config": { "harness": "graff", "model": null, "reasoning": null, "sandbox": "read-only" },
            "createdAt": "2026-09-01T00:00:00Z"
        }));
    }

    fn set_status(&self, chat: &str, status: &str) {
        *self.sessions.lock().unwrap() = vec![json!({
            "chatId": chat, "deviceId": "dev-local", "status": status,
            "updatedAt": chrono::Utc::now().to_rfc3339()
        })];
    }

    fn took(&self) -> Vec<(String, Value)> {
        std::mem::take(&mut *self.writes.lock().unwrap())
    }
}

fn run_params(value: Value) -> RunBotParams {
    serde_json::from_value(value).unwrap()
}

#[test]
fn an_older_graff_and_a_refusal_read_as_what_they_are() {
    let old = refusal(
        false,
        "",
        "error: unknown flag '--user' — graff --help lists them",
    )
    .unwrap();
    assert_eq!(old.to_string(), TOO_OLD);
    // A graff with project bots only prints its usage and exits 0.
    let usage = refusal(true, "usage: graff bot <command> [options]\n  list …", "").unwrap();
    assert_eq!(usage.to_string(), TOO_OLD);
    let said = refusal(false, "graff bot: a bot named 'notes' already exists", "").unwrap();
    assert_eq!(said.to_string(), "A bot named 'notes' already exists");
    assert!(refusal(true, "✓ created notes in ~/.graff/bots/notes", "").is_none());
    assert_eq!(
        parse::<BotsState>("not json").unwrap_err().to_string(),
        TOO_OLD
    );
}

#[test]
fn typed_text_always_follows_the_terminator_and_names_are_checked_first() {
    let args = |value: Value| action_args(&serde_json::from_value(value).unwrap());
    assert_eq!(
        args(json!({ "action": "create", "bot": "notes", "text": " --yolo is my job ", "project": "/repo/comet", "primary": true }))
            .unwrap(),
        ["create", "notes", "--project", "/repo/comet", "--primary", "--", "--yolo is my job"]
    );
    assert_eq!(
        args(json!({ "action": "routineAdd", "bot": "notes", "when": "@every 6h", "text": "--draft the notes" })).unwrap(),
        ["routine", "add", "notes", "--", "@every 6h", "--draft the notes"]
    );
    assert_eq!(
        args(json!({ "action": "forget", "bot": "notes", "text": "- old rule" })).unwrap(),
        ["forget", "notes", "--", "- old rule"]
    );
    assert_eq!(
        args(json!({ "action": "routinePause", "bot": "notes", "routine": "r1" })).unwrap(),
        ["routine", "pause", "notes", "r1"]
    );
    // Clearing what bots know about you is an explicit empty text.
    assert_eq!(
        args(json!({ "action": "about", "text": "" })).unwrap(),
        ["about", "--", ""]
    );
    for bad in [
        json!({ "action": "create", "bot": "--yolo", "text": "job" }),
        json!({ "action": "create", "bot": "notes" }),
        json!({ "action": "remove", "bot": "../x" }),
        json!({ "action": "routineRemove", "bot": "notes", "routine": "--json" }),
        json!({ "action": "routineAdd", "bot": "notes", "text": "no schedule" }),
        json!({ "action": "remember", "bot": "notes", "text": "  " }),
    ] {
        assert!(args(bad.clone()).is_err(), "{bad}");
    }
}

#[tokio::test]
async fn bots_are_off_until_turned_on_and_off_starts_nothing() {
    let cli = FakeCli::new();
    cli.on.store(false, std::sync::atomic::Ordering::SeqCst);
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    let off = bots.state().await.unwrap();
    assert!(!off.enabled && off.bots.is_empty());
    assert_eq!(bots.tick(&world).await.unwrap(), 0);
    assert_eq!(bots.detail("notes").await.unwrap_err().to_string(), OFF);
    let create: BotActionParams =
        serde_json::from_value(json!({ "action": "create", "bot": "notes", "text": "Draft" }))
            .unwrap();
    assert_eq!(bots.act(&world, create).await.unwrap_err().to_string(), OFF);
    let run = run_params(json!({ "bot": "notes", "message": "x" }));
    assert_eq!(bots.run(&world, run).await.unwrap_err().to_string(), OFF);
    assert!(cli.said().is_empty(), "off starts no graff");
    assert!(world.took().is_empty());

    // The one thing off allows is turning them on.
    let enable: BotActionParams = serde_json::from_value(json!({ "action": "enable" })).unwrap();
    let on = bots.act(&world, enable).await.unwrap();
    assert!(on.enabled);
    assert_eq!(on.bots.len(), 2);
    // A store that already has a primary bot keeps it: no second one is made.
    assert_eq!(cli.said(), ["enable", "state --json", "state --json"]);

    let disable: BotActionParams = serde_json::from_value(json!({ "action": "disable" })).unwrap();
    let off = bots.act(&world, disable).await.unwrap();
    assert!(!off.enabled && off.bots.is_empty());
    assert_eq!(bots.tick(&world).await.unwrap(), 0);
}

#[tokio::test]
async fn turning_bots_on_makes_the_main_bot_when_none_is_primary() {
    let cli = FakeCli::new();
    cli.on.store(false, std::sync::atomic::Ordering::SeqCst);
    cli.primary
        .store(false, std::sync::atomic::Ordering::SeqCst);
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    let enable: BotActionParams = serde_json::from_value(json!({ "action": "enable" })).unwrap();
    bots.act(&world, enable).await.unwrap();
    assert_eq!(
        cli.said(),
        [
            "enable".to_owned(),
            "state --json".to_owned(),
            format!("create {MAIN_BOT} --primary -- {MAIN_JOB}"),
            "state --json".to_owned(),
        ]
    );
    // Nothing is started for it: its thread begins with the user's first message.
    assert!(world.took().is_empty());
}

/// A chat, as the main bot's thread or as work it started.
fn chat_row(id: &str, title: &str, parent: Option<&str>) -> Value {
    json!({
        "id": id, "deviceId": "dev-local", "title": title, "archived": false, "spaceId": "space-1",
        "parentChatId": parent, "lastMessagePreview": "Bumped two.",
        "config": { "harness": "graff", "model": null, "reasoning": null, "sandbox": "workspace-write" },
        "createdAt": "2026-09-01T00:00:00Z"
    })
}

fn ended(chat: &str, turn: &str, peer_only: bool) -> Session {
    serde_json::from_value(json!({
        "chatId": chat, "deviceId": "dev-local", "status": "idle", "lastCompletedTurn": turn,
        "lastCompletedPeerOnly": peer_only, "updatedAt": chrono::Utc::now().to_rfc3339()
    }))
    .unwrap()
}

#[tokio::test]
async fn the_main_bot_hears_when_work_it_started_ends_and_only_that() {
    let cli = FakeCli::new();
    *cli.ada_chat.lock().unwrap() = "chat-ada".into();
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    *world.chats.lock().unwrap() = vec![
        chat_row("chat-ada", "ada", None),
        chat_row("w1", "Bump deps", Some("chat-ada")),
        // Another chat's subagent, and a chat nobody's bot started.
        chat_row("x1", "Someone else's", Some("chat-other")),
        chat_row("x2", "Typed by hand", None),
    ];
    let mut reports = reports::Reports::default();
    // The first look is how things already were.
    assert_eq!(
        bots.hear(&world, &mut reports, &[ended("w1", "t0", true)])
            .await
            .unwrap(),
        0
    );
    assert!(
        cli.said().is_empty(),
        "nothing changed, so graff was not asked"
    );

    let now = [
        ended("w1", "t1", true),
        ended("x1", "t1", true),
        ended("x2", "t1", true),
    ];
    assert_eq!(bots.hear(&world, &mut reports, &now).await.unwrap(), 1);
    let writes = world.took();
    assert_eq!(writes.len(), 1);
    let (method, params) = &writes[0];
    assert_eq!(method, methods::QUEUE_COMMAND);
    assert_eq!(params["chatId"], "chat-ada");
    let prompt = params["command"]["request"]["prompt"].as_str().unwrap();
    assert!(
        prompt.contains("\"Bump deps\" in comet (chat w1) finished its turn."),
        "{prompt}"
    );
    assert!(prompt.contains("Its last words: Bumped two."));
    // Not something the user typed.
    assert_eq!(params["command"]["request"]["turnOrigin"], "peer");

    // The same look again says nothing, and a turn the user typed in that
    // chat is theirs.
    assert_eq!(bots.hear(&world, &mut reports, &now).await.unwrap(), 0);
    assert_eq!(
        bots.hear(&world, &mut reports, &[ended("w1", "t2", false)])
            .await
            .unwrap(),
        0
    );
    assert!(world.took().is_empty());

    // A chat the main bot started while answering that report is a step
    // further from what the user asked for. Three steps are reported, with
    // the last one saying it is the last; a fourth is not.
    for (step, id) in [(2, "w2"), (3, "w3"), (4, "w4")] {
        let mut row = chat_row(id, "Follow-up", Some("chat-ada"));
        row["createdAt"] = json!(chrono::Utc::now().to_rfc3339());
        world.chats.lock().unwrap().push(row);
        let heard = bots
            .hear(&world, &mut reports, &[ended(id, "t1", true)])
            .await
            .unwrap();
        let writes = world.took();
        if step <= reports::MAX_STEPS {
            assert_eq!(heard, 1, "step {step}");
            let prompt = writes[0].1["command"]["request"]["prompt"]
                .as_str()
                .unwrap();
            assert_eq!(
                prompt.contains("last report in this chain"),
                step == reports::MAX_STEPS
            );
        } else {
            assert_eq!(heard, 0);
            assert!(writes.is_empty());
        }
    }

    // With bots off nothing is said and graff is not started.
    cli.on.store(false, std::sync::atomic::Ordering::SeqCst);
    let before = cli.said().len();
    assert_eq!(
        bots.hear(&world, &mut reports, &[ended("w1", "t3", true)])
            .await
            .unwrap(),
        0
    );
    assert_eq!(cli.said().len(), before);
    assert!(world.took().is_empty());
}

#[test]
fn the_switch_is_graffs_file_unless_the_environment_decides() {
    assert!(!flag_on(None, false));
    assert!(flag_on(None, true));
    assert!(flag_on(Some("1"), false));
    assert!(flag_on(Some("TRUE"), false));
    assert!(!flag_on(Some("0"), true));
    assert!(flag_on(Some("maybe"), true));
}

#[tokio::test]
async fn a_first_run_makes_the_bots_standing_chat_in_its_project() {
    let cli = FakeCli::new();
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    let ran = bots
        .run(
            &world,
            run_params(json!({ "bot": "notes", "message": "draft 0.4" })),
        )
        .await
        .unwrap();
    let chat_id = ran["chatId"].as_str().unwrap().to_owned();
    let writes = world.took();
    assert_eq!(writes.len(), 3, "createChat, renameChat, run");
    assert_eq!(writes[0].1["op"], "createChat");
    assert_eq!(writes[0].1["chatId"], chat_id);
    // The project on this device, not the same path on another one.
    assert_eq!(writes[0].1["spaceId"], "space-1");
    assert_eq!(writes[0].1["config"]["harness"], "graff");
    // A model this device does not offer is dropped, not a refused run.
    assert!(writes[0].1["config"]["model"].is_null());
    assert_eq!(writes[1].1["title"], "notes");
    let request = &writes[2].1["command"]["request"];
    assert_eq!(
        request["prompt"],
        "You are notes, a graff Bot.\n\ndraft 0.4"
    );
    assert_eq!(request["turnOrigin"], "peer");
    assert_eq!(request["cwd"], "/repo/comet");
    // The bot's own skip-approvals flag does not reach a chat.
    assert_eq!(request["autoApprove"], false);
    assert_eq!(request["sandbox"], "workspace-write");
    // graff remembers the chat before the turn is queued.
    assert!(cli.said().contains(&format!("set notes chat {chat_id}")));

    // A bot with no project gets a chat with no project.
    let ran = bots
        .run(
            &world,
            run_params(json!({ "bot": "ada", "message": "hello" })),
        )
        .await
        .unwrap();
    assert!(ran["chatId"].is_string());
    let writes = world.took();
    assert!(writes[0].1.get("spaceId").is_none() && writes[0].1.get("cwd").is_none());
    assert_eq!(writes[2].1["command"]["request"]["cwd"], "~");

    for (params, want) in [
        (json!({ "bot": "notes" }), "one of them"),
        (
            json!({ "bot": "notes", "message": "x", "routine": "r1" }),
            "one of them",
        ),
        (json!({ "bot": "notes", "routine": "r9" }), "no routine r9"),
        (
            json!({ "bot": "ghost", "message": "x" }),
            "no bot named ghost",
        ),
        (json!({ "bot": "--user", "message": "x" }), "No such bot"),
    ] {
        let err = bots
            .run(&world, run_params(params))
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains(want), "{err}");
    }
    assert!(world.took().is_empty(), "a refused run starts nothing");
}

#[tokio::test]
async fn later_runs_land_in_the_same_chat() {
    let cli = FakeCli::new();
    *cli.notes_chat.lock().unwrap() = "chat-notes".into();
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    world.add_chat("chat-notes", false);

    // A message: the conversation already has the standing text.
    let ran = bots
        .run(
            &world,
            run_params(json!({ "bot": "notes", "message": "shorter" })),
        )
        .await
        .unwrap();
    assert_eq!(ran["chatId"], "chat-notes");
    let writes = world.took();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].0, methods::QUEUE_COMMAND);
    assert_eq!(writes[0].1["chatId"], "chat-notes");
    assert_eq!(writes[0].1["command"]["request"]["prompt"], "shorter");
    // The chat's own settings stand.
    assert_eq!(writes[0].1["command"]["request"]["sandbox"], "read-only");

    // A routine: the current standing text goes with it, and running it now
    // settles the slot that was missed.
    bots.run(
        &world,
        run_params(json!({ "bot": "notes", "routine": "r1" })),
    )
    .await
    .unwrap();
    let writes = world.took();
    assert_eq!(
        writes[0].1["command"]["request"]["prompt"],
        "You are notes, a graff Bot.\n\n[routine r1] draft"
    );
    assert!(cli.said().contains(&"missed clear notes r1".to_owned()));

    // While a turn is running, or a question is open, the next one waits.
    for status in ["working", "awaitingInput"] {
        world.set_status("chat-notes", status);
        bots.run(
            &world,
            run_params(json!({ "bot": "notes", "message": "and this" })),
        )
        .await
        .unwrap();
        let writes = world.took();
        assert_eq!(writes.len(), 1, "{status}");
        assert_eq!(writes[0].0, methods::QUEUE_MESSAGE);
        assert_eq!(writes[0].1["text"], "and this");
        assert_eq!(writes[0].1["turnOrigin"], "peer");
    }

    // An archived chat is not written to: the bot gets a new one.
    world.chats.lock().unwrap().clear();
    world.add_chat("chat-notes", true);
    world.set_status("chat-notes", "idle");
    let ran = bots
        .run(
            &world,
            run_params(json!({ "bot": "notes", "message": "again" })),
        )
        .await
        .unwrap();
    assert_ne!(ran["chatId"], "chat-notes");
    assert_eq!(world.took()[0].1["op"], "createChat");
}

#[tokio::test]
async fn a_check_starts_each_due_routine_once_in_one_chat() {
    let cli = Arc::new(FakeCli {
        due: json!([
            { "bot": "notes", "id": "r1", "system": "You are notes.", "message": "[routine r1] draft" },
            { "bot": "notes", "id": "r2", "system": "You are notes.", "message": "[routine r2] tidy" },
            { "bot": "gone", "id": "r1", "system": "You are gone.", "message": "[routine r1] x" }
        ]),
        ..Arc::into_inner(FakeCli::new()).unwrap()
    });
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    assert_eq!(bots.tick(&world).await.unwrap(), 2);
    // Old slots are graff's to record as missed, not to run late.
    assert_eq!(cli.said()[0], "due --claim --json --stale-after 300");
    let writes = world.took();
    let creates: Vec<&Value> = writes
        .iter()
        .filter(|(_, p)| p["op"] == "createChat")
        .map(|(_, p)| p)
        .collect();
    assert_eq!(
        creates.len(),
        1,
        "the second routine uses the chat the first made"
    );
    let of = |method: &str| -> Vec<&Value> {
        writes
            .iter()
            .filter(|(m, _)| m == method)
            .map(|(_, p)| p)
            .collect()
    };
    let runs = of(methods::QUEUE_COMMAND);
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0]["chatId"], creates[0]["chatId"]);
    assert_eq!(
        runs[0]["command"]["request"]["prompt"],
        "You are notes.\n\n[routine r1] draft"
    );
    // The second waits behind the first in that chat, though the new chat
    // is not in the chat list yet.
    let held = of(methods::QUEUE_MESSAGE);
    assert_eq!(held.len(), 1);
    assert_eq!(held[0]["chatId"], creates[0]["chatId"]);
    assert_eq!(held[0]["text"], "You are notes.\n\n[routine r2] tidy");
    assert_eq!(
        cli.said()
            .iter()
            .filter(|c| c.starts_with("set notes chat "))
            .count(),
        1
    );
}

#[tokio::test]
async fn retiring_a_bot_archives_its_chat_and_detail_reads_its_memory() {
    let cli = FakeCli::new();
    *cli.notes_chat.lock().unwrap() = "chat-notes".into();
    let bots = Bots::with_cli(cli.clone());
    let world = World::default();
    let detail = bots.detail("notes").await.unwrap();
    assert_eq!(detail.memory, "- No adjectives.");
    assert!(bots.detail("../notes").await.is_err());

    let params: BotActionParams =
        serde_json::from_value(json!({ "action": "remove", "bot": "notes" })).unwrap();
    let state = bots.act(&world, params).await.unwrap();
    assert_eq!(state.about, "Alex.");
    assert!(cli.said().contains(&"rm notes".to_owned()));
    let writes = world.took();
    assert_eq!(writes.len(), 1);
    assert_eq!(
        writes[0].1,
        json!({ "op": "setChatArchived", "chatId": "chat-notes", "archived": true })
    );
}
