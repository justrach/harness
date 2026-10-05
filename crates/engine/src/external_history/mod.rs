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

    fn harness_id(self) -> HarnessId {
        match self {
            Self::Claude => HarnessId::ClaudeCode,
            Self::Codex => HarnessId::Codex,
            Self::Graff => HarnessId::Graff,
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
        // The agent that wrote the session continues it: its native id is the
        // resume handle, scoped to the folder it ran in.
        config: Some(ChatConfig {
            harness: session.source.harness_id(),
            model: None,
            reasoning: None,
            model_options: Default::default(),
            sandbox: SandboxLevel::WorkspaceWrite,
        }),
        last_message_preview: last_reply,
        last_message_at: Some(at(last_at)),
        created_at: at(session.started_at),
        harness_session_id: Some(session.id.clone()),
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
                cloud_sandbox_id: None,
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
        assert_eq!(chat.harness_session_id.as_deref(), Some("s1"));
        assert_eq!(
            chat.config.as_ref().map(|c| c.harness),
            Some(HarnessId::ClaudeCode)
        );

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
}
