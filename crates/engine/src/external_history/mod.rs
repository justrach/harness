//! Conversations from outside Harness: Claude Code, Codex and graff sessions
//! found on disk, listed for `/resume` and imported as ordinary chats.
//!
//! Each tool keeps its own history (`~/.claude/projects`, `~/.codex/sessions`,
//! `<project>/.graff/sessions`). Nothing here writes to those files. An import
//! reads one session, keeps what the person saw (their prompts, the agent's
//! replies, and a row per tool call with a one-line result) and writes it as a
//! chat doc plus a registry row, through the same paths a live chat uses, so
//! it searches, syncs and shows on the phone apps like any other chat.
//!
//! Tool arguments and full outputs are not carried over: the rows say what ran
//! and how it ended. The chat id is derived from the source and the native
//! session id, so importing twice is a no-op, and a session Harness itself
//! started (its native id is already on a chat row) is never offered.

mod claude;
mod codex;
mod graff;

use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{TimeZone, Utc};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionDoc, SessionMessageEntry};
use harness_proto::{Chat, ChatConfig, HarnessId, SandboxLevel, ToolCall};
use harness_sync::DocsStore;
use serde::{Deserialize, Serialize};

use crate::EngineError;
use crate::chat2_host::CHAT2_DOC_EPOCH;
use crate::workspace_host::WorkspaceHost;

/// Sessions with no more than this many characters of prompt are skipped as
/// empty starts (a session opened and closed).
const MIN_TITLE_CHARS: usize = 2;
/// Title length in the picker.
const TITLE_CHARS: usize = 90;
/// Lines read from the head of a file to find its first prompt.
const HEAD_LINES: usize = 400;
/// Characters of the last reply kept as the chat's preview.
const PREVIEW_CHARS: usize = 160;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Claude,
    Codex,
    Graff,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Graff => "graff",
        }
    }

    fn slug(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Graff => "graff",
        }
    }

    /// The chat an imported session becomes. Stable, so a second import finds it.
    pub fn chat_id(self, native_id: &str) -> String {
        format!("ext-{}-{native_id}", self.slug())
    }
}

/// One session found on disk, before it is imported.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalSession {
    pub source: Source,
    /// The tool's own session id.
    pub id: String,
    pub path: String,
    pub cwd: Option<String>,
    /// The first prompt, one line.
    pub title: String,
    /// Epoch millis of the first and last write.
    pub started_at: i64,
    pub updated_at: i64,
    pub size: u64,
}

/// Where each tool keeps its sessions.
#[derive(Clone, Debug)]
pub struct Roots {
    pub claude_dir: PathBuf,
    pub codex_home: PathBuf,
    /// Project folders to look in for `.graff/sessions`.
    pub projects: Vec<PathBuf>,
}

/// What an import did.
#[derive(Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportSummary {
    pub imported: usize,
    /// Already in Harness (imported before, or started by Harness).
    pub skipped: usize,
    pub errors: Vec<String>,
    /// Chat ids created by this call, in order.
    pub chat_ids: Vec<String>,
}

// ── neutral transcript ──────────────────────────────────────────────────────

pub(crate) enum Block {
    Text(String),
    Tool {
        call: ToolCall,
        output: Option<String>,
        is_error: bool,
    },
}

pub(crate) struct Msg {
    pub role: MessageRole,
    pub at_ms: i64,
    pub blocks: Vec<Block>,
}

// ── discovery ───────────────────────────────────────────────────────────────

/// Every session under `roots`, newest first. `cwd` keeps only sessions that
/// ran in that folder.
pub fn discover(roots: &Roots, cwd: Option<&str>) -> Vec<ExternalSession> {
    let mut found = Vec::new();
    found.extend(claude::discover(&roots.claude_dir, cwd));
    found.extend(codex::discover(&roots.codex_home, cwd));
    found.extend(graff::discover(&roots.projects, cwd));
    found.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    found
}

/// Read one session's conversation.
pub(crate) fn load(session: &ExternalSession) -> std::io::Result<Vec<Msg>> {
    let path = Path::new(&session.path);
    let msgs = match session.source {
        Source::Claude => claude::load(path)?,
        Source::Codex => codex::load(path)?,
        Source::Graff => graff::load(path, session.updated_at)?,
    };
    Ok(msgs)
}

// ── shared helpers for the three readers ────────────────────────────────────

/// Lines of a JSONL file as parsed objects; malformed lines are skipped (a
/// session still being written ends mid-line).
pub(crate) fn json_lines(path: &Path) -> std::io::Result<impl Iterator<Item = serde_json::Value>> {
    let file = fs::File::open(path)?;
    Ok(BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_str(&line).ok()))
}

/// Like [`json_lines`] but stops after the head of the file.
pub(crate) fn head_lines(path: &Path) -> std::io::Result<impl Iterator<Item = serde_json::Value>> {
    Ok(json_lines(path)?.take(HEAD_LINES))
}

pub(crate) fn file_times(path: &Path) -> (i64, i64, u64) {
    let meta = fs::metadata(path).ok();
    let ms = |t: Option<std::time::SystemTime>| {
        t.and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    };
    let modified = ms(meta.as_ref().and_then(|m| m.modified().ok()));
    let created = ms(meta.as_ref().and_then(|m| m.created().ok())).min(modified);
    (
        if created == 0 { modified } else { created },
        modified,
        meta.map(|m| m.len()).unwrap_or(0),
    )
}

pub(crate) fn parse_time_ms(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|t| t.timestamp_millis())
}

/// A prompt worth a title: a person's words, not the scaffolding tools wrap
/// around a turn (environment blocks, command echoes, reminders).
pub(crate) fn is_scaffolding(text: &str) -> bool {
    let t = text.trim_start();
    t.is_empty()
        || t.starts_with('<')
        || t.starts_with("Caveat:")
        || t.starts_with("# AGENTS.md")
        || t.starts_with("[Request interrupted")
}

pub(crate) fn one_line(text: &str, max: usize) -> String {
    let flat: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        flat
    } else {
        let cut: String = flat.chars().take(max.saturating_sub(1)).collect();
        format!("{}…", cut.trim_end())
    }
}

/// `Some(session)` when the file holds at least one prompt.
pub(crate) fn session_from_head(
    source: Source,
    id: String,
    path: &Path,
    cwd: Option<String>,
    first_prompt: Option<String>,
) -> Option<ExternalSession> {
    let title = one_line(&first_prompt?, TITLE_CHARS);
    if title.chars().count() < MIN_TITLE_CHARS {
        return None;
    }
    let (started_at, updated_at, size) = file_times(path);
    Some(ExternalSession {
        source,
        id,
        path: path.to_string_lossy().into_owned(),
        cwd,
        title,
        started_at,
        updated_at,
        size,
    })
}

// ── import ──────────────────────────────────────────────────────────────────

/// The service the engine carries: lists outside sessions and imports them.
#[derive(Clone)]
pub struct ExternalHistory {
    inner: Arc<Inner>,
}

struct Inner {
    roots: Roots,
    device_id: String,
    store: Arc<DocsStore>,
    workspace: WorkspaceHost,
}

impl ExternalHistory {
    pub fn new(
        roots: Roots,
        device_id: &str,
        store: Arc<DocsStore>,
        workspace: WorkspaceHost,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                roots,
                device_id: device_id.to_string(),
                store,
                workspace,
            }),
        }
    }

    /// Project folders Harness knows, plus `cwd`: where graff sessions can live.
    fn projects(&self, cwd: Option<&str>) -> Vec<PathBuf> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        let mut add = |p: &str| {
            if !p.is_empty() && seen.insert(p.to_string()) {
                out.push(PathBuf::from(p));
            }
        };
        if let Some(cwd) = cwd {
            add(cwd);
        }
        for p in &self.inner.roots.projects {
            add(&p.to_string_lossy());
        }
        for chat in self.inner.workspace.read_chats().unwrap_or_default() {
            if let Some(cwd) = &chat.cwd {
                add(cwd);
            }
        }
        out
    }

    /// Sessions that are not in Harness yet, newest first, at most `limit`.
    pub fn list(&self, cwd: Option<&str>, limit: usize) -> Vec<ExternalSession> {
        let mut roots = self.inner.roots.clone();
        roots.projects = self.projects(cwd);
        let known = self.known();
        discover(&roots, cwd)
            .into_iter()
            .filter(|s| !known.is_known(s))
            .take(limit)
            .collect()
    }

    /// Import the sessions named by `(source, id)` keys; `None` imports every
    /// session [`list`](Self::list) would show for `cwd`.
    pub fn import(&self, keys: Option<&[(Source, String)]>, cwd: Option<&str>) -> ImportSummary {
        let mut roots = self.inner.roots.clone();
        roots.projects = self.projects(cwd);
        let known = self.known();
        let mut summary = ImportSummary::default();
        let all = discover(&roots, cwd);
        let wanted: Vec<&ExternalSession> = match keys {
            None => all.iter().collect(),
            Some(keys) => all
                .iter()
                .filter(|s| keys.iter().any(|(src, id)| *src == s.source && *id == s.id))
                .collect(),
        };
        for session in wanted {
            if known.is_known(session) {
                summary.skipped += 1;
                continue;
            }
            match self.import_one(session) {
                Ok(chat_id) => {
                    summary.imported += 1;
                    summary.chat_ids.push(chat_id);
                }
                Err(err) => {
                    summary
                        .errors
                        .push(format!("{} {}: {err}", session.source.label(), session.id))
                }
            }
        }
        summary
    }

    fn known(&self) -> Known {
        let mut known = Known::default();
        for chat in self.inner.workspace.read_chats().unwrap_or_default() {
            known.chat_ids.insert(chat.id);
            if let Some(native) = chat.harness_session_id {
                known.native_ids.insert(native);
            }
        }
        known
    }

    fn import_one(&self, session: &ExternalSession) -> Result<String, EngineError> {
        let chat_id = session.source.chat_id(&session.id);
        let msgs = load(session).map_err(|e| EngineError::Other(e.to_string()))?;
        if msgs.is_empty() {
            return Err(EngineError::Other("no conversation in the file".into()));
        }
        let entries = entries_for(&msgs, &self.inner.device_id, &chat_id);
        let doc = SessionDoc::init(&chat_id).map_err(|e| EngineError::Other(e.to_string()))?;
        for entry in &entries {
            doc.push_message(entry)
                .map_err(|e| EngineError::Other(e.to_string()))?;
        }
        let bytes = doc
            .export_snapshot()
            .map_err(|e| EngineError::Other(e.to_string()))?;
        self.inner
            .store
            .save_snapshot_with_cursor(&chat_id, &bytes, 0, CHAT2_DOC_EPOCH)?;
        // Row last: once it shows in watchers the chat is clickable, and its
        // doc is already in place.
        self.inner.workspace.import_chat_row(&chat_row(
            session,
            &chat_id,
            &msgs,
            &self.inner.device_id,
        ))?;
        Ok(chat_id)
    }
}

#[derive(Default)]
struct Known {
    chat_ids: HashSet<String>,
    native_ids: HashSet<String>,
}

impl Known {
    fn is_known(&self, s: &ExternalSession) -> bool {
        self.chat_ids.contains(&s.source.chat_id(&s.id)) || self.native_ids.contains(&s.id)
    }
}

/// Chats imported from another agent that continue in graff
/// (`ext-claude-…` / `ext-codex-…`). Used to force graff resolution and to
/// keep the source agent's native session id out of `--resume`.
pub fn continues_in_graff(chat_id: &str) -> bool {
    native_id(chat_id).is_some()
}

/// The source agent's native session id embedded in an imported chat id
/// (`ext-<slug>-<native>`), for the sources that continue in graff.
pub fn native_id(chat_id: &str) -> Option<&str> {
    for slug in ["claude", "codex"] {
        let prefix = format!("ext-{slug}-");
        if let Some(id) = chat_id.strip_prefix(&prefix) {
            return (!id.is_empty()).then_some(id);
        }
    }
    None
}

/// A stored harness session id, unless it is the imported chat's own native
/// id — the source agent's handle is never a graff resume, so imported rows
/// from older builds (which recorded `claude --resume=<native>` data) drop it.
pub fn resume_id(chat_id: &str, session_id: String) -> Option<String> {
    match native_id(chat_id) {
        Some(native) if native == session_id => None,
        _ => Some(session_id),
    }
}

/// Display label for the imported chat's source, derived from its id prefix.
fn source_label(chat_id: &str) -> &'static str {
    if chat_id.starts_with("ext-claude-") {
        "Claude Code"
    } else {
        "Codex"
    }
}

/// Cap on the seeded earlier-conversation block; oldest lines drop first.
const SEED_CONVERSATION_CHARS: usize = 60_000;

/// The prompt sent to graff for the first turn of an imported chat: the user
/// message stays raw in the doc, but the agent gets the earlier conversation
/// as read-only context so it continues rather than restarts.
pub fn seed_prompt(chat_id: &str, entries: &[SessionMessageEntry], prompt: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    for entry in entries {
        let role = match entry.role {
            MessageRole::User => "User",
            MessageRole::Assistant => "Assistant",
            _ => continue,
        };
        for part in &entry.parts {
            match part {
                MessagePart::Text { text, .. } if !text.trim().is_empty() => {
                    lines.push(format!("{role}: {}", text.trim()));
                }
                MessagePart::Tool { call, output, .. } => {
                    let kind = serde_json::to_value(call)
                        .ok()
                        .and_then(|v| v.get("kind").and_then(|k| k.as_str().map(str::to_owned)))
                        .unwrap_or_else(|| "call".to_string());
                    let result = output
                        .as_deref()
                        .map(|o| one_line(o, 120))
                        .filter(|o| !o.is_empty())
                        .unwrap_or_else(|| "…".to_string());
                    lines.push(format!("Tool: {kind} — {result}"));
                }
                // Reasoning, images and system parts stay out of the seed.
                _ => {}
            }
        }
    }
    // Keep the NEWEST lines within the bound; count what fell off.
    let mut kept: Vec<String> = Vec::new();
    let mut size = 0usize;
    for line in lines.iter().rev() {
        if size + line.len() > SEED_CONVERSATION_CHARS {
            break;
        }
        size += line.len();
        kept.push(line.clone());
    }
    kept.reverse();
    let omitted = lines.len() - kept.len();
    let mut block = String::new();
    if omitted > 0 {
        block.push_str(&format!("[{omitted} earlier messages omitted]\n"));
    }
    block.push_str(&kept.join("\n"));
    format!(
        "This conversation started in {} and continues here in graff. The earlier conversation is below as read-only context; don't redo work it shows as finished.\n\n<earlier-conversation>\n{}\n</earlier-conversation>\n\n{}",
        source_label(chat_id),
        block,
        prompt
    )
}

fn chat_row(session: &ExternalSession, chat_id: &str, msgs: &[Msg], device_id: &str) -> Chat {
    let at = |ms: i64| {
        Utc.timestamp_millis_opt(ms)
            .single()
            .unwrap_or_else(Utc::now)
    };
    let last_reply = msgs
        .iter()
        .rev()
        .filter(|m| m.role == MessageRole::Assistant)
        .flat_map(|m| m.blocks.iter().rev())
        .find_map(|b| match b {
            Block::Text(t) if !t.trim().is_empty() => Some(one_line(t, PREVIEW_CHARS)),
            _ => None,
        });
    let last_at = msgs.last().map(|m| m.at_ms).unwrap_or(session.updated_at);
    Chat {
        id: chat_id.to_string(),
        device_id: device_id.to_string(),
        title: Some(session.title.clone()),
        archived: false,
        cwd: session.cwd.clone(),
        branch: None,
        checkout_id: None,
        source_context: None,
        // Imported conversations continue in graff, on graff's configured
        // provider: Claude/Codex sessions keep no native resume id (the
        // source agent is never re-launched); the first graff turn is seeded
        // with the earlier transcript. A graff import does resume its own
        // recorded session, scoped to the folder it ran in.
        config: Some(ChatConfig {
            harness: HarnessId::Graff,
            model: None,
            reasoning: None,
            model_options: Default::default(),
            sandbox: SandboxLevel::WorkspaceWrite,
        }),
        last_message_preview: last_reply,
        last_message_at: Some(at(last_at)),
        created_at: at(session.started_at),
        harness_session_id: (session.source == Source::Graff).then(|| session.id.clone()),
        harness_session_cwd: session.cwd.clone(),
        space_id: None,
        last_seen_at: Some(at(last_at)),
        room_gen: Some(CHAT2_DOC_EPOCH),
        parent_chat_id: None,
        last_prompt_at: None,
    }
}

fn entries_for(msgs: &[Msg], device_id: &str, chat_id: &str) -> Vec<SessionMessageEntry> {
    msgs.iter()
        .enumerate()
        .map(|(n, msg)| {
            let parts = msg
                .blocks
                .iter()
                .enumerate()
                .map(|(i, block)| {
                    let id = format!("{chat_id}-{n}-{i}");
                    match block {
                        Block::Text(text) => MessagePart::Text {
                            id,
                            text: text.clone(),
                        },
                        Block::Tool {
                            call,
                            output,
                            is_error,
                        } => MessagePart::Tool {
                            id,
                            call: call.clone(),
                            is_error: *is_error,
                            resolved: true,
                            output: output.clone(),
                            diff: None,
                            output_ref: None,
                            output_bytes: None,
                            diff_ref: None,
                            diff_stats: None,
                            subagent_ref: None,
                            subagent_status: None,
                            subagent_tail: None,
                            view: None,
                        },
                    }
                })
                .collect();
            SessionMessageEntry {
                id: format!("{chat_id}-{n}"),
                role: msg.role,
                parts,
                created_at: msg.at_ms,
                device_id: device_id.to_string(),
                status: (msg.role == MessageRole::Assistant).then_some(MessageStatus::Complete),
                continuation_of: None,
                duration_ms: None,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace_host::WorkspaceHostConfig;
    use std::io::Write;

    const CLAUDE_SESSION: &[&str] = &[
        r#"{"type":"user","cwd":"/w/app","sessionId":"s1","timestamp":"2026-09-01T10:00:01Z","message":{"role":"user","content":"fix the login bug"}}"#,
        r#"{"type":"assistant","timestamp":"2026-09-01T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Fixed it."}]}}"#,
    ];

    struct Fixture {
        _dir: tempfile::TempDir,
        history: ExternalHistory,
        store: Arc<DocsStore>,
        workspace: WorkspaceHost,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join("claude");
        let proj = claude.join("projects").join(claude::encode_cwd("/w/app"));
        std::fs::create_dir_all(&proj).unwrap();
        let mut f = std::fs::File::create(proj.join("s1.jsonl")).unwrap();
        for l in CLAUDE_SESSION {
            writeln!(f, "{l}").unwrap();
        }
        let store = Arc::new(DocsStore::open(dir.path().join("docs")).unwrap());
        let workspace = WorkspaceHost::open(
            store.clone(),
            WorkspaceHostConfig {
                device_id: "dev".into(),
                device_name: "Dev".into(),
                platform: "macos".into(),
                org_id: "org".into(),
                user_id: "user".into(),
                edge: None,
            },
        )
        .unwrap();
        let history = ExternalHistory::new(
            Roots {
                claude_dir: claude,
                codex_home: dir.path().join("codex"),
                projects: Vec::new(),
            },
            "dev",
            store.clone(),
            workspace.clone(),
        );
        Fixture {
            _dir: dir,
            history,
            store,
            workspace,
        }
    }

    #[tokio::test]
    async fn an_imported_session_is_a_chat_with_its_conversation_and_imports_once() {
        let fx = fixture();
        let listed = fx.history.list(None, 10);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].title, "fix the login bug");

        let summary = fx.history.import(None, None);
        assert_eq!(summary.imported, 1, "{summary:?}");
        assert_eq!(summary.chat_ids, vec!["ext-claude-s1".to_string()]);

        let chat = fx.workspace.chat("ext-claude-s1").unwrap().expect("row");
        assert_eq!(chat.title.as_deref(), Some("fix the login bug"));
        assert_eq!(chat.cwd.as_deref(), Some("/w/app"));
        assert_eq!(chat.last_message_preview.as_deref(), Some("Fixed it."));
        // Imported chats continue in graff: no native resume id is kept, so
        // `claude --resume` can never launch (#168).
        assert_eq!(chat.harness_session_id, None);
        assert_eq!(
            chat.config.as_ref().map(|c| c.harness),
            Some(HarnessId::Graff)
        );
        assert_eq!(chat.harness_session_cwd.as_deref(), Some("/w/app"));

        let bytes = fx
            .store
            .load_snapshot("ext-claude-s1")
            .unwrap()
            .expect("doc");
        let doc = loro::LoroDoc::new();
        doc.import(&bytes).unwrap();
        let entries = SessionDoc::from_doc(doc).read_entries().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].role, MessageRole::User);
        assert!(
            matches!(&entries[1].parts[0], MessagePart::Text { text, .. } if text == "Fixed it.")
        );

        // Imported sessions are not offered again, and a second import skips it.
        assert!(fx.history.list(None, 10).is_empty());
        let again = fx.history.import(None, None);
        assert_eq!((again.imported, again.skipped), (0, 1), "{again:?}");
    }

    #[tokio::test]
    async fn a_session_harness_started_is_not_offered() {
        let fx = fixture();
        // A Harness chat whose native session is the same id.
        fx.workspace
            .create_chat("c-native", None, Some("dev"), None, Some("/w/app".into()))
            .unwrap();
        let mut row = fx.workspace.chat("c-native").unwrap().unwrap();
        row.harness_session_id = Some("s1".into());
        fx.workspace.import_chat_row(&row).unwrap();
        assert!(fx.history.list(None, 10).is_empty());
        let summary = fx.history.import(None, None);
        assert_eq!(summary.imported, 0);
    }

    #[tokio::test]
    async fn importing_by_key_takes_only_what_was_asked_for() {
        let fx = fixture();
        let none = fx
            .history
            .import(Some(&[(Source::Codex, "nope".into())]), None);
        assert_eq!(none.imported, 0);
        let one = fx
            .history
            .import(Some(&[(Source::Claude, "s1".into())]), None);
        assert_eq!(one.imported, 1);
    }
    #[test]
    fn continues_in_graff_covers_claude_and_codex_imports() {
        assert!(continues_in_graff("ext-claude-s1"));
        assert!(continues_in_graff("ext-codex-9f2a"));
        assert!(!continues_in_graff("ext-graff-s1"), "graff resumes itself");
        assert!(!continues_in_graff("c-native"));
        assert!(!continues_in_graff("ext-claude-"), "no native id");
        assert_eq!(native_id("ext-codex-9f2a"), Some("9f2a"));
    }

    #[test]
    fn resume_id_drops_only_the_stored_native_id() {
        // Rows imported by older builds still carry the source agent's id.
        assert_eq!(resume_id("ext-claude-s1", "s1".to_string()), None);
        assert_eq!(resume_id("ext-codex-x", "x".to_string()), None);
        // A graff-recorded session id resumes normally.
        assert_eq!(
            resume_id("ext-claude-s1", "graff-7".to_string()),
            Some("graff-7".to_string())
        );
        assert_eq!(
            resume_id("c-native", "anything".to_string()),
            Some("anything".to_string())
        );
    }

    fn seed_entry(role: MessageRole, parts: Vec<MessagePart>) -> SessionMessageEntry {
        SessionMessageEntry {
            id: "e".into(),
            role,
            parts,
            created_at: 0,
            device_id: "dev".into(),
            status: None,
            continuation_of: None,
            duration_ms: None,
        }
    }

    #[test]
    fn seed_prompt_wraps_the_earlier_conversation() {
        let entries = vec![
            seed_entry(
                MessageRole::User,
                vec![MessagePart::Text {
                    id: "p1".into(),
                    text: "fix the login bug".into(),
                }],
            ),
            seed_entry(
                MessageRole::Assistant,
                vec![
                    MessagePart::Reasoning {
                        id: "r".into(),
                        text: "hidden thinking".into(),
                    },
                    MessagePart::Text {
                        id: "p2".into(),
                        text: "Fixed it.".into(),
                    },
                    MessagePart::Tool {
                        id: "t".into(),
                        call: ToolCall::Exec {
                            command: "cargo test".into(),
                        },
                        is_error: false,
                        resolved: true,
                        output: Some("ok\nok\nok".into()),
                        diff: None,
                        output_ref: None,
                        output_bytes: None,
                        diff_ref: None,
                        diff_stats: None,
                        subagent_ref: None,
                        subagent_status: None,
                        subagent_tail: None,
                        view: None,
                    },
                ],
            ),
        ];
        let out = seed_prompt("ext-claude-s1", &entries, "continue please");
        assert!(
            out.starts_with(
                "This conversation started in Claude Code and continues here in graff."
            )
        );
        let block = out
            .split("<earlier-conversation>")
            .nth(1)
            .unwrap()
            .split("</earlier-conversation>")
            .next()
            .unwrap();
        assert!(block.contains("User: fix the login bug"));
        assert!(block.contains("Assistant: Fixed it."));
        assert!(block.contains("Tool: exec — ok ok ok"));
        assert!(!block.contains("hidden thinking"), "reasoning is dropped");
        assert!(out.ends_with("</earlier-conversation>\n\ncontinue please"));
        assert!(
            seed_prompt("ext-codex-1", &entries, "p")
                .starts_with("This conversation started in Codex and continues here in graff.")
        );
    }

    #[test]
    fn seed_prompt_truncates_oldest_first_with_an_omitted_line() {
        let mut entries: Vec<SessionMessageEntry> = Vec::new();
        for i in 0..300 {
            entries.push(seed_entry(
                MessageRole::User,
                vec![MessagePart::Text {
                    id: format!("p{i}"),
                    text: format!("message {i} {}", "x".repeat(400)),
                }],
            ));
        }
        let out = seed_prompt("ext-codex-9", &entries, "next");
        let block = out
            .split("<earlier-conversation>")
            .nth(1)
            .unwrap()
            .split("</earlier-conversation>")
            .next()
            .unwrap();
        assert!(block.len() <= 61_000);
        let omitted: usize = block
            .trim_start()
            .strip_prefix('[')
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap()
            .parse()
            .unwrap();
        assert!(omitted > 0);
        assert!(block.contains("message 299"), "newest lines are kept");
        assert!(!block.contains("message 0 "), "oldest lines dropped");
    }
}
