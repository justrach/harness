//! Desktop workspace sessions. A project is an optional association; it is
//! never the identity of a session, panel, or conversation tab.
use super::chat_tabs::ChatTab;
use super::session_sidebar::SessionSidebarRow;
use super::*;

impl Shell {
    pub(super) fn ensure_workspace_sessions(&mut self, cx: &mut Context<Self>) {
        if self.chat_tabs.is_empty() {
            let mut tab = self.park_chat_tab(cx);
            tab.id = uuid::Uuid::new_v4().to_string();
            let legacy = tab.project.clone().unwrap_or_default();
            if let Some(layout) = self.workspace_panels.layouts.remove(&legacy) {
                self.workspace_panels.layouts.insert(tab.id.clone(), layout);
            }
            self.chat_tabs.push(tab);
            self.chat_tab = 0;
        }
        self.chat_tab = self.chat_tab.min(self.chat_tabs.len() - 1);
        for tab in &mut self.chat_tabs {
            if tab.id.is_empty() {
                tab.id = uuid::Uuid::new_v4().to_string();
                let legacy = tab.project.clone().unwrap_or_default();
                if let Some(layout) = self.workspace_panels.layouts.remove(&legacy) {
                    self.workspace_panels.layouts.insert(tab.id.clone(), layout);
                }
            }
        }
    }

    pub(super) fn workspace_session_title(&self, tab: &ChatTab, cx: &App) -> String {
        let state = self.state.read(cx);
        tab.title
            .clone()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| {
                tab.selected
                    .as_deref()
                    .and_then(|id| state.chats.iter().find(|chat| chat.id == id))
                    .and_then(|chat| chat.title.as_deref())
                    .map(transcript::single_line)
                    .filter(|title| !title.is_empty())
                    .unwrap_or_else(|| "New session".into())
            })
    }

    pub(super) fn workspace_session_sidebar_rows(&self, cx: &App) -> Vec<SessionSidebarRow> {
        let mut rows: Vec<_> = self
            .chat_tabs
            .iter()
            .enumerate()
            .map(|(ix, tab)| SessionSidebarRow {
                id: tab.id.clone(),
                title: self.workspace_session_title(tab, cx),
                project: tab.project.clone(),
                active: ix == self.chat_tab,
                icon: session_icon::SessionIcon::from_key(tab.session_icon.as_deref()),
                pinned: tab.pinned,
            })
            .collect();
        rows.sort_by_key(|row| !row.pinned);
        rows
    }

    pub(super) fn set_workspace_session_icon(
        &mut self,
        id: &str,
        icon: Option<&str>,
        cx: &mut Context<Self>,
    ) {
        if icon.is_some_and(|key| !session_icon::is_valid_key(key)) {
            return;
        }
        if let Some(tab) = self.chat_tabs.iter_mut().find(|tab| tab.id == id) {
            tab.session_icon = icon.map(str::to_owned);
            self.persist_chat_tabs(cx);
            cx.notify();
        }
    }

    pub(super) fn set_workspace_session_pinned(
        &mut self,
        id: &str,
        pinned: bool,
        cx: &mut Context<Self>,
    ) {
        if let Some(tab) = self.chat_tabs.iter_mut().find(|tab| tab.id == id) {
            tab.pinned = pinned;
            let mut order: Vec<_> = self
                .chat_tabs
                .iter()
                .map(|tab| (tab.id.clone(), tab.pinned))
                .collect();
            order.sort_by_key(|(_, pinned)| !pinned);
            self.apply_workspace_session_order(order.into_iter().map(|(id, _)| id).collect(), cx);
        }
    }

    /// Reordering follows stable session IDs, including when a project filter
    /// hides other rows. Dropping into the pinned group pins the moved session.
    pub(super) fn move_workspace_session(
        &mut self,
        from: &str,
        to: &str,
        before: bool,
        cx: &mut Context<Self>,
    ) {
        if from == to || !self.chat_tabs.iter().any(|tab| tab.id == from) {
            return;
        }
        let Some(pinned) = self
            .chat_tabs
            .iter()
            .find(|tab| tab.id == to)
            .map(|tab| tab.pinned)
        else {
            return;
        };
        let mut order = self
            .workspace_session_sidebar_rows(cx)
            .into_iter()
            .map(|row| row.id)
            .collect::<Vec<_>>();
        order.retain(|id| id != from);
        let target = order.iter().position(|id| id == to).unwrap();
        order.insert(target + usize::from(!before), from.to_owned());
        self.chat_tabs
            .iter_mut()
            .find(|tab| tab.id == from)
            .unwrap()
            .pinned = pinned;
        self.apply_workspace_session_order(order, cx);
    }

    pub(super) fn apply_workspace_session_order(
        &mut self,
        order: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        let active = self.chat_tabs.get(self.chat_tab).map(|tab| tab.id.clone());
        let history: Vec<_> = self
            .chat_tab_history
            .iter()
            .filter_map(|ix| self.chat_tabs.get(*ix).map(|tab| tab.id.clone()))
            .collect();
        self.chat_tabs.sort_by_key(|tab| {
            order
                .iter()
                .position(|id| id == &tab.id)
                .unwrap_or(usize::MAX)
        });
        self.chat_tab = active
            .and_then(|id| self.chat_tabs.iter().position(|tab| tab.id == id))
            .unwrap_or(0);
        self.chat_tab_history = history
            .into_iter()
            .filter_map(|id| self.chat_tabs.iter().position(|tab| tab.id == id))
            .collect();
        let mut saved: Vec<_> = order.into_iter().map(Some).collect();
        for prior in &self.settings.session_overview_order {
            if !saved.contains(prior) {
                saved.push(prior.clone());
            }
        }
        let overview_order_changed = self.settings.session_overview_order != saved;
        self.settings.session_overview_order = saved;
        self.persist_chat_tabs(cx);
        if overview_order_changed {
            self.schedule_save(cx);
        }
        cx.notify();
    }

    pub(super) fn activate_workspace_session(&mut self, id: &str, cx: &mut Context<Self>) {
        self.session_overview = false;
        self.command_palette = None;
        self.route = Route::Chat;
        if let Some(ix) = self.chat_tabs.iter().position(|tab| tab.id == id) {
            if ix == self.chat_tab {
                self.composer
                    .update(cx, |composer, cx| composer.reveal_pending_question(cx));
            }
            self.activate_chat_tab(ix, cx);
            self.focus_composer(cx);
            cx.notify();
        }
    }

    pub(super) fn create_workspace_session(&mut self, cx: &mut Context<Self>) {
        self.session_overview = false;
        self.command_palette = None;
        self.route = Route::Chat;
        self.close_spaces_menu(cx);
        self.park_workspace_draft(cx);
        let explicit_project = self
            .settings
            .space_filter
            .clone()
            .filter(|id| self.state.read(cx).space_row(id).is_some());
        let defaults = crate::settings::composer::ComposerDefaults::load(&self.data_dir);
        // Viewing an existing conversation must not erase the saved choice
        // to start projectless sessions. An explicit project filter still wins.
        let restore_projectless = explicit_project.is_none() && defaults.no_project;
        let project = if restore_projectless {
            None
        } else {
            explicit_project.or_else(|| self.active_project(cx))
        };
        let mut draft = self.current_canvas_draft(cx).fresh();
        // The new session inherits run picks, never an unsent prompt. Restore
        // the projectless device only after the previous session is parked.
        draft.target = restore_projectless.then_some(crate::pickers::CanvasTarget {
            space: None,
            no_project: true,
            device: defaults.device,
        });
        if !self.chat_tabs.is_empty() {
            self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        }
        let tab = ChatTab {
            id: uuid::Uuid::new_v4().to_string(),
            project,
            draft: Some(draft),
            ..Default::default()
        };
        self.chat_tab = self.chat_tabs.len();
        self.chat_tabs.push(tab.clone());
        // An explicit session choice wins over a delayed boot restoration.
        self.boot_restored = true;
        self.load_chat_tab_without_window(tab, cx);
        self.sync_panel_workspace(cx);
        self.persist_chat_tabs(cx);
        self.focus_composer(cx);
        cx.notify();
    }

    pub(super) fn rename_workspace_session(
        &mut self,
        id: &str,
        title: String,
        cx: &mut Context<Self>,
    ) {
        let title = transcript::single_line(&title);
        if title.is_empty() {
            return;
        }
        if let Some(tab) = self.chat_tabs.iter_mut().find(|tab| tab.id == id) {
            tab.title = Some(title);
            self.persist_chat_tabs(cx);
            cx.notify();
        }
    }

    pub(super) fn close_workspace_session(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(ix) = self.chat_tabs.iter().position(|tab| tab.id == id) else {
            return;
        };
        self.park_workspace_draft(cx);
        self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        let closed = self.chat_tabs.remove(ix);
        self.remember_closed_chat_tab(closed, ix, cx);
        let next =
            chat_tabs::tab_after_close(ix, self.chat_tabs.len() + 1, &mut self.chat_tab_history);
        if self.chat_tabs.is_empty() {
            self.chat_tab = 0;
            // Keep a usable empty workspace; history and running agents are untouched.
            let tab = ChatTab {
                id: uuid::Uuid::new_v4().to_string(),
                ..Default::default()
            };
            self.chat_tabs.push(tab.clone());
            self.load_chat_tab_without_window(tab, cx);
        } else if ix == self.chat_tab {
            self.chat_tab = next.min(self.chat_tabs.len() - 1);
            self.load_chat_tab_without_window(self.chat_tabs[self.chat_tab].clone(), cx);
        } else {
            if ix < self.chat_tab {
                self.chat_tab -= 1;
            }
            self.persist_chat_tabs(cx);
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::workspace_panels::{PanelTab, WorkspacePanel};

    #[gpui::test]
    fn workspace_session_same_project_keeps_panels_tabs_and_drafts_separate(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
            let first = shell.chat_tabs[0].id.clone();
            shell.workspace_new_chat(cx);
            shell.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "First draft".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            let first_key = shell.panel_key(cx);
            let before = shell.panel_layout(cx).unwrap().panels[0].tabs.clone();
            shell.create_workspace_session(cx);
            let second = shell.chat_tabs[1].id.clone();
            assert_ne!(first, second);
            assert_eq!(shell.chat_tabs[0].project, shell.chat_tabs[1].project);
            assert_ne!(first_key, shell.panel_key(cx));
            let saved_first = shell.settings.chat_tabs[0].panel_layout.as_ref().unwrap();
            assert!(saved_first.panels.iter().flat_map(|panel| &panel.tabs).any(|tab| {
                matches!(tab, crate::settings::SavedPanelTab::Draft { draft } if draft.text == "First draft")
            }), "parking must save the outgoing session's latest unsent text before switching");
            assert!(
                shell
                    .current_canvas_draft(cx)
                    .input
                    .unwrap()
                    .text
                    .is_empty()
            );
            assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), 1);
            shell.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Second draft".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            shell.panel_layout_mut(cx).panels.push(WorkspacePanel {
                id: 9,
                tabs: vec![PanelTab::Chat("peer".into())],
                active: 0,
                share: 0.5,
            });
            shell.activate_workspace_session(&first, cx);
            assert_eq!(shell.panel_layout(cx).unwrap().panels[0].tabs, before);
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "First draft"
            );
            assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), 1);
            shell.activate_workspace_session(&second, cx);
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "Second draft"
            );
            assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), 2);
            assert_eq!(shell.settings.chat_tabs.len(), 2);
            assert_eq!(shell.settings.chat_tabs[0].id, first);
            assert_eq!(shell.settings.chat_tabs[1].id, second);
        })
        .unwrap();
    }

    #[gpui::test]
    fn workspace_session_names_and_same_project_identities_survive_restore(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            let first = shell.chat_tabs[0].id.clone();
            shell.rename_workspace_session(&first, "Research".into(), cx);
            shell.create_workspace_session(cx);
            let second = shell.chat_tabs[1].id.clone();
            shell.rename_workspace_session(&second, "Implementation".into(), cx);
            let saved = shell.settings.chat_tabs.clone();
            shell.chat_tabs.clear();
            assert!(shell.restore_project_tabs(cx));
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(shell.chat_tabs[0].id, first);
            assert_eq!(shell.chat_tabs[1].id, second);
            assert_eq!(
                shell.workspace_session_title(&shell.chat_tabs[0], cx),
                "Research"
            );
            assert_eq!(
                shell.workspace_session_title(&shell.chat_tabs[1], cx),
                "Implementation"
            );
            assert_eq!(shell.settings.chat_tabs, saved);
        })
        .unwrap();
    }
    #[gpui::test]
    fn workspace_session_projectless_identity_survives_foreign_conversation_selection(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.chat_tabs[0].project = None;
            shell.settings.space_filter = None;
            shell.persist_chat_tabs(cx);
            let session = shell.chat_tabs[0].id.clone();
            let title = shell.chat_tabs[0].title.clone();
            shell.sync_panel_workspace(cx);
            shell.focus_workspace_tab(0, PanelTab::Chat("target".into()), window, cx);
            assert_eq!(shell.chat_tabs.len(), 1);
            assert_eq!(shell.chat_tabs[0].id, session);
            assert_eq!(shell.chat_tabs[0].project, None);
            assert_eq!(shell.active_project(cx), None);
            assert_eq!(
                shell.chat_tabs[0].title, title,
                "switching a conversation never renames its session"
            );
        })
        .unwrap();
    }

    #[gpui::test]
    fn workspace_session_missing_project_keeps_identity_and_association(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.create_workspace_session(cx);
            let ids = shell
                .chat_tabs
                .iter()
                .map(|tab| tab.id.clone())
                .collect::<Vec<_>>();
            shell.state.update(cx, |state, _| {
                state.spaces_synced = true;
                state.spaces.retain(|space| space.id != "a");
            });
            shell.reconcile_project_tabs(cx);
            assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            assert_eq!(
                shell
                    .chat_tabs
                    .iter()
                    .map(|tab| tab.id.clone())
                    .collect::<Vec<_>>(),
                ids
            );
            assert!(
                shell
                    .workspace_session_sidebar_rows(cx)
                    .iter()
                    .all(|row| row.project.as_deref() == Some("a"))
            );
        })
        .unwrap();
    }
}
