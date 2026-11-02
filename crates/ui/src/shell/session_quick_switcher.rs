//! Compact session navigation for a workspace whose sidebar is hidden.
use super::*;

#[derive(Default)]
pub(super) struct SessionQuickSwitcher {
    popup: popover::Popup<SessionMenu>,
    trigger: Option<FocusHandle>,
    scroll: gpui::ScrollHandle,
}

struct SessionMenu {
    selected: usize,
    focus: FocusHandle,
}

impl SessionQuickSwitcher {
    pub(super) fn is_open(&self) -> bool {
        self.popup.is_open()
    }

    pub(super) fn close(&mut self) {
        self.popup = Default::default();
    }
}

impl Shell {
    pub(super) fn workspace_session_quick_width(&self, cx: &App) -> f32 {
        let title = self
            .workspace_session_sidebar_rows(cx)
            .into_iter()
            .find(|row| row.active)
            .map(|row| row.title)
            .unwrap_or_else(|| "Sessions".into());
        Self::workspace_session_quick_width_for(
            &title,
            self.viewport_width,
            self.workspace_titlebar_buttons_end(cx),
            self.titlebar_right_pad(0.0),
            self.workspace_uses_shared_header(cx),
            cx,
        )
    }

    /// The same shaped width before a new native window has a Shell or frame.
    pub(super) fn workspace_session_quick_width_for(
        title: &str,
        viewport_width: f32,
        buttons_end: f32,
        right_pad: f32,
        shared_header: bool,
        cx: &App,
    ) -> f32 {
        let title: SharedString = title.replace(['\n', '\r'], " ").into();
        let theme = Theme::of(cx);
        let text = gpui::WindowTextSystem::new(cx.text_system().clone()).shape_line(
            title.clone(),
            px(12.0 * crate::typography::font_size(cx).pixels() / 16.0),
            &[gpui::TextRun {
                len: title.len(),
                font: gpui::font(theme.font_sans.clone()),
                color: theme.text,
                ..Default::default()
            }],
            None,
        );
        // Leave a readable tab and the panel actions beside long session names.
        let max = if shared_header {
            (viewport_width - buttons_end - right_pad - 224.0).clamp(64.0, 200.0)
        } else {
            200.0
        };
        (f32::from(text.width()).ceil() + 51.0).clamp(64.0, max)
    }

    pub(super) fn render_workspace_titlebar_identity(&self, cx: &App) -> Option<AnyElement> {
        if !matches!(self.route, Route::Chat)
            || !self.settings.sidebar_collapsed
            || self.workspace_uses_shared_header(cx)
            || self.workspace_header_transition_active(cx)
        {
            return None;
        }
        let safe_side = (self.workspace_titlebar_buttons_end(cx) + 4.0 + 200.0 + 16.0)
            .max(self.titlebar_right_pad(16.0));
        let width = (self.viewport_width - safe_side * 2.0).min(320.0);
        if width < 80.0 {
            return None;
        }
        let layout = self.panel_layout(cx)?;
        let tab = layout
            .panels
            .iter()
            .find(|panel| panel.id == layout.focused)?
            .selected()?;
        let (title, _) = self.panel_tab_label(tab, cx);
        let theme = Theme::of(cx);
        Some(
            div()
                .id("workspace-titlebar-identity")
                .debug_selector(|| "workspace-titlebar-identity".into())
                .absolute()
                .top_0()
                .left(px((self.viewport_width - width) / 2.0))
                .w(px(width))
                .h(px(Theme::TITLEBAR_HEIGHT))
                .pt(px(Theme::TITLEBAR_TOP_PAD))
                .flex()
                .items_center()
                .justify_center()
                .text_size(crate::typography::ui_rems(12.0))
                .text_color(theme.text_muted)
                .child(div().min_w_0().truncate().child(title))
                .into_any_element(),
        )
    }

    pub(super) fn open_workspace_session_quick_switcher(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.ensure_workspace_sessions(cx);
        self.close_spaces_menu(cx);
        self.close_sidebar_view_menu(cx);
        let rows = self.workspace_session_sidebar_rows(cx);
        let selected = rows.iter().position(|row| row.active).unwrap_or(0);
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        self.session_quick_switcher
            .popup
            .open(SessionMenu { selected, focus });
        self.session_quick_switcher.scroll.scroll_to_item(selected);
        cx.notify();
    }

    fn close_workspace_session_quick_switcher(
        &mut self,
        restore_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.session_quick_switcher.popup.begin_close() {
            popover::reap_popup(cx, |shell| &mut shell.session_quick_switcher.popup);
            if restore_focus && let Some(focus) = &self.session_quick_switcher.trigger {
                window.focus(focus, cx);
            }
            cx.notify();
        }
    }

    pub(super) fn dismiss_workspace_session_quick_switcher(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.session_quick_switcher.is_open() {
            return false;
        }
        self.close_workspace_session_quick_switcher(true, window, cx);
        true
    }

    fn activate_workspace_session_quick_choice(
        &mut self,
        choice: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.session_quick_switcher.is_open() {
            return;
        }
        let rows = self.workspace_session_sidebar_rows(cx);
        self.close_workspace_session_quick_switcher(choice == rows.len(), window, cx);
        if let Some(row) = rows.get(choice) {
            self.activate_workspace_session(&row.id, cx);
        } else if choice == rows.len() {
            self.open_session_overview(window, cx);
        } else if choice == rows.len() + 1 {
            self.create_workspace_session(cx);
        }
    }

    pub(super) fn render_workspace_session_quick_switcher(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let active = self
            .workspace_session_sidebar_rows(cx)
            .into_iter()
            .find(|row| row.active);
        let title = active
            .as_ref()
            .map(|row| row.title.clone())
            .unwrap_or_else(|| "Sessions".into());
        let glyph = active
            .as_ref()
            .map(|row| row.icon.clone())
            .unwrap_or_else(|| session_icon::SessionIcon::from_key(None));
        let open = self.session_quick_switcher.is_open();
        let shared_width = self
            .workspace_uses_shared_header(cx)
            .then(|| self.workspace_session_quick_width(cx));
        let focus = self
            .session_quick_switcher
            .trigger
            .get_or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let mut anchor = div().relative().flex_none().child(
            div()
                .id("workspace-session-quick-switcher")
                .debug_selector(|| "workspace-session-quick-switcher".into())
                .role(gpui::Role::Button)
                .aria_label(format!("{title}, switch session"))
                .aria_expanded(open)
                .track_focus(&focus)
                .h(px(28.0))
                .max_w(px(200.0))
                .when_some(shared_width, |el, width| el.w(px(width)))
                .px(px(7.0))
                .flex()
                .items_center()
                .gap(px(6.0))
                .rounded(px(6.0))
                .text_size(crate::typography::ui_rems(12.0))
                .text_color(theme.text)
                .cursor_pointer()
                .when(open, |el| el.bg(theme.element_hover))
                .hover(|el| el.bg(theme.element_hover))
                .focus_visible(|el| el.bg(theme.element_hover))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        this.session_quick_switcher.popup.note_trigger_press();
                        window.prevent_default();
                        cx.stop_propagation();
                    }),
                )
                .on_click(cx.listener(|this, _, window, cx| {
                    if this.session_quick_switcher.popup.take_press_was_open() {
                        this.close_workspace_session_quick_switcher(true, window, cx);
                    } else {
                        this.open_workspace_session_quick_switcher(window, cx);
                    }
                    cx.stop_propagation();
                }))
                .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(
                        event.keystroke.key.as_str(),
                        "enter" | "space" | "down" | "arrowdown"
                    ) {
                        this.open_workspace_session_quick_switcher(window, cx);
                        cx.stop_propagation();
                    }
                }))
                .child(glyph.render(14.0, theme.text_muted))
                .child(div().min_w_0().truncate().child(title))
                .child(
                    icon(icons::ALT_ARROW_DOWN)
                        .size(px(11.0))
                        .flex_none()
                        .text_color(theme.text_muted),
                ),
        );
        if self.session_quick_switcher.popup.get().is_some() {
            let closing = self.session_quick_switcher.popup.closing_since();
            let menu = self.render_workspace_session_quick_menu(theme, cx);
            anchor = anchor.child(popover::anchored_menu_below(
                "workspace-session-quick-menu",
                menu,
                closing,
            ));
        }
        anchor.into_any_element()
    }

    fn render_workspace_session_quick_menu(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = theme.for_popup();
        let rows = self.workspace_session_sidebar_rows(cx);
        let menu = self.session_quick_switcher.popup.get().unwrap();
        let selected = menu.selected.min(rows.len() + 1);
        let mut card = popover::popover_card(&theme)
            .id("workspace-session-quick-menu-card")
            .debug_selector(|| "workspace-session-quick-menu-card".into())
            .w(px(292.0))
            .track_focus(&menu.focus)
            .on_mouse_down_out(cx.listener(|this, _, window, cx| {
                this.close_workspace_session_quick_switcher(false, window, cx);
            }))
            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                window.prevent_default();
                cx.stop_propagation();
            })
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                let count = this.workspace_session_sidebar_rows(cx).len();
                let Some(menu) = this.session_quick_switcher.popup.open_mut() else {
                    return;
                };
                match event.keystroke.key.as_str() {
                    "up" | "arrowup" | "down" | "arrowdown" | "tab" => {
                        let backwards = matches!(event.keystroke.key.as_str(), "up" | "arrowup")
                            || (event.keystroke.key == "tab" && event.keystroke.modifiers.shift);
                        menu.selected = popover::menu_step(
                            Some(menu.selected),
                            count + 2,
                            if backwards { -1 } else { 1 },
                        )
                        .unwrap();
                        if menu.selected < count {
                            this.session_quick_switcher
                                .scroll
                                .scroll_to_item(menu.selected);
                        }
                    }
                    "home" => {
                        menu.selected = 0;
                        this.session_quick_switcher.scroll.scroll_to_item(0);
                    }
                    "end" => menu.selected = count + 1,
                    "enter" | "space" => {
                        let selected = menu.selected;
                        this.activate_workspace_session_quick_choice(selected, window, cx);
                    }
                    "escape" => this.close_workspace_session_quick_switcher(true, window, cx),
                    _ => return,
                }
                cx.stop_propagation();
                cx.notify();
            }))
            .on_action(cx.listener(|this, jump: &JumpSession, window, cx| {
                let rows = this.workspace_session_sidebar_rows(cx);
                let choice = rows
                    .iter()
                    .enumerate()
                    .filter(|(_, row)| {
                        this.settings
                            .space_filter
                            .as_ref()
                            .is_none_or(|project| row.project.as_ref() == Some(project))
                    })
                    .nth(jump.0)
                    .map(|(ix, _)| ix);
                if let Some(choice) = choice {
                    this.activate_workspace_session_quick_choice(choice, window, cx);
                }
                cx.stop_propagation();
            }));
        let mut list = div()
            .id("workspace-session-quick-list")
            .max_h(px(360.0))
            .overflow_y_scroll()
            .track_scroll(&self.session_quick_switcher.scroll);
        let mut shortcut_slot = 0;
        for (ix, row) in rows.iter().enumerate() {
            let matches_filter = self
                .settings
                .space_filter
                .as_ref()
                .is_none_or(|project| row.project.as_ref() == Some(project));
            let shortcut = if matches_filter && shortcut_slot < JUMP_SLOTS {
                let shortcut = settings::shortcut_badge(cx, ShortcutId::JumpSession(shortcut_slot));
                shortcut_slot += 1;
                Some(shortcut)
            } else {
                None
            };
            list = list.child(
                popover::menu_row_nav(
                    &theme,
                    row.active,
                    selected == ix,
                    format!("session-quick-row-{}", row.id),
                )
                .id(SharedString::from(format!("session-quick-row-{}", row.id)))
                .debug_selector({
                    let id = row.id.clone();
                    move || format!("session-quick-row-{id}")
                })
                .min_h(px(34.0))
                .role(gpui::Role::Button)
                .aria_label(format!(
                    "{}{}",
                    row.title,
                    if row.active { ", current session" } else { "" }
                ))
                .on_mouse_move(cx.listener(move |this, _, _, cx| {
                    if let Some(menu) = this.session_quick_switcher.popup.open_mut()
                        && menu.selected != ix
                    {
                        menu.selected = ix;
                        cx.notify();
                    }
                }))
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.activate_workspace_session_quick_choice(ix, window, cx)
                }))
                .child(row.icon.render(15.0, theme.text_muted))
                .child(div().flex_1().min_w_0().truncate().child(row.title.clone()))
                .when(row.pinned, |el| {
                    el.child(icon(icons::PIN).size(px(11.0)).text_color(theme.text_muted))
                })
                .when_some(shortcut, |el, shortcut| {
                    el.child(popover::kbd_hint(&theme, &shortcut))
                })
                .child(div().w(px(14.0)).flex_none().when(row.active, |el| {
                    el.child(icon(icons::CHECK).size(px(14.0)).text_color(theme.text))
                })),
            );
        }
        card = card
            .child(list)
            .child(div().h(px(1.0)).my(px(4.0)).mx(px(4.0)).bg(theme.border));
        for (offset, (label, glyph)) in [
            ("All sessions", icons::WIDGET),
            ("New session", icons::PLUS),
        ]
        .into_iter()
        .enumerate()
        {
            let ix = rows.len() + offset;
            card = card.child(
                popover::menu_row_nav(
                    &theme,
                    false,
                    selected == ix,
                    format!("session-quick-action-{offset}"),
                )
                .id(("session-quick-action", offset))
                .min_h(px(32.0))
                .role(gpui::Role::Button)
                .aria_label(label)
                .on_mouse_move(cx.listener(move |this, _, _, cx| {
                    if let Some(menu) = this.session_quick_switcher.popup.open_mut()
                        && menu.selected != ix
                    {
                        menu.selected = ix;
                        cx.notify();
                    }
                }))
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.activate_workspace_session_quick_choice(ix, window, cx)
                }))
                .child(icon(glyph).size(px(15.0)).text_color(theme.text_muted))
                .child(label),
            );
        }
        card.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gpui::test]
    fn workspace_session_quick_switcher_activates_across_project_filters_and_parks_draft(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
            let original = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.create_workspace_session(cx);
            let other = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.chat_tabs[shell.chat_tab].project = Some("b".into());
            shell.activate_workspace_session(&original, cx);
            shell.workspace_new_chat(cx);
            shell.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Keep this draft".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            shell.settings.space_filter = Some("a".into());
            shell.open_workspace_session_quick_switcher(window, cx);
            assert!(shell.overlay_owns_keyboard(cx));
            let choice = shell
                .workspace_session_sidebar_rows(cx)
                .iter()
                .position(|row| row.id == other)
                .unwrap();
            shell.activate_workspace_session_quick_choice(choice, window, cx);
            assert!(!shell.session_quick_switcher.is_open());
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, other);
            shell.activate_workspace_session(&original, cx);
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "Keep this draft"
            );
        })
        .unwrap();
    }

    #[gpui::test]
    fn workspace_session_quick_switcher_dismiss_returns_focus_without_navigation(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            let original = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.render_workspace_session_quick_switcher(&Theme::default(), cx);
            shell.open_workspace_session_quick_switcher(window, cx);
            assert!(shell.dismiss_workspace_session_quick_switcher(window, cx));
            assert!(
                shell
                    .session_quick_switcher
                    .trigger
                    .as_ref()
                    .unwrap()
                    .is_focused(window)
            );
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, original);
            assert!(!shell.dismiss_workspace_session_quick_switcher(window, cx));
        })
        .unwrap();
    }

    #[gpui::test]
    fn workspace_session_quick_switcher_releases_keyboard_when_its_header_leaves(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.settings.sidebar_collapsed = true;
            shell.open_workspace_session_quick_switcher(window, cx);
            shell.toggle_sidebar(cx);
            assert!(!shell.session_quick_switcher.is_open());
            shell.open_workspace_session_quick_switcher(window, cx);
            shell.open_settings(SettingsSection::Devices, cx);
            assert!(!shell.session_quick_switcher.is_open());
            assert!(shell.settings_search.as_ref().unwrap().focus_pending);
            shell.route = Route::Chat;
            shell.open_workspace_session_quick_switcher(window, cx);
            shell.apply_nav(NavEntry::Settings(SettingsSection::Devices), cx);
            assert!(!shell.session_quick_switcher.is_open());
        })
        .unwrap();
    }

    #[gpui::test]
    fn workspace_session_quick_switcher_footer_opens_overview_or_fresh_session(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            let count = shell.chat_tabs.len();
            shell.render_workspace_session_quick_switcher(&Theme::default(), cx);
            shell.open_workspace_session_quick_switcher(window, cx);
            let _menu = shell.render_workspace_session_quick_menu(&Theme::default(), cx);
            shell.activate_workspace_session_quick_choice(count, window, cx);
            assert!(shell.session_overview);
            assert_eq!(shell.chat_tabs.len(), count);
            shell.close_session_overview(window, cx);
            assert!(
                shell
                    .session_quick_switcher
                    .trigger
                    .as_ref()
                    .unwrap()
                    .is_focused(window)
            );
            shell.open_workspace_session_quick_switcher(window, cx);
            shell.activate_workspace_session_quick_choice(count + 1, window, cx);
            assert!(!shell.session_overview);
            assert_eq!(shell.chat_tabs.len(), count + 1);
            assert!(!shell.session_quick_switcher.is_open());
        })
        .unwrap();
    }
}
