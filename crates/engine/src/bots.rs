//! graff Bots on this device (codegraff ADR 0333, 0334): the user's standing
//! roles in graff's home, each with one job, its own memory and routines.
//!
//! Bots are experimental and off until the user turns them on. The switch
//! is graff's (`graff bot enable`, a file in its home), so the terminal, this
//! engine and a bot's own chat agree. While it is off the engine starts no
//! process, checks no routine and reports no bots.
//!
//! graff owns the store and the wording of every prompt; this module runs
//! `graff bot --user …` and keeps nothing itself. What the engine adds:
//!
//! - A bot's run is a turn in its standing conversation, an ordinary graff
//!   chat, so its work, approvals and result are where the user already
//!   looks. The chat is created on the first run and remembered on the bot.
//! - While the engine runs it checks routines once a minute. A slot that
//!   came due more than five minutes before a check is not run late: graff
//!   records it, and the client shows it as "was due, did not run".
//!
//! Chats are reached through the engine's own RPC surface, so tests drive
//! this module with a recording service and canned graff output.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use harness_doc::SessionCommandPayload;
use harness_proto::{
    BotDetail, BotDue, BotRow, BotVerb, BotsState, Chat, ChatConfig, HarnessId, RunRequest,
    SandboxLevel, Session, SessionStatus, Space, TurnOrigin, valid_bot_name, valid_routine_id,
};
use harness_rpc::{RpcReply, RpcService, methods};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::EngineError;

/// Every command reads or rewrites a few small files; none runs a model.
const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(10);
/// How often routines are checked while the engine runs.
pub const TICK_EVERY: Duration = Duration::from_secs(60);
/// A slot older than this at a check was missed, not late.
pub const STALE_AFTER_SECS: u64 = 300;
/// A working row older than this is a crashed run (the clients' window).
const SESSION_STALE_SECS: i64 = 45;

pub const TOO_OLD: &str = "This graff can't run bots yet. Update graff to use them here.";
pub const OFF: &str = "Bots are off. Turn them on in Settings › Agents.";

/// Runs `graff bot --user <args>`.
#[async_trait]
pub trait BotCli: Send + Sync {
    async fn run(&self, args: Vec<String>) -> Result<String, EngineError>;
    /// Whether the user has turned bots on. Starts no process, so an engine
    /// with bots off never spawns graff to learn that.
    fn enabled(&self) -> bool;
}

/// The graff this engine runs chats with, under the home it signs graff in.
pub struct GraffCli {
    graff_home: PathBuf,
}

#[async_trait]
impl BotCli for GraffCli {
    async fn run(&self, args: Vec<String>) -> Result<String, EngineError> {
        let mut command = harness_adapters::graff_bot_command(&args)
            .await
            .map_err(|err| {
                EngineError::Other(match err {
                    harness_adapters::HarnessError::NotInstalled(_) => {
                        "The `graff` CLI was not found on this device — install it first.".into()
                    }
                    other => format!("Could not resolve the graff CLI: {other}"),
                })
            })?;
        command
            .stdin(harness_adapters::process::Stdio::null())
            .kill_on_drop(true);
        #[cfg(unix)]
        command.env("HOME", &self.graff_home);
        let output = tokio::time::timeout(COMMAND_TIMEOUT, command.output())
            .await
            .map_err(|_| {
                EngineError::Other(format!("graff bot {} did not finish in time.", args[0]))
            })?
            .map_err(|err| EngineError::Other(format!("Could not run graff bot: {err}")))?;
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        let stderr = String::from_utf8_lossy(&output.stderr);
        refusal(output.status.success(), &stdout, &stderr).map_or(Ok(stdout.clone()), Err)
    }

    fn enabled(&self) -> bool {
        // graff's own rule: `GRAFF_BOTS` decides when set, else its switch file.
        let marker = self.graff_home.join(".graff").join("bots").join("enabled");
        flag_on(
            std::env::var("GRAFF_BOTS").ok().as_deref(),
            marker.is_file(),
        )
    }
}

/// Why a `graff bot --user` run did not do what was asked, if it did not.
/// A graff from before per-user bots rejects `--user` or prints its usage.
fn refusal(success: bool, stdout: &str, stderr: &str) -> Option<EngineError> {
    if stderr.contains("unknown flag") || stdout.starts_with("usage: graff bot") {
        return Some(EngineError::Other(TOO_OLD.into()));
    }
    if success {
        return None;
    }
    let last = stdout
        .lines()
        .chain(stderr.lines())
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("graff exited with an error");
    let said = last.strip_prefix("graff bot: ").unwrap_or(last);
    let mut text = said.to_owned();
    if let Some(first) = text.get(..1) {
        text.replace_range(..1, &first.to_uppercase());
    }
    Some(EngineError::Other(text))
}

/// Whether bots are on: `GRAFF_BOTS=1` or `=0` decides for this process,
/// else the switch file `graff bot enable` writes.
fn flag_on(env: Option<&str>, marker: bool) -> bool {
    match env.map(str::to_ascii_lowercase).as_deref() {
        Some("1" | "true") => true,
        Some("0" | "false") => false,
        _ => marker,
    }
}

fn parse<T: DeserializeOwned>(stdout: &str) -> Result<T, EngineError> {
    serde_json::from_str(stdout).map_err(|_| EngineError::Other(TOO_OLD.into()))
}

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| (*a).to_owned()).collect()
}

fn other(text: impl Into<String>) -> EngineError {
    EngineError::Other(text.into())
}

/// `BotAction`'s parameters. Which fields count depends on the action.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BotActionParams {
    pub action: BotVerb,
    #[serde(default)]
    pub bot: Option<String>,
    #[serde(default)]
    pub routine: Option<String>,
    /// The job, model, project, instruction, memory entry or about text.
    #[serde(default)]
    pub text: Option<String>,
    /// A routine's schedule: `5m` (once) or `@every 2h`.
    #[serde(default)]
    pub when: Option<String>,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub primary: Option<bool>,
}

/// `RunBot`'s parameters: a message for the bot, or one of its routines.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunBotParams {
    pub bot: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub routine: Option<String>,
}

fn name_of(bot: &Option<String>) -> Result<&str, EngineError> {
    let name = bot.as_deref().map(str::trim).unwrap_or_default();
    if valid_bot_name(name) {
        Ok(name)
    } else {
        Err(other(
            "A bot's name is lowercase letters, digits, - and _ (32 at most).",
        ))
    }
}

fn routine_of(routine: &Option<String>) -> Result<&str, EngineError> {
    let id = routine.as_deref().map(str::trim).unwrap_or_default();
    if valid_routine_id(id) {
        Ok(id)
    } else {
        Err(other("Say which routine."))
    }
}

fn text_of(text: &Option<String>) -> &str {
    text.as_deref().map(str::trim).unwrap_or_default()
}

/// The `graff bot --user` arguments for an action. Text a person typed
/// always follows `--`, so it is never read as a flag.
pub fn action_args(p: &BotActionParams) -> Result<Vec<String>, EngineError> {
    let text = text_of(&p.text);
    let need = |what: &str| {
        if text.is_empty() {
            Err(other(format!("Say {what}.")))
        } else {
            Ok(text)
        }
    };
    Ok(match p.action {
        BotVerb::Enable => words(&["enable"]),
        BotVerb::Disable => words(&["disable"]),
        BotVerb::Create => {
            let mut args = words(&["create", name_of(&p.bot)?]);
            if let Some(project) = p
                .project
                .as_deref()
                .map(str::trim)
                .filter(|v| !v.is_empty())
            {
                args.extend(words(&["--project", project]));
            }
            if p.primary == Some(true) {
                args.push("--primary".into());
            }
            args.extend(words(&["--", need("what the bot's job is")?]));
            args
        }
        BotVerb::Remove => words(&["rm", name_of(&p.bot)?]),
        BotVerb::SetJob => words(&["set", name_of(&p.bot)?, "job", "--", need("the job")?]),
        BotVerb::SetModel => words(&["set", name_of(&p.bot)?, "model", "--", text]),
        BotVerb::SetProject => words(&["set", name_of(&p.bot)?, "project", "--", text]),
        BotVerb::SetPrimary => words(&[
            "set",
            name_of(&p.bot)?,
            "primary",
            if p.primary == Some(false) {
                "false"
            } else {
                "true"
            },
        ]),
        BotVerb::RoutineAdd => {
            let when = text_of(&p.when);
            if when.is_empty() {
                return Err(other("Say when it runs: 30m (once) or @every 2h."));
            }
            words(&[
                "routine",
                "add",
                name_of(&p.bot)?,
                "--",
                when,
                need("what the routine does")?,
            ])
        }
        BotVerb::RoutinePause | BotVerb::RoutineResume | BotVerb::RoutineRemove => words(&[
            "routine",
            match p.action {
                BotVerb::RoutinePause => "pause",
                BotVerb::RoutineResume => "resume",
                _ => "rm",
            },
            name_of(&p.bot)?,
            routine_of(&p.routine)?,
        ]),
        BotVerb::MissedClear => {
            words(&["missed", "clear", name_of(&p.bot)?, routine_of(&p.routine)?])
        }
        BotVerb::Remember => words(&[
            "remember",
            name_of(&p.bot)?,
            "--",
            need("what to remember")?,
        ]),
        BotVerb::Forget => words(&["forget", name_of(&p.bot)?, "--", need("which entry")?]),
        BotVerb::About => words(&["about", "--", text]),
    })
}

/// The user's bots, through one graff.
#[derive(Clone)]
pub struct Bots {
    cli: Arc<dyn BotCli>,
}

impl Bots {
    pub fn on_device(graff_home: &Path) -> Self {
        Self::with_cli(Arc::new(GraffCli {
            graff_home: graff_home.to_owned(),
        }))
    }

    pub fn with_cli(cli: Arc<dyn BotCli>) -> Self {
        Self { cli }
    }

    /// Every bot, its routines and the last check. Empty and marked off,
    /// without starting graff, while bots are off.
    pub async fn state(&self) -> Result<BotsState, EngineError> {
        if !self.cli.enabled() {
            return Ok(BotsState::default());
        }
        let mut state: BotsState = parse(&self.cli.run(words(&["state", "--json"])).await?)?;
        state.enabled = true;
        Ok(state)
    }

    pub async fn detail(&self, bot: &str) -> Result<BotDetail, EngineError> {
        if !self.cli.enabled() {
            return Err(other(OFF));
        }
        if !valid_bot_name(bot) {
            return Err(other("No such bot."));
        }
        parse(&self.cli.run(words(&["show", bot, "--json"])).await?)
    }

    /// Apply one change and return the refreshed state. Retiring a bot also
    /// archives its standing conversation.
    pub async fn act(
        &self,
        rpc: &dyn RpcService,
        p: BotActionParams,
    ) -> Result<BotsState, EngineError> {
        let args = action_args(&p)?;
        // While bots are off the only thing to do is turn them on.
        if !self.cli.enabled() && !matches!(p.action, BotVerb::Enable | BotVerb::Disable) {
            return Err(other(OFF));
        }
        let chat = match p.action {
            BotVerb::Remove => {
                let name = name_of(&p.bot)?;
                let before = self.state().await?;
                before
                    .bots
                    .into_iter()
                    .find(|b| b.name == name)
                    .map(|b| b.chat)
                    .filter(|c| !c.is_empty())
            }
            _ => None,
        };
        self.cli.run(args).await?;
        if let Some(chat_id) = chat {
            // Its history stays readable under archived chats.
            let _ = call(
                rpc,
                methods::MUTATE,
                json!({ "op": "setChatArchived", "chatId": chat_id, "archived": true }),
            )
            .await;
        }
        self.state().await
    }

    /// One run of a bot in its standing conversation. Returns the chat.
    pub async fn run(&self, rpc: &dyn RpcService, p: RunBotParams) -> Result<Value, EngineError> {
        if !self.cli.enabled() {
            return Err(other(OFF));
        }
        if !valid_bot_name(&p.bot) {
            return Err(other("No such bot."));
        }
        let state = self.state().await?;
        let Some(row) = state.bots.iter().find(|b| b.name == p.bot) else {
            return Err(other(format!("There is no bot named {}.", p.bot)));
        };
        let message = p
            .message
            .as_deref()
            .map(str::trim)
            .filter(|m| !m.is_empty());
        let (turn, routine) = match (message, p.routine.as_deref()) {
            (Some(message), None) => (message.to_owned(), None),
            (None, Some(id)) => {
                let Some(routine) = row.routines.iter().find(|r| r.id == id) else {
                    return Err(other(format!("{} has no routine {id}.", p.bot)));
                };
                (routine.message.clone(), Some(routine.id.clone()))
            }
            _ => return Err(other("Send a message or pick a routine, one of them.")),
        };
        let standing = self.cli.run(words(&["prompt", &p.bot])).await?;
        // A routine always carries the bot's current standing text: its
        // memory may have changed since the conversation began.
        let (chat_id, _) = self
            .deliver(rpc, row, &row.chat, &standing, &turn, routine.is_some())
            .await?;
        if let Some(id) = &routine {
            // Running it now is the user dealing with a slot that was missed.
            let _ = self.cli.run(words(&["missed", "clear", &p.bot, id])).await;
        }
        Ok(json!({ "chatId": chat_id, "bot": p.bot, "routine": routine }))
    }

    /// Check routines once: start a turn for each one that is due now, and
    /// let graff record the ones that came due while nothing was checking.
    /// Returns how many turns were started.
    pub async fn tick(&self, rpc: &dyn RpcService) -> Result<usize, EngineError> {
        if !self.cli.enabled() {
            return Ok(0);
        }
        let stale = STALE_AFTER_SECS.to_string();
        let due: Vec<BotDue> = parse(
            &self
                .cli
                .run(words(&[
                    "due",
                    "--claim",
                    "--json",
                    "--stale-after",
                    &stale,
                ]))
                .await?,
        )?;
        if due.is_empty() {
            return Ok(0);
        }
        let state = self.state().await?;
        // A chat made for a bot's first routine takes its second too. The
        // new row may not be in the chat list yet, and it has a turn queued,
        // so the second waits behind it.
        let mut made: HashMap<String, String> = HashMap::new();
        let mut started = 0;
        for row in &due {
            let Some(bot) = state.bots.iter().find(|b| b.name == row.bot) else {
                continue;
            };
            let sent = match made.get(&row.bot) {
                Some(chat_id) => queue_message(rpc, chat_id, framed(&row.system, &row.message))
                    .await
                    .map(|()| (chat_id.clone(), false)),
                None => {
                    self.deliver(rpc, bot, &bot.chat, &row.system, &row.message, true)
                        .await
                }
            };
            match sent {
                Ok((chat_id, created)) => {
                    if created {
                        made.insert(row.bot.clone(), chat_id);
                    }
                    started += 1;
                }
                Err(err) => {
                    tracing::warn!(bot = %row.bot, routine = %row.id, "bot routine did not start: {err}")
                }
            }
        }
        Ok(started)
    }

    /// Put a turn into the bot's standing conversation, creating it first if
    /// the bot has none (or it was archived). `with_standing` sends the
    /// standing text ahead of the turn; a new conversation always gets it.
    /// Returns the chat, and whether it was made just now.
    async fn deliver(
        &self,
        rpc: &dyn RpcService,
        bot: &BotRow,
        chat_id: &str,
        standing: &str,
        turn: &str,
        with_standing: bool,
    ) -> Result<(String, bool), EngineError> {
        let framed = framed(standing, turn);
        let chats: Vec<Chat> = snapshot(rpc, methods::WATCH_CHATS).await?;
        let spaces: Vec<Space> = snapshot(rpc, methods::WATCH_SPACES).await?;
        if let Some(chat) = chats.iter().find(|c| c.id == chat_id && !c.archived) {
            let text = if with_standing {
                framed
            } else {
                turn.trim().to_owned()
            };
            let sessions: Vec<Session> = snapshot(rpc, methods::WATCH_SESSIONS).await?;
            if busy(&sessions, chat) {
                queue_message(rpc, &chat.id, text).await?;
                return Ok((chat.id.clone(), false));
            }
            let space = chat
                .space_id
                .as_deref()
                .and_then(|id| spaces.iter().find(|s| s.id == id));
            let cwd = chat
                .cwd
                .clone()
                .or_else(|| space.map(|s| s.path.clone()))
                .unwrap_or_else(|| "~".into());
            queue_run(rpc, &chat.id, chat.config.clone(), cwd, text).await?;
            return Ok((chat.id.clone(), false));
        }

        let device = call(rpc, methods::LOCAL_DEVICE, json!({})).await?;
        let device_id = device["deviceId"].as_str().unwrap_or_default().to_owned();
        let space = (!bot.project.is_empty())
            .then(|| {
                spaces
                    .iter()
                    .find(|s| s.device_id == device_id && same_folder(&s.path, &bot.project))
            })
            .flatten();
        let config = ChatConfig {
            harness: HarnessId::Graff,
            model: offered_model(rpc, &bot.model).await,
            reasoning: None,
            model_options: Default::default(),
            sandbox: SandboxLevel::WorkspaceWrite,
            chat_mode: false,
        };
        let new_id = uuid::Uuid::new_v4().to_string();
        let mut create = json!({
            "op": "createChat", "chatId": new_id, "deviceId": device_id, "config": config,
        });
        match space {
            Some(space) => create["spaceId"] = json!(space.id),
            None if !bot.project.is_empty() => create["cwd"] = json!(bot.project),
            None => {}
        }
        call(rpc, methods::MUTATE, create).await?;
        call(
            rpc,
            methods::MUTATE,
            json!({ "op": "renameChat", "chatId": new_id, "title": bot.name }),
        )
        .await?;
        // Remembered before the turn is queued: a turn in a conversation the
        // bot does not know about would be made again by its next run.
        self.cli
            .run(words(&["set", &bot.name, "chat", &new_id]))
            .await?;
        let cwd = match space {
            Some(space) => space.path.clone(),
            None if !bot.project.is_empty() => bot.project.clone(),
            None => "~".into(),
        };
        queue_run(rpc, &new_id, Some(config), cwd, framed).await?;
        Ok((new_id, true))
    }
}

/// A bot's standing text, then the turn: one message.
fn framed(standing: &str, turn: &str) -> String {
    format!("{}\n\n{}", standing.trim(), turn.trim())
}

/// Held for the end of the turn that is running in the chat.
async fn queue_message(
    rpc: &dyn RpcService,
    chat_id: &str,
    text: String,
) -> Result<(), EngineError> {
    call(
        rpc,
        methods::QUEUE_MESSAGE,
        json!({ "chatId": chat_id, "text": text, "turnOrigin": TurnOrigin::Peer }),
    )
    .await?;
    Ok(())
}

async fn queue_run(
    rpc: &dyn RpcService,
    chat_id: &str,
    config: Option<ChatConfig>,
    cwd: String,
    prompt: String,
) -> Result<(), EngineError> {
    let request = RunRequest {
        // Not something the person typed: the bot's own turn.
        turn_origin: TurnOrigin::Peer,
        prompt,
        harness: Some(config.as_ref().map_or(HarnessId::Graff, |c| c.harness)),
        model: config.as_ref().and_then(|c| c.model.clone()),
        reasoning: config.as_ref().and_then(|c| c.reasoning),
        model_options: config
            .as_ref()
            .map(|c| c.model_options.clone())
            .unwrap_or_default(),
        cwd,
        sandbox: config
            .as_ref()
            .map_or(SandboxLevel::WorkspaceWrite, |c| c.sandbox),
        // Approvals follow the chat, whatever the bot's own flag says.
        auto_approve: false,
        resume: None,
        attachments: Vec::new(),
        worktree: None,
    };
    let command = SessionCommandPayload::Run {
        request,
        message_id: uuid::Uuid::new_v4().to_string(),
    };
    call(
        rpc,
        methods::QUEUE_COMMAND,
        json!({ "chatId": chat_id, "command": command }),
    )
    .await?;
    Ok(())
}

/// Whether a chat has a turn running or a question open, so a new turn has
/// to wait its turn.
fn busy(sessions: &[Session], chat: &Chat) -> bool {
    let mine: Vec<&Session> = sessions.iter().filter(|s| s.chat_id == chat.id).collect();
    let session = mine
        .iter()
        .find(|s| s.device_id == chat.device_id)
        .or_else(|| mine.iter().max_by_key(|s| s.updated_at));
    session.is_some_and(|s| match s.status {
        SessionStatus::AwaitingInput => true,
        SessionStatus::Working => {
            chrono::Utc::now() - s.updated_at <= chrono::Duration::seconds(SESSION_STALE_SECS)
        }
        SessionStatus::Idle | SessionStatus::Errored => false,
    })
}

fn same_folder(a: &str, b: &str) -> bool {
    a.trim_end_matches(['/', '\\']) == b.trim_end_matches(['/', '\\'])
}

/// The bot's model, if graff on this device offers it by that id. An
/// unknown one would refuse the whole run, so the chat takes the default.
async fn offered_model(rpc: &dyn RpcService, model: &str) -> Option<String> {
    if model.is_empty() {
        return None;
    }
    let listed = call(rpc, methods::LIST_MODELS, json!({ "harness": "graff" }))
        .await
        .ok()?;
    listed
        .as_array()?
        .iter()
        .any(|m| m["id"].as_str() == Some(model))
        .then(|| model.to_owned())
}

async fn call(rpc: &dyn RpcService, method: &str, params: Value) -> Result<Value, EngineError> {
    match rpc.handle(method, params).await {
        Ok(RpcReply::Value(value)) => Ok(value),
        Ok(RpcReply::Stream(_)) => Err(other(format!("{method} is a stream"))),
        Err(err) => Err(other(err.to_string())),
    }
}

/// The first item of a watch stream: the list as it is now.
async fn snapshot<T: DeserializeOwned>(
    rpc: &dyn RpcService,
    method: &str,
) -> Result<T, EngineError> {
    let value = match rpc.handle(method, json!({})).await {
        Ok(RpcReply::Stream(mut stream)) => tokio::time::timeout(SNAPSHOT_TIMEOUT, stream.next())
            .await
            .ok()
            .flatten()
            .ok_or_else(|| other(format!("{method} gave no snapshot")))?,
        Ok(RpcReply::Value(value)) => value,
        Err(err) => return Err(other(err.to_string())),
    };
    serde_json::from_value(value).map_err(|err| other(format!("{method}: {err}")))
}

/// Check routines once a minute for as long as the engine runs. The first
/// check comes right away, so what was missed while the engine was down is
/// on record before a client asks.
pub fn spawn_ticker(rpc: Arc<dyn RpcService>, bots: Bots) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut every = tokio::time::interval(TICK_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut said = String::new();
        loop {
            every.tick().await;
            match bots.tick(rpc.as_ref()).await {
                Ok(_) => said.clear(),
                // Once per distinct failure, not once a minute.
                Err(err) => {
                    let text = err.to_string();
                    if text != said {
                        tracing::warn!("bot routines were not checked: {text}");
                        said = text;
                    }
                }
            }
        }
    })
}

#[cfg(test)]
#[path = "bots_tests.rs"]
mod tests;
