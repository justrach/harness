//! Chat tabs: each tab keeps its own split layout, selection and project,
//! like a terminal's tabs holding their splits. ⌘T opens a fresh tab; ⌘D
//! always splits the current one.
//!
//! The ACTIVE tab lives in the ordinary shell fields (`chat_split`, the app
//! selection, the sidebar filter); parked tabs hold copies. Switching parks
//! the live state and loads the target's, the way focusing a pane swaps.

use super::*;
use crate::pickers::CanvasDraft;

/// A tab's layout while it isn't the active one.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct ChatTab {
    pub split: Option<chat_split::ChatSplit>,
    pub selected: Option<String>,
    pub project: Option<String>,
    /// The focused pane's composer picks (read when it's a canvas).
    pub draft: Option<CanvasDraft>,
}

/// Remove a closed tab from visit history and reindex the remaining entries.
/// Return the last visited survivor, falling back to a neighbor without history.
pub(super) fn tab_after_close(closed: usize, len: usize, history: &mut Vec<usize>) -> usize {
    history.retain(|&ix| ix != closed && ix < len);
    for ix in history.iter_mut() {
        if *ix > closed {
            *ix -= 1;
        }
    }
    history
        .last()
        .copied()
        .unwrap_or_else(|| closed.saturating_sub(1).min(len.saturating_sub(2)))
}

/// The ninth tab key: always the last tab, however many are open.
pub(super) const LAST_TAB_SLOT: usize = 8;

/// The tab a number key shows: its own slot, or the last tab for
/// [`LAST_TAB_SLOT`]. None with no tab there, or fewer than two tabs.
pub(super) fn tab_for_slot(slot: usize, len: usize) -> Option<usize> {
    if len < 2 {
        return None;
    }
    if slot == LAST_TAB_SLOT {
        return Some(len - 1);
    }
    (slot < len).then_some(slot)
}

/// What closing a pane or tab did to its session ([`Shell::archive_closed_session`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CloseArchive {
    /// The setting is off.
    Off,
    /// Another pane or tab still shows it.
    StillOpen,
    /// It is still working or waiting for input; kept, with a notice.
    Running,
    Archived,
}

/// Where tab `ix` ends up after the tab at `from` moves to `to`.
pub(super) fn index_after_move(ix: usize, from: usize, to: usize) -> usize {
    if ix == from {
        to
    } else if from < ix && ix <= to {
        ix - 1
    } else if to <= ix && ix < from {
        ix + 1
    } else {
        ix
    }
}

/// Saved tabs back as parked tabs, dropping chats that no longer exist.
/// `None` unless there are two or more and the active index fits.
pub(super) fn restore_chat_tabs(
    saved: &[crate::settings::SavedChatTab],
    active: usize,
    live: impl Fn(&str) -> bool,
) -> Option<(Vec<ChatTab>, usize)> {
    if saved.len() < 2 || active >= saved.len() {
        return None;
    }
    let tabs = saved
        .iter()
        .map(|tab| ChatTab {
            split: tab
                .layout
                .as_ref()
                .and_then(|layout| chat_split::ChatSplit::from_saved(layout, &live)),
            selected: tab.selected.clone().filter(|id| live(id)),
            project: tab.project.clone(),
            draft: None,
        })
        .collect();
    Some((tabs, active))
}

/// A chat tab dragged within the tab list.
#[derive(Clone)]
pub(super) struct ChatTabDrag {
    from: usize,
    title: SharedString,
}

impl Shell {
    fn record_chat_tab_visit(&mut self) {
        self.chat_tab_history.retain(|&ix| ix != self.chat_tab);
        self.chat_tab_history.push(self.chat_tab);
    }

    /// The focused pane's live composer picks, for parking or inheriting.
    pub(super) fn current_canvas_draft(&self, cx: &App) -> CanvasDraft {
        let composer = self.composer.read(cx);
        CanvasDraft {
            input: Some(composer.canvas_input(cx)),
            ..composer.pickers().read(cx).canvas_draft(cx)
        }
    }

    /// Hand the pickers the picks of the tab/pane just switched to (call
    /// after `select_chat`; `None` for a chat or a canvas with none parked).
    pub(super) fn adopt_canvas_draft(&self, draft: Option<CanvasDraft>, cx: &mut Context<Self>) {
        if let Some(input) = draft.as_ref().and_then(|draft| draft.input.clone()) {
            self.composer
                .update(cx, |composer, cx| composer.set_canvas_input(input, cx));
        }
        let pickers = self.composer.read(cx).pickers().clone();
        pickers.update(cx, |pickers, cx| pickers.adopt_canvas_draft(draft, cx));
    }

    fn park_chat_tab(&mut self, cx: &App) -> ChatTab {
        ChatTab {
            split: self.chat_split.clone(),
            selected: self.state.read(cx).selected_chat.clone(),
            project: self.settings.space_filter.clone(),
            draft: Some(self.current_canvas_draft(cx)),
        }
    }

    fn load_chat_tab(&mut self, tab: ChatTab, window: &mut Window, cx: &mut Context<Self>) {
        self.chat_split = tab.split;
        self.chat_split_selected = tab.selected.clone();
        let draft = tab.draft.filter(|_| tab.selected.is_none());
        self.state.update(cx, |s, cx| s.select_chat(tab.selected, cx));
        // Filter first: the tab's own parked project must have the last word.
        self.set_space_filter(tab.project, cx);
        self.adopt_canvas_draft(draft, cx);
        self.sync_chat_panes(cx);
        self.persist_chat_tabs(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    /// Save the tab list for the next launch: parked tabs as they were
    /// parked, the active one from the live state.
    pub(super) fn persist_chat_tabs(&mut self, cx: &mut Context<Self>) {
        if !self.boot_restored {
            return;
        }
        let saved: Vec<crate::settings::SavedChatTab> = if self.chat_tabs.len() < 2 {
            Vec::new()
        } else {
            self.chat_tabs
                .iter()
                .enumerate()
                .map(|(ix, tab)| {
                    if ix == self.chat_tab {
                        crate::settings::SavedChatTab {
                            selected: self.state.read(cx).selected_chat.clone(),
                            project: self.settings.space_filter.clone(),
                            layout: self.chat_split.as_ref().map(chat_split::ChatSplit::to_saved),
                        }
                    } else {
                        crate::settings::SavedChatTab {
                            selected: tab.selected.clone(),
                            project: tab.project.clone(),
                            layout: tab.split.as_ref().map(chat_split::ChatSplit::to_saved),
                        }
                    }
                })
                .collect()
        };
        let active = if saved.is_empty() { 0 } else { self.chat_tab };
        if saved != self.settings.chat_tabs || active != self.settings.chat_tab {
            self.settings.chat_tabs = saved;
            self.settings.chat_tab = active;
            self.schedule_save(cx);
        }
    }

    /// Drag-reorder: the tab at `from` moves to `to`; the lit tab stays lit.
    pub(super) fn move_chat_tab(&mut self, from: usize, to: usize, cx: &mut Context<Self>) {
        let len = self.chat_tabs.len();
        if from >= len || to >= len || from == to {
            return;
        }
        let tab = self.chat_tabs.remove(from);
        self.chat_tabs.insert(to, tab);
        self.chat_tab = index_after_move(self.chat_tab, from, to);
        for ix in &mut self.chat_tab_history {
            *ix = index_after_move(*ix, from, to);
        }
        self.persist_chat_tabs(cx);
        cx.notify();
    }

    /// ⌘T: a new tab with one pane showing `open` (`None` = a fresh
    /// new-session canvas in the current project). The layout you were in
    /// stays whole in its own tab.
    pub(super) fn new_chat_tab(&mut self, open: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        if !matches!(self.route, Route::Chat) {
            self.close_settings(cx);
        }
        self.record_chat_tab_visit();
        let parked = self.park_chat_tab(cx);
        let project = parked.project.clone();
        // A fresh canvas starts from the picks of the tab it was opened from,
        // not its unsent prompt.
        let draft = parked
            .draft
            .as_ref()
            .map(CanvasDraft::fresh)
            .filter(|_| open.is_none());
        if self.chat_tabs.is_empty() {
            self.chat_tabs.push(parked);
        } else {
            self.chat_tabs[self.chat_tab] = parked;
        }
        // A chat moving into the new tab leaves its old pane empty.
        if let Some(id) = open.as_deref()
            && let Some(split) = self.chat_tabs[self.chat_tab].split.as_mut()
        {
            for pane in split.panes.iter_mut().filter(|p| p.as_deref() == Some(id)) {
                *pane = None;
            }
        }
        let tab = ChatTab {
            split: None,
            selected: open,
            project,
            draft,
        };
        self.chat_tabs.push(tab.clone());
        self.chat_tab = self.chat_tabs.len() - 1;
        self.record_chat_tab_visit();
        self.load_chat_tab(tab, window, cx);
    }

    pub(super) fn switch_chat_tab(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) {
        if ix == self.chat_tab || ix >= self.chat_tabs.len() || !matches!(self.route, Route::Chat) {
            return;
        }
        self.record_chat_tab_visit();
        self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        self.chat_tab = ix;
        self.record_chat_tab_visit();
        let tab = self.chat_tabs[ix].clone();
        self.load_chat_tab(tab, window, cx);
    }

    /// ⌃Tab / ⌃⇧Tab: browser-style tab cycling once two or more tabs are
    /// open; with one tab they keep stepping through sidebar sessions.
    pub(super) fn cycle_tab_or_session(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.chat_tabs.len() >= 2 && matches!(self.route, Route::Chat) && !self.overlay_owns_keyboard(cx) {
            self.cycle_chat_tab(forward, window, cx);
        } else {
            self.cycle_session(forward, cx);
        }
    }

    /// ⌃1–⌃9 (Alt+digit off macOS).
    pub(super) fn select_chat_tab(&mut self, slot: usize, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(ix) = tab_for_slot(slot, self.chat_tabs.len()) {
            self.switch_chat_tab(ix, window, cx);
        }
    }

    pub(super) fn cycle_chat_tab(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        let len = self.chat_tabs.len();
        if len < 2 {
            return;
        }
        let ix = if forward {
            (self.chat_tab + 1) % len
        } else {
            (self.chat_tab + len - 1) % len
        };
        self.switch_chat_tab(ix, window, cx);
    }

    /// ⌘W on a tab down to one pane closes the tab (not the window) while
    /// other tabs remain. The shared pane/tab close handler owns archiving.
    pub(super) fn close_chat_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.chat_tabs.len() < 2 || !matches!(self.route, Route::Chat) {
            return false;
        }
        let closed = self.chat_tab;
        let next = tab_after_close(closed, self.chat_tabs.len(), &mut self.chat_tab_history);
        tracing::info!(closed, tabs = self.chat_tabs.len(), "closing chat tab");
        self.chat_tabs.remove(closed);
        self.chat_tab = next;
        self.record_chat_tab_visit();
        let tab = self.chat_tabs[next].clone();
        if self.chat_tabs.len() == 1 {
            self.chat_tabs.clear();
            self.chat_tab = 0;
            self.chat_tab_history.clear();
        }
        self.load_chat_tab(tab, window, cx);
        true
    }

    /// Includes the live pane even while Settings is covering the chat outlet.
    fn chat_still_open(&self, chat_id: &str, cx: &App) -> bool {
        self.state.read(cx).selected_chat.as_deref() == Some(chat_id)
            || self.chat_split.as_ref().is_some_and(|split| {
                split.panes.iter().any(|id| id.as_deref() == Some(chat_id))
            })
            || self.chat_in_other_tab(chat_id).is_some()
    }

    /// The shared archive path for explicit pane and tab closes. Keep unfinished
    /// work and sessions still visible elsewhere; no archive runs on window exit.
    pub(super) fn archive_closed_session(
        &mut self,
        chat_id: String,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> CloseArchive {
        if !settings::archive_sessions_on_close(cx) {
            return CloseArchive::Off;
        }
        if self.chat_still_open(&chat_id, cx)
            || cx.windows().into_iter().any(|other| {
                other.window_id() != window.window_handle().window_id()
                    && other.downcast::<Shell>().is_some_and(|handle| {
                        handle.read(cx).is_ok_and(|shell| shell.chat_still_open(&chat_id, cx))
                    })
            })
        {
            return CloseArchive::StillOpen;
        }
        let state = self.state.read(cx);
        let now = Utc::now();
        // A stale heartbeat must not turn an offline host's unfinished run
        // into an archive candidate. Pending and queued sends are active too.
        let running = state.send_pending(&chat_id, now)
            || state.send_queued(&chat_id, now)
            || state.session_for(&chat_id).is_some_and(|session| {
                matches!(session.status,
                    harness_proto::SessionStatus::Working | harness_proto::SessionStatus::AwaitingInput)
            });
        if running {
            self.sidebar_notice = Some("Still running — closed without archiving".into());
            cx.notify();
            return CloseArchive::Running;
        }
        if let Some(engine) = state.engine().cloned() {
            // Each close owns its request. Reusing mutate_task would cancel
            // an earlier archive when panes or tabs close in quick succession.
            cx.spawn(async move |this, cx| {
                if let Err(error) = engine.client().call(methods::MUTATE, serde_json::json!({
                    "op": "setChatArchived", "chatId": chat_id, "archived": true,
                })).await {
                    this.update(cx, |shell, cx| {
                        shell.sidebar_notice = Some(format!("Could not archive closed session: {error}").into());
                        cx.notify();
                    }).ok();
                }
            }).detach();
        } else {
            self.sidebar_notice = Some("Engine not connected".into());
            cx.notify();
        }
        CloseArchive::Archived
    }

    /// Where `chat_id` is open in a PARKED tab: (tab, pane) — the pane is
    /// `None` when it's that tab's focused chat (or its only pane).
    fn chat_in_other_tab(&self, chat_id: &str) -> Option<(usize, Option<usize>)> {
        self.chat_tabs.iter().enumerate().find_map(|(tab_ix, tab)| {
            if tab_ix == self.chat_tab {
                return None;
            }
            if tab.selected.as_deref() == Some(chat_id) {
                return Some((tab_ix, None));
            }
            let pane = tab
                .split
                .as_ref()?
                .panes
                .iter()
                .position(|pane| pane.as_deref() == Some(chat_id))?;
            Some((tab_ix, Some(pane)))
        })
    }

    /// Opening a chat that already lives in another tab goes THERE (its
    /// tab, then its pane) instead of showing it twice. False when it isn't
    /// open in another tab.
    pub(super) fn reveal_chat_in_tabs(&mut self, chat_id: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some((tab, pane)) = self.chat_in_other_tab(chat_id) else {
            return false;
        };
        self.switch_chat_tab(tab, window, cx);
        if let Some(pane) = pane {
            self.focus_chat_pane(pane, window, cx);
        }
        true
    }

    /// Tab titles, active tab from the live state: the focused chat's title.
    /// The lit tab's pane strip shows its panes, so rows carry titles only.
    fn chat_tab_labels(&self, cx: &App) -> Vec<SharedString> {
        let state = self.state.read(cx);
        let title = |selected: Option<&str>| -> SharedString {
            selected
                .and_then(|id| state.chats.iter().find(|c| c.id == id))
                .map(|c| transcript::single_line(c.title.as_deref().unwrap_or("Untitled session")))
                .unwrap_or_else(|| "New session".into())
                .into()
        };
        self.chat_tabs
            .iter()
            .enumerate()
            .map(|(ix, tab)| {
                if ix == self.chat_tab {
                    title(state.selected_chat.as_deref())
                } else {
                    title(tab.selected.as_deref())
                }
            })
            .collect()
    }

    /// The tab list, shown once there are two or more tabs. Click to switch;
    /// the lit tab is the one on screen; drag a tab onto another to move it
    /// there. The lit tab's pane cards (`pane_strip`, taken) sit right under
    /// it, so they read as that tab's panes rather than the last tab's.
    pub(super) fn render_chat_tabs(
        &mut self,
        theme: &Theme,
        pane_strip: &mut Option<AnyElement>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.chat_tabs.len() < 2 || !matches!(self.route, Route::Chat) {
            return None;
        }
        let labels = self.chat_tab_labels(cx);
        let active = self.chat_tab;
        let accent = theme.accent;
        Some(
            div()
                .id("chat-tabs")
                .flex_none()
                .mx(px(10.0))
                .mt(px(4.0))
                .mb(px(6.0))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(
                    div()
                        .px(px(4.0))
                        .pb(px(2.0))
                        .flex()
                        .flex_row()
                        .justify_between()
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted.opacity(0.8))
                        .child(SharedString::from(format!("Tabs · {}", labels.len()))),
                )
                .children(labels.into_iter().enumerate().flat_map(|(ix, title)| {
                    let lit = ix == active;
                    let key: SharedString = format!("chat-tab-{ix}").into();
                    let row = div()
                        .id(("chat-tab", ix))
                        .debug_selector(move || format!("chat-tab-{ix}"))
                        .h(px(26.0))
                        .px(px(8.0))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(6.0))
                        .rounded(px(7.0))
                        .cursor_pointer()
                        .bg(if lit {
                            theme.element_hover
                        } else {
                            motion::hover_blend(&key, gpui::transparent_black(), theme.element_hover)
                        })
                        .on_hover(motion::hover_listener(key))
                        .text_size(crate::typography::ui_rems(12.5))
                        .text_color(if lit { theme.text } else { theme.text_muted })
                        .on_click(cx.listener(move |this, _, window, cx| this.switch_chat_tab(ix, window, cx)))
                        .when(crate::click_activation_drag_enabled(), |row| {
                            row.on_drag(
                                ChatTabDrag {
                                    from: ix,
                                    title: title.clone(),
                                },
                                |payload, _, _, cx| {
                                    cx.stop_propagation();
                                    let title = payload.title.clone();
                                    cx.new(|_| SurfaceTabGhost { title })
                                },
                            )
                        })
                        .drag_over::<ChatTabDrag>(move |style, drag, _, _| {
                            if drag.from == ix {
                                style
                            } else {
                                style.bg(accent.opacity(0.14))
                            }
                        })
                        .on_drop(cx.listener(move |this, drag: &ChatTabDrag, _, cx| {
                            this.move_chat_tab(drag.from, ix, cx)
                        }))
                        .child(
                            div()
                                .flex_none()
                                .w(px(14.0))
                                .text_size(crate::typography::ui_rems(11.0))
                                .text_color(theme.text_muted.opacity(0.7))
                                .child(SharedString::from(format!("{}", ix + 1))),
                        )
                        .child(div().flex_1().min_w_0().truncate().child(title))
                        .into_any_element();
                    let strip = if lit { pane_strip.take() } else { None };
                    std::iter::once(row).chain(strip)
                }))
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn archive_test_window(
        cx: &mut gpui::TestAppContext,
        path: &std::path::Path,
    ) -> gpui::WindowHandle<Shell> {
        cx.add_window(|_, cx| {
            let state = cx.new(|_| AppState::new());
            Shell::new(
                state,
                EngineBootConfig {
                    data_dir: path.into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            )
        })
    }

    fn init_archive_test(cx: &mut gpui::TestAppContext, path: &std::path::Path) {
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
            crate::history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            settings::init(settings::UiSettings::default(), path, cx);
        });
    }

    fn archive_test_chat(id: &str) -> harness_proto::Chat {
        serde_json::from_value(serde_json::json!({
            "id": id, "deviceId": "local", "archived": false, "createdAt": chrono::Utc::now(),
        }))
        .unwrap()
    }

    #[gpui::test]
    fn close_tab_archive_dispatches_live_sessions_without_cancelling_prior_closes(
        cx: &mut gpui::TestAppContext,
    ) {
        assert_close_archive_dispatch(cx, false);
    }

    #[gpui::test]
    fn closing_the_other_pane_goes_back_to_one_column(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = archive_test_window(cx, dir.path());
        window
            .update(cx, |shell, window, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats = ["here", "there"].map(archive_test_chat).into();
                    state.selected_chat = Some("here".into());
                });
                shell.route = Route::Chat;
                shell.chat_split = chat_split::ChatSplit::split(
                    None,
                    SplitAxis::Horizontal,
                    Some("there".into()),
                    None,
                );
                let split = shell.chat_split.as_ref().expect("two panes");
                assert_eq!(split.panes.len(), 2);
                let other = 1 - split.focus;
                assert!(!shell.close_chat_pane(7, window, cx), "no such pane");
                // The other pane's close button.
                assert!(shell.close_chat_pane(other, window, cx));
                assert!(shell.chat_split.is_none(), "back to one column");
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("here"),
                    "the chat that was in focus stays open"
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn close_pane_archive_dispatches_without_cancelling_prior_closes(cx: &mut gpui::TestAppContext) {
        assert_close_archive_dispatch(cx, true);
    }

    fn assert_close_archive_dispatch(cx: &mut gpui::TestAppContext, panes: bool) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let (out, mut requests) = tokio::sync::mpsc::channel(128);
        let (replies, inbound) = tokio::sync::mpsc::channel(128);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = archive_test_window(cx, dir.path());
        cx.update(|cx| settings::set_archive_sessions_on_close(true, cx));
        assert!(settings::UiSettings::load(dir.path()).archive_sessions_on_close);
        window
            .update(cx, |shell, window, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats = ["keep", "second", "live", "stale"]
                        .map(archive_test_chat)
                        .into();
                    state.selected_chat = Some("live".into());
                    state.set_test_engine(engine);
                });
                shell.route = Route::Chat;
                shell.chat_tabs = ["keep", "second", "stale"]
                    .map(|id| ChatTab {
                        selected: Some(id.into()),
                        ..Default::default()
                    })
                    .into();
                shell.chat_tab = 2;
                if panes {
                    shell.chat_tabs.clear();
                    shell.chat_tab = 0;
                    let split = chat_split::ChatSplit::split(
                        None, SplitAxis::Horizontal, Some("keep".into()), None,
                    );
                    shell.chat_split = chat_split::ChatSplit::split(
                        split, SplitAxis::Horizontal, Some("second".into()), None,
                    );
                }
                assert!(shell.close_focused_chat_pane(window, cx));
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("keep"));
                assert!(
                    !shell.close_focused_chat_pane(window, cx),
                    "last tab falls through to window close"
                );
            })
            .unwrap();
        cx.run_until_parked();
        let mut archived = Vec::new();
        while let Ok(request) = requests.try_recv() {
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            if request["method"] == methods::MUTATE {
                assert_eq!(request["params"]["op"], "setChatArchived");
                assert_eq!(request["params"]["archived"], true);
                archived.push(request["params"]["chatId"].as_str().unwrap().to_string());
                runtime.block_on(async {
                    replies
                        .send(
                            serde_json::json!({"id": request["id"], "err": "archive rejected"})
                                .to_string(),
                        )
                        .await
                        .unwrap();
                    while replies.capacity() < replies.max_capacity() {
                        tokio::task::yield_now().await;
                    }
                });
            }
        }
        archived.sort();
        assert_eq!(archived, ["live", "second"]);
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| {
                assert!(
                    shell
                        .sidebar_notice
                        .as_ref()
                        .unwrap()
                        .contains("archive rejected")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn close_tab_archive_skips_disabled_active_shared_and_non_session_closes(
        cx: &mut gpui::TestAppContext,
    ) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let (out, mut requests) = tokio::sync::mpsc::channel(128);
        let (_replies, inbound) = tokio::sync::mpsc::channel(128);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = archive_test_window(cx, dir.path());
        let other = archive_test_window(cx, dir.path());
        for case in [
            "disabled",
            "working",
            "waiting",
            "other-tab",
            "other-window",
            "canvas",
            "settings",
            "last-tab",
            "other-pane",
            "pending",
        ] {
            other
                .update(cx, |shell, _, cx| {
                    shell.state.update(cx, |state, _| {
                        state.selected_chat = (case == "other-window").then(|| "closing".into());
                    });
                })
                .unwrap();
            window
                .update(cx, |shell, window, cx| {
                    settings::set_archive_sessions_on_close(case != "disabled", cx);
                    shell.route = if case == "settings" {
                        Route::Settings(SettingsSection::Archived)
                    } else {
                        Route::Chat
                    };
                    shell.chat_split = None;
                    let closing = (case != "canvas").then(|| "closing".to_string());
                    shell.state.update(cx, |state, _| {
                        state.chats = ["keep", "closing"].map(archive_test_chat).into();
                        state.selected_chat = closing.clone();
                        state.sessions.clear();
                        if matches!(case, "working" | "waiting") {
                            state.sessions.push(harness_proto::Session {
                                chat_id: "closing".into(),
                                device_id: "local".into(),
                                status: if case == "working" {
                                    harness_proto::SessionStatus::Working
                                } else {
                                    harness_proto::SessionStatus::AwaitingInput
                                },
                                started_at: None,
                                updated_at: chrono::Utc::now() - chrono::Duration::hours(1),
                                last_completed_turn: None,
                            });
                        }
                        state.set_test_engine(engine.clone());
                        if case == "pending" {
                            state.begin_pending_send(
                                "closing",
                                "pending-message",
                                chrono::Utc::now(),
                            );
                        }
                    });
                    shell.chat_tabs = vec![
                        ChatTab {
                            selected: Some(
                                if case == "other-tab" {
                                    "closing"
                                } else {
                                    "keep"
                                }
                                .into(),
                            ),
                            ..Default::default()
                        },
                        ChatTab {
                            selected: closing.clone(),
                            ..Default::default()
                        },
                    ];
                    shell.chat_tab = 1;
                    if case == "last-tab" {
                        shell.chat_tabs.clear();
                        shell.chat_tab = 0;
                    }
                    if case == "other-pane" {
                        shell.chat_split = chat_split::ChatSplit::split(
                            None,
                            SplitAxis::Horizontal,
                            closing,
                            None,
                        );
                    }
                    let closed = shell.close_focused_chat_pane(window, cx);
                    assert_eq!(closed, !matches!(case, "settings" | "last-tab"), "{case}");
                })
                .unwrap();
            cx.run_until_parked();
            while let Ok(request) = requests.try_recv() {
                let request: serde_json::Value = serde_json::from_str(&request).unwrap();
                assert_ne!(
                    request["method"],
                    methods::MUTATE,
                    "unexpected archive for {case}: {request}"
                );
            }
        }
    }

    #[test]
    fn moving_a_tab_keeps_every_other_tab_in_order() {
        let order = |from, to| -> Vec<usize> { (0..4).map(|ix| index_after_move(ix, from, to)).collect() };
        // Tab 0 dragged onto tab 2: 1 and 2 shift left.
        assert_eq!(order(0, 2), [2, 0, 1, 3]);
        // Tab 3 dragged onto tab 1: 1 and 2 shift right.
        assert_eq!(order(3, 1), [0, 2, 3, 1]);
        assert_eq!(order(2, 2), [0, 1, 2, 3]);
    }

    #[test]
    fn saved_tabs_restore_without_vanished_chats() {
        use crate::settings::SavedChatTab;
        let saved = vec![
            SavedChatTab {
                selected: Some("live".into()),
                project: Some("space".into()),
                layout: None,
            },
            SavedChatTab {
                selected: Some("deleted".into()),
                project: None,
                layout: None,
            },
        ];
        let live = |id: &str| id == "live";
        let (tabs, active) = restore_chat_tabs(&saved, 1, live).unwrap();
        assert_eq!(active, 1);
        assert_eq!(tabs[0].selected.as_deref(), Some("live"));
        assert_eq!(tabs[0].project.as_deref(), Some("space"));
        assert_eq!(tabs[1].selected, None, "a deleted chat reopens as a new session");
        assert!(restore_chat_tabs(&saved[..1], 0, live).is_none());
        assert!(restore_chat_tabs(&saved, 2, live).is_none());
    }

    #[gpui::test]
    fn closing_new_tabs_returns_to_last_visited_tab(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = archive_test_window(cx, dir.path());
        window
            .update(cx, |shell, window, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats = ["a", "b", "c"].map(archive_test_chat).into();
                    state.selected_chat = Some("a".into());
                });
                shell.new_chat_tab(Some("b".into()), window, cx);
                shell.switch_chat_tab(0, window, cx);

                // A is last visited, but B is the new canvas's left neighbor.
                shell.new_chat_tab(None, window, cx);
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.chat_tab, 0);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("a"));

                // Nested creates unwind in visit order, including canvas tabs.
                shell.new_chat_tab(None, window, cx);
                shell.new_chat_tab(Some("c".into()), window, cx);
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.chat_tab, 2);
                assert!(shell.state.read(cx).selected_chat.is_none());
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("a"));

                // Closing a middle tab reindexes history; the last survivor then
                // becomes implicit, and a fresh create/close still returns to it.
                shell.new_chat_tab(Some("c".into()), window, cx);
                shell.switch_chat_tab(1, window, cx);
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.chat_tab, 1);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("c"));
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("a"));
                assert!(shell.chat_tabs.is_empty());
                assert!(shell.chat_tab_history.is_empty());
                shell.new_chat_tab(None, window, cx);
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("a"));
            })
            .unwrap();
    }

    #[gpui::test]
    fn deleting_new_session_returns_to_last_visited_tab(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = archive_test_window(cx, dir.path());
        window
            .update(cx, |shell, window, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats = ["a", "b", "c"].map(archive_test_chat).into();
                    state.selected_chat = Some("a".into());
                });
                shell.new_chat_tab(Some("b".into()), window, cx);
                shell.switch_chat_tab(0, window, cx);
                shell.new_chat_tab(Some("c".into()), window, cx);
                shell.delete_chat("c".into(), window, cx);
                assert_eq!(shell.chat_tab, 0);
                assert_eq!(shell.chat_tabs.len(), 2);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("a"));
            })
            .unwrap();
    }

    #[gpui::test]
    fn reordering_tabs_preserves_last_visited_target(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = archive_test_window(cx, dir.path());
        window
            .update(cx, |shell, window, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats = ["a", "b", "c"].map(archive_test_chat).into();
                    state.selected_chat = Some("a".into());
                });
                shell.new_chat_tab(Some("b".into()), window, cx);
                shell.switch_chat_tab(0, window, cx);
                shell.new_chat_tab(Some("c".into()), window, cx);
                // A moves behind C: [A, B, C] -> [B, C, A].
                shell.move_chat_tab(0, 2, cx);
                assert_eq!(shell.chat_tab, 1);
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.chat_tab, 1);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("a"));
            })
            .unwrap();
    }

    #[test]
    fn closing_a_tab_reindexes_visit_history() {
        let mut history = vec![0, 2, 1];
        assert_eq!(tab_after_close(1, 3, &mut history), 1);
        assert_eq!(history, [0, 1]);
        assert_eq!(tab_after_close(1, 2, &mut history), 0);
        assert_eq!(history, [0]);

        let mut history = vec![2, 1, 0];
        assert_eq!(tab_after_close(0, 3, &mut history), 0);
        assert_eq!(history, [1, 0]);
    }

    #[test]
    fn closing_a_tab_without_history_lands_on_its_neighbor() {
        for (closed, len, expected) in [(0, 3, 0), (1, 3, 0), (2, 3, 1), (1, 2, 0)] {
            assert_eq!(tab_after_close(closed, len, &mut Vec::new()), expected);
        }
    }

    #[test]
    fn number_keys_pick_their_tab_and_nine_picks_the_last() {
        assert_eq!(tab_for_slot(0, 3), Some(0));
        assert_eq!(tab_for_slot(2, 3), Some(2));
        assert_eq!(tab_for_slot(3, 3), None, "no fourth tab");
        assert_eq!(tab_for_slot(LAST_TAB_SLOT, 3), Some(2));
        assert_eq!(tab_for_slot(LAST_TAB_SLOT, 12), Some(11));
        // One tab is no tab strip: the keys do nothing.
        assert_eq!(tab_for_slot(0, 1), None);
        assert_eq!(tab_for_slot(LAST_TAB_SLOT, 0), None);
    }
}
