//! The existing activity chip, with the same card available to the keyboard.
use super::*;
use gpui::{FocusHandle, KeyDownEvent, Role};

/// The originating chat travels with the spawn id; part ids alone are not
/// unique across chats, and a card can outlive a change of selected panel.
pub type RevealChatAgent = Rc<dyn Fn(&str, &str, &mut Window, &mut App)>;

pub struct AgentWorkControl {
    state: Entity<AppState>,
    reveal: RevealChatAgent,
    focus: FocusHandle,
    open: bool,
    active: Option<usize>,
    chat: Option<String>,
    _observe: Subscription,
}

impl AgentWorkControl {
    pub fn new(state: Entity<AppState>, reveal: RevealChatAgent, cx: &mut Context<Self>) -> Self {
        Self {
            chat: state.read(cx).selected_chat.clone(),
            _observe: cx.observe(&state, |_, _, cx| cx.notify()),
            state,
            reveal,
            focus: cx.focus_handle().tab_stop(true),
            open: false,
            active: None,
        }
    }

    fn close(&mut self, cx: &mut Context<Self>) {
        self.open = false;
        self.active = None;
        dismiss_card(cx.entity_id(), cx);
        cx.notify();
    }

    fn callback(&self, cx: &mut Context<Self>) -> RevealAgent {
        let this = cx.weak_entity();
        let chat = self.chat.clone();
        Rc::new(move |part_id, window, cx| {
            this.update(cx, |this, cx| {
                // Stale hover/click callbacks never reveal a same-named tool
                // in a newly selected chat or transfer focus to another panel.
                if this.state.read(cx).selected_chat != chat {
                    this.close(cx);
                    return;
                }
                this.reveal_part(part_id, window, cx);
            })
            .ok();
        })
    }

    fn reveal_part(&mut self, part_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let was_open = self.open;
        self.close(cx);
        if was_open {
            window.focus(&self.focus, cx);
        }
        if let Some(chat) = &self.chat {
            (self.reveal)(chat, part_id, window, cx);
        }
    }

    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if event.keystroke.modifiers.platform
            || event.keystroke.modifiers.control
            || event.keystroke.modifiers.alt
        {
            return;
        }
        let key = event.keystroke.key.as_str();
        let agents = work(&self.state.read(cx).transcript).agents;
        match key {
            "enter" | "space" if self.open => {
                if let Some(agent) = self.active.and_then(|ix| agents.get(ix)) {
                    let part_id = agent.id.clone();
                    self.reveal_part(&part_id, window, cx);
                }
                cx.stop_propagation();
            }
            "enter" | "space" | "down" | "up" => {
                if !self.open {
                    self.open = true;
                    self.active = (!agents.is_empty()).then_some(if key == "up" {
                        agents.len().saturating_sub(1)
                    } else {
                        0
                    });
                    dismiss_card(cx.entity_id(), cx);
                } else {
                    self.active = crate::popover::menu_step(
                        self.active,
                        agents.len(),
                        if key == "up" { -1 } else { 1 },
                    );
                }
                cx.stop_propagation();
                cx.notify();
            }
            "escape" if self.open => {
                self.close(cx);
                cx.stop_propagation();
            }
            "tab" if self.open => self.close(cx),
            _ => {}
        }
    }
}

impl Render for AgentWorkControl {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chat = self.state.read(cx).selected_chat.clone();
        if self.chat != chat {
            self.chat = chat;
            self.close(cx);
        }
        let theme = Theme::of(cx).clone();
        let work = work(&self.state.read(cx).transcript);
        if work.is_empty() {
            self.open = false;
            return div().size_0().into_any_element();
        }
        if self.active.is_some_and(|ix| ix >= work.agents.len()) {
            self.active = (!work.agents.is_empty()).then_some(0);
        }
        let callback = self.callback(cx);
        let chip = footer_chip_inner(
            self.state.clone(),
            &theme,
            cx.entity_id(),
            Some(callback.clone()),
            !self.open,
            cx,
        );
        let active = self.active;
        let phase = if work.live || work.running_agents() > 0 {
            spin_phase(cx.entity_id(), cx)
        } else {
            0.0
        };
        div()
            .id("agent-work-control")
            .debug_selector(|| "agent-work-control".into())
            .relative()
            .track_focus(&self.focus)
            .role(Role::Button)
            .aria_label("Agent activity. Enter to open; arrow keys choose an agent.")
            .rounded(px(Theme::CONTROL_RADIUS))
            .focus(|style| style.bg(theme.element_hover))
            .on_key_down(cx.listener(Self::key))
            .on_click(cx.listener(|this, _, window, cx| {
                cx.stop_propagation();
                window.focus(&this.focus, cx);
                if this.open {
                    this.close(cx);
                } else {
                    this.open = true;
                    this.active = (!super::work(&this.state.read(cx).transcript)
                        .agents
                        .is_empty())
                    .then_some(0);
                    dismiss_card(cx.entity_id(), cx);
                    cx.notify();
                }
            }))
            .children(chip)
            .when(self.open, |root| {
                root.child(crate::popover::anchored_menu_above_end(
                    "agent-activity-keyboard",
                    div()
                        .id("agent-activity-card")
                        .debug_selector(|| "agent-activity-card".into())
                        .occlude()
                        .on_mouse_down_out(cx.listener(|this, _, _, cx| this.close(cx)))
                        .child(work_card_with_active(
                            &work,
                            &Palette::new(&theme),
                            phase,
                            Some(&callback),
                            active,
                        ))
                        .into_any_element(),
                    None,
                ))
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{AppContext as _, VisualTestContext};

    fn agent_transcript() -> Vec<SessionMessageEntry> {
        serde_json::from_value(serde_json::json!([{
            "id":"answer", "role":"assistant", "createdAt":1, "deviceId":"fixture", "status":"complete",
            "parts":[
                {"id":"first", "kind":"tool", "resolved":true, "call":{"kind":"unknown","name":"Agent: Check navigation"}, "subagentStatus":"running", "subagentRef":"doc-first"},
                {"id":"second", "kind":"tool", "resolved":true, "call":{"kind":"unknown","name":"Agent: Check colors"}, "subagentStatus":"running", "subagentRef":"doc-second"}
            ]
        }])).unwrap()
    }

    #[gpui::test]
    fn agent_activity_keyboard_opens_selects_reveals_and_closes(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        let calls = Rc::new(RefCell::new(Vec::new()));
        let captured = calls.clone();
        let state = cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
            cx.new(|_| {
                let mut state = AppState::new();
                state.selected_chat = Some("origin".into());
                state.transcript = agent_transcript();
                state.transcript_revision += 1;
                state
            })
        });
        let reveal: RevealChatAgent = Rc::new(move |chat, part, _, _| {
            captured
                .borrow_mut()
                .push((chat.to_owned(), part.to_owned()));
        });
        let window = cx.add_window(|_, cx| AgentWorkControl::new(state.clone(), reveal, cx));
        window
            .update(cx, |this, window, cx| window.focus(&this.focus, cx))
            .unwrap();
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        let draw = |visual: &mut VisualTestContext| {
            visual.update(|window, cx| {
                window.refresh();
                window.draw(cx).clear();
            })
        };
        draw(&mut visual);
        visual.simulate_keystrokes("enter");
        draw(&mut visual);
        assert!(visual.debug_bounds("agent-activity-card").is_some());
        visual.simulate_keystrokes("down enter");
        draw(&mut visual);
        assert_eq!(
            &*calls.borrow(),
            &[("origin".to_owned(), "second".to_owned())]
        );
        assert!(visual.debug_bounds("agent-activity-card").is_none());
        window
            .update(&mut visual, |this, window, _| {
                assert!(this.focus.is_focused(window))
            })
            .unwrap();
        visual.simulate_keystrokes("space");
        draw(&mut visual);
        assert!(visual.debug_bounds("agent-activity-card").is_some());
        visual.simulate_keystrokes("escape");
        draw(&mut visual);
        assert!(visual.debug_bounds("agent-activity-card").is_none());
        assert_eq!(
            calls.borrow().len(),
            1,
            "Escape must not reveal another agent"
        );

        let stale = window
            .update(&mut visual, |this, _, cx| this.callback(cx))
            .unwrap();
        state.update(&mut visual, |state, cx| {
            state.selected_chat = Some("other".into());
            state.transcript_revision += 1;
            cx.notify();
        });
        visual.update(|window, cx| stale("first", window, cx));
        assert_eq!(
            calls.borrow().len(),
            1,
            "an old card cannot act on a newly selected chat"
        );
    }
}
