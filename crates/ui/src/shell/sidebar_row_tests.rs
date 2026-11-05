use super::*;
use gpui::{TestAppContext, VisualTestContext};

struct RowHost {
    shell: Entity<Shell>,
    width: f32,
    status: harness_proto::ChatIndicator,
    archived: bool,
    branch_available: bool,
    _dir: tempfile::TempDir,
    _updates: Subscription,
}

impl Render for RowHost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.shell.update(cx, |shell, cx| {
            let branch = (self.branch_available && shell.settings.sidebar_show_branch)
                .then(|| "feature/a-very-long-branch-name-with-日本語".into());
            let harness = shell
                .settings
                .sidebar_show_harness
                .then_some(harness_proto::HarnessId::Graff);
            let row = div().w(px(self.width)).child(shell.render_chat_row(
                "matrix".into(),
                "Review an exceptionally long conversation title 日本語 العربية".into(),
                "12mo".into(),
                "A very long project name @ Review device".into(),
                branch,
                None,
                harness,
                self.status,
                false,
                self.archived,
                false,
                None,
                None,
                None,
                &Theme::default(),
                cx,
            ));
            shell.drive_sidebar_context_motion(window);
            row
        })
    }
}

fn setup(cx: &mut TestAppContext) -> (Entity<RowHost>, &mut VisualTestContext) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        motion::set_reduced_motion(cx, true);
    });
    cx.add_window_view(|_, cx| {
        let shell = cx.new(|cx| {
            let state =
                cx.new(|_| {
                    let mut state = AppState::new();
                    state.local_device_id = Some("fixture-local".into());
                    state.chats = vec![serde_json::from_value(serde_json::json!({
                    "id": "matrix", "deviceId": "fixture-local", "spaceId": "project",
                    "title": "Review the project", "createdAt": Utc::now(), "archived": false,
                    "config": { "harness": "graff", "model": "claude-sonnet-4-6",
                        "reasoning": null, "sandbox": "workspace-write" },
                })).unwrap()];
                    state.spaces = vec![serde_json::from_value(serde_json::json!({
                    "id": "project", "deviceId": "fixture-local", "path": "/fixtures/project",
                    "name": "Review project", "createdAt": Utc::now(),
                })).unwrap()];
                    state
                });
            Shell::new(
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
            )
        });
        let updates = cx.observe(&shell, |_, _, cx| cx.notify());
        RowHost {
            shell,
            width: 220.0,
            status: harness_proto::ChatIndicator::Idle,
            archived: false,
            branch_available: true,
            _updates: updates,
            _dir: dir,
        }
    })
}

#[gpui::test]
fn sidebar_compact_reveal_starts_without_a_jump_and_keeps_exiting_details(cx: &mut TestAppContext) {
    use std::time::{Duration, Instant};

    let (host, cx) = setup(cx);
    cx.run_until_parked();
    let row = cx.debug_bounds("chat-matrix").unwrap();
    let title = cx.debug_bounds("chat-title-matrix").unwrap();
    // Freeze the clock ahead of wall time so geometry samples do not depend
    // on the test machine's frame rate.
    let start = Instant::now() + Duration::from_secs(60);
    cx.update(|_, cx| motion::set_reduced_motion(cx, false));
    host.update(cx, |host, cx| {
        host.shell.update(cx, |shell, cx| {
            shell.chat_status_hover = Some("chat-matrix".into());
            shell
                .sidebar_context_fades
                .borrow_mut()
                .set_at("chat-matrix", true, false, start);
            cx.notify();
        });
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert_eq!(cx.debug_bounds("chat-matrix"), Some(row));
    assert_eq!(
        cx.debug_bounds("chat-title-matrix"),
        Some(title),
        "first frame must not jump"
    );

    host.update(cx, |host, cx| {
        host.shell.update(cx, |shell, cx| {
            shell.chat_status_hover = None;
            shell.sidebar_context_fades.borrow_mut().set_at(
                "chat-matrix",
                false,
                false,
                start + Duration::from_millis(30),
            );
            cx.notify();
        });
    });
    cx.update(|window, cx| window.draw(cx).clear());
    let exiting_title = cx.debug_bounds("chat-title-matrix").unwrap();
    assert_eq!(cx.debug_bounds("chat-matrix"), Some(row));
    assert!(exiting_title.top() < title.top());
    assert!(exiting_title.top() > title.top() - px(6.5));
    assert!(cx.debug_bounds("chat-metadata-matrix").is_some());
    assert!(
        cx.debug_bounds("chat-model-matrix").is_some(),
        "keep the complete line while fading out"
    );

    cx.update(|_, cx| motion::set_reduced_motion(cx, true));
    host.update(cx, |host, cx| host.shell.update(cx, |_, cx| cx.notify()));
    cx.update(|window, cx| window.draw(cx).clear());
    assert_eq!(cx.debug_bounds("chat-title-matrix"), Some(title));
    assert_eq!(cx.debug_bounds("chat-matrix"), Some(row));
    assert!(cx.debug_bounds("chat-metadata-matrix").is_none());
}

#[gpui::test]
fn sidebar_all_display_combinations_preserve_title_metadata_and_live_status(
    cx: &mut TestAppContext,
) {
    use harness_proto::ChatIndicator::*;
    let (host, cx) = setup(cx);
    for width in [220.0, 272.0, 360.0] {
        for mask in 0..32 {
            for status in [Idle, Working, AwaitingInput, Errored, Completed] {
                for archived in [false, true] {
                    host.update(cx, |host, cx| {
                        host.width = width;
                        host.status = status;
                        host.archived = archived;
                        host.shell.update(cx, |shell, cx| {
                            shell.settings.sidebar_compact = false;
                            shell.settings.sidebar_show_harness = mask & 1 != 0;
                            shell.settings.sidebar_show_project_icon = mask & 2 != 0;
                            shell.settings.sidebar_show_project_label = mask & 4 != 0;
                            shell.settings.sidebar_show_branch = mask & 8 != 0;
                            shell.settings.sidebar_show_updated = mask & 16 != 0;
                            shell.chat_status_hover = None;
                            shell.state.update(cx, |state, _| {
                                state.chats[0].device_id =
                                    if archived { "remote" } else { "fixture-local" }.into();
                            });
                            cx.notify();
                        });
                        cx.notify();
                    });
                    cx.run_until_parked();
                    let row = cx.debug_bounds("chat-matrix").unwrap();
                    let title = cx.debug_bounds("chat-title-matrix").unwrap();
                    assert_eq!(row.size.height, px(if mask != 0 { 38.0 } else { 30.0 }));
                    assert!(
                        title.size.width > px(0.0),
                        "title disappeared: {mask}, {width}"
                    );
                    assert!(title.top() >= row.top() && title.bottom() <= row.bottom());
                    for (bit, selector) in [
                        (1, "chat-agent-icon-matrix"),
                        (2, "chat-project-icon-matrix"),
                        (4, "chat-device-matrix"),
                        (8, "chat-branch-matrix"),
                        (16, "chat-time-matrix"),
                    ] {
                        assert_eq!(
                            cx.debug_bounds(selector).is_some(),
                            mask & bit != 0,
                            "{selector}: {mask}"
                        );
                    }
                    if let Some(metadata) = cx.debug_bounds("chat-metadata-matrix") {
                        assert!(metadata.top() >= title.bottom());
                        assert!(metadata.bottom() <= row.bottom());
                    }
                    if let (Some(project), Some(branch)) = (
                        cx.debug_bounds("chat-device-matrix"),
                        cx.debug_bounds("chat-branch-matrix"),
                    ) {
                        assert!(project.size.width > px(0.0) && branch.size.width > px(0.0));
                        assert!(branch.right() <= project.left());
                    }
                    let activity = cx.debug_bounds("chat-status-matrix");
                    assert_eq!(activity.is_some(), status != Idle);
                    if let Some(activity) = activity {
                        assert_eq!(activity.right(), row.right() - px(NAV_ITEM_INSET_X));
                        assert!(title.right() <= activity.left());
                    }
                    let time = cx.debug_bounds("chat-time-matrix");
                    cx.simulate_mouse_move(row.center(), None, Default::default());
                    assert_eq!(cx.debug_bounds("chat-status-matrix"), activity);
                    assert_eq!(cx.debug_bounds("chat-title-matrix"), Some(title));
                    assert_eq!(cx.debug_bounds("chat-time-matrix"), time);
                }
            }
        }
    }
    host.update(cx, |host, cx| {
        host.branch_available = false;
        host.shell.update(cx, |shell, cx| {
            shell.settings.reset_sidebar_display();
            shell.settings.sidebar_compact = false;
            shell.settings.sidebar_show_harness = false;
            shell.settings.sidebar_show_updated = false;
            shell.settings.sidebar_show_branch = true;
            cx.notify();
        });
        cx.notify();
    });
    cx.run_until_parked();
    assert_eq!(
        cx.debug_bounds("chat-matrix").unwrap().size.height,
        px(NAV_ITEM_HEIGHT)
    );
    assert!(cx.debug_bounds("chat-metadata-matrix").is_none());
}

#[gpui::test]
fn sidebar_queued_and_undelivered_activity_stays_visible_on_hover(cx: &mut TestAppContext) {
    let (host, cx) = setup(cx);
    for age in [0, crate::state::UNDELIVERED_GRACE_MS + 1] {
        host.update(cx, |host, cx| {
            host.status = harness_proto::ChatIndicator::Working;
            host.shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats[0].device_id = "remote".into();
                    state.connectivity.state = harness_proto::ConnectivityState::Offline;
                    state.begin_pending_send(
                        "matrix",
                        "fixture-send",
                        Utc::now() - chrono::Duration::milliseconds(age),
                    );
                });
                shell.chat_status_hover = None;
                cx.notify();
            });
            cx.notify();
        });
        cx.run_until_parked();
        let status = cx.debug_bounds("chat-status-matrix").unwrap();
        let row = cx.debug_bounds("chat-matrix").unwrap();
        cx.simulate_mouse_move(row.center(), None, Default::default());
        let hovered_status = cx.debug_bounds("chat-status-matrix").unwrap();
        assert_eq!(hovered_status.right(), status.right());
        assert_eq!(cx.debug_bounds("chat-matrix"), Some(row));
        assert_eq!(status.right(), row.right() - px(NAV_ITEM_INSET_X));
    }
}

#[gpui::test]
fn sidebar_compact_and_expanded_reveal_model_without_reflowing_rows(cx: &mut TestAppContext) {
    let (host, cx) = setup(cx);
    for compact in [true, false] {
        cx.simulate_mouse_move(gpui::point(px(600.0), px(300.0)), None, Default::default());
        host.update(cx, |host, cx| {
            host.width = 360.0;
            host.status = harness_proto::ChatIndicator::AwaitingInput;
            host.shell.update(cx, |shell, cx| {
                shell.settings.reset_sidebar_display();
                shell.settings.sidebar_compact = compact;
                shell.chat_status_hover = None;
                cx.notify();
            });
            cx.notify();
        });
        cx.run_until_parked();
        let row = cx.debug_bounds("chat-matrix").unwrap();
        let status = cx.debug_bounds("chat-status-matrix").unwrap();
        assert_eq!(row.size.height, px(38.0));
        assert_eq!(cx.debug_bounds("chat-metadata-matrix").is_some(), !compact);
        assert_eq!(cx.debug_bounds("chat-branch-matrix").is_some(), !compact);
        assert_eq!(
            cx.debug_bounds("chat-agent-icon-matrix").is_some(),
            !compact
        );
        assert!(cx.debug_bounds("chat-model-matrix").is_none());

        cx.simulate_mouse_move(row.center(), None, Default::default());
        cx.run_until_parked();
        assert_eq!(cx.debug_bounds("chat-matrix"), Some(row));
        let title = cx.debug_bounds("chat-title-matrix").unwrap();
        let metadata = cx.debug_bounds("chat-metadata-matrix").unwrap();
        let branch = cx.debug_bounds("chat-branch-matrix").unwrap();
        let agent = cx.debug_bounds("chat-agent-icon-matrix").unwrap();
        let model = cx.debug_bounds("chat-model-matrix").unwrap();
        let updated = cx.debug_bounds("chat-time-matrix").unwrap();
        let hovered_status = cx.debug_bounds("chat-status-matrix").unwrap();
        assert!(metadata.top() >= title.bottom());
        assert!(metadata.bottom() <= row.bottom());
        assert!(branch.size.width > px(0.0));
        assert!(branch.right() <= agent.left());
        assert!(agent.right() <= model.left());
        assert!(model.size.width > px(0.0));
        assert!(model.right() <= updated.left());
        assert_eq!(hovered_status.right(), status.right());
        assert!(title.right() <= hovered_status.left());

        cx.simulate_mouse_move(gpui::point(px(600.0), px(300.0)), None, Default::default());
        cx.run_until_parked();
        assert_eq!(cx.debug_bounds("chat-matrix"), Some(row));
        assert_eq!(cx.debug_bounds("chat-metadata-matrix").is_some(), !compact);
        assert!(cx.debug_bounds("chat-model-matrix").is_none());
    }
}
