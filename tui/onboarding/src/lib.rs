//! First-run setup for `harness-tui`: four questions and a ready screen, asked once before the
//! TUI starts, each answer landing in the real setting.
//!
//! 1. Agent: Graff first, preselected and recommended (it signs in through CodeGraff); Claude
//!    Code and OpenAI Codex are optional extras, saved with `SetHarnessEnabled`.
//! 2. Effort: the Graff model and its reasoning effort, saved as `model` and
//!    `model_reasoning_effort` in Codex's `config.toml` (what `/model` changes later).
//! 3. Autonomy: read only, workspace or full access, saved on the engine with `SetAutonomy`.
//! 4. Notifications: Codex's own terminal notifications (`tui.notifications`). A terminal
//!    has no permission prompt, so Yes just turns them on.
//!
//! It runs when `$CODEX_HOME/harness-setup.json` is missing on a fresh home (no
//! `config.toml` yet) or says `pending`. An existing install is marked done without asking.
//! `harness-tui --setup` (or `HARNESS_TUI_SETUP=1`) replays it; `HARNESS_TUI_SETUP=0` skips it.

use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::style::{Attribute, Color, Print, ResetColor, SetAttribute, SetBackgroundColor, SetForegroundColor};
use crossterm::{cursor, execute, queue, terminal};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

/// Questions before the ready screen.
pub const QUESTIONS: usize = 4;
const MARKER: &str = "harness-setup.json";
/// Reasoning efforts the Codex TUI can parse (the bridge drops the rest).
const CODEX_EFFORTS: [&str; 6] = ["none", "minimal", "low", "medium", "high", "xhigh"];
/// Used when the engine can't list Graff's models.
const FALLBACK_LEVELS: [&str; 4] = ["low", "medium", "high", "xhigh"];

// ----------------------------------------------------------------------------- answers

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Autonomy {
    ReadOnly,
    Workspace,
    FullAccess,
}

impl Autonomy {
    pub const ALL: [Autonomy; 3] = [Autonomy::ReadOnly, Autonomy::Workspace, Autonomy::FullAccess];

    pub fn wire(self) -> &'static str {
        match self {
            Autonomy::ReadOnly => "read-only",
            Autonomy::Workspace => "workspace",
            Autonomy::FullAccess => "full-access",
        }
    }

    pub fn parse(s: &str) -> Option<Autonomy> {
        Autonomy::ALL.into_iter().find(|a| a.wire() == s)
    }

    pub fn label(self) -> &'static str {
        match self {
            Autonomy::ReadOnly => "Read only",
            Autonomy::Workspace => "Workspace",
            Autonomy::FullAccess => "Full access",
        }
    }

    pub fn blurb(self) -> &'static str {
        match self {
            Autonomy::ReadOnly => "Reads and answers. Asks before it changes anything.",
            Autonomy::Workspace => "Edits files and runs commands inside the project. Asks before anything outside it.",
            Autonomy::FullAccess => "Edits, runs and reaches the network without asking. For trusted work.",
        }
    }

    /// What each level allows, in the order of [`CAPABILITIES`].
    fn allows(self) -> [bool; 4] {
        match self {
            Autonomy::ReadOnly => [true, false, false, false],
            Autonomy::Workspace => [true, true, true, false],
            Autonomy::FullAccess => [true, true, true, true],
        }
    }

    fn index(self) -> usize {
        Autonomy::ALL.iter().position(|a| *a == self).unwrap_or(1)
    }
}

const CAPABILITIES: [&str; 4] = [
    "Read files and search the project",
    "Edit files in the project",
    "Run commands in the project",
    "Work outside the project and use the network without asking",
];

#[derive(Clone, Debug)]
pub struct Model {
    pub id: String,
    pub label: String,
    pub levels: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Extra {
    pub id: &'static str,
    pub name: &'static str,
    pub installed: bool,
    pub on: bool,
    pub was: bool,
}

/// Everything the setup asks, with the defaults it starts from.
#[derive(Clone, Debug)]
pub struct State {
    pub step: usize,
    /// The engine answered; without it the agent and autonomy answers can't be saved.
    pub engine: bool,
    pub extras: Vec<Extra>,
    pub cursor: usize,
    pub models: Vec<Model>,
    pub model: usize,
    /// Graff's own efforts (`ListHarnesses`), for models that don't list theirs.
    pub graff_levels: Vec<String>,
    pub level: usize,
    pub autonomy: Autonomy,
    pub notify: bool,
}

impl State {
    pub fn new(engine: bool, harnesses: &[Value], models: Vec<Model>) -> State {
        let extras = [("claude-code", "Claude Code"), ("codex", "OpenAI Codex")]
            .into_iter()
            .map(|(id, name)| {
                let h = harnesses.iter().find(|h| h["id"] == id);
                let installed = h.is_some_and(|h| h["installed"].as_bool().unwrap_or(false));
                let on = installed && h.is_some_and(|h| h["enabled"].as_bool().unwrap_or(false));
                Extra { id, name, installed, on, was: on }
            })
            .collect();
        let graff_levels = harnesses
            .iter()
            .find(|h| h["id"] == "graff")
            .and_then(|h| h["reasoningLevels"].as_array())
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|l| CODEX_EFFORTS.contains(l))
            .map(str::to_owned)
            .collect();
        let mut s = State {
            step: 0,
            graff_levels,
            engine,
            extras,
            cursor: 0,
            models: models.into_iter().take(3).collect(),
            model: 0,
            level: 0,
            autonomy: Autonomy::Workspace,
            notify: true,
        };
        s.level = s.default_level();
        s
    }

    pub fn levels(&self) -> Vec<String> {
        match self.models.get(self.model) {
            Some(m) if !m.levels.is_empty() => m.levels.clone(),
            _ if !self.graff_levels.is_empty() => self.graff_levels.clone(),
            _ => FALLBACK_LEVELS.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn default_level(&self) -> usize {
        let levels = self.levels();
        levels.iter().position(|l| l == "high").unwrap_or(levels.len() / 2)
    }

    pub fn effort(&self) -> String {
        let levels = self.levels();
        levels.get(self.level.min(levels.len().saturating_sub(1))).cloned().unwrap_or_default()
    }

    /// Feed one key. `Some` ends the setup.
    pub fn key(&mut self, key: KeyEvent) -> Option<Outcome> {
        if key.kind == KeyEventKind::Release {
            return None;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            return Some(Outcome::Quit);
        }
        match key.code {
            KeyCode::Enter => {
                if self.step >= QUESTIONS {
                    return Some(Outcome::Finished);
                }
                self.step += 1;
            }
            KeyCode::Esc | KeyCode::Backspace => self.step = self.step.saturating_sub(1),
            KeyCode::Char('s') if self.step < QUESTIONS => return Some(Outcome::Skipped),
            KeyCode::Left | KeyCode::Char('h') => self.nudge(-1),
            KeyCode::Right | KeyCode::Char('l') => self.nudge(1),
            KeyCode::Up | KeyCode::Char('k') if self.step == 0 => self.cursor = self.cursor.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') if self.step == 0 => {
                self.cursor = (self.cursor + 1).min(self.extras.len().saturating_sub(1))
            }
            KeyCode::Char(' ') if self.step == 0 => {
                if let Some(e) = self.extras.get_mut(self.cursor) {
                    if e.installed {
                        e.on = !e.on;
                    }
                }
            }
            KeyCode::Tab if self.step == 1 && !self.models.is_empty() => {
                self.model = (self.model + 1) % self.models.len();
                self.level = self.default_level();
            }
            KeyCode::Char('y') if self.step == 3 => self.notify = true,
            KeyCode::Char('n') if self.step == 3 => self.notify = false,
            _ => {}
        }
        None
    }

    fn nudge(&mut self, by: isize) {
        match self.step {
            1 => {
                let n = self.levels().len() as isize;
                self.level = (self.level as isize + by).clamp(0, n - 1) as usize;
            }
            2 => {
                let i = (self.autonomy.index() as isize + by).clamp(0, 2) as usize;
                self.autonomy = Autonomy::ALL[i];
            }
            3 => self.notify = by < 0,
            _ => {}
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Finished,
    Skipped,
    /// Ctrl-C: leave everything as it was and ask again next launch.
    Quit,
}

// ----------------------------------------------------------------------------- drawing

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tone {
    Plain,
    Dim,
    Bold,
    Title,
    /// Inverted: the chosen option.
    Chosen,
    /// Boxed: the focused option that isn't inverted.
    Focus,
    Accent,
    Bar,
}

pub type Span = (String, Tone);
pub type Line = Vec<Span>;

fn sp(text: impl Into<String>, tone: Tone) -> Span {
    (text.into(), tone)
}

/// One screen of the setup, as styled lines. Pure, so tests can read it.
pub fn frame(s: &State) -> Vec<Line> {
    let mut out: Vec<Line> = Vec::new();
    let progress = if s.step < QUESTIONS {
        let filled = 16 * (s.step + 1) / QUESTIONS;
        vec![
            sp("harness setup", Tone::Dim),
            sp(format!("{:>30}", format!("{}/{}  ", s.step + 1, QUESTIONS)), Tone::Dim),
            sp("━".repeat(filled), Tone::Bold),
            sp("━".repeat(16 - filled), Tone::Dim),
        ]
    } else {
        vec![sp("harness setup", Tone::Dim), sp(format!("{:>30}", "ready"), Tone::Dim)]
    };
    out.push(progress);
    out.push(vec![]);
    let (title, sub) = match s.step {
        0 => ("Which agents should it use?", "Graff runs your sessions. Add others any time with /model."),
        1 => ("How hard should it think?", "Default for new sessions. Change it later with /model."),
        2 => ("How much can it do on its own?", "Applies to every agent on this computer. Change it later with harness-tui --setup."),
        3 => ("Tell you when it needs you?", "A terminal notification when a turn finishes or it is waiting on you."),
        _ => ("You're set.", "Start a session. Run harness-tui --setup to change any of this."),
    };
    out.push(vec![sp(title, Tone::Title)]);
    out.push(vec![sp(sub, Tone::Dim)]);
    out.push(vec![]);
    match s.step {
        0 => agents(s, &mut out),
        1 => effort(s, &mut out),
        2 => autonomy(s, &mut out),
        3 => notify(s, &mut out),
        _ => ready(s, &mut out),
    }
    out.push(vec![]);
    out.push(hints(s));
    out
}

fn agents(s: &State, out: &mut Vec<Line>) {
    out.push(vec![
        sp("  [x] ", Tone::Bold),
        sp("Graff", Tone::Bold),
        sp("  Recommended ", Tone::Chosen),
        sp("  Connected with your CodeGraff sign-in", Tone::Dim),
    ]);
    out.push(vec![sp("      Runs every session by default.", Tone::Dim)]);
    out.push(vec![]);
    out.push(vec![sp("  Optional extras", Tone::Dim)]);
    for (i, e) in s.extras.iter().enumerate() {
        let mark = if e.on { "[x]" } else { "[ ]" };
        let tone = if !e.installed {
            Tone::Dim
        } else if i == s.cursor {
            Tone::Focus
        } else {
            Tone::Plain
        };
        let pointer = if i == s.cursor { "› " } else { "  " };
        let note = if e.installed { "" } else { "  not installed on this computer" };
        out.push(vec![sp(pointer, Tone::Accent), sp(format!("{mark} {}", e.name), tone), sp(note, Tone::Dim)]);
    }
    if !s.engine {
        out.push(vec![]);
        out.push(vec![sp("  Harness isn't running, so extras can't be changed here.", Tone::Dim)]);
    }
}

fn effort(s: &State, out: &mut Vec<Line>) {
    let mut row = vec![sp("  model   ", Tone::Bold)];
    if s.models.is_empty() {
        row.push(sp(" Graff default ", Tone::Focus));
    } else {
        for (i, m) in s.models.iter().enumerate() {
            row.push(sp(format!(" {} ", m.label), if i == s.model { Tone::Focus } else { Tone::Dim }));
            row.push(sp("  ", Tone::Plain));
        }
        if s.models.len() > 1 {
            row.push(sp("  tab", Tone::Dim));
        }
    }
    out.push(row);
    out.push(vec![]);
    let levels = s.levels();
    let mut row = vec![sp("  effort  ", Tone::Bold)];
    for (i, l) in levels.iter().enumerate() {
        if i > 0 {
            row.push(sp(" — ", Tone::Dim));
        }
        let name = level_name(l);
        row.push(if i == s.level { sp(format!(" {name} "), Tone::Chosen) } else { sp(name, Tone::Plain) });
    }
    out.push(row);
    out.push(vec![]);
    let n = levels.len().max(1);
    let filled = 28 * (s.level + 1) / n;
    out.push(vec![
        sp("          ", Tone::Plain),
        sp("█".repeat(filled), Tone::Bar),
        sp("░".repeat(28 - filled), Tone::Dim),
        sp(format!("  {}", s.level + 1), Tone::Bold),
        sp(format!("/{n}"), Tone::Dim),
    ]);
    out.push(vec![sp("          ", Tone::Plain), sp(level_blurb(&s.effort()), Tone::Plain)]);
}

fn level_name(l: &str) -> String {
    match l {
        "xhigh" => "X-High".into(),
        "none" => "None".into(),
        other => {
            let mut c = other.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

fn level_blurb(l: &str) -> &'static str {
    match l {
        "none" | "minimal" => "Answers right away. For quick questions.",
        "low" => "Light thinking. Fast for small edits.",
        "medium" => "Thinks a little first. Good for everyday changes.",
        "high" => "Thinks before it edits. The default for real work.",
        "xhigh" => "Thinks longest. For hard bugs and big changes.",
        _ => "Thinks as long as the task needs.",
    }
}

fn autonomy(s: &State, out: &mut Vec<Line>) {
    let mut row = vec![sp("  ", Tone::Plain)];
    for (i, a) in Autonomy::ALL.iter().enumerate() {
        if i > 0 {
            row.push(sp(" — ", Tone::Dim));
        }
        row.push(if *a == s.autonomy { sp(format!(" {} ", a.label()), Tone::Chosen) } else { sp(a.label(), Tone::Plain) });
        if *a == Autonomy::Workspace {
            row.push(sp(" (recommended)", Tone::Dim));
        }
    }
    out.push(row);
    out.push(vec![]);
    out.push(vec![sp("  ", Tone::Plain), sp(s.autonomy.blurb(), Tone::Plain)]);
    out.push(vec![]);
    for (cap, ok) in CAPABILITIES.iter().zip(s.autonomy.allows()) {
        out.push(vec![
            sp(if ok { "  ✓ " } else { "  · " }, if ok { Tone::Accent } else { Tone::Dim }),
            sp(*cap, if ok { Tone::Plain } else { Tone::Dim }),
            sp(if ok { "" } else { "  asks first" }, Tone::Dim),
        ]);
    }
    if !s.engine {
        out.push(vec![]);
        out.push(vec![sp("  Harness isn't running, so this can't be saved yet. Replay with --setup later.", Tone::Dim)]);
    }
}

fn notify(s: &State, out: &mut Vec<Line>) {
    let yes = if s.notify { sp(" Yes ", Tone::Chosen) } else { sp(" Yes ", Tone::Plain) };
    let no = if s.notify { sp(" No ", Tone::Plain) } else { sp(" No ", Tone::Chosen) };
    out.push(vec![sp("  ", Tone::Plain), yes, sp("   ", Tone::Plain), no]);
    out.push(vec![]);
    out.push(vec![sp(
        if s.notify {
            "  Your terminal shows a notification when it finishes or needs an answer."
        } else {
            "  No notifications. You can turn them on later in config.toml (tui.notifications)."
        },
        Tone::Dim,
    )]);
}

fn ready(s: &State, out: &mut Vec<Line>) {
    let mut agents = vec!["Graff".to_string()];
    agents.extend(s.extras.iter().filter(|e| e.on).map(|e| e.name.to_string()));
    let model = s.models.get(s.model).map(|m| m.label.clone()).unwrap_or_else(|| "Graff default".into());
    let rows = [
        ("agents", agents.join(", ")),
        ("model", format!("{model}, {} effort", level_name(&s.effort()))),
        ("autonomy", s.autonomy.label().to_string()),
        ("notify", if s.notify { "On".into() } else { "Off".into() }),
    ];
    for (k, v) in rows {
        out.push(vec![sp(format!("  {k:<10}"), Tone::Dim), sp(v, Tone::Bold)]);
    }
}

fn hints(s: &State) -> Line {
    let mut h: Line = Vec::new();
    let mut add = |k: &str, t: Tone| {
        if !h.is_empty() {
            h.push(sp("    ", Tone::Plain));
        }
        h.push(sp(k, t));
    };
    match s.step {
        0 => add("↑/↓ move  space add", Tone::Dim),
        1 => {
            add("←/→ change", Tone::Dim);
            if s.models.len() > 1 {
                add("tab model", Tone::Dim);
            }
        }
        2 | 3 => add("←/→ change", Tone::Dim),
        _ => {}
    }
    add(if s.step >= QUESTIONS { " ⏎ Start a session " } else { " ⏎ Next " }, Tone::Chosen);
    if s.step > 0 {
        add("esc back", Tone::Dim);
    }
    if s.step < QUESTIONS {
        add("s skip", Tone::Dim);
    }
    h
}

/// Plain text of a frame, for tests and `--print`.
pub fn plain(lines: &[Line]) -> String {
    lines
        .iter()
        .map(|l| l.iter().map(|(t, _)| t.as_str()).collect::<String>().trim_end().to_string())
        .collect::<Vec<_>>()
        .join("\n")
}

fn paint(out: &mut impl Write, lines: &[Line]) -> io::Result<()> {
    queue!(out, terminal::Clear(terminal::ClearType::All), cursor::MoveTo(0, 0))?;
    for (row, line) in lines.iter().enumerate() {
        queue!(out, cursor::MoveTo(4, row as u16 + 2))?;
        for (text, tone) in line {
            match tone {
                Tone::Plain => {}
                Tone::Dim => queue!(out, SetAttribute(Attribute::Dim))?,
                Tone::Bold => queue!(out, SetAttribute(Attribute::Bold))?,
                Tone::Title => queue!(out, SetAttribute(Attribute::Bold), SetForegroundColor(Color::White))?,
                Tone::Chosen => queue!(out, SetAttribute(Attribute::Reverse), SetAttribute(Attribute::Bold))?,
                Tone::Focus => queue!(out, SetAttribute(Attribute::Underlined), SetAttribute(Attribute::Bold))?,
                Tone::Accent => queue!(out, SetForegroundColor(Color::Green))?,
                Tone::Bar => queue!(out, SetForegroundColor(Color::Cyan))?,
            }
            queue!(out, Print(text), SetAttribute(Attribute::Reset), ResetColor, SetBackgroundColor(Color::Reset))?;
        }
    }
    out.flush()
}

/// Ask the questions in the alternate screen. The terminal is put back whatever happens.
pub fn ask(state: &mut State) -> io::Result<Outcome> {
    let mut out = io::stdout();
    terminal::enable_raw_mode()?;
    execute!(out, terminal::EnterAlternateScreen, cursor::Hide)?;
    let result = (|| loop {
        paint(&mut out, &frame(state))?;
        if let Event::Key(key) = event::read()? {
            if let Some(done) = state.key(key) {
                return Ok(done);
            }
        }
    })();
    let _ = execute!(out, cursor::Show, terminal::LeaveAlternateScreen);
    let _ = terminal::disable_raw_mode();
    result
}

// ----------------------------------------------------------------------------- gate

pub fn codex_home(explicit: Option<&Path>) -> PathBuf {
    if let Some(p) = explicit {
        return p.to_path_buf();
    }
    if let Some(home) = std::env::var_os("CODEX_HOME") {
        return PathBuf::from(home);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into());
    home.join(".harness/tui/codex-home")
}

fn write_marker(home: &Path, state: &str) {
    let _ = std::fs::create_dir_all(home);
    let _ = std::fs::write(home.join(MARKER), format!("{{\"state\":\"{state}\"}}\n"));
}

/// Whether to ask. Records the first decision so it is made once.
pub fn due(home: &Path, force: bool) -> bool {
    match std::env::var("HARNESS_TUI_SETUP").as_deref() {
        Ok("0") => return false,
        Ok("1") => return true,
        _ => {}
    }
    if force {
        return true;
    }
    match std::fs::read_to_string(home.join(MARKER)) {
        Ok(text) => text.contains("pending"),
        Err(_) => {
            // An install that already has a config was set up before this existed.
            let fresh = !home.join("config.toml").exists();
            write_marker(home, if fresh { "pending" } else { "done" });
            fresh
        }
    }
}

// ----------------------------------------------------------------------------- engine

/// A minimal client for the engine's local IPC (`ClientFrame {id, method, params}` in,
/// `ServerFrame {id, ok | err}` out).
pub struct Engine {
    ws: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    next: u64,
}

impl Engine {
    pub async fn connect() -> Option<Engine> {
        let port = std::env::var("HARNESS_IPC_PORT").ok().and_then(|p| p.parse::<u16>().ok()).unwrap_or(27664);
        let url = format!("ws://127.0.0.1:{port}");
        let (ws, _) = tokio::time::timeout(Duration::from_secs(2), tokio_tungstenite::connect_async(url))
            .await
            .ok()?
            .ok()?;
        Some(Engine { ws, next: 1 })
    }

    pub async fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next;
        self.next += 1;
        let frame = json!({ "id": id, "method": method, "params": params }).to_string();
        self.ws.send(Message::Text(frame.into())).await.map_err(|e| e.to_string())?;
        let wait = async {
            while let Some(msg) = self.ws.next().await {
                let Ok(Message::Text(text)) = msg else { continue };
                let Ok(v) = serde_json::from_str::<Value>(text.as_str()) else { continue };
                if v["id"].as_u64() != Some(id) {
                    continue;
                }
                if let Some(err) = v.get("err") {
                    return Err(err["message"].as_str().map(str::to_owned).unwrap_or_else(|| err.to_string()));
                }
                return Ok(v.get("ok").cloned().unwrap_or(Value::Null));
            }
            Err("the engine closed the connection".to_owned())
        };
        tokio::time::timeout(Duration::from_secs(20), wait).await.map_err(|_| format!("{method} timed out"))?
    }
}

/// Graff's models from a `ListModels` reply.
pub fn parse_models(v: &Value) -> Vec<Model> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let id = m["id"].as_str()?.to_owned();
            let label = m["label"].as_str().or(m["name"].as_str()).unwrap_or(&id).to_owned();
            let levels = m["reasoningLevels"]
                .as_array()
                .or(m["reasoning_levels"].as_array())
                .into_iter()
                .flatten()
                .filter_map(|l| l.as_str().or(l["id"].as_str()).or(l["effort"].as_str()))
                .filter(|l| CODEX_EFFORTS.contains(l))
                .map(str::to_owned)
                .collect();
            Some(Model { id, label, levels })
        })
        .collect()
}

/// What the engine says now, for the first screen.
pub async fn load(engine: &mut Option<Engine>) -> State {
    let Some(e) = engine.as_mut() else {
        return State::new(false, &[], Vec::new());
    };
    let harnesses = e.call("ListHarnesses", json!({})).await.unwrap_or(Value::Null);
    let models = e.call("ListModels", json!({ "harness": "graff" })).await.map(|v| parse_models(&v)).unwrap_or_default();
    let mut s = State::new(true, harnesses.as_array().map(Vec::as_slice).unwrap_or(&[]), models);
    if let Ok(v) = e.call("GetAutonomy", json!({})).await {
        // An earlier choice wins over the suggestion; the unchosen default is full access,
        // which setup doesn't push on anyone.
        if v["chosen"].as_bool() == Some(true) {
            if let Some(a) = v["autonomy"].as_str().and_then(Autonomy::parse) {
                s.autonomy = a;
            }
        }
    }
    s
}

// ----------------------------------------------------------------------------- saving

/// Write the TUI's own answers into `config.toml`, keeping everything else in the file.
pub fn write_config(home: &Path, s: &State) -> io::Result<()> {
    let path = home.join("config.toml");
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let mut doc = text.parse::<toml_edit::DocumentMut>().unwrap_or_default();
    if let Some(m) = s.models.get(s.model) {
        doc["model"] = toml_edit::value(format!("graff/{}", m.id.trim_start_matches("graff/")));
    }
    let effort = s.effort();
    if CODEX_EFFORTS.contains(&effort.as_str()) {
        doc["model_reasoning_effort"] = toml_edit::value(effort);
    }
    if !doc.contains_table("tui") {
        doc["tui"] = toml_edit::table();
    }
    doc["tui"]["notifications"] = toml_edit::value(s.notify);
    std::fs::create_dir_all(home)?;
    std::fs::write(path, doc.to_string())
}

/// Save every answer. Returns what couldn't be saved, for one line after the screen closes.
pub async fn save(home: &Path, s: &State, engine: &mut Option<Engine>) -> Vec<String> {
    let mut problems = Vec::new();
    if let Err(e) = write_config(home, s) {
        problems.push(format!("could not write config.toml: {e}"));
    }
    match engine.as_mut() {
        Some(e) => {
            for x in s.extras.iter().filter(|x| x.on != x.was) {
                if let Err(err) = e.call("SetHarnessEnabled", json!({ "harness": x.id, "enabled": x.on })).await {
                    problems.push(format!("{}: {err}", x.name));
                }
            }
            if let Err(err) = e.call("SetAutonomy", json!({ "autonomy": s.autonomy.wire() })).await {
                problems.push(format!("autonomy: {err}"));
            }
        }
        None => problems.push("Harness isn't running, so agents and autonomy weren't saved. Run harness-tui --setup once it is.".into()),
    }
    write_marker(home, "done");
    problems
}

/// The whole first run: check the gate, ask, save. Never fails the launch.
pub async fn run(codex_home_dir: Option<&Path>, force: bool) {
    let home = codex_home(codex_home_dir);
    if !due(&home, force) || !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return;
    }
    let mut engine = Engine::connect().await;
    let mut state = load(&mut engine).await;
    match ask(&mut state) {
        Ok(Outcome::Finished) => {
            for p in save(&home, &state, &mut engine).await {
                eprintln!("setup: {p}");
            }
        }
        Ok(Outcome::Skipped) => write_marker(&home, "done"),
        Ok(Outcome::Quit) => std::process::exit(130),
        Err(e) => eprintln!("setup: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(s: &mut State, code: KeyCode) -> Option<Outcome> {
        s.key(KeyEvent::new(code, KeyModifiers::NONE))
    }

    fn sample() -> State {
        let harnesses = json!([
            { "id": "graff", "installed": true, "enabled": true },
            { "id": "claude-code", "installed": true, "enabled": false },
            { "id": "codex", "installed": false, "enabled": false },
        ]);
        let models = parse_models(&json!([
            { "id": "opus-5", "label": "Opus 5", "reasoningLevels": ["low", "medium", "high", "xhigh", "ultrathink"] },
            { "id": "gpt-5.6", "label": "GPT-5.6", "reasoningLevels": ["low", "medium", "high"] },
        ]));
        State::new(true, harnesses.as_array().unwrap(), models)
    }

    #[test]
    fn graff_first_and_preselected_extras_off() {
        let s = sample();
        let text = plain(&frame(&s));
        let graff = text.find("Graff").unwrap();
        assert!(graff < text.find("Claude Code").unwrap());
        assert!(text.contains("[x] Graff  Recommended"));
        assert!(text.contains("[ ] Claude Code"));
        assert!(text.contains("not installed"));
        assert_eq!(s.autonomy, Autonomy::Workspace);
        assert_eq!(s.effort(), "high", "unknown levels are dropped and high is the default");
    }

    #[test]
    fn walk_lands_every_answer() {
        let mut s = sample();
        press(&mut s, KeyCode::Char(' '));
        press(&mut s, KeyCode::Down);
        press(&mut s, KeyCode::Char(' ')); // not installed: stays off
        assert!(s.extras[0].on && !s.extras[1].on);
        press(&mut s, KeyCode::Enter);
        press(&mut s, KeyCode::Tab);
        press(&mut s, KeyCode::Left);
        assert_eq!((s.model, s.effort().as_str()), (1, "medium"));
        press(&mut s, KeyCode::Enter);
        press(&mut s, KeyCode::Right);
        assert_eq!(s.autonomy, Autonomy::FullAccess);
        press(&mut s, KeyCode::Esc);
        assert_eq!(s.step, 1);
        press(&mut s, KeyCode::Enter);
        press(&mut s, KeyCode::Enter);
        press(&mut s, KeyCode::Char('n'));
        press(&mut s, KeyCode::Enter);
        assert_eq!(s.step, QUESTIONS);
        assert!(plain(&frame(&s)).contains("Full access"));
        assert_eq!(press(&mut s, KeyCode::Enter), Some(Outcome::Finished));

        let dir = std::env::temp_dir().join(format!("harness-tui-setup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.toml"), "# mine\nmodel = \"codex/old\"\n[tui]\ntheme = \"codegraff\"\n").unwrap();
        write_config(&dir, &s).unwrap();
        let text = std::fs::read_to_string(dir.join("config.toml")).unwrap();
        assert!(text.contains("# mine"));
        assert!(text.contains("model = \"graff/gpt-5.6\""));
        assert!(text.contains("model_reasoning_effort = \"medium\""));
        assert!(text.contains("theme = \"codegraff\""));
        assert!(text.contains("notifications = false"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn skip_and_gate() {
        let mut s = sample();
        assert_eq!(press(&mut s, KeyCode::Char('s')), Some(Outcome::Skipped));
        let dir = std::env::temp_dir().join(format!("harness-tui-gate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // SAFETY: tests in this module don't read HARNESS_TUI_SETUP concurrently.
        unsafe { std::env::remove_var("HARNESS_TUI_SETUP") };
        assert!(due(&dir, false), "a fresh home asks");
        assert!(due(&dir, false), "and keeps asking until answered");
        write_marker(&dir, "done");
        assert!(!due(&dir, false));
        assert!(due(&dir, true), "--setup replays");
        let old = dir.join("old");
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(old.join("config.toml"), "model = \"graff/x\"\n").unwrap();
        assert!(!due(&old, false), "an existing install is not asked");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
