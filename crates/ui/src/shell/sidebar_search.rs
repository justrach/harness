//! On-demand session-name search beside the sidebar's project filter.
//! Search is a local projection: opening an archived result never restores it.
use super::*;
use harness_proto::Chat;

fn search_icon(theme: &Theme, size: f32) -> gpui::Svg {
    // SVG painting requires a local foreground; parent text color is not
    // inherited by Svg::paint. Match the adjacent sidebar control icons.
    icon(icons::MAGNIFER)
        .size(px(size))
        .text_color(theme.text_muted)
}

pub(super) struct SidebarSearch {
    input: Entity<ComposerInput>,
    focus: FocusHandle,
    clear_focus: FocusHandle,
    archive_focus: FocusHandle,
    include_archived: bool,
    project: Option<String>,
    active: usize,
    active_id: Option<String>,
    keyboard_selection: bool,
    pressed_keys: std::collections::HashSet<String>,
    focus_pending: bool,
    scroll: gpui::ScrollHandle,
    _events: Subscription,
    _focus_out: Subscription,
    _activation: Subscription,
}

fn matching_chats<'a>(
    chats: &'a [Chat],
    query: &str,
    project: Option<&str>,
    include_archived: bool,
    sort: SidebarSort,
) -> Vec<&'a Chat> {
    let query = query.trim().to_lowercase();
    let mut matches: Vec<_> = chats
        .iter()
        .filter(|chat| chat.parent_chat_id.is_none())
        .filter(|chat| include_archived || !chat.archived)
        .filter(|chat| project.is_none_or(|id| chat.space_id.as_deref() == Some(id)))
        .filter(|chat| {
            chat.title
                .as_deref()
                .unwrap_or("New session")
                .to_lowercase()
                .contains(&query)
                || chat.id.to_lowercase().contains(&query)
        })
        .collect();
    matches.sort_by(|left, right| spaces::compare_sidebar_chats(sort, left, right));
    matches
}

impl Shell {
    pub(super) fn render_sidebar_search_trigger(
        &self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let open = self.sidebar_search.is_some();
        div()
            .id("sidebar-search-toggle")
            .debug_selector(|| "sidebar-search-toggle".into())
            .role(gpui::Role::Button)
            .aria_label("Search sessions")
            .aria_expanded(open)
            .track_focus(&self.sidebar_search_trigger_focus)
            .size(px(29.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(8.0))
            .border_1()
            .border_color(theme.border.opacity(0.0))
            .focus_visible(|el| el.border_color(theme.border_strong))
            .cursor_pointer()
            .text_color(theme.text_muted)
            .bg(if open {
                theme.glass_hover()
            } else {
                theme.glass_hover().opacity(0.0)
            })
            .hover(|el| el.bg(theme.glass_hover()))
            // Use GPUI's native release-to-click path: one physical press
            // toggles once, even when X11 repeats keydown without is_held.
            // It also rejects modified keys and presses interrupted by focus.
            .on_click(cx.listener(|this, _, window, cx| {
                this.toggle_sidebar_search(window, cx);
            }))
            .capture_key_down(|event: &gpui::KeyDownEvent, window, _| {
                if event.is_held {
                    // Reject repeats before GPUI records a pending click. A
                    // real initial press remains pending until its release.
                    window.prevent_default();
                }
            })
            .child(search_icon(theme, 16.0).debug_selector(|| "sidebar-search-trigger-icon".into()))
            .into_any_element()
    }

    pub(super) fn sidebar_search_has_focus(&self, window: &Window, cx: &App) -> bool {
        self.sidebar_search
            .as_ref()
            .is_some_and(|search| search.focus.contains_focused(window, cx))
    }

    pub(super) fn sidebar_search_is_filtering(&self, cx: &App) -> bool {
        self.sidebar_search.as_ref().is_some_and(|search| {
            search.include_archived || !search.input.read(cx).text().trim().is_empty()
        })
    }

    pub(super) fn sidebar_search_ids(&self, cx: &App) -> Vec<String> {
        let Some(search) = &self.sidebar_search else {
            return Vec::new();
        };
        matching_chats(
            &self.state.read(cx).chats,
            search.input.read(cx).text(),
            self.settings.space_filter.as_deref(),
            search.include_archived,
            self.settings.sidebar_sort,
        )
        .into_iter()
        .map(|chat| chat.id.clone())
        .collect()
    }

    pub(super) fn toggle_sidebar_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.sidebar_search.take().is_some() {
            window.focus(&self.sidebar_search_trigger_focus, cx);
        } else {
            self.cancel_sidebar_session_transfer(cx);
            self.cancel_pinned_session_drag(cx);
            self.command_palette = None;
            self.close_spaces_menu(cx);
            self.close_sidebar_view_menu(cx);
            let input = cx.new(|cx| {
                ComposerInput::with_context("Search names or session IDs…", "PaletteSearch", cx)
                    .with_single_line()
                    .with_accessibility_role(gpui::Role::SearchInput)
                    .with_tab_stop(true)
            });
            let events = cx.subscribe(&input, |this, _, event, cx| {
                if matches!(event, ComposerInputEvent::Edited) {
                    this.reset_sidebar_search(cx);
                }
            });
            let focus = cx.focus_handle();
            let focus_out = cx.on_focus_out(&focus, window, |this, _, _, _| {
                if let Some(search) = this.sidebar_search.as_mut() {
                    search.pressed_keys.clear();
                }
            });
            let activation = cx.observe_window_activation(window, |this, window, _| {
                if !window.is_window_active() {
                    if let Some(search) = this.sidebar_search.as_mut() {
                        search.pressed_keys.clear();
                    }
                }
            });
            window.focus(&input.focus_handle(cx), cx);
            self.sidebar_search = Some(SidebarSearch {
                input,
                focus,
                clear_focus: cx.focus_handle().tab_stop(true),
                archive_focus: cx.focus_handle().tab_stop(true),
                include_archived: false,
                project: self.settings.space_filter.clone(),
                active: 0,
                active_id: None,
                keyboard_selection: false,
                pressed_keys: Default::default(),
                focus_pending: true,
                scroll: gpui::ScrollHandle::new(),
                _events: events,
                _focus_out: focus_out,
                _activation: activation,
            });
        }
        cx.notify();
    }

    pub(super) fn focus_sidebar_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if matches!(self.route, Route::Chat) && !self.settings.sidebar_collapsed {
            if let Some(search) = self.sidebar_search.as_mut() {
                if std::mem::take(&mut search.focus_pending) {
                    window.focus(&search.input.focus_handle(cx), cx);
                }
            }
        }
    }

    fn sync_sidebar_search_scope(&mut self, cx: &mut Context<Self>) {
        if let Some(search) = self.sidebar_search.as_mut() {
            if search.project != self.settings.space_filter {
                search.project = self.settings.space_filter.clone();
                self.reset_sidebar_search(cx);
            }
        }
    }

    fn reset_sidebar_search(&mut self, cx: &mut Context<Self>) {
        if let Some(search) = self.sidebar_search.as_mut() {
            search.active = 0;
            search.active_id = None;
            search.keyboard_selection = false;
            search.scroll.set_offset(gpui::Point::default());
        }
        cx.notify();
    }

    /// Keep the cursor on a session, not its old position in a live sort.
    /// A disappearing target is reported so Enter before the next paint cannot
    /// silently open the row that happened to replace it.
    fn reconcile_sidebar_search(&mut self, ids: &[String], cx: &App) -> bool {
        let Some(search) = self.sidebar_search.as_mut() else {
            return false;
        };
        // Archive-only browsing paints the current session as selected until
        // the user navigates. Follow that session even when another tab changes
        // selection, but never override an explicit keyboard choice.
        if !search.keyboard_selection && search.input.read(cx).text().trim().is_empty() {
            if let Some(selected) = self.state.read(cx).selected_chat.as_ref() {
                if ids.contains(selected) {
                    search.active_id = Some(selected.clone());
                }
            }
        }
        let position = search
            .active_id
            .as_ref()
            .and_then(|id| ids.iter().position(|item| item == id));
        let disappeared = search.active_id.is_some() && position.is_none();
        let previous = search.active;
        search.active = position.unwrap_or_else(|| search.active.min(ids.len().saturating_sub(1)));
        search.active_id = ids.get(search.active).cloned();
        if previous != search.active {
            search.scroll.scroll_to_item(search.active);
        }
        disappeared
    }

    fn sidebar_search_control_press(&mut self, event: &gpui::KeyDownEvent) -> bool {
        let Some(search) = self.sidebar_search.as_mut() else {
            return false;
        };
        // X11 may send repeat keydowns with is_held=false. Only a release (or
        // focus loss) makes a discrete search action available again.
        search.pressed_keys.insert(event.keystroke.key.clone()) && !event.is_held
    }

    fn clear_sidebar_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(search) = self.sidebar_search.as_mut() {
            search.include_archived = false;
            search.input.update(cx, |input, cx| input.set_text("", cx));
            window.focus(&search.input.focus_handle(cx), cx);
        }
        self.reset_sidebar_search(cx);
    }

    pub(super) fn sidebar_search_key(
        &mut self,
        event: &gpui::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Only bare keys belong to result navigation. Modified keys remain
        // available to text editing, platform shortcuts, and parent controls.
        if event.keystroke.modifiers.modified() {
            return;
        }
        self.sync_sidebar_search_scope(cx);
        match event.keystroke.key.as_str() {
            "escape" => {
                if !self.sidebar_search_control_press(event) {
                    cx.stop_propagation();
                    return;
                }
                if self.sidebar_search.as_ref().is_some_and(|search| {
                    search.include_archived || !search.input.read(cx).text().is_empty()
                }) {
                    self.clear_sidebar_search(window, cx);
                } else {
                    self.toggle_sidebar_search(window, cx);
                }
            }
            "up" | "down" if self.sidebar_search_is_filtering(cx) => {
                let ids = self.sidebar_search_ids(cx);
                self.reconcile_sidebar_search(&ids, cx);
                let count = ids.len();
                if let Some(search) = self.sidebar_search.as_mut() {
                    if count > 0 {
                        let current = search.active.min(count - 1);
                        search.active = if event.keystroke.key == "down" {
                            (current + 1) % count
                        } else {
                            (current + count - 1) % count
                        };
                        search.active_id = ids.get(search.active).cloned();
                        search.keyboard_selection = true;
                        search.scroll.scroll_to_item(search.active);
                        cx.notify();
                    }
                }
            }
            "enter" if self.sidebar_search_is_filtering(cx) => {
                let ids = self.sidebar_search_ids(cx);
                let disappeared = self.reconcile_sidebar_search(&ids, cx);
                if disappeared {
                    cx.notify();
                }
                if self.sidebar_search_control_press(event) && !disappeared {
                    if let Some(id) = self
                        .sidebar_search
                        .as_ref()
                        .and_then(|search| ids.get(search.active.min(ids.len().saturating_sub(1))))
                    {
                        self.open_chat_in_tab(id.clone(), window, cx);
                    }
                }
            }
            _ => return,
        }
        cx.stop_propagation();
    }

    pub(super) fn render_sidebar_search_controls(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let search = self.sidebar_search.as_ref()?;
        let input = search.input.clone();
        let has_query = !input.read(cx).text().is_empty();
        let include_archived = search.include_archived;
        let clear_focus = search.clear_focus.clone();
        let archive_focus = search.archive_focus.clone();
        let controls = div()
            .id("sidebar-search-controls")
            .debug_selector(|| "sidebar-search-controls".into())
            .track_focus(&search.focus)
            .key_context("SidebarSearch")
            .flex_none()
            .mx(px(Theme::SPACE_SM))
            .on_key_down(cx.listener(Self::sidebar_search_key))
            .capture_key_up(cx.listener(|this, event: &gpui::KeyUpEvent, window, _| {
                if let Some(search) = this.sidebar_search.as_mut() {
                    if search.pressed_keys.remove(&event.keystroke.key) {
                        // Child controls already handled this keydown. Prevent
                        // their native keyboard-click fallback from firing too.
                        window.prevent_default();
                    }
                }
            }))
            .child(
                div()
                    .debug_selector(|| "sidebar-search-field".into())
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .h(px(32.0))
                    .px(px(8.0))
                    .rounded(px(6.0))
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.surface)
                    .child(
                        search_icon(theme, 14.0)
                            .debug_selector(|| "sidebar-search-field-icon".into()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(crate::typography::ui_rems(12.0))
                            .child(input),
                    )
                    .when(has_query || include_archived, |row| {
                        row.child(
                            div()
                                .id("sidebar-search-clear")
                                .debug_selector(|| "sidebar-search-clear".into())
                                .role(gpui::Role::Button)
                                .aria_label("Clear session search")
                                .track_focus(&clear_focus)
                                .size(px(18.0))
                                .rounded(px(3.0))
                                .flex()
                                .items_center()
                                .justify_center()
                                .cursor_pointer()
                                .text_color(theme.text_muted)
                                .hover(|el| el.bg(theme.glass_hover()))
                                .on_click(cx.listener(|this, event, window, cx| {
                                    if !matches!(event, gpui::ClickEvent::Keyboard(_)) {
                                        this.clear_sidebar_search(window, cx);
                                    }
                                }))
                                .on_key_down(cx.listener(
                                    |this, event: &gpui::KeyDownEvent, window, cx| {
                                        if matches!(event.keystroke.key.as_str(), "enter" | "space")
                                        {
                                            if !event.keystroke.modifiers.modified()
                                                && this.sidebar_search_control_press(event)
                                            {
                                                this.clear_sidebar_search(window, cx);
                                            }
                                            cx.stop_propagation();
                                        }
                                    },
                                ))
                                .child(
                                    icon(icons::CLOSE)
                                        .size(px(12.0))
                                        .text_color(theme.text_muted),
                                ),
                        )
                    }),
            )
            .child(
                div()
                    .id("sidebar-search-archived")
                    .debug_selector(|| "sidebar-search-archived".into())
                    .role(gpui::Role::CheckBox)
                    .aria_label(if include_archived {
                        "Include archived sessions, checked"
                    } else {
                        "Include archived sessions, unchecked"
                    })
                    .track_focus(&archive_focus)
                    .h(px(28.0))
                    .px(px(Theme::SPACE_SM))
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .text_size(crate::typography::ui_rems(11.0))
                    .line_height(px(16.0))
                    .text_color(theme.text_muted)
                    .cursor_pointer()
                    .on_click(cx.listener(|this, event, _, cx| {
                        if !matches!(event, gpui::ClickEvent::Keyboard(_)) {
                            this.toggle_sidebar_search_archived(cx);
                        }
                    }))
                    .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            if !event.keystroke.modifiers.modified()
                                && this.sidebar_search_control_press(event)
                            {
                                this.toggle_sidebar_search_archived(cx);
                            }
                            cx.stop_propagation();
                        }
                    }))
                    .child(
                        div()
                            .debug_selector(|| "sidebar-search-checkbox".into())
                            .size(px(14.0))
                            .flex_none()
                            .rounded(px(3.0))
                            .border_1()
                            .border_color(if include_archived {
                                theme.accent
                            } else {
                                theme.border_strong
                            })
                            .flex()
                            .items_center()
                            .justify_center()
                            .when(include_archived, |el| {
                                el.child(icon(icons::CHECK).size(px(10.0)).text_color(theme.accent))
                            }),
                    )
                    .child(
                        div()
                            .debug_selector(|| "sidebar-search-archive-label".into())
                            .child("Include archived sessions"),
                    ),
            );
        Some(controls.into_any_element())
    }

    fn toggle_sidebar_search_archived(&mut self, cx: &mut Context<Self>) {
        if let Some(search) = self.sidebar_search.as_mut() {
            search.include_archived = !search.include_archived;
        }
        self.reset_sidebar_search(cx);
    }

    pub(super) fn render_sidebar_search_results(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.sync_sidebar_search_scope(cx);
        if !self.sidebar_search_is_filtering(cx) {
            return None;
        }
        let search = self.sidebar_search.as_ref()?;
        let scroll = search.scroll.clone();
        let query = search.input.read(cx).text().trim().to_string();
        let now = Utc::now();
        let data: Vec<_> = {
            let state = self.state.read(cx);
            matching_chats(
                &state.chats,
                &query,
                self.settings.space_filter.as_deref(),
                search.include_archived,
                self.settings.sidebar_sort,
            )
            .into_iter()
            .map(|chat| {
                let project = state
                    .space_for_chat(chat)
                    .map(|space| space.display_name())
                    .unwrap_or("~");
                let folder = match state.device_name(&chat.device_id) {
                    Some(device) => format!("{project} @ {device}"),
                    None => project.to_string(),
                };
                let folder = if chat.archived {
                    format!("Archived · {folder}")
                } else {
                    folder
                };
                (chat.clone(), folder, state.display_status_for(chat, now))
            })
            .collect()
        };
        let count = data.len();
        let ids: Vec<_> = data.iter().map(|(chat, _, _)| chat.id.clone()).collect();
        self.reconcile_sidebar_search(&ids, cx);
        let search = self.sidebar_search.as_ref()?;
        let active = search.active;
        let keyboard_selection = search.keyboard_selection;
        let selected_chat = self.state.read(cx).selected_chat.clone();
        let rows = data
            .into_iter()
            .enumerate()
            .map(|(index, (chat, folder, status))| {
                let row = self.render_chat_row(
                    chat.id.clone(),
                    transcript::single_line(chat.title.as_deref().unwrap_or("New session")).into(),
                    format_time_ago(chat.last_message_at.unwrap_or(chat.created_at), now).into(),
                    folder.into(),
                    None,
                    None,
                    self.settings
                        .sidebar_show_harness
                        .then(|| chat.config.as_ref().map(|c| c.harness))
                        .flatten(),
                    status,
                    if query.is_empty() && !keyboard_selection {
                        selected_chat.as_deref() == Some(chat.id.as_str())
                    } else {
                        index == active
                    },
                    chat.archived,
                    false,
                    None,
                    None,
                    Some(ChatRowSearch::Sidebar(&query)),
                    theme,
                    cx,
                );
                let result_id = chat.id.clone();
                div()
                    .id(("sidebar-search-result", index))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, _, _, cx| {
                            if let Some(search) = this.sidebar_search.as_mut() {
                                search.active = index;
                                search.active_id = Some(result_id.clone());
                                cx.notify();
                            }
                        }),
                    )
                    .child(row)
                    .into_any_element()
            })
            .collect::<Vec<_>>();
        let list = div()
            .id("sidebar-search-results")
            .debug_selector(|| "sidebar-search-results".into())
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .track_scroll(&scroll)
            .flex()
            .flex_col()
            .gap(px(SIDEBAR_LIST_GAP))
            .children(rows)
            .when(count == 0, |el| {
                el.child(
                    div()
                        .id("sidebar-search-empty")
                        .debug_selector(|| "sidebar-search-empty".into())
                        .px(px(8.0))
                        .py(px(24.0))
                        .flex()
                        .flex_col()
                        .gap(px(6.0))
                        .text_size(crate::typography::ui_rems(12.0))
                        .child("No matching sessions")
                        .child(
                            div()
                                .text_color(theme.text_muted)
                                .child("Try another name, session ID, or project."),
                        ),
                )
            });
        Some(
            div()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .px(px(Theme::SPACE_SM))
                .child(
                    div()
                        .flex_none()
                        .px(px(8.0))
                        .py(px(6.0))
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted)
                        .child(SharedString::from(format!(
                            "{} {}",
                            count,
                            if count == 1 { "result" } else { "results" }
                        ))),
                )
                .child(
                    crate::edge_fade::edge_faded(SIDEBAR_GLASS_FADE_BAND, true, true, list)
                        .fade_overflow_y(&scroll),
                )
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests;
