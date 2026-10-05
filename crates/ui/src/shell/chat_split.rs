//! Ghostty-style split chat panes: ⌘D / ⌘⇧D split the conversation column,
//! ⌘[ / ⌘] and ⌘⌥+arrows move focus, ⌘⌃+arrows resize, ⌘⌃= equalizes,
//! ⌘⇧↩ zooms and ⌘W closes the focused pane.
//!
//! App state has ONE selected chat, and it owns the composer, queue and
//! everything chat-scoped. So the focused pane always IS the selected chat
//! (the ordinary transcript + composer column); every other pane is a live
//! read-only transcript of its chat. Moving focus swaps: the target pane's
//! chat becomes the selection and the old selection takes the pane it left.

use super::*;
use crate::pickers::CanvasDraft;

mod opening;

/// Every pane holds another engine doc watch; Ghostty-scale grids aren't
/// the point of a chat column.
pub(super) const MAX_CHAT_PANES: usize = 8;
/// No pane gets squeezed below this share of the split (less once so many
/// panes are open that equal shares fall under it; see `min_share`).
const MIN_PANE_SHARE: f32 = 0.15;
/// One ⌘⌃+arrow press moves the divider by this share.
const RESIZE_STEP: f32 = 0.05;
const JUMP_KEYS: [(&str, &str); MAX_CHAT_PANES] = [
    ("chat-pane-jump-0", "chat-pane-jump-pill-0"),
    ("chat-pane-jump-1", "chat-pane-jump-pill-1"),
    ("chat-pane-jump-2", "chat-pane-jump-pill-2"),
    ("chat-pane-jump-3", "chat-pane-jump-pill-3"),
    ("chat-pane-jump-4", "chat-pane-jump-pill-4"),
    ("chat-pane-jump-5", "chat-pane-jump-pill-5"),
    ("chat-pane-jump-6", "chat-pane-jump-pill-6"),
    ("chat-pane-jump-7", "chat-pane-jump-pill-7"),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PaneDirection {
    Left,
    Right,
    Up,
    Down,
}

/// Pure split layout. `panes[focus]` is a placeholder for the selected chat;
/// every other slot names the chat it shows (`None` = an empty pane that
/// becomes a new-session canvas when focused).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct ChatSplit {
    pub axis: SplitAxis,
    pub panes: Vec<Option<String>>,
    pub focus: usize,
    /// Each pane's share of the column along `axis`; sums to 1.
    pub shares: Vec<f32>,
    /// Each pane's sidebar project filter (space id; `None` = all).
    pub projects: Vec<Option<String>>,
    /// Each unfocused pane's parked composer picks (the focused pane's are
    /// live in the pickers); only a new-session canvas pane reads its own.
    pub drafts: Vec<Option<CanvasDraft>>,
    /// The chat each empty unfocused pane showed before a chats frame arrived
    /// without it. It goes back in when a later frame lists it again.
    pub vanished: Vec<Option<String>>,
    pub zoomed: bool,
}

impl ChatSplit {
    /// Split the focused pane: `selected` moves into the old slot and the new
    /// pane after it takes focus as a fresh canvas. Returns `None` at the cap
    /// or when an existing split runs along the other axis.
    pub fn split(
        existing: Option<Self>,
        axis: SplitAxis,
        selected: Option<String>,
        project: Option<String>,
    ) -> Option<Self> {
        let mut split = existing.unwrap_or(Self {
            axis,
            panes: vec![None],
            focus: 0,
            shares: vec![1.0],
            projects: vec![project],
            drafts: vec![None],
            vanished: vec![None],
            zoomed: false,
        });
        if split.axis != axis || split.panes.len() >= MAX_CHAT_PANES {
            return None;
        }
        split.panes[split.focus] = selected;
        let at = split.focus + 1;
        // Every ⌘D leaves all panes the same size, rather than halving the
        // pane it split (user request, 2026-09-26).
        split.panes.insert(at, None);
        split.shares.insert(at, 0.0);
        split.equalize();
        // The new pane starts in the project of the pane it split from.
        let project = split.projects[split.focus].clone();
        split.projects.insert(at, project);
        split.drafts.insert(at, None);
        split.vanished.insert(at, None);
        split.focus = at;
        split.zoomed = false;
        Some(split)
    }

    /// Focus pane `ix`: the current selection parks in the pane being left
    /// and the chat `ix` showed is returned for selection.
    pub fn focus_pane(&mut self, ix: usize, selected: Option<String>) -> Option<Option<String>> {
        if ix >= self.panes.len() || ix == self.focus {
            return None;
        }
        self.panes[self.focus] = selected;
        let target = self.panes[ix].take();
        // Focusing an emptied pane makes it a canvas; its lost chat stays lost.
        self.vanished[ix] = None;
        self.focus = ix;
        self.zoomed = false;
        Some(target)
    }

    /// The smallest share a divider may leave a pane: `MIN_PANE_SHARE`, or
    /// half an equal share when that many panes can't all reach it.
    fn min_share(&self) -> f32 {
        MIN_PANE_SHARE.min(0.5 / self.panes.len() as f32)
    }

    pub fn cycled(&self, forward: bool) -> usize {
        let len = self.panes.len();
        if forward {
            (self.focus + 1) % len
        } else {
            (self.focus + len - 1) % len
        }
    }

    /// The neighbor in `direction`, if the split runs that way.
    pub fn toward(&self, direction: PaneDirection) -> Option<usize> {
        let back = match (self.axis, direction) {
            (SplitAxis::Horizontal, PaneDirection::Left)
            | (SplitAxis::Vertical, PaneDirection::Up) => true,
            (SplitAxis::Horizontal, PaneDirection::Right)
            | (SplitAxis::Vertical, PaneDirection::Down) => false,
            _ => return None,
        };
        if back {
            self.focus.checked_sub(1)
        } else {
            Some(self.focus + 1).filter(|&ix| ix < self.panes.len())
        }
    }

    /// Move the focused pane's far divider (its near one for the last pane)
    /// toward `direction`. Returns false when the split runs the other way.
    pub fn resize(&mut self, direction: PaneDirection) -> bool {
        let grow = match (self.axis, direction) {
            (SplitAxis::Horizontal, PaneDirection::Right)
            | (SplitAxis::Vertical, PaneDirection::Down) => true,
            (SplitAxis::Horizontal, PaneDirection::Left)
            | (SplitAxis::Vertical, PaneDirection::Up) => false,
            _ => return false,
        };
        if self.panes.len() < 2 {
            return false;
        }
        // The divider after the focused pane, or before it for the last one.
        let (a, b) = if self.focus + 1 < self.panes.len() {
            (self.focus, self.focus + 1)
        } else {
            (self.focus - 1, self.focus)
        };
        let delta = if grow { RESIZE_STEP } else { -RESIZE_STEP };
        let total = self.shares[a] + self.shares[b];
        // Repeated splits halve shares (4 panes: 0.5/0.25/0.125/0.125), so
        // two neighbors can sum below 2×MIN; an unguarded clamp(min > max)
        // panicked and took the whole app down. Same guard as drag_divider.
        let min = self.min_share().min(total / 2.0);
        let first = (self.shares[a] + delta).clamp(min, total - min);
        self.shares[a] = first;
        self.shares[b] = total - first;
        self.zoomed = false;
        true
    }

    /// Drag the divider before pane `divider` (between it and the pane
    /// ahead of it) by `delta` of the whole column, from `start` shares.
    /// Only those two panes change; neither goes below the minimum share.
    pub fn drag_divider(&mut self, start: &[f32], divider: usize, delta: f32) {
        if divider == 0 || divider >= self.shares.len() || start.len() != self.shares.len() {
            return;
        }
        self.shares.copy_from_slice(start);
        let total = start[divider - 1] + start[divider];
        let min = self.min_share().min(total / 2.0);
        let first = (start[divider - 1] + delta).clamp(min, total - min);
        self.shares[divider - 1] = first;
        self.shares[divider] = total - first;
        self.zoomed = false;
    }

    /// Ghostty's equalize_splits: every pane weighs one leaf, so a flat
    /// split along one axis gets equal shares.
    pub fn equalize(&mut self) {
        let share = 1.0 / self.panes.len() as f32;
        self.shares.iter_mut().for_each(|s| *s = share);
    }

    /// Close the focused pane. An even split stays even; otherwise its share
    /// goes to the neighbor that takes focus, keeping dragged sizes. The
    /// neighbor's chat is returned for selection. `None` means the split is
    /// down to one pane and should be dropped.
    pub fn close_focused(&mut self) -> Option<Option<String>> {
        if self.panes.len() <= 1 {
            return None;
        }
        let even = self.is_even();
        let closed = self.focus;
        let share = self.shares.remove(closed);
        self.panes.remove(closed);
        self.projects.remove(closed);
        self.drafts.remove(closed);
        self.vanished.remove(closed);
        let next = closed.saturating_sub(1).min(self.panes.len() - 1);
        self.shares[next] += share;
        if even {
            self.equalize();
        }
        self.focus = next;
        self.zoomed = false;
        self.vanished[next] = None;
        Some(self.panes[next].take())
    }

    fn is_even(&self) -> bool {
        let share = 1.0 / self.shares.len() as f32;
        self.shares.iter().all(|s| (s - share).abs() < 1e-3)
    }

    /// The selection moved from `previous` to `selected` outside the split
    /// (sidebar click, ⌘1–9, a deep link). When the new chat already sits in
    /// an unfocused pane, focus moves to that pane and every pane keeps its
    /// place; the old focused pane keeps showing `previous`. Swapping the two
    /// panes instead made a chat jump from the far right into the middle
    /// (user report, 2026-09-26). Returns the pane focus left, if it moved.
    pub fn selection_changed(&mut self, previous: Option<String>, selected: Option<&str>) -> Option<usize> {
        let selected = selected?;
        let ix = self
            .panes
            .iter()
            .position(|pane| pane.as_deref() == Some(selected))?;
        let from = self.focus;
        self.panes[from] = previous;
        self.panes[ix] = None;
        self.focus = ix;
        self.zoomed = false;
        Some(from)
    }

    /// Empty the panes whose chat is gone from the chats list. `archived(id)`
    /// is `None` when the list lacks the chat, else whether it is archived.
    /// An archived chat's pane simply closes; a missing chat is remembered,
    /// because a list can lack a chat only briefly and emptying the pane for
    /// good turned it into a new-session canvas (user report, 2026-09-29).
    pub fn prune(&mut self, archived: impl Fn(&str) -> Option<bool>) {
        for (pane, vanished) in self.panes.iter_mut().zip(self.vanished.iter_mut()) {
            match pane.as_deref().map(&archived) {
                Some(None) => {
                    *vanished = pane.take();
                    tracing::info!(chat = vanished.as_deref(), "split pane's chat left the chats list");
                }
                Some(Some(true)) => *pane = None,
                _ => {}
            }
        }
    }

    /// Put each remembered chat back in its pane once `live` lists it again,
    /// unless the pane has been focused or filled since.
    pub fn restore_returned(&mut self, live: impl Fn(&str) -> bool) {
        for (ix, (pane, vanished)) in self.panes.iter_mut().zip(self.vanished.iter_mut()).enumerate() {
            if pane.is_some() || ix == self.focus {
                *vanished = None;
            } else if let Some(id) = vanished.take_if(|id| live(id)) {
                tracing::info!(chat = %id, "chat is back in the chats list; restoring its split pane");
                *pane = Some(id);
            }
        }
    }

    pub fn to_saved(&self) -> crate::settings::SavedChatLayout {
        crate::settings::SavedChatLayout {
            vertical: self.axis == SplitAxis::Vertical,
            panes: self.panes.clone(),
            focus: self.focus,
            shares: self.shares.clone(),
            projects: self.projects.clone(),
        }
    }

    /// Rebuild a saved layout. Chats that no longer exist (`live` says
    /// no) come back as empty panes; a malformed save restores nothing.
    pub fn from_saved(saved: &crate::settings::SavedChatLayout, live: impl Fn(&str) -> bool) -> Option<Self> {
        let len = saved.panes.len();
        if !(2..=MAX_CHAT_PANES).contains(&len)
            || saved.shares.len() != len
            || saved.focus >= len
            || saved.shares.iter().any(|s| !s.is_finite() || *s <= 0.0)
        {
            return None;
        }
        let total: f32 = saved.shares.iter().sum();
        let mut projects = saved.projects.clone();
        projects.resize(len, None);
        Some(Self {
            axis: if saved.vertical { SplitAxis::Vertical } else { SplitAxis::Horizontal },
            panes: saved
                .panes
                .iter()
                .enumerate()
                .map(|(ix, pane)| pane.clone().filter(|id| ix != saved.focus && live(id)))
                .collect(),
            focus: saved.focus,
            shares: saved.shares.iter().map(|s| s / total).collect(),
            projects,
            drafts: vec![None; len],
            vanished: vec![None; len],
            zoomed: false,
        })
    }

    /// Chats shown by unfocused panes.
    pub fn peer_chats(&self) -> impl Iterator<Item = &str> {
        self.panes
            .iter()
            .enumerate()
            .filter(|(ix, _)| *ix != self.focus)
            .filter_map(|(_, pane)| pane.as_deref())
    }
}

/// Ghostty's split keys: its macOS defaults, and its GTK ones elsewhere
/// (Ctrl+Shift/Super combos, so bare Ctrl+letter stays with text inputs).
pub(super) fn chat_split_bindings(mac: bool) -> Vec<KeyBinding> {
    let b = |mac_combo: &str, other: &str| if mac { mac_combo.to_owned() } else { other.to_owned() };
    vec![
        KeyBinding::new(&b("cmd-d", "ctrl-shift-o"), SplitChatRight, None),
        KeyBinding::new(&b("cmd-shift-d", "ctrl-shift-e"), SplitChatDown, None),
        KeyBinding::new(&b("cmd-]", "ctrl-super-]"), FocusNextChatPane, None),
        KeyBinding::new(&b("cmd-[", "ctrl-super-["), FocusPrevChatPane, None),
        KeyBinding::new(&b("cmd-alt-left", "ctrl-alt-left"), FocusChatPaneLeft, None),
        KeyBinding::new(&b("cmd-alt-right", "ctrl-alt-right"), FocusChatPaneRight, None),
        KeyBinding::new(&b("cmd-alt-up", "ctrl-alt-up"), FocusChatPaneUp, None),
        KeyBinding::new(&b("cmd-alt-down", "ctrl-alt-down"), FocusChatPaneDown, None),
        KeyBinding::new(&b("cmd-ctrl-left", "ctrl-super-shift-left"), ResizeChatPaneLeft, None),
        KeyBinding::new(&b("cmd-ctrl-right", "ctrl-super-shift-right"), ResizeChatPaneRight, None),
        KeyBinding::new(&b("cmd-ctrl-up", "ctrl-super-shift-up"), ResizeChatPaneUp, None),
        KeyBinding::new(&b("cmd-ctrl-down", "ctrl-super-shift-down"), ResizeChatPaneDown, None),
        KeyBinding::new(&b("cmd-ctrl-=", "ctrl-super-shift-="), EqualizeChatPanes, None),
        KeyBinding::new(&b("cmd-shift-enter", "ctrl-shift-enter"), ToggleChatPaneZoom, None),
        // Jump to the message box from anywhere (the browser keeps ⌘L for
        // its address bar: its Browser-scoped binding is bound later).
        KeyBinding::new(&b("cmd-l", "ctrl-shift-l"), FocusComposer, None),
        // Chat tabs (`chat_tabs.rs`): Safari/Terminal's keys on macOS.
        KeyBinding::new(&b("cmd-t", "ctrl-shift-t"), NewChatTab, None),
        KeyBinding::new(&b("cmd-shift-]", "ctrl-pagedown"), NextChatTab, None),
        KeyBinding::new(&b("cmd-shift-[", "ctrl-pageup"), PrevChatTab, None),
    ]
}

/// An in-progress divider drag: which divider, where the pointer went down
/// (along the split axis) and the shares at that moment.
pub(super) struct DividerDrag {
    divider: usize,
    origin: f32,
    start: Vec<f32>,
}

/// A live read-only transcript for one unfocused pane's chat.
pub(super) struct PeerChatView {
    pub transcript: Entity<Transcript>,
    _events: Subscription,
}

impl Shell {
    fn chat_split_active(&self) -> bool {
        matches!(self.route, Route::Chat) && self.chat_split.is_some()
    }

    pub(super) fn split_chat(&mut self, axis: SplitAxis, window: &mut Window, cx: &mut Context<Self>) {
        self.split_chat_opening(axis, None, window, cx);
    }

    /// Whether a new split along `axis` is possible right now.
    fn can_split(&self, axis: SplitAxis) -> bool {
        self.chat_split
            .as_ref()
            .is_none_or(|s| s.axis == axis && s.panes.len() < MAX_CHAT_PANES)
    }

    pub(super) fn focus_chat_pane(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) {
        let selected = self.state.read(cx).selected_chat.clone();
        let draft = self.current_canvas_draft(cx);
        let Some(split) = self.chat_split.as_mut() else {
            return;
        };
        let from = split.focus;
        let Some(target) = split.focus_pane(ix, selected) else {
            return;
        };
        // Each pane keeps its own workspace and composer picks: park the
        // live ones in the pane being left and bring the target pane's back.
        split.projects[from] = self.settings.space_filter.clone();
        split.drafts[from] = Some(draft);
        let project = split.projects[ix].clone();
        let target_draft = split.drafts[ix].take().filter(|_| target.is_none());
        self.chat_split_selected = target.clone();
        self.state.update(cx, |s, cx| s.select_chat(target, cx));
        // Filter first: on a canvas it re-aims the project, and the pane's
        // own parked project must have the last word.
        self.set_space_filter(project, cx);
        self.adopt_canvas_draft(target_draft, cx);
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    /// A press released on an unfocused pane: a plain click focuses it, but
    /// a drag that selected text there keeps its selection (and the pane
    /// stays unfocused) so the text can be copied.
    pub(super) fn release_on_peer_pane(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) {
        if crate::markdown::selection::selected_text().is_some() {
            return;
        }
        self.focus_chat_pane(ix, window, cx);
    }

    pub(super) fn cycle_chat_pane(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(ix) = self.chat_split.as_ref().map(|split| split.cycled(forward)) {
            self.focus_chat_pane(ix, window, cx);
        }
    }

    pub(super) fn focus_chat_pane_toward(
        &mut self,
        direction: PaneDirection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(ix) = self.chat_split.as_ref().and_then(|s| s.toward(direction)) {
            self.focus_chat_pane(ix, window, cx);
        }
    }

    pub(super) fn resize_chat_pane(&mut self, direction: PaneDirection, cx: &mut Context<Self>) {
        if let Some(split) = self.chat_split.as_mut()
            && split.resize(direction)
        {
            self.persist_chat_layout(cx);
            cx.notify();
        }
    }

    pub(super) fn equalize_chat_panes(&mut self, cx: &mut Context<Self>) {
        if let Some(split) = self.chat_split.as_mut() {
            split.equalize();
            self.persist_chat_layout(cx);
            cx.notify();
        }
    }

    pub(super) fn toggle_chat_pane_zoom(&mut self, cx: &mut Context<Self>) {
        if let Some(split) = self.chat_split.as_mut() {
            split.zoomed = !split.zoomed;
            cx.notify();
        }
    }

    /// Close pane `ix`, focused or not (a pane's own close button). Closing an
    /// unfocused pane focuses it first, so it closes the way ⌘W would.
    pub(super) fn close_chat_pane(
        &mut self,
        ix: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(split) = self.chat_split.as_ref() else {
            return false;
        };
        if ix >= split.panes.len() {
            return false;
        }
        if split.focus != ix {
            self.focus_chat_pane(ix, window, cx);
        }
        self.close_focused_chat_pane(window, cx)
    }

    /// ⌘W with a split open closes the focused pane (not the window); with
    /// one pane left it closes the tab. Either can archive the closed session
    /// ([`Shell::archive_closed_session`]).
    pub(crate) fn close_focused_chat_pane(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.close_focused_chat_pane_archiving(window, cx).0
    }

    /// [`Self::close_focused_chat_pane`], plus what it did to the session.
    pub(super) fn close_focused_chat_pane_archiving(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (bool, Option<super::chat_tabs::CloseArchive>) {
        let closing = self.state.read(cx).selected_chat.clone();
        let closed = self.close_focused_chat_view(window, cx);
        let archive = closing
            .filter(|_| closed)
            .map(|chat_id| self.archive_closed_session(chat_id, window, cx));
        (closed, archive)
    }

    fn close_focused_chat_view(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if !self.chat_split_active() {
            // One pane left: close its tab while others remain.
            return self.close_chat_tab(window, cx);
        }
        let Some(split) = self.chat_split.as_mut() else {
            return false;
        };
        let Some(target) = split.close_focused() else {
            self.chat_split = None;
            return false;
        };
        let project = split.projects[split.focus].clone();
        let draft = split.drafts[split.focus].take().filter(|_| target.is_none());
        if split.panes.len() == 1 {
            self.chat_split = None;
        }
        self.chat_split_selected = target.clone();
        self.state.update(cx, |s, cx| s.select_chat(target, cx));
        self.set_space_filter(project, cx);
        self.adopt_canvas_draft(draft, cx);
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
        true
    }

    /// Follow selection changes made outside the split (called from
    /// `on_state_changed`), and drop panes whose chat was deleted.
    pub(super) fn chat_split_on_state_changed(&mut self, cx: &mut Context<Self>) {
        let filter = self.settings.space_filter.clone();
        let Some(split) = self.chat_split.as_mut() else {
            return;
        };
        let state = self.state.read(cx);
        let selected = state.selected_chat.clone();
        if selected != self.chat_split_selected {
            let previous = std::mem::replace(&mut self.chat_split_selected, selected.clone());
            // Focus moved to the pane already showing the chat: the pane it
            // left keeps the live project, as when clicking a pane.
            if let Some(from) = split.selection_changed(previous, selected.as_deref()) {
                split.projects[from] = filter;
            }
        }
        if state.chats_synced {
            let chat = |id: &str| state.chats.iter().find(|c| c.id == id);
            split.prune(|id| chat(id).map(|c| c.archived));
            split.restore_returned(|id| chat(id).is_some_and(|c| !c.archived));
        }
        self.sync_chat_panes(cx);
    }

    /// Save the layout for the next launch (only after launch restored the
    /// previous one, so a cold start never overwrites it with nothing).
    pub(super) fn persist_chat_layout(&mut self, cx: &mut Context<Self>) {
        if !self.boot_restored {
            return;
        }
        let saved = self.chat_split.as_ref().map(ChatSplit::to_saved);
        if saved != self.settings.chat_layout {
            self.settings.chat_layout = saved;
            self.schedule_save(cx);
        }
    }

    /// Reconcile peer transcript views and their doc watches with the split.
    pub(super) fn sync_chat_panes(&mut self, cx: &mut Context<Self>) {
        self.persist_chat_layout(cx);
        let wanted: Vec<String> = self
            .chat_split
            .as_ref()
            .map(|split| split.peer_chats().map(str::to_owned).collect())
            .unwrap_or_default();
        let stale: Vec<String> = self
            .peer_chat_views
            .keys()
            .filter(|id| !wanted.contains(id))
            .cloned()
            .collect();
        for id in stale {
            self.peer_chat_views.remove(&id);
            self.state.update(cx, |s, _| s.unwatch_peer_chat(&id));
        }
        for id in wanted {
            if self.peer_chat_views.contains_key(&id) {
                continue;
            }
            let transcript = cx.new(|cx| Transcript::for_doc(self.state.clone(), id.clone(), true, cx));
            let links = Self::session_links(Some(id.clone()), cx);
            let views = Self::view_opener(cx);
            transcript.update(cx, |transcript, _| {
                transcript.set_workspace_link_handler(links);
                transcript.set_view_opener(views);
            });
            let events = cx.subscribe(&transcript, Self::on_transcript_event);
            self.state
                .update(cx, |s, cx| s.watch_peer_chat(id.clone(), cx));
            self.peer_chat_views.insert(
                id,
                PeerChatView {
                    transcript,
                    _events: events,
                },
            );
        }
    }

    /// The focused pane's share of the conversation column width (1 unless
    /// a side-by-side split is showing).
    pub(super) fn focused_chat_pane_share(&self) -> f32 {
        match &self.chat_split {
            Some(split)
                if matches!(self.route, Route::Chat)
                    && !split.zoomed
                    && split.axis == SplitAxis::Horizontal =>
            {
                split.shares[split.focus]
            }
            _ => 1.0,
        }
    }

    /// Lay the focused column (`main`) out beside or above its peer panes.
    pub(super) fn render_chat_split(&mut self, main: AnyElement, total_width: f32, cx: &mut Context<Self>) -> AnyElement {
        let Some(split) = self.chat_split.clone().filter(|s| !s.zoomed) else {
            return main;
        };
        if !matches!(self.route, Route::Chat) {
            return main;
        }
        let theme = Theme::of(cx).clone();
        let horizontal = split.axis == SplitAxis::Horizontal;
        let mut main = Some(main);
        let mut children: Vec<AnyElement> = Vec::new();
        for (ix, pane) in split.panes.iter().enumerate() {
            if ix > 0 {
                children.push(self.render_split_divider(ix, horizontal, &theme, cx));
            }
            let share = split.shares[ix];
            if ix == split.focus {
                let body = main.take().expect("one focused pane");
                let slot = div().relative().flex().min_w_0().min_h_0().overflow_hidden();
                children.push(
                    if horizontal { slot.flex_1().h_full() } else { slot.w_full().h(gpui::relative(share)) }
                        .child(body)
                        .into_any_element(),
                );
                continue;
            }
            let peer = self.render_peer_chat_pane(ix, pane.as_deref(), &theme, cx);
            let slot = div().relative().flex_none().overflow_hidden();
            children.push(
                if horizontal { slot.h_full().w(px((total_width * share).max(0.0))) } else { slot.w_full().h(gpui::relative(share)) }
                    .child(peer)
                    .into_any_element(),
            );
        }
        let measured = self.chat_split_bounds.clone();
        let root = div()
            .id("chat-split-root")
            .relative()
            .size_full()
            .min_w_0()
            .flex()
            .overflow_hidden()
            // Divider drags track the pointer across the whole split.
            .on_mouse_move(cx.listener(move |this, event: &gpui::MouseMoveEvent, _, cx| {
                let Some(drag) = this.chat_split_drag.as_ref() else {
                    return;
                };
                if event.pressed_button != Some(gpui::MouseButton::Left) {
                    this.chat_split_drag = None;
                    return;
                }
                let Some(bounds) = this.chat_split_bounds.get() else {
                    return;
                };
                let (pos, extent) = if horizontal {
                    (f32::from(event.position.x), f32::from(bounds.size.width))
                } else {
                    (f32::from(event.position.y), f32::from(bounds.size.height))
                };
                if extent <= 0.0 {
                    return;
                }
                let (divider, origin, start) = (drag.divider, drag.origin, drag.start.clone());
                if let Some(split) = this.chat_split.as_mut() {
                    split.drag_divider(&start, divider, (pos - origin) / extent);
                    cx.notify();
                }
            }))
            .on_mouse_up(
                gpui::MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    if this.chat_split_drag.take().is_some() {
                        this.persist_chat_layout(cx);
                    }
                }),
            )
            .child(
                gpui::canvas(move |bounds, _, _| measured.set(Some(bounds)), |_, _, _, _| {})
                    .absolute()
                    .inset_0(),
            );
        if horizontal { root.flex_row() } else { root.flex_col() }
            .children(children)
            .into_any_element()
    }

    /// A 1px divider with a wider invisible grab area: drag to resize the two
    /// panes beside it, double-click to equalize (Ghostty).
    fn render_split_divider(&mut self, ix: usize, horizontal: bool, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let dragging = self.chat_split_drag.as_ref().is_some_and(|d| d.divider == ix);
        let grab = div()
            .id(("chat-split-divider", ix))
            .absolute()
            .when(horizontal, |el| el.top_0().bottom_0().left(px(-4.0)).w(px(9.0)).cursor_col_resize())
            .when(!horizontal, |el| el.left_0().right_0().top(px(-4.0)).h(px(9.0)).cursor_row_resize())
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(move |this, event: &gpui::MouseDownEvent, _, cx| {
                    cx.stop_propagation();
                    if event.click_count >= 2 {
                        this.chat_split_drag = None;
                        this.equalize_chat_panes(cx);
                        return;
                    }
                    let Some(split) = this.chat_split.as_ref() else {
                        return;
                    };
                    this.chat_split_drag = Some(DividerDrag {
                        divider: ix,
                        origin: if horizontal { f32::from(event.position.x) } else { f32::from(event.position.y) },
                        start: split.shares.clone(),
                    });
                    cx.notify();
                }),
            );
        let line = div()
            .relative()
            .flex_none()
            .bg(if dragging { theme.accent.opacity(0.7) } else { theme.border });
        if horizontal { line.w(px(1.0)).h_full() } else { line.h(px(1.0)).w_full() }
            .child(grab)
            .into_any_element()
    }

    fn render_peer_chat_pane(
        &mut self,
        ix: usize,
        chat_id: Option<&str>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title: SharedString = chat_id
            .and_then(|id| {
                self.state
                    .read(cx)
                    .chats
                    .iter()
                    .find(|c| c.id == id)
                    .map(|c| c.title.clone().unwrap_or_else(|| "Untitled session".into()))
            })
            .unwrap_or_else(|| "New session".into())
            .into();
        // An empty pane names the project its new session will start in.
        let empty_hint: SharedString = self
            .chat_split
            .as_ref()
            .and_then(|split| split.projects.get(ix).cloned().flatten())
            .and_then(|id| self.state.read(cx).spaces.iter().find(|s| s.id == id).map(space_label))
            .map_or_else(
                || "Click to start a session".into(),
                |project| format!("Click to start a session in {project}").into(),
            );
        let view = chat_id.and_then(|id| self.peer_chat_views.get(id));
        let body: AnyElement = match view {
            Some(view) => {
                let transcript = view.transcript.clone();
                let (anim, hover) = JUMP_KEYS[ix.min(MAX_CHAT_PANES - 1)];
                let pill = transcript.read(cx).jump_button_shown().then(|| {
                    div()
                        .absolute()
                        .bottom(px(16.0))
                        .left_0()
                        .right_0()
                        .flex()
                        .justify_center()
                        .child(self.jump_pill(anim, hover, transcript.clone(), cx))
                });
                // Cached: with several panes streaming, a frame redraws only
                // the panes whose transcript changed; the rest replay their
                // last frame (their text stays selectable, see
                // `selection_owner_reset`).
                div()
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .child(transcript.cached(gpui::StyleRefinement::default().size_full()))
                    .children(pill)
                    .into_any_element()
            }
            None => div()
                .flex_1()
                .px(px(16.0))
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(4.0))
                .text_center()
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(13.0))
                        .text_color(theme.text_muted.opacity(0.8))
                        .child(SharedString::from("Empty pane")),
                )
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(11.5))
                        .text_color(theme.text_muted.opacity(0.55))
                        .child(empty_hint),
                )
                .into_any_element(),
        };
        div()
            .id(("chat-peer-pane", ix))
            .size_full()
            .relative()
            .flex()
            .flex_col()
            // The window titlebar overlays the top of the content area.
            .pt(px(Theme::TITLEBAR_HEIGHT))
            .child(
                div()
                    .flex_none()
                    .px(px(14.0))
                    .pb(px(6.0))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(crate::typography::ui_rems(12.0))
                            .text_color(theme.text_muted)
                            .child(title),
                    )
                    // Closing the other panes is how you get back to one
                    // column; ⌘W / Ctrl+Shift+W closes the focused pane.
                    .child(
                        div()
                            .id(("chat-peer-pane-close", ix))
                            .flex_none()
                            .size(px(20.0))
                            .rounded(px(5.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .hover(|style| style.bg(theme.ink(0.08)))
                            .role(gpui::Role::Button)
                            .aria_label("Close this pane")
                            .on_mouse_down(gpui::MouseButton::Left, |_, window, _| {
                                window.prevent_default()
                            })
                            .on_click(cx.listener(move |this, _, window, cx| {
                                cx.stop_propagation();
                                this.close_chat_pane(ix, window, cx);
                            }))
                            .child(
                                crate::icons::icon(crate::icons::CLOSE)
                                    .size(px(12.0))
                                    .text_color(theme.text_muted),
                            ),
                    ),
            )
            // Ghostty dims unfocused splits.
            .child(div().flex_1().min_h_0().flex().flex_col().opacity(0.8).child(body))
            // Focus on release so text drags retain their transcript. Capture
            // first so thought-process and other controls cannot swallow the
            // activation; leave propagation intact for their own interactions.
            .capture_any_mouse_up(cx.listener(move |this, event: &gpui::MouseUpEvent, window, cx| {
                if event.button == gpui::MouseButton::Left {
                    this.release_on_peer_pane(ix, window, cx);
                }
            }))
            .into_any_element()
    }
}

/// Pane glyph: which part of the split a card or row badge stands for.
pub(super) fn pane_glyph(axis: SplitAxis, ix: usize, len: usize) -> &'static str {
    match (axis, ix, len) {
        (SplitAxis::Horizontal, 0, _) => "◧",
        (SplitAxis::Horizontal, i, n) if i + 1 == n => "◨",
        (SplitAxis::Vertical, 0, _) => "⬒",
        (SplitAxis::Vertical, i, n) if i + 1 == n => "⬓",
        _ => "▣",
    }
}

fn space_label(space: &harness_proto::Space) -> String {
    space.name.clone().unwrap_or_else(|| {
        std::path::Path::new(&space.path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| space.path.clone())
    })
}

impl Shell {
    /// A strip of mini cards mirroring the split above the session list:
    /// each shows its pane's session, with the focused one lit.
    /// Click a card to move into that pane.
    pub(super) fn render_pane_strip(&mut self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let split = self
            .chat_split
            .clone()
            .filter(|_| matches!(self.route, Route::Chat))?;
        let len = split.panes.len();
        struct Card {
            title: SharedString,
            harness: Option<harness_proto::HarnessId>,
        }
        let cards = {
            let state = self.state.read(cx);
            let selected = state.selected_chat.clone();
            let pane_chat = |ix: usize| {
                if ix == split.focus {
                    selected.clone()
                } else {
                    split.panes[ix].clone()
                }
            };
            let cards: Vec<Card> = (0..len)
                .map(|ix| {
                    let chat = pane_chat(ix).and_then(|id| state.chats.iter().find(|c| c.id == id));
                    let harness = if let Some(chat) = chat {
                        chat.config.as_ref().map(|config| config.harness)
                    } else if ix == split.focus {
                        self.current_canvas_draft(cx).harness
                    } else {
                        split
                            .drafts
                            .get(ix)
                            .and_then(|draft| draft.as_ref())
                            .and_then(|draft| draft.harness)
                    };
                    Card {
                        harness,
                        title: chat
                            .map(|c| {
                                transcript::single_line(
                                    &c.title.clone().unwrap_or_else(|| "Untitled".into()),
                                )
                            })
                            .unwrap_or_else(|| "New session".into())
                            .into(),
                    }
                })
                .collect();
            cards
        };

        let mut row: Vec<AnyElement> = Vec::with_capacity(len);
        for (ix, card) in cards.into_iter().enumerate() {
            let focused = ix == split.focus;
            row.push(
                div()
                    .id(("chat-pane-card", ix))
                    .flex_1()
                    .min_w(px(96.0))
                    .px(px(8.0))
                    .py(px(7.0))
                    .rounded(px(10.0))
                    .border_1()
                    .border_color(if focused { theme.accent.opacity(0.55) } else { theme.border })
                    .bg(if focused { theme.ink(0.05) } else { theme.ink(0.015) })
                    .hover(|style| style.bg(theme.ink(0.05)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if this.chat_split.as_ref().is_some_and(|s| s.focus == ix) {
                            window.focus(&this.composer.focus_handle(cx), cx);
                        } else {
                            this.focus_chat_pane(ix, window, cx);
                        }
                    }))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(5.0))
                            .child(
                                {
                                    let (path, tint) = card.harness
                                        .map(crate::pickers::harness_brand_icon)
                                        .unwrap_or((icons::CHAT_ROUND_LINE, None));
                                    icon(path)
                                        .size(px(11.0))
                                        .text_color(tint.unwrap_or(if focused {
                                            theme.accent
                                        } else {
                                            theme.text_muted
                                        }))
                                },
                            )
                            .child(
                                div()
                                    .min_w_0()
                                    .flex_1()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(12.5))
                                    .font_weight(gpui::FontWeight::MEDIUM)
                                    .text_color(if focused { theme.text } else { theme.text_muted })
                                    .child(card.title),
                            ),
                    )
                    .into_any_element(),
            );
        }

        Some(
            div()
                .id("sidebar-pane-strip")
                .px(px(Theme::SPACE_SM))
                .pb(px(8.0))
                .flex()
                .flex_col()
                .child(div().flex().flex_row().flex_wrap().items_start().gap(px(6.0)).children(row))
                .into_any_element(),
        )
    }
}

impl Shell {
    /// While a sidebar session is being dragged, Ghostty-style drop targets
    /// over the chat area: the right edge opens it in a new pane to the
    /// right, the bottom edge in a new pane below.
    pub(super) fn render_split_drop_zones(&self, theme: &Theme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        if !matches!(self.route, Route::Chat) || self.sidebar_session_transfer.is_none() {
            return Vec::new();
        }
        let zone = |id: &'static str, axis: SplitAxis, label: &'static str| {
            let accent = theme.accent;
            div()
                .id(id)
                .absolute()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(12.0))
                .border_1()
                .border_dashed()
                .border_color(theme.border)
                .bg(theme.ink(0.02))
                .text_size(crate::typography::ui_rems(12.5))
                .text_color(theme.text_muted)
                .child(SharedString::from(label))
                .drag_over::<SidebarSessionDrag>(move |style, _, _, _| {
                    style
                        .bg(accent.opacity(0.14))
                        .border_color(accent.opacity(0.7))
                        .text_color(accent)
                })
                .on_drop(cx.listener(move |this, payload: &SidebarSessionDrag, window, cx| {
                    let chat = payload.chat_id.clone();
                    this.cancel_sidebar_session_transfer(cx);
                    this.split_chat_opening(axis, Some(chat), window, cx);
                }))
        };
        let mut zones = Vec::new();
        let right = self.can_split(SplitAxis::Horizontal);
        let below = self.can_split(SplitAxis::Vertical);
        if right {
            zones.push(
                zone("chat-drop-right", SplitAxis::Horizontal, "Open to the right ◨")
                    .top(px(Theme::TITLEBAR_HEIGHT + 8.0))
                    .bottom(px(8.0))
                    .right(px(8.0))
                    .w(gpui::relative(0.3))
                    .into_any_element(),
            );
        }
        if below {
            let zone = zone("chat-drop-below", SplitAxis::Vertical, "Open below ⬓")
                .left(px(8.0))
                .bottom(px(8.0))
                .h(gpui::relative(0.28));
            // Leave the right column to the right-hand target.
            let zone = if right { zone.right(gpui::relative(0.33)) } else { zone.right(px(8.0)) };
            zones.push(zone.into_any_element());
        }
        zones
    }
}

#[cfg(test)]
mod chat_split_tests {
    use super::*;

    fn two(selected: &str) -> ChatSplit {
        ChatSplit::split(None, SplitAxis::Horizontal, Some(selected.into()), Some("p".into())).unwrap()
    }

    #[test]
    fn split_parks_the_selection_and_focuses_a_fresh_pane() {
        let split = two("a");
        assert_eq!(split.panes, vec![Some("a".into()), None]);
        assert_eq!(split.focus, 1);
        assert_eq!(split.shares, vec![0.5, 0.5]);
        assert_eq!(split.peer_chats().collect::<Vec<_>>(), ["a"]);
        assert_eq!(split.projects, vec![Some("p".into()), Some("p".into())], "new pane inherits the project");
    }

    #[test]
    fn pane_drafts_follow_their_panes() {
        let draft = |model: &str| CanvasDraft {
            model: Some(model.into()),
            ..Default::default()
        };
        let mut split = two("a");
        assert_eq!(split.drafts, vec![None, None]);
        split.drafts[0] = Some(draft("x"));
        let mut split = ChatSplit::split(Some(split), SplitAxis::Horizontal, None, None).unwrap();
        assert_eq!(split.drafts, vec![Some(draft("x")), None, None], "a new pane slots in empty");
        split.drafts[1] = Some(draft("y"));
        assert!(split.close_focused().is_some());
        assert_eq!(split.drafts, vec![Some(draft("x")), Some(draft("y"))], "the closed pane's slot goes");
    }

    #[test]
    fn split_respects_the_cap_and_axis() {
        let mut split = Some(two("a"));
        for _ in 1..MAX_CHAT_PANES - 1 {
            split = ChatSplit::split(split, SplitAxis::Horizontal, None, None);
        }
        let full = split.unwrap();
        assert_eq!(full.panes.len(), MAX_CHAT_PANES);
        assert!(ChatSplit::split(Some(full.clone()), SplitAxis::Horizontal, None, None).is_none());
        assert!(ChatSplit::split(Some(two("a")), SplitAxis::Vertical, None, None).is_none());
        assert!((full.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn focus_swaps_the_selection_into_the_pane_left_behind() {
        let mut split = two("a");
        assert_eq!(split.focus_pane(0, Some("b".into())), Some(Some("a".into())));
        assert_eq!(split.panes, vec![None, Some("b".into())]);
        assert_eq!(split.focus, 0);
        assert_eq!(split.focus_pane(0, None), None, "already focused");
        assert_eq!(split.focus_pane(7, None), None, "out of range");
    }

    #[test]
    fn directional_focus_follows_the_axis() {
        let split = two("a");
        assert_eq!(split.toward(PaneDirection::Left), Some(0));
        assert_eq!(split.toward(PaneDirection::Right), None);
        assert_eq!(split.toward(PaneDirection::Up), None);
        assert_eq!(split.cycled(true), 0);
        assert_eq!(split.cycled(false), 0);
    }

    #[test]
    fn resize_moves_the_divider_and_clamps() {
        let mut split = two("a");
        // Focus is the last pane: Left moves the divider left, growing it.
        assert!(split.resize(PaneDirection::Left));
        assert!((split.shares[0] - 0.45).abs() < 1e-5);
        for _ in 0..40 {
            split.resize(PaneDirection::Left);
        }
        assert!((split.shares[0] - MIN_PANE_SHARE).abs() < 1e-5);
        assert!(!split.resize(PaneDirection::Up), "wrong axis");
        split.equalize();
        assert_eq!(split.shares, vec![0.5, 0.5]);
    }

    #[test]
    fn resizing_small_neighbors_after_four_splits_does_not_panic() {
        let mut split = two("a");
        for _ in 0..2 {
            split = ChatSplit::split(Some(split), SplitAxis::Horizontal, None, None).unwrap();
        }
        assert_eq!(split.panes.len(), 4);
        // Ghostty-style halving (or a drag) can leave two small neighbors.
        split.shares = vec![0.5, 0.25, 0.125, 0.125];
        assert!(split.shares[split.focus] + split.shares[split.focus - 1] < 2.0 * MIN_PANE_SHARE);
        for direction in [PaneDirection::Left, PaneDirection::Right] {
            for _ in 0..10 {
                assert!(split.resize(direction));
            }
        }
        assert!((split.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
        assert!(split.shares.iter().all(|&s| s > 0.0));
    }

    #[test]
    fn every_split_leaves_panes_the_same_size() {
        let mut split = two("a");
        for panes in 3..=4 {
            split = ChatSplit::split(Some(split), SplitAxis::Horizontal, None, None).unwrap();
            let share = 1.0 / panes as f32;
            assert!(
                split.shares.iter().all(|s| (s - share).abs() < 1e-5),
                "{panes} panes: {:?}",
                split.shares
            );
        }
        // Closing from an even split keeps it even.
        split.close_focused();
        assert!(split.shares.iter().all(|s| (s - 1.0 / 3.0).abs() < 1e-5), "{:?}", split.shares);
        // A dragged layout keeps its sizes: the closed share goes to the neighbor.
        let start = split.shares.clone();
        split.drag_divider(&start, 1, 0.1);
        let dragged = split.shares.clone();
        split.focus = 2;
        split.close_focused();
        assert!((split.shares[0] - dragged[0]).abs() < 1e-5);
        assert!((split.shares[1] - (dragged[1] + dragged[2])).abs() < 1e-5);
    }

    #[test]
    fn splits_past_four_panes_share_the_column_evenly() {
        let mut split = two("a");
        let mut sizes = vec![split.panes.len()];
        while let Some(next) = ChatSplit::split(Some(split.clone()), SplitAxis::Horizontal, None, None) {
            split = next;
            sizes.push(split.panes.len());
            assert!((split.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
            assert!(
                split.shares.iter().all(|&s| s >= 1.0 / MAX_CHAT_PANES as f32 - 1e-5),
                "no sliver panes: {:?}",
                split.shares
            );
        }
        assert_eq!(sizes, (2..=MAX_CHAT_PANES).collect::<Vec<_>>());
        assert_eq!(split.focus, MAX_CHAT_PANES - 1, "the newest pane takes focus");
        // Every divider still drags, even with the column full.
        let start = split.shares.clone();
        split.drag_divider(&start, 1, 0.02);
        assert!(split.shares[0] > start[0] && split.shares[1] < start[1]);
        assert!(split.resize(PaneDirection::Left));
        assert!((split.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn dragging_a_divider_moves_only_its_two_panes() {
        let mut split = ChatSplit::split(Some(two("a")), SplitAxis::Horizontal, None, None).unwrap();
        split.equalize();
        let start = split.shares.clone();
        split.drag_divider(&start, 1, 0.1);
        assert!((split.shares[0] - (1.0 / 3.0 + 0.1)).abs() < 1e-5);
        assert!((split.shares[1] - (1.0 / 3.0 - 0.1)).abs() < 1e-5);
        assert!((split.shares[2] - 1.0 / 3.0).abs() < 1e-5, "far pane untouched");
        split.drag_divider(&start, 1, 5.0);
        assert!((split.shares[1] - MIN_PANE_SHARE).abs() < 1e-5, "clamped at the minimum");
        assert!((split.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
        split.drag_divider(&start, 0, 0.1);
        split.drag_divider(&start, 9, 0.1);
    }

    #[test]
    fn closing_hands_focus_and_space_to_the_neighbor() {
        let mut split = two("a");
        split.focus_pane(0, Some("b".into()));
        split.zoomed = true;
        assert_eq!(split.close_focused(), Some(Some("b".into())));
        assert_eq!(split.panes.len(), 1);
        assert_eq!(split.shares, vec![1.0]);
        assert_eq!(split.projects.len(), 1);
        assert!(!split.zoomed);
        assert_eq!(split.close_focused(), None);
    }

    #[test]
    fn cmd_d_splits_the_terminal_only_while_it_has_focus() {
        // Same order as `apply_keymap`: chat splits first, terminal after.
        let mut bindings = chat_split_bindings(true);
        bindings.push(KeyBinding::new("cmd-d", SplitRight, Some("Terminal")));
        let keymap = gpui::Keymap::new(bindings);
        let resolve = |contexts: &[&str]| {
            let stack: Vec<gpui::KeyContext> = contexts
                .iter()
                .map(|c| gpui::KeyContext::parse(c).unwrap())
                .collect();
            let (matched, _) =
                keymap.bindings_for_input(&[gpui::Keystroke::parse("cmd-d").unwrap()], &stack);
            matched.first().map(|b| b.action().name())
        };
        assert_eq!(resolve(&["Shell", "Terminal"]), Some(SplitRight.name()));
        assert_eq!(resolve(&["Shell", "Composer"]), Some(SplitChatRight.name()));
        assert_eq!(resolve(&["Shell"]), Some(SplitChatRight.name()));
    }

    #[test]
    fn layouts_round_trip_and_drop_vanished_chats() {
        let mut split = ChatSplit::split(Some(two("a")), SplitAxis::Horizontal, None, None).unwrap();
        split.panes[1] = Some("gone".into());
        split.equalize();
        let saved = split.to_saved();
        let back = ChatSplit::from_saved(&saved, |id| id == "a").unwrap();
        assert_eq!(back.panes, vec![Some("a".into()), None, None], "vanished chat → empty pane");
        assert_eq!(back.focus, split.focus);
        assert!((back.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
        let mut broken = saved.clone();
        broken.focus = 9;
        assert!(ChatSplit::from_saved(&broken, |_| true).is_none());
        broken = saved;
        broken.shares.pop();
        assert!(ChatSplit::from_saved(&broken, |_| true).is_none());
    }

    fn three() -> ChatSplit {
        // a | b | (focused)
        ChatSplit::split(Some(two("a")), SplitAxis::Horizontal, Some("b".into()), None).unwrap()
    }

    #[test]
    fn a_chat_that_leaves_the_list_briefly_returns_to_its_pane() {
        let mut split = three();
        let listed = |ids: &'static [&'static str]| move |id: &str| ids.contains(&id).then_some(false);
        split.prune(listed(&["a"]));
        assert_eq!(split.panes, vec![Some("a".into()), None, None]);
        split.restore_returned(|id| id == "a");
        assert_eq!(split.panes[1], None, "still missing");
        split.restore_returned(|id| ["a", "b"].contains(&id));
        assert_eq!(split.panes, vec![Some("a".into()), Some("b".into()), None], "back in place, not a canvas");
    }

    #[test]
    fn a_returning_chat_never_displaces_a_newer_pick_or_an_archive() {
        let mut split = three();
        // `a` is archived: its pane closes for good. `b` leaves the list, and
        // its emptied pane is focused as a new canvas before `b` returns.
        split.prune(|id| (id == "a").then_some(true));
        assert_eq!(split.panes, vec![None, None, None]);
        split.focus_pane(1, Some("c".into()));
        split.restore_returned(|_| true);
        assert_eq!(split.panes, vec![None, None, Some("c".into())]);
        // Closing a pane keeps the memory aligned with the panes.
        split.close_focused();
        assert_eq!(split.vanished.len(), split.panes.len());
    }

    #[test]
    fn selecting_a_chat_in_another_pane_focuses_it_in_place() {
        // Three panes: a | b | (focused, showing c). Picking `a` from the
        // sidebar focuses the first pane; nothing moves.
        let mut split = two("a");
        split = ChatSplit::split(Some(split), SplitAxis::Horizontal, Some("b".into()), None).unwrap();
        assert_eq!(split.focus, 2);
        assert_eq!(split.selection_changed(Some("c".into()), Some("a")), Some(2));
        assert_eq!(split.focus, 0);
        assert_eq!(split.panes, vec![None, Some("b".into()), Some("c".into())]);
        // An unrelated chat loads in the focused pane, in place.
        assert_eq!(split.selection_changed(Some("a".into()), Some("z")), None);
        assert_eq!(split.focus, 0);
        assert_eq!(split.panes[1].as_deref(), Some("b"));
        assert_eq!(split.panes[2].as_deref(), Some("c"));
    }
}
