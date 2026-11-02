//! Synthetic native window-transfer hooks, excluded from production builds.
use super::workspace_panels::PanelTab;
use super::*;

impl Shell {
    pub fn fixture_open_workspace_window(
        state: Entity<AppState>,
        boot: EngineBootConfig,
        record: crate::settings::SavedWorkspaceWindow,
        cx: &mut App,
    ) -> Result<gpui::WindowHandle<Self>, String> {
        crate::open_workspace_window(state, boot, record, cx)
    }

    pub fn fixture_fork_window_state(source: &Entity<AppState>, cx: &mut App) -> Entity<AppState> {
        cx.new(|cx| AppState::for_window(source, cx))
    }

    pub fn fixture_transfer_save_record(
        &mut self,
        cx: &mut Context<Self>,
    ) -> crate::settings::SavedWorkspaceWindow {
        self.save_window_record(cx);
        settings::current(cx)
            .workspace_windows
            .into_iter()
            .flatten()
            .find(|record| record.id == self.window_id)
            .unwrap_or_else(|| {
                crate::settings::SavedWorkspaceWindow::from_settings(
                    self.window_id.clone(),
                    &self.settings,
                )
            })
    }

    pub fn fixture_tear_off_prepare(
        &mut self,
        url: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (u64, usize, Entity<crate::browser::BrowserSurface>) {
        self.ensure_workspace_sessions(cx);
        self.sync_panel_workspace(cx);
        self.settings.sidebar_collapsed =
            std::env::var_os("HARNESS_FIXTURE_SIDEBAR_EXPANDED").is_none();
        self.add_browser_surface(Some(url), window, cx);
        let browser_id = self.browser_seq;
        let browser = self.browsers[&browser_id].clone();
        let owner = self.panel_key(cx);
        let panel = self.panel_layout(cx).unwrap().panels[0].id;
        let tab = PanelTab::Surface {
            owner,
            surface: RightSurface::Browser(browser_id),
        };
        let layout = self.panel_layout_mut(cx);
        layout.panels.truncate(1);
        layout.panels[0].tabs = vec![
            PanelTab::Chat("fixture-a".into()),
            PanelTab::Chat("fixture-b".into()),
            tab.clone(),
        ];
        layout.panels[0].active = 2;
        layout.focused = panel;
        self.focus_workspace_tab(panel, tab, window, cx);
        self.composer.update(cx, |composer, cx| {
            composer.current_key = "fixture-a".into();
            composer.input.update(cx, |input, cx| {
                input.set_text("Keep this unsent transfer draft", cx)
            });
            composer.attachments.insert(
                "fixture-a".into(),
                vec![crate::attachments::StagedAttachment {
                    #[cfg(target_os = "macos")]
                    editable: None,
                    #[cfg(target_os = "macos")]
                    unavailable_editable: None,
                    unavailable: None,
                    annotations: None,
                    id: "fixture-attachment".into(),
                    name: "transfer-notes.txt".into(),
                    image: None,
                    file: Some(std::sync::Arc::from(&b"synthetic transfer attachment"[..])),
                }],
            );
        });
        self.persist_chat_tabs(cx);
        (panel, 2, browser)
    }

    pub fn fixture_detach_panel_tab(
        &mut self,
        panel: u64,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<gpui::WindowHandle<Self>, String> {
        let tab = self
            .panel_layout(cx)
            .and_then(|layout| layout.panels.iter().find(|candidate| candidate.id == panel))
            .and_then(|panel| panel.tabs.get(index))
            .cloned()
            .ok_or("The fixture tab no longer exists.")?;
        self.move_workspace_tab_to_new_window(panel, tab, None, window, cx)
    }

    pub fn fixture_browser_entity(&self) -> Option<Entity<crate::browser::BrowserSurface>> {
        self.browsers.values().next().cloned()
    }

    pub fn fixture_rejoin_browser_only(&mut self, cx: &mut Context<Self>) -> u64 {
        let layout = self.panel_layout_mut(cx);
        layout.panels.truncate(1);
        let panel = &mut layout.panels[0];
        panel.tabs.retain(|tab| {
            matches!(
                tab,
                PanelTab::Surface {
                    surface: RightSurface::Browser(_),
                    ..
                }
            )
        });
        panel.active = 0;
        let id = panel.id;
        layout.focused = id;
        self.persist_chat_tabs(cx);
        cx.notify();
        id
    }

    pub fn fixture_rejoin_populate(
        &mut self,
        draft: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> u64 {
        let panel = self.panel_layout(cx).unwrap().panels[0].id;
        let chat = PanelTab::Chat("fixture-a".into());
        self.focus_workspace_tab(panel, chat.clone(), window, cx);
        let layout = self.panel_layout_mut(cx);
        layout.panels.truncate(1);
        layout.panels[0].tabs = vec![chat];
        layout.panels[0].active = 0;
        layout.focused = panel;
        self.composer.update(cx, |composer, cx| {
            composer.current_key = "fixture-a".into();
            composer
                .input
                .update(cx, |input, cx| input.set_text(draft, cx));
            composer.attachments.insert(
                "fixture-a".into(),
                vec![crate::attachments::StagedAttachment {
                    #[cfg(target_os = "macos")]
                    editable: None,
                    #[cfg(target_os = "macos")]
                    unavailable_editable: None,
                    unavailable: None,
                    annotations: None,
                    id: "fixture-rejoin-attachment".into(),
                    name: "destination-review.txt".into(),
                    image: None,
                    file: Some(std::sync::Arc::from(&b"Destination attachment bytes"[..])),
                }],
            );
        });
        self.persist_chat_tabs(cx);
        cx.notify();
        panel
    }

    pub fn fixture_rejoin_panel_bounds(&self, cx: &App) -> Option<gpui::Bounds<Pixels>> {
        let panel = self.panel_layout(cx)?.focused;
        self.workspace_panels
            .panel_bounds
            .borrow()
            .get(&(self.workspace_layout_key(cx), panel))
            .copied()
    }

    pub fn fixture_rejoin_active_tab_bounds(&self, cx: &App) -> Option<gpui::Bounds<Pixels>> {
        self.fixture_active_drag_tab_bounds(self.panel_layout(cx)?.focused, cx)
    }

    pub fn fixture_transfer_select_chat(
        &mut self,
        chat: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let panel = self.panel_layout(cx).unwrap().panels[0].id;
        self.focus_workspace_tab(panel, PanelTab::Chat(chat.into()), window, cx);
    }

    pub fn fixture_transfer_status(&self, cx: &App) -> serde_json::Value {
        let composer = self.composer.read(cx);
        let selected_tab = self
            .panel_layout(cx)
            .and_then(|layout| {
                layout
                    .panels
                    .iter()
                    .find(|panel| panel.id == layout.focused)
            })
            .and_then(|panel| panel.selected());
        let selected_kind = selected_tab.map(|tab| match tab {
            PanelTab::Chat(_) => "chat",
            PanelTab::Surface {
                surface: RightSurface::Browser(_),
                ..
            } => "browser",
            PanelTab::New(_) => "new",
            PanelTab::Draft(_) => "draft",
            _ => "tool",
        });
        serde_json::json!({
            "windowId": self.window_id,
            "sessionId": self.chat_tabs.get(self.chat_tab).map(|tab| &tab.id),
            "selectedTabKind": selected_kind,
            "selectedChat": self.state.read(cx).selected_chat,
            "draft": composer.parked_chat_input("fixture-a", cx).text,
            "attachmentBytes": composer.attachments.get("fixture-a").and_then(|items| items.first()).map(|item| item.bytes().len()).unwrap_or(0),
            "browsers": self.browsers.len(),
            "tabs": self.panel_layout(cx).map(|layout| layout.panels.iter().map(|panel| panel.tabs.len()).sum::<usize>()).unwrap_or(0)
        })
    }
}
