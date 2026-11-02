use super::*;

fn chat(id: &str, title: &str, archived: bool, project: &str) -> Chat {
    serde_json::from_value(serde_json::json!({
        "id": id, "title": title, "deviceId": "local", "spaceId": project,
        "archived": archived, "createdAt": "2026-10-01T00:00:00Z",
    }))
    .unwrap()
}

#[test]
fn sidebar_search_matches_names_and_all_archived_pages() {
    let mut chats: Vec<_> = (0..50)
        .map(|i| chat(&format!("old-{i}"), "Old session", true, "project"))
        .collect();
    chats.push(chat("target", "SÍDEBAR experiments", true, "project"));
    chats.push(chat("active", "Sídebar polish", false, "project"));
    chats.push(chat("metadata", "Unrelated title", false, "sídebar"));
    let find = |include| {
        matching_chats(
            &chats,
            "  síDEBAR  ",
            None,
            include,
            SidebarSort::LastUpdated,
        )
        .into_iter()
        .map(|chat| chat.id.as_str())
        .collect::<Vec<_>>()
    };
    assert_eq!(find(false), ["active"]);
    assert_eq!(find(true), ["active", "target"]);
    assert_eq!(
        matching_chats(&chats, "no such title", None, true, SidebarSort::Created).len(),
        0
    );
}

#[test]
fn sidebar_search_respects_project_top_level_and_sidebar_sort() {
    let mut chats = vec![
        chat("a", "Sidebar first", false, "one"),
        chat("b", "Sidebar second", true, "two"),
        chat("child", "Sidebar child", false, "one"),
    ];
    chats[2].parent_chat_id = Some("a".into());
    chats[1].last_message_at = Some(Utc::now());
    let ids = |project, sort| {
        matching_chats(&chats, "sidebar", project, true, sort)
            .into_iter()
            .map(|chat| chat.id.as_str())
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(None, SidebarSort::LastUpdated), ["b", "a"]);
    assert_eq!(ids(Some("one"), SidebarSort::LastUpdated), ["a"]);
    assert_eq!(ids(None, SidebarSort::Created), ["a", "b"]);
    assert_eq!(
        ids(Some("missing"), SidebarSort::Created),
        Vec::<&str>::new()
    );
}

// GPUI's simulate_keystrokes emits keydown only. Complete each physical
// press so these interaction tests exercise the native release/click path too.
fn press_keys(cx: &mut gpui::VisualTestContext, keys: &str) {
    for key in keys.split(' ') {
        cx.simulate_keystrokes(key);
        cx.update(|window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                    keystroke: Keystroke::parse(key).unwrap(),
                }),
                cx,
            );
        });
    }
    cx.run_until_parked();
}

struct SearchSidebar {
    shell: Entity<Shell>,
    show_conversation: bool,
    _observe: Subscription,
}

impl Render for SearchSidebar {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let show_conversation = self.show_conversation;
        self.shell.update(cx, |shell, cx| {
            shell.focus_sidebar_search(window, cx);
            let theme = Theme::of(cx).clone();
            div()
                .track_focus(&shell.shortcut_focus)
                .w(px(shell.settings.sidebar_width))
                .h(px(650.0))
                .flex()
                .flex_col()
                .capture_key_down(cx.listener(Shell::on_key_down_capture))
                .on_key_down(cx.listener(Shell::on_key_down))
                .on_action(cx.listener(|shell, _: &ToggleSidebar, _, cx| shell.toggle_sidebar(cx)))
                .when(!shell.settings.sidebar_collapsed, |el| {
                    el.child(
                        div()
                            .flex_1()
                            .min_h_0()
                            .child(shell.render_chat_sidebar(&theme, cx)),
                    )
                })
                .when(show_conversation, |el| el.child(shell.composer.clone()))
        })
    }
}

fn fixture(
    cx: &mut gpui::TestAppContext,
    width: f32,
) -> (
    tempfile::TempDir,
    Entity<Shell>,
    &mut gpui::VisualTestContext,
) {
    fixture_with_conversation(cx, width, false)
}

fn fixture_with_conversation(
    cx: &mut gpui::TestAppContext,
    width: f32,
    show_conversation: bool,
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
        settings::init(settings::UiSettings::default(), dir.path(), cx);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        let shell = cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            let mut shell = Shell::new(
                state,
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
            );
            shell.settings.sidebar_width = width;
            shell.settings.space_filter = None;
            shell.state.update(cx, |state, cx| {
                state.workspace_scope = Some(WorkspaceScope::Local);
                state.local_device_id = Some("local".into());
                state.spaces = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "project", "deviceId": "local", "path": "/fixture/project",
                        "createdAt": "2026-10-01T00:00:00Z",
                    }))
                    .unwrap(),
                ];
                state.chats = vec![
                    chat("current", "Current session", false, "project"),
                    chat("active", "Sidebar polish", false, "project"),
                    chat("archived", "Sidebar experiments", true, "project"),
                ];
                state.select_chat(Some("current".into()), cx);
            });
            shell
        });
        let observe = cx.observe(&shell, |_, _, cx| cx.notify());
        SearchSidebar {
            shell,
            show_conversation,
            _observe: observe,
        }
    });
    let shell = host.read_with(cx, |host, _| host.shell.clone());
    (dir, shell, cx)
}

#[gpui::test]
fn sidebar_search_native_controls_and_archived_open(cx: &mut gpui::TestAppContext) {
    for width in [224.0, 400.0] {
        let (_dir, shell, cx) = fixture(cx, width);
        let trigger = cx.debug_bounds("sidebar-search-toggle").unwrap();
        assert!(trigger.right() <= px(width));
        assert!(cx.debug_bounds("sidebar-search-controls").is_none());
        cx.simulate_click(trigger.center(), Default::default());
        cx.run_until_parked();
        assert!(cx.debug_bounds("sidebar-search-controls").is_some());
        let input = shell.read_with(cx, |shell, _| {
            shell.sidebar_search.as_ref().unwrap().input.clone()
        });
        cx.update(|window, cx| {
            assert!(input.focus_handle(cx).is_focused(window));
            input.update(cx, |input, cx| input.set_text("SIDEBAR", cx));
        });
        cx.run_until_parked();
        cx.update(|_, cx| {
            shell.update(cx, |shell, cx| {
                assert_eq!(shell.sidebar_search_ids(cx), ["active"]);
                assert_eq!(shell.sidebar_visible_order(cx), ["active"]);
            })
        });
        let archived_toggle = cx.debug_bounds("sidebar-search-archived").unwrap();
        cx.simulate_click(archived_toggle.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.sidebar_search_ids(cx), ["active", "archived"])
        });
        // Exercise the input's actual event route, not only the filtering helper.
        cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
        press_keys(cx, "down enter");
        cx.run_until_parked();
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
            assert_eq!(
                shell.chat_tabs.len(),
                2,
                "search must preserve the previous session tab"
            );
        });
        cx.update(|window, cx| {
            window.focus(&input.focus_handle(cx), cx);
            input.update(cx, |input, cx| input.set_text("no matches", cx));
        });
        cx.run_until_parked();
        assert!(cx.debug_bounds("sidebar-search-empty").is_some());
        press_keys(cx, "escape");
        cx.run_until_parked();
        assert!(cx.debug_bounds("sidebar-search-empty").is_none());
        shell.read_with(cx, |shell, cx| {
            assert!(!shell.sidebar_search_is_filtering(cx))
        });
        press_keys(cx, "escape");
        cx.run_until_parked();
        assert!(cx.debug_bounds("sidebar-search-controls").is_none());
        cx.update(|window, cx| {
            assert!(
                shell
                    .read(cx)
                    .sidebar_search_trigger_focus
                    .is_focused(window)
            );
            shell.update(cx, |shell, cx| {
                shell.toggle_sidebar_search(window, cx);
                shell.toggle_sidebar(cx);
                assert!(shell.settings.sidebar_collapsed);
                assert!(shell.sidebar_search.is_none());
            });
        });
    }
}

mod edge_cases;
mod keyboard_edges;
mod reported_regressions;
mod shortcut;
