//! Right-pane host for the Tool Access Map. Reads the selected chat's
//! transcript and agent identity from AppState — the same live data the
//! chat uses — and re-renders as the turn streams.
use gpui::{
    App, AppContext, Context, Entity, IntoElement, Render, SharedString, Window, div, prelude::*,
    px,
};
use harness_proto::{HarnessId, SessionStatus};

use crate::icons;
use crate::state::AppState;
use crate::theme::Theme;
use crate::tool_access::{self, MapState};

pub struct ToolAccessPanel {
    pub chat_id: String,
    state: Entity<AppState>,
    map: MapState,
}

impl ToolAccessPanel {
    pub fn new(chat_id: String, state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let map = snapshot_map(&chat_id, &state, None, cx);
        Self {
            chat_id,
            state,
            map,
        }
    }
}

fn harness_label(id: HarnessId) -> &'static str {
    match id {
        HarnessId::ClaudeCode => "claude",
        HarnessId::Codex => "codex",
        HarnessId::Cursor => "cursor",
        HarnessId::Devin => "devin",
        HarnessId::Grok => "grok",
        HarnessId::Hermes => "hermes",
        HarnessId::Graff => "graff",
        HarnessId::Pi => "pi",
        HarnessId::Opencode => "opencode",
        HarnessId::Antigravity => "antigravity",
        HarnessId::Exo => "exo",
        HarnessId::Mock => "mock",
    }
}

fn snapshot_map(
    chat_id: &str,
    state: &Entity<AppState>,
    previous: Option<&MapState>,
    cx: &App,
) -> MapState {
    let app = state.read(cx);
    let chat = app.chats.iter().find(|c| c.id == chat_id);
    let agent_name = chat
        .and_then(|c| c.config.as_ref())
        .map(|c| harness_label(c.harness).to_string())
        .unwrap_or_else(|| "agent".into());
    let model = chat
        .and_then(|c| c.config.as_ref())
        .and_then(|c| c.model.clone())
        .unwrap_or_default();
    let task = chat
        .and_then(|c| c.title.clone().or_else(|| c.last_message_preview.clone()))
        .unwrap_or_else(|| "Current turn".into());
    let running = app
        .sessions
        .iter()
        .find(|s| s.chat_id == chat_id)
        .is_some_and(|s| matches!(s.status, SessionStatus::Working | SessionStatus::AwaitingInput));
    let entries = if app.selected_chat.as_deref() == Some(chat_id) {
        app.transcript.clone()
    } else {
        Vec::new()
    };
    let tools = tool_access::tools_from_entries(&entries);
    let mut map = tool_access::from_turn(&agent_name, &model, &task, running, &tools);
    if let Some(prev) = previous {
        map.selected_tool = prev.selected_tool.clone();
        map.selected_call = prev.selected_call.clone();
        if prev.selected_agent < map.agents.len() {
            map.selected_agent = prev.selected_agent;
        }
    }
    map
}

impl Render for ToolAccessPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.map = snapshot_map(&self.chat_id, &self.state, Some(&self.map), cx);
        let theme = Theme::of(cx).clone();
        let reduce = cx.reduce_motion();
        let phase = tool_access::pulse_phase(cx.entity_id(), cx);
        let view = cx.entity();

        let mut root = tool_access::panel(&theme).child(tool_access::header_bar(&self.map, &theme));

        // Agent tabs with selection handlers.
        let tabs = div()
            .w_full()
            .px(px(16.0))
            .pt(px(12.0))
            .flex()
            .flex_row()
            .gap(px(8.0))
            .children(self.map.agents.iter().enumerate().map(|(ix, agent)| {
                let selected = ix == self.map.selected_agent;
                let entity = view.clone();
                div()
                    .id(SharedString::from(format!("tool-access-agent-{ix}")))
                    .h(px(32.0))
                    .px(px(12.0))
                    .rounded(px(8.0))
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
                    .text_size(px(12.0))
                    .text_color(if selected {
                        theme.text
                    } else {
                        theme.text_muted
                    })
                    .on_click(move |_, _, cx| {
                        entity.update(cx, |this, cx| {
                            this.map.selected_agent = ix;
                            this.map.selected_tool = None;
                            this.map.selected_call = None;
                            cx.notify();
                        });
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
            }));
        root = root.child(tabs);

        if let Some(tool_id) = self.map.selected_tool.clone() {
            let entity = view.clone();
            let agent_name = self
                .map
                .selected()
                .map(|a| a.name.to_string())
                .unwrap_or_else(|| "Agent".into());
            let detail = tool_access::tool_detail(
                &self.map,
                tool_id.as_ref(),
                &agent_name,
                &theme,
                phase,
                reduce,
            );
            let tid = tool_id.clone();
            root.child(
                div()
                    .id("tool-access-detail")
                    .flex_1()
                    .min_h_0()
                    .overflow_hidden()
                    .child(detail)
                    .child(
                        div()
                            .id("tool-access-back")
                            .absolute()
                            .top(px(8.0))
                            .left(px(12.0))
                            .h(px(28.0))
                            .px(px(10.0))
                            .rounded(px(6.0))
                            .flex()
                            .items_center()
                            .gap(px(6.0))
                            .cursor_pointer()
                            .bg(theme.surface_raised)
                            .border_1()
                            .border_color(theme.border)
                            .text_size(px(12.0))
                            .text_color(theme.text_muted)
                            .on_click(move |_, _, cx| {
                                entity.update(cx, |this, cx| {
                                    this.map.selected_tool = None;
                                    this.map.selected_call = None;
                                    cx.notify();
                                });
                            })
                            .child(
                                icons::icon(icons::ARROW_LEFT)
                                    .size(px(12.0))
                                    .text_color(theme.text_muted),
                            )
                            .child("Back"),
                    )
                    .child(replay_bar(&self.map, tid.as_ref(), &theme, view.clone())),
            )
        } else {
            root.child(
                div()
                    .id("tool-access-graph")
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .child(tool_access::graph(&self.map, &theme, phase, reduce))
                    .child(tool_pickers(&self.map, &theme, view)),
            )
        }
    }
}

fn tool_pickers(map: &MapState, theme: &Theme, view: Entity<ToolAccessPanel>) -> gpui::AnyElement {
    div()
        .absolute()
        .left(px(16.0))
        .right(px(16.0))
        .bottom(px(12.0))
        .flex()
        .flex_row()
        .flex_wrap()
        .gap(px(8.0))
        .children(map.tools.iter().map(|tool| {
            let id = tool.id.clone();
            let entity = view.clone();
            let active = tool.calls > 0 || matches!(tool.access, crate::tool_access::ToolAccessKind::Used);
            div()
                .id(SharedString::from(format!("pick-{}", tool.id)))
                .h(px(28.0))
                .px(px(10.0))
                .rounded(px(6.0))
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface_raised)
                .opacity(if active { 1.0 } else { 0.45 })
                .flex()
                .items_center()
                .gap(px(6.0))
                .cursor_pointer()
                .text_size(px(12.0))
                .text_color(theme.text)
                .on_click(move |_, _, cx| {
                    let id = id.clone();
                    entity.update(cx, |this, cx| {
                        this.map.selected_tool = Some(id);
                        this.map.selected_call = None;
                        cx.notify();
                    });
                })
                .child(
                    icons::icon(tool.icon)
                        .size(px(12.0))
                        .text_color(theme.text_muted),
                )
                .child(tool.name.clone())
        }))
        .into_any_element()
}

fn replay_bar(
    map: &MapState,
    tool_id: &str,
    theme: &Theme,
    view: Entity<ToolAccessPanel>,
) -> gpui::AnyElement {
    let records = map.records(tool_id);
    let call_id = map
        .selected_call
        .clone()
        .or_else(|| records.first().map(|r| r.id.clone()));
    let Some(call_id) = call_id else {
        return div().into_any_element();
    };
    let entity = view.clone();
    let tid = SharedString::from(tool_id.to_string());
    let cid = call_id.clone();
    div()
        .absolute()
        .right(px(16.0))
        .bottom(px(12.0))
        .flex()
        .flex_row()
        .gap(px(8.0))
        .child(
            div()
                .id("tool-access-replay")
                .h(px(28.0))
                .px(px(12.0))
                .rounded(px(6.0))
                .bg(theme.accent)
                .text_color(theme.on_accent)
                .text_size(px(12.0))
                .flex()
                .items_center()
                .cursor_pointer()
                                .on_click(move |_, _, cx| {
                    let tid = tid.clone();
                    let cid = cid.clone();
                    entity.update(cx, |this, cx| {
                        tool_access::begin_replay(&mut this.map, tid.as_ref(), cid.as_ref());
                        cx.notify();
                        let tid2 = tid.clone();
                        let cid2 = cid.clone();
                        cx.spawn(async move |this, cx| {
                            cx.background_executor()
                                .timer(std::time::Duration::from_millis(700))
                                .await;
                            let _ = this.update(cx, |this, cx| {
                                tool_access::finish_replay(
                                    &mut this.map,
                                    tid2.as_ref(),
                                    cid2.as_ref(),
                                    "{\n  \"ok\": true,\n  \"replayed\": true\n}",
                                );
                                cx.notify();
                            });
                        })
                        .detach();
                    });
                })
                .child("Replay"),
        )
        .into_any_element()
}
