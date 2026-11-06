//! Right-pane host for the Tool Access Map. Reads the chat's transcript and
//! agent identity from AppState — the same live data the chat uses — and
//! redraws when a tool starts or finishes, not for every word of a reply.
use std::rc::Rc;

use gpui::{
    App, Context, Entity, IntoElement, Render, SharedString, Subscription, Window, div, prelude::*,
    px,
};
use harness_proto::{HarnessId, SessionStatus};

use crate::icons;
use crate::state::AppState;
use crate::theme::Theme;
use crate::tool_access::{self, MapState, ToolActivity};
use crate::transcript::ToolItem;

pub struct ToolAccessPanel {
    pub chat_id: String,
    state: Entity<AppState>,
    map: MapState,
    activity: ToolActivity,
    identity: ChatIdentity,
    tools: Vec<ToolItem>,
    _state_changes: Subscription,
}

impl ToolAccessPanel {
    pub fn new(chat_id: String, state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let _state_changes = cx.observe(&state, |this, _, cx| {
            if this.refresh(cx) {
                cx.notify();
            }
        });
        let mut panel = Self {
            chat_id,
            state,
            map: tool_access::from_chat("agent", "", "", false, &[]),
            activity: ToolActivity::default(),
            identity: ChatIdentity::default(),
            tools: Vec::new(),
            _state_changes,
        };
        panel.refresh(cx);
        panel
    }

    /// Bring the map up to date with the app state; whether anything changed.
    fn refresh(&mut self, cx: &App) -> bool {
        let app = self.state.read(cx);
        let entries = app.overview_transcript(&self.chat_id);
        let activity = tool_access::tool_activity(entries);
        // A chat no view has loaded right now reads empty. It didn't lose its
        // calls, so keep what was last seen instead of dropping to zero.
        let unloaded = activity.calls == 0 && self.activity.calls > 0;
        let tools_changed = !unloaded && activity != self.activity;
        let identity = ChatIdentity::of(&self.chat_id, app);
        if !tools_changed && identity == self.identity && !self.map_is_unbuilt() {
            return false;
        }
        if tools_changed {
            self.tools = tool_access::tools_from_entries(entries);
            self.activity = activity;
        }
        let previous = std::mem::replace(
            &mut self.map,
            tool_access::from_chat(
                &identity.agent,
                &identity.model,
                &identity.task,
                identity.running,
                &self.tools,
            ),
        );
        self.map.selected_tool = previous.selected_tool;
        self.map.selected_call = previous.selected_call;
        if previous.selected_agent < self.map.agents.len() {
            self.map.selected_agent = previous.selected_agent;
        }
        self.identity = identity;
        true
    }

    fn map_is_unbuilt(&self) -> bool {
        self.identity == ChatIdentity::default()
    }
}

/// Who the map is about, from the chat's row and live session.
#[derive(Debug, Default, PartialEq)]
struct ChatIdentity {
    agent: String,
    model: String,
    task: String,
    running: bool,
}

impl ChatIdentity {
    fn of(chat_id: &str, app: &AppState) -> Self {
        let chat = app.chats.iter().find(|c| c.id == chat_id);
        let config = chat.and_then(|c| c.config.as_ref());
        Self {
            agent: config
                .map(|c| harness_label(c.harness).to_string())
                .unwrap_or_else(|| "agent".into()),
            model: config.and_then(|c| c.model.clone()).unwrap_or_default(),
            task: chat
                .and_then(|c| c.title.clone().or_else(|| c.last_message_preview.clone()))
                .unwrap_or_else(|| "This chat".into()),
            running: app
                .sessions
                .iter()
                .find(|s| s.chat_id == chat_id)
                .is_some_and(|s| {
                    matches!(
                        s.status,
                        SessionStatus::Working | SessionStatus::AwaitingInput
                    )
                }),
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

impl Render for ToolAccessPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let reduce = cx.reduce_motion();
        // The spinner is the only thing that moves. A settled map holds no
        // clock, so an open panel with nothing running doesn't keep redrawing.
        let phase = if self.map.agents.iter().any(|agent| agent.running) {
            tool_access::pulse_phase(cx.entity_id(), cx)
        } else {
            0.0
        };
        let view = cx.entity();

        let mut root = tool_access::panel(&theme).child(tool_access::header_bar(&self.map, &theme));

        // Agent tabs with selection handlers.
        let tabs = div()
            .id("tool-access-agents")
            .w_full()
            .flex_none()
            .overflow_x_scroll()
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
                    .flex_none()
                    .max_w(px(220.0))
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
                    .child(div().min_w_0().truncate().child(agent.name.clone()))
            }));
        root = root.child(tabs);

        if let Some(tool_id) = self.map.selected_tool.clone() {
            let agent_name = self
                .map
                .selected()
                .map(|a| a.name.to_string())
                .unwrap_or_else(|| "Agent".into());
            let select_view = view.clone();
            let back_view = view;
            let actions = tool_access::DetailActions {
                select_call: Rc::new(move |call, cx| {
                    select_view.update(cx, |this, cx| {
                        this.map.selected_call = Some(call);
                        cx.notify();
                    });
                }),
                back: Rc::new(move |cx| {
                    back_view.update(cx, |this, cx| {
                        this.map.selected_tool = None;
                        this.map.selected_call = None;
                        cx.notify();
                    });
                }),
            };
            root.child(
                div()
                    .id("tool-access-detail")
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .child(tool_access::tool_detail(
                        &self.map,
                        tool_id.as_ref(),
                        &agent_name,
                        Some(actions),
                        &theme,
                    )),
            )
        } else {
            let on_pick: tool_access::PickCallback = Rc::new(move |tool, cx| {
                view.update(cx, |this, cx| {
                    this.map.selected_tool = Some(tool);
                    this.map.selected_call = None;
                    cx.notify();
                });
            });
            root.child(
                div()
                    .id("tool-access-graph")
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .child(tool_access::graph(
                        &self.map,
                        Some(on_pick),
                        &theme,
                        phase,
                        reduce,
                    )),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::AppContext as _;
    use harness_doc::{MessagePart, MessageRole, SessionMessageEntry};

    fn tools_entry(id: &str, part: &str, resolved: bool) -> SessionMessageEntry {
        let part: MessagePart = serde_json::from_value(serde_json::json!({
            "id": part, "kind": "tool", "resolved": resolved,
            "call": {"kind": "exec", "command": "cargo test"},
        }))
        .unwrap();
        serde_json::from_value(serde_json::json!({
            "id": id, "role": MessageRole::Assistant, "createdAt": 1,
            "deviceId": "fixture", "status": "complete", "parts": [part],
        }))
        .unwrap()
    }

    fn calls(panel: &Entity<ToolAccessPanel>, cx: &gpui::App) -> usize {
        panel.read(cx).map.tools.iter().map(|tool| tool.calls).sum()
    }

    fn setup(cx: &mut gpui::App) -> Entity<AppState> {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        cx.new(|_| AppState::new())
    }

    /// Opened from a split's other panel, the chat isn't the selected one. It
    /// read as empty because only the selected chat's transcript was looked at.
    #[gpui::test]
    fn a_chat_in_another_panel_shows_its_calls(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            let state = setup(cx);
            state.update(cx, |state, _| {
                state.selected_chat = Some("focused".into());
                state.set_peer_chat_snapshot(
                    "other".into(),
                    vec![tools_entry("a", "t1", true), tools_entry("b", "t2", true)],
                );
            });
            let panel = cx.new(|cx| ToolAccessPanel::new("other".into(), state.clone(), cx));
            assert_eq!(calls(&panel, cx), 2);
        });
    }

    #[gpui::test]
    fn the_map_follows_the_chat_without_being_touched(cx: &mut gpui::TestAppContext) {
        let (state, panel) = cx.update(|cx| {
            let state = setup(cx);
            state.update(cx, |state, _| {
                state.selected_chat = Some("chat".into());
                state.transcript = vec![tools_entry("a", "t1", true)];
            });
            let panel = cx.new(|cx| ToolAccessPanel::new("chat".into(), state.clone(), cx));
            (state, panel)
        });
        panel.read_with(cx, |_, cx| assert_eq!(calls(&panel, cx), 1));
        state.update(cx, |state, cx| {
            state.transcript.push(tools_entry("b", "t2", false));
            cx.notify();
        });
        cx.run_until_parked();
        panel.read_with(cx, |_, cx| assert_eq!(calls(&panel, cx), 2));
    }

    /// Selecting something else unloads the chat. That isn't the calls going away.
    #[gpui::test]
    fn leaving_the_chat_keeps_its_numbers(cx: &mut gpui::TestAppContext) {
        let (state, panel) = cx.update(|cx| {
            let state = setup(cx);
            state.update(cx, |state, _| {
                state.selected_chat = Some("chat".into());
                state.transcript = vec![tools_entry("a", "t1", true)];
            });
            let panel = cx.new(|cx| ToolAccessPanel::new("chat".into(), state.clone(), cx));
            (state, panel)
        });
        state.update(cx, |state, cx| {
            state.selected_chat = Some("elsewhere".into());
            state.transcript = Vec::new();
            cx.notify();
        });
        cx.run_until_parked();
        panel.read_with(cx, |_, cx| assert_eq!(calls(&panel, cx), 1));
    }

    #[gpui::test]
    fn a_settled_map_does_not_keep_the_view_redrawing(cx: &mut gpui::TestAppContext) {
        let panel = cx.update(|cx| {
            let state = setup(cx);
            state.update(cx, |state, _| {
                state.selected_chat = Some("chat".into());
                state.transcript = vec![tools_entry("a", "t1", true)];
            });
            cx.new(|cx| ToolAccessPanel::new("chat".into(), state.clone(), cx))
        });
        let (_view, window) = cx.add_window_view(|_, _| PanelHost(panel.clone()));
        window.update(|window, cx| window.draw(cx).clear());
        window.update(|_, cx| {
            assert!(!crate::motion::has_pulse_lease(panel.entity_id(), cx));
        });
    }

    /// A card opens the tool, a row picks a call, the arrow goes back.
    #[gpui::test]
    fn a_person_can_get_around_the_map(cx: &mut gpui::TestAppContext) {
        let panel = cx.update(|cx| {
            let state = setup(cx);
            state.update(cx, |state, _| {
                state.selected_chat = Some("chat".into());
                state.transcript = vec![tools_entry("a", "t1", true), tools_entry("b", "t2", true)];
            });
            cx.new(|cx| ToolAccessPanel::new("chat".into(), state.clone(), cx))
        });
        let (_view, window) = cx.add_window_view(|_, _| PanelHost(panel.clone()));
        window.simulate_resize(gpui::size(px(900.0), px(700.0)));
        let click = |window: &mut gpui::VisualTestContext, selector: &'static str| {
            window.update(|window, cx| {
                window.refresh();
                window.draw(cx).clear();
            });
            let bounds = window
                .debug_bounds(selector)
                .unwrap_or_else(|| panic!("{selector} is on screen"));
            window.simulate_click(bounds.center(), Default::default());
            window.run_until_parked();
        };
        click(window, "tool-access-tool-terminal");
        panel.read_with(window, |panel, _| {
            assert_eq!(panel.map.selected_tool.as_deref(), Some("terminal"));
            assert_eq!(panel.map.selected_call, None, "it opens on the latest");
            assert_eq!(panel.map.records("terminal")[0].id.as_ref(), "t2");
        });
        click(window, "tool-access-call-t1");
        panel.read_with(window, |panel, _| {
            assert_eq!(panel.map.selected_call.as_deref(), Some("t1"));
        });
        click(window, "tool-access-back");
        panel.read_with(window, |panel, _| {
            assert_eq!(panel.map.selected_tool, None);
        });
    }

    struct PanelHost(Entity<ToolAccessPanel>);
    impl Render for PanelHost {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(self.0.clone())
        }
    }
}
