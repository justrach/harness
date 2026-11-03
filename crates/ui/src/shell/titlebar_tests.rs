use super::*;

struct ToolbarHost(Entity<Shell>);

impl Render for ToolbarHost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            if matches!(shell.route, Route::Chat) {
                shell.render_top_tab_bar(cx)
            } else {
                div()
                    .size_full()
                    .child(shell.render_titlebar_cluster(cx))
                    .into_any_element()
            }
        })
    }
}

/// Exercise the production workspace/Settings cluster independently of the
/// legacy tab bar used by the tab-opening tests below.
struct TitlebarClusterHost(Entity<Shell>);

impl Render for TitlebarClusterHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            div().size_full().child(shell.render_titlebar_cluster(cx))
        })
    }
}

#[gpui::test]
fn titlebar_keeps_toggle_and_update_inside_sidebar_across_first_prompt(
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
        TitlebarClusterHost(cx.new(|cx| {
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
            shell.app_update.postponed = Some("9.9.9".into());
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
                    let toggle = cx.debug_bounds("toggle-sidebar").unwrap();
                    let update = cx.debug_bounds("titlebar-update").unwrap();
                    assert_eq!(update.left() - toggle.right(), px(TITLEBAR_CONTROL_GAP));
                    assert_eq!(toggle.size, gpui::size(px(24.0), px(24.0)));
                    assert_eq!(update.size, toggle.size);
                    if !collapsed {
                        assert!(
                            update.right() < px(sidebar_width),
                            "the divider must not intersect update"
                        );
                    }
                    let bounds = (toggle, update);
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
    for in_settings in [false, true] {
        let mut update_bounds = None;
        for mode in [
            "none",
            "available",
            "downloading",
            "ready",
            "later",
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
                shell.app_update.postponed = (mode == "later").then(|| "9.9.9".into());
                shell.update_flow = match mode {
                    "downloading" => UpdateFlow::Downloading,
                    "ready" | "later" => UpdateFlow::Ready(StagedUpdate {
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
            let toggle = cx.debug_bounds("toggle-sidebar").unwrap();
            let update = cx.debug_bounds("titlebar-update");
            if matches!(mode, "none" | "available" | "downloading") {
                assert!(update.is_none());
                shell.read_with(cx, |shell, cx| {
                    assert_eq!(shell.titlebar_update_slot(cx), 0.0)
                });
                continue;
            }
            if mode == "ready" {
                // Automatic restart may wait on active work. A staged update
                // still offers manual restart in the compact titlebar slot.
                shell.read_with(cx, |shell, cx| {
                    assert!(settings::with_current(cx, |s| s.restart_to_install_updates));
                    assert!(shell.app_update.postponed.is_none());
                    assert!(shell.app_update.countdown_started.is_none());
                });
            }
            let update = update.expect("every visible update state owns the same slot");
            assert_eq!(update.left() - toggle.right(), px(TITLEBAR_CONTROL_GAP));
            assert!(update.right() < px(SIDEBAR_DEFAULT));
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.titlebar_update_slot(cx), TITLEBAR_ACTION_SLOT_WIDTH)
            });
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
    let plus = cx.debug_bounds("top-new-tab").unwrap();
    cx.simulate_click(plus.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert!(shell.spaces_menu.is_open());
        assert_eq!(shell.chat_split, layout);
        assert_eq!(shell.current_canvas_draft(cx), draft);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
}

#[gpui::test]
fn titlebar_plus_opens_project_picker_preserving_single_session(cx: &mut gpui::TestAppContext) {
    for collapsed in [false, true] {
        assert_plus_opens_tab(cx, collapsed, false);
    }
}

#[gpui::test]
fn titlebar_plus_opens_project_picker_preserving_split(cx: &mut gpui::TestAppContext) {
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

/// The sidebar control stays beside the tabs while collapsing, and removing
/// the arrow buttons does not remove keyboard/command tab navigation.
#[gpui::test]
fn titlebar_groups_sidebar_toggle_with_tabs(cx: &mut gpui::TestAppContext) {
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
    let toggle = cx.debug_bounds("toggle-sidebar").expect("sidebar toggle");
    let tab = cx.debug_bounds("chat-tab-0").expect("active tab");
    let plus = cx.debug_bounds("top-new-tab").expect("new tab action");
    assert_eq!(toggle.center().y, tab.center().y);
    assert_eq!(toggle.center().y, plus.center().y);
    assert!(tab.left() >= toggle.right());
    assert!(
        tab.left() - toggle.right() <= px(16.0),
        "no former arrow spacer"
    );
    assert!(cx.debug_bounds("nav-back").is_none());
    assert!(cx.debug_bounds("nav-forward").is_none());

    for collapsed in [true, false] {
        cx.simulate_click(toggle.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.settings.sidebar_collapsed, collapsed);
        });
        assert_eq!(cx.debug_bounds("toggle-sidebar").unwrap(), toggle);
        assert_eq!(cx.debug_bounds("chat-tab-0").unwrap(), tab);
    }

    cx.update_window_entity(&shell, |shell, window, cx| {
        shell.cycle_chat_tab(true, window, cx);
        assert_eq!(shell.chat_tab, 1);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("bravo"));
        shell.cycle_chat_tab(false, window, cx);
        assert_eq!(shell.chat_tab, 0);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("alpha"));
    });
    shell.update(cx, |shell, cx| {
        shell.route = Route::Settings(SettingsSection::Devices);
        cx.notify();
    });
    cx.update(|window, cx| window.draw(cx).clear());
    assert!(cx.debug_bounds("toggle-sidebar").is_some());
    assert!(cx.debug_bounds("nav-back").is_none());
    assert!(cx.debug_bounds("nav-forward").is_none());
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
    assert!(cx.debug_bounds("titlebar-update").is_none());
    assert_eq!(
        shell.read_with(cx, |shell, cx| shell.titlebar_update_slot(cx)),
        0.0
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
    // Postponed updates keep the compact titlebar control even with the sidebar open.
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
