//! Explicit history actions and a confirmation that keeps cancellation safe.
use super::*;

#[derive(Clone)]
enum HistoryDiscardTarget {
    Chat {
        id: String,
        title: String,
    },
    Draft {
        record: settings::SavedClosedChat,
        title: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup(
        cx: &mut gpui::TestAppContext,
    ) -> (
        tempfile::TempDir,
        gpui::WindowHandle<Shell>,
        gpui::VisualTestContext,
    ) {
        let (dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.debug_gate = Some(GatePhase::Ready);
            shell.boot_restored = true;
            shell.reduced_motion = true;
            shell.state.update(cx, |state, _| {
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "current")
                    .unwrap()
                    .title = Some("Release notes".into())
            });
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
            assert!(shell.workspace_close_focused(window, cx));
            let first = shell.panel_layout(cx).unwrap().focused;
            shell.focus_workspace_tab(
                first,
                workspace_panels::PanelTab::Chat("peer".into()),
                window,
                cx,
            );
            shell.workspace_split(SplitAxis::Horizontal, cx);
            let second = shell.panel_layout(cx).unwrap().focused;
            shell.focus_workspace_tab(
                second,
                workspace_panels::PanelTab::Chat("target".into()),
                window,
                cx,
            );
            shell.focus_workspace_tab(
                first,
                workspace_panels::PanelTab::Chat("peer".into()),
                window,
                cx,
            );
            shell.toggle_chat_history(window, cx);
        })
        .unwrap();
        let mut visual = gpui::VisualTestContext::from_window(host.into(), cx);
        visual.simulate_resize(gpui::size(px(980.0), px(760.0)));
        draw(&mut visual);
        (dir, host, visual)
    }

    fn draw(visual: &mut gpui::VisualTestContext) {
        visual.run_until_parked();
        visual.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
    }

    fn click(visual: &mut gpui::VisualTestContext, selector: &'static str) {
        draw(visual);
        let bounds = visual
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"));
        visual.simulate_click(bounds.center(), Default::default());
        draw(visual);
    }

    fn layout_tabs(
        shell: &Shell,
        cx: &App,
    ) -> (u64, Vec<(u64, usize, Vec<workspace_panels::PanelTab>)>) {
        let layout = shell.panel_layout(cx).unwrap();
        (
            layout.focused,
            layout
                .panels
                .iter()
                .map(|panel| (panel.id, panel.active, panel.tabs.clone()))
                .collect(),
        )
    }

    #[gpui::test]
    fn history_actions_cancel_is_default_and_background_shortcuts_cannot_escape(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host, mut visual) = setup(cx);
        assert!(visual.debug_bounds("chat-history-title-icon").is_some());
        assert!(
            visual
                .debug_bounds("command-palette-keyboard-hints")
                .is_none()
        );
        click(&mut visual, "history-discard-current");
        host.update(cx, |shell, window, cx| {
            let prompt = shell
                .command_palette
                .as_ref()
                .unwrap()
                .history_discard
                .as_ref()
                .unwrap();
            assert!(prompt.buttons[0].is_focused(window));
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("peer"),
                "discard must not bubble into row restore"
            );
            assert_eq!(settings::recently_closed_chats(cx).len(), 1);
        })
        .unwrap();
        let before_layout = host.read_with(cx, layout_tabs).unwrap();
        for busy in [false, true] {
            host.update(cx, |shell, _, cx| {
                shell
                    .command_palette
                    .as_mut()
                    .unwrap()
                    .history_discard
                    .as_mut()
                    .unwrap()
                    .busy = busy;
                cx.notify();
            })
            .unwrap();
            draw(&mut visual);
            for action in [
                Box::new(FocusComposer) as Box<dyn gpui::Action>,
                Box::new(NewTab),
                Box::new(OpenSettings),
                Box::new(crate::app_menus::CloseTab),
                Box::new(crate::app_menus::CloseTabWithoutArchiving),
                Box::new(FocusChatPaneRight),
                Box::new(FocusNextChatPane),
                Box::new(SplitChatRight),
                Box::new(SplitChatDown),
            ] {
                visual.update(|window, cx| window.dispatch_action(action, cx));
                draw(&mut visual);
                host.update(cx, |shell, window, cx| {
                    let prompt = shell
                        .command_palette
                        .as_ref()
                        .unwrap()
                        .history_discard
                        .as_ref()
                        .unwrap();
                    assert!(prompt.buttons[0].is_focused(window));
                    assert!(matches!(shell.route, Route::Chat));
                    assert_eq!(layout_tabs(shell, cx), before_layout);
                })
                .unwrap();
            }
        }
        host.update(cx, |shell, _, _| {
            shell
                .command_palette
                .as_mut()
                .unwrap()
                .history_discard
                .as_mut()
                .unwrap()
                .busy = false
        })
        .unwrap();
        draw(&mut visual);
        visual.simulate_keystrokes("enter");
        draw(&mut visual);
        host.read_with(cx, |shell, cx| {
            assert!(!shell.history_discard_is_open());
            assert!(shell.command_palette.is_some());
            assert_eq!(settings::recently_closed_chats(cx).len(), 1);
        })
        .unwrap();
    }

    #[gpui::test]
    fn history_actions_hidden_chat_is_searchable_and_restore_unhides(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host, mut visual) = setup(cx);
        click(&mut visual, "history-discard-current");
        click(&mut visual, "history-discard-hide");
        host.update(cx, |shell, _, cx| {
            assert!(
                !shell
                    .command_entries(cx)
                    .contains(&Entry::Chat("current".into()))
            );
            assert!(shell.state.read(cx).chat_row("current").is_some());
            assert_eq!(settings::recently_closed_chats(cx).len(), 1);
            shell
                .command_palette
                .as_ref()
                .unwrap()
                .search
                .update(cx, |input, cx| input.set_text("Release notes", cx));
            assert_eq!(
                shell.command_entries(cx),
                vec![Entry::Chat("current".into())]
            );
        })
        .unwrap();
        draw(&mut visual);
        click(&mut visual, "history-restore-current");
        host.read_with(cx, |shell, cx| {
            assert!(shell.command_palette.is_none());
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            assert!(!settings::hidden_history_entries(cx).contains(&"chat:current".into()));
        })
        .unwrap();
    }

    #[gpui::test]
    fn history_actions_unsent_discard_requires_confirmation_and_preserves_other_history(
        cx: &mut gpui::TestAppContext,
    ) {
        let (dir, host, mut visual) = setup(cx);
        host.update(cx, |_, _, cx| {
            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                settings.remember_closed_chat(settings::SavedClosedChat {
                    id: "discard-me".into(),
                    ..Default::default()
                });
            })
        })
        .unwrap();
        click(&mut visual, "history-discard-discard-me");
        visual.simulate_keystrokes("escape");
        draw(&mut visual);
        host.read_with(cx, |_, cx| {
            assert_eq!(settings::recently_closed_chats(cx).len(), 2)
        })
        .unwrap();
        click(&mut visual, "history-discard-discard-me");
        click(&mut visual, "history-discard-confirm");
        host.read_with(cx, |shell, cx| {
            assert!(!shell.history_discard_is_open());
            let records = settings::recently_closed_chats(cx);
            assert_eq!(records.len(), 1);
            assert_eq!(records[0].chat_id.as_deref(), Some("current"));
            assert_eq!(shell.state.read(cx).chats.len(), 4);
        })
        .unwrap();
        assert_eq!(
            settings::UiSettings::load(dir.path())
                .recently_closed_chats
                .len(),
            1
        );
    }

    #[gpui::test]
    fn history_actions_failed_delete_keeps_the_confirmation_and_recovery(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host, mut visual) = setup(cx);
        click(&mut visual, "history-discard-current");
        click(&mut visual, "history-discard-confirm");
        draw(&mut visual);
        host.update(cx, |shell, window, cx| {
            let prompt = shell
                .command_palette
                .as_ref()
                .unwrap()
                .history_discard
                .as_ref()
                .unwrap();
            assert!(!prompt.busy);
            assert!(
                prompt
                    .error
                    .as_ref()
                    .unwrap()
                    .contains("Engine not connected")
            );
            assert!(prompt.buttons[0].is_focused(window));
            assert!(shell.state.read(cx).chat_row("current").is_some());
            assert_eq!(settings::recently_closed_chats(cx).len(), 1);
        })
        .unwrap();
    }
}

impl HistoryDiscardTarget {
    fn key(&self) -> String {
        match self {
            Self::Chat { id, .. } => format!("chat:{id}"),
            Self::Draft { record, .. } => format!("draft:{}", record.id),
        }
    }

    fn title(&self) -> &str {
        match self {
            Self::Chat { title, .. } | Self::Draft { title, .. } => title,
        }
    }
}

pub(super) struct HistoryDiscardPrompt {
    target: HistoryDiscardTarget,
    focus: FocusHandle,
    buttons: [FocusHandle; 3],
    focus_pending: bool,
    busy: bool,
    error: Option<String>,
}

impl Shell {
    #[cfg(feature = "appshots-fixture")]
    pub(super) fn history_discard_is_busy(&self) -> bool {
        self.command_palette
            .as_ref()
            .and_then(|palette| palette.history_discard.as_ref())
            .is_some_and(|prompt| prompt.busy)
    }

    pub(super) fn history_discard_is_open(&self) -> bool {
        self.command_palette
            .as_ref()
            .is_some_and(|palette| palette.history_discard.is_some())
    }

    pub(super) fn render_history_action(
        &mut self,
        entry: Entry,
        title: &str,
        discard: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let key = match &entry {
            Entry::Chat(id) | Entry::ClosedDraft(id) => id,
            _ => return div().into_any_element(),
        };
        let verb = if discard { "Discard" } else { "Restore" };
        let selector = format!("history-{}-{key}", verb.to_lowercase());
        let hover_group = SharedString::from(selector.clone());
        let hover_color = if discard {
            theme.danger_strong
        } else {
            theme.text
        };
        let focus = self
            .command_palette
            .as_mut()
            .unwrap()
            .history_action_focus
            .entry(selector.clone())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let click_entry = entry.clone();
        let label = format!("{verb} {title}");
        div()
            .id(SharedString::from(selector.clone()))
            .group(hover_group.clone())
            .debug_selector(move || selector.clone())
            .size(px(26.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(6.0))
            .cursor_pointer()
            .occlude()
            .role(gpui::Role::Button)
            .aria_label(label)
            .track_focus(&focus)
            .text_color(theme.text_muted)
            .hover(|style| {
                style.bg(theme.glass_hover()).text_color(if discard {
                    theme.danger_strong
                } else {
                    theme.text
                })
            })
            .focus_visible(|style| style.bg(theme.glass_hover()))
            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                window.prevent_default();
                cx.stop_propagation();
            })
            .on_click(cx.listener(move |this, _, window, cx| {
                cx.stop_propagation();
                if discard {
                    this.begin_history_discard(click_entry.clone(), cx);
                } else {
                    this.activate_command(click_entry.clone(), window, cx);
                }
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "up" | "down") {
                        if let Some(palette) = &this.command_palette {
                            window.focus(&palette.search.focus_handle(cx), cx);
                        }
                        return;
                    }
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        cx.stop_propagation();
                        if event.is_held {
                            return;
                        }
                        if discard {
                            this.begin_history_discard(entry.clone(), cx);
                        } else {
                            this.activate_command(entry.clone(), window, cx);
                        }
                    }
                }),
            )
            .tooltip(move |_, cx| cx.new(|_| SurfaceTabTooltip { text: verb.into() }).into())
            .child(
                icon(if discard {
                    icons::TRASH_BIN_MINIMALISTIC
                } else {
                    icons::RESTART
                })
                .size(px(14.0))
                .text_color(theme.text_muted)
                .group_hover(hover_group, move |style| style.text_color(hover_color)),
            )
            .into_any_element()
    }

    fn begin_history_discard(&mut self, entry: Entry, cx: &mut Context<Self>) {
        let target = match entry {
            Entry::Chat(id) => {
                let Some(chat) = self.state.read(cx).chats.iter().find(|chat| chat.id == id) else {
                    return;
                };
                HistoryDiscardTarget::Chat {
                    title: transcript::single_line(
                        chat.title.as_deref().unwrap_or("Untitled chat"),
                    ),
                    id,
                }
            }
            Entry::ClosedDraft(id) => {
                let Some(record) = settings::recently_closed_chats(cx)
                    .into_iter()
                    .find(|record| record.id == id && record.chat_id.is_none())
                else {
                    return;
                };
                HistoryDiscardTarget::Draft {
                    title: closed_draft_title(&record),
                    record,
                }
            }
            _ => return,
        };
        let Some(palette) = self
            .command_palette
            .as_mut()
            .filter(|palette| palette.navigation.is_history())
        else {
            return;
        };
        palette.history_discard = Some(HistoryDiscardPrompt {
            target,
            focus: cx.focus_handle(),
            buttons: std::array::from_fn(|_| cx.focus_handle().tab_stop(true)),
            focus_pending: true,
            busy: false,
            error: None,
        });
        palette.focus_pending = false;
        cx.notify();
    }

    pub(super) fn cancel_history_discard(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(palette) = self.command_palette.as_mut() else {
            return;
        };
        if palette
            .history_discard
            .as_ref()
            .is_some_and(|prompt| prompt.busy)
        {
            return;
        }
        palette.history_discard = None;
        palette.enter_press.release();
        window.focus(&palette.search.focus_handle(cx), cx);
        cx.notify();
    }

    fn finish_history_discard(&mut self, cx: &mut Context<Self>) {
        if let Some(palette) = self.command_palette.as_mut() {
            palette.history_discard = None;
            palette.focus_pending = true;
            palette.enter_press.release();
        }
        cx.notify();
    }

    fn history_discard_error(&mut self, error: String, cx: &mut Context<Self>) {
        if let Some(prompt) = self
            .command_palette
            .as_mut()
            .and_then(|palette| palette.history_discard.as_mut())
        {
            prompt.busy = false;
            prompt.error = Some(error);
            prompt.focus_pending = true;
        }
        cx.notify();
    }

    fn hide_history_discard_target(&mut self, cx: &mut Context<Self>) {
        let Some(target) = self
            .command_palette
            .as_ref()
            .and_then(|palette| palette.history_discard.as_ref())
            .filter(|prompt| !prompt.busy)
            .map(|prompt| prompt.target.clone())
        else {
            return;
        };
        if self.hide_history_entry(&target.key(), cx) {
            // Hiding must remove it from the visible list even if we arrived
            // through search. The next search can find it again.
            if let Some(palette) = self.command_palette.as_mut() {
                palette
                    .search
                    .update(cx, |search, cx| search.set_text("", cx));
                palette.active = 0;
            }
            self.finish_history_discard(cx);
        } else {
            self.history_discard_error(
                "This item is no longer available. Close this dialog and search again.".into(),
                cx,
            );
        }
    }

    fn confirm_history_discard(&mut self, cx: &mut Context<Self>) {
        let Some(prompt) = self
            .command_palette
            .as_mut()
            .and_then(|palette| palette.history_discard.as_mut())
        else {
            return;
        };
        if prompt.busy {
            return;
        }
        prompt.busy = true;
        prompt.error = None;
        let target = prompt.target.clone();
        match target {
            HistoryDiscardTarget::Draft { record, .. } => {
                if self.discard_closed_chat_record(&record, cx) {
                    self.finish_history_discard(cx);
                } else {
                    self.history_discard_error("This draft changed while the dialog was open. Close this dialog and review it again.".into(), cx);
                }
            }
            HistoryDiscardTarget::Chat { id, .. } => {
                let key = format!("chat:{id}");
                let deletion = self.delete_history_chat(id, cx);
                cx.spawn(async move |this, cx| {
                    let result = deletion.await;
                    let _ = this.update(cx, |this, cx| {
                        if !this
                            .command_palette
                            .as_ref()
                            .and_then(|palette| palette.history_discard.as_ref())
                            .is_some_and(|prompt| prompt.target.key() == key)
                        {
                            return;
                        }
                        match result {
                            Ok(()) => this.finish_history_discard(cx),
                            Err(error) => this.history_discard_error(
                                format!("Couldn’t delete the conversation. {error}"),
                                cx,
                            ),
                        }
                    });
                })
                .detach();
            }
        }
        cx.notify();
    }

    pub(super) fn render_history_discard(
        &mut self,
        viewport: gpui::Size<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let prompt = self.command_palette.as_mut()?.history_discard.as_mut()?;
        if std::mem::take(&mut prompt.focus_pending) {
            window.focus(&prompt.buttons[0], cx);
        }
        let buttons = prompt.buttons.clone();
        let focus = prompt.focus.clone();
        let busy = prompt.busy;
        let error = prompt.error.clone();
        let is_chat = matches!(prompt.target, HistoryDiscardTarget::Chat { .. });
        let title = prompt.target.title().to_string();
        let heading = if is_chat {
            "Discard conversation?"
        } else {
            "Discard draft?"
        };
        let warning = if is_chat {
            "Delete permanently will remove this conversation and all of its messages. This can’t be undone."
        } else {
            "Discard draft will permanently remove its unsent text and attachments. This can’t be undone."
        };
        let delete_label = if busy {
            "Deleting…"
        } else if is_chat {
            "Delete permanently"
        } else {
            "Discard draft"
        };
        let theme = Theme::of(cx).for_popup();
        let card = popover::dialog_card(&theme)
            .w(px(440.0_f32.min(f32::from(viewport.width) - 32.0)))
            .id("history-discard-dialog")
            .debug_selector(|| "history-discard-dialog".into())
            .role(gpui::Role::Dialog)
            .aria_label(heading)
            .track_focus(&focus)
            .on_action(|_: &FocusComposer, _, cx| cx.stop_propagation())
            .on_action(|_: &NewTab, _, cx| cx.stop_propagation())
            .on_action(|_: &NewChatTab, _, cx| cx.stop_propagation())
            .on_action(|_: &NewConversation, _, cx| cx.stop_propagation())
            .on_action(|_: &OpenSettings, _, cx| cx.stop_propagation())
            .on_action(|_: &ToggleSidebar, _, cx| cx.stop_propagation())
            .on_action(|_: &ToggleCommandPalette, _, cx| cx.stop_propagation())
            .on_action(|_: &NextChatTab, _, cx| cx.stop_propagation())
            .on_action(|_: &PrevChatTab, _, cx| cx.stop_propagation())
            .on_action(|_: &SelectChatTab, _, cx| cx.stop_propagation())
            .on_action(|_: &crate::app_menus::CloseTab, _, cx| cx.stop_propagation())
            .on_action(|_: &crate::app_menus::CloseTabWithoutArchiving, _, cx| {
                cx.stop_propagation()
            })
            .on_action(|_: &FocusChatPaneLeft, _, cx| cx.stop_propagation())
            .on_action(|_: &FocusChatPaneRight, _, cx| cx.stop_propagation())
            .on_action(|_: &FocusChatPaneUp, _, cx| cx.stop_propagation())
            .on_action(|_: &FocusChatPaneDown, _, cx| cx.stop_propagation())
            .on_action(|_: &FocusNextChatPane, _, cx| cx.stop_propagation())
            .on_action(|_: &FocusPrevChatPane, _, cx| cx.stop_propagation())
            .on_action(|_: &SplitChatRight, _, cx| cx.stop_propagation())
            .on_action(|_: &SplitChatDown, _, cx| cx.stop_propagation())
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    match event.keystroke.key.as_str() {
                        "escape" => this.cancel_history_discard(window, cx),
                        "tab" => {
                            if !busy {
                                let at = buttons
                                    .iter()
                                    .position(|focus| focus.is_focused(window))
                                    .unwrap_or(0);
                                let next = if event.keystroke.modifiers.shift {
                                    (at + 2) % 3
                                } else {
                                    (at + 1) % 3
                                };
                                window.focus(&buttons[next], cx);
                            }
                        }
                        _ => return,
                    }
                    cx.stop_propagation();
                }),
            )
            .child(popover::dialog_title(&theme, heading))
            .child(div().mt(px(8.0)).child(popover::dialog_body(&theme, title)))
            .child(div().mt(px(12.0)).child(popover::dialog_body(
                &theme,
                "Hide from list keeps it saved. You can find it again by searching Chat history.",
            )))
            .child(
                div()
                    .debug_selector(|| "history-discard-warning".into())
                    .mt(px(10.0))
                    .child(popover::dialog_body(&theme, warning)),
            )
            .when_some(error, |card, error| {
                card.child(
                    div()
                        .mt(px(10.0))
                        .text_color(theme.danger_strong)
                        .child(error),
                )
            })
            .child(
                div()
                    .mt(px(20.0))
                    .flex()
                    .flex_wrap()
                    .justify_end()
                    .gap(px(8.0))
                    .child(self.history_confirmation_button(
                        "history-discard-cancel",
                        "Cancel",
                        0,
                        false,
                        busy,
                        &theme,
                        cx,
                    ))
                    .child(self.history_confirmation_button(
                        "history-discard-hide",
                        "Hide from list",
                        1,
                        false,
                        busy,
                        &theme,
                        cx,
                    ))
                    .child(self.history_confirmation_button(
                        "history-discard-confirm",
                        delete_label,
                        2,
                        true,
                        busy,
                        &theme,
                        cx,
                    )),
            );
        Some(popover::modal(
            "history-discard-modal",
            viewport,
            card.into_any_element(),
        ))
    }

    fn history_confirmation_button(
        &self,
        id: &'static str,
        label: &str,
        action: usize,
        danger: bool,
        busy: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let focus = self
            .command_palette
            .as_ref()
            .unwrap()
            .history_discard
            .as_ref()
            .unwrap()
            .buttons[action]
            .clone();
        let button = if danger {
            popover::btn_danger(theme, label)
        } else {
            popover::btn_ghost(theme, label, id)
        };
        button
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .track_focus(&focus.tab_stop(!busy))
            .border_1()
            .border_color(theme.text_muted.opacity(0.0))
            .focus_visible(|style| style.border_color(theme.text_muted))
            .when(busy, |button| button.opacity(0.5).cursor_default())
            .on_click(cx.listener(move |this, _, window, cx| {
                cx.stop_propagation();
                if busy {
                    return;
                }
                match action {
                    0 => this.cancel_history_discard(window, cx),
                    1 => this.hide_history_discard_target(cx),
                    _ => this.confirm_history_discard(cx),
                }
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        cx.stop_propagation();
                        if busy || event.is_held {
                            return;
                        }
                        match action {
                            0 => this.cancel_history_discard(window, cx),
                            1 => this.hide_history_discard_target(cx),
                            _ => this.confirm_history_discard(cx),
                        }
                    }
                }),
            )
            .into_any_element()
    }
}
