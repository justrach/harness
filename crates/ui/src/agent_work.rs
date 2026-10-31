//! Agent work components: what the selected chat's agent is doing, drawn as a
//! step timeline, a row of step dots, a card of running subagents, and chips
//! for the tools in use.
//!
//! Everything shown comes from the transcript of the current turn (since the
//! last user message):
//! - steps are the agent's latest todo list; the first open item is the
//!   active one while the turn streams;
//! - the active step's substeps are the tool calls made since that list was
//!   last written, and its status word comes from the newest unfinished one;
//! - a question the agent is waiting on (an unresolved input request) is the
//!   gated last step, marked "Asks first";
//! - a done step's duration is the time between the todo snapshots that
//!   opened and closed it, and only when they came from different messages
//!   (a single streamed message carries one timestamp, so nothing is shown
//!   rather than a made-up number);
//! - agents are subagent spawns with a lifecycle status; running ones show
//!   their live tail, finished ones "Ready to review";
//! - tool chips are the tool families and MCP servers the turn used.
//!
//! Motion: active states are ring spinners on one shared 1s clock, so every
//! spinner stays in phase. A substep or a step changing state fades up over
//! 200ms. Reduced motion stops the spinners on a static partial ring and
//! snaps the fades.
use std::time::Duration;

use gpui::{
    AnyElement, App, AppContext, Context, ElementId, Entity, EntityId, Hsla, IntoElement,
    PathBuilder, Render, SharedString, Subscription, Window, canvas, div, point, prelude::*, px,
};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry, SubagentStatus};
use harness_proto::{COMPACTION_TOOL_NAME, ToolCall};

use crate::context_usage::{HitSlop, hit_area};
use crate::motion::{AnimationExt, CubicBezier, MotionSpec};
use crate::popover::outer_radius;
use crate::state::AppState;
use crate::theme::Theme;
use crate::typography::{CAP_CENTER_NUDGE, TEXT_BODY, TEXT_TITLE, TabularNums};

/// One spinner turn: linear, clockwise, shared by every spinner.
pub const SPIN: MotionSpec = MotionSpec::new(1000, CubicBezier::new(0.0, 0.0, 1.0, 1.0));
/// Enter transition for a substep or a step changing state.
pub const ENTER: MotionSpec = MotionSpec::new(180, crate::motion::EASE_OUT_QUINT);
/// The spinner's gap, in turns (54 degrees).
const SPINNER_GAP: f32 = 0.15;
/// Substeps shown under the active step, newest last.
pub const MAX_SUBSTEPS: usize = 3;
/// Step dots in the composer footer before it switches to "3/9".
const MAX_FOOTER_DOTS: usize = 6;
const TITLE_MAX: usize = 44;
/// Top inset of an agent row's 18 px glyph, so it centers on the title's
/// letters rather than the top of its line box.
const AGENT_GLYPH_TOP: f32 = 2.0;

// Geometry of the timeline (px).
const STEP_ROW: f32 = 34.0;
const SUB_ROW: f32 = 28.0;
const ICON: f32 = 18.0;
const SUB_X: f32 = 25.0;
const TEXT_X: f32 = 40.0;
const CARD_W: f32 = 320.0;
const CARD_PAD: f32 = 16.0;
/// Tool chips: the shared small-control radius.
const CHIP_RADIUS: f32 = Theme::CONTROL_RADIUS;
/// The card's corners are concentric with the chips that sit in its corner:
/// chip radius + 1 px border + padding.
const CARD_RADIUS: f32 = outer_radius(CHIP_RADIUS, 1.0, CARD_PAD);

/// Where a step stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepState {
    Done,
    Active,
    Pending,
    /// Waits on the user before it runs.
    AsksFirst,
}

/// Where a substep stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubState {
    Done,
    Active,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Substep {
    pub id: String,
    pub title: String,
    pub state: SubState,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub title: String,
    pub state: StepState,
    /// Measured from todo snapshots in different messages; `None` otherwise.
    pub duration_ms: Option<i64>,
    /// The active step's verb ("Writing"), from its newest unfinished tool.
    pub status: Option<&'static str>,
    pub substeps: Vec<Substep>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Running,
    Done,
    Failed,
    Stopped,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AgentRow {
    pub id: String,
    pub title: String,
    pub state: AgentState,
    /// Live tail while running; the outcome once it ends.
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolChip {
    pub label: String,
    pub icon: &'static str,
}

/// Everything the components draw for one chat.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Work {
    pub steps: Vec<Step>,
    pub agents: Vec<AgentRow>,
    pub tools: Vec<ToolChip>,
    /// The turn is still streaming.
    pub live: bool,
}

impl Work {
    pub fn is_empty(&self) -> bool {
        self.steps.is_empty() && self.agents.is_empty()
    }

    pub fn running_agents(&self) -> usize {
        self.agents
            .iter()
            .filter(|a| a.state == AgentState::Running)
            .count()
    }
}

fn is_compaction(call: &ToolCall) -> bool {
    matches!(call, ToolCall::Unknown { name, .. } if name == COMPACTION_TOOL_NAME)
}

fn first_line(text: &str, max: usize) -> String {
    let line = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim();
    let mut out: String = line.chars().take(max).collect();
    if line.chars().count() > max {
        out.push('…');
    }
    out
}

fn file_name(path: &str) -> &str {
    path.rsplit(['/', '\\'])
        .find(|c| !c.is_empty())
        .unwrap_or(path)
}

fn host(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    rest.split(['/', '?', '#']).next().unwrap_or(rest)
}

/// "Reading x" while it runs, "Read x" once done. `None` for calls that are
/// not work of their own (todo updates, compaction).
pub fn substep_title(call: &ToolCall, done: bool) -> Option<String> {
    let verb = |running: &str, finished: &str| if done { finished } else { running }.to_owned();
    let (verb, object) = match call {
        ToolCall::Todo { .. } => return None,
        call if is_compaction(call) => return None,
        ToolCall::Exec { command } => (verb("Running", "Ran"), first_line(command, TITLE_MAX)),
        ToolCall::ReadFile { path } => (verb("Reading", "Read"), file_name(path).to_owned()),
        ToolCall::WriteFile { path, .. } => (verb("Writing", "Wrote"), file_name(path).to_owned()),
        ToolCall::EditFile { path, .. } => (verb("Editing", "Edited"), file_name(path).to_owned()),
        ToolCall::ApplyPatch { path } => (
            verb("Patching", "Patched"),
            path.as_deref()
                .map_or("files".to_owned(), |p| file_name(p).to_owned()),
        ),
        ToolCall::Search { pattern, .. } | ToolCall::Glob { pattern } => (
            verb("Searching", "Searched"),
            first_line(pattern, TITLE_MAX),
        ),
        ToolCall::WebFetch { url, .. } => (verb("Fetching", "Fetched"), host(url).to_owned()),
        ToolCall::WebSearch { query } => (
            verb("Searching the web for", "Searched the web for"),
            first_line(query, TITLE_MAX),
        ),
        call if call.is_subagent_spawn() => (
            verb("Delegating", "Delegated"),
            crate::transcript::subagent_tab_title(call)
                .map_or("a subagent".to_owned(), |t| t.to_string()),
        ),
        ToolCall::Mcp { server, tool, .. } => (verb("Using", "Used"), format!("{server} {tool}")),
        ToolCall::Unknown { name, .. } => (verb("Using", "Used"), first_line(name, TITLE_MAX)),
    };
    Some(first_line(&format!("{verb} {object}"), TITLE_MAX))
}

/// The active step's status word, from the tool it is waiting on.
pub fn status_word(call: Option<&ToolCall>) -> &'static str {
    match call {
        Some(ToolCall::Exec { .. }) => "Running",
        Some(
            ToolCall::WriteFile { .. } | ToolCall::EditFile { .. } | ToolCall::ApplyPatch { .. },
        ) => "Writing",
        Some(ToolCall::ReadFile { .. }) => "Reading",
        Some(ToolCall::Search { .. } | ToolCall::Glob { .. }) => "Searching",
        Some(ToolCall::WebFetch { .. } | ToolCall::WebSearch { .. }) => "Browsing",
        Some(call) if call.is_subagent_spawn() => "Delegating",
        _ => "Working",
    }
}

fn tool_chip(call: &ToolCall) -> Option<ToolChip> {
    let chip = |label: &str, icon| {
        Some(ToolChip {
            label: label.to_owned(),
            icon,
        })
    };
    match call {
        ToolCall::Todo { .. } => None,
        call if is_compaction(call) => None,
        call if call.is_subagent_spawn() => chip("Agents", crate::icons::BOT),
        ToolCall::Exec { .. } => chip("Terminal", crate::icons::TERMINAL),
        ToolCall::ReadFile { .. }
        | ToolCall::WriteFile { .. }
        | ToolCall::EditFile { .. }
        | ToolCall::ApplyPatch { .. } => chip("Files", crate::icons::DOCUMENT),
        ToolCall::Search { .. } | ToolCall::Glob { .. } => chip("Search", crate::icons::MAGNIFER),
        ToolCall::WebFetch { .. } | ToolCall::WebSearch { .. } => chip("Web", crate::icons::GLOBAL),
        ToolCall::Mcp { server, .. } => {
            let icon = if server.to_ascii_lowercase().contains("git") {
                crate::icons::GIT_BRANCH
            } else {
                crate::icons::WIDGET
            };
            Some(ToolChip {
                label: first_line(server, 24),
                icon,
            })
        }
        ToolCall::Unknown { .. } => None,
    }
}

fn agent_state(status: SubagentStatus) -> AgentState {
    match status {
        SubagentStatus::Running => AgentState::Running,
        SubagentStatus::Done => AgentState::Done,
        SubagentStatus::Failed | SubagentStatus::Disconnected => AgentState::Failed,
        SubagentStatus::Cancelled => AgentState::Stopped,
    }
}

/// What the components show for `transcript`. Pure: tests and fixtures call
/// it with synthetic entries.
pub fn work(transcript: &[SessionMessageEntry]) -> Work {
    let scope_start = transcript
        .iter()
        .rposition(|e| e.role == MessageRole::User)
        .map_or(0, |i| i + 1);
    let scope = &transcript[scope_start..];
    let live = scope
        .iter()
        .any(|e| e.status == Some(MessageStatus::Streaming));

    // Todo snapshots in order, with the message time they arrived at, and
    // the tool calls after the latest one.
    let mut snapshots: Vec<(usize, i64, &[harness_proto::TodoItem])> = Vec::new();
    let mut since_todo: Vec<(&str, &ToolCall, bool)> = Vec::new();
    let mut asks: Option<String> = None;
    let mut tools: Vec<ToolChip> = Vec::new();
    let mut agents: Vec<AgentRow> = Vec::new();
    for (entry_index, entry) in scope.iter().enumerate() {
        for part in &entry.parts {
            match part {
                MessagePart::Tool {
                    call: ToolCall::Todo { items },
                    ..
                } if !items.is_empty() => {
                    snapshots.push((entry_index, entry.created_at, items));
                    since_todo.clear();
                }
                MessagePart::Tool {
                    id, call, resolved, ..
                } => {
                    since_todo.push((id, call, *resolved));
                    if let Some(chip) = tool_chip(call)
                        && !tools.contains(&chip)
                    {
                        tools.push(chip);
                    }
                }
                MessagePart::Input {
                    questions,
                    resolved: false,
                    ..
                } => {
                    asks = questions.first().map(|q| {
                        let header = q.header.trim();
                        first_line(
                            if header.is_empty() {
                                &q.question
                            } else {
                                header
                            },
                            TITLE_MAX,
                        )
                    });
                }
                _ => {}
            }
        }
    }

    // Subagents: every running one in the chat, and the ones this turn
    // started that have since ended.
    for (entry_index, entry) in transcript.iter().enumerate() {
        for part in &entry.parts {
            let MessagePart::Tool {
                id,
                call,
                subagent_status: Some(status),
                subagent_tail,
                ..
            } = part
            else {
                continue;
            };
            if !call.is_subagent_spawn() {
                continue;
            }
            let state = agent_state(*status);
            if state != AgentState::Running && entry_index < scope_start {
                continue;
            }
            let detail = match state {
                AgentState::Running => subagent_tail
                    .as_deref()
                    .map(|t| first_line(t, TITLE_MAX))
                    .filter(|t| !t.is_empty())
                    .unwrap_or_else(|| "Working".to_owned()),
                AgentState::Done => "Ready to review".to_owned(),
                AgentState::Failed => "Failed".to_owned(),
                AgentState::Stopped => "Stopped".to_owned(),
            };
            agents.push(AgentRow {
                id: id.clone(),
                title: crate::transcript::subagent_tab_title(call)
                    .map_or_else(|| "Subagent".to_owned(), |t| t.to_string()),
                state,
                detail,
            });
        }
    }

    let mut steps = Vec::new();
    if let Some((_, _, items)) = snapshots.last() {
        let active = live.then(|| items.iter().position(|i| !i.done)).flatten();
        for (index, item) in items.iter().enumerate() {
            let state = if item.done {
                StepState::Done
            } else if Some(index) == active {
                StepState::Active
            } else {
                StepState::Pending
            };
            let substeps = if state == StepState::Active {
                let mut subs: Vec<Substep> = since_todo
                    .iter()
                    .filter_map(|(id, call, resolved)| {
                        substep_title(call, *resolved).map(|title| Substep {
                            id: (*id).to_owned(),
                            title,
                            state: if *resolved {
                                SubState::Done
                            } else {
                                SubState::Active
                            },
                        })
                    })
                    .collect();
                let skip = subs.len().saturating_sub(MAX_SUBSTEPS);
                subs.drain(..skip);
                subs
            } else {
                Vec::new()
            };
            let status = (state == StepState::Active).then(|| {
                if asks.is_some() {
                    "Waiting"
                } else {
                    status_word(
                        since_todo
                            .iter()
                            .rev()
                            .find(|(_, _, resolved)| !resolved)
                            .map(|(_, call, _)| *call),
                    )
                }
            });
            steps.push(Step {
                title: first_line(&item.text, TITLE_MAX),
                state,
                duration_ms: step_duration(&snapshots, index),
                status,
                substeps,
            });
        }
        if let Some(title) = asks {
            steps.push(Step {
                title,
                state: StepState::AsksFirst,
                duration_ms: None,
                status: None,
                substeps: Vec::new(),
            });
        }
    }

    Work {
        steps,
        agents,
        tools,
        live,
    }
}

/// How long item `index` of the latest list took: from the snapshot where it
/// became the first open item to the one where it was first seen done. Only
/// counted across different messages, since one message has one timestamp.
pub fn step_duration(
    snapshots: &[(usize, i64, &[harness_proto::TodoItem])],
    index: usize,
) -> Option<i64> {
    let (_, _, latest) = snapshots.last()?;
    let text = &latest.get(index)?.text;
    let done_at = snapshots
        .iter()
        .position(|(_, _, items)| items.iter().any(|i| &i.text == text && i.done))?;
    let started_at = snapshots[..done_at].iter().position(|(_, _, items)| {
        items
            .iter()
            .find(|i| !i.done)
            .is_some_and(|i| &i.text == text)
    })?;
    let (start_entry, start_ms, _) = snapshots[started_at];
    let (end_entry, end_ms, _) = snapshots[done_at];
    (end_entry != start_entry && end_ms > start_ms).then_some(end_ms - start_ms)
}

/// 12s, 1m 5s, 2h 3m.
pub fn duration_label(ms: i64) -> String {
    let secs = (ms.max(0) + 500) / 1000;
    match secs {
        0..60 => format!("{secs}s"),
        60..3600 => match secs % 60 {
            0 => format!("{}m", secs / 60),
            s => format!("{}m {s}s", secs / 60),
        },
        _ => format!("{}h {}m", secs / 3600, (secs % 3600) / 60),
    }
}

/// The agents card header: "3 agents" plus "running" or "done".
pub fn agents_header(work: &Work) -> (String, &'static str) {
    let count = work.agents.len();
    let running = work.running_agents();
    let noun = if count == 1 { "agent" } else { "agents" };
    if running > 0 {
        (
            format!(
                "{running} {}",
                if running == 1 { "agent" } else { "agents" }
            ),
            "running",
        )
    } else {
        (format!("{count} {noun}"), "done")
    }
}

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

/// Colors for the components. Accents are fixed; surfaces follow the theme,
/// with the near-black card of the reference design in dark mode.
#[derive(Debug, Clone, Copy)]
pub struct Palette {
    pub card: Hsla,
    pub card_border: Hsla,
    pub text: Hsla,
    pub muted: Hsla,
    pub faint: Hsla,
    pub line: Hsla,
    pub pink: Hsla,
    pub blue: Hsla,
    pub blue_text: Hsla,
    pub amber_text: Hsla,
    pub amber_bg: Hsla,
    pub red_text: Hsla,
    pub red_bg: Hsla,
    pub blue_bg: Hsla,
    pub chip_bg: Hsla,
    pub chip_border: Hsla,
    pub on_pink: Hsla,
}

fn hex(value: u32) -> Hsla {
    gpui::rgb(value).into()
}

impl Palette {
    pub fn new(theme: &Theme) -> Self {
        if theme.appearance.is_dark() {
            Self {
                card: hex(0x18181B),
                card_border: hex(0x27272A),
                text: hex(0xF4F4F5),
                muted: hex(0xA1A1AA),
                faint: hex(0x71717A),
                line: hex(0x3F3F46),
                pink: hex(0xEC4899),
                blue: hex(0x3B82F6),
                blue_text: hex(0x60A5FA),
                amber_text: hex(0xF5B547),
                amber_bg: hex(0x3B2C12),
                red_text: hex(0xF87171),
                red_bg: hex(0x4A1D20),
                blue_bg: hex(0x1E3A5F),
                chip_bg: hex(0x27272A),
                chip_border: hex(0x3F3F46),
                on_pink: hex(0xFFFFFF),
            }
        } else {
            Self {
                card: theme.surface_dialog,
                card_border: theme.border,
                text: theme.text,
                muted: theme.text_muted,
                faint: theme.text_faint,
                line: theme.text_faint.opacity(0.45),
                pink: hex(0xEC4899),
                blue: hex(0x3B82F6),
                blue_text: hex(0x2563EB),
                amber_text: hex(0xB45309),
                amber_bg: hex(0xFEF3C7),
                red_text: hex(0xB91C1C),
                red_bg: hex(0xFEE2E2),
                blue_bg: hex(0xDBEAFE),
                chip_bg: theme.surface_raised,
                chip_border: theme.border,
                on_pink: hex(0xFFFFFF),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Glyphs
// ---------------------------------------------------------------------------

/// Spinner phase in `[0, 1)` on the shared clock; 0 under reduced motion.
pub fn spin_phase(view: EntityId, cx: &mut App) -> f32 {
    crate::motion::pulse_delta(&SPIN, view, cx)
}

/// The arc a spinner draws at `phase`: start and sweep in turns, clockwise
/// from 12 o'clock.
pub fn spinner_arc(phase: f32) -> (f32, f32) {
    (phase.rem_euclid(1.0), 1.0 - SPINNER_GAP)
}

fn arc_path(
    center: gpui::Point<gpui::Pixels>,
    radius: f32,
    start: f32,
    sweep: f32,
    stroke: f32,
    dash: Option<&[gpui::Pixels]>,
) -> Option<gpui::Path<gpui::Pixels>> {
    let steps = (48.0 * sweep).ceil().max(2.0) as usize;
    let mut path = PathBuilder::stroke(px(stroke));
    if let Some(dash) = dash {
        path = path.dash_array(dash);
    }
    for i in 0..=steps {
        let angle = -std::f32::consts::FRAC_PI_2
            + std::f32::consts::TAU * (start + sweep * i as f32 / steps as f32);
        let p = point(
            center.x + px(radius * angle.cos()),
            center.y + px(radius * angle.sin()),
        );
        if i == 0 {
            path.move_to(p);
        } else {
            path.line_to(p);
        }
    }
    path.build().ok()
}

/// A ring spinner: a faint track and a rotating arc with a gap.
pub fn spinner(diameter: f32, stroke: f32, color: Hsla, track: Hsla, phase: f32) -> AnyElement {
    let (start, sweep) = spinner_arc(phase);
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let radius = (diameter - stroke) / 2.0;
            if let Some(path) = arc_path(bounds.center(), radius, 0.0, 1.0, stroke, None) {
                window.paint_path(path, track);
            }
            if let Some(path) = arc_path(bounds.center(), radius, start, sweep, stroke, None) {
                window.paint_path(path, color);
            }
        },
    )
    .flex_none()
    .size(px(diameter))
    .into_any_element()
}

fn dashed_ring(diameter: f32, stroke: f32, color: Hsla) -> AnyElement {
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let radius = (diameter - stroke) / 2.0;
            let dash = [px(2.0), px(2.2)];
            if let Some(path) = arc_path(bounds.center(), radius, 0.0, 1.0, stroke, Some(&dash)) {
                window.paint_path(path, color);
            }
        },
    )
    .flex_none()
    .size(px(diameter))
    .into_any_element()
}

fn check_dot(diameter: f32, p: &Palette) -> AnyElement {
    div()
        .flex_none()
        .size(px(diameter))
        .rounded_full()
        .bg(p.pink)
        .flex()
        .items_center()
        .justify_center()
        .child(
            crate::icons::icon(crate::icons::CHECK)
                .size(px(diameter * 0.62))
                .text_color(p.on_pink),
        )
        .into_any_element()
}

fn hollow(diameter: f32, color: Hsla) -> AnyElement {
    div()
        .flex_none()
        .size(px(diameter))
        .rounded_full()
        .border(px(1.5))
        .border_color(color)
        .into_any_element()
}

fn lock_dot(diameter: f32, p: &Palette) -> AnyElement {
    div()
        .flex_none()
        .size(px(diameter))
        .rounded_full()
        .border(px(1.5))
        .border_color(p.blue)
        .flex()
        .items_center()
        .justify_center()
        .child(
            crate::icons::icon(crate::icons::LOCK)
                .size(px(diameter * 0.5))
                .text_color(p.blue),
        )
        .into_any_element()
}

/// The active step: a pink spinner around a pink dot.
fn active_dot(diameter: f32, p: &Palette, phase: f32) -> AnyElement {
    div()
        .flex_none()
        .relative()
        .size(px(diameter))
        .flex()
        .items_center()
        .justify_center()
        .child(
            div()
                .absolute()
                .inset_0()
                .child(spinner(diameter, 2.0, p.pink, p.line, phase)),
        )
        .child(div().size(px(diameter * 0.34)).rounded_full().bg(p.pink))
        .into_any_element()
}

/// A step's state glyph at `diameter`.
pub fn step_glyph(state: StepState, diameter: f32, p: &Palette, phase: f32) -> AnyElement {
    match state {
        StepState::Done => check_dot(diameter, p),
        StepState::Active => active_dot(diameter, p, phase),
        StepState::Pending => hollow(diameter, p.line),
        StepState::AsksFirst => lock_dot(diameter, p),
    }
}

/// A pill: "Asks first", "Agent", "Trigger".
pub fn tag(label: impl Into<SharedString>, text: Hsla, bg: Hsla) -> AnyElement {
    div()
        .flex_none()
        .px(px(9.0))
        .py(px(2.0))
        .rounded_full()
        .bg(bg)
        .text_size(px(TEXT_BODY))
        .text_color(text)
        .child(label.into())
        .into_any_element()
}

pub fn asks_first_tag(p: &Palette) -> AnyElement {
    tag("Asks first", p.amber_text, p.amber_bg)
}

fn enter(id: ElementId, element: gpui::Div) -> AnyElement {
    element
        .with_animation(id, ENTER.animation(), |el, t| {
            el.relative().opacity(t).top(px(3.0 * (1.0 - t)))
        })
        .into_any_element()
}

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Row {
    Step(usize),
    Sub,
}

fn connectors(steps: &[Step], p: Palette) -> AnyElement {
    let mut rows = Vec::new();
    for (i, step) in steps.iter().enumerate() {
        rows.push(Row::Step(i));
        rows.extend(step.substeps.iter().map(|_| Row::Sub));
    }
    let mut y = 0.0;
    let centers: Vec<(Row, f32)> = rows
        .iter()
        .map(|row| {
            let h = match row {
                Row::Step(_) => STEP_ROW,
                Row::Sub => SUB_ROW,
            };
            let c = y + h / 2.0;
            y += h;
            (*row, c)
        })
        .collect();
    let states: Vec<StepState> = steps.iter().map(|s| s.state).collect();
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let o = bounds.origin;
            let at = |x: f32, y: f32| point(o.x + px(x), o.y + px(y));
            let r = ICON / 2.0 + 2.0;
            let dash = [px(3.0), px(3.0)];
            let mut stroke =
                |from: gpui::Point<gpui::Pixels>,
                 to: gpui::Point<gpui::Pixels>,
                 ctrl: Option<(gpui::Point<gpui::Pixels>, gpui::Point<gpui::Pixels>)>,
                 color: Hsla,
                 dashed: bool| {
                    let mut path = PathBuilder::stroke(px(1.5));
                    if dashed {
                        path = path.dash_array(&dash);
                    }
                    path.move_to(from);
                    match ctrl {
                        Some((a, b)) => path.cubic_bezier_to(to, a, b),
                        None => path.line_to(to),
                    }
                    if let Ok(path) = path.build() {
                        window.paint_path(path, color);
                    }
                };
            for pair in centers.windows(2) {
                let ((a, ay), (b, by)) = (pair[0], pair[1]);
                match (a, b) {
                    (Row::Step(i), Row::Step(_)) => {
                        let pink = states[i] == StepState::Done;
                        stroke(
                            at(ICON / 2.0, ay + r),
                            at(ICON / 2.0, by - r),
                            None,
                            if pink { p.pink } else { p.line },
                            !pink,
                        );
                    }
                    (Row::Step(_), Row::Sub) => {
                        let (from, to) = (at(ICON / 2.0, ay + r), at(SUB_X, by - 4.0));
                        let mid = (ay + r + by - 4.0) / 2.0;
                        stroke(
                            from,
                            to,
                            Some((at(ICON / 2.0, mid), at(SUB_X, mid))),
                            p.line,
                            false,
                        );
                    }
                    (Row::Sub, Row::Sub) => stroke(
                        at(SUB_X, ay + 4.0),
                        at(SUB_X, by - 4.0),
                        None,
                        p.line,
                        false,
                    ),
                    (Row::Sub, Row::Step(_)) => {
                        let (from, to) = (at(SUB_X, ay + 4.0), at(ICON / 2.0, by - r));
                        let mid = (ay + 4.0 + by - r) / 2.0;
                        stroke(
                            from,
                            to,
                            Some((at(SUB_X, mid), at(ICON / 2.0, mid))),
                            p.line,
                            true,
                        );
                    }
                }
            }
        },
    )
    .absolute()
    .top_0()
    .left_0()
    .w(px(TEXT_X))
    .h(px(y))
    .into_any_element()
}

/// The step timeline: steps with their state, the active step's substeps
/// on a branch, and a gated last step.
pub fn timeline(steps: &[Step], p: &Palette, phase: f32) -> AnyElement {
    let mut rows: Vec<AnyElement> = Vec::new();
    for (i, step) in steps.iter().enumerate() {
        let title_color = match step.state {
            StepState::Done => p.muted,
            StepState::Active | StepState::AsksFirst => p.text,
            StepState::Pending => p.faint,
        };
        let trail: Option<AnyElement> = match step.state {
            StepState::Done => step.duration_ms.map(|ms| {
                div()
                    .text_color(p.faint)
                    .tabular_nums()
                    .relative()
                    .top(px(-CAP_CENTER_NUDGE))
                    .child(SharedString::from(duration_label(ms)))
                    .into_any_element()
            }),
            StepState::Active => step.status.map(|word| {
                div()
                    .text_color(p.blue_text)
                    .relative()
                    .top(px(-CAP_CENTER_NUDGE))
                    .child(SharedString::from(word))
                    .into_any_element()
            }),
            StepState::AsksFirst => Some(asks_first_tag(p)),
            StepState::Pending => None,
        };
        let row = div()
            .h(px(STEP_ROW))
            .flex()
            .items_center()
            .child(
                div()
                    .w(px(TEXT_X))
                    .flex_none()
                    .child(step_glyph(step.state, ICON, p, phase)),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_size(px(TEXT_TITLE))
                    .text_color(title_color)
                    // The glyph and its connectors stay on the row's center;
                    // the title rises to put its letters there.
                    .relative()
                    .top(px(-CAP_CENTER_NUDGE))
                    .child(SharedString::from(step.title.clone())),
            )
            .children(trail.map(|t| {
                div()
                    .flex_none()
                    .pl(px(10.0))
                    .text_size(px(TEXT_BODY))
                    .child(t)
            }));
        rows.push(enter(
            ElementId::Name(format!("agent-step-{i}-{:?}", step.state).into()),
            row,
        ));
        for sub in &step.substeps {
            let glyph = match sub.state {
                SubState::Done => div()
                    .size(px(5.0))
                    .rounded_full()
                    .bg(p.faint)
                    .into_any_element(),
                SubState::Active => spinner(10.0, 1.5, p.pink, p.line, phase),
            };
            let row = div()
                .h(px(SUB_ROW))
                .flex()
                .items_center()
                .child(
                    div().w(px(TEXT_X)).flex_none().flex().child(
                        div()
                            .ml(px(SUB_X - 5.0))
                            .w(px(10.0))
                            .flex()
                            .justify_center()
                            .child(glyph),
                    ),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_size(px(TEXT_BODY))
                        .text_color(p.muted)
                        .relative()
                        .top(px(-CAP_CENTER_NUDGE))
                        .child(SharedString::from(sub.title.clone())),
                );
            rows.push(enter(
                ElementId::Name(format!("agent-sub-{}-{:?}", sub.id, sub.state).into()),
                row,
            ));
        }
    }
    div()
        .relative()
        .flex()
        .flex_col()
        .child(connectors(steps, *p))
        .children(rows)
        .into_any_element()
}

/// A row of step dots joined by connectors: pink between done steps, dashed
/// gray from the active one on.
pub fn step_dots(
    states: &[StepState],
    diameter: f32,
    link: f32,
    p: &Palette,
    phase: f32,
) -> AnyElement {
    let mut row = div().flex().items_center();
    for (i, state) in states.iter().enumerate() {
        if i > 0 {
            let pink = states[i - 1] == StepState::Done;
            let color = if pink { p.pink } else { p.line };
            let line = canvas(
                |_, _, _| (),
                move |bounds, _, window, _| {
                    let y = bounds.center().y;
                    let mut path = PathBuilder::stroke(px(1.5));
                    if !pink {
                        path = path.dash_array(&[px(3.0), px(3.0)]);
                    }
                    path.move_to(point(bounds.origin.x, y));
                    path.line_to(point(bounds.origin.x + bounds.size.width, y));
                    if let Ok(path) = path.build() {
                        window.paint_path(path, color);
                    }
                },
            )
            .flex_none()
            .w(px(link))
            .h(px(diameter));
            row = row.child(line);
        }
        row = row.child(step_glyph(*state, diameter, p, phase));
    }
    row.into_any_element()
}

/// The status legend: Running, Done, Waiting.
pub fn legend(p: &Palette, phase: f32) -> AnyElement {
    let item = |glyph: AnyElement, label: &'static str, color: Hsla| {
        div().flex().items_center().gap(px(6.0)).child(glyph).child(
            div()
                .text_size(px(TEXT_BODY))
                .text_color(color)
                .child(label),
        )
    };
    div()
        .flex()
        .items_center()
        .gap(px(16.0))
        .child(item(
            spinner(12.0, 1.5, p.blue, p.line, phase),
            "Running",
            p.blue_text,
        ))
        .child(item(check_dot(12.0, p), "Done", p.text))
        .child(item(dashed_ring(12.0, 1.2, p.faint), "Waiting", p.faint))
        .into_any_element()
}

/// Tool chips with their icons.
pub fn tool_chips(tools: &[ToolChip], p: &Palette) -> AnyElement {
    div()
        .flex()
        .flex_wrap()
        .gap(px(6.0))
        .children(tools.iter().map(|tool| {
            div()
                .flex()
                .items_center()
                .gap(px(6.0))
                .px(px(8.0))
                .py(px(3.0))
                .rounded(px(CHIP_RADIUS))
                .bg(p.chip_bg)
                .border(px(1.0))
                .border_color(p.chip_border)
                .text_size(px(TEXT_BODY))
                .text_color(p.text)
                .child(
                    crate::icons::icon(tool.icon)
                        .size(px(14.0))
                        .text_color(p.muted)
                        .relative()
                        .top(px(CAP_CENTER_NUDGE)),
                )
                .child(SharedString::from(tool.label.clone()))
        }))
        .into_any_element()
}

/// The agents card body: a header and one row per subagent. No Stop or
/// Review buttons: the card is a tooltip, which takes no clicks, and the
/// spawn chip in the transcript already opens a subagent.
pub fn agents(work: &Work, p: &Palette, phase: f32) -> AnyElement {
    let (count, word) = agents_header(work);
    let header = div()
        .flex()
        .items_center()
        .gap(px(5.0))
        .text_size(px(TEXT_TITLE))
        .tabular_nums()
        .child(div().text_color(p.text).child(SharedString::from(count)))
        .child(div().text_color(p.muted).child(word));
    let rows = work.agents.iter().map(|agent| {
        let glyph = match agent.state {
            AgentState::Running => spinner(18.0, 2.0, p.pink, p.line, phase),
            AgentState::Done => check_dot(18.0, p),
            AgentState::Failed | AgentState::Stopped => hollow(18.0, p.faint),
        };
        let detail_color = match agent.state {
            AgentState::Done => p.pink,
            AgentState::Failed => p.red_text,
            _ => p.muted,
        };
        div()
            .flex()
            .items_start()
            .gap(px(12.0))
            // Centers the glyph on the title's letters (optical, measured).
            .child(div().pt(px(AGENT_GLYPH_TOP)).child(glyph))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_size(px(TEXT_TITLE))
                            .text_color(p.text)
                            .child(SharedString::from(agent.title.clone())),
                    )
                    .child(
                        div()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_size(px(TEXT_BODY))
                            .text_color(detail_color)
                            .child(SharedString::from(agent.detail.clone())),
                    ),
            )
            .into_any_element()
    });
    div()
        .flex()
        .flex_col()
        .gap(px(14.0))
        .child(header)
        .children(rows)
        .into_any_element()
}

/// A dark card around a component.
pub fn card(p: &Palette) -> gpui::Div {
    div()
        .w(px(CARD_W))
        .p(px(CARD_PAD))
        .rounded(px(CARD_RADIUS))
        .bg(p.card)
        .border(px(1.0))
        .border_color(p.card_border)
        .flex()
        .flex_col()
        .gap(px(14.0))
}

/// The whole hover card: timeline, agents and tools, whichever exist.
pub fn work_card(work: &Work, p: &Palette, phase: f32) -> AnyElement {
    card(p)
        .when(!work.steps.is_empty(), |c| {
            c.child(timeline(&work.steps, p, phase))
        })
        .when(!work.agents.is_empty(), |c| {
            c.when(!work.steps.is_empty(), |c| {
                c.child(div().h(px(1.0)).bg(p.card_border))
            })
            .child(agents(work, p, phase))
        })
        .when(!work.tools.is_empty(), |c| {
            c.child(tool_chips(&work.tools, p))
        })
        .into_any_element()
}

// ---------------------------------------------------------------------------
// The composer footer chip and its hover card
// ---------------------------------------------------------------------------

/// The footer chip's states, from steps: dots up to [`MAX_FOOTER_DOTS`],
/// otherwise a "done/total" count.
pub fn footer_dots(work: &Work) -> Option<Vec<StepState>> {
    let states: Vec<StepState> = work.steps.iter().map(|s| s.state).collect();
    (!states.is_empty() && states.len() <= MAX_FOOTER_DOTS).then_some(states)
}

/// The chip next to the context ring while the chat has steps or agents.
pub fn footer_chip(
    state: Entity<AppState>,
    theme: &Theme,
    view: EntityId,
    cx: &mut App,
) -> Option<AnyElement> {
    let work = work(&state.read(cx).transcript);
    if work.is_empty() {
        return None;
    }
    let p = Palette::new(theme);
    let animates = work.live || work.running_agents() > 0;
    let phase = if animates { spin_phase(view, cx) } else { 0.0 };
    let body: AnyElement = match footer_dots(&work) {
        Some(states) => step_dots(&states, 12.0, 6.0, &p, phase),
        None if !work.steps.is_empty() => {
            let done = work
                .steps
                .iter()
                .filter(|s| s.state == StepState::Done)
                .count();
            div()
                .flex()
                .items_center()
                .gap(px(5.0))
                .child(if work.live {
                    spinner(12.0, 1.5, p.pink, p.line, phase)
                } else {
                    check_dot(12.0, &p)
                })
                .child(
                    div()
                        .tabular_nums()
                        .child(SharedString::from(format!("{done}/{}", work.steps.len()))),
                )
                .into_any_element()
        }
        None => {
            let (count, _) = agents_header(&work);
            div()
                .flex()
                .items_center()
                .gap(px(5.0))
                .child(if work.running_agents() > 0 {
                    spinner(12.0, 1.5, p.pink, p.line, phase)
                } else {
                    check_dot(12.0, &p)
                })
                .child(div().tabular_nums().child(SharedString::from(count)))
                .into_any_element()
        }
    };
    let pill = div()
        .flex()
        .items_center()
        .h(px(24.0))
        .px(px(6.0))
        .rounded(px(Theme::CONTROL_RADIUS))
        .text_size(px(TEXT_BODY))
        .text_color(theme.text_muted)
        .group_hover("agent-work", |s| s.bg(crate::theme::ink(0.05)))
        .child(body);
    Some(
        hit_area("agent-work", "agent-work", HitSlop::AGENT_WORK, pill)
            .tooltip(move |_, cx| hover_card(state.clone(), cx))
            .into_any_element(),
    )
}

/// The card the footer chip opens on hover.
pub fn hover_card(state: Entity<AppState>, cx: &mut App) -> gpui::AnyView {
    cx.new(|cx| AgentWorkCard::new(state, cx)).into()
}

/// The hover card's live view.
pub struct AgentWorkCard {
    state: Entity<AppState>,
    built_from: Option<u64>,
    work: Work,
    _subscription: Subscription,
}

impl AgentWorkCard {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        Self {
            _subscription: cx.observe(&state, |_, _, cx| cx.notify()),
            state,
            built_from: None,
            work: Work::default(),
        }
    }
}

impl Render for AgentWorkCard {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let revision = self.state.read(cx).transcript_revision;
        if self.built_from != Some(revision) {
            self.built_from = Some(revision);
            self.work = work(&self.state.read(cx).transcript);
        }
        let theme = Theme::of(cx).clone();
        let p = Palette::new(&theme);
        let animates = self.work.live || self.work.running_agents() > 0;
        let phase = if animates {
            spin_phase(cx.entity_id(), cx)
        } else {
            0.0
        };
        work_card(&self.work, &p, phase)
    }
}

/// How long an enter transition runs; reduced motion snaps it (gpui).
pub fn enter_len() -> Duration {
    ENTER.total()
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_proto::TodoItem;
    use serde_json::json;

    fn entry(
        id: &str,
        role: &str,
        at: i64,
        status: &str,
        parts: serde_json::Value,
    ) -> SessionMessageEntry {
        serde_json::from_value(json!({
            "id": id, "role": role, "createdAt": at, "deviceId": "d",
            "status": status, "parts": parts,
        }))
        .unwrap()
    }

    fn todo(id: &str, items: &[(&str, bool)]) -> serde_json::Value {
        json!({"id": id, "kind": "tool", "resolved": true, "call": {
            "kind": "todo",
            "items": items.iter().map(|(t, d)| json!({"text": t, "done": d})).collect::<Vec<_>>()
        }})
    }

    fn tool(id: &str, call: serde_json::Value, resolved: bool) -> serde_json::Value {
        json!({"id": id, "kind": "tool", "resolved": resolved, "call": call})
    }

    fn ask() -> SessionMessageEntry {
        entry(
            "u",
            "user",
            0,
            "complete",
            json!([{"id": "t", "kind": "text", "text": "go"}]),
        )
    }

    #[test]
    fn no_todo_list_means_no_steps() {
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                1,
                "streaming",
                json!([tool("r", json!({"kind": "readFile", "path": "a.rs"}), true)]),
            ),
        ];
        let w = work(&t);
        assert!(w.steps.is_empty());
        assert!(w.agents.is_empty());
        assert!(w.is_empty());
        assert_eq!(
            w.tools,
            vec![ToolChip {
                label: "Files".into(),
                icon: crate::icons::DOCUMENT
            }]
        );
    }

    #[test]
    fn latest_todo_list_sets_steps_and_active_substeps() {
        let t = vec![
            ask(),
            entry(
                "a1",
                "assistant",
                1_000,
                "complete",
                json!([todo(
                    "t1",
                    &[("Collect", false), ("Draft", false), ("Check", false)]
                ),]),
            ),
            entry(
                "a2",
                "assistant",
                13_000,
                "complete",
                json!([
                    todo(
                        "t2",
                        &[("Collect", true), ("Draft", false), ("Check", false)]
                    ),
                    tool("old", json!({"kind": "exec", "command": "ls"}), true),
                ]),
            ),
            entry(
                "a3",
                "assistant",
                14_000,
                "streaming",
                json!([
                    todo(
                        "t3",
                        &[("Collect", true), ("Draft", false), ("Check", false)]
                    ),
                    tool(
                        "w1",
                        json!({"kind": "webFetch", "url": "https://example.invalid/fees"}),
                        true
                    ),
                    tool(
                        "w2",
                        json!({"kind": "writeFile", "path": "docs/overview.md"}),
                        true
                    ),
                    tool(
                        "w3",
                        json!({"kind": "editFile", "path": "docs/validators.md"}),
                        false
                    ),
                ]),
            ),
        ];
        let w = work(&t);
        assert!(w.live);
        let states: Vec<_> = w.steps.iter().map(|s| s.state).collect();
        assert_eq!(
            states,
            vec![StepState::Done, StepState::Active, StepState::Pending]
        );
        assert_eq!(w.steps[0].duration_ms, Some(12_000));
        assert_eq!(w.steps[1].status, Some("Writing"));
        let subs: Vec<_> = w.steps[1]
            .substeps
            .iter()
            .map(|s| (s.title.as_str(), s.state))
            .collect();
        assert_eq!(
            subs,
            vec![
                ("Fetched example.invalid", SubState::Done),
                ("Wrote overview.md", SubState::Done),
                ("Editing validators.md", SubState::Active),
            ]
        );
        assert!(w.steps[0].substeps.is_empty() && w.steps[2].substeps.is_empty());
    }

    #[test]
    fn durations_need_two_messages() {
        // Opened and closed inside one streamed message: one timestamp, so
        // no duration rather than a made-up one.
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                5_000,
                "streaming",
                json!([
                    todo("t1", &[("Only", false), ("Next", false)]),
                    todo("t2", &[("Only", true), ("Next", false)]),
                ]),
            ),
        ];
        let w = work(&t);
        assert_eq!(w.steps[0].state, StepState::Done);
        assert_eq!(w.steps[0].duration_ms, None);
    }

    #[test]
    fn finished_turn_has_no_active_step() {
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                1,
                "complete",
                json!([todo("t1", &[("One", true), ("Two", false)]),]),
            ),
        ];
        let states: Vec<_> = work(&t).steps.iter().map(|s| s.state).collect();
        assert_eq!(states, vec![StepState::Done, StepState::Pending]);
    }

    #[test]
    fn a_new_user_message_starts_a_new_turn() {
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                1,
                "complete",
                json!([todo("t1", &[("Old", false)])]),
            ),
            ask(),
        ];
        assert!(work(&t).steps.is_empty());
    }

    #[test]
    fn pending_question_is_the_gated_step() {
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                1,
                "streaming",
                json!([
                    todo("t1", &[("Draft", true), ("Send", false)]),
                    {"id": "q", "kind": "input", "requestId": "r", "resolved": false, "questions": [
                        {"id": "q1", "header": "Send to team", "question": "Send it?", "options": ["Yes", "No"]}
                    ]},
                ]),
            ),
        ];
        let w = work(&t);
        let last = w.steps.last().unwrap();
        assert_eq!(last.state, StepState::AsksFirst);
        assert_eq!(last.title, "Send to team");
        assert_eq!(w.steps[1].status, Some("Waiting"));
    }

    #[test]
    fn answered_question_is_not_gated() {
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                1,
                "streaming",
                json!([
                    todo("t1", &[("Draft", false)]),
                    {"id": "q", "kind": "input", "requestId": "r", "resolved": true, "questions": [
                        {"id": "q1", "header": "Send", "question": "Send it?", "options": []}
                    ]},
                ]),
            ),
        ];
        assert!(
            work(&t)
                .steps
                .iter()
                .all(|s| s.state != StepState::AsksFirst)
        );
    }

    #[test]
    fn subagents_show_running_and_this_turns_finished() {
        let spawn = |id: &str, name: &str, status: &str, tail: Option<&str>| {
            let mut v = tool(id, json!({"kind": "unknown", "name": name}), true);
            v["subagentStatus"] = json!(status);
            if let Some(tail) = tail {
                v["subagentTail"] = json!(tail);
            }
            v
        };
        let t = vec![
            ask(),
            entry(
                "a0",
                "assistant",
                1,
                "complete",
                json!([
                    spawn("s0", "Agent: Earlier done", "done", None),
                    spawn(
                        "s1",
                        "Agent: Long audit",
                        "running",
                        Some("Reading contracts\nmore")
                    ),
                ]),
            ),
            ask(),
            entry(
                "a1",
                "assistant",
                2,
                "streaming",
                json!([
                    spawn("s2", "Agent: Refactor fee module", "running", None),
                    spawn("s3", "Agent: Summarize PRs", "done", None),
                    spawn("s4", "Agent: Broken", "failed", None),
                ]),
            ),
        ];
        let w = work(&t);
        let rows: Vec<_> = w
            .agents
            .iter()
            .map(|a| (a.title.as_str(), a.state, a.detail.as_str()))
            .collect();
        assert_eq!(
            rows,
            vec![
                ("Long audit", AgentState::Running, "Reading contracts"),
                ("Refactor fee module", AgentState::Running, "Working"),
                ("Summarize PRs", AgentState::Done, "Ready to review"),
                ("Broken", AgentState::Failed, "Failed"),
            ]
        );
        assert_eq!(agents_header(&w), ("2 agents".into(), "running"));
        assert_eq!(w.tools[0].label, "Agents");
    }

    #[test]
    fn substeps_keep_the_newest_three() {
        let mut parts = vec![todo("t", &[("Work", false)])];
        for i in 0..5 {
            parts.push(tool(
                &format!("r{i}"),
                json!({"kind": "readFile", "path": format!("f{i}.rs")}),
                true,
            ));
        }
        let t = vec![ask(), entry("a", "assistant", 1, "streaming", json!(parts))];
        let titles: Vec<_> = work(&t).steps[0]
            .substeps
            .iter()
            .map(|s| s.title.clone())
            .collect();
        assert_eq!(titles, vec!["Read f2.rs", "Read f3.rs", "Read f4.rs"]);
    }

    #[test]
    fn tool_chips_dedupe_in_first_use_order() {
        let t = vec![
            ask(),
            entry(
                "a",
                "assistant",
                1,
                "complete",
                json!([
                    tool("1", json!({"kind": "exec", "command": "make"}), true),
                    tool(
                        "2",
                        json!({"kind": "mcp", "server": "github", "tool": "list_prs"}),
                        true
                    ),
                    tool("3", json!({"kind": "exec", "command": "make test"}), true),
                    tool("4", json!({"kind": "webSearch", "query": "fees"}), true),
                    tool(
                        "5",
                        json!({"kind": "unknown", "name": COMPACTION_TOOL_NAME}),
                        true
                    ),
                ]),
            ),
        ];
        let labels: Vec<_> = work(&t).tools.into_iter().map(|c| c.label).collect();
        assert_eq!(labels, vec!["Terminal", "github", "Web"]);
    }

    #[test]
    fn spinner_arc_rotates_with_a_fixed_gap() {
        assert_eq!(spinner_arc(0.0), (0.0, 0.85));
        assert_eq!(spinner_arc(1.25).0, 0.25);
        // One shared 1s linear clock: every spinner reads the same phase.
        assert_eq!(SPIN.duration_ms, 1000);
        assert_eq!(SPIN.curve.eval(0.5), 0.5);
    }

    #[test]
    fn durations_read_like_the_design() {
        assert_eq!(duration_label(12_000), "12s");
        assert_eq!(duration_label(65_000), "1m 5s");
        assert_eq!(duration_label(120_000), "2m");
        assert_eq!(duration_label(3_780_000), "1h 3m");
    }

    #[test]
    fn footer_switches_to_a_count_past_six_steps() {
        let step = |state| Step {
            title: String::new(),
            state,
            duration_ms: None,
            status: None,
            substeps: vec![],
        };
        let mut w = Work {
            steps: vec![step(StepState::Done); 6],
            ..Default::default()
        };
        assert_eq!(footer_dots(&w).map(|d| d.len()), Some(6));
        w.steps.push(step(StepState::Pending));
        assert_eq!(footer_dots(&w), None);
        let _ = TodoItem {
            text: String::new(),
            done: false,
        };
    }

    #[test]
    fn enter_transition_is_short() {
        assert!(enter_len() <= Duration::from_millis(250));
    }
}
