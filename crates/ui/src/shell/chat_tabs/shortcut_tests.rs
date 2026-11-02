use super::*;

fn fixture(
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
        settings::init(settings::UiSettings::expanded(), dir.path(), cx);
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

fn assert_target_preserved(shell: &Shell, cx: &App) {
    assert_eq!(shell.chat_tabs.len(), 2, "must reveal or append, not duplicate");
    assert_eq!(shell.chat_tab, 1);
    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("target"));
    assert_eq!(shell.chat_tabs[0].selected.as_deref(), Some("current"));
}

#[gpui::test]
fn session_jump_shortcuts_preserve_tabs_and_split_layouts(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        for parked in [None, Some(false), Some(true)] {
            let (_dir, window) = fixture(cx, split, parked);
            let (layout, draft, slot) = window
                .update(cx, |shell, _, cx| {
                    // Cmd-number jumps are also allowed from Settings.
                    shell.route = Route::Settings(SettingsSection::Appearance);
                    (
                        shell.chat_split.clone(),
                        shell.current_canvas_draft(cx),
                        shell.sidebar_visible_order(cx).iter().position(|id| id == "target").unwrap(),
                    )
                })
                .unwrap();
            // Exercise the registered binding and real shell action listener.
            let combo = platform_combo(&format!("mod-{}", slot + 1));
            let keystroke = gpui::Keystroke::parse(&combo).unwrap();
            for _ in 0..2 {
                cx.update_window(window.into(), |_, window, cx| {
                    window.draw(cx).clear();
                    window.dispatch_event(
                        gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                            keystroke: keystroke.clone(),
                            is_held: false,
                            prefer_character_input: false,
                        }),
                        cx,
                    );
                    window.dispatch_event(
                        gpui::PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke: keystroke.clone() }),
                        cx,
                    );
                }).unwrap();
                window.update(cx, |shell, _, cx| {
                    assert_target_preserved(shell, cx);
                    assert_eq!(shell.chat_tabs[0].split, layout);
                    assert_eq!(shell.chat_tabs[0].draft.as_ref(), Some(&draft));
                    if parked == Some(true) {
                        assert_eq!(shell.chat_split.as_ref().unwrap().panes[1].as_deref(), Some("parked"));
                    }
                }).unwrap();
            }
            window.update(cx, |shell, window, cx| {
                let slot = shell.sidebar_visible_order(cx).iter().position(|id| id == "current").unwrap();
                shell.jump_to_session(slot, window, cx);
                assert_eq!(shell.chat_tab, 0);
                assert_eq!(shell.chat_split, layout);
                assert_eq!(shell.current_canvas_draft(cx), draft);
                if split {
                    let slot = shell.sidebar_visible_order(cx).iter().position(|id| id == "peer").unwrap();
                    shell.jump_to_session(slot, window, cx);
                    assert_eq!(shell.chat_tabs.len(), 2);
                    assert_eq!(shell.chat_tab, 0);
                    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                    assert_eq!(shell.chat_split.as_ref().unwrap().panes[1].as_deref(), Some("current"));
                }
                let selected = shell.state.read(cx).selected_chat.clone();
                shell.jump_to_session(99, window, cx);
                assert_eq!(shell.state.read(cx).selected_chat, selected);
            }).unwrap();
        }
    }
}

#[gpui::test]
fn session_cycle_fallback_preserves_the_original_tab(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        for forward in [false, true] {
            let (_dir, window) = fixture(cx, split, None);
            window.update(cx, |shell, window, cx| {
                // Leave the peer in its split but make the next sidebar row
                // unopened in both directions, exercising the single-tab fallback.
                shell.state.update(cx, |state, _| {
                    state.chats.retain(|chat| chat.id == "current" || chat.id == "target");
                });
                let layout = shell.chat_split.clone();
                let draft = shell.current_canvas_draft(cx);
                shell.cycle_tab_or_session(forward, window, cx);
                assert_target_preserved(shell, cx);
                assert_eq!(shell.chat_tabs[0].split, layout);
                assert_eq!(shell.chat_tabs[0].draft.as_ref(), Some(&draft));
                // Once two tabs exist, Ctrl+Tab cycles tabs rather than
                // continuing through sidebar sessions.
                shell.cycle_tab_or_session(!forward, window, cx);
                assert_eq!(shell.chat_tabs.len(), 2);
                assert_eq!(shell.chat_tab, 0);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("current"));
                assert_eq!(shell.chat_split, layout);
                assert_eq!(shell.current_canvas_draft(cx), draft);
            }).unwrap();
        }
    }
}
