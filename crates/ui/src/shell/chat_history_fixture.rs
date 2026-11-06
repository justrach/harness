//! Synthetic history and close/reopen states, excluded from production builds.
use super::workspace_panels::PanelTab;
use super::*;

impl Shell {
    /// This fixture intentionally omits live engine watches to keep its sample
    /// timestamps and transcript states stable. Verify mutation against the
    /// real engine before reconciling the fixture's chat projection.
    pub fn fixture_chat_history_confirm_deletion(
        &mut self,
        deleted: String,
        cx: &mut Context<Self>,
    ) -> gpui::Task<Result<Vec<String>, String>> {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return gpui::Task::ready(Err("synthetic engine is not attached".into()));
        };
        cx.spawn(async move |this, cx| {
            let mut watch = engine
                .client()
                .subscribe_scoped(harness_rpc::methods::WATCH_CHATS, serde_json::json!({}))
                .await
                .map_err(|error| error.to_string())?;
            let frame = watch
                .recv()
                .await
                .ok_or("temporary engine closed its chat snapshot stream")?;
            let chats: Vec<harness_proto::Chat> =
                serde_json::from_value(frame).map_err(|error| error.to_string())?;
            let ids: Vec<_> = chats.into_iter().map(|chat| chat.id).collect();
            if ids.contains(&deleted) {
                return Err(format!(
                    "temporary engine still contains deleted chat {deleted}: {ids:?}"
                ));
            }
            this.update(cx, |shell, cx| {
                shell.state.update(cx, |state, cx| {
                    state.chats.retain(|chat| ids.contains(&chat.id));
                    cx.notify();
                });
                cx.notify();
            })
            .map_err(|error| error.to_string())?;
            Ok(ids)
        })
    }

    pub fn fixture_chat_history_close(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.workspace_close_focused(window, cx)
    }

    pub fn fixture_chat_history_unsent(&mut self, cx: &mut Context<Self>) {
        let record = settings::SavedClosedChat {
            id: "fixture-unsent-history".into(),
            window_id: self.window_id.clone(),
            session_id: self.workspace_layout_key(cx),
            panel_id: self.panel_layout(cx).map_or(0, |layout| layout.focused),
            closed_at: self.next_chat_close_time(cx),
            draft: settings::SavedWindowChatDraft {
                input: settings::SavedCanvasDraft {
                    text: "Unsent notes for the synthetic release review".into(),
                    ..Default::default()
                },
                ..Default::default()
            },
            ..Default::default()
        };
        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
            settings.remember_closed_chat(record)
        });
        cx.notify();
    }

    pub fn fixture_chat_history_case(
        &mut self,
        kind: &str,
        collapsed: bool,
        long_session: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_command_palette(window, cx);
        self.boot_restored = true;
        self.fixture_shared_header_case(kind, collapsed, long_session, window, cx);
        self.chat_tabs[0].title = Some(
            if long_session {
                "Review the release plan and cross-platform navigation details"
            } else {
                "Design review"
            }
            .into(),
        );
        self.chat_tabs[0].project = Some("launch".into());
        self.set_space_filter(Some("launch".into()), cx);
        self.persist_chat_tabs(cx);
        if std::env::var("HARNESS_HISTORY_ACTIONS_ONLY").as_deref() != Ok("1") {
            cx.activate(true);
            window.activate_window();
        }
        cx.notify();
    }

    pub fn fixture_chat_history_draft(
        &mut self,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.composer.update(cx, |composer, cx| {
            composer.fixture_set_draft(text, cx);
            composer.focus_pending = false;
        });
        if std::env::var("HARNESS_HISTORY_ACTIONS_ONLY").as_deref() != Ok("1") {
            cx.activate(true);
            window.activate_window();
        }
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }

    pub fn fixture_chat_history_state(&self, cx: &App) -> serde_json::Value {
        let state = self.state.read(cx);
        let layout = self.panel_layout(cx);
        let saved = settings::UiSettings::load(&self.data_dir);
        let composer = self.composer.read(cx);
        serde_json::json!({
            "selectedChat": state.selected_chat,
            "sessionId": self.chat_tabs.get(self.chat_tab).map(|tab| &tab.id),
            "panelIds": layout.map(|layout| layout.panels.iter().map(|panel| panel.id).collect::<Vec<_>>()),
            "tabs": layout.map(|layout| layout.panels.iter().map(|panel| panel.tabs.iter().filter_map(|tab| match tab {
                PanelTab::Chat(id) => Some(id.clone()),
                _ => None,
            }).collect::<Vec<_>>()).collect::<Vec<_>>()),
            "focusedPanel": layout.map(|layout| layout.focused),
            "draft": composer.parked_chat_input(state.selected_chat.as_deref().unwrap_or_default(), cx).text,
            "currentKey": composer.current_key,
            "liveDraft": composer.input.read(cx).text().to_string(),
            "launchArchived": state.chats.iter().find(|chat| chat.id == "launch-0").map(|chat| chat.archived),
            "sidebarCollapsed": self.settings.sidebar_collapsed,
            "sharedHeader": self.workspace_uses_shared_header(cx),
            "closedRecord": settings::recently_closed_chats(cx).into_iter().find(|record| record.chat_id.as_deref() == Some("launch-0")),
            "savedClosedRecord": saved.recently_closed_chats.iter().find(|record| record.chat_id.as_deref() == Some("launch-0")),
            "unsentRecord": settings::recently_closed_chats(cx).into_iter().find(|record| record.id == "fixture-unsent-history"),
            "savedUnsentRecord": saved.recently_closed_chats.iter().find(|record| record.id == "fixture-unsent-history"),
            "allChats": state.chats.iter().map(|chat| chat.id.clone()).collect::<Vec<_>>(),
            "palette": self.fixture_chat_history_palette_state(cx),
        })
    }
}
