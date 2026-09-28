use super::*;
use gpui::{TestAppContext, WindowHandle};
use harness_proto::{Chat, HarnessId, Space};

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
        settings::init(settings::UiSettings::default(), dir, cx);
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
                default_harness: HarnessId::Mock,
            },
            cx,
        );
        shell.space_boot_applied = true;
        shell.state.update(cx, |state, _| {
            state.apply_spaces(vec![space("active"), space("other")]);
        });
        shell
    })
}

fn space(id: &str) -> Space {
    Space {
        id: id.into(),
        device_id: "local".into(),
        path: format!("/projects/{id}"),
        name: None,
        git_detected: false,
        git_checked_at: None,
        checkout_id: None,
        created_at: Utc::now(),
    }
}

fn chat(project: Option<&str>) -> Chat {
    Chat {
        last_prompt_at: None,
        id: "original".into(),
        device_id: "local".into(),
        title: None,
        archived: false,
        cwd: project.map(|p| format!("/projects/{p}")),
        branch: None,
        checkout_id: None,
        source_context: None,
        config: None,
        last_message_preview: None,
        last_message_at: None,
        created_at: Utc::now(),
        harness_session_id: None,
        harness_session_cwd: None,
        parent_chat_id: None,
        space_id: project.map(str::to_owned),
        last_seen_at: None,
        room_gen: None,
    }
}

#[gpui::test]
fn split_inherits_active_session_project_not_global_picker(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let window = setup(cx, dir.path());
    window
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats = vec![chat(Some("active"))];
                state.select_chat(Some("original".into()), cx);
                // Project selection is global; it can differ from the open session.
                state.select_space(Some("other".into()), cx);
            });
            shell.split_chat(SplitAxis::Horizontal, window, cx);
            let state = shell.state.read(cx);
            assert!(
                state.selected_chat.is_none(),
                "the split must be a fresh conversation"
            );
            assert_eq!(state.selected_space.as_deref(), Some("active"));
            assert!(!state.no_project);
            assert_eq!(state.chats.len(), 1);
            assert_eq!(state.chats[0].space_id.as_deref(), Some("active"));
            assert_eq!(
                shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                Some("original")
            );
            shell.focus_chat_pane(0, window, cx);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("original")
            );
            shell.focus_chat_pane(1, window, cx);
            assert_eq!(
                shell.state.read(cx).selected_space.as_deref(),
                Some("active")
            );
        })
        .unwrap();
}

#[gpui::test]
fn split_from_canvas_keeps_its_folder_or_unselected_fallback(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let window = setup(cx, dir.path());
    window
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, cx| {
                state.select_space(Some("active".into()), cx)
            });
            shell.split_chat(SplitAxis::Horizontal, window, cx);
            assert_eq!(
                shell.state.read(cx).selected_space.as_deref(),
                Some("active")
            );
            shell.state.update(cx, |state, _| {
                state.selected_space = None;
                state.no_project = false;
            });
            shell.split_chat(SplitAxis::Horizontal, window, cx);
            assert!(shell.state.read(cx).selected_chat.is_none());
            assert!(shell.state.read(cx).selected_space.is_none());
            assert!(!shell.state.read(cx).no_project);
        })
        .unwrap();
}

#[gpui::test]
fn split_from_projectless_session_does_not_inherit_another_folder(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let window = setup(cx, dir.path());
    window
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats = vec![chat(None)];
                state.select_chat(Some("original".into()), cx);
                state.select_space(Some("other".into()), cx);
            });
            shell.split_chat(SplitAxis::Horizontal, window, cx);
            assert!(shell.state.read(cx).selected_chat.is_none());
            assert!(shell.state.read(cx).selected_space.is_none());
            assert!(shell.state.read(cx).no_project);
        })
        .unwrap();
}
