use super::*;

/// A Ready shell with `count` sessions in the sidebar, `working` among them
/// running, in a window `height` tall, settled.
pub(super) fn sidebar_shell<'a>(
    cx: &'a mut gpui::TestAppContext,
    count: usize,
    working: Option<&str>,
    height: f32,
) -> (
    tempfile::TempDir,
    Entity<Shell>,
    &'a mut gpui::VisualTestContext,
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
        // The conversation sidebar, as people get it; test builds default to task view.
        let mut settings = settings::UiSettings::expanded();
        settings.sidebar_task_view = false;
        settings::init(settings, dir.path(), cx);
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
    let now = Utc::now();
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, _| {
            state.workspace_scope = Some(WorkspaceScope::Local);
            state.local_device_id = Some("local".into());
            state.chats_synced = true;
            state.chats = (0..count)
                .map(|i| {
                    serde_json::from_value(serde_json::json!({
                        "id": format!("chat-{i}"), "title": format!("Chat number {i}"),
                        "deviceId": "local", "archived": false,
                        "createdAt": "2026-09-20T00:00:00Z"
                    }))
                    .unwrap()
                })
                .collect();
            state.sessions = working
                .into_iter()
                .map(|chat_id| harness_proto::Session {
                    last_completed_turn: None,
                    last_completed_peer_only: false,
                    chat_id: chat_id.into(),
                    device_id: "local".into(),
                    status: harness_proto::SessionStatus::Working,
                    started_at: Some(now),
                    updated_at: now,
                })
                .collect();
        });
        shell.debug_gate = Some(GatePhase::Ready);
        // The boot splash has its own spinner; a running app is past it.
        shell.splash = SplashPhase::Gone;
        cx.notify();
    });
    cx.simulate_resize(gpui::size(px(1200.0), px(height)));
    // Let the sidebar's open animation settle: a moving width re-renders it.
    for _ in 0..3 {
        cx.executor().advance_clock(Duration::from_secs(2));
        cx.run_until_parked();
    }
    (dir, shell, cx)
}

/// A working chat's spinner animates without re-rendering the sidebar: its
/// ticks reach only the motion view beside it (`sidebar_motion.rs`).
#[gpui::test]
fn a_working_chat_spinner_animates_without_re_rendering_the_sidebar(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = sidebar_shell(cx, 50, Some("chat-3"), 800.0);
    let slots = shell.read_with(cx, |shell, _| shell.sidebar_motion_slots.clone());
    assert_eq!(
        slots.borrow().len(),
        1,
        "the working row placed its spinner slot"
    );

    let before = crate::shell::SIDEBAR_RENDERS.with(|n| n.get());
    assert!(before > 0, "the window drew the sidebar");
    // Twenty-odd spinner ticks (15Hz).
    for _ in 0..12 {
        cx.executor().advance_clock(Duration::from_millis(130));
        cx.run_until_parked();
    }
    // The shell's once-a-second heartbeat (and a minute rollover) may land in
    // this window and refresh the sidebar; the spinner itself ticks ~20 times
    // and, drawn inside the sidebar, re-rendered it on most of them.
    let renders = crate::shell::SIDEBAR_RENDERS.with(|n| n.get()) - before;
    assert!(
        renders <= 2,
        "spinner ticks re-rendered the sidebar {renders} times"
    );
    assert_eq!(
        slots.borrow().len(),
        1,
        "the slot stays while the sidebar is cached"
    );
}

/// `debug_bounds` takes a `'static` selector.
fn selector(name: String) -> &'static str {
    Box::leak(name.into_boxed_str())
}

/// Rows far outside the session list render as empty slots of their height,
/// so a sidebar rebuild (a scroll, an agent update) costs the rows on screen,
/// not every session; scrolling brings real rows in, never blank ones.
#[gpui::test]
fn far_off_screen_sidebar_rows_are_slots_until_scrolled_into_view(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = sidebar_shell(cx, 200, None, 700.0);
    shell.update(cx, |shell, cx| {
        shell
            .sidebar_unfolded_groups
            .insert("project:home:local".into());
        cx.notify();
    });
    // The sidebar is a cached view: re-render it, as a sidebar update would,
    // so this frame's rows are the ones queried.
    let built = |cx: &mut gpui::VisualTestContext| {
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
        (0..200)
            .filter(|i| {
                cx.debug_bounds(selector(format!("chat-chat-{i}")))
                    .is_some()
            })
            .collect::<Vec<_>>()
    };
    let slots = |cx: &mut gpui::VisualTestContext| {
        (0..200)
            .filter(|i| {
                cx.debug_bounds(selector(format!("session-slot-chat-{i}")))
                    .is_some()
            })
            .count()
    };
    let rows = built(cx);
    assert_eq!(slots(cx), 200, "every session keeps its slot");
    assert!(
        rows.len() < 100,
        "built {} of 200 rows with ~15 on screen",
        rows.len()
    );
    let viewport = shell.read_with(cx, |shell, _| shell.sidebar_scroll.bounds());
    let on_screen = |cx: &mut gpui::VisualTestContext| {
        (0..200)
            .filter(|i| {
                cx.debug_bounds(selector(format!("session-slot-chat-{i}")))
                    .is_some_and(|b| b.bottom() > viewport.top() && b.top() < viewport.bottom())
            })
            .collect::<Vec<_>>()
    };
    let visible = on_screen(cx);
    let mut top_rows = visible.clone();
    assert!(!visible.is_empty());
    for i in &visible {
        assert!(rows.contains(i), "row {i} is on screen but blank");
    }

    // Jump to the end, as a fast scroll does, and let the sidebar re-render.
    shell.update(cx, |shell, cx| {
        let max = shell.sidebar_scroll.max_offset().y;
        shell.sidebar_scroll.set_offset(gpui::point(px(0.0), -max));
        shell.sidebar_pane.update(cx, |_, cx| cx.notify());
    });
    cx.run_until_parked();
    let rows = built(cx);
    let rows = if on_screen(cx).iter().all(|i| rows.contains(i)) {
        rows
    } else {
        // A skipped slot found on screen asks for one more frame.
        cx.run_until_parked();
        built(cx)
    };
    let visible = on_screen(cx);
    let at_top = std::mem::take(&mut top_rows);
    assert!(
        visible.iter().all(|i| !at_top.contains(i)),
        "scrolled to the end: {visible:?}"
    );
    for i in &visible {
        assert!(
            rows.contains(i),
            "row {i} is on screen but blank after the scroll"
        );
    }
}
