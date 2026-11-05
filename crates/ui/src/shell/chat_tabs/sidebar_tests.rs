use super::*;

/// Render the real sidebar rows so the regression exercises their click handler.
struct SidebarRows(Entity<Shell>);

impl Render for SidebarRows {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            let selected = shell.state.read(cx).selected_chat.clone();
            div()
                .w(px(280.0))
                .flex()
                .flex_col()
                .children(["current", "peer", "target"].map(|id| {
                    shell.render_chat_row(
                        id.into(),
                        id.into(),
                        "now".into(),
                        "local".into(),
                        None,
                        None,
                        None,
                        harness_proto::ChatIndicator::Idle,
                        selected.as_deref() == Some(id),
                        false,
                        false,
                        None,
                        None,
                        None,
                        &theme,
                        cx,
                    )
                }))
        })
    }
}

fn assert_sidebar_click(cx: &mut gpui::TestAppContext, split: bool, parked_pane: Option<bool>) {
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
        SidebarRows(cx.new(|cx| {
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
            shell.settings.sidebar_collapsed = false;
            shell.state.update(cx, |state, cx| {
                state.local_device_id = Some("local".into());
                state.spaces = ["a", "b"].map(|id| serde_json::from_value(serde_json::json!({
                    "id": id, "deviceId": "local", "path": format!("/fixtures/{id}"), "createdAt": Utc::now(),
                })).unwrap()).into();
                state.chats = ["current", "peer", "target", "parked"]
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "archived": false,
                            "spaceId": if id == "current" || id == "peer" { "a" } else { "b" },
                            "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.select_chat(Some("current".into()), cx);
                state.select_space(Some("a".into()), cx);
            });
            if split {
                shell.chat_split = chat_split::ChatSplit::split(
                    None,
                    SplitAxis::Horizontal,
                    Some("peer".into()),
                    Some("a".into()),
                );
            }
            if let Some(peer) = parked_pane {
                shell.chat_tabs = vec![
                    ChatTab { project: Some("a".into()), ..Default::default() },
                    ChatTab {
                        project: Some("b".into()),
                        selected: Some(if peer { "parked" } else { "target" }.into()),
                        split: peer.then(|| {
                            chat_split::ChatSplit::split(
                                None,
                                SplitAxis::Horizontal,
                                Some("target".into()),
                                Some("b".into()),
                            )
                            .unwrap()
                        }),
                        ..Default::default()
                    },
                ];
                // Revealing a parked tab must also work when leaving Settings.
                shell.route = Route::Settings(SettingsSection::Appearance);
            }
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let (layout, draft) = shell.read_with(cx, |shell, cx| {
        (shell.chat_split.clone(), shell.current_canvas_draft(cx))
    });
    for _ in 0..2 {
        let row = cx.debug_bounds("chat-target").unwrap();
        cx.simulate_click(row.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.chat_tabs.len(), 2, "clicks must not duplicate tabs");
            assert_eq!(shell.chat_tab, 1);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("target")
            );
            assert!(matches!(shell.route, Route::Chat));
            assert_eq!(shell.chat_tabs[0].selected.as_deref(), Some("current"));
            assert_eq!(shell.chat_tabs[0].split, layout);
            assert_eq!(shell.chat_tabs[0].draft.as_ref(), Some(&draft));
            if parked_pane == Some(true) {
                let split = shell.chat_split.as_ref().unwrap();
                assert_eq!(split.focus, 0);
                assert_eq!(split.panes[1].as_deref(), Some("parked"));
            }
        });
    }
    // Clicking the original chat returns to its existing tab.
    let row = cx.debug_bounds("chat-current").unwrap();
    cx.simulate_click(row.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 0);
        assert_eq!(shell.chat_tabs.len(), 2);
        assert_eq!(shell.chat_split, layout);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
        assert_eq!(shell.current_canvas_draft(cx), draft);
    });
    if split {
        // A chat already in the live split focuses its pane, not a new tab.
        let row = cx.debug_bounds("chat-peer").unwrap();
        cx.simulate_click(row.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.chat_tab, 0);
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            let split = shell.chat_split.as_ref().unwrap();
            assert_eq!(split.focus, 0);
            assert_eq!(split.panes[1].as_deref(), Some("current"));
        });
    }
}

#[gpui::test]
fn cross_project_navigation_keeps_the_previous_project_view(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        assert_sidebar_click(cx, split, None);
    }
}

#[gpui::test]
fn sidebar_click_reveals_existing_tab_and_pane(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        for peer in [false, true] {
            assert_sidebar_click(cx, split, Some(peer));
        }
    }
}

/// Real navigation controls next to a narrow composer, without starting an engine.
struct QuestionNavigation(Entity<Shell>);

impl Render for QuestionNavigation {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            div()
                .size_full()
                .flex()
                .child(
                    div()
                        .w(px(280.0))
                        .h_full()
                        .child(shell.render_workspace_session_sidebar(
                            &Theme::default(),
                            window,
                            cx,
                        )),
                )
                .child(
                    div()
                        .flex_1()
                        .h_full()
                        .debug_selector(|| "question-outside".into()),
                )
                .child(
                    div()
                        .w(px(200.0))
                        .h_full()
                        .flex()
                        .flex_col()
                        .justify_end()
                        .child(shell.composer.clone()),
                )
        })
    }
}

fn assert_active_question_reselection(cx: &mut gpui::TestAppContext, tabs: bool, split: bool) {
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
    let (host, cx) = cx.add_window_view(|window, cx| {
        window.resize(gpui::size(px(1000.0), px(600.0)));
        QuestionNavigation(cx.new(|cx| {
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
            shell.settings.sidebar_collapsed = false;
            shell.settings.sidebar_width = 280.0;
            shell.route = Route::Chat;
            shell.state.update(cx, |state, cx| {
                state.chats = ["current", "peer"]
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "archived": false,
                            "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.select_chat(Some("current".into()), cx);
            });
            if tabs {
                shell.chat_tabs = vec![
                    ChatTab::default(),
                    ChatTab {
                        selected: Some("peer".into()),
                        ..Default::default()
                    },
                ];
            }
            if split {
                shell.chat_split = chat_split::ChatSplit::split(
                    None,
                    SplitAxis::Horizontal,
                    Some("peer".into()),
                    None,
                );
            }
            shell.ensure_workspace_sessions(cx);
            shell.chat_tabs[0].id = "current-session".into();
            shell.chat_tabs[0].selected = Some("current".into());
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![workspace_panels::PanelTab::Chat("current".into())];
            layout.last_selected = Some(Some("current".into()));
            if split {
                layout.panels.push(workspace_panels::WorkspacePanel {
                    id: 1,
                    tabs: vec![workspace_panels::PanelTab::Chat("peer".into())],
                    active: 0,
                    share: 0.5,
                });
                layout.panels[0].share = 0.5;
                layout.next_id = 2;
            }
            shell.composer.update(cx, |composer, cx| {
                composer.set_available_width(200.0, cx);
                composer.set_available_height(600.0, cx);
            });
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let (state, composer, layout, tab_count) = shell.read_with(cx, |shell, _| {
        (
            shell.state.clone(),
            shell.composer.clone(),
            shell.chat_split.clone(),
            shell.chat_tabs.len(),
        )
    });
    cx.run_until_parked();
    state.update(cx, |state, cx| {
        state.transcript = serde_json::from_value(serde_json::json!([{
            "id": "assistant", "role": "assistant", "createdAt": 0,
            "deviceId": "local", "status": "streaming", "parts": [{
                "kind": "input", "id": "input", "requestId": "pending-question",
                "resolved": false, "questions": [{
                    "id": "question", "header": "Choose", "question": "Which approach?",
                    "multiSelect": true, "options": ["Yes"]
                }]
            }]
        }]))
        .unwrap();
        cx.notify();
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("question-popover").is_some());
    // Exercise the visible workspace-session row and the handler used by an
    // already-focused panel tab. The narrow host keeps the question in its
    // floating presentation, independent of the main workspace's dimensions.
    let selectors = ["workspace-session-current-session", "active-panel-tab"];
    for selector in &selectors {
        // Ordinary outside clicks and background notifications stay dismissed.
        let outside = cx.debug_bounds("question-outside").unwrap();
        cx.simulate_click(outside.center(), Default::default());
        state.update(cx, |state, cx| {
            state.select_chat(Some("current".into()), cx);
            cx.notify();
        });
        cx.update(|window, cx| window.focus(&composer.focus_handle(cx), cx));
        cx.run_until_parked();
        assert!(cx.debug_bounds("question-popover").is_none());
        assert!(cx.debug_bounds("question-expand").is_some());
        // Repeated clicks on the real already-active control must reopen even
        // though mouse-down outside the question dismisses it first.
        for _ in 0..2 {
            reselect_question_control(&shell, selector, cx);
            assert!(cx.debug_bounds("question-popover").is_some(), "{selector}");
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert_eq!(shell.chat_tab, 0);
                assert_eq!(shell.chat_tabs.len(), tab_count, "no duplicated tab");
                assert_eq!(shell.chat_split, layout);
            });
        }
    }
    // An active queue edit owns the composer: explicit reselection must not
    // reveal its suspended question or replace the queued text with an answer.
    let close = cx.debug_bounds("question-close").unwrap();
    cx.simulate_click(close.center(), Default::default());
    state.update(cx, |state, _| {
        state.queue = vec![harness_doc::QueuedMessage::new(
            "row",
            "queued text",
            "local",
        )];
    });
    composer.update(cx, |composer, cx| {
        composer.editing_queued = Some("row".into());
        composer.prepare_queue_edit_input(cx);
        composer
            .input
            .update(cx, |input, cx| input.set_text("queued text", cx));
        cx.notify();
    });
    cx.run_until_parked();
    for selector in selectors {
        reselect_question_control(&shell, selector, cx);
        assert!(cx.debug_bounds("question-popover").is_none(), "{selector}");
        composer.read_with(cx, |composer, cx| {
            assert_eq!(composer.editing_queued.as_deref(), Some("row"));
            assert_eq!(composer.input.read(cx).text(), "queued text");
        });
    }
}

fn reselect_question_control(
    shell: &Entity<Shell>,
    selector: &'static str,
    cx: &mut gpui::VisualTestContext,
) {
    if selector == "active-panel-tab" {
        shell.update_in(cx, |shell, window, cx| {
            let panel = shell.panel_layout(cx).unwrap().focused;
            shell.focus_workspace_tab(
                panel,
                workspace_panels::PanelTab::Chat("current".into()),
                window,
                cx,
            );
        });
    } else {
        let control = cx.debug_bounds(selector).unwrap();
        cx.simulate_click(control.center(), Default::default());
    }
    cx.run_until_parked();
}

#[gpui::test]
fn active_sidebar_and_single_tab_reselection_reopens_pending_question(
    cx: &mut gpui::TestAppContext,
) {
    assert_active_question_reselection(cx, false, false);
}

#[gpui::test]
fn active_sidebar_tab_and_pane_reselection_reopens_pending_question(cx: &mut gpui::TestAppContext) {
    assert_active_question_reselection(cx, true, true);
}

/// The workspace session sidebar at a fixed window height.
struct ChatSidebar(Entity<Shell>);

impl Render for ChatSidebar {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            div()
                .w(px(280.0))
                .h(px(600.0))
                .child(shell.render_workspace_session_sidebar(&Theme::default(), window, cx))
        })
    }
}

#[gpui::test]
fn workspace_sessions_scroll_without_displacing_sidebar_controls(cx: &mut gpui::TestAppContext) {
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
        ChatSidebar(cx.new(|cx| {
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
            shell.route = Route::Chat;
            shell.chat_tabs = vec![Default::default(); 25];
            shell.chat_tab = 24;
            shell.ensure_workspace_sessions(cx);
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    cx.run_until_parked();
    // The workspace already provides creation and search actions. No duplicate
    // legacy controls (or their click targets) should take space above the list.
    assert!(cx.debug_bounds("sidebar-new-chat").is_none());
    assert!(cx.debug_bounds("sidebar-search-field").is_none());
    let create = cx
        .debug_bounds("sidebar-session-create")
        .expect("new-session footer rendered");
    let switcher = cx.debug_bounds("session-switcher").unwrap();
    let list = cx.debug_bounds("workspace-session-list").unwrap();
    assert!(list.top() >= switcher.bottom());
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.chat_tabs.len(), 25);
        let viewport = shell.sidebar_scroll.bounds();
        assert!(viewport.bottom() <= create.top());
        assert!(shell.sidebar_scroll.max_offset().y > px(0.0));
    });
    shell.update(cx, |shell, cx| {
        shell.chat_tabs.truncate(1);
        shell.chat_tab = 0;
        cx.notify();
    });
    cx.run_until_parked();
    assert_eq!(cx.debug_bounds("sidebar-session-create").unwrap(), create);
    assert_eq!(cx.debug_bounds("session-switcher").unwrap(), switcher);
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.sidebar_scroll.max_offset().y, px(0.0))
    });
}
