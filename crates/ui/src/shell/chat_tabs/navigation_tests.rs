use super::*;

pub(in crate::shell) fn fixture(
    cx: &mut gpui::TestAppContext,
    split: bool,
    parked: Option<bool>,
) -> (tempfile::TempDir, gpui::WindowHandle<Shell>) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        settings::init(settings::UiSettings::default(), dir.path(), cx);
    });
    let window = cx.add_window(|_, cx| {
        let state = cx.new(|_| AppState::new());
        let mut shell = Shell::new(
            state,
            EngineBootConfig {
                data_dir: dir.path().into(),
                ipc_port: 0,
                edge_url: "http://127.0.0.1:1".into(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: harness_proto::HarnessId::Mock,
            },
            cx,
        );
        shell.settings.space_filter = None;
        shell.state.update(cx, |state, cx| {
            state.local_device_id = Some("local".into());
            state.workspace_scope = Some(WorkspaceScope::Local);
            state.chats = ["current", "peer", "target", "parked"]
                .map(|id| {
                    serde_json::from_value(serde_json::json!({
                        "id": id, "deviceId": "local", "archived": false,
                        "createdAt": Utc::now(),
                    }))
                    .unwrap()
                })
                .into();
            state.select_chat(Some("current".into()), cx);
        });
        if split {
            shell.chat_split = chat_split::ChatSplit::split(
                None,
                SplitAxis::Horizontal,
                Some("peer".into()),
                None,
            );
        }
        if let Some(peer) = parked {
            shell.chat_tabs = vec![
                ChatTab::default(),
                ChatTab {
                    selected: Some(if peer { "parked" } else { "target" }.into()),
                    split: peer.then(|| {
                        chat_split::ChatSplit::split(
                            None,
                            SplitAxis::Horizontal,
                            Some("target".into()),
                            None,
                        )
                        .unwrap()
                    }),
                    ..Default::default()
                },
            ];
        }
        shell
    });
    (dir, window)
}

pub(in crate::shell) fn assert_target_preserved(shell: &Shell, cx: &App) {
    assert_eq!(shell.chat_tabs.len(), 2, "must reveal or append, not duplicate");
    assert_eq!(shell.chat_tab, 1);
    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("target"));
    assert_eq!(shell.chat_tabs[0].selected.as_deref(), Some("current"));
}

#[gpui::test]
fn notification_clicks_preserve_tabs_and_split_layouts(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        for parked in [None, Some(false), Some(true)] {
            let (_dir, window) = fixture(cx, split, parked);
            let (state, layout, draft) = window.update(cx, |shell, _, cx| {
                shell.route = Route::Settings(SettingsSection::Appearance);
                (shell.state.clone(), shell.chat_split.clone(), shell.current_canvas_draft(cx))
            }).unwrap();
            for _ in 0..2 {
                // Exercise the actual desktop-notification click entry point.
                cx.update(|cx| crate::open_notified_chat("target".into(), &state, cx));
                cx.run_until_parked();
                window.update(cx, |shell, _, cx| {
                    assert_target_preserved(shell, cx);
                    assert!(matches!(shell.route, Route::Chat));
                    assert_eq!(shell.chat_tabs[0].split, layout);
                    assert_eq!(shell.chat_tabs[0].draft.as_ref(), Some(&draft));
                }).unwrap();
            }
            // Notification clicks target the first Shell window. Keep each
            // matrix case isolated from the previous case's window.
            window.update(cx, |_, window, _| window.remove_window()).unwrap();
        }
    }
}

#[gpui::test]
fn unsaved_file_reveal_preserves_existing_chat_tabs(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        for parked in [None, Some(false), Some(true)] {
            let (_dir, window) = fixture(cx, split, parked);
            let (layout, draft) = window.update(cx, |shell, _, cx| {
                let state = shell.state.clone();
                let files = cx.new(|cx| {
                    let mut files = FilesSurface::new(state, "target".into(), false, 1000, 13.0, false, false, cx);
                    files.seed_pending_exit_test_document(true);
                    files
                });
                shell.file_surfaces.insert(0, files);
                shell.file_surface_keys.insert(("target".into(), "test.rs".into()), 0);
                shell.file_surface_paths.insert(0, "test.rs".into());
                shell.right_tabs.insert("target".into(), vec![RightSurface::File(0)]);
                (shell.chat_split.clone(), shell.current_canvas_draft(cx))
            }).unwrap();
            for _ in 0..2 {
                window.update(cx, |shell, _, cx| {
                    assert!(!shell.prepare_exit(PendingExit::Quit, cx));
                }).unwrap();
                // The shell observer updates the active chat's panel key.
                cx.run_until_parked();
                window.update(cx, |shell, _, cx| {
                    assert_target_preserved(shell, cx);
                    assert_eq!(shell.chat_tabs[0].split, layout);
                    assert_eq!(shell.chat_tabs[0].draft.as_ref(), Some(&draft));
                    assert_eq!(shell.resolved_right_active(cx), RightSurface::File(0));
                }).unwrap();
            }
        }
    }
}

#[gpui::test]
fn notification_to_live_peer_only_focuses_that_pane(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, true, Some(false));
    let (state, parked) = window.update(cx, |shell, _, _| (shell.state.clone(), shell.chat_tabs[1].clone())).unwrap();
    cx.update(|cx| crate::open_notified_chat("peer".into(), &state, cx));
    cx.run_until_parked();
    window.update(cx, |shell, _, cx| {
        assert_eq!(shell.chat_tabs.len(), 2);
        assert_eq!(shell.chat_tab, 0);
        assert_eq!(shell.chat_tabs[1], parked);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        assert!(shell.chat_split.as_ref().unwrap().panes.iter().any(|id| id.as_deref() == Some("current")));
    }).unwrap();
}

#[gpui::test]
fn blank_canvas_unsaved_file_reveal_stays_in_current_tab(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, true, Some(false));
    window.update(cx, |shell, _, cx| {
        let tabs = shell.chat_tabs.clone();
        let state = shell.state.clone();
        let files = cx.new(|cx| {
            let mut files = FilesSurface::new(state, String::new(), false, 1000, 13.0, false, false, cx);
            files.seed_pending_exit_test_document(true);
            files
        });
        shell.file_surfaces.insert(0, files);
        shell.file_surface_keys.insert((String::new(), "test.rs".into()), 0);
        assert!(!shell.prepare_exit(PendingExit::Quit, cx));
        assert_eq!(shell.chat_tabs, tabs);
        assert_eq!(shell.chat_tab, 0);
        assert!(shell.state.read(cx).selected_chat.is_none());
    }).unwrap();
}

#[gpui::test]
fn conversation_deep_links_preserve_tabs_after_validation(cx: &mut gpui::TestAppContext) {
    for parked in [None, Some(false), Some(true)] {
        let (_dir, window) = fixture(cx, true, parked);
        let layout = window.update(cx, |shell, _, cx| {
            let layout = shell.chat_split.clone();
            let workspace = crate::links::workspace_locator(Some(WorkspaceScope::Local), None, Some("local")).unwrap();
            let url = crate::links::harness_conversation_link("target", &workspace);
            shell.state.update(cx, |state, cx| state.open_deep_link(&url, cx));
            layout
        }).unwrap();
        cx.run_until_parked();
        window.update(cx, |shell, _, cx| {
            assert_target_preserved(shell, cx);
            assert_eq!(shell.chat_tabs[0].split, layout);
            let url = crate::links::harness_conversation_link("peer", "different-workspace");
            shell.state.update(cx, |state, cx| state.open_deep_link(&url, cx));
        }).unwrap();
        cx.run_until_parked();
        window.update(cx, |shell, _, cx| assert_target_preserved(shell, cx)).unwrap();
    }
}

