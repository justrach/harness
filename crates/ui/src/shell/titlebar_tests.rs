use super::*;

#[test]
fn new_session_action_lives_in_the_titlebar_only_when_useful() {
    assert_eq!(titlebar_new_session_alpha(true, true), 1.0);
    assert_eq!(titlebar_new_session_alpha(true, false), 0.0);
    assert_eq!(titlebar_new_session_alpha(false, true), 0.0);
    assert_eq!(titlebar_new_session_alpha(false, false), 0.0);
}

struct ToolbarHost(Entity<Shell>);

impl Render for ToolbarHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            div().size_full().child(shell.render_titlebar_cluster(cx))
        })
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
