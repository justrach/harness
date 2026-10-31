use super::*;

fn search_input(shell: &Entity<Shell>, cx: &gpui::VisualTestContext) -> Entity<ComposerInput> {
    shell.read_with(cx, |shell, _| {
        shell.sidebar_search.as_ref().unwrap().input.clone()
    })
}

#[gpui::test]
fn sidebar_search_shortcut_survives_rapid_collapse_reopen_and_typing(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    // Dispatch both shortcuts in the same frame, while the dispatch tree still
    // contains the old sidebar, then type as soon as the new frame is ready.
    cx.update(|window, cx| {
        for combo in ["mod-b", "mod-f"] {
            let keystroke = Keystroke::parse(&platform_combo(combo)).unwrap();
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
        }
    });
    press_keys(cx, "x");
    let input = search_input(&shell, cx);
    cx.update(|window, cx| {
        assert!(input.focus_handle(cx).is_focused(window));
        assert_eq!(input.read(cx).text(), "x");
    });
}

#[gpui::test]
fn sidebar_search_shortcut_held_repeats_keep_the_same_search(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    press_keys(cx, &platform_combo("mod-f"));
    press_keys(cx, "q");
    let input = search_input(&shell, cx);
    for is_held in [true, false, true] {
        cx.update(|window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                    keystroke: Keystroke::parse(&platform_combo("mod-f")).unwrap(),
                    is_held,
                    prefer_character_input: false,
                }),
                cx,
            );
        });
    }
    cx.update(|window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                keystroke: Keystroke::parse(&platform_combo("mod-f")).unwrap(),
            }),
            cx,
        );
    });
    cx.run_until_parked();
    assert_eq!(search_input(&shell, cx), input);
    input.read_with(cx, |input, _| assert_eq!(input.text(), "q"));
}

#[gpui::test]
fn sidebar_search_shortcut_does_not_match_extra_modifiers(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    for combo in ["mod-shift-f", "mod-alt-f"] {
        press_keys(cx, &platform_combo(combo));
        shell.read_with(cx, |shell, _| assert!(shell.sidebar_search.is_none()));
    }
    press_keys(cx, &platform_combo("mod-f"));
    let input = search_input(&shell, cx);
    press_keys(cx, "q");
    for combo in ["mod-shift-f", "mod-alt-f"] {
        press_keys(cx, &platform_combo(combo));
        assert_eq!(search_input(&shell, cx), input);
        input.read_with(cx, |input, _| assert_eq!(input.text(), "q"));
    }
}

#[gpui::test]
fn sidebar_search_shortcut_reopens_after_escape_and_sidebar_toggle(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    for close in ["escape", "mod-b", "escape", "mod-b"] {
        press_keys(cx, &platform_combo("mod-f"));
        let input = search_input(&shell, cx);
        press_keys(cx, "q escape");
        assert_eq!(search_input(&shell, cx), input, "first Escape only clears");
        input.read_with(cx, |input, _| assert_eq!(input.text(), ""));
        press_keys(cx, &platform_combo(close));
        shell.read_with(cx, |shell, _| assert!(shell.sidebar_search.is_none()));
        press_keys(cx, &platform_combo("mod-f"));
        let next = search_input(&shell, cx);
        assert_ne!(next, input, "closed inputs must not be reused");
        cx.update(|window, cx| assert!(next.focus_handle(cx).is_focused(window)));
        press_keys(cx, "escape");
    }
}

#[gpui::test]
fn sidebar_search_shortcut_refocuses_from_its_accessible_controls(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    press_keys(cx, &platform_combo("mod-f"));
    press_keys(cx, "q");
    let input = search_input(&shell, cx);
    for control in ["trigger", "clear", "archive"] {
        cx.update(|window, cx| {
            let shell = shell.read(cx);
            let search = shell.sidebar_search.as_ref().unwrap();
            let focus = match control {
                "trigger" => &shell.sidebar_search_trigger_focus,
                "clear" => &search.clear_focus,
                _ => &search.archive_focus,
            }
            .clone();
            window.focus(&focus, cx);
        });
        press_keys(cx, &platform_combo("mod-f"));
        cx.update(|window, cx| assert!(input.focus_handle(cx).is_focused(window)));
        shell.read_with(cx, |shell, _| {
            assert!(!shell.sidebar_search.as_ref().unwrap().focus_pending);
        });
    }
    press_keys(cx, "x");
    input.read_with(cx, |input, _| assert_eq!(input.text(), "qx"));
}

#[gpui::test]
fn sidebar_search_shortcut_preserves_result_selection_and_project_scope(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats = vec![
                    chat("active", "Match one", false, "project"),
                    chat("archived", "Match two", true, "project"),
                    chat("foreign", "Match foreign", false, "other"),
                ];
                cx.notify();
            });
            shell.set_space_filter(Some("project".into()), cx);
        });
    });
    cx.run_until_parked();
    press_keys(cx, &platform_combo("mod-f"));
    let input = search_input(&shell, cx);
    super::super::edge_cases::query(&input, "match", cx);
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx));
    });
    press_keys(cx, "down");
    press_keys(cx, &platform_combo("mod-f"));
    shell.read_with(cx, |shell, cx| {
        let search = shell.sidebar_search.as_ref().unwrap();
        assert_eq!(shell.settings.space_filter.as_deref(), Some("project"));
        assert_eq!(shell.sidebar_search_ids(cx), ["active", "archived"]);
        assert_eq!(search.active_id.as_deref(), Some("archived"));
        assert!(search.keyboard_selection);
        assert!(search.include_archived);
    });
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        let state = shell.state.read(cx);
        assert_eq!(state.selected_chat.as_deref(), Some("archived"));
        assert!(
            state
                .chats
                .iter()
                .find(|chat| chat.id == "archived")
                .unwrap()
                .archived
        );
    });
}

#[gpui::test]
fn sidebar_search_shortcut_replaces_the_command_palette(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    press_keys(cx, &platform_combo("mod-k"));
    shell.read_with(cx, |shell, _| assert!(shell.command_palette.is_some()));
    press_keys(cx, &platform_combo("mod-f"));
    let input = search_input(&shell, cx);
    shell.read_with(cx, |shell, _| assert!(shell.command_palette.is_none()));
    press_keys(cx, "x");
    input.read_with(cx, |input, _| assert_eq!(input.text(), "x"));
}

#[gpui::test]
fn sidebar_search_shortcut_survives_keymap_reapplication(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    cx.update(|_, cx| {
        let keymap = shell.read(cx).settings.keymap.clone();
        let behavior = shell.read(cx).settings.composer_send_behavior;
        apply_keymap(cx, &keymap, behavior);
    });
    press_keys(cx, &platform_combo("mod-f"));
    let input = search_input(&shell, cx);
    press_keys(cx, "x");
    input.read_with(cx, |input, _| assert_eq!(input.text(), "x"));
}

#[gpui::test]
fn sidebar_search_shortcut_leaves_settings_search_alone(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = shortcut_fixture(cx);
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.open_settings(SettingsSection::Devices, cx)
        });
    });
    cx.run_until_parked();
    let before = cx.update(|window, cx| window.focused(cx));
    press_keys(cx, &platform_combo("mod-f"));
    shell.read_with(cx, |shell, _| {
        assert!(matches!(
            shell.route,
            Route::Settings(SettingsSection::Devices)
        ));
        assert!(shell.sidebar_search.is_none());
    });
    cx.update(|window, cx| assert_eq!(window.focused(cx), before));
}

#[gpui::test]
fn sidebar_search_shortcut_does_not_steal_focus_from_overlays(cx: &mut gpui::TestAppContext) {
    let mut failures = Vec::new();
    for overlay in [
        "rename",
        "rename-project",
        "add-project",
        "project-picker",
        "model-picker",
        "delete-session",
        "delete-project",
        "archive-choice",
    ] {
        for search_open in [false, true] {
            let (_dir, shell, cx) = shortcut_fixture(cx);
            if search_open {
                press_keys(cx, &platform_combo("mod-f"));
            }
            cx.update(|window, cx| {
                shell.update(cx, |shell, cx| match overlay {
                    "rename" => shell.open_rename_chat("synthetic-chat".into(), cx),
                    "rename-project" => shell.open_rename_space("synthetic-project".into(), cx),
                    "add-project" => shell.open_add_space(cx),
                    "delete-session" => {
                        shell.delete_confirm = Some("synthetic-chat".into());
                        cx.notify();
                    }
                    "delete-project" => {
                        shell.delete_space_confirm = Some("synthetic-project".into());
                        cx.notify();
                    }
                    "archive-choice" => {
                        shell.archive_choice_prompt = true;
                        cx.notify();
                    }
                    "project-picker" => {
                        let pickers = shell.composer.read(cx).pickers().clone();
                        pickers.update(cx, |pickers, cx| pickers.open_project_menu(window, cx));
                    }
                    _ => {
                        let pickers = shell.composer.read(cx).pickers().clone();
                        pickers.update(cx, |pickers, cx| pickers.open_model_menu(window, cx));
                    }
                });
            });
            cx.run_until_parked();
            let before = cx.update(|window, cx| window.focused(cx));
            assert!(before.is_some(), "{overlay} must own focus for this test");
            press_keys(cx, &platform_combo("mod-f"));
            cx.update(|window, cx| {
                if window.focused(cx) != before
                    || shell.read(cx).sidebar_search.is_some() != search_open
                {
                    failures.push(format!("{overlay}, search_open={search_open}"));
                }
            });
        }
    }
    assert!(
        failures.is_empty(),
        "shortcut bypassed overlays: {failures:?}"
    );
}
