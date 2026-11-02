//! Project navigation. A tab is a view of one existing Space; conversations
//! and their agent sessions keep their own identities and lifecycle.
use super::*;

impl Shell {
    pub(in crate::shell) fn active_project(&self, cx: &App) -> Option<String> {
        if let Some(tab) = self
            .chat_tabs
            .get(self.chat_tab)
            .filter(|tab| !tab.id.is_empty())
        {
            return tab.project.clone();
        }
        self.settings.space_filter.clone().or_else(|| {
            let state = self.state.read(cx);
            state
                .selected_chat_row()
                .and_then(|chat| chat.space_id.clone())
                .or_else(|| state.selected_space.clone())
        })
    }

    pub(in crate::shell) fn project_sidebar_filter(&self, cx: &App) -> Option<String> {
        self.active_project(cx)
            .or_else(|| self.state.read(cx).no_project.then(|| String::new()))
    }

    /// Open an existing project once, restoring its most recent view.
    pub(in crate::shell) fn open_project_tab(
        &mut self,
        project: Option<String>,
        cx: &mut Context<Self>,
    ) {
        self.session_overview = false;
        if project
            .as_ref()
            .is_some_and(|id| self.state.read(cx).space_row(id).is_none())
        {
            return;
        }
        self.route = Route::Chat;
        self.close_spaces_menu(cx);
        self.ensure_workspace_sessions(cx);
        self.park_workspace_draft(cx);
        let current = self.park_chat_tab(cx);
        let mut fresh = self.current_canvas_draft(cx).fresh();
        fresh.target = None;
        if current.project == project {
            self.set_space_filter(project, cx);
            self.persist_chat_tabs(cx);
            self.focus_composer(cx);
            return;
        }
        self.record_chat_tab_visit();
        if self.chat_tabs.is_empty() {
            // Don't keep the initial projectless welcome canvas as a project.
            if current.project.is_some() || current.selected.is_some() {
                self.chat_tabs.push(current);
            }
        } else {
            self.chat_tabs[self.chat_tab] = current;
        }
        let remembered_index = self
            .chat_tab_history
            .iter()
            .rev()
            .copied()
            .find(|&ix| {
                self.chat_tabs
                    .get(ix)
                    .is_some_and(|tab| tab.project == project)
            })
            .or_else(|| self.chat_tabs.iter().position(|tab| tab.project == project));
        if let Some(ix) = remembered_index {
            self.chat_tab = ix;
        } else {
            let remembered = self
                .closed_chat_tabs
                .iter()
                .rposition(|closed| closed.tab.project == project)
                .map(|ix| self.closed_chat_tabs.remove(ix).tab);
            let tab = remembered.unwrap_or_else(|| {
                let state = self.state.read(cx);
                let selected = state
                    .sidebar_chats(Utc::now(), project.as_deref())
                    .into_iter()
                    .find(|(_, chat)| chat.space_id == project)
                    .map(|(_, chat)| chat.id.clone());
                ChatTab {
                    id: uuid::Uuid::new_v4().to_string(),
                    project: project.clone(),
                    draft: selected.is_none().then_some(fresh),
                    selected,
                    ..Default::default()
                }
            });
            self.chat_tab = self.chat_tabs.len();
            self.chat_tabs.push(tab);
        }
        self.record_chat_tab_visit();
        self.load_chat_tab_without_window(self.chat_tabs[self.chat_tab].clone(), cx);
    }

    /// A chat selection changes the focused tab, never the workspace identity.
    /// Deleted project associations become projectless without deleting sessions.
    pub(in crate::shell) fn reconcile_project_tabs(&mut self, cx: &mut Context<Self>) {
        if !self.boot_restored || !self.state.read(cx).spaces_synced {
            return;
        }
        self.ensure_workspace_sessions(cx);
        // A missing project may be offline or not yet in this profile's snapshot.
        // Keep its saved association until the user deliberately changes it.
        self.persist_chat_tabs(cx);
    }

    /// Restore every saved workspace independently, preserving unresolved references.
    pub(in crate::shell) fn restore_project_tabs(&mut self, cx: &mut Context<Self>) -> bool {
        if self.settings.project_tabs_version >= 1 && self.settings.chat_tabs.is_empty() {
            self.chat_tabs.clear();
            self.chat_tab = 0;
            self.load_chat_tab_without_window(ChatTab::default(), cx);
            self.ensure_workspace_sessions(cx);
            self.persist_chat_tabs(cx);
            return true;
        }
        let state = self.state.read(cx);
        let active = self.settings.chat_tab;
        let mut tabs: Vec<ChatTab> = Vec::new();
        let mut active_id = None;
        let mut layouts = Vec::new();
        for (ix, saved) in self.settings.chat_tabs.iter().enumerate() {
            let project = saved.project.clone().or_else(|| saved.selected.as_deref()
                .and_then(|id| state.chats.iter().find(|chat| chat.id == id))
                .and_then(|chat| chat.space_id.clone()));
            // Slots remain stable across partial sync and archived rows.
            let live = |_id: &str| true;
            // A current panel layout owns placement. Retained legacy peers
            // must not be imported again after the user moved or closed them.
            let mut split = if saved.panel_layout.is_some() {
                None
            } else {
                saved
                    .layout
                    .as_ref()
                    .and_then(|layout| chat_split::ChatSplit::from_saved(layout, live))
            };
            if let Some(split) = split.as_mut() {
                split.projects.fill(project.clone());
            }
            let tab = ChatTab {
                id: if saved.id.is_empty() {
                    uuid::Uuid::new_v4().to_string()
                } else {
                    saved.id.clone()
                },
                title: saved.title.clone(),
                session_icon: saved.session_icon.clone(),
                pinned: saved.pinned,
                selected: saved.selected.clone().filter(|id| live(id)),
                project: project.clone(),
                split,
                draft: None,
            };
            if ix == active {
                active_id = Some(tab.id.clone());
            }
            // Each saved workspace is its own view, even for the same project.
            // A missing/duplicated legacy identifier receives a fresh stable identity.
            let mut tab = tab;
            if tabs.iter().any(|existing| existing.id == tab.id) {
                tab.id = uuid::Uuid::new_v4().to_string();
                if ix == active { active_id = Some(tab.id.clone()); }
            }
            let panel_layout = saved.panel_layout.clone().or_else(|| {
                tab.split.as_ref().map(|split| {
                    workspace_session_persistence::legacy_workspace_panels(
                        split,
                        tab.selected.as_deref(),
                    )
                })
            });
            if let Some(layout) = panel_layout {
                layouts.push((tab.id.clone(), layout));
            }
            tabs.push(tab);
        }
        if tabs.is_empty() {
            return false;
        }
        self.chat_tab = tabs
            .iter()
            .position(|tab| Some(&tab.id) == active_id.as_ref())
            .unwrap_or(0);
        self.chat_tabs = tabs;
        for (id, layout) in layouts {
            self.restore_workspace_panels(&id, &layout, cx);
        }
        self.load_chat_tab_without_window(self.chat_tabs[self.chat_tab].clone(), cx);
        self.state.update(cx, |state, _| state.auto_selected = true);
        true
    }

    pub(in crate::shell) fn render_project_picker(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let trigger = window_control_button(
            "top-new-tab",
            icons::PLUS,
            theme,
            cx.listener(|this, _, window, cx| {
                if this.spaces_menu.is_open() {
                    this.close_spaces_menu(cx);
                } else {
                    this.open_spaces_menu(window, cx);
                }
            }),
        )
        .role(gpui::Role::Button)
        .aria_label("Open project");
        div()
            .relative()
            .child(trigger)
            .when(self.spaces_menu.get().is_some(), |el| {
                let closing = self.spaces_menu.closing_since();
                el.child(popover::anchored_menu_below_end(
                    "project-tab-picker",
                    self.render_spaces_menu(theme, cx),
                    closing,
                ))
            })
            .into_any_element()
    }
}
