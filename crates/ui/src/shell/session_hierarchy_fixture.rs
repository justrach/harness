//! Synthetic session → panel → tab review states. No agent runs or navigation.
use super::workspace_panels::PanelTab;
use super::*;
use gpui::point;

impl Shell {
    pub fn fixture_session_hierarchy(
        &mut self,
        phase: u8,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if phase == 0 {
            self.settings.sidebar_collapsed = false;
            self.settings.sidebar_width = SIDEBAR_DEFAULT;
            self.sidebar_tween = None;
            self.session_sidebar.close_menu();
            self.session_quick_switcher.close();
            self.ensure_workspace_sessions(cx);
            self.chat_tabs.truncate(1);
            self.chat_tab = 0;
            self.chat_tabs[0].id = "fixture-design-session".into();
            self.chat_tabs[0].title = Some("Design review".into());
            self.chat_tabs[0].session_icon = Some("star".into());
            self.chat_tabs[0].pinned = true;
            self.chat_tabs[0].project = Some("launch".into());
            self.workspace_panels = Default::default();
            self.state.update(cx, |state, _| {
                for (ix, (id, harness, model, branch)) in [
                    (
                        "launch-0",
                        harness_proto::HarnessId::Graff,
                        "claude-sonnet-4-6",
                        "design/sidebar",
                    ),
                    (
                        "launch-1",
                        harness_proto::HarnessId::Codex,
                        "gpt-6-sol",
                        "design/tab-chrome",
                    ),
                    (
                        "launch-2",
                        harness_proto::HarnessId::Cursor,
                        "composer-2",
                        "release/preview",
                    ),
                ]
                .into_iter()
                .enumerate()
                {
                    if let Some(chat) = state.chats.iter_mut().find(|chat| chat.id == id) {
                        chat.cwd = Some("/fixtures/launch".into());
                        chat.source_context = Some(harness_proto::ConversationSourceContext {
                            checkout_id: "fixture-launch".into(),
                            repo_root: "/fixtures/launch".into(),
                            cwd: "/fixtures/launch".into(),
                            branch: branch.into(),
                            head_sha: None,
                            observed_at: Utc::now(),
                        });
                        chat.source_context_unavailable_at = None;
                        if let Some(config) = chat.config.as_mut() {
                            config.harness = harness;
                            config.model = Some(model.into());
                        }
                        chat.last_message_at =
                            Some(Utc::now() - chrono::Duration::minutes((ix as i64 + 1) * 3));
                        chat.last_seen_at = chat.last_message_at;
                    }
                }
            });
            self.sync_panel_workspace(cx);
            self.workspace_split(SplitAxis::Vertical, cx);
            let lower = self.panel_layout(cx).unwrap().focused;
            let draft = self
                .panel_layout(cx)
                .unwrap()
                .panels
                .iter()
                .find(|panel| panel.id == lower)
                .unwrap()
                .selected()
                .unwrap()
                .clone();
            self.add_browser_surface(None, window, cx);
            let browser = self.browser_seq;
            let owner = self.panel_key(cx);
            let layout = self.panel_layout_mut(cx);
            layout.axis = SplitAxis::Vertical;
            layout.panels[0].tabs = ["launch-0", "launch-1", "launch-2"]
                .into_iter()
                .map(|id| PanelTab::Chat(id.into()))
                .collect();
            layout.panels[0].active = 0;
            let panel = layout
                .panels
                .iter_mut()
                .find(|panel| panel.id == lower)
                .unwrap();
            panel.tabs = vec![
                draft,
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Browser(browser),
                },
                PanelTab::Files(owner),
            ];
            panel.active = 0;
            self.focus_workspace_tab(0, PanelTab::Chat("launch-0".into()), window, cx);
            self.persist_chat_tabs(cx);

            self.create_workspace_session(cx);
            let implementation = self.chat_tabs[self.chat_tab].id.clone();
            self.rename_workspace_session(&implementation, "Implementation".into(), cx);
            self.set_workspace_session_icon(&implementation, Some("code"), cx);
            self.workspace_split(SplitAxis::Horizontal, cx);
            self.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Explore the implementation without changing the design session"
                            .into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            self.park_workspace_draft(cx);
            self.persist_chat_tabs(cx);
            self.activate_workspace_session("fixture-design-session", cx);
            self.settings.reset_sidebar_display();
            self.settings.sidebar_compact = true;
            window.blur();
        } else if phase == 1 {
            self.fixture_session_hierarchy_hover(true, window, cx);
        } else if phase == 2 {
            self.workspace_new_tab(cx);
            self.focus_workspace_new_tab(window, cx);
        } else if phase == 3 {
            let id = self
                .chat_tabs
                .iter()
                .find(|tab| tab.title.as_deref() == Some("Implementation"))
                .unwrap()
                .id
                .clone();
            self.activate_workspace_session(&id, cx);
            self.settings.sidebar_compact = true;
            window.blur();
        } else if phase == 4 {
            self.settings.sidebar_collapsed = false;
            self.sidebar_tween = None;
            self.session_sidebar.close_menu();
            self.session_quick_switcher.close();
            self.dismiss_workspace_panel_overlay(window, cx);
            self.activate_workspace_session("fixture-design-session", cx);
            self.settings.sidebar_compact = true;
            window.blur();
        } else if phase == 5 {
            self.dismiss_workspace_panel_overlay(window, cx);
            self.rename_workspace_session("fixture-design-session", "Design and polish".into(), cx);
            window.blur();
        } else if phase == 6 {
            self.settings.sidebar_collapsed = true;
            self.sidebar_tween = None;
            self.focus_workspace_tab(0, PanelTab::Chat("launch-0".into()), window, cx);
            window.blur();
            self.fixture_session_hierarchy_hover(false, window, cx);
        } else if matches!(phase, 7..=9) {
            self.fixture_session_hierarchy(4, window, cx);
            let row = self
                .workspace_session_sidebar_rows(cx)
                .into_iter()
                .find(|row| row.title == "Implementation")
                .unwrap();
            // The second row is deliberately inactive: its hover wash must
            // stay distinct from the pinned, selected Design review row.
            let position = point(px(100.0), px(140.0));
            if phase == 7 {
                window.defer(cx, move |window, cx| {
                    window.dispatch_event(
                        gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                            position,
                            pressed_button: None,
                            modifiers: Default::default(),
                        }),
                        cx,
                    );
                });
            } else {
                self.open_workspace_session_menu(row.id, phase == 9, position, window, cx);
            }
        } else if phase == 10 {
            self.fixture_session_hierarchy(6, window, cx);
            self.open_workspace_session_quick_switcher(window, cx);
        }
        cx.notify();
    }

    pub fn fixture_session_hierarchy_hover(
        &mut self,
        hover: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = self.workspace_layout_key(cx);
        let tab = self
            .workspace_panels
            .active_tab_bounds
            .borrow()
            .get(&(key, 0))
            .copied();
        let position = if hover {
            tab.map(|bounds| bounds.center())
                .unwrap_or(point(px(390.0), px(21.0)))
        } else {
            point(px(120.0), px(400.0))
        };
        // Dispatch after the fixture's Shell update releases its entity lease.
        // Native event listeners update that same Shell.
        window.defer(cx, move |window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position,
                    pressed_button: None,
                    modifiers: Default::default(),
                }),
                cx,
            );
        });
    }
}
