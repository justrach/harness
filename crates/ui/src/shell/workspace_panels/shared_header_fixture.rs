//! Synthetic states for the single-panel shared window header.
use super::*;

impl Shell {
    pub fn fixture_shared_header_case(
        &mut self,
        kind: &str,
        collapsed: bool,
        long_session: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.route = Route::Chat;
        self.ensure_workspace_sessions(cx);
        self.chat_tabs.truncate(1);
        self.chat_tab = 0;
        self.chat_tabs[0].id = "fixture-shared-header-session".into();
        self.chat_tabs[0].title = Some(
            if long_session {
                "Review the release plan and cross-platform navigation details"
            } else {
                "New session"
            }
            .into(),
        );
        self.chat_tabs[0].session_icon = None;
        self.settings.sidebar_collapsed = collapsed;
        self.settings.sidebar_width = SIDEBAR_DEFAULT;
        self.sidebar_tween = None;
        self.session_sidebar.close_menu();
        self.session_quick_switcher.close();
        self.session_overview = false;
        self.workspace_panels = Default::default();
        self.state.update(cx, |state, cx| {
            state.select_chat((kind != "empty").then(|| "launch-0".into()), cx)
        });
        self.sync_panel_workspace(cx);
        self.workspace_panels.seq = 200;
        let layout = self.panel_layout_mut(cx);
        layout.panels.truncate(1);
        let first = layout.panels[0].id;
        layout.panels[0].tabs = match kind {
            "empty" => vec![],
            "many-tabs" => vec![
                PanelTab::Chat("launch-0".into()),
                PanelTab::Chat("launch-1".into()),
                PanelTab::Chat("launch-2".into()),
                PanelTab::New(100),
                PanelTab::New(101),
                PanelTab::New(102),
            ],
            _ => vec![PanelTab::Chat("launch-0".into())],
        };
        layout.panels[0].active = 0;
        layout.focused = first;
        layout.expanded = None;
        if matches!(kind, "split" | "expanded-split" | "split-empty") {
            let second = layout.add_panel(first);
            let panel = layout.panel_mut(second).unwrap();
            panel.tabs = if kind == "split-empty" {
                vec![]
            } else {
                vec![PanelTab::Chat("launch-1".into())]
            };
            panel.active = 0;
            layout.axis = SplitAxis::Horizontal;
            layout.focused = first;
            if kind == "expanded-split" {
                layout.expanded = Some(first);
            }
        }
        self.persist_chat_tabs(cx);
        window.blur();
        cx.notify();
    }

    pub fn fixture_shared_header_state(&self, cx: &App) -> serde_json::Value {
        let layout = self.panel_layout(cx);
        serde_json::json!({
            "sidebarCollapsed": self.settings.sidebar_collapsed,
            "sessionTitle": self.chat_tabs.get(self.chat_tab).and_then(|tab| tab.title.as_ref()),
            "panels": layout.map(|layout| layout.panels.len()),
            "tabs": layout.map(|layout| layout.panels.iter().map(|panel| panel.tabs.len()).sum::<usize>()),
            "expanded": layout.and_then(|layout| layout.expanded),
            "sharedHeader": self.workspace_uses_shared_header(cx),
            "sessionMenuOpen": self.session_quick_switcher.is_open(),
            "placementOpen": self.workspace_panels.menu.is_some(),
            "draft": self.composer.read(cx).input.read(cx).text().to_string()
        })
    }
}
