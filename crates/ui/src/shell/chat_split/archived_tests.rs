//! Archived sessions keep their panes (#489): viewing one is not reprompting it.

use super::*;
use gpui::{TestAppContext, WindowHandle};

fn setup(cx: &mut TestAppContext, dir: &std::path::Path) -> WindowHandle<Shell> {
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
        settings::init(settings::UiSettings::expanded(), dir, cx);
    });
    cx.add_window(|_, cx| {
        let state = cx.new(|_| AppState::new());
        let mut shell = Shell::new(
            state,
            EngineBootConfig {
                data_dir: dir.into(),
                ipc_port: 0,
                edge_url: "http://127.0.0.1:1".into(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: harness_proto::HarnessId::Mock,
            },
            cx,
        );
        shell.route = Route::Chat;
        shell
    })
}

fn chats(archived: &[&str]) -> Vec<harness_proto::Chat> {
    ["live", "old"]
        .map(|id| {
            serde_json::from_value(serde_json::json!({
                "id": id, "deviceId": "local", "title": id,
                "archived": archived.contains(&id), "createdAt": Utc::now(),
            }))
            .unwrap()
        })
        .into()
}

/// A chats frame (or any other state change) reaches the split.
fn sync(window: WindowHandle<Shell>, cx: &mut TestAppContext, archived: &[&str]) {
    window
        .update(cx, |shell, _, cx| {
            shell.state.update(cx, |state, cx| {
                state.apply_chats(chats(archived));
                cx.notify();
            });
        })
        .unwrap();
    cx.run_until_parked();
}

#[gpui::test]
fn an_archived_session_keeps_its_pane_after_a_split(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let window = setup(cx, dir.path());
    sync(window, cx, &["old"]);
    window
        .update(cx, |shell, window, cx| {
            shell.open_chat_preserving_tabs("old".into(), cx);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("old"));
            // ⌘D: the archived session parks in the pane it leaves.
            shell.split_chat(SplitAxis::Horizontal, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    for _ in 0..3 {
        sync(window, cx, &["old"]);
        window
            .update(cx, |shell, _, cx| {
                let split = shell.chat_split.as_ref().expect("split");
                assert_eq!(
                    split.panes[0].as_deref(),
                    Some("old"),
                    "the pane still shows it"
                );
                assert!(shell.select_chat_pane(0, cx));
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("old"),
                    "reactivating the pane shows the archived session, not a new one"
                );
            })
            .unwrap();
        sync(window, cx, &["old"]);
        window
            .update(cx, |shell, _, cx| {
                assert!(shell.select_chat_pane(1, cx));
                assert_eq!(shell.state.read(cx).selected_chat, None);
            })
            .unwrap();
    }
    // Away to another tab and back: the tab's split still holds it.
    let tab = window
        .update(cx, |shell, window, cx| {
            let tab = shell.chat_tab;
            shell.new_chat_tab(None, window, cx);
            tab
        })
        .unwrap();
    sync(window, cx, &["old"]);
    window
        .update(cx, |shell, window, cx| {
            shell.switch_chat_tab(tab, window, cx)
        })
        .unwrap();
    sync(window, cx, &["old"]);
    window
        .update(cx, |shell, _, cx| {
            let split = shell.chat_split.as_ref().expect("the tab's split");
            assert_eq!(split.panes[0].as_deref(), Some("old"));
            let state = shell.state.read(cx);
            assert_eq!(state.chats.len(), 2, "no replacement session");
            assert!(
                state
                    .chats
                    .iter()
                    .any(|chat| chat.id == "old" && chat.archived)
            );
            assert!(
                state.visible_chats().all(|chat| chat.id != "old"),
                "still archived"
            );
        })
        .unwrap();
}

#[gpui::test]
fn archiving_a_session_shown_in_another_pane_still_closes_it(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let window = setup(cx, dir.path());
    sync(window, cx, &["old"]);
    window
        .update(cx, |shell, window, cx| {
            shell.open_chat_preserving_tabs("live".into(), cx);
            shell.split_chat(SplitAxis::Horizontal, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    sync(window, cx, &["old"]);
    window
        .update(cx, |shell, _, _| {
            assert_eq!(
                shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                Some("live")
            );
        })
        .unwrap();
    // Archived from the sidebar (or elsewhere) while it sits in that pane.
    sync(window, cx, &["old", "live"]);
    window
        .update(cx, |shell, _, _| {
            assert_eq!(shell.chat_split.as_ref().unwrap().panes[0], None);
        })
        .unwrap();
}
