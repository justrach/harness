//! Chat tabs: each tab keeps its own split layout, selection and project,
//! like a terminal's tabs holding their splits. ⌘T opens a fresh tab; ⌘D
//! also opens one when another side-by-side pane would be too narrow to read
//! (`MIN_PANE_WIDTH`), so a wall of slivers never builds up.
//!
//! The ACTIVE tab lives in the ordinary shell fields (`chat_split`, the app
//! selection, the sidebar filter); parked tabs hold copies. Switching parks
//! the live state and loads the target's, the way focusing a pane swaps.

use super::*;

/// Narrowest a side-by-side chat pane may get before ⌘D opens a tab instead.
pub(super) const MIN_PANE_WIDTH: f32 = 380.0;

/// A tab's layout while it isn't the active one.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct ChatTab {
    pub split: Option<chat_split::ChatSplit>,
    pub selected: Option<String>,
    pub project: Option<String>,
}

/// Whether one more side-by-side pane still leaves every pane readable.
pub(super) fn fits_another_pane(column_width: f32, panes: usize) -> bool {
    column_width <= 0.0 || column_width / (panes + 1) as f32 >= MIN_PANE_WIDTH
}

/// The tab to show after closing `closed` of `len`: its left neighbor, or the
/// new first tab when the first one closed.
pub(super) fn tab_after_close(closed: usize, len: usize) -> usize {
    closed.saturating_sub(1).min(len.saturating_sub(2))
}

impl Shell {
    fn park_chat_tab(&mut self, cx: &App) -> ChatTab {
        ChatTab {
            split: self.chat_split.clone(),
            selected: self.state.read(cx).selected_chat.clone(),
            project: self.settings.space_filter.clone(),
        }
    }

    fn load_chat_tab(&mut self, tab: ChatTab, window: &mut Window, cx: &mut Context<Self>) {
        self.chat_split = tab.split;
        self.chat_split_selected = tab.selected.clone();
        if self.chat_split.is_none() {
            motion::reveal_reset(chat_split::STRIP_REVEAL_KEY);
        }
        self.state.update(cx, |s, cx| s.select_chat(tab.selected, cx));
        self.set_space_filter(tab.project, cx);
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    /// ⌘T: a new tab with one pane showing `open` (`None` = a fresh
    /// new-session canvas in the current project). The layout you were in
    /// stays whole in its own tab.
    pub(super) fn new_chat_tab(&mut self, open: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        if !matches!(self.route, Route::Chat) {
            return;
        }
        let parked = self.park_chat_tab(cx);
        let project = parked.project.clone();
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
        };
        self.chat_tabs.push(tab.clone());
        self.chat_tab = self.chat_tabs.len() - 1;
        self.load_chat_tab(tab, window, cx);
    }

    pub(super) fn switch_chat_tab(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) {
        if ix == self.chat_tab || ix >= self.chat_tabs.len() || !matches!(self.route, Route::Chat) {
            return;
        }
        self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        self.chat_tab = ix;
        let tab = self.chat_tabs[ix].clone();
        self.load_chat_tab(tab, window, cx);
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
    /// other tabs remain. Its chats stay in the sidebar.
    pub(super) fn close_chat_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.chat_tabs.len() < 2 || !matches!(self.route, Route::Chat) {
            return false;
        }
        let closed = self.chat_tab;
        let next = tab_after_close(closed, self.chat_tabs.len());
        self.chat_tabs.remove(closed);
        self.chat_tab = next;
        let tab = self.chat_tabs[next].clone();
        if self.chat_tabs.len() == 1 {
            self.chat_tabs.clear();
            self.chat_tab = 0;
        }
        self.load_chat_tab(tab, window, cx);
        true
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

    /// Tab titles, active tab from the live state: the focused chat's title
    /// and how many panes the tab holds.
    fn chat_tab_labels(&self, cx: &App) -> Vec<(SharedString, usize)> {
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
                    (
                        title(state.selected_chat.as_deref()),
                        self.chat_split.as_ref().map_or(1, |s| s.panes.len()),
                    )
                } else {
                    (
                        title(tab.selected.as_deref()),
                        tab.split.as_ref().map_or(1, |s| s.panes.len()),
                    )
                }
            })
            .collect()
    }

    /// The tab row above the sidebar's pane strip, shown once there are two
    /// or more tabs. Click to switch; the lit tab is the one on screen.
    pub(super) fn render_chat_tabs(&mut self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.chat_tabs.len() < 2 || !matches!(self.route, Route::Chat) {
            return None;
        }
        let labels = self.chat_tab_labels(cx);
        let active = self.chat_tab;
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
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted.opacity(0.8))
                        .child(SharedString::from(format!("Tabs · {}", labels.len()))),
                )
                .children(labels.into_iter().enumerate().map(|(ix, (title, panes))| {
                    let lit = ix == active;
                    let key: SharedString = format!("chat-tab-{ix}").into();
                    div()
                        .id(("chat-tab", ix))
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
                        .child(
                            div()
                                .flex_none()
                                .w(px(14.0))
                                .text_size(crate::typography::ui_rems(11.0))
                                .text_color(theme.text_muted.opacity(0.7))
                                .child(SharedString::from(format!("{}", ix + 1))),
                        )
                        .child(div().flex_1().min_w_0().truncate().child(title))
                        .when(panes > 1, |row| {
                            row.child(
                                div()
                                    .flex_none()
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .text_color(theme.text_muted.opacity(0.7))
                                    .child(SharedString::from(format!("{panes} panes"))),
                            )
                        })
                }))
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_stop_before_panes_get_unreadable() {
        // 1200px column: two panes of 600 fit, a third at 400 fits, a fourth
        // at 300 would not.
        assert!(fits_another_pane(1200.0, 1));
        assert!(fits_another_pane(1200.0, 2));
        assert!(!fits_another_pane(1200.0, 3));
        // Unmeasured (first frame) never blocks a split.
        assert!(fits_another_pane(0.0, 7));
    }

    #[test]
    fn closing_a_tab_lands_on_its_neighbor() {
        assert_eq!(tab_after_close(0, 3), 0);
        assert_eq!(tab_after_close(1, 3), 0);
        assert_eq!(tab_after_close(2, 3), 1);
        assert_eq!(tab_after_close(1, 2), 0);
    }
}
