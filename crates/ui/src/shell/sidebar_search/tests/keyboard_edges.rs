use super::edge_cases::{open_search, query};
use super::*;

mod archive_navigation;
mod selection_changes;

#[gpui::test]
fn sidebar_search_modified_input_keys_do_not_activate_or_clear(cx: &mut gpui::TestAppContext) {
    for key in [
        "ctrl-enter",
        "alt-enter",
        "shift-enter",
        "cmd-enter",
        "ctrl-escape",
    ] {
        let (_dir, shell, cx) = fixture(cx, 280.0);
        let input = open_search(&shell, cx);
        query(&input, "sidebar", cx);
        press_keys(cx, key);
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current"),
                "{key} must not open a session"
            );
            assert_eq!(
                input.read(cx).text(),
                if key == "shift-enter" {
                    "sidebar "
                } else {
                    "sidebar"
                },
                "{key} must preserve the single-line query (Shift+Enter inserts a space)"
            );
            assert!(
                shell
                    .sidebar_search
                    .as_ref()
                    .unwrap()
                    .pressed_keys
                    .is_empty(),
                "{key} must not latch an unhandled action"
            );
        });
        press_keys(cx, "enter");
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("active"),
                "a modified key must not block the next plain Enter"
            );
        });
    }
}

#[gpui::test]
fn sidebar_search_modified_arrows_do_not_move_the_result_cursor(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    cx.run_until_parked();
    for key in ["alt-down", "ctrl-up", "cmd-down", "shift-up"] {
        press_keys(cx, key);
        shell.read_with(cx, |shell, _| {
            assert_eq!(
                shell.sidebar_search.as_ref().unwrap().active,
                0,
                "{key} must not navigate results"
            );
        });
    }
    press_keys(cx, "down");
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.sidebar_search.as_ref().unwrap().active, 1)
    });
}

#[gpui::test]
fn sidebar_search_archive_only_enter_starts_from_the_selected_session(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    cx.run_until_parked();
    cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
    shell.read_with(cx, |shell, cx| {
        let search = shell.sidebar_search.as_ref().unwrap();
        assert_eq!(
            search.active_id.as_deref(),
            Some("current"),
            "archive-only keyboard cursor must match the visible selected row"
        );
        assert_eq!(shell.sidebar_search_ids(cx)[search.active], "current");
    });
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
}

#[gpui::test]
fn sidebar_search_archive_only_navigation_tracks_the_selected_row(cx: &mut gpui::TestAppContext) {
    for (key, expected) in [("up", "archived"), ("down", "active")] {
        let (_dir, shell, cx) = fixture(cx, 280.0);
        let input = open_search(&shell, cx);
        cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
        cx.run_until_parked();
        cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
        press_keys(cx, key);
        shell.read_with(cx, |shell, _| {
            assert_eq!(
                shell.sidebar_search.as_ref().unwrap().active_id.as_deref(),
                Some(expected),
                "{key} must navigate relative to the selected row, not a hidden first-row cursor"
            );
        });
        press_keys(cx, "enter");
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some(expected)
            );
        });
    }
}

#[test]
fn sidebar_search_id_and_title_collisions_keep_scope_and_deterministic_order() {
    let mut rows = vec![
        chat("match-id", "Other title", false, "one"),
        chat("title-hit", "MATCH-ID", false, "one"),
        chat("archived-match-id", "Other", true, "one"),
        chat("child-match-id", "MATCH-ID", false, "one"),
        chat("foreign-match-id", "MATCH-ID", false, "two"),
    ];
    rows[3].parent_chat_id = Some("match-id".into());
    for sort in [SidebarSort::Created, SidebarSort::LastUpdated] {
        let found = matching_chats(&rows, "\tMATCH-ID\n", Some("one"), true, sort);
        assert_eq!(
            found
                .into_iter()
                .map(|chat| chat.id.as_str())
                .collect::<Vec<_>>(),
            ["archived-match-id", "match-id", "title-hit"]
        );
    }
    assert!(
        matching_chats(
            &rows,
            "match-id",
            Some("missing"),
            true,
            SidebarSort::Created
        )
        .is_empty()
    );
}
