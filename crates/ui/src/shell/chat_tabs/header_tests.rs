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
            let mut strip = shell.render_pane_strip(&theme, cx);
            div()
                .w(px(shell.settings.sidebar_width))
                .flex()
                .flex_col()
                .children(shell.render_chat_tabs(&theme, &mut strip, cx))
                .children(strip)
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
        settings::init(settings::UiSettings::default(), path, cx);
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
                state.chats = [("first", "First\nchat"), ("second", "Second chat")]
                    .map(|(id, title)| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "title": title,
                            "archived": false, "createdAt": Utc::now(),
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
fn sidebar_single_tab_header_tracks_live_chat_and_canvas(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    assert_single_header(&shell, cx, "First chat");
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| shell.open_chat("second".into(), cx));
    });
    assert_single_header(&shell, cx, "Second chat");
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            cx.notify();
        });
    });
    assert_single_header(&shell, cx, "New session");
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
fn sidebar_single_tab_header_survives_split_and_tab_closure(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.split_chat(SplitAxis::Horizontal, window, cx)
        });
    });
    assert_single_header(&shell, cx, "New session");
    let header = cx.debug_bounds("chat-tab-0").unwrap();
    let first = cx.debug_bounds("chat-pane-card-0").unwrap();
    let second = cx.debug_bounds("chat-pane-card-1").unwrap();
    assert!(header.bottom() <= first.top());
    assert_eq!(first.top(), second.top());
    assert_eq!(first.size.width, px(99.0));
    assert_eq!(first.size.width, second.size.width);
    // Cmd+W removes the extra Cmd+D pane; the header must not disappear.
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.close_focused_chat_pane(window, cx));
            assert!(shell.chat_split.is_none());
        });
    });
    assert_single_header(&shell, cx, "First chat");
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.new_chat_tab(Some("second".into()), window, cx)
        });
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("chat-tab-1").is_some());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.close_chat_tab(window, cx));
            assert!(shell.chat_tabs.is_empty());
        });
    });
    assert_single_header(&shell, cx, "First chat");
}

#[gpui::test]
fn tab_row_close_button_closes_that_tab(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.new_chat_tab(Some("second".into()), window, cx);
            shell.new_chat_tab(None, window, cx);
        });
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_tab, 2);
        assert_eq!(
            shell.chat_tab_labels(cx),
            vec![
                SharedString::from("First chat"),
                "Second chat".into(),
                "New session".into()
            ]
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
            vec![SharedString::from("Second chat"), "New session".into()]
        );
    });
    // Closing the lit tab hands off to the last visited one, back to one tab.
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.close_chat_tab_at(1, window, cx))
        });
    });
    assert_single_header(&shell, cx, "Second chat");
    // A lone tab has nothing to close.
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            assert!(!shell.close_chat_tab_at(0, window, cx))
        });
    });
}
