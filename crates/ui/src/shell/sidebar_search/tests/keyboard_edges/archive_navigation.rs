use super::*;

#[gpui::test]
fn sidebar_search_archive_only_query_clear_resets_navigation_to_current(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    cx.run_until_parked();
    press_keys(cx, "down");
    shell.read_with(cx, |shell, _| {
        assert!(shell.sidebar_search.as_ref().unwrap().keyboard_selection)
    });
    query(&input, "sidebar", cx);
    query(&input, "", cx);
    shell.read_with(cx, |shell, _| {
        let search = shell.sidebar_search.as_ref().unwrap();
        assert_eq!(search.active_id.as_deref(), Some("current"));
        assert!(
            !search.keyboard_selection,
            "clearing the query restores the ordinary selected-row highlight"
        );
        assert!(search.include_archived);
    });
    press_keys(cx, "up enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("archived")
        );
    });
}

#[gpui::test]
fn sidebar_search_archive_only_starts_on_an_archived_current_session(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    cx.update(|_, cx| {
        shell.read(cx).state.clone().update(cx, |state, cx| {
            state.select_chat(Some("archived".into()), cx)
        });
    });
    cx.run_until_parked();
    let input = open_search(&shell, cx);
    for _ in 0..2 {
        cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
        cx.run_until_parked();
        cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
        shell.read_with(cx, |shell, _| {
            assert_eq!(
                shell.sidebar_search.as_ref().unwrap().active_id.as_deref(),
                Some("archived")
            );
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
        cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
        cx.run_until_parked();
    }
}

#[gpui::test]
fn sidebar_search_archive_only_enter_before_redraw_uses_current(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let _input = open_search(&shell, cx);
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.toggle_sidebar_search_archived(cx);
            shell.sidebar_search_key(
                &gpui::KeyDownEvent {
                    keystroke: Keystroke::parse("enter").unwrap(),
                    is_held: false,
                    prefer_character_input: false,
                },
                window,
                cx,
            );
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
        });
    });
}

#[gpui::test]
fn sidebar_search_archive_only_tolerates_current_outside_scope_and_empty_scope(
    cx: &mut gpui::TestAppContext,
) {
    for project in ["other", "missing"] {
        let (_dir, shell, cx) = fixture(cx, 280.0);
        cx.update(|_, cx| {
            shell.read(cx).state.clone().update(cx, |state, cx| {
                state
                    .chats
                    .push(chat("foreign", "Foreign session", true, "other"));
                cx.notify();
            });
        });
        cx.run_until_parked();
        let input = open_search(&shell, cx);
        cx.update(|_, cx| {
            shell.update(cx, |shell, cx| {
                shell.set_space_filter(Some(project.into()), cx);
                shell.toggle_sidebar_search_archived(cx);
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
        press_keys(cx, "down up enter");
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some(if project == "other" {
                    "foreign"
                } else {
                    "current"
                })
            );
        });
    }
}

#[gpui::test]
fn sidebar_search_id_match_survives_a_title_rename(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "ACTIVE", cx);
    cx.update(|_, cx| {
        shell.read(cx).state.clone().update(cx, |state, cx| {
            state
                .chats
                .iter_mut()
                .find(|chat| chat.id == "active")
                .unwrap()
                .title = Some("Renamed away from the old title".into());
            cx.notify();
        });
    });
    cx.run_until_parked();
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("active")
        );
    });
}
