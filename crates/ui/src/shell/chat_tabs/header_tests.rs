use super::*;
use gpui::{TestAppContext, VisualTestContext};

struct HeaderHost {
    shell: Entity<Shell>,
    _updates: Subscription,
}

impl Render for HeaderHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.shell.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            div()
                .w(px(1000.0))
                .flex()
                .flex_row()
                .children(shell.render_chat_tabs(&theme, cx))
        })
    }
}

fn setup<'a>(
    cx: &'a mut TestAppContext,
    path: &std::path::Path,
) -> (Entity<Shell>, &'a mut VisualTestContext) {
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
        settings::init(settings::UiSettings::expanded(), path, cx);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        let shell = cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            let mut shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: path.into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.settings.sidebar_width = 220.0;
            shell.state.update(cx, |state, cx| {
                state.spaces = ["a", "b", "c"]
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "path": format!("/fixtures/{id}"),
                            "name": id.to_uppercase(), "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.chats = [("first", "First\nchat"), ("second", "Second chat")]
                    .map(|(id, title)| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "title": title,
                            "archived": false, "spaceId": "a", "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.select_chat(Some("first".into()), cx);
            });
            shell
        });
        let updates = cx.observe(&shell, |_, _, cx| cx.notify());
        HeaderHost {
            shell,
            _updates: updates,
        }
    });
    let shell = host.read_with(cx, |host, _| host.shell.clone());
    (shell, cx)
}

/// The real workspace session a ⌘D splits, as a restored window has it.
fn seed_workspace_session(shell: &mut Shell, cx: &mut Context<Shell>) {
    shell.boot_restored = true;
    shell.ensure_workspace_sessions(cx);
    shell.sync_panel_workspace(cx);
}

fn assert_single_header(shell: &Entity<Shell>, cx: &mut VisualTestContext, title: &str) {
    cx.run_until_parked();
    assert!(cx.debug_bounds("chat-tab-0").is_some());
    assert!(cx.debug_bounds("chat-tab-1").is_none());
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 0);
        assert_eq!(shell.chat_tab_labels(cx), vec![SharedString::from(title)]);
    });
}

#[gpui::test]
fn project_tab_name_stays_stable_across_chats_and_canvas(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    assert_single_header(&shell, cx, "A");
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| shell.open_chat("second".into(), cx));
    });
    assert_single_header(&shell, cx, "A");
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            cx.notify();
        });
    });
    assert_single_header(&shell, cx, "A");
    // This chat-specific header must not leak into Settings.
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.route = Route::Settings(SettingsSection::Appearance);
            cx.notify();
        });
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("chat-tab-0").is_none());
}

#[gpui::test]
fn top_tab_survives_split_and_tab_closure(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            seed_workspace_session(shell, cx);
            shell.workspace_split(SplitAxis::Horizontal, cx);
            assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), 2);
        });
    });
    assert_single_header(&shell, cx, "A");
    let header = cx.debug_bounds("chat-tab-0").unwrap();
    assert_eq!(header.size.height, px(NAV_ITEM_HEIGHT));
    assert!(cx.debug_bounds("chat-tab-group-0").is_none());
    assert!(cx.debug_bounds("chat-pane-card-0").is_none());
    // Cmd+W removes the extra Cmd+D panel's tab, then the emptied panel; the
    // header must not disappear at either step.
    for panels in [2, 1] {
        cx.update(|window, cx| {
            shell.update(cx, |shell, cx| {
                assert!(shell.workspace_close_focused(window, cx));
                assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), panels);
            });
        });
        assert_single_header(&shell, cx, "A");
    }
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| shell.open_project_tab(Some("b".into()), cx));
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("chat-tab-1").is_some());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.close_chat_tab(window, cx));
            assert_eq!(shell.chat_tabs.len(), 1);
        });
    });
    assert_single_header(&shell, cx, "A");
}

#[gpui::test]
fn tab_row_close_button_closes_that_tab(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.open_project_tab(Some("b".into()), cx);
            shell.open_project_tab(Some("c".into()), cx);
        });
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 2);
        assert_eq!(
            shell.chat_tab_labels(cx),
            vec![SharedString::from("A"), "B".into(), "C".into()]
        );
    });
    // The ✕ on a parked tab closes that tab; the lit tab stays lit.
    let close = cx.debug_bounds("chat-tab-close-0").unwrap();
    cx.simulate_click(close.center(), gpui::Modifiers::none());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 1);
        assert_eq!(shell.state.read(cx).selected_chat, None);
        assert_eq!(
            shell.chat_tab_labels(cx),
            vec![SharedString::from("B"), "C".into()]
        );
    });
    // Closing the lit tab hands off to the last visited one, back to one tab.
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.close_chat_tab_at(1, window, cx))
        });
    });
    assert_single_header(&shell, cx, "B");
    // A lone project closes to the projectless canvas, without deleting chats.
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.close_chat_tab_at(0, window, cx))
        });
    });
}

#[gpui::test]
fn selecting_and_switching_tabs_preserves_split_and_draft(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.split_chat(SplitAxis::Horizontal, window, cx)
        });
    });
    cx.run_until_parked();
    let (layout, selected, draft) = shell.read_with(cx, |shell, cx| {
        (
            shell.chat_split.clone(),
            shell.state.read(cx).selected_chat.clone(),
            shell.current_canvas_draft(cx),
        )
    });
    let header = cx.debug_bounds("chat-tab-0").unwrap();
    cx.simulate_click(header.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split, layout);
        assert_eq!(shell.state.read(cx).selected_chat, selected);
        assert_eq!(shell.current_canvas_draft(cx), draft);
    });
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| shell.open_project_tab(Some("b".into()), cx));
    });
    cx.run_until_parked();
    let header = cx.debug_bounds("chat-tab-0").unwrap();
    cx.simulate_click(header.center(), Default::default());
    cx.run_until_parked();
    assert!(cx.debug_bounds("chat-pane-card-0").is_none());
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split, layout);
        assert_eq!(shell.current_canvas_draft(cx), draft);
    });
}

#[gpui::test]
fn top_strip_reveals_the_selected_tab_when_it_overflows(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.chat_tabs = vec![ChatTab::default(); 25];
            shell.chat_tab = 24;
            cx.notify();
        })
    });
    cx.run_until_parked();
    cx.update(|window, _| window.refresh());
    cx.run_until_parked();
    let bounds = shell.read_with(cx, |shell, _| shell.chat_tab_scroll.bounds());
    let last = cx.debug_bounds("chat-tab-24").unwrap();
    assert!(
        last.left() >= bounds.left() && last.right() <= bounds.right(),
        "{last:?} vs {bounds:?}"
    );
    cx.update(|window, cx| shell.update(cx, |shell, cx| shell.switch_chat_tab(0, window, cx)));
    cx.run_until_parked();
    let first = cx.debug_bounds("chat-tab-0").unwrap();
    assert!(
        first.left() >= bounds.left() && first.right() <= bounds.right(),
        "{first:?} vs {bounds:?}"
    );
}

#[gpui::test]
fn pane_focus_updates_one_top_tab_instead_of_adding_subtabs(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            seed_workspace_session(shell, cx);
            for _ in 0..7 {
                shell.workspace_split(SplitAxis::Horizontal, cx);
            }
        });
    });
    assert_single_header(&shell, cx, "A");
    assert!(cx.debug_bounds("chat-pane-card-7").is_none());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            crate::shell::exit_regressions::focus_workspace_panel_for_test(shell, 0, window, cx)
        })
    });
    assert_single_header(&shell, cx, "A");
    shell.read_with(cx, |shell, cx| {
        let layout = shell.panel_layout(cx).unwrap();
        assert_eq!(layout.panels.len(), 8);
        assert_eq!(layout.focused, layout.panels[0].id);
    });
}
