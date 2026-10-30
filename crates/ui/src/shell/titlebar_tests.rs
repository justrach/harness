use super::*;

#[test]
fn new_session_action_lives_in_the_titlebar_on_every_chat_tab() {
    assert_eq!(titlebar_new_session_alpha(true), 1.0);
    assert_eq!(titlebar_new_session_alpha(false), 0.0);
}

#[test]
fn titlebar_distribution_handles_fullscreen_captions_and_fractional_widths() {
    for (width, start, buttons, expected) in [
        (256.0, 88.0, 5, 9.5),
        (224.0, 88.0, 5, 2.0),
        (225.0, 88.0, 5, 2.0),
        (255.5, 88.0, 5, 9.5),
        (400.0, 88.0, 5, 45.5),
        (256.0, 12.0, 5, 28.5),
        (240.0, 50.0, 5, 15.0),
        (256.0, 10.0, 5, 29.0),
        (256.0, 36.0, 5, 22.5),
        (256.0, 88.0, 4, 21.0),
        (0.0, 88.0, 5, 2.0),
        (128.0, 88.0, 5, 2.0),
        (256.0, 88.0, 0, 2.0),
        (256.0, 88.0, 1, 2.0),
    ] {
        let gap = distributed_titlebar_gap(width, start, buttons, 2.0);
        assert!(
            (gap - expected).abs() < 0.001,
            "width={width}, start={start}, buttons={buttons}: expected {expected}, got {gap}"
        );
        assert!(gap.is_finite() && gap >= TITLEBAR_CONTROL_GAP);
    }
    for (scale, expected) in [
        (1.0, 10.0),
        (1.25, 9.6),
        (1.5, 28.0 / 3.0),
        (2.0, 9.5),
        (3.0, 28.0 / 3.0),
    ] {
        let gap = distributed_titlebar_gap(255.0, 88.0, 5, scale);
        assert!(
            (gap - expected).abs() < 0.001,
            "display scale {scale}: got {gap}"
        );
        let physical_gap = gap * scale;
        assert!((physical_gap - physical_gap.round()).abs() < 0.001);
    }
}

struct ToolbarHost(Entity<Shell>);

impl Render for ToolbarHost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            div()
                .size_full()
                .child(shell.render_titlebar_cluster(window, cx))
        })
    }
}

#[gpui::test]
fn titlebar_keeps_plus_and_update_inside_sidebar_across_first_prompt(
    cx: &mut gpui::TestAppContext,
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
        ToolbarHost(cx.new(|cx| {
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
            shell.chat_tabs = vec![chat_tabs::ChatTab::default(); 3];
            shell.chat_tab = 1;
            shell.settings.sidebar_width = SIDEBAR_MIN;
            shell.install = harness_update::InstallKind::MacApp {
                bundle: PathBuf::from("/nonexistent/Harness.app"),
            };
            shell.update_flow = UpdateFlow::Ready(StagedUpdate {
                path: PathBuf::from("/nonexistent/staged"),
                version: "9.9.9".into(),
            });
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    for fullscreen in [false, true] {
        for sidebar_width in [
            SIDEBAR_MIN,
            225.0,
            255.0,
            255.5,
            SIDEBAR_DEFAULT,
            399.5,
            SIDEBAR_MAX,
        ] {
            for collapsed in [false, true] {
                let mut draft_bounds = None;
                for selected in [None, Some("first-prompt")] {
                    shell.update(cx, |shell, cx| {
                        shell.fullscreen = Some(fullscreen);
                        shell.titlebar_tween = None;
                        shell.settings.sidebar_width = sidebar_width;
                        shell.settings.sidebar_collapsed = collapsed;
                        shell.state.update(cx, |state, cx| {
                            state.select_chat(selected.map(str::to_owned), cx);
                        });
                        cx.notify();
                    });
                    cx.update(|window, cx| window.draw(cx).clear());
                    let plus = cx
                        .debug_bounds("titlebar-new-session")
                        .expect("+ must remain available before and after the first prompt");
                    let update = cx.debug_bounds("titlebar-update").unwrap();
                    let controls = [
                        cx.debug_bounds("toggle-sidebar").unwrap(),
                        cx.debug_bounds("nav-back").unwrap(),
                        cx.debug_bounds("nav-forward").unwrap(),
                        plus,
                        update,
                    ];
                    let gap = controls[1].left() - controls[0].right();
                    assert!(gap >= px(TITLEBAR_CONTROL_GAP));
                    for pair in controls.windows(2) {
                        assert_eq!(
                            pair[1].left() - pair[0].right(),
                            gap,
                            "every adjacent titlebar icon must have the same gap"
                        );
                    }
                    if !collapsed {
                        assert!(
                            update.right() < px(sidebar_width),
                            "the divider must not intersect update"
                        );
                        assert!(
                            px(sidebar_width) - update.right() <= px(TITLEBAR_CLUSTER_PAD),
                            "fullscreen={fullscreen}, width={sidebar_width}: trailing gap {:?}, controls {controls:?}",
                            px(sidebar_width) - update.right()
                        );
                    }
                    let bounds = (plus, update);
                    if let Some(draft) = draft_bounds {
                        assert_eq!(
                            bounds, draft,
                            "sending the first prompt must not move controls"
                        );
                    } else {
                        draft_bounds = Some(bounds);
                    }
                }
            }
        }
    }
    // An empty active tab still offers a working +, rather than consuming it
    // as the update control's slot.
    shell.update(cx, |shell, cx| {
        shell
            .state
            .update(cx, |state, cx| state.select_chat(None, cx));
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    let tabs_before = shell.read_with(cx, |shell, _| shell.chat_tabs.len());
    let plus = cx.debug_bounds("titlebar-new-session").unwrap();
    cx.simulate_click(plus.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.chat_tabs.len(), tabs_before + 1)
    });

    for in_settings in [false, true] {
        let mut update_bounds = None;
        for mode in [
            "none",
            "available",
            "downloading",
            "ready",
            "failed",
            "advisory",
            "preview",
        ] {
            shell.update(cx, |shell, cx| {
                shell.route = if in_settings {
                    Route::Settings(SettingsSection::Devices)
                } else {
                    Route::Chat
                };
                shell.fullscreen = Some(false);
                shell.titlebar_tween = None;
                shell.settings.sidebar_collapsed = false;
                shell.settings.sidebar_width = SIDEBAR_DEFAULT;
                shell.chat_tabs = vec![chat_tabs::ChatTab::default(); 3];
                shell.chat_tab = 1;
                shell.install = if mode == "advisory" {
                    harness_update::InstallKind::Unmanaged
                } else {
                    harness_update::InstallKind::MacApp {
                        bundle: PathBuf::from("/nonexistent/Harness.app"),
                    }
                };
                shell.update_dismissed = None;
                shell.app_update.dev_preview = mode == "preview";
                shell.update_flow = match mode {
                    "downloading" => UpdateFlow::Downloading,
                    "ready" => UpdateFlow::Ready(StagedUpdate {
                        path: PathBuf::from("/nonexistent/staged"),
                        version: "9.9.9".into(),
                    }),
                    "failed" => UpdateFlow::Failed("synthetic download failure".into()),
                    _ => UpdateFlow::Idle,
                };
                shell.state.update(cx, |state, _| {
                    state.update = Some(harness_update::UpdateStatus {
                        current_version: "0.0.0".into(),
                        latest_version: Some("9.9.9".into()),
                        update_available: mode != "none",
                        checked_at: None,
                        error: None,
                        host: None,
                    });
                });
                cx.notify();
            });
            cx.update(|window, cx| window.draw(cx).clear());
            assert_eq!(
                cx.debug_bounds("titlebar-new-session").is_none(),
                in_settings
            );
            assert_eq!(cx.debug_bounds("nav-back").is_none(), in_settings);
            assert_eq!(cx.debug_bounds("nav-forward").is_none(), in_settings);
            let update = cx.debug_bounds("titlebar-update");
            if mode == "none" {
                assert!(update.is_none());
                continue;
            }
            let update = update.expect("every visible update state owns the same slot");
            let right_gap = px(SIDEBAR_DEFAULT) - update.right();
            assert!(
                right_gap > px(0.0) && right_gap <= px(TITLEBAR_CLUSTER_PAD),
                "route/settings={in_settings}, mode={mode}: keep a small right inset"
            );
            if let Some(expected) = update_bounds {
                assert_eq!(
                    update, expected,
                    "changing update state must not shift its button"
                );
            } else {
                update_bounds = Some(update);
            }
            if matches!(mode, "downloading" | "preview" | "advisory") {
                cx.simulate_click(update.center(), Default::default());
                cx.run_until_parked();
                shell.read_with(cx, |shell, _| {
                    if mode == "downloading" {
                        assert!(matches!(shell.update_flow, UpdateFlow::Downloading));
                    } else {
                        assert!(matches!(shell.update_flow, UpdateFlow::Idle));
                    }
                    assert!(
                        shell.app_update.watch.is_none(),
                        "inert clicks cannot arm a restart"
                    );
                    if mode == "advisory" {
                        assert_eq!(shell.update_dismissed.as_deref(), Some("9.9.9"));
                    }
                });
                cx.update(|window, cx| window.draw(cx).clear());
                assert_eq!(
                    cx.debug_bounds("titlebar-update").is_none(),
                    mode == "advisory"
                );
            }
        }
    }
}

fn assert_plus_opens_tab(cx: &mut gpui::TestAppContext, collapsed: bool, split: bool) {
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
        ToolbarHost(cx.new(|cx| {
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
            shell.settings.sidebar_collapsed = collapsed;
            shell.state.update(cx, |state, cx| {
                state.chats = ["current", "peer", "parked"]
                    .into_iter()
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "archived": false,
                            "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .collect();
                state.select_chat(Some("current".into()), cx);
            });
            if split {
                shell.chat_split = chat_split::ChatSplit::split(
                    None,
                    SplitAxis::Horizontal,
                    Some("peer".into()),
                    None,
                );
                shell.chat_tabs = vec![
                    chat_tabs::ChatTab::default(),
                    chat_tabs::ChatTab {
                        selected: Some("parked".into()),
                        ..Default::default()
                    },
                ];
            }
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let (layout, draft) = shell.read_with(cx, |shell, cx| {
        (shell.chat_split.clone(), shell.current_canvas_draft(cx))
    });
    let plus = cx.debug_bounds("titlebar-new-session").unwrap();
    cx.simulate_click(plus.center(), Default::default());
    cx.run_until_parked();
    shell.update(cx, |shell, cx| {
        let count = if split { 3 } else { 2 };
        assert_eq!(
            shell.chat_tabs.len(),
            count,
            "+ must append a tab, not replace the active session"
        );
        assert_eq!(shell.chat_tab, count - 1);
        assert!(shell.state.read(cx).selected_chat.is_none());
        assert!(
            shell.chat_split.is_none(),
            "the new tab starts with one pane"
        );
        assert_eq!(
            shell.current_canvas_draft(cx),
            draft,
            "new-tab picks match Cmd+T inheritance"
        );
        let original = &shell.chat_tabs[0];
        assert_eq!(original.selected.as_deref(), Some("current"));
        assert_eq!(
            original.split, layout,
            "all original split panes stay in their tab"
        );
        if split {
            assert_eq!(shell.chat_tabs[1].selected.as_deref(), Some("parked"));
        }
    });
    cx.update_window_entity(&shell, |shell, window, cx| {
        shell.switch_chat_tab(0, window, cx);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
        assert_eq!(shell.chat_split, layout);
        assert_eq!(shell.current_canvas_draft(cx), draft);
    });
}

#[gpui::test]
fn titlebar_plus_preserves_single_session_in_new_tab(cx: &mut gpui::TestAppContext) {
    for collapsed in [false, true] {
        assert_plus_opens_tab(cx, collapsed, false);
    }
}

#[gpui::test]
fn titlebar_plus_preserves_split_tab_in_new_tab(cx: &mut gpui::TestAppContext) {
    for collapsed in [false, true] {
        assert_plus_opens_tab(cx, collapsed, true);
    }
}

#[gpui::test]
fn graff_notice_card_shows_dismisses_and_resurfaces(cx: &mut gpui::TestAppContext) {
    use harness_adapters::graff_bundle::GraffNotice;
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
    let (shell, cx) = cx.add_window_view(|_, cx| {
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
        shell.debug_gate = Some(GatePhase::Ready);
        shell
    });
    // Shell::new doesn't spawn the watch-channel reader under cfg(test)
    // (the process-wide channel would wake another test's scheduler), so the
    // test applies the notices itself, exactly as the reader does.
    shell.update(cx, |shell, cx| {
        shell.graff_notice = Some(GraffNotice::Updated {
            from: Some("1.0.0".into()),
            to: "1.0.1".into(),
        });
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("graff-notice").is_some(),
        "an Updated notice shows the card"
    );
    assert!(
        cx.debug_bounds("graff-notice-highlights").is_none(),
        "no release lines yet, so no highlights section"
    );
    shell.update(cx, |shell, cx| {
        shell.graff_notice_highlights = vec!["compaction fix".into(), "fewer requests".into()];
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("graff-notice-highlights").is_some(),
        "the engine's release lines fill the card"
    );

    let dismiss = cx.debug_bounds("graff-notice-dismiss").unwrap();
    cx.simulate_click(dismiss.center(), Default::default());
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("graff-notice").is_none(),
        "dismiss hides the card"
    );
    shell.read_with(cx, |_, cx| {
        assert_eq!(
            settings::current(cx).graff_notice_dismissed.as_deref(),
            Some("1.0.1"),
            "dismiss persists the dismissed version"
        );
    });

    // The same version stays hidden; a newer one re-raises the card.
    // Shell::new doesn't spawn the watch-channel reader under cfg(test)
    // (the process-wide channel would wake another test's scheduler), so the
    // test applies the notices itself, exactly as the reader does.
    shell.update(cx, |shell, cx| {
        shell.graff_notice = Some(GraffNotice::Updated {
            from: Some("1.0.0".into()),
            to: "1.0.1".into(),
        });
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("graff-notice").is_none(),
        "a dismissed version never shows again"
    );

    shell.update(cx, |shell, cx| {
        shell.graff_notice = Some(GraffNotice::Available {
            current: Some("1.0.1".into()),
            latest: "1.0.2".into(),
        });
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("graff-notice").is_some(),
        "a newer version shows again"
    );
    assert!(cx.debug_bounds("graff-notice-update").is_some());
    assert!(cx.debug_bounds("graff-notice-whats-new").is_some());
}

/// #219: the titlebar arrows walk OPEN tabs, not NavHistory — the enabled
/// state and the click both come from `chat_tabs`/`chat_tab`, gated by the
/// Chat route.
#[gpui::test]
fn titlebar_arrows_walk_open_tabs_not_route_history(cx: &mut gpui::TestAppContext) {
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
        ToolbarHost(cx.new(|cx| {
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.chats = ["alpha", "bravo", "charlie", "ghost"]
                    .into_iter()
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "archived": false,
                            "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .collect();
                state
            });
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
            // Three tabs: two chats + an open new-session canvas, first lit.
            shell.chat_tabs = vec![
                chat_tabs::ChatTab {
                    selected: Some("alpha".into()),
                    ..Default::default()
                },
                chat_tabs::ChatTab {
                    selected: Some("bravo".into()),
                    ..Default::default()
                },
                chat_tabs::ChatTab::default(),
            ];
            shell.chat_tab = 0;
            shell
                .state
                .update(cx, |state, cx| state.select_chat(Some("alpha".into()), cx));
            // Route history pointing at an unopened chat must not feed the
            // arrows.
            shell.nav.push(NavEntry::Chat("ghost".into()));
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("nav-back").is_none(),
        "first tab: no back arrow"
    );
    let forward = cx.debug_bounds("nav-forward").expect("next tab exists");
    cx.simulate_click(forward.center(), Default::default());
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 1);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("bravo"));
    });

    cx.update(|window, cx| window.draw(cx).clear());
    // Tab 2 is an open new-session canvas — still a real tab.
    let forward = cx.debug_bounds("nav-forward").unwrap();
    cx.simulate_click(forward.center(), Default::default());
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 2);
        assert!(shell.state.read(cx).selected_chat.is_none());
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("nav-forward").is_none(),
        "last tab: no forward arrow"
    );
    let back = cx.debug_bounds("nav-back").unwrap();
    cx.simulate_click(back.center(), Default::default());
    shell.read_with(cx, |shell, _| assert_eq!(shell.chat_tab, 1));

    // Settings hides the open tabs entirely — the arrows go with them.
    shell.update(cx, |shell, cx| {
        shell.route = Route::Settings(SettingsSection::Devices);
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(cx.debug_bounds("nav-back").is_none() && cx.debug_bounds("nav-forward").is_none());
    shell.update(cx, |shell, cx| {
        shell.route = Route::Chat;
        // One tab: both disabled.
        shell.chat_tabs.truncate(1);
        shell.chat_tab = 0;
        shell
            .state
            .update(cx, |state, cx| state.select_chat(Some("alpha".into()), cx));
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(cx.debug_bounds("nav-back").is_none() && cx.debug_bounds("nav-forward").is_none());
}

#[gpui::test]
fn update_control_lives_in_the_titlebar_and_later_stops_the_countdown(
    cx: &mut gpui::TestAppContext,
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
    let (shell, cx) = cx.add_window_view(|_, cx| {
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
        shell.debug_gate = Some(GatePhase::Ready);
        shell
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(
        cx.debug_bounds("titlebar-update").is_none(),
        "no update, no control"
    );
    assert_eq!(
        shell.read_with(cx, |shell, cx| shell.titlebar_update_slot(cx)),
        0.0
    );

    // Harness Dev can show the ready-state geometry without a staged update.
    shell.update(cx, |shell, cx| {
        shell.app_update.dev_preview = true;
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    let preview = cx.debug_bounds("titlebar-update").unwrap();
    cx.simulate_click(preview.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert!(matches!(shell.update_flow, UpdateFlow::Idle));
        assert!(shell.app_update.watch.is_none());
        assert_eq!(shell.titlebar_update_slot(cx), TITLEBAR_ACTION_SLOT_WIDTH);
    });

    shell.update(cx, |shell, cx| {
        shell.app_update.dev_preview = false;
        shell.install = harness_update::InstallKind::MacApp {
            bundle: PathBuf::from("/nonexistent/Harness.app"),
        };
        shell.update_flow = UpdateFlow::Ready(StagedUpdate {
            path: PathBuf::from("/nonexistent/staged"),
            version: "9.9.9".into(),
        });
        // The heads-up is counting down (no watcher runs in this test).
        shell.app_update.countdown_started = Some(std::time::Instant::now());
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(cx.debug_bounds("titlebar-update").is_some());
    assert_eq!(
        shell.read_with(cx, |shell, cx| shell.titlebar_update_slot(cx)),
        TITLEBAR_ACTION_SLOT_WIDTH
    );
    assert!(cx.debug_bounds("app-update-countdown").is_some());

    let later = cx.debug_bounds("app-update-later").unwrap();
    cx.simulate_click(later.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.app_update.postponed.as_deref(), Some("9.9.9"));
        assert!(shell.app_update.countdown_started.is_none());
        assert!(
            matches!(shell.update_flow, UpdateFlow::Ready(_)),
            "Later keeps the update staged for quit"
        );
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(cx.debug_bounds("app-update-countdown").is_none());
    assert!(cx.debug_bounds("titlebar-update").is_some());

    // Settings → Devices sees the same flow, and its button does what the
    // titlebar click does: here, try the (nonexistent) staged install, which
    // fails into a retry instead of starting another download.
    {
        use crate::settings::devices::{SharedUpdatePhase, UpdatePhase};
        assert_eq!(
            cx.update(|_, cx| cx.global::<SharedUpdatePhase>().0.clone()),
            UpdatePhase::Ready("9.9.9".into())
        );
        cx.update(|window, cx| window.dispatch_action(Box::new(StartAppUpdate), cx));
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            assert!(
                matches!(shell.update_flow, UpdateFlow::Failed(_)),
                "the version card's button restarts into the staged update"
            );
        });
        cx.update(|window, cx| window.draw(cx).clear());
        assert!(matches!(
            cx.update(|_, cx| cx.global::<SharedUpdatePhase>().0.clone()),
            UpdatePhase::Failed(_)
        ));
        assert!(
            !dir.path().join("app-update-relaunch.json").exists(),
            "a failed install leaves no relaunch marker"
        );
    }

    // A new-session prompt parked in another tab is unsent work too.
    shell.update(cx, |shell, cx| {
        assert!(!shell.has_unsent_composer_input(cx));
        shell.chat_tabs = vec![
            chat_tabs::ChatTab::default(),
            chat_tabs::ChatTab {
                draft: Some(crate::pickers::CanvasDraft {
                    input: Some(crate::pickers::CanvasInput {
                        text: "half-written prompt".into(),
                        stage: Vec::new(),
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ];
        assert!(shell.has_unsent_composer_input(cx));
    });
}
