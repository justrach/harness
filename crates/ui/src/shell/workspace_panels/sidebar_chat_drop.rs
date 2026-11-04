//! What the panels accept from outside: a chat dragged from the sidebar, and
//! files dragged from the desktop. Tab drags between panels live in
//! `window_drag.rs` and the panel header.
use super::*;

impl WorkspaceLayout {
    /// Show a sidebar chat in `panel`. A chat already in this layout moves
    /// there, so one conversation never holds two tabs.
    pub(super) fn place_chat(&mut self, chat: &str, panel: u64) {
        let tab = PanelTab::Chat(chat.into());
        match self.location(&tab) {
            Some((from, _)) if from != panel => {
                self.move_tab(from, &tab, panel, None);
            }
            _ => self.insert(panel, tab),
        }
    }

    /// Open a sidebar chat in a new panel beside `beside`. `None` when there
    /// is no room, or when the chat is already that panel's only tab.
    pub(super) fn open_chat_beside(
        &mut self,
        chat: &str,
        beside: u64,
        edge: PanelEdge,
    ) -> Option<u64> {
        let tab = PanelTab::Chat(chat.into());
        if let Some((from, _)) = self.location(&tab) {
            return self.split_tab(from, &tab, beside, edge);
        }
        if self.panel(beside).is_none() || !self.can_add_panel(edge.axis()) {
            return None;
        }
        self.axis = edge.axis();
        let to = self.add_panel(beside);
        if !edge.after() {
            self.reorder_panel(to, false);
        }
        self.insert(to, tab);
        Some(to)
    }
}

/// Whether the panel body itself takes dropped files. The chat or draft the
/// composer is showing goes through `render_main`, whose own dropzone takes
/// them, so a drop there must not reach this handler too. Tools (a terminal,
/// a browser, a file tree) don't attach files.
pub(super) fn panel_body_takes_files(
    tab: Option<&PanelTab>,
    selected_chat: Option<&str>,
    focused: bool,
) -> bool {
    match tab {
        Some(PanelTab::Chat(id)) => selected_chat != Some(id.as_str()),
        Some(PanelTab::Draft(_)) => selected_chat.is_some() || !focused,
        Some(PanelTab::New(_) | PanelTab::Empty) | None => true,
        Some(_) => false,
    }
}

impl Shell {
    fn drop_sidebar_chat_on_panel(
        &mut self,
        chat: &str,
        panel: u64,
        edge: Option<PanelEdge>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.split_drop_session = None;
        self.cancel_sidebar_session_transfer(cx);
        // Archived or deleted while it was being dragged.
        if !self.state.read(cx).visible_chats().any(|c| c.id == chat) {
            cx.notify();
            return;
        }
        self.park_workspace_draft(cx);
        let tab = PanelTab::Chat(chat.to_owned());
        let opened = match edge {
            Some(edge) => self
                .panel_layout_mut(cx)
                .open_chat_beside(chat, panel, edge),
            None => {
                self.panel_layout_mut(cx).place_chat(chat, panel);
                None
            }
        };
        if let Some(opened) = opened {
            self.start_panel_insertion(opened, panel, cx);
        }
        // A declined split still shows the chat, where it already is or here.
        let target = opened
            .or_else(|| self.panel_layout(cx)?.location(&tab).map(|(id, _)| id))
            .unwrap_or(panel);
        self.focus_workspace_tab(target, tab, window, cx);
        cx.notify();
    }

    /// A sidebar row's menu or Option-click: the same as dropping the chat on
    /// the focused panel's right edge, for people who'd rather not drag.
    pub(in crate::shell) fn open_sidebar_chat_to_the_right(
        &mut self,
        chat: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.panel_layout(cx).map(|layout| layout.focused) {
            Some(panel) => {
                self.drop_sidebar_chat_on_panel(chat, panel, Some(PanelEdge::Right), window, cx)
            }
            None => self.open_chat_in_tab(chat.to_owned(), window, cx),
        }
    }

    /// Where a dragged sidebar chat can land on this panel: its right edge,
    /// its bottom edge, or the middle for a new tab. Keyed on
    /// `split_drop_session` so a synced frame that ends the sidebar's reorder
    /// preview can't take the targets away mid-drag.
    pub(super) fn render_panel_chat_drop_zones(
        &self,
        panel: u64,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(chat) = self.split_drop_session.clone() else {
            return Empty.into_any_element();
        };
        let (right, below) = self.panel_layout(cx).map_or((false, false), |layout| {
            (
                layout.can_add_panel(SplitAxis::Horizontal),
                layout.can_add_panel(SplitAxis::Vertical),
            )
        });
        let accent = theme.accent;
        let border = theme.border;
        let fill = theme.ink(0.02);
        let text = theme.text_muted;
        let mut zone = |name: &'static str, edge: Option<PanelEdge>, label: &'static str| {
            let chat = chat.clone();
            div()
                .id(SharedString::from(format!(
                    "panel-chat-drop-{panel}-{name}"
                )))
                .debug_selector(move || format!("panel-chat-drop-{panel}-{name}"))
                .absolute()
                .flex()
                .items_center()
                .justify_center()
                .overflow_hidden()
                .rounded(px(10.0))
                .border_1()
                .border_dashed()
                .border_color(border)
                .bg(fill)
                .text_size(crate::typography::ui_rems(12.5))
                .text_color(text)
                .child(SharedString::from(label))
                .drag_over::<SidebarSessionDrag>(move |style, _, _, _| {
                    style
                        .bg(accent.opacity(0.14))
                        .border_color(accent.opacity(0.7))
                        .text_color(accent)
                })
                .on_drop(
                    cx.listener(move |this, _: &SidebarSessionDrag, window, cx| {
                        this.drop_sidebar_chat_on_panel(&chat, panel, edge, window, cx);
                        cx.stop_propagation();
                    }),
                )
        };
        let here = zone("here", None, "Open here")
            .left(px(8.0))
            .top(px(8.0))
            .right(if right {
                gpui::relative(0.34)
            } else {
                px(8.0).into()
            })
            .bottom(if below {
                gpui::relative(0.31)
            } else {
                px(8.0).into()
            });
        let beside = right.then(|| {
            zone("right", Some(PanelEdge::Right), "Open to the right ◨")
                .top(px(8.0))
                .bottom(px(8.0))
                .right(px(8.0))
                .w(gpui::relative(0.3))
        });
        let under = below.then(|| {
            zone("below", Some(PanelEdge::Bottom), "Open below ⬓")
                .left(px(8.0))
                .bottom(px(8.0))
                .h(gpui::relative(0.27))
                // Leave the right column to the right-hand target.
                .right(if right {
                    gpui::relative(0.34)
                } else {
                    px(8.0).into()
                })
        });
        // Deferred: only deferred elements paint above a browser's native
        // page, so anything else would leave these targets hidden behind it.
        gpui::deferred(
            div()
                .id(("panel-chat-drop", panel))
                .absolute()
                .inset_0()
                .occlude()
                .bg(theme.bg.opacity(0.72))
                .child(here)
                .children(beside)
                .children(under),
        )
        .into_any_element()
    }

    /// Files released on a panel the composer isn't showing: focus that panel
    /// first, so they attach to its conversation rather than the last one.
    pub(super) fn drop_paths_on_panel(
        &mut self,
        panel: u64,
        tab: Option<PanelTab>,
        mut paths: Vec<std::path::PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        paths.retain(|path| !path.as_os_str().is_empty());
        if paths.is_empty() || !self.focus_panel_for_drop(panel, tab, window, cx) {
            return;
        }
        self.composer
            .update(cx, |composer, cx| composer.add_paths(paths, cx));
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    /// A file from the file tree released on a panel the composer isn't
    /// showing. It mentions the file in that panel's conversation.
    pub(super) fn drop_workspace_path_on_panel(
        &mut self,
        panel: u64,
        tab: Option<PanelTab>,
        path: &crate::files::WorkspacePathDrag,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.focus_panel_for_drop(panel, tab, window, cx) {
            return;
        }
        self.composer.update(cx, |composer, cx| {
            composer.add_workspace_path(&path.path, path.is_directory, window, cx)
        });
        cx.notify();
    }

    /// Bring the conversation under a drop to the composer. False when there
    /// is none to take it, or the panel changed under the drag.
    fn focus_panel_for_drop(
        &mut self,
        panel: u64,
        tab: Option<PanelTab>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let current = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .and_then(|panel| panel.selected().cloned());
        if current != tab {
            return false;
        }
        match tab {
            Some(PanelTab::Chat(id)) => {
                if !self.state.read(cx).chats.iter().any(|chat| chat.id == id) {
                    return false;
                }
                self.focus_workspace_tab(panel, PanelTab::Chat(id), window, cx);
                true
            }
            Some(tab @ PanelTab::Draft(_)) => {
                self.focus_workspace_tab(panel, tab, window, cx);
                true
            }
            Some(PanelTab::New(_) | PanelTab::Empty) | None => {
                // An empty panel becomes a new conversation on its computer.
                self.activate_workspace_empty(panel, 0, window, cx);
                self.panel_layout(cx)
                    .and_then(|layout| layout.panel(layout.focused))
                    .and_then(|panel| panel.selected())
                    .is_some_and(|tab| matches!(tab, PanelTab::Draft(_)))
            }
            Some(_) => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout(tabs: &[&[&str]]) -> WorkspaceLayout {
        let mut layout = WorkspaceLayout::default();
        let mut panel = 0;
        for (ix, chats) in tabs.iter().enumerate() {
            if ix > 0 {
                panel = layout.add_panel(panel);
            }
            for chat in *chats {
                layout
                    .panel_mut(panel)
                    .unwrap()
                    .tabs
                    .push(PanelTab::Chat((*chat).into()));
            }
        }
        layout
    }

    fn chats(layout: &WorkspaceLayout) -> Vec<Vec<String>> {
        layout
            .panels
            .iter()
            .map(|panel| {
                panel
                    .tabs
                    .iter()
                    .filter_map(|tab| match tab {
                        PanelTab::Chat(id) => Some(id.clone()),
                        _ => None,
                    })
                    .collect()
            })
            .collect()
    }

    #[test]
    fn placing_a_chat_moves_it_instead_of_opening_it_twice() {
        let mut two = layout(&[&["a", "b"], &["c"]]);
        let second = two.panels[1].id;
        two.place_chat("b", second);
        assert_eq!(chats(&two), [vec!["a"], vec!["c", "b"]]);
        assert_eq!(two.focused, second);
        // Already there: selected, not added.
        two.place_chat("c", second);
        assert_eq!(chats(&two), [vec!["a"], vec!["c", "b"]]);
        assert_eq!(two.panels[1].selected(), Some(&PanelTab::Chat("c".into())));
    }

    #[test]
    fn opening_beside_adds_a_panel_on_the_chosen_edge() {
        let mut one = layout(&[&["a"]]);
        let first = one.panels[0].id;
        let opened = one
            .open_chat_beside("new", first, PanelEdge::Right)
            .unwrap();
        assert_eq!(chats(&one), [vec!["a"], vec!["new"]]);
        assert_eq!(one.focused, opened);
        assert_eq!(one.axis, SplitAxis::Horizontal);

        let mut left = layout(&[&["a"]]);
        let first = left.panels[0].id;
        left.open_chat_beside("new", first, PanelEdge::Left)
            .unwrap();
        assert_eq!(chats(&left), [vec!["new"], vec!["a"]]);
    }

    #[test]
    fn opening_beside_moves_a_chat_already_open_and_respects_the_limits() {
        let mut two = layout(&[&["a", "b"], &["c"]]);
        let first = two.panels[0].id;
        two.open_chat_beside("b", first, PanelEdge::Right).unwrap();
        assert_eq!(chats(&two), [vec!["a"], vec!["b"], vec!["c"]]);

        // Its panel's only tab: nothing to split off.
        let mut one = layout(&[&["a"]]);
        let first = one.panels[0].id;
        assert_eq!(one.open_chat_beside("a", first, PanelEdge::Right), None);
        assert_eq!(chats(&one), [vec!["a"]]);

        // No room for another stacked panel.
        let mut full = layout(&[&["a"], &["b"]]);
        full.stack_limit = 2;
        let first = full.panels[0].id;
        assert_eq!(full.open_chat_beside("new", first, PanelEdge::Bottom), None);
        assert_eq!(full.panels.len(), 2);
        assert!(
            full.open_chat_beside("new", first, PanelEdge::Right)
                .is_some()
        );

        // The panel went away mid-drag.
        let mut gone = layout(&[&["a"]]);
        assert_eq!(gone.open_chat_beside("new", 99, PanelEdge::Right), None);
    }

    #[test]
    fn only_panels_without_the_live_composer_take_files_themselves() {
        let chat = PanelTab::Chat("a".into());
        assert!(panel_body_takes_files(Some(&chat), Some("b"), false));
        assert!(panel_body_takes_files(Some(&chat), None, false));
        assert!(!panel_body_takes_files(Some(&chat), Some("a"), true));
        let draft = PanelTab::Draft(1);
        assert!(panel_body_takes_files(Some(&draft), None, false));
        assert!(panel_body_takes_files(Some(&draft), Some("a"), true));
        assert!(!panel_body_takes_files(Some(&draft), None, true));
        assert!(panel_body_takes_files(
            Some(&PanelTab::Empty),
            Some("a"),
            true
        ));
        assert!(panel_body_takes_files(None, None, true));
        assert!(!panel_body_takes_files(
            Some(&PanelTab::Terminal(1)),
            Some("a"),
            true
        ));
    }
}
