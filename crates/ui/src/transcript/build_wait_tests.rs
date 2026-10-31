use super::*;

#[gpui::test]
fn build_wait_replaces_thinking_and_clears_on_resume(cx: &mut gpui::TestAppContext) {
    struct Host(Entity<Transcript>);
    impl Render for Host {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(self.0.clone())
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    let now = chrono::Utc::now();
    state.update(cx, |state, cx| {
        state.select_chat(Some("fixture".into()), cx);
        state.sessions.push(harness_proto::Session {
            chat_id: "fixture".into(), device_id: "synthetic".into(),
            status: harness_proto::SessionStatus::Working,
            started_at: Some(now - chrono::Duration::minutes(5)), updated_at: now,
            last_completed_turn: None, last_completed_peer_only: false,
        });
        state.receive_transcript_frame(harness_doc::TranscriptFrame::Reset {
            reset: serde_json::from_value(serde_json::json!([{
                "id": "reply", "role": "assistant", "createdAt": 1, "deviceId": "synthetic",
                "status": "streaming", "parts": [{"id": "text", "kind": "text", "text": "Checking the sample."}]
            }])).unwrap(),
        }, cx);
    });
    let (_, cx) = cx.add_window_view(|_, cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx))));
    cx.simulate_resize(size(px(700.), px(600.)));
    for waiting in [false, true, false] {
        state.update(cx, |state, cx| {
            state.tool_progress = if waiting {
                vec![harness_proto::ToolProgressItem {
                    tool_id: "harness:build-wait".into(),
                    output: (now.timestamp() - 240).to_string(),
                    state: Some("waiting".into()),
                }]
            } else {
                vec![]
            };
            cx.notify();
        });
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
        assert_eq!(
            cx.debug_bounds("build-wait-status").is_some(),
            waiting,
            "a confirmed wait must replace thinking, then clear on acquisition"
        );
        assert_eq!(cx.debug_bounds("build-wait-dot").is_some(), waiting);
        assert_eq!(cx.debug_bounds("thinking-status").is_some(), !waiting);
    }
}

#[gpui::test]
fn build_wait_is_scoped_to_live_chat_panes_not_parent_or_frozen_docs(
    cx: &mut gpui::TestAppContext,
) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        let state = cx.new(|_| AppState::new());
        let primary = cx.new(|cx| Transcript::new(state.clone(), cx));
        let peer = cx.new(|cx| Transcript::for_doc(state.clone(), "peer".into(), true, cx));
        let child = cx.new(|cx| Transcript::for_doc(state.clone(), "child".into(), true, cx));
        let frozen = cx.new(|cx| Transcript::for_doc(state.clone(), "peer".into(), false, cx));
        let now = chrono::Utc::now();
        state.update(cx, |state, cx| {
            state.selected_chat = Some("primary".into());
            state.watch_peer_chat("peer".into(), cx);
            state.watch_subagent_doc("child".into(), cx);
            for chat_id in ["primary", "peer"] {
                state.sessions.push(harness_proto::Session {
                    chat_id: chat_id.into(),
                    device_id: "synthetic".into(),
                    status: harness_proto::SessionStatus::Working,
                    started_at: Some(now - chrono::Duration::minutes(5)),
                    updated_at: now,
                    last_completed_turn: None,
                    last_completed_peer_only: false,
                });
            }
            state.receive_tool_progress(
                "primary",
                vec![harness_proto::build_wait_item(now.timestamp() - 240)],
            );
        });
        primary.update(cx, |this, _| this.chat_id = Some("primary".into()));
        let wait = |view: &Entity<Transcript>, cx: &mut gpui::App| {
            view.update(cx, |this, cx| this.confirmed_build_wait_since(cx))
        };
        assert_eq!(wait(&primary, cx), Some(now.timestamp() - 240));
        assert_eq!(
            wait(&peer, cx),
            None,
            "the parent's wait leaked to another split"
        );
        assert_eq!(
            wait(&child, cx),
            None,
            "the parent's wait leaked to a subagent"
        );
        assert_eq!(wait(&frozen, cx), None);
        state.update(cx, |state, _| {
            state.receive_tool_progress("primary", vec![]);
            state.receive_tool_progress(
                "peer",
                vec![harness_proto::build_wait_item(now.timestamp() - 60)],
            );
        });
        assert_eq!(wait(&primary, cx), None);
        assert_eq!(wait(&peer, cx), Some(now.timestamp() - 60));
        assert_eq!(wait(&child, cx), None);
        assert_eq!(wait(&frozen, cx), None);
        // Promotion clears the old primary feed instead of reusing its wait.
        state.update(cx, |state, cx| state.select_chat(Some("other".into()), cx));
        assert_eq!(wait(&primary, cx), None);
        assert_eq!(wait(&peer, cx), Some(now.timestamp() - 60));
        state.update(cx, |state, _| {
            // A completed/cancelled turn must stop showing its wait even before
            // the progress stream's clearing frame arrives.
            state
                .sessions
                .iter_mut()
                .find(|s| s.chat_id == "peer")
                .unwrap()
                .status = harness_proto::SessionStatus::Idle;
        });
        assert_eq!(wait(&peer, cx), None);
        state.update(cx, |state, _| {
            let session = state
                .sessions
                .iter_mut()
                .find(|s| s.chat_id == "peer")
                .unwrap();
            session.status = harness_proto::SessionStatus::Working;
            session.started_at = Some(now);
        });
        assert_eq!(wait(&peer, cx), None, "a stale wait leaked into a new turn");
    });
}
