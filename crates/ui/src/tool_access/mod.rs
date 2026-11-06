//! Tool Access Map: a per-agent graph of the tools a chat can use.
//!
//! Reachable from chat as a right-pane surface (same panel chrome as Files /
//! Changes / Browser). Tabs are the chat's real agent plus any subagents it
//! spawned — never hardcoded demo personas. Tools come from every turn's real
//! [`ToolCall`] events and the agent's known families (Files, Terminal, Search,
//! Web, MCP servers).
//!
//! Click a tool for its recent calls with their INPUT / OUTPUT. Unused tools
//! sit at ~45% opacity; tools in use link to the agent with a blue Bezier.
//! Light and dark follow the active theme.
mod panel;
pub use panel::ToolAccessPanel;

use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;
use std::sync::Arc;

use gpui::{
    AnyElement, App, EntityId, Hsla, IntoElement, PathBuilder, SharedString, canvas, div, point,
    prelude::*, px,
};
use harness_doc::{MessagePart, SessionMessageEntry, SubagentStatus};
use harness_proto::{ToolCall, view::tool_chip_content};

use crate::icons;
use crate::motion::{self, CubicBezier, MotionSpec};
use crate::popover::{CARD_RADIUS, nested_radius};
use crate::theme::Theme;
use crate::transcript::{ToolDetail, ToolItem, ToolItemKind};
use crate::typography::{
    CAP_CENTER_NUDGE, TEXT_BODY, TEXT_CAPTION, TEXT_TITLE, TabularNums, WEIGHT_REGULAR,
    WEIGHT_STRONG,
};

const SPIN: MotionSpec = MotionSpec::new(1000, CubicBezier::new(0.0, 0.0, 1.0, 1.0));
fn link_color() -> Hsla { gpui::hsla(215.0 / 360.0, 0.85, 0.58, 1.0) }

/// Panel corner matches other right-pane cards.
pub const PANEL_RADIUS: f32 = CARD_RADIUS;
const NODE_RADIUS: f32 = nested_radius(PANEL_RADIUS, 1.0, 12.0);
const TAB_RADIUS: f32 = 8.0;
const TOOL_H: f32 = 52.0;
const TOOL_GAP: f32 = 10.0;
const TOOL_W: f32 = 180.0;
const GRAPH_PADDING: f32 = 16.0;
const AGENT_W: f32 = 220.0;
const AGENT_H: f32 = 96.0;
/// Both tool columns, the agent, and room for the links to read as links.
const GRAPH_MIN_WIDTH: f32 = GRAPH_PADDING * 2.0 + TOOL_W * 2.0 + AGENT_W + 80.0;
/// Calls kept per tool for the detail view. A long chat has thousands, and the
/// counts don't need them.
const HISTORY_LIMIT: usize = 100;

/// Called with the id of the tool or call a person clicked.
pub type PickCallback = Rc<dyn Fn(SharedString, &mut App)>;

/// What a tool's detail view can do. Fixtures render it without any.
#[derive(Clone)]
pub struct DetailActions {
    pub select_call: PickCallback,
    pub back: Rc<dyn Fn(&mut App)>,
}

/// One agent the map can focus: the chat's own agent, or a spawned subagent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTab {
    pub id: SharedString,
    pub name: SharedString,
    pub model: SharedString,
    pub task: SharedString,
    pub running: bool,
    pub icon: &'static str,
}

/// A tool node on the left (used) or right (available / no access).
#[derive(Debug, Clone, PartialEq)]
pub struct ToolNode {
    pub id: SharedString,
    pub name: SharedString,
    pub subtitle: SharedString,
    pub icon: &'static str,
    pub calls: usize,
    pub last_ms: Option<u64>,
    pub failed: bool,
    pub access: ToolAccessKind,
    pub side: ToolSide,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolAccessKind {
    Used,
    Available,
    NoAccess,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolSide {
    Input,
    Output,
}

/// One recorded invocation of a tool.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolCallRecord {
    pub id: SharedString,
    pub summary: SharedString,
    pub input: SharedString,
    pub output: SharedString,
    pub ok: bool,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MapState {
    pub agents: Vec<AgentTab>,
    pub selected_agent: usize,
    pub tools: Vec<ToolNode>,
    pub history: BTreeMap<String, Vec<ToolCallRecord>>,
    pub selected_tool: Option<SharedString>,
    pub selected_call: Option<SharedString>,
}

impl MapState {
    pub fn selected(&self) -> Option<&AgentTab> {
        self.agents.get(self.selected_agent)
    }

    pub fn stats_label(&self) -> String {
        let used = self
            .tools
            .iter()
            .filter(|t| t.access == ToolAccessKind::Used)
            .count();
        let total = self.tools.len();
        let calls: usize = self.tools.iter().map(|t| t.calls).sum();
        let running = self.agents.iter().filter(|a| a.running).count();
        if running > 0 {
            format!("{used}/{total} tools · {calls} calls · {running} running")
        } else {
            format!("{used}/{total} tools · {calls} calls")
        }
    }

    pub fn tool(&self, id: &str) -> Option<&ToolNode> {
        self.tools.iter().find(|t| t.id.as_ref() == id)
    }

    pub fn records(&self, tool_id: &str) -> &[ToolCallRecord] {
        self.history
            .get(tool_id)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }
}

/// Build the map from the chat's agent identity and its tool items, oldest first.
pub fn from_chat(
    agent_name: &str,
    model: &str,
    task: &str,
    agent_running: bool,
    tools: &[ToolItem],
) -> MapState {
    let mut agents = vec![AgentTab {
        id: SharedString::from("main"),
        name: SharedString::from(agent_name.to_owned()),
        model: SharedString::from(model.to_owned()),
        task: SharedString::from(task.to_owned()),
        running: agent_running,
        icon: icons::BOT,
    }];
    for tool in tools {
        if !tool.call.is_subagent_spawn() {
            continue;
        }
        let (label, detail) = tool_chip_content(&tool.call);
        let running = matches!(tool.subagent_status, Some(SubagentStatus::Running));
        agents.push(AgentTab {
            id: SharedString::from(tool.part_id.clone()),
            name: SharedString::from(if detail.is_empty() {
                label.to_owned()
            } else {
                detail
            }),
            model: SharedString::from(
                tool.call
                    .subagent_model()
                    .unwrap_or("")
                    .to_owned(),
            ),
            task: SharedString::from(label),
            running,
            icon: icons::BOT,
        });
    }

    let mut buckets: BTreeMap<&'static str, ToolBucket> = BTreeMap::new();
    for (id, name, icon, side) in KNOWN_TOOLS {
        buckets.insert(
            id,
            ToolBucket {
                name,
                icon,
                side: *side,
                calls: Vec::new(),
            },
        );
    }

    // Newest first, so the detail view opens on the latest call.
    let mut history: BTreeMap<String, Vec<ToolCallRecord>> = BTreeMap::new();
    for tool in tools.iter().rev() {
        if tool.kind != ToolItemKind::Call || tool.call.is_subagent_spawn() {
            continue;
        }
        let family = tool_family(&tool.call);
        let bucket = buckets.entry(family.id).or_insert_with(|| ToolBucket {
            name: family.name,
            icon: family.icon,
            side: family.side,
            calls: Vec::new(),
        });
        bucket.calls.push(CallMeta {
            failed: tool.is_error,
            duration_ms: None,
        });
        let records = history.entry(family.id.to_owned()).or_default();
        if records.len() < HISTORY_LIMIT {
            let (verb, detail) = tool_chip_content(&tool.call);
            records.push(ToolCallRecord {
                id: SharedString::from(tool.part_id.clone()),
                summary: SharedString::from(format!("{verb} {detail}")),
                input: SharedString::from(invocation_json(&tool.call)),
                output: SharedString::from(output_json(tool)),
                ok: !tool.is_error,
                duration_ms: None,
            });
        }
    }

    let mut tools_out = Vec::new();
    for (id, bucket) in buckets {
        let calls = bucket.calls.len();
        // Newest first. A failure the agent has since got past is a number in the
        // subtitle; only the latest call's result earns the red badge.
        let failed = bucket.calls.first().is_some_and(|c| c.failed);
        let failures = bucket.calls.iter().filter(|c| c.failed).count();
        let last_ms = bucket.calls.iter().find_map(|c| c.duration_ms);
        let access = if calls > 0 {
            ToolAccessKind::Used
        } else if matches!(id, "notion" | "slack" | "hubspot") {
            // Reserved families without a harness binding stay "no access".
            ToolAccessKind::NoAccess
        } else {
            ToolAccessKind::Available
        };
        tools_out.push(ToolNode {
            id: SharedString::from(id),
            name: SharedString::from(bucket.name),
            subtitle: SharedString::from(match access {
                ToolAccessKind::Used => {
                    let failures = (failures > 0)
                        .then(|| format!(" · {failures} failed"))
                        .unwrap_or_default();
                    if let Some(ms) = last_ms {
                        format!("{calls}×{failures} · Last call {}", format_ms(ms))
                    } else {
                        format!("{calls}×{failures}")
                    }
                }
                ToolAccessKind::Available => "Not used yet".into(),
                ToolAccessKind::NoAccess => "No access".into(),
            }),
            icon: bucket.icon,
            calls,
            last_ms,
            failed,
            access,
            side: bucket.side,
        });
    }

    // Stable visual order: inputs left, outputs right.
    tools_out.sort_by_key(|t| {
        (
            matches!(t.side, ToolSide::Output),
            matches!(t.access, ToolAccessKind::NoAccess),
            t.name.to_lowercase(),
        )
    });

    MapState {
        agents,
        selected_agent: 0,
        tools: tools_out,
        history,
        selected_tool: None,
        selected_call: None,
    }
}

struct ToolBucket {
    name: &'static str,
    icon: &'static str,
    side: ToolSide,
    calls: Vec<CallMeta>,
}

struct CallMeta {
    failed: bool,
    duration_ms: Option<u64>,
}

struct Family {
    id: &'static str,
    name: &'static str,
    icon: &'static str,
    side: ToolSide,
}

const KNOWN_TOOLS: &[(&str, &str, &str, ToolSide)] = &[
    ("files", "Files", icons::DOCUMENT, ToolSide::Input),
    ("terminal", "Terminal", icons::TERMINAL, ToolSide::Input),
    ("search", "Search", icons::MAGNIFER, ToolSide::Input),
    ("web", "Web search", icons::GLOBAL, ToolSide::Output),
    ("mcp", "MCP", icons::WIDGET, ToolSide::Input),
];

fn tool_family(call: &ToolCall) -> Family {
    match call {
        ToolCall::Exec { .. } => Family {
            id: "terminal",
            name: "Terminal",
            icon: icons::TERMINAL,
            side: ToolSide::Input,
        },
        ToolCall::ReadFile { .. }
        | ToolCall::WriteFile { .. }
        | ToolCall::EditFile { .. }
        | ToolCall::ApplyPatch { .. } => Family {
            id: "files",
            name: "Files",
            icon: icons::DOCUMENT,
            side: ToolSide::Input,
        },
        ToolCall::Search { .. } | ToolCall::Glob { .. } => Family {
            id: "search",
            name: "Search",
            icon: icons::MAGNIFER,
            side: ToolSide::Input,
        },
        ToolCall::WebFetch { .. } | ToolCall::WebSearch { .. } => Family {
            id: "web",
            name: "Web search",
            icon: icons::GLOBAL,
            side: ToolSide::Output,
        },
        ToolCall::Mcp { .. } => Family {
            id: "mcp",
            name: "MCP",
            icon: icons::WIDGET,
            side: ToolSide::Input,
        },
        ToolCall::Todo { .. } => Family {
            id: "files",
            name: "Files",
            icon: icons::CHECKLIST,
            side: ToolSide::Input,
        },
        ToolCall::Unknown { .. } => Family {
            id: "mcp",
            name: "MCP",
            icon: icons::WIDGET,
            side: ToolSide::Input,
        },
    }
}

fn invocation_json(call: &ToolCall) -> String {
    match call {
        ToolCall::Exec { command } => format!("{{\n  \"cmd\": \"{}\"\n}}", escape(command)),
        ToolCall::ReadFile { path } => format!("{{\n  \"path\": \"{}\"\n}}", escape(path)),
        ToolCall::WriteFile { path, .. } | ToolCall::EditFile { path, .. } => {
            format!("{{\n  \"path\": \"{}\"\n}}", escape(path))
        }
        ToolCall::ApplyPatch { path } => format!(
            "{{\n  \"path\": \"{}\"\n}}",
            escape(path.as_deref().unwrap_or("workspace"))
        ),
        ToolCall::Search { pattern, path } => match path {
            Some(p) => format!(
                "{{\n  \"pattern\": \"{}\",\n  \"path\": \"{}\"\n}}",
                escape(pattern),
                escape(p)
            ),
            None => format!("{{\n  \"pattern\": \"{}\"\n}}", escape(pattern)),
        },
        ToolCall::Glob { pattern } => format!("{{\n  \"pattern\": \"{}\"\n}}", escape(pattern)),
        ToolCall::WebSearch { query } => format!("{{\n  \"query\": \"{}\"\n}}", escape(query)),
        ToolCall::WebFetch { url, .. } => format!("{{\n  \"url\": \"{}\"\n}}", escape(url)),
        ToolCall::Mcp {
            server, tool, input, ..
        } => format!(
            "{{\n  \"server\": \"{}\",\n  \"tool\": \"{}\"{}\n}}",
            escape(server),
            escape(tool),
            input
                .as_ref()
                .map(|v| format!(",\n  \"input\": {v}"))
                .unwrap_or_default()
        ),
        ToolCall::Todo { items } => {
            let body = items
                .iter()
                .map(|i| format!("    {{\"text\": \"{}\", \"done\": {}}}", escape(&i.text), i.done))
                .collect::<Vec<_>>()
                .join(",\n");
            format!("{{\n  \"items\": [\n{body}\n  ]\n}}")
        }
        ToolCall::Unknown { name, input } => format!(
            "{{\n  \"name\": \"{}\"{}\n}}",
            escape(name),
            input
                .as_ref()
                .map(|v| format!(",\n  \"input\": {v}"))
                .unwrap_or_default()
        ),
    }
}

fn output_json(tool: &ToolItem) -> String {
    if let Some(detail) = tool.detail.as_ref() {
        match detail.as_ref() {
            ToolDetail::Output { lines, .. } => {
                let body = lines
                    .iter()
                    .map(|l| l.as_ref())
                    .collect::<Vec<_>>()
                    .join("\\n");
                return format!("{{\n  \"text\": \"{}\"\n}}", escape(&body));
            }
            ToolDetail::Stats { stats } => {
                let body = stats
                    .iter()
                    .map(|s| {
                        format!(
                            "    {{\"path\": \"{}\", \"+\": {}, \"-\": {}}}",
                            escape(&s.path),
                            s.additions,
                            s.deletions
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(",\n");
                return format!("{{\n  \"stats\": [\n{body}\n  ]\n}}");
            }
            ToolDetail::Diff { file, .. } => {
                return format!(
                    "{{\n  \"path\": \"{}\",\n  \"+\": {},\n  \"-\": {}\n}}",
                    escape(&file.path),
                    file.additions,
                    file.deletions
                );
            }
            ToolDetail::Thought { .. } => {}
        }
    }
    if tool.is_error {
        "{\n  \"ok\": false\n}".into()
    } else if tool.resolved {
        "{\n  \"ok\": true\n}".into()
    } else {
        String::new()
    }
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn format_ms(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else if ms < 10_000 {
        format!("{:.1}s", ms as f32 / 1000.0)
    } else {
        format!("{:.0}s", ms as f32 / 1000.0)
    }
}

/// What the map shows of a transcript, cheap enough to compare whenever the app
/// state changes. Reply text streaming past leaves it the same, so the map isn't
/// rebuilt or redrawn for it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ToolActivity {
    pub calls: usize,
    pub resolved: usize,
    pub failed: usize,
    pub running_agents: usize,
}

pub fn tool_activity(entries: &[SessionMessageEntry]) -> ToolActivity {
    let mut activity = ToolActivity::default();
    for part in entries
        .iter()
        .filter(|entry| entry.role == harness_doc::MessageRole::Assistant)
        .flat_map(|entry| &entry.parts)
    {
        if let MessagePart::Tool {
            resolved,
            is_error,
            subagent_status,
            ..
        } = part
        {
            activity.calls += 1;
            activity.resolved += usize::from(*resolved);
            activity.failed += usize::from(*is_error);
            activity.running_agents +=
                usize::from(matches!(subagent_status, Some(SubagentStatus::Running)));
        }
    }
    activity
}

/// Every tool call in the chat, oldest first. Only the calls the detail view can
/// show get their output parsed.
pub fn tools_from_entries(entries: &[SessionMessageEntry]) -> Vec<ToolItem> {
    let mut out = Vec::new();
    let mut shown: HashMap<&'static str, usize> = HashMap::new();
    for entry in entries.iter().rev() {
        if entry.role != harness_doc::MessageRole::Assistant {
            continue;
        }
        for part in entry.parts.iter().rev() {
            let MessagePart::Tool {
                id,
                call,
                resolved,
                is_error,
                output,
                diff,
                diff_stats,
                subagent_ref,
                subagent_status,
                subagent_tail,
                view,
                ..
            } = part
            else {
                continue;
            };
            let seen = shown.entry(tool_family(call).id).or_default();
            let detail = (*seen < HISTORY_LIMIT)
                .then(|| {
                    crate::transcript::tool_detail(
                        output.as_deref(),
                        diff.as_ref(),
                        diff_stats.as_deref(),
                    )
                })
                .flatten()
                .map(Arc::new);
            *seen += 1;
            out.push(ToolItem {
                part_id: id.clone(),
                call: call.clone(),
                is_error: *is_error,
                resolved: *resolved,
                detail,
                invocation: crate::transcript::call_block(call).map(Arc::new),
                output_ref: None,
                output_bytes: None,
                diff_ref: None,
                subagent_ref: subagent_ref.clone().map(SharedString::from),
                subagent_status: *subagent_status,
                subagent_tail: subagent_tail.clone().map(SharedString::from),
                view: view.clone(),
                kind: ToolItemKind::Call,
            });
        }
    }
    out.reverse();
    out
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

pub fn panel(theme: &Theme) -> gpui::Div {
    div()
        .size_full()
        .flex()
        .flex_col()
        .bg(theme.surface)
        .text_color(theme.text)
        .text_size(px(TEXT_BODY))
        .font_weight(WEIGHT_REGULAR)
}

pub fn header_bar(state: &MapState, theme: &Theme) -> AnyElement {
    div()
        .h(px(40.0))
        .w_full()
        .px(px(16.0))
        .flex()
        .items_center()
        .justify_between()
        .border_b_1()
        .border_color(theme.border)
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.0))
                .child(
                    icons::icon(icons::WIDGET)
                        .size(px(14.0))
                        .text_color(theme.accent)
                        .mt(px(CAP_CENTER_NUDGE)),
                )
                .child(
                    div()
                        .text_size(px(TEXT_TITLE))
                        .font_weight(WEIGHT_STRONG)
                        .child("Tool access"),
                ),
        )
        .child(
            div()
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text_muted)
                .tabular_nums()
                .child(SharedString::from(state.stats_label())),
        )
        .into_any_element()
}

pub fn agent_tabs(state: &MapState, theme: &Theme) -> AnyElement {
    div()
        .w_full()
        .px(px(16.0))
        .pt(px(12.0))
        .flex()
        .flex_row()
        .gap(px(8.0))
        .children(state.agents.iter().enumerate().map(|(ix, agent)| {
            let selected = ix == state.selected_agent;
            div()
                .id(SharedString::from(format!("tool-access-agent-{ix}")))
                .h(px(32.0))
                .px(px(12.0))
                .rounded(px(TAB_RADIUS))
                .flex()
                .items_center()
                .gap(px(6.0))
                .cursor_pointer()
                .bg(if selected {
                    theme.surface_raised
                } else {
                    theme.ink(0.04)
                })
                .border_1()
                .border_color(if selected {
                    theme.border
                } else {
                    theme.ink(0.0)
                })
                .text_color(if selected {
                    theme.text
                } else {
                    theme.text_muted
                })
                .child(
                    icons::icon(agent.icon)
                        .size(px(12.0))
                        .text_color(if selected {
                            theme.text
                        } else {
                            theme.text_muted
                        }),
                )
                .child(agent.name.clone())
        }))
        .into_any_element()
}

fn tool_card(
    tool: &ToolNode,
    theme: &Theme,
    selected: bool,
    on_pick: Option<PickCallback>,
) -> AnyElement {
    let id = tool.id.clone();
    let selector = format!("tool-access-tool-{}", tool.id);
    let dimmed = matches!(
        tool.access,
        ToolAccessKind::Available | ToolAccessKind::NoAccess
    );
    div()
        .id(SharedString::from(format!("tool-access-tool-{}", tool.id)))
        .h(px(TOOL_H))
        .w(px(TOOL_W))
        .px(px(12.0))
        .rounded(px(NODE_RADIUS))
        .border_1()
        .border_color(if selected { theme.accent } else { theme.border })
        .bg(theme.surface_raised)
        .opacity(if dimmed { 0.45 } else { 1.0 })
        .flex()
        .flex_col()
        .justify_center()
        .gap(px(2.0))
        .debug_selector(move || selector)
        .when_some(on_pick, |card, pick| {
            card.cursor_pointer()
                .on_click(move |_, _, cx| pick(id.clone(), cx))
        })
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.0))
                .child(
                    icons::icon(tool.icon)
                        .size(px(14.0))
                        .text_color(theme.text_muted),
                )
                .child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .truncate()
                        .font_weight(WEIGHT_STRONG)
                        .text_size(px(TEXT_BODY))
                        .child(tool.name.clone()),
                )
                .when(tool.failed, |row| {
                    row.child(
                        div()
                            .px(px(6.0))
                            .h(px(18.0))
                            .rounded(px(6.0))
                            .bg(theme.danger)
                            .text_color(gpui::white())
                            .text_size(px(TEXT_CAPTION))
                            .flex()
                            .items_center()
                            .child("Failed"),
                    )
                }),
        )
        .child(
            div()
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text_muted)
                .truncate()
                .child(tool.subtitle.clone()),
        )
        .into_any_element()
}

fn agent_card(agent: &AgentTab, theme: &Theme, phase: f32, reduce_motion: bool) -> AnyElement {
    div()
        .w(px(AGENT_W))
        .h(px(AGENT_H))
        .px(px(16.0))
        .py(px(12.0))
        .rounded(px(NODE_RADIUS))
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface_raised)
        .flex()
        .flex_col()
        .gap(px(8.0))
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.0))
                        .child(
                            icons::icon(agent.icon)
                                .size(px(16.0))
                                .text_color(theme.text),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .child(
                                    div()
                                        .font_weight(WEIGHT_STRONG)
                                        .text_size(px(TEXT_TITLE))
                                        .child(agent.name.clone()),
                                )
                                .when(!agent.model.is_empty(), |col| {
                                    col.child(
                                        div()
                                            .text_size(px(TEXT_CAPTION))
                                            .text_color(theme.text_muted)
                                            .child(agent.model.clone()),
                                    )
                                }),
                        ),
                )
                .when(agent.running, |row| {
                    row.child(
                        div()
                            .h(px(22.0))
                            .px(px(8.0))
                            .rounded(px(11.0))
                            .bg(link_color().opacity(0.18))
                            .text_color(link_color())
                            .text_size(px(TEXT_CAPTION))
                            .flex()
                            .items_center()
                            .gap(px(6.0))
                            .child(if reduce_motion {
                                div()
                                    .size(px(10.0))
                                    .rounded_full()
                                    .border_1()
                                    .border_color(link_color())
                                    .into_any_element()
                            } else {
                                crate::agent_work::spinner(10.0, 1.5, link_color(), link_color().opacity(0.25), phase)
                            })
                            .child("Running"),
                    )
                }),
        )
        .child(
            div()
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text_muted)
                .child(agent.task.clone()),
        )
        .into_any_element()
}

/// Which cards in a column get a link: the tools actually in use.
fn linked_rows(tools: &[&ToolNode]) -> Vec<usize> {
    tools
        .iter()
        .enumerate()
        .filter(|(_, tool)| tool.access == ToolAccessKind::Used)
        .map(|(ix, _)| ix)
        .collect()
}

/// The vertical centre of a card in a column centred in `height`.
fn card_center_y(row: usize, rows: usize, height: f32) -> f32 {
    let step = TOOL_H + TOOL_GAP;
    height / 2.0 + (row as f32 - (rows as f32 - 1.0) / 2.0) * step
}

/// Bezier links from the agent card to the cards of the tools in use.
fn links_canvas(
    inputs: (Vec<usize>, usize),
    outputs: (Vec<usize>, usize),
    theme_link: Hsla,
) -> AnyElement {
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let w = f32::from(bounds.size.width);
            let h = f32::from(bounds.size.height);
            let mid_x = w * 0.5;
            let mid_y = h * 0.5;
            let at = |x: f32, y: f32| point(bounds.origin.x + px(x), bounds.origin.y + px(y));
            let mut link = |from: (f32, f32), to: (f32, f32)| {
                let mut path = PathBuilder::stroke(px(1.5));
                path.move_to(at(from.0, from.1));
                path.cubic_bezier_to(
                    at(to.0, to.1),
                    at(from.0 + (to.0 - from.0) * 0.45, from.1),
                    at(from.0 + (to.0 - from.0) * 0.55, to.1),
                );
                if let Ok(built) = path.build() {
                    window.paint_path(built, theme_link.opacity(0.85));
                }
            };
            let edge = GRAPH_PADDING + TOOL_W;
            let (rows, count) = &inputs;
            for row in rows {
                link(
                    (edge, card_center_y(*row, *count, h)),
                    (mid_x - AGENT_W / 2.0, mid_y),
                );
            }
            let (rows, count) = &outputs;
            for row in rows {
                link(
                    (mid_x + AGENT_W / 2.0, mid_y),
                    (w - edge, card_center_y(*row, *count, h)),
                );
            }
        },
    )
    .absolute()
    .inset_0()
    .into_any_element()
}

pub fn graph(
    state: &MapState,
    on_pick: Option<PickCallback>,
    theme: &Theme,
    phase: f32,
    reduce_motion: bool,
) -> AnyElement {
    let Some(agent) = state.selected() else {
        return div().into_any_element();
    };
    // The map counts the chat's own calls. A subagent's are in its own document,
    // which this panel doesn't read, so its tab doesn't borrow the chat's numbers.
    if state.selected_agent > 0 {
        return div()
            .flex_1()
            .w_full()
            .min_h(px(280.0))
            .p(px(GRAPH_PADDING))
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap(px(12.0))
            .child(agent_card(agent, theme, phase, reduce_motion))
            .child(
                div()
                    .text_size(px(TEXT_CAPTION))
                    .text_color(theme.text_muted)
                    .child("Its tool calls are in its own transcript. Open it from the chat."),
            )
            .into_any_element();
    }
    let inputs: Vec<_> = state
        .tools
        .iter()
        .filter(|t| t.side == ToolSide::Input)
        .collect();
    let outputs: Vec<_> = state
        .tools
        .iter()
        .filter(|t| t.side == ToolSide::Output)
        .collect();
    let input_links = (linked_rows(&inputs), inputs.len());
    let output_links = (linked_rows(&outputs), outputs.len());
    let selected = state.selected_tool.clone();

    // Scrolls in a narrow split panel rather than piling the cards up, which
    // would also leave the links pointing at nothing.
    div()
        .id("tool-access-graph-scroll")
        .flex_1()
        .w_full()
        .min_h(px(280.0))
        .overflow_x_scroll()
        .child(
            div()
                .relative()
                .size_full()
                .min_w(px(GRAPH_MIN_WIDTH))
                .px(px(GRAPH_PADDING))
                .py(px(GRAPH_PADDING))
                .child(links_canvas(input_links, output_links, link_color()))
                .child(
                    div()
                        .relative()
                        .size_full()
                        .flex()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .child(div().flex().flex_col().gap(px(TOOL_GAP)).children(
                            inputs.into_iter().map(|tool| {
                                let sel = selected.as_ref() == Some(&tool.id);
                                tool_card(tool, theme, sel, on_pick.clone())
                            }),
                        ))
                        .child(agent_card(agent, theme, phase, reduce_motion))
                        .child(div().flex().flex_col().gap(px(TOOL_GAP)).children(
                            outputs.into_iter().map(|tool| {
                                let sel = selected.as_ref() == Some(&tool.id);
                                tool_card(tool, theme, sel, on_pick.clone())
                            }),
                        )),
                ),
        )
        .into_any_element()
}

pub fn tool_detail(
    state: &MapState,
    tool_id: &str,
    agent_name: &str,
    actions: Option<DetailActions>,
    theme: &Theme,
) -> AnyElement {
    let Some(tool) = state.tool(tool_id) else {
        return div().into_any_element();
    };
    let records = state.records(tool_id);
    let selected_call = state
        .selected_call
        .as_ref()
        .and_then(|id| records.iter().find(|r| &r.id == id))
        .or_else(|| records.first());

    div()
        .flex_1()
        .m(px(16.0))
        .rounded(px(NODE_RADIUS))
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface_raised)
        .flex()
        .flex_col()
        .overflow_hidden()
        .child(
            div()
                .h(px(44.0))
                .px(px(14.0))
                .flex()
                .items_center()
                .gap(px(10.0))
                .border_b_1()
                .border_color(theme.border)
                .child(
                    div()
                        .id("tool-access-back")
                        .debug_selector(|| "tool-access-back".into())
                        .size(px(24.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(6.0))
                        .role(gpui::Role::Button)
                        .aria_label("Back to the map")
                        .when_some(actions.as_ref().map(|a| a.back.clone()), |button, back| {
                            button
                                .cursor_pointer()
                                .hover(|style| style.bg(theme.ink(0.06)))
                                .on_click(move |_, _, cx| back(cx))
                        })
                        .child(
                            icons::icon(icons::ALT_ARROW_LEFT)
                                .size(px(14.0))
                                .text_color(theme.text_muted),
                        ),
                )
                .child(
                    icons::icon(tool.icon)
                        .size(px(14.0))
                        .text_color(theme.text_muted),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .font_weight(WEIGHT_STRONG)
                                .child(tool.name.clone()),
                        )
                        .child(
                            div()
                                .text_size(px(TEXT_CAPTION))
                                .text_color(theme.text_muted)
                                .child(tool.subtitle.clone()),
                        ),
                )
                .child(div().flex_1())
                .child(
                    div()
                        .text_size(px(TEXT_CAPTION))
                        .text_color(theme.text_muted)
                        .tabular_nums()
                        .child(SharedString::from(format!(
                            "{} {}",
                            tool.calls,
                            if tool.calls == 1 { "call" } else { "calls" }
                        ))),
                ),
        )
        .child(if records.is_empty() {
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .text_color(theme.text_muted)
                .child(SharedString::from(format!(
                    "{agent_name} hasn't called it yet"
                )))
                .into_any_element()
        } else {
            div()
                .flex_1()
                .flex()
                .flex_row()
                .min_h_0()
                .child(
                    div()
                        .id("tool-access-history")
                        .w(px(260.0))
                        .flex_none()
                        .h_full()
                        .overflow_y_scroll()
                        .border_r_1()
                        .border_color(theme.border)
                        .py(px(8.0))
                        .children(records.iter().map(|rec| {
                            let selected = selected_call.is_some_and(|s| s.id == rec.id);
                            let call = rec.id.clone();
                            let select = actions.as_ref().map(|a| a.select_call.clone());
                            let selector = format!("tool-access-call-{}", rec.id);
                            div()
                                .id(SharedString::from(format!("tool-access-call-{}", rec.id)))
                                .debug_selector(move || selector)
                                .px(px(12.0))
                                .py(px(8.0))
                                .flex()
                                .items_center()
                                .gap(px(8.0))
                                .bg(if selected {
                                    theme.ink(0.06)
                                } else {
                                    theme.ink(0.0)
                                })
                                .when_some(select, |row, select| {
                                    row.cursor_pointer()
                                        .hover(|style| style.bg(theme.ink(0.04)))
                                        .on_click(move |_, _, cx| select(call.clone(), cx))
                                })
                                .child(if rec.ok {
                                    icons::icon(icons::CHECK)
                                        .size(px(12.0))
                                        .text_color(theme.success)
                                        .into_any_element()
                                } else {
                                    icons::icon(icons::CLOSE_CIRCLE)
                                        .size(px(12.0))
                                        .text_color(theme.danger)
                                        .into_any_element()
                                })
                                .child(
                                    div()
                                        .min_w_0()
                                        .flex_1()
                                        .truncate()
                                        .font_family(theme.font_mono.clone())
                                        .text_size(px(TEXT_CAPTION))
                                        .child(rec.summary.clone()),
                                )
                                .when_some(rec.duration_ms, |row, ms| {
                                    row.child(
                                        div()
                                            .text_size(px(TEXT_CAPTION))
                                            .text_color(theme.text_faint)
                                            .tabular_nums()
                                            .child(SharedString::from(format_ms(ms))),
                                    )
                                })
                        }))
                        .when(tool.calls > records.len(), |list| {
                            list.child(
                                div()
                                    .px(px(12.0))
                                    .py(px(8.0))
                                    .text_size(px(TEXT_CAPTION))
                                    .text_color(theme.text_faint)
                                    .tabular_nums()
                                    .child(SharedString::from(format!(
                                        "Latest {} of {}",
                                        records.len(),
                                        tool.calls
                                    ))),
                            )
                        }),
                )
                .child(
                    div()
                        .id("tool-access-call")
                        .flex_1()
                        .min_w_0()
                        .h_full()
                        .overflow_y_scroll()
                        .p(px(14.0))
                        .flex()
                        .flex_col()
                        .gap(px(12.0))
                        .children(selected_call.map(|rec| {
                            div()
                                .flex()
                                .flex_col()
                                .gap(px(12.0))
                                .child(io_block("INPUT", &rec.input, theme))
                                .child(io_block("OUTPUT", &rec.output, theme))
                        })),
                )
                .into_any_element()
        })
        .into_any_element()
}

fn io_block(title: &str, body: &str, theme: &Theme) -> AnyElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .child(
            div()
                .text_size(px(TEXT_CAPTION))
                .font_weight(WEIGHT_STRONG)
                .text_color(theme.text_muted)
                .child(SharedString::from(title.to_owned())),
        )
        .child(
            div()
                .w_full()
                .p(px(10.0))
                .rounded(px(8.0))
                .bg(theme.ink(0.05))
                .font_family(theme.font_mono.clone())
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text)
                .child(SharedString::from(body.to_owned())),
        )
        .into_any_element()
}

/// Full panel body for the selected agent (graph or tool detail).
pub fn body(state: &MapState, theme: &Theme, phase: f32, reduce_motion: bool) -> AnyElement {
    let agent_name = state
        .selected()
        .map(|a| a.name.as_ref())
        .unwrap_or("Agent");
    div()
        .size_full()
        .flex()
        .flex_col()
        .child(header_bar(state, theme))
        .child(agent_tabs(state, theme))
        .child(if let Some(tool_id) = state.selected_tool.as_ref() {
            tool_detail(state, tool_id, agent_name, None, theme)
        } else {
            graph(state, None, theme, phase, reduce_motion)
        })
        .into_any_element()
}

pub fn pulse_phase(view: EntityId, cx: &mut App) -> f32 {
    motion::pulse_delta(&SPIN, view, cx)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn tool_item(id: &str, call: ToolCall, resolved: bool, is_error: bool) -> ToolItem {
        ToolItem {
            part_id: id.into(),
            call,
            is_error,
            resolved,
            detail: None,
            invocation: None,
            output_ref: None,
            output_bytes: None,
            diff_ref: None,
            subagent_ref: None,
            subagent_status: None,
            subagent_tail: None,
            view: None,
            kind: ToolItemKind::Call,
        }
    }

    #[test]
    fn map_uses_real_agent_names_not_demo_personas() {
        let tools = vec![
            tool_item(
                "1",
                ToolCall::Search {
                    pattern: "expiry".into(),
                    path: None,
                },
                true,
                false,
            ),
            tool_item(
                "2",
                ToolCall::Exec {
                    command: "pnpm test".into(),
                },
                true,
                true,
            ),
        ];
        let state = from_chat(
            "graff",
            "codegraff/auto",
            "Fix session expiry",
            true,
            &tools,
        );
        assert_eq!(state.agents[0].name.as_ref(), "graff");
        assert!(!state.agents.iter().any(|a| {
            matches!(a.name.as_ref(), "Researcher" | "Coder" | "Writer" | "Analyst")
        }));
        assert!(state.stats_label().contains("tools"));
        assert!(state.tools.iter().any(|t| t.id.as_ref() == "search" && t.calls == 1));
        assert!(state.tools.iter().any(|t| t.id.as_ref() == "terminal" && t.failed));
    }

    fn entry(role: harness_doc::MessageRole, id: &str, parts: Vec<MessagePart>) -> SessionMessageEntry {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "role": role,
            "createdAt": 1,
            "deviceId": "fixture",
            "status": "complete",
            "parts": parts,
        }))
        .unwrap()
    }

    fn exec_part(id: &str, command: &str, output: Option<&str>) -> MessagePart {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "kind": "tool",
            "resolved": true,
            "call": {"kind": "exec", "command": command},
            "output": output,
        }))
        .unwrap()
    }

    fn text_part(id: &str, text: &str) -> MessagePart {
        MessagePart::Text {
            id: id.into(),
            text: text.into(),
        }
    }

    /// Two turns with tools, then one that only talks: the state of most chats
    /// after a reply, which read "0 calls".
    fn chat_ending_in_plain_text() -> Vec<SessionMessageEntry> {
        use harness_doc::MessageRole::{Assistant, User};
        vec![
            entry(User, "u1", vec![text_part("p1", "first")]),
            entry(
                Assistant,
                "a1",
                vec![
                    exec_part("t1", "cargo build", None),
                    exec_part("t2", "cargo test", None),
                ],
            ),
            entry(User, "u2", vec![text_part("p2", "second")]),
            entry(Assistant, "a2", vec![exec_part("t3", "ls", None)]),
            entry(User, "u3", vec![text_part("p3", "thanks")]),
            entry(Assistant, "a3", vec![text_part("r3", "You're welcome.")]),
        ]
    }

    #[test]
    fn the_map_counts_the_whole_chat_not_just_the_last_turn() {
        let tools = tools_from_entries(&chat_ending_in_plain_text());
        let ids: Vec<_> = tools.iter().map(|tool| tool.part_id.as_str()).collect();
        assert_eq!(ids, ["t1", "t2", "t3"], "oldest first");
        let state = from_chat("graff", "m", "task", false, &tools);
        assert_eq!(state.tool("terminal").unwrap().calls, 3);
        assert_eq!(state.stats_label(), "1/5 tools · 3 calls");
    }

    #[test]
    fn the_latest_call_comes_first_and_a_long_history_is_capped() {
        use harness_doc::MessageRole::Assistant;
        let count = HISTORY_LIMIT + 5;
        let parts = (0..count)
            .map(|ix| exec_part(&format!("t{ix}"), "ls", Some("out")))
            .collect();
        let tools = tools_from_entries(&[entry(Assistant, "a", parts)]);
        assert_eq!(tools.len(), count);
        assert!(
            tools[0].detail.is_none(),
            "output too old to be shown isn't parsed"
        );
        assert!(tools[count - 1].detail.is_some());
        let state = from_chat("graff", "m", "task", false, &tools);
        assert_eq!(state.tool("terminal").unwrap().calls, count);
        let records = state.records("terminal");
        assert_eq!(records.len(), HISTORY_LIMIT);
        assert_eq!(records[0].id.as_ref(), format!("t{}", count - 1));
    }

    #[test]
    fn streaming_text_leaves_the_activity_alone_and_a_tool_changes_it() {
        use harness_doc::MessageRole::Assistant;
        let mut entries = chat_ending_in_plain_text();
        let before = tool_activity(&entries);
        assert_eq!(before.calls, 3);
        entries.push(entry(Assistant, "a4", vec![text_part("r4", "More words")]));
        assert_eq!(tool_activity(&entries), before);
        entries.push(entry(Assistant, "a5", vec![exec_part("t4", "ls", None)]));
        assert_ne!(tool_activity(&entries), before);
    }

    #[test]
    fn only_tools_in_use_get_a_link() {
        // Unused web search used to get one, reading as if the agent had used it.
        let tools = vec![tool_item(
            "1",
            ToolCall::Search {
                pattern: "x".into(),
                path: None,
            },
            true,
            false,
        )];
        let state = from_chat("graff", "m", "task", false, &tools);
        let column = |side: ToolSide| -> Vec<&ToolNode> {
            state
                .tools
                .iter()
                .filter(|tool| tool.side == side)
                .collect()
        };
        let inputs = column(ToolSide::Input);
        let rows = linked_rows(&inputs);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            inputs[rows[0]].id.as_ref(),
            "search",
            "it links to the right card"
        );
        assert!(linked_rows(&column(ToolSide::Output)).is_empty());
    }

    #[test]
    fn an_old_failure_is_a_count_and_only_the_latest_gets_the_badge() {
        let exec = |id: &str, failed: bool| {
            tool_item(
                id,
                ToolCall::Exec {
                    command: "x".into(),
                },
                true,
                failed,
            )
        };
        let state = from_chat(
            "graff",
            "m",
            "t",
            false,
            &[exec("1", true), exec("2", false)],
        );
        let terminal = state.tool("terminal").unwrap();
        assert!(!terminal.failed);
        assert_eq!(terminal.subtitle.as_ref(), "2× · 1 failed");
        let state = from_chat(
            "graff",
            "m",
            "t",
            false,
            &[exec("1", false), exec("2", true)],
        );
        assert!(state.tool("terminal").unwrap().failed);
    }

    #[test]
    fn card_centres_stack_around_the_middle() {
        assert_eq!(card_center_y(0, 1, 400.0), 200.0);
        assert_eq!(card_center_y(1, 3, 400.0), 200.0);
        assert_eq!(card_center_y(0, 3, 400.0), 200.0 - (TOOL_H + TOOL_GAP));
        assert_eq!(card_center_y(2, 3, 400.0), 200.0 + (TOOL_H + TOOL_GAP));
    }
}
