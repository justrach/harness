//! Project tabs: each Space keeps its own selection and split layout.
//! The top bar switches projects; the sidebar switches conversations.
//!
//! The ACTIVE tab lives in the ordinary shell fields (`chat_split`, the app
//! selection, the sidebar filter); parked tabs hold copies. Switching parks
//! the live state and loads the target's, the way focusing a pane swaps.

use super::*;
use crate::pickers::CanvasDraft;
#[cfg(test)]
mod project_tests;
mod projects;

#[cfg(test)]
mod header_tests;
#[cfg(test)]
pub(super) mod navigation_tests;
#[cfg(test)]
pub(super) mod test_support;
#[cfg(test)]
mod shortcut_tests;
#[cfg(test)]
mod sidebar_tests;

/// The window-level open-work strip, above the conversation toolbar.
pub(super) const TOP_TAB_HEIGHT: f32 = 42.0;
const SINGLE_TAB_WIDTH: f32 = 184.0;
const TAB_INSET: f32 = 3.0;
const TAB_GAP: f32 = 4.0;

/// A tab's layout while it isn't the active one.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct ChatTab {
    pub id: String,
    pub title: Option<String>,
    pub session_icon: Option<String>,
    pub pinned: bool,
    pub split: Option<chat_split::ChatSplit>,
    pub selected: Option<String>,
    pub project: Option<String>,
    /// The focused pane's composer picks (read when it's a canvas).
    pub draft: Option<CanvasDraft>,
}

impl Default for ChatTab {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: None,
            session_icon: None,
            pinned: false,
            split: None,
            selected: None,
            project: None,
            draft: None,
        }
    }
}

/// How many closed views ⌘⇧T can bring back.
const CLOSED_TAB_LIMIT: usize = 20;

/// A closed tab or pane's snapshot and its former position in the tab list.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct ClosedChatTab {
    pub index: usize,
    pub tab: ChatTab,
    pub archived: Vec<String>,
    pub closed_at: i64,
    pane: bool,
    replacement: Option<ChatTab>,
}

impl ChatTab {
    /// Every chat the tab shows, the selected one first.
    pub(super) fn chats(&self) -> Vec<String> {
        let mut chats = Vec::new();
        let panes = self
            .split
            .iter()
            .flat_map(|split| split.panes.iter().flatten());
        for id in self.selected.iter().chain(panes) {
            if !chats.contains(id) {
                chats.push(id.clone());
            }
        }
        chats
    }

    /// Drop deleted chats without resurrecting an otherwise empty tab.
    pub(super) fn without_deleted(mut self, exists: impl Fn(&str) -> bool) -> Option<Self> {
        self.selected = self.selected.filter(|id| exists(id));
        if let Some(split) = self.split.as_mut() {
            for pane in &mut split.panes {
                if pane.as_deref().is_some_and(|id| !exists(id)) {
                    *pane = None;
                }
            }
        }
        (!self.id.is_empty() || self.project.is_some() || !self.chats().is_empty()).then_some(self)
    }

    fn has_canvas_input(&self) -> bool {
        self.draft
            .iter()
            .chain(
                self.split
                    .iter()
                    .flat_map(|split| split.drafts.iter().flatten()),
            )
            .any(|draft| {
                draft
                    .input
                    .as_ref()
                    .is_some_and(|input| !input.text.is_empty() || !input.stage.is_empty())
            })
    }

    fn contains_chat(&self, id: &str) -> bool {
        self.selected.as_deref() == Some(id)
            || self
                .split
                .as_ref()
                .is_some_and(|split| split.panes.iter().any(|pane| pane.as_deref() == Some(id)))
    }
}

/// Its old place, or the end if the tab list has since shrunk.
pub(super) fn reopen_index(closed_at: usize, len: usize) -> usize {
    closed_at.min(len)
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

    pub(super) fn park_chat_tab(&mut self, cx: &App) -> ChatTab {
        self.park_workspace_draft(cx);
        let identity = self.chat_tabs.get(self.chat_tab);
        ChatTab {
            id: identity.map(|tab| tab.id.clone()).unwrap_or_default(),
            title: identity.and_then(|tab| tab.title.clone()),
            session_icon: identity.and_then(|tab| tab.session_icon.clone()),
            pinned: identity.is_some_and(|tab| tab.pinned),
            split: self.chat_split.clone(),
            selected: self.state.read(cx).selected_chat.clone(),
            project: self.active_project(cx),
            draft: Some(self.current_canvas_draft(cx)),
        }
    }

    fn load_chat_tab(&mut self, tab: ChatTab, window: &mut Window, cx: &mut Context<Self>) {
        self.load_chat_tab_without_window(tab, cx);
        window.focus(&self.composer.focus_handle(cx), cx);
    }

    pub(super) fn load_chat_tab_without_window(&mut self, tab: ChatTab, cx: &mut Context<Self>) {
        self.chat_tab_revealed = None;
        if let Ok(id) = uuid::Uuid::parse_str(&tab.id) { self.chat_tab_id = id; }
        self.chat_split = tab.split;
        self.chat_split_selected = tab.selected.clone();
        let on_canvas = tab.selected.is_none();
        let draft = tab.draft.filter(|_| on_canvas);
        if on_canvas && draft.is_none() {
            self.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(Default::default(), cx)
            });
        }
        self.state.update(cx, |s, cx| {
            s.auto_selected = true;
            s.select_space(tab.project.clone(), cx);
        });
        self.state
            .update(cx, |s, cx| s.select_chat(tab.selected, cx));
        // Filter first: the tab's own parked project must have the last word.
        self.set_space_filter(tab.project, cx);
        self.adopt_canvas_draft(draft, cx);
        self.sync_chat_panes(cx);
        self.persist_chat_tabs(cx);
        self.focus_composer(cx);
        cx.notify();
    }

    /// Save the tab list for the next launch: parked tabs as they were
    /// parked, the active one from the live state.
    pub(super) fn persist_chat_tabs(&mut self, cx: &mut Context<Self>) {
        if !self.boot_restored {
            return;
        }
        self.park_workspace_draft(cx);
        let mut current = self.park_chat_tab(cx);
        if current.title.is_none() {
            current.title = current
                .selected
                .as_deref()
                .and_then(|id| {
                    self.state
                        .read(cx)
                        .chats
                        .iter()
                        .find(|chat| chat.id == id)
                        .and_then(|chat| chat.title.clone())
                })
                .map(|title| transcript::single_line(&title))
                .filter(|title| !title.is_empty());
        }
        if current.id.is_empty() {
            current.id = uuid::Uuid::new_v4().to_string();
            // Migrate the running legacy project layout without rebuilding its tabs.
            let old_key = current.project.clone().unwrap_or_default();
            if let Some(layout) = self.workspace_panels.layouts.remove(&old_key) {
                self.workspace_panels
                    .layouts
                    .insert(current.id.clone(), layout);
            }
        }
        if self.chat_tabs.is_empty() {
            self.chat_tabs.push(current.clone());
            self.chat_tab = 0;
        } else if let Some(tab) = self.chat_tabs.get_mut(self.chat_tab) {
            *tab = current;
        }
        let saved: Vec<crate::settings::SavedChatTab> = self
            .chat_tabs
            .iter()
            .map(|tab| crate::settings::SavedChatTab {
                id: tab.id.clone(),
                title: tab.title.clone(),
                session_icon: tab.session_icon.clone(),
                pinned: tab.pinned,
                selected: tab.selected.clone(),
                project: tab.project.clone(),
                layout: tab.split.as_ref().map(chat_split::ChatSplit::to_saved),
                panel_layout: self.saved_workspace_panels(&tab.id, cx),
            })
            .collect();
        if saved != self.settings.chat_tabs
            || self.chat_tab != self.settings.chat_tab
            || self.settings.project_tabs_version != 2
        {
            self.settings.project_tabs_version = 2;
            self.settings.chat_tabs = saved;
            self.settings.chat_tab = self.chat_tab;
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

    /// Open a conversation in its project, or show the project picker.
    pub(super) fn new_chat_tab(
        &mut self,
        open: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(chat) = open {
            self.open_chat_preserving_tabs(chat, cx);
        } else {
            if !matches!(self.route, Route::Chat) {
                self.close_settings(cx);
            }
            self.workspace_new_chat(cx);
        }
    }

    /// Explicit moves leave no second selected/peer reference in parked tabs.
    pub(super) fn detach_chat_from_tab_snapshots(&mut self, chat_id: &str) {
        for tab in &mut self.chat_tabs {
            if tab.selected.as_deref() == Some(chat_id) {
                tab.selected = None;
            }
            if let Some(split) = tab.split.as_mut() {
                for pane in split.panes.iter_mut().chain(&mut split.vanished) {
                    if pane.as_deref() == Some(chat_id) {
                        *pane = None;
                    }
                }
            }
        }
    }

    pub(super) fn switch_chat_tab(
        &mut self,
        ix: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.activate_chat_tab(ix, cx) {
            window.focus(&self.composer.focus_handle(cx), cx);
        }
    }

    pub(super) fn activate_chat_tab(&mut self, ix: usize, cx: &mut Context<Self>) -> bool {
        if ix == self.chat_tab || ix >= self.chat_tabs.len() || !matches!(self.route, Route::Chat) {
            return false;
        }
        self.record_chat_tab_visit();
        self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        self.chat_tab = ix;
        self.record_chat_tab_visit();
        let tab = self.chat_tabs[ix].clone();
        self.load_chat_tab_without_window(tab, cx);
        true
    }

    /// ⌃Tab / ⌃⇧Tab: browser-style tab cycling once two or more tabs are
    /// open; with one tab they keep stepping through sidebar sessions.
    pub(super) fn cycle_tab_or_session(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if matches!(self.route, Route::Chat)
            && !self.overlay_owns_keyboard(cx)
            && self.workspace_cycle_tab(forward, window, cx)
        {
            return;
        }
        if self.chat_tabs.len() >= 2
            && matches!(self.route, Route::Chat)
            && !self.overlay_owns_keyboard(cx)
        {
            self.cycle_chat_tab(forward, window, cx);
        } else {
            self.cycle_session(forward, window, cx);
        }
    }

    /// ⌃1–⌃9 (Alt+digit off macOS).
    pub(super) fn select_chat_tab(
        &mut self,
        slot: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(ix) = tab_for_slot(slot, self.chat_tabs.len()) {
            self.switch_chat_tab(ix, window, cx);
        }
    }

    pub(super) fn cycle_chat_tab(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
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

    /// Close a project view. Conversations and running agents are unaffected.
    pub(super) fn close_chat_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.close_chat_tab_at(self.chat_tab, window, cx)
    }

    pub(super) fn close_chat_tab_at(
        &mut self,
        ix: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !matches!(self.route, Route::Chat) {
            return false;
        }
        if self.chat_tabs.is_empty() {
            let tab = self.park_chat_tab(cx);
            if tab.project.is_none() {
                return false;
            }
            self.chat_tabs.push(tab);
        }
        if ix >= self.chat_tabs.len() {
            return false;
        }
        self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        let closed = self.chat_tabs.remove(ix);
        self.remember_closed_chat_tab(closed, ix, cx);
        let next = tab_after_close(ix, self.chat_tabs.len() + 1, &mut self.chat_tab_history);
        if self.chat_tabs.is_empty() {
            self.chat_tab = 0;
            self.load_chat_tab(ChatTab::default(), window, cx);
        } else if ix == self.chat_tab {
            self.chat_tab = next.min(self.chat_tabs.len() - 1);
            self.load_chat_tab(self.chat_tabs[self.chat_tab].clone(), window, cx);
        } else {
            if ix < self.chat_tab {
                self.chat_tab -= 1;
            }
            self.persist_chat_tabs(cx);
        }
        cx.notify();
        true
    }

    /// A tab with chats in it joins the closed-tab stack; an empty canvas
    /// has nothing to bring back.
    pub(super) fn remember_closed_chat_tab(&mut self, tab: ChatTab, index: usize, cx: &App) {
        if tab.id.is_empty() && tab.project.is_none() && tab.chats().is_empty() {
            return;
        }
        if self.closed_chat_tabs.len() == CLOSED_TAB_LIMIT {
            self.closed_chat_tabs.remove(0);
        }
        let closed_at = self.next_chat_close_time(cx);
        self.closed_chat_tabs.push(ClosedChatTab {
            tab,
            index,
            archived: Vec::new(),
            closed_at,
            pane: false,
            replacement: None,
        });
    }

    pub(super) fn remember_closed_chat_pane(&mut self, cx: &App) {
        let tab = self.park_chat_tab(cx);
        self.remember_closed_chat_tab(tab, self.chat_tab, cx);
        if let Some(closed) = self.closed_chat_tabs.last_mut() { closed.pane = true; }
    }

    pub(super) fn remember_last_tab_canvas(&mut self, cx: &App) {
        let canvas = self.park_chat_tab(cx);
        if let Some(closed) = self.closed_chat_tabs.last_mut() {
            closed.replacement = Some(canvas);
        }
    }

    /// ⌘⇧T: reopen the most recently closed tab in its old place and show
    /// it. Repeats walk back through earlier closes; a tab whose chats were
    /// all deleted since is skipped, and with none left this does nothing.
    pub(super) fn reopen_closed_chat_tab(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let session_closed_at = self
            .closed_chat_tabs
            .last()
            .map_or(0, |closed| closed.closed_at);
        if settings::recently_closed_chats(cx)
            .first()
            .is_some_and(|closed| closed.closed_at > session_closed_at)
            && self.reopen_recently_closed_chat(window, cx)
        {
            return true;
        }
        if self.reopen_closed_chat_tab_without_window(cx) {
            window.focus(&self.composer.focus_handle(cx), cx);
            true
        } else {
            self.reopen_recently_closed_chat(window, cx)
        }
    }

    pub(super) fn reopen_closed_chat_tab_without_window(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(closed) = self.closed_chat_tabs.pop() else { return false; };
        let tab = closed.tab.clone();
        if !matches!(self.route, Route::Chat) { self.close_settings(cx); }
        if let Some(ix) = self.chat_tabs.iter().position(|open| !tab.id.is_empty() && open.id == tab.id) {
            self.activate_chat_tab(ix, cx);
            if closed.pane {
                let Some(restored) = self.restore_closed_pane(&tab, cx) else {
                    self.sidebar_notice = Some("Cannot reopen pane: the split direction changed or it is full".into());
                    self.closed_chat_tabs.push(closed);
                    cx.notify();
                    return false;
                };
                self.load_chat_tab_without_window(restored, cx);
            }
            return true;
        }
        for chat_id in &closed.archived { self.queue_close_archive(chat_id.clone(), false, cx); }
        self.record_chat_tab_visit();
        let parked = self.park_chat_tab(cx);
        if self.chat_tabs.is_empty() {
            if parked.project.is_some() || parked.selected.is_some() {
                self.chat_tabs.push(parked);
            }
        } else {
            self.chat_tabs[self.chat_tab] = parked;
        }
        let at = reopen_index(closed.index, self.chat_tabs.len());
        self.chat_tabs.insert(at, tab.clone());
        for ix in &mut self.chat_tab_history {
            if *ix >= at {
                *ix += 1;
            }
        }
        tracing::info!(at, tabs = self.chat_tabs.len(), "reopening closed chat tab");
        self.chat_tab = at;
        self.record_chat_tab_visit();
        self.load_chat_tab_without_window(tab, cx);
        true
    }

    /// Insert only the closed pane: keep any edits made in the surviving panes.
    fn restore_closed_pane(&mut self, closed: &ChatTab, cx: &App) -> Option<ChatTab> {
        let original = closed.split.as_ref()?;
        let current = self.park_chat_tab(cx);
        let mut split = current
            .split
            .clone()
            .unwrap_or_else(|| chat_split::ChatSplit {
                axis: original.axis,
                panes: vec![None],
                focus: 0,
                shares: vec![1.0],
                projects: vec![None],
                drafts: vec![None],
                vanished: vec![None],
                zoomed: false,
            });
        if split.axis != original.axis || split.panes.len() >= chat_split::MAX_CHAT_PANES {
            return None;
        }
        let index = original.focus.min(split.panes.len());
        let mut after_close = original.clone();
        after_close.close_focused();
        let unchanged_sizes = split.shares == after_close.shares;
        let share = original.shares[original.focus];
        split.panes[split.focus] = current.selected;
        split.projects[split.focus] = current.project;
        split.drafts[split.focus] = current.draft;
        for size in &mut split.shares {
            *size *= 1.0 - share;
        }
        split.panes.insert(index, None);
        split.projects.insert(index, closed.project.clone());
        split.drafts.insert(index, None);
        split.vanished.insert(index, None);
        split.shares.insert(index, share);
        if unchanged_sizes && split.shares.len() == original.shares.len() {
            split.shares.clone_from(&original.shares);
        }
        split.focus = index;
        split.zoomed = original.zoomed;
        Some(ChatTab {
            id: current.id,
            title: current.title,
            session_icon: current.session_icon,
            pinned: current.pinned,
            split: Some(split),
            selected: closed.selected.clone(),
            project: closed.project.clone(),
            draft: closed.draft.clone(),
        })
    }

    /// Includes the live pane even while Settings is covering the chat outlet.
    fn chat_still_open(&self, chat_id: &str, cx: &App) -> bool {
        self.state.read(cx).selected_chat.as_deref() == Some(chat_id)
            || self
                .chat_split
                .as_ref()
                .is_some_and(|split| split.panes.iter().any(|id| id.as_deref() == Some(chat_id)))
            || self.chat_in_other_tab(chat_id).is_some()
            || self.workspace_panels.layouts.values().any(|layout| {
                layout.panels.iter().any(|panel| {
                    panel.tabs.iter().any(
                        |tab| matches!(tab, workspace_panels::PanelTab::Chat(id) if id == chat_id),
                    )
                })
            })
    }

    /// The ✕-button archive path, under the archive-on-close setting.
    /// ⌘W supplies the saved preference to `archive_closed_session_if_idle`.
    /// No archive runs on window exit.
    pub(super) fn archive_closed_session(
        &mut self,
        chat_id: String,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> CloseArchive {
        if !settings::archive_sessions_on_close(cx) {
            return CloseArchive::Off;
        }
        self.archive_closed_session_if_idle(chat_id, window, cx)
    }

    /// Shared safety checks for a saved preference or an explicit close choice.
    pub(super) fn archive_closed_session_if_idle(
        &mut self,
        chat_id: String,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> CloseArchive {
        if self.chat_still_open(&chat_id, cx)
            || cx.windows().into_iter().any(|other| {
                other.window_id() != window.window_handle().window_id()
                    && other.downcast::<Shell>().is_some_and(|handle| {
                        handle
                            .read(cx)
                            .is_ok_and(|shell| shell.chat_still_open(&chat_id, cx))
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
                matches!(
                    session.status,
                    harness_proto::SessionStatus::Working
                        | harness_proto::SessionStatus::AwaitingInput
                )
            });
        if running {
            let notice: SharedString = "Still running — closed without archiving".into();
            self.sidebar_notice = Some(notice.clone());
            self.close_archive_notice_task = Some(cx.spawn(async move |this, cx| {
                cx.background_executor().timer(Duration::from_secs(5)).await;
                let _ = this.update(cx, |shell, cx| {
                    if shell.sidebar_notice.as_ref() == Some(&notice) {
                        shell.sidebar_notice = None;
                        cx.notify();
                    }
                });
            }));
            cx.notify();
            return CloseArchive::Running;
        }
        if let Some(closed) = self.closed_chat_tabs.last_mut()
            && closed.tab.contains_chat(&chat_id)
            && !closed.archived.contains(&chat_id)
        {
            closed.archived.push(chat_id.clone());
        }
        self.queue_close_archive(chat_id, true, cx);
        CloseArchive::Archived
    }

    /// Keep close/undo requests in order, independently of unrelated mutations.
    fn queue_close_archive(&mut self, chat_id: String, archived: bool, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.sidebar_notice = Some("Engine not connected".into());
            cx.notify();
            return;
        };
        if !archived {
            *self
                .chat_tab_unarchiving
                .entry(chat_id.clone())
                .or_default() += 1;
        }
        let requested_at = Utc::now().timestamp_millis();
        let previous = self.chat_close_archive_tasks.remove(&chat_id);
        let key = chat_id.clone();
        let task = cx.spawn(async move |this, cx| {
            if let Some(previous) = previous {
                previous.await;
            }
            let mut params = serde_json::json!({
                "op": "setChatArchived", "chatId": chat_id, "archived": archived,
            });
            if archived {
                params["archiveRequestedAt"] = requested_at.into();
            }
            let result = engine.client().call(methods::MUTATE, params).await;
            this.update(cx, |shell, cx| {
                if !archived {
                    if result.is_ok() {
                        shell.state.update(cx, |state, cx| {
                            if let Some(chat) =
                                state.chats.iter_mut().find(|chat| chat.id == chat_id)
                            {
                                chat.archived = false;
                            }
                            cx.notify();
                        });
                    }
                    if let Some(count) = shell.chat_tab_unarchiving.get_mut(&chat_id) {
                        *count -= 1;
                        if *count == 0 {
                            shell.chat_tab_unarchiving.remove(&chat_id);
                        }
                    }
                }
                if let Err(error) = result {
                    let verb = if archived { "archive" } else { "restore" };
                    shell.sidebar_notice =
                        Some(format!("Could not {verb} closed session: {error}").into());
                }
                cx.notify();
            })
            .ok();
        });
        self.chat_close_archive_tasks.insert(key, task);
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

    /// Sidebar selection stays in the owning project and focuses an existing
    /// split pane when possible.
    pub(super) fn open_chat_in_tab(
        &mut self,
        chat_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.reveal_chat_in_other_window(&chat_id, window, cx) {
            return;
        }
        let already_selected = self.state.read(cx).selected_chat.as_deref() == Some(chat_id.as_str());
        self.park_workspace_draft(cx);
        self.open_chat_preserving_tabs(chat_id, cx);
        if already_selected {
            self.composer
                .update(cx, |composer, cx| composer.reveal_pending_question(cx));
        }
        window.focus(&self.composer.focus_handle(cx), cx);
    }

    /// External navigation opens the owning project before selecting its chat.
    pub(crate) fn open_chat_preserving_tabs(&mut self, chat_id: String, cx: &mut Context<Self>) {
        if chat_split::existing_chat_selection(Some(chat_id.clone()), self.state.read(cx)).is_none() {
            return;
        }
        self.command_palette = None;
        self.route = Route::Chat;
        if self.state.read(cx).selected_chat.as_deref() == Some(chat_id.as_str()) {
            self.reveal_workspace_chat(chat_id.clone(), cx);
            self.focus_composer(cx);
            cx.notify();
            return;
        }
        if let Some(pane) =
            self.chat_split.as_ref().and_then(|split| {
                split.panes.iter().enumerate().position(|(ix, id)| {
                    ix != split.focus && id.as_deref() == Some(chat_id.as_str())
                })
            })
        {
            self.select_chat_pane(pane, cx);
            return;
        }
        // External links and notifications prefer the workspace already showing
        // the conversation. The panel history picker has its own in-panel policy.
        self.ensure_workspace_sessions(cx);
        let existing = self.chat_tabs.iter().enumerate().find(|(ix, tab)| {
            *ix != self.chat_tab && (tab.chats().iter().any(|id| id == &chat_id)
                || self.workspace_panels.layouts.get(&tab.id).is_some_and(|layout| layout.panels.iter().any(|panel| panel.tabs.iter().any(|tab| matches!(tab, workspace_panels::PanelTab::Chat(id) if id == &chat_id)))))
        }).map(|(ix, _)| ix);
        if let Some(ix) = existing {
            self.activate_chat_tab(ix, cx);
        } else if let Some(project) = self
            .state
            .read(cx)
            .chats
            .iter()
            .find(|chat| chat.id == chat_id)
            .map(|chat| chat.space_id.clone())
        {
            self.open_project_tab(project, cx);
        }
        // An already-visible peer is focused instead of duplicated.
        if let Some(pane) = self.chat_split.as_ref().and_then(|split| {
            split
                .panes
                .iter()
                .position(|id| id.as_deref() == Some(chat_id.as_str()))
        }) {
            self.select_chat_pane(pane, cx);
        } else {
            self.state
                .update(cx, |state, cx| state.select_chat(Some(chat_id), cx));
            self.chat_split_on_state_changed(cx);
        }
        self.persist_chat_tabs(cx);
        self.focus_composer(cx);
        cx.notify();
    }

    /// Project names stay stable when navigating conversations or split panes.
    fn chat_tab_labels(&self, cx: &App) -> Vec<SharedString> {
        let state = self.state.read(cx);
        let title = |project: Option<&str>| -> SharedString {
            project
                .and_then(|id| state.space_row(id))
                .map(|space| {
                    let name = transcript::single_line(space.display_name());
                    if state
                        .spaces
                        .iter()
                        .filter(|other| other.display_name() == space.display_name())
                        .count()
                        > 1
                    {
                        format!("{name} {}", state.space_device_tag(space, Utc::now()).0)
                    } else {
                        name
                    }
                })
                .unwrap_or_else(|| "No project".into())
                .into()
        };
        if self.chat_tabs.is_empty() {
            return vec![title(self.active_project(cx).as_deref())];
        }
        self.chat_tabs
            .iter()
            .enumerate()
            .map(|(ix, tab)| {
                if ix == self.chat_tab {
                    title(self.active_project(cx).as_deref())
                } else {
                    title(tab.project.as_deref())
                }
            })
            .collect()
    }

    /// One ordinary top-level tab per workspace. Splits stay inside their tab.
    pub(super) fn render_chat_tabs(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !matches!(self.route, Route::Chat) {
            return None;
        }
        let labels = self.chat_tab_labels(cx);
        let multiple = labels.len() > 1;
        let active = self.chat_tab;
        let width = f32::from(self.chat_tab_scroll.bounds().size.width);
        let reveal = (active, width.to_bits());
        if self.chat_tab_revealed != Some(reveal) && width > 0.0 {
            let item_width = SINGLE_TAB_WIDTH + 2.0 * TAB_INSET;
            let start = active as f32 * (item_width + TAB_GAP);
            let end = start + item_width;
            let current = -f32::from(self.chat_tab_scroll.offset().x);
            let offset = if start < current {
                start
            } else if end > current + width {
                end - width
            } else {
                current
            };
            self.chat_tab_scroll
                .set_offset(gpui::point(px(-offset.max(0.0)), px(0.0)));
            self.chat_tab_revealed = Some(reveal);
        }
        let drag_fill = theme.element_hover;
        let mut tabs = Vec::new();
        for (ix, title) in labels.into_iter().enumerate() {
            let selected = ix == active;
            let hover_group: SharedString = format!("top-tab-{ix}").into();
            let tooltip = title.clone();
            let header = div()
                .id(("chat-tab", ix))
                .debug_selector(move || format!("chat-tab-{ix}"))
                .group(hover_group.clone())
                .flex_none()
                .h(px(NAV_ITEM_HEIGHT))
                .w(px(SINGLE_TAB_WIDTH))
                .px(px(NAV_ITEM_INSET_X))
                .flex()
                .items_center()
                .gap(px(NAV_ITEM_GAP))
                .rounded(px(NAV_ITEM_RADIUS))
                .bg(if selected {
                    theme.active_bg(theme.element_hover)
                } else {
                    gpui::transparent_black()
                })
                .when(selected, |el| el.shadow(theme.sidebar_selected_shadows()))
                .hover(|s| {
                    s.bg(if selected {
                        theme.active_bg(theme.element_hover)
                    } else {
                        theme.element_hover
                    })
                })
                .text_size(crate::typography::ui_rems(12.5))
                .text_color(theme.text)
                .cursor_pointer()
                .role(gpui::Role::Button)
                .aria_selected(selected)
                .aria_label(title.to_string())
                .tooltip(move |_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: tooltip.clone(),
                    })
                    .into()
                })
                .block_mouse_except_scroll()
                .on_mouse_down(MouseButton::Left, |_, window, cx| {
                    window.prevent_default();
                    cx.stop_propagation();
                })
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.switch_chat_tab(ix, window, cx);
                }))
                .when(multiple && crate::click_activation_drag_enabled(), |el| {
                    el.on_drag(
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
                        style.bg(drag_fill)
                    }
                })
                .on_drop(cx.listener(move |this, drag: &ChatTabDrag, _, cx| {
                    this.move_chat_tab(drag.from, ix, cx)
                }))
                .child(
                    icon(icons::FOLDER)
                        .size(px(13.0))
                        .flex_none()
                        .text_color(theme.text_muted),
                )
                .child(div().flex_1().min_w_0().truncate().child(title))
                .when(multiple || self.active_project(cx).is_some(), |el| {
                    el.child(
                        div()
                            .id(("chat-tab-close", ix))
                            .debug_selector(move || format!("chat-tab-close-{ix}"))
                            .size(px(16.0))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(4.0))
                            .opacity(0.0)
                            .group_hover(hover_group, |s| s.opacity(1.0))
                            .hover(|s| s.bg(theme.ink(0.10)))
                            .role(gpui::Role::Button)
                            .aria_label("Close project tab")
                            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                                window.prevent_default();
                                cx.stop_propagation();
                            })
                            .on_click(cx.listener(move |this, _, window, cx| {
                                cx.stop_propagation();
                                this.close_chat_tab_at(ix, window, cx);
                            }))
                            .child(
                                icon(icons::CLOSE)
                                    .size(px(11.0))
                                    .text_color(theme.text_muted),
                            ),
                    )
                });
            tabs.push(
                div()
                    .flex_none()
                    .p(px(TAB_INSET))
                    .child(header)
                    .into_any_element(),
            );
        }
        Some(
            div()
                .id("chat-tabs")
                .debug_selector(|| "top-chat-tabs".into())
                .flex_1()
                .min_w_0()
                .h(px(38.0))
                .overflow_hidden()
                .child(
                    div()
                        .id("chat-tab-rows")
                        .size_full()
                        .overflow_x_scroll()
                        .track_scroll(&self.chat_tab_scroll)
                        .flex()
                        .items_center()
                        .gap(px(TAB_GAP))
                        .children(tabs),
                )
                .into_any_element(),
        )
    }
    pub(super) fn render_top_tab_bar(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::of(cx).clone();
        let left = if cfg!(target_os = "macos") {
            titlebar_cluster_start(self.fullscreen.unwrap_or(false))
        } else {
            10.0 + caption_buttons_width(self.linux_left_caption_count())
        };
        let tabs = self.render_chat_tabs(&theme, cx);
        let row = div()
            .h(px(TOP_TAB_HEIGHT))
            .flex_none()
            .flex()
            .items_center()
            .gap(px(6.0))
            .pl(px(left))
            .pr(px(self.titlebar_right_pad(10.0)))
            .child(self.render_sidebar_toggle(cx))
            .children(tabs)
            .child(self.render_project_picker(&theme, cx))
            .child(div().w(px(16.0)).flex_none());
        self.titlebar_drag_region("top-tab-bar", row, cx)
            .into_any_element()
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
            settings::init(settings::UiSettings::expanded(), path, cx);
        });
    }

    fn archive_test_chat(id: &str) -> harness_proto::Chat {
        serde_json::from_value(serde_json::json!({
            "id": id, "deviceId": "local", "archived": false, "createdAt": chrono::Utc::now(),
        }))
        .unwrap()
    }

    fn running_notice_test_window(
        cx: &mut gpui::TestAppContext,
        path: &std::path::Path,
    ) -> gpui::WindowHandle<Shell> {
        let window = archive_test_window(cx, path);
        window
            .update(cx, |shell, _, cx| {
                settings::set_archive_sessions_on_close(true, cx);
                shell.state.update(cx, |state, _| {
                    state.chats = ["keep", "closing"].map(archive_test_chat).into();
                    state.selected_chat = Some("keep".into());
                    state.sessions.push(harness_proto::Session {
                        chat_id: "closing".into(),
                        device_id: "local".into(),
                        status: harness_proto::SessionStatus::Working,
                        started_at: None,
                        updated_at: chrono::Utc::now(),
                        last_completed_turn: None,
                        last_completed_peer_only: false,
                    });
                });
            })
            .unwrap();
        window
    }

    #[gpui::test]
    fn close_archive_running_notice_expires_without_clearing_newer_notices(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = running_notice_test_window(cx, dir.path());
        let show_notice = |cx: &mut gpui::TestAppContext| {
            window
                .update(cx, |shell, window, cx| {
                    assert_eq!(
                        shell.archive_closed_session_if_idle("closing".into(), window, cx),
                        CloseArchive::Running
                    );
                    assert_eq!(
                        shell.sidebar_notice.as_deref(),
                        Some("Still running — closed without archiving")
                    );
                })
                .unwrap();
            cx.run_until_parked();
        };
        show_notice(cx);
        cx.executor().advance_clock(Duration::from_secs(4));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_some()))
            .unwrap();
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, cx| {
                assert!(
                    shell.sidebar_notice.is_none(),
                    "warning expires after five seconds"
                );
                assert!(!shell.state.read(cx).chats[1].archived);
                assert_eq!(
                    shell.state.read(cx).sessions[0].status,
                    harness_proto::SessionStatus::Working,
                    "dismissing the warning must not stop the session"
                );
            })
            .unwrap();

        // Repeating the same warning starts a fresh five-second interval.
        show_notice(cx);
        cx.executor().advance_clock(Duration::from_secs(4));
        cx.run_until_parked();
        show_notice(cx);
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_some()))
            .unwrap();
        cx.executor().advance_clock(Duration::from_secs(4));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_none()))
            .unwrap();

        // An unrelated error replacing the warning must remain visible.
        show_notice(cx);
        window
            .update(cx, |shell, _, _| {
                shell.sidebar_notice = Some("Archive request failed".into());
            })
            .unwrap();
        cx.executor().advance_clock(Duration::from_secs(5));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| {
                assert_eq!(
                    shell.sidebar_notice.as_deref(),
                    Some("Archive request failed")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn close_archive_notice_expires_at_five_seconds_for_all_active_states(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        for case in ["working", "waiting", "pending", "queued"] {
            let window = running_notice_test_window(cx, dir.path());
            window
                .update(cx, |shell, window, cx| {
                    shell.state.update(cx, |state, _| {
                        let now = chrono::Utc::now();
                        state.local_device_id = Some("local".into());
                        if matches!(case, "pending" | "queued") {
                            state.sessions.clear();
                            if case == "queued" {
                                state.chats[1].device_id = "remote".into();
                                state.connectivity.state =
                                    harness_proto::ConnectivityState::Offline;
                            }
                            state.begin_pending_send("closing", "synthetic-send", now);
                            assert_eq!(state.send_queued("closing", now), case == "queued");
                        } else {
                            state.sessions[0].status = if case == "waiting" {
                                harness_proto::SessionStatus::AwaitingInput
                            } else {
                                harness_proto::SessionStatus::Working
                            };
                            state.sessions[0].updated_at = now - chrono::Duration::hours(1);
                        }
                    });
                    assert_eq!(
                        shell.archive_closed_session_if_idle("closing".into(), window, cx),
                        CloseArchive::Running,
                        "{case}"
                    );
                })
                .unwrap();
            cx.run_until_parked();
            cx.executor().advance_clock(Duration::from_millis(4999));
            cx.run_until_parked();
            window
                .update(cx, |shell, _, _| {
                    assert!(
                        shell.sidebar_notice.is_some(),
                        "{case}: not before five seconds"
                    );
                })
                .unwrap();
            cx.executor().advance_clock(Duration::from_millis(1));
            cx.run_until_parked();
            window
                .update(cx, |shell, window, cx| {
                    assert!(
                        shell.sidebar_notice.is_none(),
                        "{case}: expires at five seconds"
                    );
                    let state = shell.state.read(cx);
                    assert!(!state.chats[1].archived, "{case}");
                    if matches!(case, "pending" | "queued") {
                        assert!(state.send_pending("closing", chrono::Utc::now()), "{case}");
                    } else {
                        assert_eq!(
                            state.sessions[0].status,
                            if case == "waiting" {
                                harness_proto::SessionStatus::AwaitingInput
                            } else {
                                harness_proto::SessionStatus::Working
                            },
                            "{case}: session status is unchanged"
                        );
                    }
                    window.remove_window();
                })
                .unwrap();
        }
    }

    #[gpui::test]
    fn close_archive_notice_can_be_dismissed_and_reshown_in_a_burst(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let window = running_notice_test_window(cx, dir.path());
        window
            .update(cx, |shell, window, cx| {
                shell.archive_closed_session_if_idle("closing".into(), window, cx);
                // The sidebar's click-to-dismiss handler clears this field.
                shell.sidebar_notice = None;
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(4));
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                assert!(shell.sidebar_notice.is_none());
                // Several closes in one update, before any timer task is polled.
                for _ in 0..3 {
                    assert_eq!(
                        shell.archive_closed_session_if_idle("closing".into(), window, cx),
                        CloseArchive::Running
                    );
                }
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| {
                assert!(
                    shell.sidebar_notice.is_some(),
                    "old timer cannot clear new warning"
                );
            })
            .unwrap();
        cx.executor().advance_clock(Duration::from_millis(3999));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_some()))
            .unwrap();
        cx.executor().advance_clock(Duration::from_millis(1));
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_none()))
            .unwrap();
    }

    #[gpui::test]
    fn close_archive_notice_timers_are_independent_between_windows(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        let first = running_notice_test_window(cx, dir.path());
        let second = running_notice_test_window(cx, dir.path());
        first
            .update(cx, |shell, window, cx| {
                assert_eq!(
                    shell.archive_closed_session_if_idle("closing".into(), window, cx),
                    CloseArchive::Running
                );
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(2));
        cx.run_until_parked();
        second
            .update(cx, |shell, window, cx| {
                assert_eq!(
                    shell.archive_closed_session_if_idle("closing".into(), window, cx),
                    CloseArchive::Running
                );
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(3));
        cx.run_until_parked();
        first
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_none()))
            .unwrap();
        second
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_some()))
            .unwrap();
        cx.executor().advance_clock(Duration::from_secs(2));
        cx.run_until_parked();
        second
            .update(cx, |shell, _, _| assert!(shell.sidebar_notice.is_none()))
            .unwrap();
    }

    #[gpui::test]
    fn close_archive_notice_timer_is_safe_when_its_window_closes(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        init_archive_test(cx, dir.path());
        for timer_started in [false, true] {
            let window = running_notice_test_window(cx, dir.path());
            window
                .update(cx, |shell, window, cx| {
                    shell.archive_closed_session_if_idle("closing".into(), window, cx);
                })
                .unwrap();
            if timer_started {
                cx.run_until_parked();
            }
            window
                .update(cx, |_, window, _| window.remove_window())
                .unwrap();
            cx.run_until_parked();
            cx.executor().advance_clock(Duration::from_secs(5));
            cx.run_until_parked();
            cx.update(|cx| assert!(window.read(cx).is_err()));
        }
    }

    #[gpui::test]
    fn closing_project_tabs_never_dispatches_archive(cx: &mut gpui::TestAppContext) {
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
    fn close_pane_archive_dispatches_without_cancelling_prior_closes(
        cx: &mut gpui::TestAppContext,
    ) {
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
                        None,
                        SplitAxis::Horizontal,
                        Some("keep".into()),
                        None,
                    );
                    shell.chat_split = chat_split::ChatSplit::split(
                        split,
                        SplitAxis::Horizontal,
                        Some("second".into()),
                        None,
                    );
                }
                assert!(shell.close_focused_chat_pane(window, cx));
                assert!(shell.close_focused_chat_pane(window, cx));
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("keep"));
                if !panes {
                    assert!(shell.close_focused_chat_pane(window, cx));
                    assert!(shell.state.read(cx).selected_chat.is_none());
                }
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
        if !panes {
            assert!(
                archived.is_empty(),
                "closing projects must not archive conversations"
            );
            return;
        }
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
                                last_completed_peer_only: false,
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
        let order =
            |from, to| -> Vec<usize> { (0..4).map(|ix| index_after_move(ix, from, to)).collect() };
        // Tab 0 dragged onto tab 2: 1 and 2 shift left.
        assert_eq!(order(0, 2), [2, 0, 1, 3]);
        // Tab 3 dragged onto tab 1: 1 and 2 shift right.
        assert_eq!(order(3, 1), [0, 2, 3, 1]);
        assert_eq!(order(2, 2), [0, 1, 2, 3]);
    }

    #[gpui::test]
    fn close_tab_without_archiving_bypasses_enabled_preference(cx: &mut gpui::TestAppContext) {
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
        cx.update(|cx| settings::set_archive_sessions_on_close(true, cx));
        window
            .update(cx, |shell, window, cx| {
                window.activate_window();
                shell.route = Route::Chat;
                shell.state.update(cx, |state, _| {
                    state.chats = ["keep", "closing", "pane"].map(archive_test_chat).into();
                    state.selected_chat = Some("closing".into());
                    state.set_test_engine(engine);
                });
                shell.boot_restored = true;
                shell.chat_tabs = [("keep-session", "keep"), ("closing-session", "closing")]
                    .map(|(id, chat)| {
                        let mut layout = workspace_panels::WorkspaceLayout::default();
                        layout.panels[0].tabs = vec![workspace_panels::PanelTab::Chat(chat.into())];
                        shell.workspace_panels.layouts.insert(id.into(), layout);
                        ChatTab {
                            id: id.into(),
                            selected: Some(chat.into()),
                            ..Default::default()
                        }
                    })
                    .into();
                shell.chat_tab = 1;
                shell.workspace_split(SplitAxis::Horizontal, cx);
                let layout = shell.panel_layout_mut(cx);
                let panel = layout
                    .panels
                    .iter_mut()
                    .rfind(|panel| !panel.tabs.is_empty());
                let panel = panel.unwrap();
                panel.tabs = vec![workspace_panels::PanelTab::Chat("pane".into())];
                panel.active = 0;
                let panel = panel.id;
                shell.focus_workspace_tab(
                    panel,
                    workspace_panels::PanelTab::Chat("pane".into()),
                    window,
                    cx,
                );
            })
            .unwrap();
        // Close the split panel with its only tab, then its neighbor's last
        // chat, which moves on to a new one. Repeating the shortcut there must
        // leave the window and both sessions open.
        for expected_panels in [
            vec![vec!["closing"]],
            vec![vec!["new chat"]],
            vec![vec!["new chat"]],
        ] {
            cx.update(|cx| cx.dispatch_action(&crate::app_menus::CloseTabWithoutArchiving));
            cx.run_until_parked();
            window
                .update(cx, |shell, _, cx| {
                    let layout = shell.panel_layout(cx).unwrap();
                    let panels: Vec<Vec<&str>> = layout
                        .panels
                        .iter()
                        .map(|panel| {
                            panel
                                .tabs
                                .iter()
                                .map(|tab| match tab {
                                    workspace_panels::PanelTab::Chat(id) => id.as_str(),
                                    workspace_panels::PanelTab::Draft(_) => "new chat",
                                    other => panic!("unexpected tab {other:?}"),
                                })
                                .collect()
                        })
                        .collect();
                    assert_eq!(panels, expected_panels);
                    if panels.last().unwrap() == &["new chat"] {
                        assert_eq!(shell.state.read(cx).selected_chat, None);
                    }
                    assert_eq!(shell.chat_tabs.len(), 2);
                    assert_eq!(shell.chat_tabs[shell.chat_tab].id, "closing-session");
                    assert_eq!(
                        shell.workspace_panels.layouts["keep-session"].panels[0].tabs,
                        [workspace_panels::PanelTab::Chat("keep".into())]
                    );
                    assert!(shell.state.read(cx).chats.iter().all(|chat| !chat.archived));
                    assert!(settings::archive_sessions_on_close(cx));
                    assert!(shell.sidebar_notice.is_none());
                })
                .unwrap();
            while let Ok(request) = requests.try_recv() {
                let request: serde_json::Value = serde_json::from_str(&request).unwrap();
                assert_ne!(
                    request["method"],
                    methods::MUTATE,
                    "unexpected archive: {request}"
                );
            }
        }
    }

    #[test]
    fn a_closed_tab_keeps_only_chats_that_still_exist() {
        let mut split =
            chat_split::ChatSplit::split(None, SplitAxis::Horizontal, Some("a".into()), None)
                .unwrap();
        split.panes[1] = Some("gone".into());
        let tab = ChatTab {
            selected: Some("a".into()),
            split: Some(split),
            ..Default::default()
        };
        assert_eq!(tab.chats(), ["a", "gone"]);
        let kept = tab.clone().without_deleted(|id| id == "a").unwrap();
        assert_eq!(kept.chats(), ["a"]);
        // A session outlives its chats.
        assert!(tab.without_deleted(|_| false).unwrap().chats().is_empty());
        // Its old place, or the end once the list is shorter.
        assert_eq!(reopen_index(1, 3), 1);
        assert_eq!(reopen_index(4, 2), 2);
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
