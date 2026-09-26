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
            zoomed: false,
        });
        if split.axis != axis || split.panes.len() >= MAX_CHAT_PANES {
            return None;
        }
        split.panes[split.focus] = selected;
        let at = split.focus + 1;
        // The new pane takes half of the pane it split, like Ghostty — until
        // that half would be a sliver, then every pane gets an equal share.
        let half = split.shares[split.focus] / 2.0;
        split.shares[split.focus] = half;
        split.panes.insert(at, None);
        split.shares.insert(at, half);
        if half < MIN_PANE_SHARE {
            split.equalize();
        }
        // The new pane starts in the project of the pane it split from.
        let project = split.projects[split.focus].clone();
        split.projects.insert(at, project);
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

    /// Close the focused pane. Its share goes to the neighbor that takes
    /// focus, whose chat is returned for selection. `None` means the split
    /// is down to one pane and should be dropped.
    pub fn close_focused(&mut self) -> Option<Option<String>> {
        if self.panes.len() <= 1 {
            return None;
        }
        let closed = self.focus;
        let share = self.shares.remove(closed);
        self.panes.remove(closed);
        self.projects.remove(closed);
        let next = closed.saturating_sub(1).min(self.panes.len() - 1);
        self.shares[next] += share;
        self.focus = next;
        self.zoomed = false;
        Some(self.panes[next].take())
    }

    /// The selection moved from `previous` to `selected` outside the split
    /// (sidebar click, ⌘1–9, a deep link). When the new chat already sits in
    /// an unfocused pane, the two trade places instead of showing twice.
    pub fn selection_changed(&mut self, previous: Option<String>, selected: Option<&str>) {
        let Some(selected) = selected else {
            return;
        };
        if let Some(ix) = self
            .panes
            .iter()
            .position(|pane| pane.as_deref() == Some(selected))
        {
            self.panes[ix] = previous;
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
    pub fn from_saved(
        saved: &crate::settings::SavedChatLayout,
        live: impl Fn(&str) -> bool,
    ) -> Option<Self> {
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
            axis: if saved.vertical {
                SplitAxis::Vertical
            } else {
                SplitAxis::Horizontal
            },
            panes: saved
                .panes
                .iter()
                .enumerate()
                .map(|(ix, pane)| pane.clone().filter(|id| ix != saved.focus && live(id)))
                .collect(),
            focus: saved.focus,
            shares: saved.shares.iter().map(|s| s / total).collect(),
            projects,
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
    let b = |mac_combo: &str, other: &str| {
        if mac {
            mac_combo.to_owned()
        } else {
            other.to_owned()
        }
    };
    vec![
        KeyBinding::new(&b("cmd-d", "ctrl-shift-o"), SplitChatRight, None),
        KeyBinding::new(&b("cmd-shift-d", "ctrl-shift-e"), SplitChatDown, None),
        KeyBinding::new(&b("cmd-]", "ctrl-super-]"), FocusNextChatPane, None),
        KeyBinding::new(&b("cmd-[", "ctrl-super-["), FocusPrevChatPane, None),
        KeyBinding::new(&b("cmd-alt-left", "ctrl-alt-left"), FocusChatPaneLeft, None),
        KeyBinding::new(
            &b("cmd-alt-right", "ctrl-alt-right"),
            FocusChatPaneRight,
            None,
        ),
        KeyBinding::new(&b("cmd-alt-up", "ctrl-alt-up"), FocusChatPaneUp, None),
        KeyBinding::new(&b("cmd-alt-down", "ctrl-alt-down"), FocusChatPaneDown, None),
        KeyBinding::new(
            &b("cmd-ctrl-left", "ctrl-super-shift-left"),
            ResizeChatPaneLeft,
            None,
        ),
        KeyBinding::new(
            &b("cmd-ctrl-right", "ctrl-super-shift-right"),
            ResizeChatPaneRight,
            None,
        ),
        KeyBinding::new(
            &b("cmd-ctrl-up", "ctrl-super-shift-up"),
            ResizeChatPaneUp,
            None,
        ),
        KeyBinding::new(
            &b("cmd-ctrl-down", "ctrl-super-shift-down"),
            ResizeChatPaneDown,
            None,
        ),
        KeyBinding::new(
            &b("cmd-ctrl-=", "ctrl-super-shift-="),
            EqualizeChatPanes,
            None,
        ),
        KeyBinding::new(
            &b("cmd-shift-enter", "ctrl-shift-enter"),
            ToggleChatPaneZoom,
            None,
        ),
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

    pub(super) fn split_chat(
        &mut self,
        axis: SplitAxis,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.split_chat_opening(axis, None, window, cx);
    }

    /// Whether a new split along `axis` is possible right now.
    fn can_split(&self, axis: SplitAxis) -> bool {
        self.chat_split
            .as_ref()
            .is_none_or(|s| s.axis == axis && s.panes.len() < MAX_CHAT_PANES)
    }

    /// Split and show `open` in the new, focused pane (`None` = a fresh
    /// new-session canvas, Ghostty's new surface).
    pub(super) fn split_chat_opening(
        &mut self,
        axis: SplitAxis,
        open: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !matches!(self.route, Route::Chat) {
            return;
        }
        // Another side-by-side pane would be too narrow to read: open it in
        // a new tab instead, leaving this layout as it is.
        let panes = self.chat_split.as_ref().map_or(1, |s| s.panes.len());
        if axis == SplitAxis::Horizontal
            && self.can_split(axis)
            && !chat_tabs::fits_another_pane(self.chat_column_width, panes)
        {
            self.new_chat_tab(open, window, cx);
            return;
        }
        let selected = self.state.read(cx).selected_chat.clone();
        // Dragging the chat you are in moves it; the pane it leaves empties.
        let parked = selected.clone().filter(|id| open.as_ref() != Some(id));
        let project = self.settings.space_filter.clone();
        // Split a copy: a refused split (at the cap, or across axes) must
        // leave the existing layout alone, not drop every pane.
        let Some(split) = ChatSplit::split(self.chat_split.clone(), axis, parked, project) else {
            return;
        };
        self.chat_split = Some(split);
        self.chat_split_selected = None;
        self.state.update(cx, |s, cx| s.select_chat(open, cx));
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    pub(super) fn focus_chat_pane(
        &mut self,
        ix: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let selected = self.state.read(cx).selected_chat.clone();
        let Some(split) = self.chat_split.as_mut() else {
            return;
        };
        let from = split.focus;
        let Some(target) = split.focus_pane(ix, selected) else {
            return;
        };
        // Each pane keeps its own workspace: park the live sidebar filter in
        // the pane being left and bring the target pane's back.
        split.projects[from] = self.settings.space_filter.clone();
        let project = split.projects[ix].clone();
        self.chat_split_selected = target.clone();
        self.state.update(cx, |s, cx| s.select_chat(target, cx));
        self.set_space_filter(project, cx);
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    pub(super) fn cycle_chat_pane(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
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

    /// ⌘W with a split open closes the focused pane (not the window).
    pub(crate) fn close_focused_chat_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.chat_split_active() {
            // One pane left: close its tab while others remain.
            return self.close_chat_tab(window, cx);
        }
        let Some(split) = self.chat_split.as_mut() else {
            return false;
        };
        let Some(target) = split.close_focused() else {
            self.chat_split = None;
            motion::reveal_reset(STRIP_REVEAL_KEY);
            return false;
        };
        let project = split.projects[split.focus].clone();
        if split.panes.len() == 1 {
            self.chat_split = None;
            motion::reveal_reset(STRIP_REVEAL_KEY);
        }
        self.chat_split_selected = target.clone();
        self.state.update(cx, |s, cx| s.select_chat(target, cx));
        self.set_space_filter(project, cx);
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
        true
    }

    /// Follow selection changes made outside the split (called from
    /// `on_state_changed`), and drop panes whose chat was deleted.
    pub(super) fn chat_split_on_state_changed(&mut self, cx: &mut Context<Self>) {
        let Some(split) = self.chat_split.as_mut() else {
            return;
        };
        let state = self.state.read(cx);
        let selected = state.selected_chat.clone();
        if selected != self.chat_split_selected {
            let previous = std::mem::replace(&mut self.chat_split_selected, selected.clone());
            split.selection_changed(previous, selected.as_deref());
        }
        if state.chats_synced {
            for pane in split.panes.iter_mut() {
                if pane
                    .as_deref()
                    .is_some_and(|id| !state.chats.iter().any(|c| c.id == id && !c.archived))
                {
                    *pane = None;
                }
            }
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
            let transcript =
                cx.new(|cx| Transcript::for_doc(self.state.clone(), id.clone(), true, cx));
            let links = Self::session_links(Some(id.clone()), cx);
            transcript.update(cx, |transcript, _| {
                transcript.set_workspace_link_handler(links)
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
    pub(super) fn render_chat_split(
        &mut self,
        main: AnyElement,
        total_width: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
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
                let slot = div()
                    .relative()
                    .flex()
                    .min_w_0()
                    .min_h_0()
                    .overflow_hidden();
                children.push(
                    if horizontal {
                        slot.flex_1().h_full()
                    } else {
                        slot.w_full().h(gpui::relative(share))
                    }
                    .child(body)
                    .into_any_element(),
                );
                continue;
            }
            let peer = self.render_peer_chat_pane(ix, pane.as_deref(), &theme, cx);
            let slot = div().relative().flex_none().overflow_hidden();
            children.push(
                if horizontal {
                    slot.h_full().w(px((total_width * share).max(0.0)))
                } else {
                    slot.w_full().h(gpui::relative(share))
                }
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
            .on_mouse_move(
                cx.listener(move |this, event: &gpui::MouseMoveEvent, _, cx| {
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
                }),
            )
            .on_mouse_up(
                gpui::MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    if this.chat_split_drag.take().is_some() {
                        this.persist_chat_layout(cx);
                    }
                }),
            )
            .child(
                gpui::canvas(
                    move |bounds, _, _| measured.set(Some(bounds)),
                    |_, _, _, _| {},
                )
                .absolute()
                .inset_0(),
            );
        if horizontal {
            root.flex_row()
        } else {
            root.flex_col()
        }
        .children(children)
        .into_any_element()
    }

    /// A 1px divider with a wider invisible grab area: drag to resize the two
    /// panes beside it, double-click to equalize (Ghostty).
    fn render_split_divider(
        &mut self,
        ix: usize,
        horizontal: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let dragging = self
            .chat_split_drag
            .as_ref()
            .is_some_and(|d| d.divider == ix);
        let grab = div()
            .id(("chat-split-divider", ix))
            .absolute()
            .when(horizontal, |el| {
                el.top_0()
                    .bottom_0()
                    .left(px(-4.0))
                    .w(px(9.0))
                    .cursor_col_resize()
            })
            .when(!horizontal, |el| {
                el.left_0()
                    .right_0()
                    .top(px(-4.0))
                    .h(px(9.0))
                    .cursor_row_resize()
            })
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
                        origin: if horizontal {
                            f32::from(event.position.x)
                        } else {
                            f32::from(event.position.y)
                        },
                        start: split.shares.clone(),
                    });
                    cx.notify();
                }),
            );
        let line = div().relative().flex_none().bg(if dragging {
            theme.accent.opacity(0.7)
        } else {
            theme.border
        });
        if horizontal {
            line.w(px(1.0)).h_full()
        } else {
            line.h(px(1.0)).w_full()
        }
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
            .and_then(|id| {
                self.state
                    .read(cx)
                    .spaces
                    .iter()
                    .find(|s| s.id == id)
                    .map(space_label)
            })
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
                div()
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .child(transcript)
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
                    .truncate()
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child(title),
            )
            // Ghostty dims unfocused splits.
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .opacity(0.8)
                    .child(body),
            )
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(move |this, _, window, cx| this.focus_chat_pane(ix, window, cx)),
            )
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
    /// The pane glyph for a chat open in an UNFOCUSED pane (sidebar badge).
    pub(super) fn peer_pane_badge(&self, chat_id: &str) -> Option<SharedString> {
        let split = self.chat_split.as_ref().filter(|s| !s.zoomed)?;
        if !matches!(self.route, Route::Chat) {
            return None;
        }
        let ix = split
            .panes
            .iter()
            .enumerate()
            .position(|(ix, pane)| ix != split.focus && pane.as_deref() == Some(chat_id))?;
        Some(pane_glyph(split.axis, ix, split.panes.len()).into())
    }

    /// A strip of mini cards mirroring the split above the session list:
    /// each shows its pane's session and workspace (project), the focused
    /// one lit. Click a card to move into that pane. Hovering the strip eases
    /// open a preview of the hovered card's conversation underneath.
    pub(super) fn render_pane_strip(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let split = self
            .chat_split
            .clone()
            .filter(|_| matches!(self.route, Route::Chat))?;
        let len = split.panes.len();
        let hovered = self.pane_strip_hovered.min(len - 1);
        let t = motion::reveal_t(STRIP_REVEAL_KEY);
        struct Card {
            title: SharedString,
            project: SharedString,
        }
        let (cards, preview) = {
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
                    // The focused pane's workspace is the live sidebar filter.
                    let project = if ix == split.focus {
                        self.settings.space_filter.clone()
                    } else {
                        split.projects.get(ix).cloned().flatten()
                    };
                    Card {
                        title: pane_chat(ix)
                            .and_then(|id| state.chats.iter().find(|c| c.id == id))
                            .map(|c| {
                                transcript::single_line(
                                    &c.title.clone().unwrap_or_else(|| "Untitled".into()),
                                )
                            })
                            .unwrap_or_else(|| "New session".into())
                            .into(),
                        project: project
                            .as_deref()
                            .and_then(|id| state.spaces.iter().find(|s| s.id == id))
                            .map(space_label)
                            .unwrap_or_else(|| "All projects".into())
                            .into(),
                    }
                })
                .collect();
            // Only build the preview while it is (becoming) visible.
            let preview = (t > 0.001).then(|| match pane_chat(hovered) {
                Some(_) if hovered == split.focus => conversation_preview(&state.transcript),
                Some(id) => conversation_preview(state.sub_transcript(&id)),
                None => ConversationPreview::default(),
            });
            (cards, preview)
        };

        let mut row: Vec<AnyElement> = Vec::with_capacity(len);
        for (ix, card) in cards.into_iter().enumerate() {
            let focused = ix == split.focus;
            let lit = t > 0.001 && ix == hovered;
            row.push(
                div()
                    .id(("chat-pane-card", ix))
                    .flex_1()
                    .min_w(px(96.0))
                    .px(px(8.0))
                    .py(px(7.0))
                    .rounded(px(10.0))
                    .border_1()
                    .border_color(if focused {
                        theme.accent.opacity(0.55)
                    } else {
                        theme.border
                    })
                    .bg(if focused || lit {
                        theme.ink(0.05)
                    } else {
                        theme.ink(0.015)
                    })
                    .cursor_pointer()
                    .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                        if *hovered && this.pane_strip_hovered != ix {
                            this.pane_strip_hovered = ix;
                            cx.notify();
                        }
                    }))
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
                                div()
                                    .flex_none()
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .text_color(if focused {
                                        theme.accent
                                    } else {
                                        theme.text_muted
                                    })
                                    .child(SharedString::from(pane_glyph(split.axis, ix, len))),
                            )
                            .child(
                                div()
                                    .min_w_0()
                                    .flex_1()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(12.5))
                                    .font_weight(gpui::FontWeight::MEDIUM)
                                    .text_color(if focused {
                                        theme.text
                                    } else {
                                        theme.text_muted
                                    })
                                    .child(card.title),
                            ),
                    )
                    .child(
                        div()
                            .mt(px(2.0))
                            .pl(px(16.0))
                            .truncate()
                            .text_size(crate::typography::ui_rems(11.0))
                            .text_color(theme.text_muted.opacity(0.75))
                            .child(card.project),
                    )
                    .into_any_element(),
            );
        }

        let panel = preview.map(|preview| {
            let line = |label: &'static str, text: Option<SharedString>, lines: usize| {
                div()
                    .flex()
                    .flex_col()
                    .gap(px(1.0))
                    .child(
                        div()
                            .text_size(crate::typography::ui_rems(10.5))
                            .text_color(theme.text_muted.opacity(0.7))
                            .child(SharedString::from(label)),
                    )
                    .child(
                        div()
                            .h(px(17.0 * lines as f32))
                            .overflow_hidden()
                            .text_size(crate::typography::ui_rems(12.0))
                            .line_height(px(17.0))
                            .text_color(theme.text)
                            .child(text.unwrap_or_else(|| "—".into())),
                    )
            };
            div()
                .h(px(PREVIEW_HEIGHT * t))
                .opacity(t)
                .overflow_hidden()
                .child(
                    div()
                        .mt(px(6.0))
                        .p(px(10.0))
                        .rounded(px(10.0))
                        .bg(theme.ink(0.035))
                        .flex()
                        .flex_col()
                        .gap(px(6.0))
                        .child(line("You", preview.prompt, 1))
                        .child(line(
                            if preview.streaming {
                                "Working…"
                            } else {
                                "Reply"
                            },
                            preview.reply,
                            3,
                        )),
                )
        });

        Some(
            div()
                .id("sidebar-pane-strip")
                .px(px(Theme::SPACE_SM))
                .pb(px(8.0))
                .flex()
                .flex_col()
                .on_hover(motion::reveal_listener(STRIP_REVEAL_KEY))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .flex_wrap()
                        .items_start()
                        .gap(px(6.0))
                        .children(row),
                )
                .children(panel)
                .into_any_element(),
        )
    }
}

impl Shell {
    /// While a sidebar session is being dragged, Ghostty-style drop targets
    /// over the chat area: the right edge opens it in a new pane to the
    /// right, the bottom edge in a new pane below.
    pub(super) fn render_split_drop_zones(
        &self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
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
                .on_drop(
                    cx.listener(move |this, payload: &SidebarSessionDrag, window, cx| {
                        let chat = payload.chat_id.clone();
                        this.cancel_sidebar_session_transfer(cx);
                        this.split_chat_opening(axis, Some(chat), window, cx);
                    }),
                )
        };
        let mut zones = Vec::new();
        let right = self.can_split(SplitAxis::Horizontal);
        let below = self.can_split(SplitAxis::Vertical);
        if right {
            zones.push(
                zone(
                    "chat-drop-right",
                    SplitAxis::Horizontal,
                    "Open to the right ◨",
                )
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
            let zone = if right {
                zone.right(gpui::relative(0.33))
            } else {
                zone.right(px(8.0))
            };
            zones.push(zone.into_any_element());
        }
        zones
    }
}

pub(super) const STRIP_REVEAL_KEY: &str = "chat-pane-strip";
/// Revealed height of the hover preview (prompt line + three reply lines).
const PREVIEW_HEIGHT: f32 = 132.0;

/// Markdown to one line of prose: drop heading/quote/list markers and
/// emphasis/code fences, collapse whitespace.
fn plain_text(markdown: &str) -> String {
    markdown
        .lines()
        .map(|line| {
            let line = line.trim_start();
            let line = line.trim_start_matches('#').trim_start_matches('>');
            let line = line
                .strip_prefix("- ")
                .or_else(|| line.strip_prefix("* "))
                .unwrap_or(line);
            if line.trim_start().starts_with("```") {
                ""
            } else {
                line
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
        .replace("**", "")
        .replace("__", "")
        .replace('`', "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Default)]
struct ConversationPreview {
    prompt: Option<SharedString>,
    reply: Option<SharedString>,
    streaming: bool,
}

/// The latest prompt and reply text of a transcript, for the hover preview.
fn conversation_preview(entries: &[harness_doc::SessionMessageEntry]) -> ConversationPreview {
    // The latest text part (a reply streams its newest words last), with
    // markdown markers dropped so the preview reads as prose.
    let text = |entry: &harness_doc::SessionMessageEntry| {
        entry
            .parts
            .iter()
            .rev()
            .find_map(|part| match part {
                harness_doc::MessagePart::Text { text, .. } => Some(plain_text(text)),
                _ => None,
            })
            .filter(|text| !text.is_empty())
            .map(SharedString::from)
    };
    let mut preview = ConversationPreview {
        streaming: entries
            .last()
            .is_some_and(|e| e.status == Some(harness_doc::MessageStatus::Streaming)),
        ..Default::default()
    };
    for entry in entries.iter().rev() {
        match entry.role {
            harness_doc::MessageRole::User if preview.prompt.is_none() => {
                preview.prompt = text(entry)
            }
            harness_doc::MessageRole::Assistant
                if preview.reply.is_none() && preview.prompt.is_none() =>
            {
                preview.reply = text(entry)
            }
            _ => {}
        }
        if preview.prompt.is_some() {
            break;
        }
    }
    preview
}

#[cfg(test)]
mod chat_split_tests {
    use super::*;

    fn entry(role: harness_doc::MessageRole, text: &str) -> harness_doc::SessionMessageEntry {
        serde_json::from_value(serde_json::json!({
            "id": text, "role": role, "createdAt": 0, "deviceId": "d",
            "parts": [{"kind": "text", "id": "p", "text": text}],
        }))
        .unwrap()
    }

    #[test]
    fn preview_takes_the_latest_prompt_and_its_reply() {
        use harness_doc::MessageRole::{Assistant, User};
        let entries = [
            entry(User, "old"),
            entry(Assistant, "old reply"),
            entry(User, "fix  the\nbuild"),
            entry(Assistant, "done"),
        ];
        let p = conversation_preview(&entries);
        assert_eq!(p.prompt.as_deref(), Some("fix the build"));
        assert_eq!(p.reply.as_deref(), Some("done"));
        let p = conversation_preview(&entries[..3]);
        assert_eq!(p.reply, None, "no reply to the latest prompt yet");
        assert_eq!(
            plain_text("## Plan\n- **fix** the `build`\n```rust\nlet x;\n```"),
            "Plan fix the build let x;"
        );
    }

    fn two(selected: &str) -> ChatSplit {
        ChatSplit::split(
            None,
            SplitAxis::Horizontal,
            Some(selected.into()),
            Some("p".into()),
        )
        .unwrap()
    }

    #[test]
    fn split_parks_the_selection_and_focuses_a_fresh_pane() {
        let split = two("a");
        assert_eq!(split.panes, vec![Some("a".into()), None]);
        assert_eq!(split.focus, 1);
        assert_eq!(split.shares, vec![0.5, 0.5]);
        assert_eq!(split.peer_chats().collect::<Vec<_>>(), ["a"]);
        assert_eq!(
            split.projects,
            vec![Some("p".into()), Some("p".into())],
            "new pane inherits the project"
        );
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
        assert_eq!(
            split.focus_pane(0, Some("b".into())),
            Some(Some("a".into()))
        );
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
    fn splits_past_four_panes_share_the_column_evenly() {
        let mut split = two("a");
        let mut sizes = vec![split.panes.len()];
        while let Some(next) =
            ChatSplit::split(Some(split.clone()), SplitAxis::Horizontal, None, None)
        {
            split = next;
            sizes.push(split.panes.len());
            assert!((split.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
            assert!(
                split
                    .shares
                    .iter()
                    .all(|&s| s >= 1.0 / MAX_CHAT_PANES as f32 - 1e-5),
                "no sliver panes: {:?}",
                split.shares
            );
        }
        assert_eq!(sizes, (2..=MAX_CHAT_PANES).collect::<Vec<_>>());
        assert_eq!(
            split.focus,
            MAX_CHAT_PANES - 1,
            "the newest pane takes focus"
        );
        // Every divider still drags, even with the column full.
        let start = split.shares.clone();
        split.drag_divider(&start, 1, 0.02);
        assert!(split.shares[0] > start[0] && split.shares[1] < start[1]);
        assert!(split.resize(PaneDirection::Left));
        assert!((split.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn dragging_a_divider_moves_only_its_two_panes() {
        let mut split =
            ChatSplit::split(Some(two("a")), SplitAxis::Horizontal, None, None).unwrap();
        split.equalize();
        let start = split.shares.clone();
        split.drag_divider(&start, 1, 0.1);
        assert!((split.shares[0] - (1.0 / 3.0 + 0.1)).abs() < 1e-5);
        assert!((split.shares[1] - (1.0 / 3.0 - 0.1)).abs() < 1e-5);
        assert!(
            (split.shares[2] - 1.0 / 3.0).abs() < 1e-5,
            "far pane untouched"
        );
        split.drag_divider(&start, 1, 5.0);
        assert!(
            (split.shares[1] - MIN_PANE_SHARE).abs() < 1e-5,
            "clamped at the minimum"
        );
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
        let mut split =
            ChatSplit::split(Some(two("a")), SplitAxis::Horizontal, None, None).unwrap();
        split.panes[1] = Some("gone".into());
        split.equalize();
        let saved = split.to_saved();
        let back = ChatSplit::from_saved(&saved, |id| id == "a").unwrap();
        assert_eq!(
            back.panes,
            vec![Some("a".into()), None, None],
            "vanished chat → empty pane"
        );
        assert_eq!(back.focus, split.focus);
        assert!((back.shares.iter().sum::<f32>() - 1.0).abs() < 1e-5);
        let mut broken = saved.clone();
        broken.focus = 9;
        assert!(ChatSplit::from_saved(&broken, |_| true).is_none());
        broken = saved;
        broken.shares.pop();
        assert!(ChatSplit::from_saved(&broken, |_| true).is_none());
    }

    #[test]
    fn selecting_a_peer_chat_trades_places() {
        let mut split = two("a");
        split.selection_changed(Some("c".into()), Some("a"));
        assert_eq!(split.panes[0].as_deref(), Some("c"));
        split.selection_changed(Some("a".into()), Some("z"));
        assert_eq!(
            split.panes[0].as_deref(),
            Some("c"),
            "unrelated picks load in place"
        );
    }
}
