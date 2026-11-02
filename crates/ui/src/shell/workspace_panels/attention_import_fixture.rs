//! Synthetic, native captures of the approved attention and import controls.
use super::*;

impl Shell {
    pub fn fixture_attention_selected(&self, cx: &App) -> bool {
        self.state.read(cx).selected_chat.as_deref() == Some("launch-1")
            && self
                .panel_layout(cx)
                .and_then(|layout| layout.panel(0))
                .and_then(WorkspacePanel::selected)
                == Some(&PanelTab::Chat("launch-1".into()))
    }

    pub fn fixture_attention_import(
        &mut self,
        variant: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings.sidebar_collapsed = false;
        self.close_cloud_computer(window, cx);
        self.state
            .update(cx, |state, cx| state.apply_cloud_sandboxes(None, cx));
        self.fixture_reconciliation_design("approved-base", window, cx);
        let now = Utc::now();
        let error = variant == "attention-error";
        self.state.update(cx, |state, cx| {
            state.sessions.clear();
            if variant.starts_with("attention-") {
                let device = state
                    .chats
                    .iter()
                    .find(|chat| chat.id == "launch-1")
                    .map(|chat| chat.device_id.clone())
                    .unwrap_or_else(|| "fixture".into());
                state.sessions.push(harness_proto::Session {
                    chat_id: "launch-1".into(),
                    device_id: device,
                    status: if error {
                        harness_proto::SessionStatus::Errored
                    } else {
                        harness_proto::SessionStatus::AwaitingInput
                    },
                    started_at: Some(now),
                    updated_at: now,
                    last_completed_turn: None,
                    last_completed_peer_only: false,
                });
            }
            cx.notify();
        });
        if variant == "attention-overflow" {
            let layout = self.panel_layout_mut(cx);
            // Existing synthetic conversations plus empty tabs keep the request
            // genuinely outside the available strip without creating real work.
            layout.panels[0].tabs = vec![PanelTab::Chat("launch-0".into())];
            for id in 800..807 {
                layout.panels[0].tabs.push(PanelTab::New(id));
            }
            layout.panels[0]
                .tabs
                .push(PanelTab::Chat("launch-1".into()));
            layout.panels[0].active = 0;
            self.workspace_panels.scrolls.clear();
            self.workspace_panels.revealed_tabs.clear();
        } else if variant == "newtab" {
            self.workspace_new_tab(cx);
            self.focus_workspace_new_tab(window, cx);
            let layout = self.panel_layout_mut(cx);
            let tab = layout.panels[0].selected().unwrap().clone();
            layout.panels[0].tabs = vec![tab];
            layout.panels[0].active = 0;
        }
        window.blur();
        cx.notify();
    }
}
