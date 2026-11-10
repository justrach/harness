//! Bots (codegraff ADR 0333): a graff Bot is a standing role kept in a
//! project's `.graff/bots/<name>/`, with its own memory, work log and
//! scheduled routines.
//!
//! graff owns the store and the wording of every prompt. These tools read
//! both through `graff bot … --json` and start each run as an ordinary graff
//! chat, so the work happens where its owner can watch it, answer its
//! approvals and steer it. A bot's standing text travels as the start of the
//! chat's first message.

use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use async_trait::async_trait;
use harness_proto::{HarnessId, Space};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::graff_peer::graff_executable;
use super::{CreateChatArgs, ToolDef, Tools};

/// Every command here reads or rewrites a few small files; none runs a model.
const BOT_TIMEOUT: Duration = Duration::from_secs(20);

pub(super) fn catalog() -> Vec<ToolDef> {
    let project = json!({
        "type": "string",
        "description": "Project id, path, or name. Defaults to the project of the chat you are speaking from."
    });
    vec![
        ToolDef {
            name: "list_bots",
            description: "graff Bots in a project: standing roles that each hold one job and keep their own memory, work log and scheduled routines (.graff/bots). Shows each bot's routines, when each runs next, and which are due now. Create and edit bots with `graff bot` in the project folder.",
            input_schema: json!({ "type": "object", "properties": { "project": project } }),
        },
        ToolDef {
            name: "run_bot",
            description: "Start one run of a bot as a new graff chat in its project, so its work, approvals and result are visible there. Pass message to give it a task, or routine to run one of its routines now without moving the routine's schedule. Returns the new chat id.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "project": project,
                    "bot": { "type": "string", "description": "The bot's name (see list_bots)." },
                    "message": { "type": "string", "description": "What the bot should do in this run." },
                    "routine": { "type": "string", "description": "A routine id of this bot, e.g. r1, instead of a message." },
                    "wait": { "type": "boolean", "default": false, "description": "Block until the run's first turn finishes and return the reply. From a chat, returns a status snapshot immediately." },
                    "timeout_secs": { "type": "integer", "minimum": 1, "maximum": 3600, "default": 600 }
                },
                "required": ["bot"]
            }),
        },
        ToolDef {
            name: "run_due_bots",
            description: "Start a graff chat for every bot routine in a project that is due now, and move each one to its next slot so it is not started twice. Nothing runs a routine by itself: call this on the cadence you want routines checked. Returns the chats it started.",
            input_schema: json!({ "type": "object", "properties": { "project": project } }),
        },
    ]
}

pub(super) fn handles(name: &str) -> bool {
    catalog().iter().any(|t| t.name == name)
}

/// Runs `graff bot <args>` in a project folder and returns what it printed.
#[async_trait]
pub trait BotCli: Send + Sync {
    async fn bot(&self, folder: &Path, args: &[&str]) -> anyhow::Result<String>;
}

/// The graff Harness runs chats with.
#[derive(Default)]
pub struct GraffBots {
    /// A graff from before bots reads `bot list` as a prompt and would spend
    /// a model call on it, so the help text is checked first. Only a yes is
    /// kept: graff can be updated while this server runs.
    has_bots: AtomicBool,
}

async fn graff(folder: &Path, args: &[&str]) -> anyhow::Result<std::process::Output> {
    let program = graff_executable();
    let run = tokio::process::Command::new(&program)
        .args(args)
        .current_dir(folder)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .output();
    tokio::time::timeout(BOT_TIMEOUT, run)
        .await
        .map_err(|_| {
            anyhow!(
                "graff {} timed out after {}s",
                args.join(" "),
                BOT_TIMEOUT.as_secs()
            )
        })?
        .with_context(|| format!("could not run {}", program.display()))
}

/// Whether a graff's help text lists the `bot` command.
pub(super) fn help_lists_bots(help: &str) -> bool {
    help.lines()
        .any(|line| line.trim_start().starts_with("graff bot "))
}

#[async_trait]
impl BotCli for GraffBots {
    async fn bot(&self, folder: &Path, args: &[&str]) -> anyhow::Result<String> {
        if !self.has_bots.load(Ordering::Relaxed) {
            let help = graff(folder, &["--help"]).await?;
            if !help_lists_bots(&String::from_utf8_lossy(&help.stdout)) {
                bail!("this graff has no `graff bot` command; update graff to use bots");
            }
            self.has_bots.store(true, Ordering::Relaxed);
        }
        let mut argv = vec!["bot"];
        argv.extend_from_slice(args);
        let output = graff(folder, &argv).await?;
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            let reason = [stdout, stderr]
                .into_iter()
                .find(|s| !s.is_empty())
                .unwrap_or_else(|| output.status.to_string());
            bail!("{reason}");
        }
        Ok(stdout)
    }
}

#[derive(Deserialize)]
struct Bot {
    name: String,
    job: String,
    #[serde(default)]
    model: String,
    #[serde(default)]
    yolo: bool,
}

#[derive(Deserialize)]
struct Routine {
    bot: String,
    id: String,
    instruction: String,
    when: String,
    #[serde(default)]
    paused: bool,
    #[serde(default)]
    done: bool,
    #[serde(default)]
    runs: u32,
    /// The turn that runs it now.
    message: String,
}

#[derive(Deserialize)]
struct Due {
    bot: String,
    id: String,
    instruction: String,
    system: String,
    message: String,
}

fn rows<T: DeserializeOwned>(command: &str, stdout: &str) -> anyhow::Result<Vec<T>> {
    serde_json::from_str(stdout)
        .with_context(|| format!("graff bot {command} did not print the JSON this Harness reads"))
}

/// A bot's standing text and the turn, as the one message that starts a chat.
pub(super) fn first_message(system: &str, message: &str) -> String {
    format!("{}\n\n{}", system.trim(), message.trim())
}

#[derive(Deserialize, Default)]
struct ProjectArgs {
    project: Option<String>,
}

#[derive(Deserialize)]
struct RunArgs {
    project: Option<String>,
    bot: String,
    message: Option<String>,
    routine: Option<String>,
    #[serde(default)]
    wait: bool,
    timeout_secs: Option<u64>,
}

fn given(value: &Option<String>) -> Option<&str> {
    value.as_deref().map(str::trim).filter(|v| !v.is_empty())
}

impl Tools {
    pub(super) async fn call_bot_tool(&self, name: &str, args: Value) -> Result<Value, String> {
        let result = match name {
            "list_bots" => self.list_bots(super::parse(args)?).await,
            "run_bot" => self.run_bot(super::parse(args)?).await,
            "run_due_bots" => self.run_due_bots(super::parse(args)?).await,
            other => return Err(format!("unknown tool: {other}")),
        };
        result.map_err(|e| e.to_string())
    }

    /// The project whose bots a call is about. Bots are files in the project
    /// folder, so the project has to be hosted on this device.
    async fn bot_space(&self, project: &Option<String>) -> anyhow::Result<Space> {
        let space = match given(project) {
            Some(key) => self.harness.resolve_space(key).await?,
            None => {
                let Some(chat_id) = self.harness.origin().chat_id.clone() else {
                    bail!("name the project: this server is not speaking for a chat");
                };
                let chat = self.harness.resolve_chat(&chat_id).await?;
                let Some(space_id) = chat.space_id else {
                    bail!("this chat has no project; name one (see list_projects)");
                };
                self.harness.resolve_space(&space_id).await?
            }
        };
        if space.device_id != self.harness.local_device_id().await? {
            bail!(
                "bots are files in the project folder, and {} is hosted on another device; ask a chat on that device",
                space.display_name()
            );
        }
        Ok(space)
    }

    async fn bots_in(&self, space: &Space) -> anyhow::Result<Vec<Bot>> {
        let out = self
            .bots
            .bot(Path::new(&space.path), &["list", "--json"])
            .await?;
        rows("list", &out)
    }

    async fn list_bots(&self, args: ProjectArgs) -> anyhow::Result<Value> {
        let space = self.bot_space(&args.project).await?;
        let folder = Path::new(&space.path);
        let bots = self.bots_in(&space).await?;
        let routines: Vec<Routine> = rows(
            "routine list",
            &self
                .bots
                .bot(folder, &["routine", "list", "--json"])
                .await?,
        )?;
        let due: Vec<Due> = rows("due", &self.bots.bot(folder, &["due", "--json"]).await?)?;
        let listed: Vec<Value> = bots
            .iter()
            .map(|bot| {
                let routines: Vec<Value> = routines
                    .iter()
                    .filter(|r| r.bot == bot.name)
                    .map(|r| {
                        json!({
                            "id": r.id,
                            "instruction": r.instruction,
                            "when": r.when,
                            "paused": r.paused,
                            "done": r.done,
                            "runs": r.runs,
                            "due": due.iter().any(|d| d.bot == r.bot && d.id == r.id),
                        })
                    })
                    .collect();
                json!({
                    "name": bot.name,
                    "job": bot.job,
                    "model": (!bot.model.is_empty()).then_some(&bot.model),
                    "skipsApprovals": bot.yolo,
                    "routines": routines,
                })
            })
            .collect();
        let mut result = json!({
            "project": { "id": space.id, "name": space.display_name(), "path": space.path },
            "bots": listed,
        });
        if bots.is_empty() {
            result["note"] = json!(
                "No bots in this project yet. Create one in its folder: graff bot create NAME \"the one job it holds\""
            );
        }
        Ok(result)
    }

    async fn run_bot(&self, args: RunArgs) -> anyhow::Result<Value> {
        let space = self.bot_space(&args.project).await?;
        let folder = Path::new(&space.path);
        let name = args.bot.trim();
        let bots = self.bots_in(&space).await?;
        let Some(bot) = bots.iter().find(|b| b.name == name) else {
            let known: Vec<&str> = bots.iter().map(|b| b.name.as_str()).collect();
            bail!(
                "no bot named {name:?} in {}; it has: {}",
                space.display_name(),
                if known.is_empty() {
                    "none".to_owned()
                } else {
                    known.join(", ")
                }
            );
        };
        let (title, message) = match (given(&args.message), given(&args.routine)) {
            (Some(message), None) => (bot.name.clone(), message.to_owned()),
            (None, Some(id)) => {
                let routines: Vec<Routine> = rows(
                    "routine list",
                    &self
                        .bots
                        .bot(folder, &["routine", "list", name, "--json"])
                        .await?,
                )?;
                let Some(routine) = routines.into_iter().find(|r| r.bot == name && r.id == id)
                else {
                    bail!("{name} has no routine {id:?} (see list_bots)");
                };
                (format!("{name}: {id}"), routine.message)
            }
            _ => bail!("pass message or routine, one of them"),
        };
        let system = self.bots.bot(folder, &["prompt", name]).await?;
        self.start_bot_chat(
            &space,
            bot,
            title,
            &system,
            &message,
            args.wait,
            args.timeout_secs,
        )
        .await
    }

    async fn run_due_bots(&self, args: ProjectArgs) -> anyhow::Result<Value> {
        let space = self.bot_space(&args.project).await?;
        let folder = Path::new(&space.path);
        let bots = self.bots_in(&space).await?;
        // From here each row is claimed: graff has moved it to its next slot.
        let due: Vec<Due> = rows(
            "due",
            &self.bots.bot(folder, &["due", "--claim", "--json"]).await?,
        )?;
        let mut started = Vec::new();
        let mut failed = Vec::new();
        for row in &due {
            let run = match bots.iter().find(|b| b.name == row.bot) {
                Some(bot) => {
                    let title = format!("{}: {}", row.bot, row.id);
                    self.start_bot_chat(&space, bot, title, &row.system, &row.message, false, None)
                        .await
                }
                None => Err(anyhow!("its bot is gone")),
            };
            match run {
                Ok(chat) => started.push(json!({
                    "bot": row.bot,
                    "routine": row.id,
                    "instruction": row.instruction,
                    "chatId": chat["chatId"],
                })),
                Err(err) => failed.push(json!({
                    "bot": row.bot,
                    "routine": row.id,
                    "error": err.to_string(),
                })),
            }
        }
        let mut result = json!({ "started": started });
        if !failed.is_empty() {
            result["failed"] = json!(failed);
            result["note"] = json!(
                "A failed routine was already moved to its next slot. Run it now with run_bot and its routine id."
            );
        } else if due.is_empty() {
            result["note"] = json!("Nothing is due.");
        }
        Ok(result)
    }

    #[allow(clippy::too_many_arguments)]
    async fn start_bot_chat(
        &self,
        space: &Space,
        bot: &Bot,
        title: String,
        system: &str,
        message: &str,
        wait: bool,
        timeout_secs: Option<u64>,
    ) -> anyhow::Result<Value> {
        // The bot's model is a graff model name. One this device does not
        // offer would refuse the whole run, so the chat takes graff's default.
        let offered = self
            .harness
            .models(HarnessId::Graff)
            .await
            .unwrap_or_default();
        let known = offered.is_empty() || offered.iter().any(|m| m.id == bot.model);
        let model = (!bot.model.is_empty() && known).then(|| bot.model.clone());
        let mut created = self
            .create_chat(CreateChatArgs {
                project: Some(space.id.clone()),
                harness: Some("graff".to_owned()),
                model,
                title: Some(title),
                prompt: Some(first_message(system, message)),
                wait,
                timeout_secs,
                ..Default::default()
            })
            .await?;
        created["bot"] = json!(bot.name);
        if !bot.model.is_empty() && !known {
            created["modelIgnored"] = json!(bot.model);
        }
        Ok(created)
    }
}
