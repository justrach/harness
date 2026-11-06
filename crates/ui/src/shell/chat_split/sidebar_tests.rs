use super::*;

/// Split layouts keep one ordinary workspace tab at every sidebar width.
struct SplitTabHost(Entity<Shell>);

impl Render for SplitTabHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            div().w(px(1800.0)).h(px(600.0)).flex().flex_row().children(
                shell.render_chat_tabs(&theme, cx).map(|tabs| {
                    div()
                        .w_full()
                        .debug_selector(|| "tabs-header".into())
                        .child(tabs)
                }),
            )
        })
    }
}

fn assert_split_tab(cx: &mut gpui::TestAppContext, width: f32, count: usize, tabs: bool) {
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
        settings::init(settings::UiSettings::expanded(), dir.path(), cx);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        SplitTabHost(cx.new(|cx| {
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
            if tabs {
                shell.chat_tabs = vec![Default::default(), Default::default()];
            }
            shell.state.update(cx, |state, cx| {
                state.chats = (0..count)
                    .map(|ix| {
                        serde_json::from_value(serde_json::json!({
                            "id": format!("pane-{ix}"), "deviceId": "local",
                            "title": if ix % 2 == 0 {
                                "A long chat title that must truncate without changing the grid"
                            } else {
                                "Short"
                            },
                            "archived": false, "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .collect();
                state.select_chat(Some(format!("pane-{}", count - 1)), cx);
            });
            let mut split = None;
            for ix in 0..count - 1 {
                split = ChatSplit::split(
                    split,
                    SplitAxis::Horizontal,
                    Some(format!("pane-{ix}")),
                    None,
                );
            }
            shell.chat_split = split;
            shell
        }))
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    assert!(cx.debug_bounds("tabs-header").is_some());
    let tab = cx.debug_bounds("chat-tab-0").unwrap();
    assert_eq!(tab.size.height, px(NAV_ITEM_HEIGHT));
    assert_eq!(cx.debug_bounds("chat-tab-1").is_some(), tabs);
    assert!(cx.debug_bounds("chat-tab-2").is_none());
    assert!(cx.debug_bounds("chat-pane-card-0").is_none());
    assert!(cx.debug_bounds("chat-tab-group-0").is_none());
    cx.update(|window, cx| shell.update(cx, |shell, cx| shell.focus_chat_pane(0, window, cx)));
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
        assert_eq!(shell.chat_split.as_ref().unwrap().panes.len(), count);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("pane-0")
        );
    });
}

#[gpui::test]
fn split_panes_do_not_create_tab_groups(cx: &mut gpui::TestAppContext) {
    for tabs in [false, true] {
        for width in [220.0, 310.0] {
            for count in [3, 4] {
                assert_split_tab(cx, width, count, tabs);
            }
        }
    }
}

#[gpui::test]
fn split_tabs_are_independent_of_sidebar_width(cx: &mut gpui::TestAppContext) {
    for tabs in [false, true] {
        for count in [3, 4, 8] {
            assert_split_tab(cx, 180.0, count, tabs);
        }
    }
}
