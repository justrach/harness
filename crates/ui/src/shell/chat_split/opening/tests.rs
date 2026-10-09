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

/// A chats frame that briefly drops the dragged session cancels the sidebar's
/// reorder preview mid-drag. The split drop zones used to go with it, so the
/// drop landed on nothing and the session never opened.
#[gpui::test]
fn a_sidebar_drop_still_splits_after_a_mid_drag_chats_frame(cx: &mut TestAppContext) {
    struct Host(Entity<Shell>);
    impl Render for Host {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            self.0.update(cx, |shell, cx| {
                let theme = Theme::default();
                div()
                    .size_full()
                    .flex()
                    .flex_row()
                    .on_drop::<SidebarSessionDrag>(
                        cx.listener(|shell, _, _, cx| shell.cancel_sidebar_session_transfer(cx)),
                    )
                    .child(
                        div()
                            .w(px(280.0))
                            .h_full()
                            .child(shell.render_chat_sidebar(&theme, cx)),
                    )
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .h_full()
                            .children(shell.render_split_drop_zones(&theme, cx)),
                    )
            })
        }
    }
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
        settings::init(settings::UiSettings::default(), dir.path(), cx);
    });
    let named = |id: &str| Chat {
        id: id.into(),
        title: Some(id.into()),
        ..chat(None)
    };
    let (host, cx) = cx.add_window_view(|_, cx| {
        Host(cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            let shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: dir.path().into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: HarnessId::Mock,
                },
                cx,
            );
            shell.state.update(cx, |state, cx| {
                state.workspace_scope = Some(WorkspaceScope::Local);
                state.local_device_id = Some("local".into());
                state.chats = vec![named("open"), named("dragged")];
                state.select_chat(Some("open".into()), cx);
            });
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());

    let from = cx.debug_bounds("chat-dragged").unwrap().center();
    cx.simulate_mouse_down(from, MouseButton::Left, gpui::Modifiers::default());
    cx.simulate_mouse_move(
        from + gpui::point(px(8.0), px(0.0)),
        Some(MouseButton::Left),
        gpui::Modifiers::default(),
    );
    assert!(cx.debug_bounds("chat-drop-right").is_some());

    // The session drops out of one chats frame and comes back in the next.
    shell.update(cx, |shell, cx| {
        shell
            .state
            .update(cx, |state, _| state.chats.retain(|c| c.id != "dragged"));
    });
    cx.simulate_mouse_move(from, Some(MouseButton::Left), gpui::Modifiers::default());
    shell.update(cx, |shell, cx| {
        assert!(
            shell.sidebar_session_transfer.is_none(),
            "the reorder preview ended"
        );
        shell
            .state
            .update(cx, |state, _| state.chats.push(named("dragged")));
    });

    let target = cx.debug_bounds("chat-drop-right").unwrap().center();
    cx.simulate_mouse_move(target, Some(MouseButton::Left), gpui::Modifiers::default());
    cx.simulate_mouse_up(target, MouseButton::Left, gpui::Modifiers::default());
    shell.update(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("dragged")
        );
        let split = shell.chat_split.as_ref().expect("the drop splits");
        assert_eq!(split.panes, vec![Some("open".into()), None]);
        assert!(shell.split_drop_session.is_none());
    });
    assert!(
        cx.debug_bounds("chat-drop-right").is_none(),
        "the zones go with the drag"
    );
}

#[gpui::test]
fn selecting_text_in_an_unfocused_pane_keeps_the_selection(cx: &mut TestAppContext) {
    let _selection = crate::markdown::selection::test_state_lock();
    let dir = tempfile::tempdir().unwrap();
    let window = setup(cx, dir.path());
    window
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats = vec![chat(Some("active"))];
                state.select_chat(Some("original".into()), cx);
            });
            shell.split_chat(SplitAxis::Horizontal, window, cx);
            let focus = shell.chat_split.as_ref().unwrap().focus;
            let other = 1 - focus;

            // A drag in the unfocused pane selected some text: releasing it
            // must not focus (and so rebuild) that pane.
            crate::markdown::selection::begin_with_span("peer-row:0", "copy me", 0..4);
            shell.release_on_peer_pane(other, window, cx);
            assert_eq!(shell.chat_split.as_ref().unwrap().focus, focus, "a text drag must not move focus");
            assert_eq!(crate::markdown::selection::selected_text().as_deref(), Some("copy"));
            crate::markdown::selection::end_active_drag();
            crate::markdown::selection::clear_if_owner("peer-row:0");

            // A plain click (nothing selected) still focuses the pane.
            shell.release_on_peer_pane(other, window, cx);
            assert_eq!(shell.chat_split.as_ref().unwrap().focus, other, "a click focuses the pane");
        })
        .unwrap();
}
