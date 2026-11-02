//! The overview follows independent workspace sessions, each with its own panels
//! and tabs. Project association never merges two session cards.
use super::*;

use super::session_overview_data::{OverviewActivity, overview_activity};

#[cfg(test)]
#[path = "session_overview_tests.rs"]
mod regression_tests;

#[cfg(test)]
#[path = "session_overview_reorder_tests.rs"]
mod reorder_tests;

#[derive(Clone)]
struct OverviewSessionDrag {
    session: String,
    title: SharedString,
}

#[derive(Clone)]
struct OverviewThread {
    id: String,
    session: String,
    indicator: harness_proto::ChatIndicator,
    activity: OverviewActivity,
}

struct OverviewSession {
    id: String,
    project: Option<String>,
    panel_count: usize,
    tab_count: usize,
    name: String,
    threads: Vec<OverviewThread>,
    summary: String,
}

#[derive(Default)]
pub(super) struct OverviewRuntime {
    active: bool,
    sessions: Vec<String>,
    watched: std::collections::HashSet<String>,
    updates: std::collections::HashMap<String, (String, std::time::Instant)>,
    question: Option<OverviewQuestion>,
    composer_observer: Option<Subscription>,
    text_observer: Option<Subscription>,
    clock: Option<Task<()>>,
    drag_scroll: Option<Task<()>>,
    drag_scroll_delta: f32,
}

#[derive(Clone)]
struct OverviewQuestion {
    chat: String,
    request: Option<String>,
    focus_pending: bool,
}

fn priority(indicator: harness_proto::ChatIndicator) -> u8 {
    use harness_proto::ChatIndicator::*;
    match indicator {
        AwaitingInput => 0,
        Errored => 1,
        Working => 2,
        Completed => 3,
        Idle => 4,
    }
}

fn status_label(indicator: harness_proto::ChatIndicator) -> &'static str {
    use harness_proto::ChatIndicator::*;
    match indicator {
        AwaitingInput => "Needs you",
        Errored => "Needs attention",
        Working => "Working",
        Completed => "Done",
        Idle => "Ready",
    }
}

fn status_style(
    indicator: harness_proto::ChatIndicator,
    theme: &Theme,
) -> (&'static str, gpui::Hsla) {
    use harness_proto::ChatIndicator::*;
    match indicator {
        AwaitingInput => (icons::INFO_CIRCLE, theme.warning),
        Errored => (icons::DANGER_TRIANGLE, theme.danger),
        Working => (icons::REFRESH, theme.accent),
        Completed => (icons::CHECK, theme.success),
        Idle => (icons::CLOCK_CIRCLE, theme.text_muted),
    }
}

fn overview_columns(width: f32) -> usize {
    if width >= 1000.0 {
        3
    } else if width >= 700.0 {
        2
    } else {
        1
    }
}

fn overview_card_width(width: f32) -> f32 {
    let columns = overview_columns(width);
    ((width - 64.0 - 20.0 * (columns - 1) as f32) / columns as f32)
        .floor()
        .max(0.0)
}

impl Shell {
    pub(super) fn session_name(&self, project: Option<&str>, cx: &App) -> String {
        let state = self.state.read(cx);
        project
            .and_then(|id| state.space_row(id))
            .map(|space| transcript::single_line(space.display_name()))
            .unwrap_or_else(|| "Scratchpad".into())
    }

    pub(super) fn open_session_overview(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !matches!(self.route, Route::Chat) || self.session_overview {
            return;
        }
        self.ensure_workspace_sessions(cx);
        self.persist_chat_tabs(cx);
        self.close_spaces_menu(cx);
        self.close_sidebar_view_menu(cx);
        self.session_overview_return_focus = window.focused(cx);
        self.session_overview = true;
        self.prepare_overview(cx);
        window.focus(&self.session_overview_focus, cx);
        cx.notify();
    }

    pub(super) fn close_session_overview(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session_overview = false;
        self.release_session_overview(cx);
        if let Some(focus) = self.session_overview_return_focus.take() {
            window.focus(&focus, cx);
        } else {
            window.focus(&self.composer.focus_handle(cx), cx);
        }
        cx.notify();
    }

    pub(super) fn render_session_switcher(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let name = self.session_name(self.active_project(cx).as_deref(), cx);
        let open = self.spaces_menu.is_open();
        let label: SharedString = name.clone().into();
        let trigger = div()
            .id("session-switcher")
            .debug_selector(|| "session-switcher".into())
            .role(gpui::Role::Button)
            .aria_label(format!("{name}, switch project"))
            .aria_expanded(open)
            .track_focus(&self.session_switcher_focus)
            .focus_visible(|el| el.bg(theme.glass_hover()))
            .flex_1()
            .min_w_0()
            .h(px(38.0))
            .px(px(NAV_ITEM_INSET_X))
            .flex()
            .items_center()
            .gap(px(6.0))
            .rounded(px(7.0))
            .text_size(crate::typography::ui_rems(20.0))
            .font_weight(gpui::FontWeight::MEDIUM)
            .text_color(theme.text)
            .cursor_pointer()
            .hover(|el| el.bg(theme.glass_hover()))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.spaces_menu.note_trigger_press()),
            )
            .on_click(cx.listener(|this, _, window, cx| {
                if this.spaces_menu.take_press_was_open() {
                    this.close_spaces_menu(cx);
                } else {
                    this.open_spaces_menu(window, cx);
                }
            }))
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if matches!(
                    event.keystroke.key.as_str(),
                    "enter" | "space" | "down" | "arrowdown"
                ) {
                    this.open_spaces_menu(window, cx);
                    cx.stop_propagation();
                }
            }))
            .when(!open, |el| {
                el.tooltip(move |_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: label.clone(),
                    })
                    .into()
                })
            })
            .child(div().min_w_0().truncate().child(name))
            .child(
                icon(icons::ALT_ARROW_DOWN)
                    .size(px(14.0))
                    .flex_none()
                    .text_color(theme.text_muted),
            );
        let overview = self.render_all_sessions_button("all-sessions", theme, cx);
        let row = div()
            .relative()
            .flex()
            .items_center()
            .gap(px(4.0))
            .child(trigger)
            .child(overview);
        let row = if self.spaces_menu.get().is_some() {
            let closing = self.spaces_menu.closing_since();
            row.child(popover::anchored_menu_below(
                "session-switcher-menu",
                self.render_spaces_menu(theme, cx),
                closing,
            ))
        } else {
            row
        };
        // Anchor inside the same gutters as the sidebar's navigation rows.
        div()
            .px(px(SIDEBAR_GUTTER))
            .pt(px(6.0))
            .child(row)
            .into_any_element()
    }

    pub(super) fn render_all_sessions_button(
        &mut self,
        id: &'static str,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let focus = self
            .session_overview_controls
            .entry(id.into())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        window_control_button(
            id,
            icons::WIDGET,
            theme,
            cx.listener(|this, _, window, cx| this.open_session_overview(window, cx)),
        )
        .role(gpui::Role::Button)
        .aria_label("All sessions")
        .track_focus(&focus)
        .focus_visible(|el| el.bg(theme.glass_hover()))
        .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                this.open_session_overview(window, cx);
                cx.stop_propagation();
            }
        }))
        .tooltip(|_, cx| {
            cx.new(|_| SurfaceTabTooltip {
                text: "All sessions".into(),
            })
            .into()
        })
        .into_any_element()
    }

    fn overview_sessions(&self, cx: &App) -> Vec<OverviewSession> {
        let state = self.state.read(cx);
        let rows = self.workspace_session_sidebar_rows(cx);
        // Preserve the admitted order while task statuses change; newly created
        // sessions append, and a closed session disappears immediately.
        let mut order: Vec<_> = self
            .session_overview_runtime
            .sessions
            .iter()
            .filter(|id| rows.iter().any(|row| &row.id == *id))
            .cloned()
            .collect();
        for row in &rows {
            if !order.contains(&row.id) {
                order.push(row.id.clone());
            }
        }
        if self.session_overview_runtime.sessions.is_empty() {
            order.sort_by_key(|id| {
                self.settings
                    .session_overview_order
                    .iter()
                    .position(|saved| saved.as_ref() == Some(id))
                    .unwrap_or(usize::MAX)
            });
        }
        order.sort_by_key(|id| !rows.iter().any(|row| row.id == *id && row.pinned));
        let now = Utc::now();
        order
            .into_iter()
            .filter_map(|id| {
                let row = rows.iter().find(|row| row.id == id)?;
                let tab = self.chat_tabs.iter().find(|tab| tab.id == id)?;
                let layout = self.workspace_panels.layouts.get(&id);
                let mut chat_ids = Vec::new();
                if let Some(layout) = layout {
                    for panel in &layout.panels {
                        for tab in &panel.tabs {
                            if let workspace_panels::PanelTab::Chat(chat) = tab
                                && !chat_ids.contains(chat)
                            {
                                chat_ids.push(chat.clone());
                            }
                        }
                    }
                } else {
                    chat_ids = tab.chats();
                }
                let panel_count = layout.map_or_else(
                    || tab.split.as_ref().map_or(1, |split| split.panes.len()),
                    |layout| layout.panels.len(),
                );
                let tab_count = layout.map_or_else(
                    || chat_ids.len().max(usize::from(tab.draft.is_some())),
                    |layout| layout.panels.iter().map(|panel| panel.tabs.len()).sum(),
                );
                let mut threads: Vec<_> = chat_ids
                    .into_iter()
                    .filter_map(|chat_id| {
                        let chat = state
                            .chats
                            .iter()
                            .find(|chat| chat.id == chat_id && !chat.archived)?;
                        let indicator = state.display_status_for(chat, now);
                        let activity = overview_activity(
                            chat,
                            indicator,
                            state.overview_transcript(&chat.id),
                            now,
                        );
                        Some(OverviewThread {
                            id: chat.id.clone(),
                            session: id.clone(),
                            indicator: if activity.pending_question {
                                harness_proto::ChatIndicator::AwaitingInput
                            } else {
                                indicator
                            },
                            activity,
                        })
                    })
                    .collect();
                threads.sort_by_key(|thread| priority(thread.indicator));
                let summary = threads
                    .first()
                    .map(|thread| thread.activity.update.clone())
                    .unwrap_or_else(|| "No activity yet.".into());
                Some(OverviewSession {
                    id,
                    project: row.project.clone(),
                    name: row.title.clone(),
                    threads,
                    summary,
                    panel_count,
                    tab_count,
                })
            })
            .collect()
    }

    fn move_overview_session(&mut self, session: &str, target: &str, cx: &mut Context<Self>) {
        if !self.session_overview
            || self.session_overview_runtime.question.is_some()
            || self.add_space.is_some()
            || self.command_palette.is_some()
        {
            return;
        }
        let mut order: Vec<_> = self
            .overview_sessions(cx)
            .into_iter()
            .map(|session| session.id)
            .collect();
        let Some(from) = order.iter().position(|id| id == session) else {
            return;
        };
        let Some(to) = order.iter().position(|id| id == target) else {
            return;
        };
        if from == to {
            return;
        }
        self.session_overview_runtime.drag_scroll = None;
        self.session_overview_runtime.drag_scroll_delta = 0.0;
        // Older versions saved overview order separately from sidebar order.
        // Move within the order on screen before updating their shared state.
        let moved = order.remove(from);
        order.insert(to, moved);
        let pinned = self
            .chat_tabs
            .iter()
            .find(|tab| tab.id == target)
            .is_some_and(|tab| tab.pinned);
        if let Some(tab) = self.chat_tabs.iter_mut().find(|tab| tab.id == session) {
            tab.pinned = pinned;
        }
        self.apply_workspace_session_order(order.clone(), cx);
        self.session_overview_runtime.sessions = order;
        cx.notify();
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_overview_project_order(&self, cx: &App) -> Vec<Option<String>> {
        self.overview_sessions(cx)
            .into_iter()
            .map(|session| Some(session.id))
            .collect()
    }

    fn track_overview_drag_scroll(
        &mut self,
        event: &gpui::DragMoveEvent<OverviewSessionDrag>,
        cx: &mut Context<Self>,
    ) {
        let delta = if event.bounds.contains(&event.event.position) {
            spaces::pinned_drag_scroll_delta(
                f32::from(event.event.position.y),
                f32::from(event.bounds.top()),
                f32::from(event.bounds.bottom()),
            )
        } else {
            0.0
        };
        self.session_overview_runtime.drag_scroll_delta = delta;
        if delta == 0.0 || self.session_overview_runtime.drag_scroll.is_some() {
            return;
        }
        self.session_overview_runtime.drag_scroll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(
                        SIDEBAR_DRAG_SCROLL_FRAME_MS,
                    ))
                    .await;
                let keep_running = this
                    .update(cx, |this, cx| {
                        let delta = this.session_overview_runtime.drag_scroll_delta;
                        let offset = this.session_overview_scroll.offset();
                        let max = f32::from(this.session_overview_scroll.max_offset().y);
                        let next = (f32::from(offset.y) - delta).clamp(-max, 0.0);
                        if !this.session_overview
                            || !cx.has_active_drag()
                            || this.session_overview_runtime.question.is_some()
                            || this.add_space.is_some()
                            || this.command_palette.is_some()
                            || delta == 0.0
                            || next == f32::from(offset.y)
                        {
                            this.session_overview_runtime.drag_scroll = None;
                            return false;
                        }
                        this.session_overview_scroll
                            .set_offset(gpui::point(offset.x, px(next)));
                        cx.notify();
                        true
                    })
                    .unwrap_or(false);
                if !keep_running {
                    break;
                }
            }
        }));
    }

    /// Reuse the split-pane feed ownership so a dashboard never tears down a
    /// watch still used by a pane. Keep the visible final summaries live after
    /// completion, and follow every active task even below the card's fold.
    pub(super) fn overview_live_chats(&self, cx: &App) -> Vec<String> {
        if !self.session_overview {
            return Vec::new();
        }
        self.overview_sessions(cx)
            .into_iter()
            .flat_map(|session| session.threads.into_iter().enumerate())
            .filter(|(index, thread)| {
                matches!(
                    thread.indicator,
                    harness_proto::ChatIndicator::Working
                        | harness_proto::ChatIndicator::AwaitingInput
                ) || (*index < 2 && self.session_overview_runtime.watched.contains(&thread.id))
            })
            .filter(|(_, thread)| self.state.read(cx).selected_chat.as_deref() != Some(&thread.id))
            .map(|(_, thread)| thread.id)
            .collect()
    }

    fn prepare_overview(&mut self, cx: &mut Context<Self>) {
        if self.session_overview_runtime.active {
            return;
        }
        self.session_overview_runtime.active = true;
        self.session_overview_runtime.composer_observer =
            Some(cx.observe(&self.composer, |this, _, cx| {
                if this.session_overview_runtime.question.is_some() {
                    cx.notify();
                }
            }));
        self.session_overview_runtime.text_observer = Some(cx.subscribe(
            &self.state,
            |this, _, _: &crate::state::TranscriptTextChanged, cx| {
                if this.session_overview {
                    cx.notify();
                }
            },
        ));
        self.session_overview_runtime.clock = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_secs(30))
                    .await;
                if !this
                    .update(cx, |this, cx| {
                        if this.session_overview {
                            cx.notify();
                            true
                        } else {
                            false
                        }
                    })
                    .unwrap_or(false)
                {
                    break;
                }
            }
        }));
    }

    pub(super) fn release_session_overview(&mut self, cx: &mut Context<Self>) {
        if !self.session_overview_runtime.active {
            return;
        }
        self.session_overview_runtime = OverviewRuntime::default();
        self.sync_chat_panes(cx);
    }

    pub(super) fn close_overview_question(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.session_overview_runtime.question.take().is_none() {
            return false;
        }
        window.focus(&self.session_overview_focus, cx);
        cx.notify();
        true
    }

    pub(super) fn open_overview_question(
        &mut self,
        chat: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Keep the native composer bound to its normal selected chat. Only its
        // presentation moves; answers still use the existing request pipeline.
        self.open_chat_in_tab(chat.clone(), window, cx);
        self.session_overview = true;
        self.prepare_overview(cx);
        self.session_overview_runtime.question = Some(OverviewQuestion {
            chat,
            request: None,
            focus_pending: true,
        });
        cx.notify();
    }

    fn overview_question_overlay(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let question = self.session_overview_runtime.question.clone()?;
        let state = self.state.read(cx);
        if state.selected_chat.as_deref() != Some(&question.chat) {
            self.close_overview_question(window, cx);
            return None;
        }
        let pending = crate::composer::pending_input_request(&state.transcript).map(|(id, _)| id);
        let expected = pending.as_deref().or(question.request.as_deref());
        // The native wizard stays latched across an empty replay. A known
        // request only ends when it is resolved or a nonempty replay replaces it.
        let ended = expected.is_some_and(|request| {
            crate::composer::input_request_resolved(&state.transcript, request)
                || (state.transcript_replayed && pending.is_none() && !state.transcript.is_empty())
        });
        if ended {
            self.close_overview_question(window, cx);
            return None;
        }
        if let Some(id) = pending.as_ref() {
            self.session_overview_runtime.question.as_mut()?.request = Some(id.clone());
        }
        let theme = Theme::of(cx).clone();
        let viewport = window.viewport_size();
        let width = (f32::from(viewport.width) - 32.0).clamp(240.0, 560.0);
        let height = (f32::from(viewport.height) - 110.0).max(160.0);
        let matches = expected.is_some_and(|request| {
            self.composer.update(cx, |composer, cx| {
                composer.prepare_overview_question(&question.chat, request, cx)
            })
        });
        let panel = if matches {
            self.composer.update(cx, |composer, cx| {
                composer.render_overview_question(width, height, window, cx)
            })
        } else {
            None
        };
        if panel.is_some() && question.focus_pending {
            self.composer.update(cx, |composer, cx| {
                composer.focus_overview_question(window, cx);
            });
            self.session_overview_runtime
                .question
                .as_mut()?
                .focus_pending = false;
        }
        let content = if let Some(panel) = panel {
            panel
        } else {
            let submitted =
                expected.is_some_and(|id| self.composer.read(cx).overview_question_submitted(id));
            let failure = self.composer.read(cx).overview_question_failure();
            let chat = question.chat.clone();
            let keyboard_chat = chat.clone();
            let focus = self
                .session_overview_controls
                .entry("question-open-chat".into())
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            div()
                .p(px(20.0))
                .rounded(px(16.0))
                .bg(theme.bg)
                .text_size(crate::typography::ui_rems(13.0))
                .flex()
                .flex_col()
                .gap(px(12.0))
                .child(failure.unwrap_or_else(|| {
                    if submitted {
                        "Sending answer…"
                    } else {
                        "Opening question…"
                    }
                    .into()
                }))
                .child(
                    popover::btn_ghost(&theme, "Open conversation", "overview-question-open-chat")
                        .id("overview-question-open-chat")
                        .role(gpui::Role::Button)
                        .track_focus(&focus)
                        .focus_visible(|el| el.bg(theme.element_hover))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.overview_open_chat(chat.clone(), window, cx)
                        }))
                        .on_key_down(cx.listener(
                            move |this, event: &gpui::KeyDownEvent, window, cx| {
                                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                    this.overview_open_chat(keyboard_chat.clone(), window, cx);
                                    cx.stop_propagation();
                                }
                            },
                        )),
                )
                .into_any_element()
        };
        let close_focus = self
            .session_overview_controls
            .entry("question-back".into())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let close = popover::btn_ghost(&theme, "Back to all sessions", "overview-question-back")
            .id("overview-question-back")
            .role(gpui::Role::Button)
            .track_focus(&close_focus)
            .focus_visible(|el| el.bg(theme.element_hover))
            .on_click(cx.listener(|this, _, window, cx| {
                this.close_overview_question(window, cx);
            }))
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                    this.close_overview_question(window, cx);
                    cx.stop_propagation();
                }
            }));
        let body = div()
            .w(px(width))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .child(div().flex().justify_end().child(close))
            .child(content);
        Some(popover::modal(
            "overview-question-modal",
            viewport,
            body.into_any_element(),
        ))
    }

    fn overview_open_chat(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.close_session_overview(window, cx);
        self.open_chat_in_tab(id, window, cx);
    }

    fn activate_overview_session_chat(
        &mut self,
        session: &str,
        chat: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.activate_workspace_session(session, cx);
        let panel = self.workspace_panels.layouts.get(session).and_then(|layout| {
            layout.panels.iter().find(|panel| panel.tabs.iter().any(|tab| matches!(tab, workspace_panels::PanelTab::Chat(id) if id == &chat))).map(|panel| panel.id)
        });
        if let Some(panel) = panel {
            self.focus_workspace_tab(panel, workspace_panels::PanelTab::Chat(chat), window, cx);
        } else {
            self.open_chat_in_tab(chat, window, cx);
        }
    }

    fn overview_open_session_chat(
        &mut self,
        session: &str,
        chat: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_session_overview(window, cx);
        self.activate_overview_session_chat(session, chat, window, cx);
    }

    fn open_overview_session_question(
        &mut self,
        session: &str,
        chat: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.activate_overview_session_chat(session, chat.clone(), window, cx);
        self.open_overview_question(chat, window, cx);
    }

    pub(super) fn overview_background_focus(&self, focus: gpui::FocusHandle) -> gpui::FocusHandle {
        focus.tab_stop(
            self.session_overview_runtime.question.is_none()
                && self.add_space.is_none()
                && self.command_palette.is_none(),
        )
    }

    fn overview_task_button(
        &mut self,
        thread: &OverviewThread,
        compact: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = thread.id.clone();
        let keyboard_id = id.clone();
        let session = thread.session.clone();
        let keyboard_session = session.clone();
        let focus = self
            .session_overview_controls
            .entry(format!("chat:{session}:{id}:{compact}"))
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let tip: SharedString = thread.activity.title.clone().into();
        let (glyph, color) = status_style(thread.indicator, theme);
        // A status glyph reports the agent's state; it never presents a
        // checkbox that the user could mistake for a completion control.
        let phase =
            if thread.indicator == harness_proto::ChatIndicator::Working && !self.reduced_motion {
                motion::pulse_delta_slow(&motion::HARNESS_PULSE, cx.entity_id(), cx)
            } else {
                0.0
            };
        let title = div()
            .flex_1()
            .min_w_0()
            .line_clamp(if compact { 1 } else { 2 })
            .text_ellipsis()
            .child(thread.activity.title.clone());
        div()
            .id(SharedString::from(format!(
                "overview-task-{session}-{id}-{compact}"
            )))
            .role(gpui::Role::Button)
            .aria_label(format!(
                "Open {}. {}",
                thread.activity.title,
                status_label(thread.indicator)
            ))
            .track_focus(&self.overview_background_focus(focus))
            .focus_visible(|el| el.bg(theme.element_hover))
            .cursor_pointer()
            .rounded(px(4.0))
            .w_full()
            .flex()
            .items_start()
            .gap(px(10.0))
            .hover(|el| el.bg(theme.element_hover.opacity(0.45)))
            .text_size(crate::typography::ui_rems(if compact {
                13.0
            } else {
                16.0
            }))
            .line_height(px(if compact { 19.0 } else { 22.0 }))
            .font_weight(if compact {
                gpui::FontWeight::NORMAL
            } else {
                gpui::FontWeight::MEDIUM
            })
            .on_click(cx.listener(move |this, _, window, cx| {
                this.overview_open_session_chat(&session, id.clone(), window, cx)
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        this.overview_open_session_chat(
                            &keyboard_session,
                            keyboard_id.clone(),
                            window,
                            cx,
                        );
                        cx.stop_propagation();
                    }
                }),
            )
            .tooltip(move |_, cx| cx.new(|_| SurfaceTabTooltip { text: tip.clone() }).into())
            .child(
                div()
                    .mt(px(if compact { 2.0 } else { 3.5 }))
                    .size(px(15.0))
                    .flex_none()
                    .child(
                        icon(glyph)
                            .size(px(15.0))
                            .text_color(color)
                            .with_transformation(gpui::Transformation::rotate(gpui::percentage(
                                phase,
                            ))),
                    ),
            )
            .child(title)
            .into_any_element()
    }

    pub(super) fn render_session_overview(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.prepare_overview(cx);
        let admitted = self.overview_sessions(cx);
        self.session_overview_runtime.sessions =
            admitted.iter().map(|session| session.id.clone()).collect();
        for thread in admitted.iter().flat_map(|session| &session.threads) {
            if matches!(
                thread.indicator,
                harness_proto::ChatIndicator::Working | harness_proto::ChatIndicator::AwaitingInput
            ) {
                self.session_overview_runtime
                    .watched
                    .insert(thread.id.clone());
            }
        }
        self.sync_chat_panes(cx);
        let theme = Theme::of(cx).clone();
        let width = f32::from(window.viewport_size().width);
        let card_width = overview_card_width(width);
        let sessions = self.overview_sessions(cx);
        let mut working = 0;
        let mut attention = 0;
        let mut completed = 0;
        for thread in sessions.iter().flat_map(|session| &session.threads) {
            match thread.indicator {
                harness_proto::ChatIndicator::Working => working += 1,
                harness_proto::ChatIndicator::AwaitingInput
                | harness_proto::ChatIndicator::Errored => attention += 1,
                harness_proto::ChatIndicator::Completed => completed += 1,
                _ => {}
            }
        }
        let now = std::time::Instant::now();
        let mut cards = Vec::new();
        for session in sessions {
            let session_id = session.id.clone();
            let keyboard_session = session_id.clone();
            let drop_session = session_id.clone();
            let highlight_session = session_id.clone();
            let keyboard_drag_session = session_id.clone();
            let key = format!("session:{session_id}");
            let hover_key: SharedString =
                format!("overview-heading-{}-{key}", cx.entity_id()).into();
            let focus = self
                .session_overview_controls
                .entry(key.clone())
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            let name: SharedString = session.name.clone().into();
            let tip = name.clone();
            let grip_focus = self
                .session_overview_controls
                .entry(format!("reorder:{key}"))
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            let grip_reveal = if grip_focus.is_focused(window) {
                1.0
            } else {
                motion::hover_t(&hover_key)
            };
            let grip = div()
                .id(SharedString::from(format!("overview-reorder-{key}")))
                .debug_selector(move || format!("overview-reorder-{keyboard_drag_session}"))
                .size(px(22.0))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(4.0))
                .opacity(grip_reveal)
                .hover(|el| el.bg(theme.element_hover))
                .cursor(gpui::CursorStyle::OpenHand)
                .role(gpui::Role::Button)
                .aria_label(format!("Reorder {}. Use arrow keys to move.", session.name))
                .track_focus(&self.overview_background_focus(grip_focus))
                .focus_visible(|el| el.opacity(1.0).bg(theme.element_hover))
                .on_mouse_down(MouseButton::Left, |_, window, cx| {
                    window.prevent_default();
                    cx.stop_propagation();
                })
                .on_click(|_, _, cx| cx.stop_propagation())
                .when(
                    self.session_overview_runtime.question.is_none()
                        && self.add_space.is_none()
                        && self.command_palette.is_none(),
                    |el| {
                        el.on_drag(
                            OverviewSessionDrag {
                                session: session_id.clone(),
                                title: name.clone(),
                            },
                            |payload, _, _, cx| {
                                cx.stop_propagation();
                                cx.new(|_| SurfaceTabGhost {
                                    title: payload.title.clone(),
                                })
                            },
                        )
                    },
                )
                .on_key_down(cx.listener({
                    let session_id = session_id.clone();
                    move |this, event: &gpui::KeyDownEvent, window, cx| {
                        let columns = overview_columns(f32::from(window.viewport_size().width));
                        let delta = match event.keystroke.key.as_str() {
                            "left" => -1,
                            "right" => 1,
                            "up" => -(columns as isize),
                            "down" => columns as isize,
                            _ => return,
                        };
                        let order = this.overview_sessions(cx);
                        if let Some(index) = order.iter().position(|row| row.id == session_id)
                            && let Some(target) = index
                                .checked_add_signed(delta)
                                .and_then(|next| order.get(next))
                        {
                            this.move_overview_session(&session_id, &target.id, cx);
                        }
                        cx.stop_propagation();
                    }
                }))
                .tooltip(|_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: "Drag to reorder · Arrow keys when focused".into(),
                    })
                    .into()
                })
                .child(
                    icon(icons::DRAG_HANDLE)
                        .size(px(13.0))
                        .text_color(theme.text_muted),
                );
            let primary = session.threads.first();
            let indicator = primary.map_or(harness_proto::ChatIndicator::Idle, |thread| {
                thread.indicator
            });
            let (glyph, color) = status_style(indicator, &theme);
            let needs = matches!(
                indicator,
                harness_proto::ChatIndicator::AwaitingInput | harness_proto::ChatIndicator::Errored
            );
            let heading = div()
                .id(SharedString::from(format!("overview-heading-{key}")))
                // Only the strip above the sheet reveals the handle. Card
                // contents retain their own pointer and hover behavior.
                .on_hover(motion::hover_listener(hover_key))
                .h(px(22.0))
                .mb(px(9.0))
                .px(px(3.0))
                .flex()
                .items_center()
                .gap(px(8.0))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .items_center()
                        .child(
                            div()
                                .w(px(27.0 * grip_reveal))
                                .h(px(22.0))
                                .flex_none()
                                .overflow_hidden()
                                .child(grip),
                        )
                        .child(
                            div()
                                .id(SharedString::from(format!("overview-open-{key}")))
                                .min_w_0()
                                .truncate()
                                .role(gpui::Role::Button)
                                .aria_label(format!("Open {}. {}", session.name, session.summary))
                                .track_focus(&self.overview_background_focus(focus))
                                .focus_visible(|el| el.bg(theme.element_hover))
                                .cursor_pointer()
                                .text_size(crate::typography::ui_rems(13.0))
                                .font_weight(gpui::FontWeight::MEDIUM)
                                .text_color(theme.text_muted)
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.close_session_overview(window, cx);
                                    this.activate_workspace_session(&session_id, cx);
                                }))
                                .on_key_down(cx.listener(
                                    move |this, event: &gpui::KeyDownEvent, window, cx| {
                                        if matches!(event.keystroke.key.as_str(), "enter" | "space")
                                        {
                                            this.close_session_overview(window, cx);
                                            this.activate_workspace_session(&keyboard_session, cx);
                                            cx.stop_propagation();
                                        }
                                    },
                                ))
                                .tooltip(move |_, cx| {
                                    cx.new(|_| SurfaceTabTooltip { text: tip.clone() }).into()
                                })
                                .child(name),
                        ),
                )
                .child(
                    div()
                        .flex_none()
                        .flex()
                        .items_center()
                        .gap(px(4.0))
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(color)
                        .child(icon(glyph).size(px(13.0)).text_color(color))
                        .child(status_label(indicator)),
                );
            let mut content = div().relative().size_full().p(px(20.0)).flex().flex_col();
            if let Some(thread) = primary {
                let signature = format!(
                    "{}:{:?}:{:?}",
                    thread.id, thread.indicator, thread.activity.update_key
                );
                let update = self
                    .session_overview_runtime
                    .updates
                    .entry(key.clone())
                    .or_insert_with(|| {
                        (signature.clone(), now - std::time::Duration::from_secs(1))
                    });
                if update.0 != signature {
                    *update = (signature, now);
                }
                let progress = (now.duration_since(update.1).as_secs_f32() / 0.22).clamp(0.0, 1.0);
                let animate = progress < 1.0 && !self.reduced_motion;
                if animate {
                    self.motion_active.set(true);
                }
                let summary_tip: SharedString = thread.activity.update.clone().into();
                let summary = div()
                    .id(SharedString::from(format!("overview-status-{}", thread.id)))
                    .ml(px(25.0))
                    .mt(px(6.0))
                    .h(px(38.0))
                    .min_h(px(38.0))
                    .overflow_hidden()
                    .text_size(crate::typography::ui_rems(13.0))
                    .line_height(px(19.0))
                    .text_color(theme.text_muted)
                    .tooltip(move |_, cx| {
                        cx.new(|_| SurfaceTabTooltip {
                            text: summary_tip.clone(),
                        })
                        .into()
                    })
                    .child(
                        div()
                            .line_clamp(2)
                            .text_ellipsis()
                            .child(thread.activity.update.clone()),
                    )
                    .when(animate, |el| {
                        el.relative()
                            .top(px(4.0 * (1.0 - progress)))
                            .opacity(0.4 + 0.6 * progress)
                    });
                content = content
                    .child(
                        div()
                            .min_h(px(22.0))
                            .flex_none()
                            .child(self.overview_task_button(thread, false, &theme, cx)),
                    )
                    .child(summary);
                let mut steps = div()
                    .ml(px(25.0))
                    .mt(px(12.0))
                    .flex_none()
                    .flex()
                    .flex_col();
                // Prefer the current unfinished work when a plan is longer
                // than the card.
                let first_open = thread
                    .activity
                    .checklist
                    .iter()
                    .position(|step| !step.done)
                    .unwrap_or(0);
                let start = first_open
                    .saturating_sub(1)
                    .min(thread.activity.checklist.len().saturating_sub(3));
                for (offset, step) in thread
                    .activity
                    .checklist
                    .iter()
                    .skip(start)
                    .take(3)
                    .enumerate()
                {
                    let tip: SharedString = step.text.clone().into();
                    steps = steps.child(
                        div()
                            .id(SharedString::from(format!(
                                "overview-step-{}-{offset}",
                                thread.id
                            )))
                            .flex()
                            .items_center()
                            .gap(px(8.0))
                            .h(px(28.0))
                            .overflow_hidden()
                            .text_size(crate::typography::ui_rems(13.0))
                            .line_height(px(18.0))
                            .text_color(if step.done {
                                theme.text_muted
                            } else {
                                theme.text
                            })
                            .tooltip(move |_, cx| {
                                cx.new(|_| SurfaceTabTooltip { text: tip.clone() }).into()
                            })
                            .child(div().w(px(14.0)).flex_none().flex().justify_center().child(
                                if step.done {
                                    icon(icons::CHECK)
                                        .size(px(13.0))
                                        .text_color(theme.text_muted)
                                        .into_any_element()
                                } else {
                                    div()
                                        .size(px(9.0))
                                        .rounded_full()
                                        .border_1()
                                        .border_color(theme.accent_strong)
                                        .into_any_element()
                                },
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .h_full()
                                    .flex()
                                    .items_center()
                                    .border_b_1()
                                    .border_color(theme.border.opacity(0.55))
                                    .child(
                                        div()
                                            .w_full()
                                            .line_clamp(1)
                                            .text_ellipsis()
                                            .child(step.text.clone()),
                                    ),
                            ),
                    );
                }
                content = content.child(steps);
                let mut bottom = div()
                    .mt_auto()
                    .pt(px(14.0))
                    .flex_none()
                    .flex()
                    .flex_col()
                    .gap(px(4.0));
                if needs {
                    let id = thread.id.clone();
                    let keyboard_id = id.clone();
                    let action_session = thread.session.clone();
                    let keyboard_action_session = action_session.clone();
                    let is_question = thread.activity.pending_question;
                    let label = if is_question {
                        "Answer question"
                    } else if indicator == harness_proto::ChatIndicator::Errored {
                        "Review error"
                    } else {
                        "Review request"
                    };
                    let focus = self
                        .session_overview_controls
                        .entry(format!("action:{action_session}:{id}"))
                        .or_insert_with(|| cx.focus_handle().tab_stop(true))
                        .clone();
                    // The approved emphasis is neutral ink, independent of a
                    // user's decorative accent choice.
                    let button = div()
                        .id(SharedString::from(format!(
                            "overview-answer-{action_session}-{id}"
                        )))
                        .role(gpui::Role::Button)
                        .aria_label(format!("{label}: {}", thread.activity.title))
                        .track_focus(&self.overview_background_focus(focus))
                        .border_1()
                        .border_color(gpui::transparent_black())
                        .focus_visible(|el| el.border_color(theme.accent))
                        .px(px(12.0))
                        .py(px(6.0))
                        .rounded(px(6.0))
                        .bg(theme.text)
                        .text_color(theme.bg)
                        .text_size(crate::typography::ui_rems(12.0))
                        .child(label)
                        .cursor_pointer()
                        .hover(|el| el.opacity(0.9))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if is_question {
                                this.open_overview_session_question(
                                    &action_session,
                                    id.clone(),
                                    window,
                                    cx,
                                );
                            } else {
                                this.overview_open_session_chat(
                                    &action_session,
                                    id.clone(),
                                    window,
                                    cx,
                                );
                            }
                        }))
                        .on_key_down(cx.listener(
                            move |this, event: &gpui::KeyDownEvent, window, cx| {
                                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                    if is_question {
                                        this.open_overview_session_question(
                                            &keyboard_action_session,
                                            keyboard_id.clone(),
                                            window,
                                            cx,
                                        );
                                    } else {
                                        this.overview_open_session_chat(
                                            &keyboard_action_session,
                                            keyboard_id.clone(),
                                            window,
                                            cx,
                                        );
                                    }
                                    cx.stop_propagation();
                                }
                            },
                        ));
                    bottom = bottom.child(div().ml(px(25.0)).flex().child(button));
                } else if let Some(other) = session.threads.get(1) {
                    bottom = bottom
                        .border_t_1()
                        .border_color(theme.border.opacity(0.5))
                        .child(self.overview_task_button(other, true, &theme, cx))
                        .child(
                            div()
                                .ml(px(25.0))
                                .text_size(crate::typography::ui_rems(11.0))
                                .text_color(theme.text_muted)
                                .truncate()
                                .child(other.activity.update.clone()),
                        );
                }
                content = content.child(bottom).child(
                    div()
                        .mt(px(13.0))
                        .ml(px(25.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_end()
                        .gap(px(8.0))
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted)
                        .child(
                            div()
                                .min_w_0()
                                .truncate()
                                .child(thread.activity.age_label.clone()),
                        ),
                );
            } else {
                content = content
                    .justify_center()
                    .items_center()
                    .text_center()
                    .child(
                        icon(icons::CHAT_ROUND_LINE)
                            .size(px(28.0))
                            .mb(px(14.0))
                            .text_color(theme.text_muted.opacity(0.55)),
                    )
                    .child(
                        div()
                            .text_size(crate::typography::ui_rems(14.0))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .text_color(theme.text_muted)
                            .child("No tasks yet"),
                    )
                    .child(
                        div()
                            .mt(px(6.0))
                            .w_full()
                            .max_w(px(230.0))
                            .text_size(crate::typography::ui_rems(12.0))
                            .line_height(px(18.0))
                            .text_color(theme.text_muted)
                            .child("Open this session to start a conversation."),
                    );
            }
            cards.push(
                div()
                    .id(SharedString::from(format!("overview-session-{key}")))
                    .w(px(card_width))
                    .flex_none()
                    .flex()
                    .flex_col()
                    .on_drop(
                        cx.listener(move |this, payload: &OverviewSessionDrag, _, cx| {
                            cx.stop_propagation();
                            this.move_overview_session(&payload.session, &drop_session, cx);
                        }),
                    )
                    .child(heading)
                    .child(
                        div()
                            .id(SharedString::from(format!("overview-card-{key}")))
                            .debug_selector(|| "overview-card".into())
                            .h(px(312.0))
                            .w_full()
                            .flex_none()
                            .relative()
                            .rounded(px(12.0))
                            .overflow_hidden()
                            .bg(theme.composer_bg())
                            .shadow(theme.composer_shadows())
                            .drag_over::<OverviewSessionDrag>(move |style, payload, _, _| {
                                if payload.session == highlight_session {
                                    style
                                } else {
                                    style.border_1().border_color(theme.accent)
                                }
                            })
                            .when(needs, |el| {
                                el.child(
                                    gpui::svg()
                                        .path(icons::SESSION_ATTENTION)
                                        .absolute()
                                        .top_0()
                                        .right_0()
                                        .w(px(260.0))
                                        .h(px(190.0))
                                        .text_color(theme.warning),
                                )
                            })
                            .child(content),
                    )
                    .child(
                        div()
                            .mt(px(8.0))
                            .px(px(3.0))
                            .flex()
                            .items_center()
                            .gap(px(6.0))
                            .text_size(crate::typography::ui_rems(11.0))
                            .text_color(theme.text_muted)
                            .child(
                                icon(icons::SPLIT_COLUMNS)
                                    .size(px(12.0))
                                    .text_color(theme.text_muted),
                            )
                            .child(format!(
                                "{} {} · {} {}",
                                session.panel_count,
                                if session.panel_count == 1 {
                                    "panel"
                                } else {
                                    "panels"
                                },
                                session.tab_count,
                                if session.tab_count == 1 {
                                    "tab"
                                } else {
                                    "tabs"
                                }
                            ))
                            .when_some(
                                session.project.as_ref().and_then(|project| {
                                    self.state
                                        .read(cx)
                                        .space_row(project)
                                        .map(|space| transcript::single_line(space.display_name()))
                                }),
                                |el, project| {
                                    el.child(div().flex_1())
                                        .child(div().min_w_0().truncate().child(project))
                                },
                            ),
                    ),
            );
        }
        let new_focus = self
            .session_overview_controls
            .entry("new-session".into())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let new_project = window_control_button(
            "overview-new-session",
            icons::PLUS,
            &theme,
            cx.listener(|this, _, window, cx| {
                this.close_session_overview(window, cx);
                this.create_workspace_session(cx);
            }),
        )
        .w_auto()
        .h(px(28.0))
        .px(px(8.0))
        .gap(px(6.0))
        .text_size(crate::typography::ui_rems(12.0))
        .text_color(theme.text_muted)
        .role(gpui::Role::Button)
        .aria_label("New session")
        .track_focus(&self.overview_background_focus(new_focus))
        .focus_visible(|el| el.bg(theme.element_hover))
        .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                this.create_workspace_session(cx);
                cx.stop_propagation();
            }
        }))
        .when(width >= 640.0, |el| el.child("New session"));
        let back = window_control_button(
            "session-overview-close",
            icons::ARROW_LEFT,
            &theme,
            cx.listener(|this, _, window, cx| this.close_session_overview(window, cx)),
        )
        .debug_selector(|| "session-overview-back".into())
        .w_auto()
        .px(px(8.0))
        .gap(px(6.0))
        .text_size(crate::typography::ui_rems(12.0))
        .text_color(theme.text_muted)
        .role(gpui::Role::Button)
        .aria_label("All sessions, back to session, Escape")
        .track_focus(&self.overview_background_focus(self.session_overview_focus.clone()))
        .focus_visible(|el| el.bg(theme.element_hover))
        .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                this.close_session_overview(window, cx);
                cx.stop_propagation();
            }
        }))
        .tooltip(|_, cx| {
            cx.new(|_| SurfaceTabTooltip {
                text: "Back to session · Esc".into(),
            })
            .into()
        })
        .child("All sessions");
        let summary = div()
            .id("overview-summary")
            .h(px(26.0))
            .px(px(12.0))
            .rounded_full()
            .bg(theme.element_hover.opacity(0.6))
            .flex()
            .items_center()
            .gap(px(14.0))
            .text_size(crate::typography::ui_rems(11.0))
            .text_color(theme.text_muted)
            .aria_label(format!(
                "{working} working, {attention} need you, {completed} done"
            ))
            .when(working + attention + completed == 0, |el| {
                el.child("No tasks running")
            })
            .children(
                [
                    (working, "working", theme.accent),
                    (
                        attention,
                        if attention == 1 {
                            "needs you"
                        } else {
                            "need you"
                        },
                        theme.warning,
                    ),
                    (completed, "done", theme.text_muted),
                ]
                .into_iter()
                .filter(|(count, _, _)| *count > 0)
                .map(|(count, label, color)| {
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.0))
                        .child(div().size(px(5.0)).rounded_full().bg(color))
                        .child(if width >= 640.0 {
                            format!("{count} {label}")
                        } else {
                            count.to_string()
                        })
                }),
            );
        let header = div()
            .relative()
            .h(px(Theme::TITLEBAR_HEIGHT))
            .flex_none()
            .flex()
            .items_center()
            .pt(px(Theme::TITLEBAR_TOP_PAD))
            .gap(px(TITLEBAR_IDENTITY_GAP))
            .pl(px(cluster_buttons_start(
                cfg!(target_os = "macos"),
                self.fullscreen.unwrap_or(false),
                self.linux_left_caption_count(),
            )))
            .pr(px(self.titlebar_right_pad(TITLEBAR_ACTION_EDGE_INSET)))
            // Center against the window, independent of unequal navigation
            // and caption controls on either side. This remains a drag area.
            .child(
                div()
                    .absolute()
                    .inset_0()
                    .pt(px(Theme::TITLEBAR_TOP_PAD))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(summary),
            )
            .child(back)
            .child(self.render_chat_history_button("overview-chat-history", &theme, cx))
            .child(div().flex_1())
            .child(new_project);
        let header = self.titlebar_drag_region("session-overview-titlebar", header, cx);
        let mut root = div()
            .id("session-overview")
            .debug_selector(|| "session-overview".into())
            .size_full()
            .bg(crate::theme::mix(theme.bg, theme.glass(), 0.4))
            .text_color(theme.text)
            .flex()
            .flex_col()
            .child(header)
            .child(
                div()
                    .id("session-overview-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.session_overview_scroll)
                    .on_drag_move::<OverviewSessionDrag>(cx.listener(|this, event, _, cx| {
                        this.track_overview_drag_scroll(event, cx);
                    }))
                    .px(px(32.0))
                    .pt(px(22.0))
                    .pb(px(32.0))
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .items_start()
                            .gap(px(20.0))
                            .children(cards),
                    ),
            );
        if self.command_palette.is_none()
            && self.add_space.is_none()
            && let Some(overlay) = self.overview_question_overlay(window, cx)
        {
            root = root.child(overlay);
        }
        if let Some(overlay) = self.render_add_space_overlay(window.viewport_size(), window, cx) {
            root = root.child(overlay);
        }
        if let Some(overlay) = self.render_command_palette(window.viewport_size(), window, cx) {
            root = root.child(overlay);
        }
        root.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attention_precedes_working_and_finished_threads() {
        use harness_proto::ChatIndicator::*;
        assert!(priority(AwaitingInput) < priority(Working));
        assert!(priority(Errored) < priority(Working));
        assert!(priority(Working) < priority(Completed));
        assert!(priority(Completed) < priority(Idle));
    }

    #[gpui::test]
    fn overview_preserves_selection_draft_split_and_sidebar(cx: &mut gpui::TestAppContext) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, true, Some(true));
        window
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.settings.sidebar_collapsed = true;
                let selected = shell.state.read(cx).selected_chat.clone();
                let split = shell.chat_split.clone();
                let draft = shell.current_canvas_draft(cx);
                window.focus(&shell.composer.focus_handle(cx), cx);
                let focus = window.focused(cx);
                shell.open_session_overview(window, cx);
                assert!(shell.session_overview);
                assert!(shell.overlay_owns_keyboard(cx));
                assert_eq!(shell.state.read(cx).selected_chat, selected);
                assert_eq!(shell.chat_split, split);
                shell.close_session_overview(window, cx);
                assert!(!shell.session_overview);
                assert!(shell.settings.sidebar_collapsed);
                assert_eq!(shell.state.read(cx).selected_chat, selected);
                assert_eq!(shell.chat_split, split);
                assert_eq!(shell.current_canvas_draft(cx), draft);
                assert_eq!(window.focused(cx), focus);
            })
            .unwrap();
    }

    #[gpui::test]
    fn overview_includes_all_threads_and_empty_open_sessions(cx: &mut gpui::TestAppContext) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, Some(false));
        window
            .update(cx, |shell, _, cx| {
                shell.boot_restored = true;
                shell.open_project_tab(Some("empty".into()), cx);
                let sessions = shell.overview_sessions(cx);
                assert_eq!(sessions.len(), 3);
                let a = sessions
                    .iter()
                    .find(|session| session.project.as_deref() == Some("a"))
                    .unwrap();
                assert_eq!(a.threads.len(), 1);
                assert!(a.threads.iter().any(|thread| thread.id == "current"));
                assert!(
                    !a.threads.iter().any(|thread| thread.id == "peer"),
                    "another chat in the project is not automatically a tab in this session"
                );
                let empty = sessions
                    .iter()
                    .find(|session| session.project.as_deref() == Some("empty"))
                    .unwrap();
                assert!(empty.threads.is_empty());
                assert_eq!(empty.summary, "No activity yet.");
            })
            .unwrap();
    }

    #[test]
    fn overview_grid_keeps_cards_inside_small_windows() {
        for width in [320.0, 699.0, 700.0, 999.0, 1000.0, 1440.0] {
            let columns = overview_columns(width);
            let card = overview_card_width(width);
            assert!(card >= 256.0);
            assert!(card * columns as f32 + 20.0 * (columns - 1) as f32 + 64.0 <= width);
        }
    }
}
