use super::*;
// These compatibility tests seed the complete project catalogue directly.
// Startup now waits for both catalogues, not just the conversations frame.
fn fixture(
    cx: &mut gpui::TestAppContext,
    split: bool,
    parked: Option<bool>,
) -> (tempfile::TempDir, gpui::WindowHandle<Shell>) {
    let result = crate::shell::chat_tabs::navigation_tests::fixture(cx, split, parked);
    result
        .1
        .update(cx, |shell, _, cx| {
            shell
                .state
                .update(cx, |state, _| state.spaces_synced = true);
        })
        .unwrap();
    result
}

mod navigation_edges;
mod parked_lifecycle;
mod persistence;
mod restored_tabs;
mod saved_layout;
mod startup_safety;

#[gpui::test]
fn archived_session_survives_split_focus_and_tab_switching(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, _| {
                state.chats_synced = true;
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "current")
                    .unwrap()
                    .archived = true;
            });
            // Exercise the retained legacy split migration path explicitly. Cmd+D
            // now creates a workspace panel, which has separate coverage.
            shell.split_chat_opening(SplitAxis::Horizontal, None, window, cx);
            shell.chat_split_on_state_changed(cx);
            assert_eq!(
                shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                Some("current")
            );
            assert!(shell.peer_chat_views.contains_key("current"));
            assert!(shell.state.read(cx).selected_chat.is_none());

            for _ in 0..3 {
                shell.focus_chat_pane(0, window, cx);
                shell.chat_split_on_state_changed(cx);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
                shell.focus_chat_pane(1, window, cx);
                shell.chat_split_on_state_changed(cx);
                assert_eq!(
                    shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                    Some("current")
                );
            }

            // Parking and reloading the whole tab must retain the peer too.
            shell.new_chat_tab(Some("target".into()), window, cx);
            shell.switch_chat_tab(0, window, cx);
            shell.chat_split_on_state_changed(cx);
            assert_eq!(
                shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                Some("current")
            );
            shell.focus_chat_pane(0, window, cx);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
            assert_eq!(
                shell.state.read(cx).chats.len(),
                4,
                "navigation must not create a session"
            );
        })
        .unwrap();
}

#[gpui::test]
fn archived_layout_restores_after_initial_sync(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for canvas in [false, true] {
            let (_dir, window) = fixture(cx, false, None);
            window
                .update(cx, |shell, window, cx| {
                    let saved = ChatSplit::split(None, axis, Some("peer".into()), None)
                        .unwrap()
                        .to_saved();
                    shell.settings.chat_layout = Some(saved.clone());
                    shell.settings.last_chat_id = (!canvas).then(|| "current".into());
                    shell.state.update(cx, |state, cx| {
                        state.select_chat(None, cx);
                        state.auto_selected = false;
                        for chat in &mut state.chats {
                            chat.archived = true;
                        }
                    });
                    // A partial initial frame must not consume the saved layout.
                    shell.boot_select_chat(cx);
                    assert!(!shell.boot_restored);
                    assert_eq!(shell.settings.chat_layout.as_ref(), Some(&saved));
                    shell.state.update(cx, |state, _| {
                        state.apply_chats(state.chats.clone());
                    });
                    shell.boot_select_chat(cx);
                    assert!(shell.boot_restored);
                    assert_eq!(
                        shell.state.read(cx).selected_chat.as_deref(),
                        (!canvas).then_some("current")
                    );
                    let split = shell.chat_split.as_ref().unwrap();
                    assert_eq!(split.axis, axis);
                    assert_eq!(split.panes[0].as_deref(), Some("peer"));
                    assert!(shell.peer_chat_views.contains_key("peer"));
                    shell.focus_chat_pane(0, window, cx);
                    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                    assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
                    assert_eq!(shell.state.read(cx).visible_chats().count(), 0);
                })
                .unwrap();
        }
    }
}

#[gpui::test]
fn deleted_session_still_clears_its_split_pane(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.split_chat_opening(SplitAxis::Horizontal, None, window, cx);
            shell.state.update(cx, |state, _| {
                state.chats.retain(|chat| chat.id != "current");
            });
            // An incomplete initial list must not discard an open pane.
            shell.chat_split_on_state_changed(cx);
            assert_eq!(
                shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                Some("current")
            );
            shell.state.update(cx, |state, _| state.chats_synced = true);
            shell.chat_split_on_state_changed(cx);
            assert!(shell.chat_split.as_ref().unwrap().panes[0].is_none());
            assert!(!shell.peer_chat_views.contains_key("current"));
        })
        .unwrap();
}

// Assert the rendered workspace's placement rather than superseded legacy
// bookkeeping that remains available for backwards-compatible settings.
fn workspace_chat_ids(shell: &Shell, cx: &App) -> Vec<String> {
    shell
        .panel_layout(cx)
        .unwrap()
        .panels
        .iter()
        .flat_map(|panel| &panel.tabs)
        .filter_map(|tab| match tab {
            crate::shell::workspace_panels::PanelTab::Chat(id) => Some(id.clone()),
            _ => None,
        })
        .collect()
}
