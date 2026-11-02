use super::*;
use crate::shell::chat_tabs::ChatTab;

fn visible_order(shell: &Shell, cx: &App) -> Vec<String> {
    shell
        .overview_sessions(cx)
        .into_iter()
        .map(|session| session.id)
        .collect()
}

fn install_sessions(shell: &mut Shell) {
    shell.chat_tabs = [
        ("one", Some("a"), Some("current")),
        ("two", Some("a"), Some("peer")),
        ("three", Some("b"), Some("target")),
        ("empty", None, None),
    ]
    .into_iter()
    .map(|(id, project, selected)| ChatTab {
        id: id.into(),
        title: Some(id.into()),
        project: project.map(String::from),
        selected: selected.map(String::from),
        ..Default::default()
    })
    .collect();
    shell.chat_tab = 0;
}

#[gpui::test]
fn overview_reorder_moves_independent_sessions_without_navigation(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            install_sessions(shell);
            shell.settings.session_overview_order = vec![Some("closed".into())];
            shell.open_session_overview(window, cx);
            shell.session_overview_runtime.sessions = visible_order(shell, cx);
            assert_eq!(visible_order(shell, cx), ["one", "two", "three", "empty"]);
            let active_id = shell.chat_tabs[shell.chat_tab].id.clone();
            let selected = shell.state.read(cx).selected_chat.clone();
            let split = shell.chat_split.clone();
            let draft = shell.current_canvas_draft(cx);

            shell.move_overview_session("one", "three", cx);
            assert_eq!(visible_order(shell, cx), ["two", "three", "one", "empty"]);
            shell.move_overview_session("empty", "two", cx);
            let order = vec![
                "empty".to_owned(),
                "two".to_owned(),
                "three".to_owned(),
                "one".to_owned(),
            ];
            assert_eq!(visible_order(shell, cx), order);
            assert_eq!(
                shell
                    .chat_tabs
                    .iter()
                    .map(|tab| tab.id.clone())
                    .collect::<Vec<_>>(),
                order
            );
            assert_eq!(
                shell.settings.session_overview_order,
                ["empty", "two", "three", "one", "closed"].map(|id| Some(id.into()))
            );
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, active_id);
            assert_eq!(shell.state.read(cx).selected_chat, selected);
            assert_eq!(shell.chat_split, split);
            assert_eq!(shell.current_canvas_draft(cx), draft);

            shell.close_session_overview(window, cx);
            assert!(shell.session_overview_runtime.sessions.is_empty());
            shell.open_session_overview(window, cx);
            assert_eq!(visible_order(shell, cx), order);
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, active_id);
            assert_eq!(shell.state.read(cx).selected_chat, selected);
        })
        .unwrap();
}

#[gpui::test]
fn overview_reorder_preserves_legacy_display_order_and_persists_the_shared_order(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            install_sessions(shell);
            shell.chat_tab_history = vec![2, 1];
            shell.settings.session_overview_order = ["three", "two", "one", "empty"]
                .map(|id| Some(id.into()))
                .into();
            shell.open_session_overview(window, cx);
            assert_eq!(visible_order(shell, cx), ["three", "two", "one", "empty"]);
            let active = shell.chat_tabs[shell.chat_tab].id.clone();
            let draft = shell.current_canvas_draft(cx);

            shell.move_overview_session("three", "two", cx);
            let expected = ["two", "three", "one", "empty"];
            assert_eq!(visible_order(shell, cx), expected);
            assert_eq!(
                shell
                    .workspace_session_sidebar_rows(cx)
                    .iter()
                    .map(|row| row.id.as_str())
                    .collect::<Vec<_>>(),
                expected
            );
            assert_eq!(
                shell
                    .settings
                    .chat_tabs
                    .iter()
                    .map(|tab| tab.id.as_str())
                    .collect::<Vec<_>>(),
                expected
            );
            assert_eq!(
                shell.settings.session_overview_order,
                expected.map(|id| Some(id.into()))
            );
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, active);
            assert_eq!(
                shell
                    .chat_tab_history
                    .iter()
                    .map(|ix| shell.chat_tabs[*ix].id.as_str())
                    .collect::<Vec<_>>(),
                ["three", "two"]
            );
            assert_eq!(shell.current_canvas_draft(cx), draft);
            shell.close_session_overview(window, cx);
            shell.open_session_overview(window, cx);
            assert_eq!(visible_order(shell, cx), expected);
        })
        .unwrap();
}

#[gpui::test]
fn overview_reorder_ignores_invalid_targets_and_modal_background_drops(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            install_sessions(shell);
            shell.open_session_overview(window, cx);
            shell.session_overview_runtime.sessions = visible_order(shell, cx);
            let before = visible_order(shell, cx);
            let saved = shell.settings.session_overview_order.clone();
            for (from, to) in [("one", "one"), ("missing", "one"), ("one", "missing")] {
                shell.move_overview_session(from, to, cx);
                assert_eq!(visible_order(shell, cx), before);
                assert_eq!(shell.settings.session_overview_order, saved);
            }
            shell.session_overview_runtime.question = Some(OverviewQuestion {
                chat: "current".into(),
                request: None,
                focus_pending: false,
            });
            shell.move_overview_session("two", "one", cx);
            assert_eq!(visible_order(shell, cx), before);
            assert_eq!(shell.settings.session_overview_order, saved);
        })
        .unwrap();
}

#[gpui::test]
fn overview_new_sessions_append_and_same_project_sessions_stay_distinct(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            install_sessions(shell);
            shell.chat_tabs.truncate(1);
            shell.settings.session_overview_order = vec![Some("later".into()), Some("one".into())];
            shell.open_session_overview(window, cx);
            shell.session_overview_runtime.sessions = visible_order(shell, cx);
            assert_eq!(visible_order(shell, cx), ["one"]);
            shell.chat_tabs.push(ChatTab {
                id: "later".into(),
                title: Some("Another task".into()),
                project: Some("a".into()),
                selected: Some("peer".into()),
                ..Default::default()
            });
            assert_eq!(
                visible_order(shell, cx),
                ["one", "later"],
                "new sessions append instead of moving existing cards"
            );
            let sessions = shell.overview_sessions(cx);
            assert_eq!(sessions.len(), 2);
            assert_eq!(
                sessions[0]
                    .threads
                    .iter()
                    .map(|thread| thread.id.as_str())
                    .collect::<Vec<_>>(),
                ["current"]
            );
            assert_eq!(
                sessions[1]
                    .threads
                    .iter()
                    .map(|thread| thread.id.as_str())
                    .collect::<Vec<_>>(),
                ["peer"]
            );
            assert_eq!(sessions[1].name, "Another task");
            shell.session_overview_runtime.sessions = visible_order(shell, cx);
            shell.move_overview_session("later", "one", cx);
            assert_eq!(visible_order(shell, cx), ["later", "one"]);
        })
        .unwrap();
}

#[gpui::test]
fn overview_saved_order_never_admits_closed_sessions_or_unrelated_project_chats(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            install_sessions(shell);
            shell.chat_tabs.truncate(1);
            shell.settings.session_overview_order = vec![
                Some("closed".into()),
                None,
                Some("one".into()),
                Some("closed".into()),
            ];
            shell.state.update(cx, |state, _| {
                state.sessions.push(harness_proto::Session {
            last_completed_peer_only: false,
                    chat_id: "target".into(),
                    device_id: "local".into(),
                    status: harness_proto::SessionStatus::Working,
                    started_at: Some(Utc::now()),
                    updated_at: Utc::now(),
                    last_completed_turn: None,
                })
            });
            shell.open_session_overview(window, cx);
            assert_eq!(visible_order(shell, cx), ["one"]);
            assert!(
                shell.overview_sessions(cx)[0]
                    .threads
                    .iter()
                    .all(|thread| thread.id != "target")
            );
        })
        .unwrap();
}

#[test]
fn overview_reorder_settings_round_trip_keeps_session_ids_and_legacy_nulls() {
    let mut settings = crate::settings::UiSettings::default();
    settings.session_overview_order =
        vec![Some("session-two".into()), None, Some("session-one".into())];
    let encoded = serde_json::to_value(&settings).unwrap();
    assert_eq!(
        encoded["sessionOverviewOrder"],
        serde_json::json!(["session-two", null, "session-one"])
    );
    let restored: crate::settings::UiSettings = serde_json::from_value(encoded).unwrap();
    assert_eq!(
        restored.session_overview_order,
        settings.session_overview_order
    );
    let legacy: crate::settings::UiSettings = serde_json::from_str("{}").unwrap();
    assert!(legacy.session_overview_order.is_empty());
}
