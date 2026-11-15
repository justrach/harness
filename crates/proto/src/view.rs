//! Frontend-agnostic view logic: the derivations every viewport needs and none
//! of them should own — sort orders, staleness gating, sidebar grouping, the
//! boot gate, relative times.
//!
//! This lives in `proto` rather than in the viewport crate so the rules stay
//! pure and independently testable: the same workspace doc must produce the
//! same row order on every surface, and there is exactly one implementation
//! and one test suite per rule.
//!
//! Everything in this module is pure. `chat_indicator` (the status derivation
//! these gate on) is in [`crate::entities`].

use chrono::{DateTime, Utc};

use crate::{AuthState, Chat, ChatIndicator, Session, SessionStatus, Space, WorkspaceScope};

// ---------------------------------------------------------------------------
// Connection + status
// ---------------------------------------------------------------------------

/// Viewport ⇄ engine connection lifecycle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionStatus {
    Connecting,
    Ready,
    Failed(String),
}

/// What a chat's status dot / working indicator should show right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Indicator {
    None,
    Working,
    AwaitingInput,
    Errored,
}

/// A `Working`/`AwaitingInput` session older than this is treated as dead — a
/// crashed backend must never show an eternal "Working" (feature-inventory
/// §1.12). Engines heartbeat sessions well inside this window.
pub const SESSION_STALE_MS: i64 = 45_000;

/// Staleness-checked indicator for a session row. Pure.
pub fn effective_indicator(session: Option<&Session>, now: DateTime<Utc>) -> Indicator {
    let Some(session) = session else {
        return Indicator::None;
    };
    match session.status {
        SessionStatus::Idle => Indicator::None,
        SessionStatus::Errored => Indicator::Errored,
        SessionStatus::Working | SessionStatus::AwaitingInput => {
            let age_ms = now
                .signed_duration_since(session.updated_at)
                .num_milliseconds();
            if age_ms > SESSION_STALE_MS {
                Indicator::None
            } else if session.status == SessionStatus::Working {
                Indicator::Working
            } else {
                Indicator::AwaitingInput
            }
        }
    }
}

/// The full display status for a chat row / tab dot: live states win, then the
/// synced seen marker decides completed-vs-idle. Staleness gating rides on
/// [`effective_indicator`]; the derivation itself is [`crate::chat_indicator`].
pub fn display_status(chat: &Chat, session: Option<&Session>, now: DateTime<Utc>) -> ChatIndicator {
    let live = session.filter(|s| effective_indicator(Some(s), now) != Indicator::None);
    crate::chat_indicator(chat, live)
}

/// Attention bucket for the sidebar's Active list — lower is more urgent.
pub fn attention_rank(status: ChatIndicator) -> u8 {
    match status {
        ChatIndicator::AwaitingInput => 0,
        ChatIndicator::Errored => 1,
        ChatIndicator::Working => 2,
        ChatIndicator::Completed => 3,
        ChatIndicator::Idle => 4,
    }
}

// ---------------------------------------------------------------------------
// Sort orders
// ---------------------------------------------------------------------------

/// Active-list order: when each chat was last CALLED (`last_prompt_at` desc,
/// then `last_message_at` for hosts without the stamp, then `created_at`),
/// id tiebreak so the sort is total. Agent replies don't move a row. Deliberately NOT
/// attention-bucketed: status drives the DOT, never the position — bucketing
/// meant that merely OPENING a completed session (completed → seen → idle)
/// dropped its row under the pointer (user report: "their position in the
/// scrollbar changes"). Matches the old sidebar, which rendered chats in
/// recency order and let the dots carry urgency; [`attention_rank`] still
/// aggregates the space rows' urgency dot.
pub fn sort_active(rows: &mut Vec<(ChatIndicator, &Chat)>) {
    // When a person last called the chat (its last prompt); agent replies
    // don't move a row. Hosts that predate the stamp: the last message.
    rows.sort_by(|(_, a), (_, b)| {
        let ka = a.last_prompt_at.or(a.last_message_at).unwrap_or(a.created_at);
        let kb = b.last_prompt_at.or(b.last_message_at).unwrap_or(b.created_at);
        kb.cmp(&ka).then_with(|| a.id.cmp(&b.id))
    });
}

/// Session-tab order for a space: creation order (activity never reorders
/// tabs), id tiebreak. Pure.
pub fn sort_tabs(chats: &mut [&Chat]) {
    chats.sort_by(|a, b| {
        a.created_at
            .cmp(&b.created_at)
            .then_with(|| a.id.cmp(&b.id))
    });
}

/// Spaces list order: creation order, id tiebreak — total and stable across
/// devices. Pure.
pub fn sort_spaces(spaces: &mut [Space]) {
    spaces.sort_by(|a, b| {
        a.created_at
            .cmp(&b.created_at)
            .then_with(|| a.id.cmp(&b.id))
    });
}

/// Sidebar order: `last_message_at` desc, falling back to `created_at`; ties
/// break by `created_at` desc then id so the sort is total and stable across
/// devices. Pure.
pub fn sort_chats(chats: &mut [Chat]) {
    chats.sort_by(|a, b| {
        let ka = a.last_message_at.unwrap_or(a.created_at);
        let kb = b.last_message_at.unwrap_or(b.created_at);
        kb.cmp(&ka)
            .then_with(|| b.created_at.cmp(&a.created_at))
            .then_with(|| a.id.cmp(&b.id))
    });
}

// ---------------------------------------------------------------------------
// Boot gate
// ---------------------------------------------------------------------------

/// The app gate (harness's App.tsx phases). Pure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GatePhase {
    /// Booting / probing — splash covers this.
    Loading,
    /// Engine unreachable and embedding failed.
    Failed(String),
    /// Engine up, but signed out — show the sign-in card.
    SignIn,
    /// Signed in but no organization selected — "Create your workspace".
    OrgGate,
    /// Render the shell.
    Ready,
}

/// Missing scope is treated as synced. Current engines always publish
/// [`WorkspaceScope`] before becoming ready, while old daemons are deliberately
/// kept behind the account gate instead of being mistaken for local runtimes.
pub fn gate_phase(
    connection: &ConnectionStatus,
    workspace_scope: Option<WorkspaceScope>,
    auth: Option<&AuthState>,
) -> GatePhase {
    match connection {
        ConnectionStatus::Connecting => GatePhase::Loading,
        ConnectionStatus::Failed(err) => GatePhase::Failed(err.clone()),
        ConnectionStatus::Ready => match workspace_scope.unwrap_or(WorkspaceScope::Synced) {
            WorkspaceScope::Local | WorkspaceScope::Development => GatePhase::Ready,
            WorkspaceScope::Synced => match auth {
                Some(AuthState::NeedsOrganization { .. }) => GatePhase::OrgGate,
                Some(AuthState::SignedIn { .. }) => GatePhase::Ready,
                Some(AuthState::SignedOut) | None => GatePhase::SignIn,
            },
        },
    }
}

#[cfg(test)]
mod gate_tests {
    use super::*;
    use crate::UserProfile;

    fn user() -> UserProfile {
        UserProfile {
            id: "user-1".into(),
            email: "user@example.com".into(),
            name: None,
            avatar_url: None,
            member_number: None,
            started_at: None,
            card_scenes: None,
            card_traits: None,
        }
    }

    #[test]
    fn workspace_scope_controls_the_auth_gate() {
        assert_eq!(
            gate_phase(
                &ConnectionStatus::Ready,
                Some(WorkspaceScope::Local),
                Some(&AuthState::SignedOut),
            ),
            GatePhase::Ready
        );
        assert_eq!(
            gate_phase(
                &ConnectionStatus::Ready,
                Some(WorkspaceScope::Synced),
                Some(&AuthState::SignedOut),
            ),
            GatePhase::SignIn
        );
        assert_eq!(
            gate_phase(
                &ConnectionStatus::Ready,
                Some(WorkspaceScope::Synced),
                Some(&AuthState::NeedsOrganization { user: user() }),
            ),
            GatePhase::OrgGate
        );
    }

    #[test]
    fn development_and_local_never_use_the_workos_gate() {
        for scope in [WorkspaceScope::Local, WorkspaceScope::Development] {
            for auth in [
                AuthState::SignedOut,
                AuthState::NeedsOrganization { user: user() },
                AuthState::SignedIn {
                    user: user(),
                    org_id: Some("org-1".into()),
                },
            ] {
                assert_eq!(
                    gate_phase(&ConnectionStatus::Ready, Some(scope), Some(&auth)),
                    GatePhase::Ready
                );
            }
        }
    }

    #[test]
    fn missing_scope_falls_back_to_a_synced_gate() {
        assert_eq!(
            gate_phase(&ConnectionStatus::Ready, None, None),
            GatePhase::SignIn
        );
    }
}

/// Parse an `AuthStatus` frame tolerantly. The engine currently serializes its
/// own enum (`{"_tag": "SignedIn", ...}`) while the proto type expects
/// `{"state": "signedIn", ...}` — accept both so either side can converge
/// without breaking a viewport.
pub fn parse_auth_state(value: &serde_json::Value) -> Option<AuthState> {
    if let Ok(state) = serde_json::from_value::<AuthState>(value.clone()) {
        return Some(state);
    }
    let tag = value.get("_tag").and_then(|t| t.as_str())?;
    let user = || -> Option<crate::UserProfile> {
        let u = value.get("user")?;
        Some(crate::UserProfile {
            id: u.get("id")?.as_str()?.to_string(),
            email: u.get("email")?.as_str()?.to_string(),
            name: u.get("name").and_then(|n| n.as_str()).map(str::to_string),
            avatar_url: u
                .get("avatarUrl")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            member_number: u.get("memberNumber").and_then(|v| v.as_u64()),
            started_at: u.get("startedAt").and_then(|v| v.as_i64()),
            card_scenes: u
                .get("cardScenes")
                .and_then(|v| v.as_u64())
                .and_then(|n| u32::try_from(n).ok()),
            card_traits: u
                .get("cardTraits")
                .and_then(|v| serde_json::from_value(v.clone()).ok()),
        })
    };
    match tag {
        "SignedOut" => Some(AuthState::SignedOut),
        "NeedsOrganization" => Some(AuthState::NeedsOrganization { user: user()? }),
        "SignedIn" => Some(AuthState::SignedIn {
            user: user()?,
            org_id: value
                .get("orgId")
                .and_then(|v| v.as_str())
                .map(str::to_string),
        }),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Sidebar grouping
// ---------------------------------------------------------------------------

/// One grouped-by-project sidebar section.
#[derive(Debug, Clone, PartialEq)]
pub struct ChatGroup<'a> {
    pub label: String,
    pub chats: Vec<&'a Chat>,
}

/// Project label for a chat: the basename of its cwd, or "No project".
pub fn project_label(cwd: Option<&str>) -> String {
    let Some(cwd) = cwd.map(str::trim).filter(|c| !c.is_empty()) else {
        return "No project".to_string();
    };
    if matches!(cwd, "~" | "~/") {
        return "No project".to_string();
    }
    std::path::Path::new(cwd.trim_end_matches(['/', '\\']))
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| cwd.to_string())
}

/// Group chats by project label, preserving the incoming (recency) order both
/// for groups (by their most recent chat) and rows within a group. Pure.
pub fn group_chats<'a>(chats: impl IntoIterator<Item = &'a Chat>) -> Vec<ChatGroup<'a>> {
    let mut groups: Vec<ChatGroup<'a>> = Vec::new();
    for chat in chats {
        let label = project_label(chat.cwd.as_deref());
        match groups.iter_mut().find(|g| g.label == label) {
            Some(group) => group.chats.push(chat),
            None => groups.push(ChatGroup {
                label,
                chats: vec![chat],
            }),
        }
    }
    groups
}

/// Compact relative time ("now", "5m", "3h", "2d", "1w", …) — no "ago" suffix;
/// port of harness's `formatTimeAgo`.
pub fn format_time_ago(then: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let s = now.signed_duration_since(then).num_seconds().max(0);
    // Under a minute reads as "now" — otherwise 45–59s floors to a bare "0m".
    if s < 60 {
        return "now".to_string();
    }
    let m = s / 60;
    if m < 60 {
        return format!("{m}m");
    }
    let h = m / 60;
    if h < 24 {
        return format!("{h}h");
    }
    let d = h / 24;
    if d < 7 {
        return format!("{d}d");
    }
    let w = d / 7;
    if w < 5 {
        return format!("{w}w");
    }
    let mo = d / 30;
    if mo < 12 {
        return format!("{mo}mo");
    }
    format!("{}y", d / 365)
}

/// Session-row sub-line, "project · branch" (harness `chatLocation`): the repo
/// checkout identity. Either part may be missing; empty when both are.
pub fn chat_location(chat: &Chat) -> Option<String> {
    let project = chat
        .cwd
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(|c| project_label(Some(c)));
    let reference = chat
        .branch
        .as_deref()
        .map(str::trim)
        .filter(|b| !b.is_empty());
    match (project, reference) {
        (Some(p), Some(r)) => Some(format!("{p} · {r}")),
        (Some(p), None) => Some(p),
        (None, Some(r)) => Some(r.to_string()),
        (None, None) => None,
    }
}

// ---------------------------------------------------------------------------
// Tool summaries (pure)
// ---------------------------------------------------------------------------

/// Collapse model-generated text onto ONE line for single-line surfaces (tool
/// chips, titles, previews): newlines, tabs and runs of whitespace become
/// single spaces, trimmed.
///
/// Both viewports need this for the same reason from opposite directions — gpui
/// breaks on a literal `\n` before its ellipsis logic, and a terminal cell grid
/// would take an embedded newline as a cursor move.
pub fn single_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn plural(n: usize, one: &str, many: &str) -> String {
    if n == 1 {
        format!("{n} {one}")
    } else {
        format!("{n} {many}")
    }
}

/// Per-kind chip label + one-line detail. Labels match harness's `describeTool`
/// (tool-chip.tsx) exactly, so the two viewports name a tool identically.
pub fn tool_chip_content(call: &crate::ToolCall) -> (&'static str, String) {
    let (label, detail) = tool_chip_content_raw(call);
    (label, single_line(&detail))
}

fn tool_chip_content_raw(call: &crate::ToolCall) -> (&'static str, String) {
    use crate::ToolCall;
    match call {
        ToolCall::Exec { command } => ("Run", command.clone()),
        ToolCall::ReadFile { path } => ("Read", path.clone()),
        ToolCall::WriteFile { path, .. } => ("Write", path.clone()),
        ToolCall::EditFile { path, .. } => ("Edit", path.clone()),
        ToolCall::ApplyPatch { path } => {
            ("Patch", path.clone().unwrap_or_else(|| "workspace".into()))
        }
        ToolCall::Search { pattern, path } => (
            "Search",
            match path {
                Some(path) => format!("{pattern} in {path}"),
                None => pattern.clone(),
            },
        ),
        ToolCall::Glob { pattern } => ("Glob", pattern.clone()),
        ToolCall::WebFetch { url, .. } => ("Fetch", url.clone()),
        ToolCall::WebSearch { query } => ("Web", query.clone()),
        ToolCall::Todo { items } => {
            let done = items.iter().filter(|i| i.done).count();
            ("Todo", format!("{done}/{} done", items.len()))
        }
        ToolCall::Mcp { server, tool, .. } => ("MCP", format!("{server} · {tool}")),
        // Subagent spawns decode as Unknown named "Agent[: <description>]"
        // (every native driver's convention): label them "Agent" with the
        // description as the detail — "Tool · Agent: scan repo" read as two
        // labels fighting.
        ToolCall::Unknown { name, .. } => match name.strip_prefix("Agent: ") {
            Some(description) => ("Agent", description.to_owned()),
            None if name.starts_with("Jev: ") => ("Jev", name[5..].to_owned()),
            None if name == "Agent" => ("Agent", String::new()),
            None if name == crate::COMPACTION_TOOL_NAME => ("Compact", "context".into()),
            None => agent_control(name).unwrap_or_else(|| ("Tool", name.clone())),
        },
    }
}

// ---------------------------------------------------------------------------
// Collapsed command previews: long filepaths (pure)
// ---------------------------------------------------------------------------

/// A path in a collapsed command preview is shortened only past this many
/// characters: `/bin/zsh` or `"\tools\pwsh.exe"` already read fine.
pub const PREVIEW_PATH_MAX_CHARS: usize = 32;

/// Directories a collapsed preview may shorten a path against: the chat's
/// folder (paths inside it read relative) and the home directory (`~`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PreviewPathAnchors<'a> {
    pub workspace: Option<&'a str>,
    pub home: Option<&'a str>,
}

/// The collapsed `Run` preview of `command`. Every recognised filepath longer
/// than [`PREVIEW_PATH_MAX_CHARS`] is shortened: relative when it is inside
/// the workspace, `~` when it is under home, then `…/parent/file` (or
/// `…/file`) while it is still long. Everything else is kept byte for byte:
/// the executable's name, the subcommand, flags, quotes, operators and order.
///
/// Display only: execution, the expanded invocation and copied text keep the
/// original command.
///
/// A token counts as a path only when it is certainly one: an absolute path
/// (`/…`, `~/…`, `C:\…`, `C:/…`, `\\server\…`, `\\?\…`, `\dir\…`) forming a
/// whole word, a whole quoted word or a `--flag=` value, with no glob,
/// variable, operator or URL characters. Quoted `-c` scripts aren't parsed.
pub fn compact_command_paths(command: &str, anchors: PreviewPathAnchors<'_>) -> String {
    let mut out = String::with_capacity(command.len());
    let mut last = 0;
    for range in path_candidates(command) {
        if let Some(short) = compact_path(&command[range.clone()], anchors) {
            out.push_str(&command[last..range.start]);
            out.push_str(&short);
            last = range.end;
        }
    }
    out.push_str(&command[last..]);
    out
}

/// Whether `command` holds a path [`compact_command_paths`] may shorten under
/// some anchors. Such a command keeps its expanded invocation even when it
/// fits the header, so the full path stays one click away.
pub fn command_has_long_path(command: &str) -> bool {
    path_candidates(command)
        .into_iter()
        .any(|range| command[range].chars().count() > PREVIEW_PATH_MAX_CHARS)
}

/// Byte ranges of the recognised paths among `command`'s words: a bare word,
/// the inside of a wholly quoted word, or the value of `-flag=value`.
fn path_candidates(command: &str) -> Vec<std::ops::Range<usize>> {
    command_words(command)
        .into_iter()
        .filter_map(|word| {
            let text = &command[word.clone()];
            let value = if text.starts_with('-') {
                word.start + text.find('=')? + 1..word.end
            } else {
                word
            };
            unquoted(command, value)
        })
        .filter(|range| path_separator(&command[range.clone()]).is_some())
        .collect()
}

/// Split `command` into shell-like words: whitespace outside quotes ends a
/// word; `\ ` outside quotes and `\"` inside double quotes are escapes.
fn command_words(command: &str) -> Vec<std::ops::Range<usize>> {
    let bytes = command.as_bytes();
    let mut words = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        let mut quote: Option<u8> = None;
        while i < bytes.len() {
            let b = bytes[i];
            match quote {
                Some(q) if b == q => quote = None,
                Some(b'"') if b == b'\\' && bytes.get(i + 1) == Some(&b'"') => i += 1,
                Some(_) => {}
                None if b.is_ascii_whitespace() => break,
                None if b == b'"' || b == b'\'' => quote = Some(b),
                None if b == b'\\' && bytes.get(i + 1) == Some(&b' ') => i += 1,
                None => {}
            }
            i += 1;
        }
        words.push(start..i.min(bytes.len()));
    }
    words
}

/// The path text of a word: inside its quotes when it is wholly quoted, the
/// word itself when it has no quotes, and nothing for mixed quoting.
fn unquoted(command: &str, range: std::ops::Range<usize>) -> Option<std::ops::Range<usize>> {
    let text = &command[range.clone()];
    match text.chars().next() {
        Some(q @ ('"' | '\'')) => {
            let inner = text.strip_prefix(q)?.strip_suffix(q)?;
            (!inner.contains(q)).then(|| range.start + 1..range.end - 1)
        }
        _ => (!text.contains(['"', '\''])).then_some(range),
    }
}

/// The separator of a confidently recognised absolute filepath, or `None`
/// for anything else (relative words, URLs, globs, regexes, scripts).
fn path_separator(path: &str) -> Option<char> {
    let b = path.as_bytes();
    let (sep, body) = if path.starts_with('/') || path.starts_with("~/") {
        ('/', path)
    } else if let Some(rest) = path.strip_prefix(r"\\?\") {
        ('\\', rest)
    } else if path.starts_with(r"\\") {
        ('\\', path)
    } else if b.len() >= 3
        && b[0].is_ascii_alphabetic()
        && b[1] == b':'
        && matches!(b[2], b'\\' | b'/')
    {
        (b[2] as char, path)
    } else if b.first() == Some(&b'\\')
        && b.get(1)
            .is_some_and(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_'))
    {
        ('\\', path)
    } else {
        return None;
    };
    let suspicious = body.contains("://")
        || body.contains(" -")
        || body.contains([
            '*', '?', '$', '`', '{', '}', '[', ']', '|', '<', '>', ';', '&', '^', '"', '\'', '\n',
            '\t', '\r',
        ]);
    // In a slash path a backslash is only ever an escaped space; anything
    // else (`/\d+/`) is a pattern, not a path.
    let stray_escape = sep == '/'
        && body
            .match_indices('\\')
            .any(|(i, _)| !body[i + 1..].starts_with(' '));
    (!suspicious && !stray_escape).then_some(sep)
}

/// `path` without `dir` and its separator when `path` lies strictly inside
/// `dir`. Windows paths compare case-insensitively with either separator.
fn strip_dir<'p>(path: &'p str, dir: &str, sep: char, windows: bool) -> Option<&'p str> {
    let dir = dir.trim_end_matches(['/', '\\']);
    if dir.is_empty() || path.len() <= dir.len() + 1 {
        return None;
    }
    let is_sep = |c: u8| c == b'/' || c == b'\\';
    let same = path.as_bytes()[..dir.len()]
        .iter()
        .zip(dir.as_bytes())
        .all(|(a, b)| {
            a == b || (windows && (a.eq_ignore_ascii_case(b) || (is_sep(*a) && is_sep(*b))))
        });
    let next = path.as_bytes()[dir.len()];
    (same && (next == sep as u8 || (windows && is_sep(next)))).then(|| &path[dir.len() + 1..])
}

/// One recognised path, shortened; `None` when it is short, unrecognised, or
/// nothing shorter exists.
fn compact_path(path: &str, anchors: PreviewPathAnchors<'_>) -> Option<String> {
    let sep = path_separator(path)?;
    if path.chars().count() <= PREVIEW_PATH_MAX_CHARS {
        return None;
    }
    let (body, trailing) = match path.strip_suffix(sep) {
        Some(body) if !body.is_empty() => (body, true),
        _ => (path, false),
    };
    let windows = sep == '\\' || body.as_bytes().get(1) == Some(&b':');
    let home = format!("~{sep}");
    let (lead, rest) = if let Some(rest) = anchors
        .workspace
        .and_then(|dir| strip_dir(body, dir, sep, windows))
    {
        ("", rest)
    } else if let Some(rest) = body.strip_prefix("~/") {
        (home.as_str(), rest)
    } else if let Some(rest) = anchors
        .home
        .and_then(|dir| strip_dir(body, dir, sep, windows))
    {
        (home.as_str(), rest)
    } else {
        ("", body)
    };
    let mut short = format!("{lead}{rest}");
    if short.chars().count() > PREVIEW_PATH_MAX_CHARS {
        let segments: Vec<&str> = rest.split(sep).filter(|s| !s.is_empty()).collect();
        for keep in [2, 1] {
            if segments.len() <= keep {
                continue;
            }
            let tail = segments[segments.len() - keep..].join(&sep.to_string());
            let elided = format!("{lead}…{sep}{tail}");
            if elided.chars().count() <= PREVIEW_PATH_MAX_CHARS || keep == 1 {
                if elided.chars().count() < short.chars().count() {
                    short = elided;
                }
                break;
            }
        }
    }
    if trailing {
        short.push(sep);
    }
    (short != path).then_some(short)
}

/// A parent's control of its subagents, as drivers name them (codex collab
/// tools, graff background agents): waits always read "Waiting on subagent".
/// Worker IDs and task titles remain in the call for routing and linked tabs,
/// rather than exposing implementation details in the wait chip.
fn agent_control(name: &str) -> Option<(&'static str, String)> {
    if name.starts_with("Wait for ") {
        return Some(("Waiting on", "subagent".into()));
    }
    for (prefix, label) in [
        ("Message agent", "Message"),
        ("Resume agent", "Resume"),
        ("Close agent", "Close"),
    ] {
        if name == prefix || name.strip_prefix(prefix).is_some_and(|rest| rest.starts_with(' ')) {
            return Some((label, "subagent".into()));
        }
    }
    match name {
        "agent_output" => Some(("Waiting on", "subagent".into())),
        "Send agent message" | "agent_message" => Some(("Message", "subagent".into())),
        "subagent_resume" => Some(("Resume", "subagent".into())),
        "Load tools" => Some(("Load", "tools".into())),
        _ => None,
    }
}

/// The ToolGroup summary line — "Ran 3 commands · edited 2 files".
///
/// Takes `(call, is_error)` pairs so each viewport can keep its own row model;
/// the summary itself is one implementation for both.
pub fn tool_group_summary(tools: &[(crate::ToolCall, bool)]) -> String {
    use crate::ToolCall;
    let mut commands = 0usize;
    let mut edited: Vec<&str> = Vec::new();
    let mut reads = 0usize;
    let mut searches = 0usize;
    let mut fetches = 0usize;
    let mut todos = 0usize;
    let mut other = 0usize;
    let mut failed = 0usize;
    for (call, is_error) in tools {
        if *is_error {
            failed += 1;
        }
        match call {
            ToolCall::Exec { .. } => commands += 1,
            ToolCall::WriteFile { path, .. } | ToolCall::EditFile { path, .. } => {
                if !edited.contains(&path.as_str()) {
                    edited.push(path);
                }
            }
            ToolCall::ApplyPatch { path } => {
                let p = path.as_deref().unwrap_or("patch");
                if !edited.contains(&p) {
                    edited.push(p);
                }
            }
            ToolCall::ReadFile { .. } => reads += 1,
            ToolCall::Search { .. } | ToolCall::Glob { .. } | ToolCall::WebSearch { .. } => {
                searches += 1
            }
            ToolCall::WebFetch { .. } => fetches += 1,
            ToolCall::Todo { .. } => todos += 1,
            ToolCall::Mcp { .. } | ToolCall::Unknown { .. } => other += 1,
        }
    }
    let mut segments: Vec<String> = Vec::new();
    if commands > 0 {
        segments.push(format!("ran {}", plural(commands, "command", "commands")));
    }
    if !edited.is_empty() {
        segments.push(format!("edited {}", plural(edited.len(), "file", "files")));
    }
    if reads > 0 {
        segments.push(format!("read {}", plural(reads, "file", "files")));
    }
    if searches > 0 {
        segments.push(format!("searched {}", plural(searches, "time", "times")));
    }
    if fetches > 0 {
        segments.push(format!("fetched {}", plural(fetches, "page", "pages")));
    }
    if todos > 0 {
        segments.push("updated todos".to_string());
    }
    if other > 0 {
        segments.push(format!("called {}", plural(other, "tool", "tools")));
    }
    if segments.is_empty() {
        segments.push(plural(tools.len(), "tool", "tools"));
    }
    if failed > 0 {
        segments.push(format!("{failed} failed"));
    }
    let mut summary = segments.join(" · ");
    // Capitalize the first segment only (harness's style).
    if let Some(first) = summary.get(0..1) {
        let upper = first.to_uppercase();
        summary.replace_range(0..1, &upper);
    }
    summary
}

/// The status-dot palette, as oklch triples (L, C, H°).
///
/// Colors live here rather than in the viewport because the *meaning* of a
/// dot is part of the protocol, not the presentation — a given status must
/// read the same on every surface. `harness-ui` has the oklch→sRGB math.
pub mod dot {
    /// Running. Pink, not amber: the harsh yellow read as a warning, and running
    /// is routine (user request).
    pub const WORKING: (f32, f32, f32) = (0.718, 0.202, 349.761);
    /// Asking a question. Indigo — must read differently from "busy" at a glance.
    pub const AWAITING: (f32, f32, f32) = (0.673, 0.182, 276.935);
    /// Errored. Red-400.
    pub const ERRORED: (f32, f32, f32) = (0.704, 0.191, 22.216);
    /// Finished but unseen. Emerald — reads as "ready for you".
    pub const COMPLETED: (f32, f32, f32) = (0.765, 0.177, 163.223);
}

// ---------------------------------------------------------------------------
// Checkout selection (new sessions)
// ---------------------------------------------------------------------------

/// Where a new session runs (t3code's env-mode: `local | worktree`).
///
/// "Current worktree" is deliberately **not** a third mode — it is `Local` when
/// the picked ref already happens to be materialized as a worktree, in which
/// case the session reuses that checkout's path. Modelling it as three states
/// would let the UI hold a combination the engine cannot honour.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CheckoutKind {
    /// The space's own folder — or the picked ref's existing worktree.
    #[default]
    Local,
    /// A fresh isolated worktree created off the picked base ref on send.
    NewWorktree,
}

/// The resolved on-send checkout action.
#[derive(Debug, Clone, PartialEq)]
pub enum CheckoutPlan {
    /// Run in the space folder as-is. `branch` is the checkout's branch (the
    /// picked or current ref), carried onto `createChat` so the session names
    /// it from the first frame; `None` = refs never loaded.
    CurrentCheckout { branch: Option<String> },
    /// Reuse the picked ref's existing worktree (a cwd override; no git).
    ReuseWorktree { path: String, branch: String },
    /// `CreateWorktree` off `base` on send (the engine mints a `harness/<name>`
    /// branch). `base: None` = refs never loaded — send falls back to the space
    /// folder rather than failing.
    NewWorktree { base: Option<String> },
}

/// Resolve the on-send action from the mode and the picked ref.
pub fn checkout_plan(kind: CheckoutKind, picked: Option<&crate::RepoRef>) -> CheckoutPlan {
    let name = picked.map(|r| r.name.clone());
    match kind {
        CheckoutKind::NewWorktree => CheckoutPlan::NewWorktree { base: name },
        CheckoutKind::Local => match picked.and_then(|r| r.worktree_path.clone()) {
            Some(path) => CheckoutPlan::ReuseWorktree {
                path,
                branch: name.unwrap_or_default(),
            },
            None => CheckoutPlan::CurrentCheckout { branch: name },
        },
    }
}

/// Label of the checkout-kind trigger (t3code `resolveEnvModeLabel`).
pub fn checkout_label(kind: CheckoutKind, picked: Option<&crate::RepoRef>) -> &'static str {
    match kind {
        CheckoutKind::NewWorktree => "New worktree",
        CheckoutKind::Local => {
            if picked.is_some_and(|r| r.worktree_path.is_some()) {
                "Current worktree"
            } else {
                "Current checkout"
            }
        }
    }
}

#[cfg(test)]
mod checkout_tests {
    use super::*;
    use crate::RepoRef;

    fn plain(name: &str) -> RepoRef {
        RepoRef {
            name: name.into(),
            current: false,
            worktree_path: None,
        }
    }

    fn materialized(name: &str, path: &str) -> RepoRef {
        RepoRef {
            name: name.into(),
            current: false,
            worktree_path: Some(path.into()),
        }
    }

    #[test]
    fn local_resolves_by_whether_the_ref_has_a_worktree() {
        // The same mode means two different things depending on the ref — which
        // is exactly why "current worktree" is not its own state.
        assert_eq!(
            checkout_plan(CheckoutKind::Local, Some(&plain("main"))),
            CheckoutPlan::CurrentCheckout {
                branch: Some("main".into())
            }
        );
        assert_eq!(
            checkout_plan(CheckoutKind::Local, Some(&materialized("feat", "/wt/feat"))),
            CheckoutPlan::ReuseWorktree {
                path: "/wt/feat".into(),
                branch: "feat".into()
            }
        );
        // No ref picked at all is still the space folder — with no branch to
        // stamp until refs load.
        assert_eq!(
            checkout_plan(CheckoutKind::Local, None),
            CheckoutPlan::CurrentCheckout { branch: None }
        );
    }

    #[test]
    fn new_worktree_carries_its_base_and_tolerates_none() {
        assert_eq!(
            checkout_plan(CheckoutKind::NewWorktree, Some(&plain("main"))),
            CheckoutPlan::NewWorktree {
                base: Some("main".into())
            }
        );
        // Refs never loaded: send falls back to the space folder rather than
        // failing, so the base is allowed to be absent.
        assert_eq!(
            checkout_plan(CheckoutKind::NewWorktree, None),
            CheckoutPlan::NewWorktree { base: None }
        );
    }

    #[test]
    fn labels_say_which_of_the_three_outcomes_you_will_get() {
        assert_eq!(
            checkout_label(CheckoutKind::Local, Some(&plain("main"))),
            "Current checkout"
        );
        assert_eq!(
            checkout_label(CheckoutKind::Local, Some(&materialized("f", "/wt/f"))),
            "Current worktree"
        );
        assert_eq!(
            checkout_label(CheckoutKind::NewWorktree, Some(&plain("main"))),
            "New worktree"
        );
    }
}

#[cfg(test)]
mod sort_tests {
    use super::*;
    use chrono::TimeZone;

    fn chat(id: &str, prompt: Option<i64>, message: Option<i64>) -> Chat {
        let at = |ms| chrono::Utc.timestamp_millis_opt(ms).unwrap();
        let mut c: Chat = serde_json::from_value(serde_json::json!({
            "id": id, "deviceId": "d", "archived": false, "createdAt": at(0)
        }))
        .unwrap();
        c.last_prompt_at = prompt.map(at);
        c.last_message_at = message.map(at);
        c
    }

    #[test]
    fn orders_by_last_call_not_by_agent_replies() {
        let busy = chat("busy", Some(1_000), Some(9_000));
        let fresh = chat("fresh", Some(5_000), Some(5_000));
        let old_host = chat("old-host", None, Some(4_000));
        let mut rows = vec![
            (ChatIndicator::Idle, &busy),
            (ChatIndicator::Idle, &old_host),
            (ChatIndicator::Idle, &fresh),
        ];
        sort_active(&mut rows);
        let ids: Vec<&str> = rows.iter().map(|(_, c)| c.id.as_str()).collect();
        assert_eq!(ids, ["fresh", "old-host", "busy"]);
    }
}

#[cfg(test)]
mod preview_path_tests {
    use super::*;

    const NONE: PreviewPathAnchors<'static> = PreviewPathAnchors {
        workspace: None,
        home: None,
    };
    const MAC: PreviewPathAnchors<'static> = PreviewPathAnchors {
        workspace: Some("/Users/example/projects/demo"),
        home: Some("/Users/example"),
    };
    const WINDOWS: PreviewPathAnchors<'static> = PreviewPathAnchors {
        workspace: Some(r"C:\work\demo-app"),
        home: Some(r"C:\Users\ExampleUser"),
    };

    fn compact(command: &str, anchors: PreviewPathAnchors<'_>) -> String {
        compact_command_paths(command, anchors)
    }

    #[test]
    fn issue_examples_keep_the_executable_and_command() {
        // The collapsed `Run` preview used to show these byte for byte, so the
        // long executable path crowded the command off the row.
        assert_eq!(
            compact(
                r#""C:\Users\ExampleUser\.cache\agent-runtime\dependencies\native\powershell\pwsh.exe" -Command "git status""#,
                NONE,
            ),
            r#""…\powershell\pwsh.exe" -Command "git status""#
        );
        assert_eq!(
            compact(
                "/Users/example/tools/runtime/bundled/shells/zsh -lc 'git status'",
                NONE
            ),
            "…/shells/zsh -lc 'git status'"
        );
        assert_eq!(
            compact(
                r#"cat "/Users/example/projects/demo/application/src/settings.rs""#,
                NONE
            ),
            r#"cat "…/src/settings.rs""#
        );
    }

    #[test]
    fn short_commands_and_paths_are_unchanged() {
        for command in [
            r#""\folder\pwsh.exe" -Command "git status""#,
            "/bin/zsh -lc 'git status'",
            "git status",
            "ls -la /tmp",
            "cargo test -p harness-proto --lib view",
            "",
        ] {
            assert_eq!(compact(command, MAC), command);
            assert!(!command_has_long_path(command), "{command}");
        }
    }

    #[test]
    fn paths_inside_the_workspace_read_relative() {
        assert_eq!(
            compact(
                "cargo test --manifest-path /Users/example/projects/demo/crates/ui/Cargo.toml -p demo-ui",
                MAC,
            ),
            "cargo test --manifest-path crates/ui/Cargo.toml -p demo-ui"
        );
        assert_eq!(
            compact(
                "cargo build --manifest-path=/Users/example/projects/demo/crates/ui/Cargo.toml",
                MAC,
            ),
            "cargo build --manifest-path=crates/ui/Cargo.toml"
        );
        // Still long once relative: elided like any other path.
        assert_eq!(
            compact(
                "rustfmt /Users/example/projects/demo/crates/server/src/handlers/sessions/history.rs",
                MAC,
            ),
            "rustfmt …/sessions/history.rs"
        );
        // A sibling folder that merely shares the prefix isn't inside it.
        assert_eq!(
            compact("cat /Users/example/projects/demo-old/src/main.rs", MAC),
            "cat ~/projects/demo-old/src/main.rs"
        );
    }

    #[test]
    fn paths_under_home_use_a_tilde() {
        assert_eq!(
            compact("/Users/example/.local/share/toolchains/bin/rg -n TODO", MAC),
            "~/.local/share/toolchains/bin/rg -n TODO"
        );
        assert_eq!(
            compact(
                r#""/Users/example/Library/Application Support/Tool Runtime/bin/node" --version"#,
                MAC,
            ),
            r#""~/…/bin/node" --version"#
        );
        assert_eq!(
            compact(
                "~/Library/Caches/example-tool/runtime/bin/tool --help",
                NONE
            ),
            "~/…/bin/tool --help"
        );
    }

    #[test]
    fn quoted_and_escaped_paths_with_spaces() {
        assert_eq!(
            compact(
                r#"open "/Users/example/My Projects/demo app/build output/report.txt""#,
                NONE,
            ),
            r#"open "…/build output/report.txt""#
        );
        assert_eq!(
            compact(
                "open '/Users/example/My Projects/demo app/build output/report.txt'",
                NONE
            ),
            "open '…/build output/report.txt'"
        );
        assert_eq!(
            compact(
                r"ls /Users/example/My\ Projects/demo/very/deep/folder",
                NONE
            ),
            "ls …/deep/folder"
        );
    }

    #[test]
    fn every_long_path_in_a_command_is_shortened() {
        assert_eq!(
            compact(
                "cp /Users/example/projects/demo/target/release/app /Users/example/Applications/Staging/app && echo done",
                MAC,
            ),
            "cp target/release/app ~/Applications/Staging/app && echo done"
        );
    }

    #[test]
    fn windows_paths() {
        // UNC share, with a short `/quiet` switch left alone.
        assert_eq!(
            compact(
                r#""\\fileserver\team share\builds\nightly\2026\windows\setup.exe" /quiet"#,
                NONE,
            ),
            r#""…\windows\setup.exe" /quiet"#
        );
        // Extended-length prefix.
        assert_eq!(
            compact(
                r"\\?\C:\Users\ExampleUser\AppData\Local\Programs\tool\tool.exe --version",
                NONE,
            ),
            r"…\tool\tool.exe --version"
        );
        // Home matches case-insensitively.
        assert_eq!(
            compact(
                r"c:\users\exampleuser\AppData\Local\Programs\Tool\tool.exe --version",
                WINDOWS,
            ),
            r"~\…\Tool\tool.exe --version"
        );
        // Forward slashes inside a backslash workspace.
        assert_eq!(
            compact(
                "npx eslint C:/work/demo-app/src/components/panel.tsx",
                WINDOWS
            ),
            "npx eslint src/components/panel.tsx"
        );
        // Paths with parentheses are still paths.
        assert_eq!(
            compact(
                r#""C:\Program Files (x86)\Example Vendor\Example Tool\bin\tool.exe" sync"#,
                NONE,
            ),
            r#""…\bin\tool.exe" sync"#
        );
    }

    #[test]
    fn unicode_long_names_and_trailing_separators() {
        assert_eq!(
            compact(
                "cat \"/Users/example/プロジェクト/デモ/設定/ファイル.txt\"",
                NONE
            ),
            "cat \"…/設定/ファイル.txt\""
        );
        assert_eq!(
            compact(
                "tail /Users/example/projects/an-extremely-long-generated-file-name-that-never-ends.log",
                NONE,
            ),
            "tail …/an-extremely-long-generated-file-name-that-never-ends.log"
        );
        assert_eq!(
            compact("ls /Users/example/projects/demo/application/", NONE),
            "ls …/demo/application/"
        );
    }

    #[test]
    fn non_paths_are_left_alone() {
        for command in [
            "curl -L https://example.com/a/very/long/path/that/keeps/going/index.html",
            "rg -g '/Users/example/projects/demo/**/*.rs' needle",
            "sed -n '/^start of a long pattern here$/,/^end$/p' notes.txt",
            "bash -lc 'cd /Users/example/projects/demo/application && cargo build'",
            "echo $HOME/projects/demo/application/src/settings.rs",
            r"rg '/\d+/very/long/regular/expression/pattern/here/'",
            r#"tool --out="/Users/example/projects/demo/application/"suffix"#,
        ] {
            assert_eq!(compact(command, MAC), command);
        }
    }

    #[test]
    fn long_path_detection_matches_what_can_shorten() {
        assert!(command_has_long_path(
            "cat /Users/example/projects/demo/application/src/settings.rs"
        ));
        assert!(command_has_long_path(
            r#""C:\Users\ExampleUser\.cache\agent-runtime\dependencies\native\powershell\pwsh.exe" -Command "git status""#
        ));
        assert!(!command_has_long_path(
            "curl -L https://example.com/a/very/long/path/that/keeps/going/index.html"
        ));
    }
}
