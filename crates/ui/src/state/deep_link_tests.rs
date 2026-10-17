use super::*;
use gpui::AppContext;

#[gpui::test]
fn deferred_deep_links_hand_off_navigation_without_replacing_selection(cx: &mut gpui::TestAppContext) {
    let state = cx.new(|_| AppState::new());
    state.update(cx, |state, cx| {
        state.selected_chat = Some("current".into());
        let workspace = crate::links::workspace_locator(
            Some(WorkspaceScope::Local), None, Some("local"),
        ).unwrap();
        let url = crate::links::harness_conversation_link("target", &workspace);
        state.open_deep_link(&url, cx);
        assert!(state.take_linked_chat().is_none(), "wait for workspace identity");
        state.workspace_scope = Some(WorkspaceScope::Local);
        state.local_device_id = Some("local".into());
        state.apply_pending_deep_link(cx);
        assert!(state.take_linked_chat().is_none(), "wait for the target chat to sync");
        state.chats.push(serde_json::from_value(serde_json::json!({
            "id": "target", "deviceId": "local", "archived": false,
            "createdAt": Utc::now(),
        })).unwrap());
        state.chats_synced = true;
        state.apply_pending_deep_link(cx);
        assert_eq!(state.selected_chat.as_deref(), Some("current"));
        assert_eq!(state.take_linked_chat().as_deref(), Some("target"));
        assert!(state.take_linked_chat().is_none(), "consume once");
        assert!(state.pending_deep_link.is_none());
    });
}

#[gpui::test]
fn missing_deep_link_targets_do_not_queue_navigation(cx: &mut gpui::TestAppContext) {
    let state = cx.new(|_| AppState::new());
    state.update(cx, |state, cx| {
        state.selected_chat = Some("current".into());
        state.workspace_scope = Some(WorkspaceScope::Local);
        state.local_device_id = Some("local".into());
        state.chats_synced = true;
        let workspace = crate::links::workspace_locator(
            state.workspace_scope, None, state.local_device_id.as_deref(),
        ).unwrap();
        let url = crate::links::harness_conversation_link("missing", &workspace);
        state.open_deep_link(&url, cx);
        assert!(state.take_linked_chat().is_none());
        assert!(state.take_deep_link_notice().is_some());
        assert_eq!(state.selected_chat.as_deref(), Some("current"));
    });
}
