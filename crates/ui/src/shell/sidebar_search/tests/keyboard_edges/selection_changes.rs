use super::*;

#[gpui::test]
fn sidebar_search_archive_only_follows_selection_changes_before_navigation(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    cx.run_until_parked();
    // Selecting a tab outside search changes the row the archive-only list
    // paints as selected. Its keyboard cursor must follow that same session.
    cx.update(|_, cx| {
        shell.read(cx).state.clone().update(cx, |state, cx| {
            state.select_chat(Some("archived".into()), cx)
        });
    });
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
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("archived")
        );
    });
}

#[gpui::test]
fn sidebar_search_archive_only_keeps_explicit_navigation_across_selection_changes(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    cx.run_until_parked();
    press_keys(cx, "up");
    cx.update(|_, cx| {
        shell
            .read(cx)
            .state
            .clone()
            .update(cx, |state, cx| state.select_chat(Some("active".into()), cx));
    });
    cx.run_until_parked();
    cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("archived"),
            "an explicit keyboard choice must not jump when another surface changes selection"
        );
    });
}
