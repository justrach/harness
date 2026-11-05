//! Synthetic stacked-panel insertion targets, excluded from production builds.
use super::*;

impl Shell {
    pub fn fixture_tab_insertion_case(
        &mut self,
        empty_target: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.fixture_shared_header_case("split", true, false, window, cx);
        let layout = self.panel_layout_mut(cx);
        layout.axis = SplitAxis::Vertical;
        layout.expanded = None;
        layout.panels[0].tabs = vec![
            PanelTab::Chat("launch-0".into()),
            PanelTab::Chat("launch-2".into()),
        ];
        layout.panels[0].active = 0;
        layout.panels[1].tabs = if empty_target {
            vec![]
        } else {
            vec![PanelTab::New(100), PanelTab::New(101), PanelTab::New(102)]
        };
        layout.panels[1].active = 0;
        layout.focused = layout.panels[0].id;
        self.persist_chat_tabs(cx);
        cx.notify();
    }

    pub fn fixture_tab_insertion_state(&self, cx: &App) -> serde_json::Value {
        let names = |panel: &WorkspacePanel| {
            panel
                .tabs
                .iter()
                .map(|tab| match tab {
                    PanelTab::Chat(chat) => chat.clone(),
                    PanelTab::New(id) => format!("new-{id}"),
                    other => format!("{other:?}"),
                })
                .collect::<Vec<_>>()
        };
        let layout = self.panel_layout(cx);
        serde_json::json!({
            "upper": layout.and_then(|layout| layout.panels.first()).map(names),
            "lower": layout.and_then(|layout| layout.panels.get(1)).map(names),
            "panels": layout.map(|layout| layout.panels.len()),
            "hover": self.workspace_panels.window_drop_hover.as_ref().map(|hover| serde_json::json!({
                "panel": hover.panel, "before": hover.before, "header": hover.header
            })),
            "drag": cx.has_active_drag(),
            "windowDrag": self.workspace_panels.window_drag.is_some(),
            "draft": self.composer.read(cx).parked_chat_input("launch-0", cx).text
        })
    }
}
