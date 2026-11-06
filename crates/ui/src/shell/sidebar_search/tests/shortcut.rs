use super::*;

mod edge_cases;
mod removal;

fn shortcut_fixture(
    cx: &mut gpui::TestAppContext,
) -> (
    tempfile::TempDir,
    Entity<Shell>,
    &mut gpui::VisualTestContext,
) {
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
    // Mount the real shell so both its registered binding and action listener
    // are exercised, including focus handoff as the sidebar mounts.
    let (shell, cx) = cx.add_window_view(|window, cx| {
        window.activate_window();
        Shell::new(
            cx.new(|_| AppState::new()),
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
        )
    });
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.route = Route::Chat;
            shell.settings.space_filter = None;
            shell.state.update(cx, |state, cx| {
                state.connection = crate::state::ConnectionStatus::Ready;
                state.workspace_scope = Some(WorkspaceScope::Local);
                state.local_device_id = Some("local".into());
                state.spaces = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "one", "deviceId": "local", "path": "/fixture/one",
                        "createdAt": "2026-10-01T00:00:00Z",
                    }))
                    .unwrap(),
                ];
                cx.notify();
            });
            // The live application restores its initial workspace after sync.
            // This isolated shell skips bootstrap, so establish that state here.
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            window.focus(&shell.composer.focus_handle(cx), cx);
            cx.notify();
        });
    });
    cx.run_until_parked();
    (dir, shell, cx)
}

fn open_workspace_search(
    shell: &Entity<Shell>,
    cx: &mut gpui::VisualTestContext,
) -> Entity<ComposerInput> {
    press_keys(cx, &platform_combo("mod-f"));
    shell.read_with(cx, |shell, _| {
        shell.sidebar_search.as_ref().unwrap().input.clone()
    })
}

#[gpui::test]
fn sidebar_search_shortcut_reveals_and_focuses_search(cx: &mut gpui::TestAppContext) {
    for collapsed in [false, true] {
        let (_dir, shell, cx) = shortcut_fixture(cx);
        if collapsed {
            press_keys(cx, &platform_combo("mod-b"));
        }
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.settings.sidebar_collapsed, collapsed);
            assert!(shell.sidebar_search.is_none());
        });

        press_keys(cx, &platform_combo("mod-f"));
        let input = shell.read_with(cx, |shell, _| {
            assert!(
                !shell.settings.sidebar_collapsed,
                "search must reveal the sidebar"
            );
            shell
                .sidebar_search
                .as_ref()
                .expect("the shortcut must open session search")
                .input
                .clone()
        });
        cx.update(|window, cx| {
            assert!(input.focus_handle(cx).is_focused(window));
        });
        assert!(cx.debug_bounds("sidebar-search-controls").is_some());
        press_keys(cx, "s i d e b a r");
        input.read_with(cx, |input, _| assert_eq!(input.text(), "sidebar"));
    }
}

#[gpui::test]
fn sidebar_search_shortcut_refocuses_without_toggling_or_resetting(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    // Open through the workspace shortcut, then exercise an already-open search.
    let input = open_workspace_search(&shell, cx);
    super::edge_cases::query(&input, "sidebar", cx);
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx));
    });
    cx.run_until_parked();
    for move_focus in [false, true] {
        if move_focus {
            cx.update(|window, cx| {
                window.focus(&shell.read(cx).composer.focus_handle(cx), cx);
            });
        }
        press_keys(cx, &platform_combo("mod-f"));
        cx.update(|window, cx| {
            let shell = shell.read(cx);
            let search = shell
                .sidebar_search
                .as_ref()
                .expect("search must stay open");
            assert_eq!(search.input, input, "reuse the existing search input");
            assert_eq!(input.read(cx).text(), "sidebar");
            assert!(search.include_archived, "preserve the archive filter");
            assert!(input.focus_handle(cx).is_focused(window));
        });
    }
    press_keys(cx, "x");
    input.read_with(cx, |input, _| assert_eq!(input.text(), "sidebarx"));
}

#[gpui::test]
fn closing_workspace_search_returns_typing_to_composer(cx: &mut gpui::TestAppContext) {
    for escape in [false, true] {
        let (_dir, shell, cx) = shortcut_fixture(cx);
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats = vec![chat("current", "Current session", false, "one")];
                state.select_chat(Some("current".into()), cx);
            });
            cx.notify();
        });
        cx.run_until_parked();
        let composer = shell.read_with(cx, |shell, _| shell.composer.clone());
        let input = composer.read_with(cx, |composer, _| composer.input.clone());
        cx.update(|window, cx| {
            assert!(
                shell
                    .read(cx)
                    .shortcut_focus
                    .contains(&composer.focus_handle(cx), window)
            );
        });
        open_workspace_search(&shell, cx);
        press_keys(cx, "q escape");
        cx.update(|window, cx| {
            if escape {
                let keystroke = Keystroke::parse("escape").unwrap();
                window.dispatch_event(
                    gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                        keystroke: keystroke.clone(),
                        is_held: false,
                        prefer_character_input: false,
                    }),
                    cx,
                );
                window.dispatch_event(
                    gpui::PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke }),
                    cx,
                );
            } else {
                shell.update(cx, |shell, cx| shell.toggle_sidebar_search(window, cx));
            }
            assert!(shell.read(cx).sidebar_search.is_none());
            // Assert before Shell's deferred recovery can mask stale focus.
            assert!(composer.focus_handle(cx).is_focused(window));
            assert!(shell.read(cx).shortcut_focus.contains_focused(window, cx));
        });
        press_keys(cx, "d r a f t");
        input.read_with(cx, |input, _| assert_eq!(input.text(), "draft"));
    }
}
