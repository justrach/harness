use super::*;

/// A settled shell with fifty chats in the sidebar and one open.
pub(super) fn shell_with_chats<'a>(
    cx: &'a mut gpui::TestAppContext,
    dir: &tempfile::TempDir,
) -> (Entity<Shell>, &'a mut gpui::VisualTestContext) {
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
        settings::init(settings::UiSettings::expanded(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
    });
    let data_dir = dir.path().to_path_buf();
    let (shell, cx) = cx.add_window_view(|_, cx| {
        let state = cx.new(|_| AppState::new());
        Shell::new(
            state,
            EngineBootConfig {
                data_dir,
                ipc_port: 0,
                edge_url: "http://127.0.0.1:1".into(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: harness_proto::HarnessId::Mock,
            },
            cx,
        )
    });
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, cx| {
            state.workspace_scope = Some(WorkspaceScope::Local);
            state.local_device_id = Some("local".into());
            state.chats_synced = true;
            state.no_project = true;
            state.chats = (0..50)
                .map(|i| {
                    serde_json::from_value(serde_json::json!({
                        "id": format!("chat-{i}"), "title": format!("Chat number {i}"),
                        "deviceId": "local", "archived": false,
                        "createdAt": "2026-09-20T00:00:00Z"
                    }))
                    .unwrap()
                })
                .collect();
            state.select_chat(Some("chat-3".into()), cx);
        });
        shell.debug_gate = Some(GatePhase::Ready);
        shell.splash = SplashPhase::Gone;
        cx.notify();
    });
    cx.simulate_resize(gpui::size(px(1200.0), px(800.0)));
    for _ in 0..3 {
        cx.executor().advance_clock(Duration::from_secs(2));
        cx.run_until_parked();
    }
    (shell, cx)
}

/// Typing in the composer redraws the composer, not the app: no shell or
/// app-state notification, and no sidebar rebuild per keystroke (the sidebar
/// re-renders on every shell notification and costs the most to rebuild).
#[gpui::test]
fn typing_in_the_composer_leaves_the_shell_and_sidebar_alone(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    cx.update(|window, cx| {
        let focus = shell.read(cx).composer.focus_handle(cx);
        window.focus(&focus, cx);
    });
    // Establish keyboard focus styling before measuring keystroke invalidation.
    cx.simulate_keystrokes("right");
    cx.run_until_parked();
    let state = shell.read_with(cx, |shell, _| shell.state.clone());
    let notified = std::rc::Rc::new(std::cell::Cell::new(0usize));
    let _subs = cx.update(|_, cx| {
        let shell_count = notified.clone();
        let state_count = notified.clone();
        [
            cx.observe(&shell, move |_, _| shell_count.set(shell_count.get() + 1)),
            cx.observe(&state, move |_, _| state_count.set(state_count.get() + 1)),
        ]
    });
    let before = crate::shell::SIDEBAR_RENDERS.with(|n| n.get());
    for ch in "hello world".chars() {
        cx.simulate_input(&ch.to_string());
        cx.run_until_parked();
    }
    // Debounced draft saves and the like.
    cx.executor().advance_clock(Duration::from_secs(2));
    cx.run_until_parked();
    assert_eq!(
        notified.get(),
        0,
        "a keystroke notified the shell or app state"
    );
    // The first character can flip the row's draft state, and the shell's
    // once-a-second heartbeat (or a minute rollover) may land in the window;
    // eleven keys must not mean eleven rebuilds.
    let renders = crate::shell::SIDEBAR_RENDERS.with(|n| n.get()) - before;
    assert!(
        renders <= 3,
        "typing re-rendered the sidebar {renders} times"
    );
}

/// An old engine is only worth noticing if the person can see it was noticed.
#[gpui::test]
fn an_older_engine_shows_in_the_sidebar(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    assert!(cx.debug_bounds("sidebar-notice").is_none());
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, cx| {
            state.engine_notice = Some("The engine is old".into());
            cx.notify();
        });
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.sidebar_notice.as_deref(), Some("The engine is old"));
        assert_eq!(shell.state.read(cx).engine_notice, None, "shown once");
    });
}

/// A tap that does nothing has to say why.
#[gpui::test]
fn the_hold_to_quit_hint_shows_during_a_hold(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (_shell, cx) = shell_with_chats(cx, &dir);
    assert!(cx.debug_bounds("quit-hold-hint").is_none());
    cx.update(|_, cx| crate::quit_hold::begin(cx, || true, |_| {}));
    cx.run_until_parked();
    assert!(cx.debug_bounds("quit-hold-hint").is_some());
    for _ in 0..60 {
        cx.executor().advance_clock(Duration::from_millis(30));
        cx.run_until_parked();
    }
    assert!(cx.debug_bounds("quit-hold-hint").is_none());
}
