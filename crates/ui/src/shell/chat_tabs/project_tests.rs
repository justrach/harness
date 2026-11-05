use super::*;

#[gpui::test]
fn project_sidebar_navigation_keeps_one_stable_tab(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.persist_chat_tabs(cx);
            let labels = shell.chat_tab_labels(cx);
            shell.open_chat_in_tab("peer".into(), window, cx);
            assert_eq!(shell.chat_tabs.len(), 1);
            assert_eq!(shell.chat_tab_labels(cx), labels);
            assert_eq!(labels, [SharedString::from("A")]);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            let visible = shell.sidebar_visible_order(cx);
            assert!(visible.contains(&"peer".into()));
            assert!(!visible.contains(&"target".into()));
            shell.open_new_session(cx);
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(&shell.chat_tab_labels(cx)[..1], labels.as_slice());
            assert_ne!(shell.chat_tabs[0].id, shell.chat_tabs[1].id);
            assert_eq!(shell.chat_tabs[0].project, shell.chat_tabs[1].project);
            assert_eq!(shell.state.read(cx).selected_space.as_deref(), Some("a"));
        })
        .unwrap();
}

#[gpui::test]
fn project_switch_restores_split_selection_and_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, true, None);
    window
        .update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.persist_chat_tabs(cx);
            let split = shell.chat_split.clone();
            shell.open_project_tab(Some("b".into()), cx);
            shell.open_chat_preserving_tabs("target".into(), cx);
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(shell.settings.space_filter.as_deref(), Some("b"));
            shell.open_project_tab(Some("a".into()), cx);
            assert_eq!(shell.chat_split, split);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            shell.open_project_tab(Some("b".into()), cx);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("target")
            );
            shell.open_new_session(cx);
            shell.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "An unsent draft".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            let draft = shell.current_canvas_draft(cx);
            shell.open_project_tab(Some("a".into()), cx);
            shell.open_project_tab(Some("b".into()), cx);
            assert_eq!(shell.current_canvas_draft(cx), draft);
            assert!(shell.state.read(cx).selected_chat.is_none());
        })
        .unwrap();
}

#[gpui::test]
fn project_close_preserves_conversations_and_reopens_empty_projects(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    cx.update(|cx| settings::set_archive_sessions_on_close(true, cx));
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.open_project_tab(Some("empty".into()), cx);
            assert!(shell.close_chat_tab(window, cx));
            assert!(shell.reopen_closed_chat_tab(window, cx));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("empty"));
            assert!(shell.state.read(cx).selected_chat.is_none());
            assert!(shell.close_chat_tab(window, cx));
            assert!(shell.close_chat_tab(window, cx));
            assert!(shell.state.read(cx).chats.iter().all(|chat| !chat.archived));
            assert!(shell.sidebar_visible_order(cx).is_empty());
            assert!(shell.restore_project_tabs(cx));
            assert!(shell.state.read(cx).selected_chat.is_none());
            assert_eq!(shell.chat_tabs.len(), 1);
            assert!(shell.chat_tabs[0].project.is_none());
            assert!(shell.reopen_closed_chat_tab(window, cx));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            shell.open_project_tab(Some("a".into()), cx);
            assert_eq!(
                shell
                    .chat_tabs
                    .iter()
                    .filter(|tab| tab.project.as_deref() == Some("a"))
                    .count(),
                1
            );
        })
        .unwrap();
}

#[gpui::test]
fn project_restore_preserves_distinct_legacy_tabs_and_unresolved_projects(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.settings.chat_tabs = [
                ("a", Some("current")),
                ("b", Some("target")),
                ("a", Some("peer")),
                ("empty", None),
                ("deleted", None),
            ]
            .map(|(project, selected)| settings::SavedChatTab {
                project: Some(project.into()),
                selected: selected.map(str::to_owned),
                layout: None,
                ..Default::default()
            })
            .into();
            shell.settings.chat_tab = 2;
            assert!(shell.restore_project_tabs(cx));
            assert_eq!(shell.chat_tabs.len(), 5);
            assert_eq!(shell.chat_tabs[0].project, shell.chat_tabs[2].project);
            assert_ne!(shell.chat_tabs[0].id, shell.chat_tabs[2].id);
            assert_eq!(shell.chat_tabs[4].project.as_deref(), Some("deleted"));
            assert_eq!(shell.chat_tab, 2);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert_eq!(shell.settings.chat_tabs.len(), 5);
            shell.open_project_tab(Some("empty".into()), cx);
            let saved = shell.settings.chat_tabs.clone();
            shell.chat_tabs.clear();
            assert!(shell.restore_project_tabs(cx));
            assert_eq!(shell.settings.chat_tabs, saved);
            assert_eq!(shell.settings.space_filter.as_deref(), Some("empty"));
        })
        .unwrap();
}

#[gpui::test]
fn project_picker_opens_without_creating_a_conversation(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            let chats = shell.state.read(cx).chats.clone();
            shell.open_spaces_menu(window, cx);
            assert!(shell.spaces_menu.is_open());
            assert_eq!(shell.state.read(cx).chats, chats);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            shell.open_project_tab(Some("b".into()), cx);
            assert!(!shell.spaces_menu.is_open());
            assert_eq!(shell.chat_tabs.len(), 2);
            shell.open_project_tab(Some("b".into()), cx);
            assert_eq!(shell.chat_tabs.len(), 2);
        })
        .unwrap();
}

#[gpui::test]
fn project_close_reorder_and_reopen_follow_visit_history(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.open_project_tab(Some("b".into()), cx);
            shell.open_project_tab(Some("a".into()), cx);
            shell.open_project_tab(Some("empty".into()), cx);
            shell.move_chat_tab(0, 2, cx); // B, Empty, A
            assert!(shell.close_chat_tab(window, cx));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            assert!(shell.reopen_closed_chat_tab(window, cx));
            assert_eq!(
                shell.chat_tab_labels(cx),
                ["B", "EMPTY", "A"].map(SharedString::from)
            );
            assert!(shell.close_chat_tab_at(0, window, cx));
            assert!(shell.close_chat_tab(window, cx));
            assert!(shell.reopen_closed_chat_tab(window, cx));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("empty"));
            assert!(shell.reopen_closed_chat_tab(window, cx));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("b"));
            assert!(!shell.reopen_closed_chat_tab(window, cx));
        })
        .unwrap();
}

#[gpui::test]
fn disconnected_delete_preserves_conversation_selection_and_project(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window.update(cx, |shell, window, cx| {
        shell.boot_restored = true;
        shell.open_chat_preserving_tabs("target".into(), cx);
        shell.delete_chat("target".into(), window, cx);
    }).unwrap();
    cx.run_until_parked();
    window.update(cx, |shell, _, cx| {
        assert_eq!(shell.chat_tabs.len(), 2);
        assert_eq!(shell.settings.space_filter.as_deref(), Some("b"));
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("target"));
        assert!(shell.state.read(cx).chats.iter().any(|chat| chat.id == "target"));
        assert!(shell.sidebar_notice.as_deref().unwrap().contains("Engine not connected"));
    }).unwrap();
}
