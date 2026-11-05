use super::*;

#[gpui::test]
fn stale_open_requests_do_not_replace_the_current_archived_view(cx: &mut gpui::TestAppContext) {
    for settings in [false, true] {
        let (_dir, window) = archived_window(cx, true, None);
        window
            .update(cx, |shell, _, cx| {
                if settings {
                    shell.route = Route::Settings(SettingsSection::Archived);
                }
                let layout = shell.chat_split.clone();
                let tabs = shell.chat_tabs.clone();
                shell.state.update(cx, |state, cx| {
                    let mut chats = state.chats.clone();
                    chats.retain(|chat| chat.id != "target");
                    state.apply_chats(chats);
                    cx.notify();
                });
                shell.open_chat_preserving_tabs("target".into(), cx);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert_eq!(shell.chat_tabs, tabs);
                assert_eq!(shell.chat_split, layout);
                assert_eq!(matches!(shell.route, Route::Settings(_)), settings);
            })
            .unwrap();
    }
}

#[gpui::test]
fn stale_split_drop_does_not_change_layout_or_selection(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        let (_dir, window) = archived_window(cx, false, None);
        window
            .update(cx, |shell, window, cx| {
                shell.state.update(cx, |state, cx| {
                    let mut chats = state.chats.clone();
                    chats.retain(|chat| chat.id != "target");
                    state.apply_chats(chats);
                    cx.notify();
                });
                shell.split_chat_opening(axis, Some("target".into()), window, cx);
                assert!(shell.chat_split.is_none());
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
            })
            .unwrap();
    }
}

#[gpui::test]
fn moving_an_archived_peer_to_a_new_split_empties_its_old_slot(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = archived_window(cx, true, None);
    window
        .update(cx, |shell, window, cx| {
            shell.split_chat_opening(SplitAxis::Horizontal, Some("peer".into()), window, cx);
            let split = shell.chat_split.as_ref().unwrap();
            assert_eq!(split.focus, 2);
            assert!(
                split.panes[0].is_none(),
                "a moved session must not remain in its previous pane"
            );
            assert_eq!(split.panes[1].as_deref(), Some("current"));
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(
                shell.chat_split.as_ref().unwrap().focus,
                2,
                "observer reconciliation must not jump back to the old pane"
            );
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
        })
        .unwrap();
}

#[gpui::test]
fn moving_an_archived_session_out_of_a_parked_tab_removes_its_old_reference(
    cx: &mut gpui::TestAppContext,
) {
    for peer in [false, true] {
        let (_dir, window) = archived_window(cx, false, Some(peer));
        window
            .update(cx, |shell, window, cx| {
                shell.split_chat_opening(SplitAxis::Horizontal, Some("target".into()), window, cx);
                let parked = &shell.chat_tabs[1];
                if peer {
                    assert_eq!(parked.selected.as_deref(), Some("parked"));
                    assert!(parked.split.as_ref().unwrap().panes[0].is_none());
                } else {
                    assert!(parked.selected.is_none());
                }
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("target")
                );
                assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
                shell.switch_chat_tab(1, window, cx);
                assert_ne!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("target")
                );
                shell.switch_chat_tab(0, window, cx);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("target")
                );
            })
            .unwrap();
    }
}

#[gpui::test]
fn reopening_the_focused_archived_session_preserves_its_existing_placement(
    cx: &mut gpui::TestAppContext,
) {
    for split in [false, true] {
        let (_dir, window) = archived_window(cx, split, None);
        window
            .update(cx, |shell, window, cx| {
                let layout = shell.chat_split.clone();
                let tabs = shell.chat_tabs.clone();
                shell.new_chat_tab(Some("current".into()), window, cx);
                assert_eq!(shell.chat_split, layout);
                assert_eq!(
                    shell.chat_tabs, tabs,
                    "reopening must not duplicate the conversation"
                );
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
            })
            .unwrap();
    }
}

#[gpui::test]
fn refused_splits_do_not_detach_archived_sessions(cx: &mut gpui::TestAppContext) {
    for at_cap in [false, true] {
        let (_dir, window) = archived_window(cx, true, Some(false));
        window
            .update(cx, |shell, window, cx| {
                if at_cap {
                    let remaining = MAX_CHAT_PANES - shell.chat_split.as_ref().unwrap().panes.len();
                    for _ in 0..remaining {
                        shell.split_chat_opening(SplitAxis::Horizontal, None, window, cx);
                    }
                    assert_eq!(
                        shell.chat_split.as_ref().unwrap().panes.len(),
                        MAX_CHAT_PANES,
                        "legacy split setup must reach the cap in a bounded number of steps"
                    );
                }
                let layout = shell.chat_split.clone();
                let tabs = shell.chat_tabs.clone();
                let selected = shell.state.read(cx).selected_chat.clone();
                let axis = if at_cap {
                    SplitAxis::Horizontal
                } else {
                    SplitAxis::Vertical
                };
                shell.split_chat_opening(axis, Some("target".into()), window, cx);
                assert_eq!(shell.chat_split, layout);
                assert_eq!(shell.chat_tabs, tabs);
                assert_eq!(shell.state.read(cx).selected_chat, selected);
                assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
            })
            .unwrap();
    }
}

#[gpui::test]
fn opening_an_unopened_archived_session_still_preserves_the_previous_tab(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = archived_window(cx, true, None);
    window
        .update(cx, |shell, _, cx| {
            let previous = shell.chat_split.clone();
            shell.open_chat_preserving_tabs("target".into(), cx);
            shell.open_chat_preserving_tabs("target".into(), cx);
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(shell.chat_tabs[0].split, previous);
            assert_eq!(shell.chat_tabs[0].selected.as_deref(), Some("current"));
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("target")
            );
            assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
        })
        .unwrap();
}

#[gpui::test]
fn unknown_references_remain_openable_while_initial_metadata_is_incomplete(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = archived_window(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            let complete = shell.state.read(cx).chats.clone();
            shell.state.update(cx, |state, _| {
                state.chats.retain(|chat| chat.id != "peer");
                state.chats_synced = false;
            });
            shell.open_chat("peer".into(), cx);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            shell.state.update(cx, |state, cx| {
                state.apply_chats(complete);
                cx.notify();
            });
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
        })
        .unwrap();
}

#[gpui::test]
fn stale_explicit_tab_creation_keeps_the_current_route_and_layout(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = archived_window(cx, true, None);
    window
        .update(cx, |shell, window, cx| {
            shell.route = Route::Settings(SettingsSection::Archived);
            let layout = shell.chat_split.clone();
            shell.state.update(cx, |state, cx| {
                let mut chats = state.chats.clone();
                chats.retain(|chat| chat.id != "target");
                state.apply_chats(chats);
                cx.notify();
            });
            shell.new_chat_tab(Some("target".into()), window, cx);
            assert!(shell.chat_tabs.is_empty());
            assert_eq!(shell.chat_split, layout);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            assert!(matches!(
                shell.route,
                Route::Settings(SettingsSection::Archived)
            ));
        })
        .unwrap();
}

fn archived_window(
    cx: &mut gpui::TestAppContext,
    split: bool,
    parked: Option<bool>,
) -> (tempfile::TempDir, gpui::WindowHandle<Shell>) {
    let (dir, window) = fixture(cx, split, parked);
    window
        .update(cx, |shell, _, cx| {
            shell.route = Route::Chat;
            shell.boot_restored = true;
            shell.state.update(cx, |state, _| {
                state.chats_synced = true;
                for chat in &mut state.chats {
                    chat.archived = true;
                }
            });
        })
        .unwrap();
    (dir, window)
}
