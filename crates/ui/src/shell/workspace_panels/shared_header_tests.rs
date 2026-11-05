//! Full Shell rendering and real pointer/key routing for the shared titlebar.
use super::*;
use gpui::{AppContext as _, Bounds, TestAppContext, VisualTestContext, WindowHandle};

fn setup(
    cx: &mut TestAppContext,
    collapsed: bool,
    width: f32,
) -> (tempfile::TempDir, WindowHandle<Shell>, VisualTestContext) {
    let (dir, source) = super::window_transfer_tests::setup(cx);
    source
        .update(cx, |shell, window, cx| {
            shell.reduced_motion = true;
            shell.settings.sidebar_collapsed = collapsed;
            shell.sidebar_tween = None;
            shell.chat_tabs[shell.chat_tab].title = Some("Current session".into());
            shell.state.update(cx, |state, cx| {
                state.chats[0] = serde_json::from_value(serde_json::json!({
                    "id": "chat-a", "deviceId": "fixture-device",
                    "title": "Review the release", "archived": false,
                    "createdAt": "2026-10-31T00:00:00Z", "branch": "feature/shared-header",
                    "config": { "harness": "graff", "model": "fixture-model", "reasoning": null, "sandbox": "workspace-write" }
                })).unwrap();
                cx.notify();
            });
            window.focus(&shell.composer.focus_handle(cx), cx);
            cx.notify();
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(source.into(), cx);
    visual.simulate_resize(gpui::size(px(width), px(760.0)));
    settle(&mut visual);
    let body = bounds(&mut visual, "workspace-panel-body-0");
    visual.simulate_mouse_move(body.center(), None, Default::default());
    settle(&mut visual);
    (dir, source, visual)
}

fn settle(visual: &mut VisualTestContext) {
    visual.run_until_parked();
    visual.update(|window, cx| window.draw(cx).clear());
    visual.run_until_parked();
}

fn bounds(visual: &mut VisualTestContext, selector: &'static str) -> Bounds<Pixels> {
    visual
        .debug_bounds(selector)
        .unwrap_or_else(|| panic!("missing rendered control: {selector}"))
}

fn near(actual: Pixels, expected: f32, message: &str) {
    assert!(
        (actual - px(expected)).abs() < px(0.5),
        "{message}: {actual:?}"
    );
}

fn tabs(source: WindowHandle<Shell>, cx: &mut TestAppContext) -> Vec<PanelTab> {
    source
        .read_with(cx, |shell, cx| {
            shell.panel_layout(cx).unwrap().panels[0].tabs.clone()
        })
        .unwrap()
}

#[gpui::test]
fn workspace_shared_header_single_collapsed_panel_uses_one_row_and_centerline(
    cx: &mut TestAppContext,
) {
    let (_dir, _source, mut visual) = setup(cx, true, 1200.0);
    let body = bounds(&mut visual, "workspace-panel-body-0");
    let header = bounds(&mut visual, "workspace-panel-header-0");
    let tab = bounds(&mut visual, "panel-tab-0-0");
    let content = bounds(&mut visual, "panel-tab-content-0-0");
    let title = bounds(&mut visual, "panel-tab-0-0-title");
    let icon = bounds(&mut visual, "panel-tab-icon-0-0");
    let toggle = bounds(&mut visual, "toggle-sidebar");
    let history = bounds(&mut visual, "titlebar-chat-history");
    let session = bounds(&mut visual, "workspace-session-quick-switcher");
    let controls = bounds(&mut visual, "workspace-titlebar-controls");
    let strip = bounds(&mut visual, "workspace-panel-tab-strip-0");

    near(body.top(), 42.0, "one shared header precedes the body");
    near(header.top(), 0.0, "the panel header begins in the titlebar");
    near(tab.bottom(), 42.0, "the selected tab joins its body");
    for center in [
        content.center().y,
        title.center().y,
        icon.center().y,
        toggle.center().y,
        history.center().y,
        session.center().y,
    ] {
        near(
            center,
            21.0,
            "all resting header content shares the native centerline",
        );
    }
    assert!(
        tab.left() >= session.right(),
        "the first tab cannot sit under the session switcher"
    );
    assert!(
        strip.left() >= controls.right(),
        "the scroll viewport starts after the controls"
    );
    assert!(tab.left() >= strip.left());
    assert!(tab.right() <= strip.right());
    assert!(history.left() >= toggle.right());
    assert!(history.right() <= session.left());
    near(
        icon.left() - tab.left(),
        8.0,
        "the tab retains its normal icon inset",
    );
}

#[gpui::test]
fn workspace_shared_header_sidebar_toggle_keeps_body_height_and_tab_icon_inset(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, false, 1200.0);
    let open_tab = bounds(&mut visual, "panel-tab-0-0");
    let open_icon = bounds(&mut visual, "panel-tab-icon-0-0");
    let open_inset = open_icon.left() - open_tab.left();
    near(
        bounds(&mut visual, "workspace-panel-body-0").top(),
        42.0,
        "open sidebar body",
    );
    near(open_inset, 8.0, "ordinary tab icon inset");

    for collapsed in [true, false] {
        let toggle = bounds(&mut visual, "toggle-sidebar");
        visual.simulate_click(toggle.center(), Default::default());
        settle(&mut visual);
        source
            .read_with(cx, |shell, _| {
                assert_eq!(shell.settings.sidebar_collapsed, collapsed)
            })
            .unwrap();
        let tab = bounds(&mut visual, "panel-tab-0-0");
        let icon = bounds(&mut visual, "panel-tab-icon-0-0");
        assert_eq!(icon.left() - tab.left(), open_inset);
        near(
            bounds(&mut visual, "workspace-panel-body-0").top(),
            42.0,
            "sidebar state does not add a second header",
        );
        near(
            bounds(&mut visual, "panel-tab-content-0-0").center().y,
            21.0,
            "tab center remains steady",
        );
    }
    assert_eq!(
        tabs(source, cx),
        vec![
            PanelTab::Chat("chat-a".into()),
            PanelTab::Chat("chat-b".into())
        ]
    );
}

#[gpui::test]
fn workspace_shared_header_empty_panel_label_starts_after_the_controls(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx, true, 1200.0);
    source
        .update(cx, |shell, _, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs.clear();
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            cx.notify();
        })
        .unwrap();
    settle(&mut visual);
    let empty = bounds(&mut visual, "panel-empty-label-0");
    let controls = bounds(&mut visual, "workspace-titlebar-controls");
    let session = bounds(&mut visual, "workspace-session-quick-switcher");
    near(
        empty.center().y,
        21.0,
        "empty label shares the titlebar centerline",
    );
    near(
        bounds(&mut visual, "workspace-panel-body-0").top(),
        42.0,
        "empty body uses one header",
    );
    assert!(empty.left() >= controls.right());
    assert!(empty.left() >= session.right());
    assert!(visual.debug_bounds("panel-tab-0-0").is_none());
}

fn split_fixture(source: WindowHandle<Shell>, cx: &mut TestAppContext) {
    source
        .update(cx, |shell, _, cx| {
            let layout = shell.panel_layout_mut(cx);
            layout.axis = SplitAxis::Horizontal;
            layout.panels[0].tabs = vec![PanelTab::Chat("chat-a".into())];
            let other = layout.add_panel(0);
            assert_eq!(other, 1);
            layout.insert(other, PanelTab::Chat("chat-b".into()));
            layout.focused = 0;
            layout.equalize();
            cx.notify();
        })
        .unwrap();
}

fn assert_sidebar_toggle_hit_target_stays_fixed(cx: &mut TestAppContext, layout: &str) {
    let (_dir, source, mut visual) = setup(cx, false, 1200.0);
    if layout != "single" {
        split_fixture(source, cx);
    }
    source
        .update(cx, |shell, _, cx| {
            shell.chat_tabs[shell.chat_tab].title = Some(
                "A deliberately long session title that must not push the sidebar toggle when the window narrows"
                    .into(),
            );
            if layout == "expanded" {
                shell.panel_layout_mut(cx).expanded = Some(0);
            }
            cx.notify();
        })
        .unwrap();

    for fullscreen in [false, true] {
        source
            .update(cx, |_, window, cx| {
                if window.is_fullscreen() != fullscreen {
                    window.toggle_fullscreen();
                }
                cx.notify();
            })
            .unwrap();
        for width in [1200.0, 760.0] {
            visual.simulate_resize(gpui::size(px(width), px(760.0)));
            settle(&mut visual);
            let original = bounds(&mut visual, "toggle-sidebar");
            source
                .read_with(cx, |shell, _| {
                    assert!(!shell.settings.sidebar_collapsed);
                    assert_eq!(shell.fullscreen, Some(fullscreen));
                })
                .unwrap();

            for collapsed in [true, false, true, false] {
                // Keep the pointer at the original button, even if a bad
                // layout moves it. Looking up its center again hides that bug.
                visual.simulate_click(original.center(), Default::default());
                settle(&mut visual);
                source
                    .read_with(cx, |shell, _| {
                        assert_eq!(
                            shell.settings.sidebar_collapsed, collapsed,
                            "the original hit target must keep working: {layout}, width={width}, fullscreen={fullscreen}",
                        );
                    })
                    .unwrap();
                assert_eq!(
                    bounds(&mut visual, "toggle-sidebar"),
                    original,
                    "the toggle must stay fixed: {layout}, width={width}, fullscreen={fullscreen}, collapsed={collapsed}",
                );
            }
        }
    }
}

#[gpui::test]
fn workspace_shared_header_single_panel_sidebar_toggle_has_a_stable_hit_target(
    cx: &mut TestAppContext,
) {
    assert_sidebar_toggle_hit_target_stays_fixed(cx, "single");
}

#[gpui::test]
fn workspace_shared_header_expanded_panel_sidebar_toggle_has_a_stable_hit_target(
    cx: &mut TestAppContext,
) {
    assert_sidebar_toggle_hit_target_stays_fixed(cx, "expanded");
}

#[gpui::test]
fn workspace_shared_header_multiple_panels_sidebar_toggle_has_a_stable_hit_target(
    cx: &mut TestAppContext,
) {
    assert_sidebar_toggle_hit_target_stays_fixed(cx, "multiple");
}

#[gpui::test]
fn workspace_shared_header_expanded_panel_shares_the_row_and_restore_reveals_the_lane(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, true, 1200.0);
    split_fixture(source, cx);
    settle(&mut visual);
    for selector in ["workspace-panel-body-0", "workspace-panel-body-1"] {
        near(
            bounds(&mut visual, selector).top(),
            84.0,
            "multiple panels retain the separate titlebar lane",
        );
    }
    source
        .update(cx, |shell, _, cx| {
            let layout = shell.panel_layout_mut(cx);
            layout.expanded = Some(1);
            layout.focused = 1;
            cx.notify();
        })
        .unwrap();
    settle(&mut visual);
    near(
        bounds(&mut visual, "workspace-panel-body-1").top(),
        42.0,
        "the expanded panel shares the native session row",
    );
    assert!(visual.debug_bounds("workspace-panel-body-0").is_none());
    near(
        bounds(&mut visual, "workspace-session-quick-switcher")
            .center()
            .y,
        21.0,
        "window controls remain in their lane",
    );
    near(
        bounds(&mut visual, "panel-tab-content-1-0").center().y,
        21.0,
        "expanded panel tabs share the window controls' centerline",
    );
    let controls = bounds(&mut visual, "workspace-titlebar-controls");
    let tab = bounds(&mut visual, "panel-tab-1-0");
    assert!(tab.left() >= controls.right());
    source
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(layout.expanded, Some(1));
            assert!(shell.workspace_uses_shared_header(cx));
        })
        .unwrap();
    let restore = bounds(&mut visual, "panel-expand-1");
    visual.simulate_click(restore.center(), Default::default());
    settle(&mut visual);
    for selector in ["workspace-panel-body-0", "workspace-panel-body-1"] {
        near(
            bounds(&mut visual, selector).top(),
            84.0,
            "restoring multiple panels restores the separate lane",
        );
    }
    source
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(layout.expanded, None);
            assert_eq!(layout.panels[0].tabs, vec![PanelTab::Chat("chat-a".into())]);
            assert_eq!(layout.panels[1].tabs, vec![PanelTab::Chat("chat-b".into())]);
            assert!(!shell.workspace_uses_shared_header(cx));
        })
        .unwrap();
}

#[gpui::test]
fn workspace_shared_header_open_sidebar_needs_no_extra_lane_for_multiple_panels(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, false, 1200.0);
    split_fixture(source, cx);
    settle(&mut visual);
    for selector in ["workspace-panel-body-0", "workspace-panel-body-1"] {
        near(
            bounds(&mut visual, selector).top(),
            42.0,
            "the sidebar houses the window controls",
        );
    }
    source
        .update(cx, |shell, _, cx| {
            shell.panel_layout_mut(cx).expanded = Some(0);
            cx.notify();
        })
        .unwrap();
    settle(&mut visual);
    near(
        bounds(&mut visual, "workspace-panel-body-0").top(),
        42.0,
        "expanded panel keeps its original header height",
    );
}

#[gpui::test]
fn workspace_shared_header_long_session_keeps_narrow_window_controls_reachable(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, true, 900.0);
    source.update(cx, |shell, _, cx| {
        shell.chat_tabs[shell.chat_tab].title = Some("A deliberately long workspace session title that must truncate before the panel tabs and controls".into());
        cx.notify();
    }).unwrap();
    settle(&mut visual);
    let session = bounds(&mut visual, "workspace-session-quick-switcher");
    let history = bounds(&mut visual, "titlebar-chat-history");
    let controls = bounds(&mut visual, "workspace-titlebar-controls");
    let strip = bounds(&mut visual, "workspace-panel-tab-strip-0");
    let first = bounds(&mut visual, "panel-tab-0-0");
    let add = bounds(&mut visual, "panel-add-tab-0");
    assert!(session.size.width <= px(200.0));
    assert!(history.right() <= session.left());
    assert!(session.right() <= strip.left());
    assert!(controls.right() <= strip.left());
    assert!(first.left() >= strip.left());
    assert!(first.right() <= strip.right());
    assert!(session.right() <= add.left());
    assert!(add.left() >= px(0.0) && add.right() <= px(900.0));
    assert!(add.top() >= px(0.0) && add.bottom() <= px(42.0));

    let before = tabs(source, cx);
    visual.simulate_click(add.center(), Default::default());
    settle(&mut visual);
    source
        .read_with(cx, |shell, cx| {
            let panel = &shell.panel_layout(cx).unwrap().panels[0];
            assert_eq!(panel.tabs.len(), before.len() + 1);
            assert!(before.iter().all(|tab| panel.tabs.contains(tab)));
            assert!(matches!(panel.selected(), Some(PanelTab::New(_))));
            assert_eq!(shell.chat_tabs.len(), 1);
            assert!(shell.state.read(cx).selected_chat.is_none());
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}

fn assert_history_location(visual: &mut VisualTestContext, expected: &'static str) {
    // Cached SidebarPane scenes replay paint and input handlers, but GPUI does
    // not replay their debug bounds. Inspect a fresh frame for all locations.
    visual.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
    for selector in [
        "sidebar-chat-history",
        "titlebar-chat-history",
        "overview-chat-history",
    ] {
        assert_eq!(
            visual.debug_bounds(selector).is_some(),
            selector == expected,
            "only the visible history location should be rendered: {selector}",
        );
    }
}

#[gpui::test]
fn workspace_shared_header_history_moves_between_footer_and_header_without_navigation(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, false, 980.0);
    let before = tabs(source, cx);
    for collapsed in [false, true, false] {
        source
            .update(cx, |shell, _, cx| {
                shell.settings.sidebar_collapsed = collapsed;
                shell.sidebar_tween = None;
                cx.notify();
            })
            .unwrap();
        settle(&mut visual);
        let selector = if collapsed {
            "titlebar-chat-history"
        } else {
            "sidebar-chat-history"
        };
        assert_history_location(&mut visual, selector);
        let history = bounds(&mut visual, selector);
        if !collapsed {
            let create = bounds(&mut visual, "sidebar-session-create");
            near(
                create.left() - history.right(),
                6.0,
                "history precedes New session",
            );
            near(
                history.center().y - create.center().y,
                0.0,
                "footer actions align",
            );
        }
        visual.simulate_click(history.center(), Default::default());
        settle(&mut visual);
        source
            .read_with(cx, |shell, _| {
                assert!(shell.command_palette.is_some());
                assert_eq!(shell.settings.sidebar_collapsed, collapsed);
                assert!(matches!(shell.route, Route::Chat));
            })
            .unwrap();
        visual.simulate_keystrokes("escape");
        settle(&mut visual);
        source
            .read_with(cx, |shell, cx| {
                assert!(shell.command_palette.is_none());
                assert_eq!(shell.settings.sidebar_collapsed, collapsed);
                assert_eq!(
                    shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                    "An unsent draft"
                );
            })
            .unwrap();
        assert_eq!(tabs(source, cx), before);
        near(
            bounds(&mut visual, "workspace-panel-body-0").top(),
            42.0,
            "header stays compact",
        );
    }
}

#[gpui::test]
fn workspace_shared_header_history_excludes_control_from_drag_and_drop(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx, true, 640.0);
    let history = bounds(&mut visual, "titlebar-chat-history");
    let session = bounds(&mut visual, "workspace-session-quick-switcher");
    let strip = bounds(&mut visual, "workspace-panel-tab-strip-0");
    assert!(history.right() <= session.left());
    assert!(session.right() <= strip.left());
    source
        .update(cx, |shell, window, cx| {
            assert!(shell.window_drop_at(history.center(), window, cx).is_none());
            assert!(
                shell
                    .panel_tab_drop_at(history.center(), window, cx)
                    .is_none()
            );
        })
        .unwrap();
    visual.simulate_mouse_down(history.center(), MouseButton::Left, Default::default());
    source
        .read_with(cx, |shell, _| assert!(!shell.titlebar_should_move))
        .unwrap();
    visual.simulate_mouse_up(history.center(), MouseButton::Left, Default::default());
    settle(&mut visual);
    source
        .read_with(cx, |shell, _| assert!(shell.command_palette.is_some()))
        .unwrap();
}

#[gpui::test]
fn workspace_shared_header_history_remains_available_in_overview_and_settings(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, false, 980.0);
    source
        .update(cx, |shell, window, cx| {
            shell.open_session_overview(window, cx)
        })
        .unwrap();
    settle(&mut visual);
    assert_history_location(&mut visual, "overview-chat-history");
    let back = bounds(&mut visual, "session-overview-back");
    let history = bounds(&mut visual, "overview-chat-history");
    assert!(history.left() >= back.right());
    visual.simulate_click(history.center(), Default::default());
    settle(&mut visual);
    source
        .read_with(cx, |shell, _| {
            assert!(shell.command_palette.is_some());
            assert!(shell.session_overview);
            assert!(!shell.settings.sidebar_collapsed);
        })
        .unwrap();
    visual.simulate_keystrokes("escape");
    settle(&mut visual);
    source
        .update(cx, |shell, window, cx| {
            shell.close_session_overview(window, cx);
            shell.route = Route::Settings(SettingsSection::Appearance);
            cx.notify();
        })
        .unwrap();
    for collapsed in [false, true] {
        source
            .update(cx, |shell, _, cx| {
                shell.settings.sidebar_collapsed = collapsed;
                shell.sidebar_tween = None;
                cx.notify();
            })
            .unwrap();
        settle(&mut visual);
        assert_history_location(&mut visual, "titlebar-chat-history");
        let history = bounds(&mut visual, "titlebar-chat-history");
        visual.simulate_click(history.center(), Default::default());
        settle(&mut visual);
        source
            .read_with(cx, |shell, _| {
                assert!(shell.command_palette.is_some());
                assert!(matches!(
                    shell.route,
                    Route::Settings(SettingsSection::Appearance)
                ));
                assert_eq!(shell.settings.sidebar_collapsed, collapsed);
            })
            .unwrap();
        visual.simulate_keystrokes("escape");
        settle(&mut visual);
    }
}

#[gpui::test]
fn workspace_shared_header_session_click_and_escape_preserve_tabs_and_draft(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, true, 1200.0);
    let before_tabs = tabs(source, cx);
    let before_session = source
        .read_with(cx, |shell, _| shell.chat_tabs[shell.chat_tab].id.clone())
        .unwrap();
    let trigger = bounds(&mut visual, "workspace-session-quick-switcher");
    visual.simulate_click(trigger.center(), Default::default());
    settle(&mut visual);
    assert!(
        visual
            .debug_bounds("workspace-session-quick-menu-card")
            .is_some()
    );
    source
        .read_with(cx, |shell, _| {
            assert!(shell.session_quick_switcher.is_open())
        })
        .unwrap();

    visual.simulate_keystrokes("escape");
    settle(&mut visual);
    source
        .read_with(cx, |shell, cx| {
            assert!(!shell.session_quick_switcher.is_open());
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, before_session);
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    assert_eq!(tabs(source, cx), before_tabs);
    // Escape restores the trigger's keyboard focus; Down must reopen it.
    visual.simulate_keystrokes("down");
    settle(&mut visual);
    source
        .read_with(cx, |shell, _| {
            assert!(shell.session_quick_switcher.is_open())
        })
        .unwrap();
    visual.simulate_keystrokes("escape");
    settle(&mut visual);
    assert_eq!(tabs(source, cx), before_tabs);
}

#[gpui::test]
fn workspace_shared_header_tearoff_anchor_matches_the_new_normal_window_tab(
    cx: &mut TestAppContext,
) {
    let (_dir, source, _visual) = setup(cx, true, 900.0);
    let pointer = point(px(1100.0), px(240.0));
    let grab = point(px(37.0), px(13.0));
    let (session, destination) = source
        .update(cx, |shell, window, cx| {
            shell.chat_tabs[shell.chat_tab].title = Some(
                "A very long session title whose shaped width is capped by the destination window"
                    .into(),
            );
            shell.save_window_record(cx);
            let session = shell.park_chat_tab(cx);
            // Source chrome may have fullscreen clearance; the new window does not.
            shell.fullscreen = Some(true);
            let destination = shell
                .move_workspace_tab_to_new_window(
                    0,
                    PanelTab::Chat("chat-a".into()),
                    Some((pointer, grab)),
                    window,
                    cx,
                )
                .unwrap();
            (session, destination)
        })
        .unwrap();
    let mut destination_visual = VisualTestContext::from_window(destination.into(), cx);
    settle(&mut destination_visual);
    let tab = bounds(&mut destination_visual, "panel-tab-0-0");
    let (actual_window, target_width) = destination
        .update(cx, |_, window, _| {
            (window.bounds(), f32::from(window.viewport_size().width))
        })
        .unwrap();
    let (predicted_origin, expected_window) = source
        .update(cx, |shell, window, cx| {
            let predicted = shell.new_window_tab_origin(&session, Some("chat-a"), target_width, cx);
            let geometry =
                crate::workspace_window_geometry_at(pointer, tab.origin + grab, window, cx)
                    .unwrap();
            (predicted, geometry.bounds())
        })
        .unwrap();

    assert!((predicted_origin.x - tab.left()).abs() < px(0.5));
    assert!((predicted_origin.y - tab.top()).abs() < px(0.5));
    assert_eq!(
        actual_window, expected_window,
        "the original grab point anchors the actual destination tab, subject to display fitting"
    );
    near(
        tab.top(),
        5.0,
        "the new normal window starts with the shared header",
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}
