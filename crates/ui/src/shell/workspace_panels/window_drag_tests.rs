//! Production Shell rendering and pointer/key dispatch, with desktop previews
//! disabled by the headless platform rather than replaced with drag-state flags.
use super::*;
use gpui::{AppContext as _, TestAppContext, VisualTestContext, WindowHandle};

fn setup(cx: &mut TestAppContext) -> (tempfile::TempDir, WindowHandle<Shell>, VisualTestContext) {
    let (dir, source) = super::window_transfer_tests::setup(cx);
    source
        .update(cx, |shell, window, cx| {
            window.focus(&shell.composer.focus_handle(cx), cx);
            cx.notify();
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(source.into(), cx);
    visual.simulate_resize(gpui::size(px(1200.0), px(760.0)));
    visual.update(|window, cx| window.draw(cx).clear());
    visual.run_until_parked();
    assert!(
        visual.debug_bounds("panel-tab-0-0").is_some(),
        "the complete Shell must render its panel tabs"
    );
    (dir, source, visual)
}

fn tabs(source: WindowHandle<Shell>, cx: &mut TestAppContext) -> Vec<PanelTab> {
    source
        .read_with(cx, |shell, cx| {
            shell.panel_layout(cx).unwrap().panels[0].tabs.clone()
        })
        .unwrap()
}

fn pickup(source: WindowHandle<Shell>, visual: &mut VisualTestContext) -> Point<Pixels> {
    let start = visual.debug_bounds("panel-tab-0-0").unwrap().center();
    visual.simulate_mouse_down(start, MouseButton::Left, Default::default());
    visual.simulate_mouse_move(
        start + point(px(12.0), px(4.0)),
        Some(MouseButton::Left),
        Default::default(),
    );
    assert!(visual.cx.update(|cx| cx.has_active_drag()));
    source
        .read_with(&mut visual.cx, |shell, _| {
            assert!(shell.workspace_panels.window_drag.is_some())
        })
        .unwrap();
    start
}

fn assert_drag_cleared(source: WindowHandle<Shell>, visual: &mut VisualTestContext) {
    visual.update(|window, cx| window.draw(cx).clear());
    visual.run_until_parked();
    assert!(!visual.cx.update(|cx| cx.has_active_drag()));
    source
        .read_with(&mut visual.cx, |shell, _| {
            assert!(shell.workspace_panels.window_drag.is_none());
            assert!(!shell.workspace_panels.drag_outside.get());
            assert!(shell.workspace_panels.split_previews.is_empty());
        })
        .unwrap();
}

fn empty_rejoin_target(
    source: WindowHandle<Shell>,
    cx: &mut TestAppContext,
) -> (WindowHandle<Shell>, VisualTestContext) {
    let target = source
        .update(cx, |shell, _, cx| {
            let state = cx.new(|cx| AppState::for_window(&shell.state, cx));
            let mut record = settings::SavedWorkspaceWindow::from_settings(
                "empty-rejoin-target".into(),
                &shell.settings,
            );
            record.geometry = Some(settings::WindowGeometry {
                display_uuid: None,
                x: 1300.0,
                y: 30.0,
                width: 900.0,
                height: 700.0,
            });
            crate::open_workspace_window(state, shell.boot.clone(), record, cx).unwrap()
        })
        .unwrap();
    target
        .update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs.clear();
            layout.panels[0].active = 0;
            layout.focused = layout.panels[0].id;
            layout.last_selected = Some(None);
            cx.notify();
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(target.into(), cx);
    visual.update(|window, cx| window.draw(cx).clear());
    visual.run_until_parked();
    assert!(tabs(target, cx).is_empty());
    (target, visual)
}

fn rejoin_empty_body(cx: &mut TestAppContext, release_in_target: bool) {
    let (_dir, source, mut source_visual) = setup(cx);
    let (target, mut target_visual) = empty_rejoin_target(source, cx);
    let local = target_visual
        .debug_bounds("workspace-panel-body-0")
        .unwrap()
        .center();
    let global = target
        .update(cx, |_, window, _| window.bounds().origin + local)
        .unwrap();
    let outside = source
        .update(cx, |_, window, _| global - window.bounds().origin)
        .unwrap();
    pickup(source, &mut source_visual);
    source_visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    target
        .read_with(cx, |shell, _| {
            let hover = shell.workspace_panels.window_drop_hover.as_ref().unwrap();
            assert_eq!(hover.panel, 0);
            assert!(!hover.header);
        })
        .unwrap();
    if release_in_target {
        target_visual.simulate_mouse_up(local, MouseButton::Left, Default::default());
        target_visual.run_until_parked();
    } else {
        source_visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
        source_visual.run_until_parked();
    }
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_eq!(tabs(source, cx), vec![PanelTab::Chat("chat-b".into())]);
    assert_eq!(tabs(target, cx), vec![PanelTab::Chat("chat-a".into())]);
    target
        .read_with(cx, |shell, cx| {
            assert!(shell.workspace_panels.window_drop_hover.is_none());
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    assert_drag_cleared(source, &mut source_visual);
}

#[gpui::test]
fn window_tab_drag_rejoins_an_empty_window_body_without_a_tab_bar(cx: &mut TestAppContext) {
    rejoin_empty_body(cx, false);
}

#[gpui::test]
fn window_tab_drag_rejoins_when_mouse_up_is_dispatched_to_the_target_window(
    cx: &mut TestAppContext,
) {
    rejoin_empty_body(cx, true);
}

#[gpui::test]
fn window_tab_drag_rejoins_at_the_highlighted_tab_insertion_slot(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let (target, mut target_visual) = empty_rejoin_target(source, cx);
    target
        .update(cx, |shell, _, cx| {
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::New(100), PanelTab::New(101)];
            shell.composer.update(cx, |composer, cx| {
                composer.current_key = "".into();
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("Keep this target draft", cx));
            });
            cx.notify();
        })
        .unwrap();
    target_visual.update(|window, cx| window.draw(cx).clear());
    target_visual.run_until_parked();
    let tab = target_visual.debug_bounds("panel-tab-0-1").unwrap();
    let local = point(tab.left() + px(4.0), tab.center().y);
    let global = target
        .update(cx, |_, window, _| window.bounds().origin + local)
        .unwrap();
    let outside = source
        .update(cx, |_, window, _| global - window.bounds().origin)
        .unwrap();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    target_visual.update(|window, cx| window.draw(cx).clear());
    target
        .read_with(cx, |shell, _| {
            let hover = shell.workspace_panels.window_drop_hover.as_ref().unwrap();
            assert!(hover.header);
            assert_eq!(hover.before, Some(1));
        })
        .unwrap();
    let cue = target_visual
        .debug_bounds("window-rejoin-tab-cue-0")
        .unwrap();
    let highlighted = target_visual.debug_bounds("panel-tab-0-1").unwrap();
    assert!(
        (cue.left() - highlighted.left()).abs() < px(1.0),
        "the marker must show the selected insertion slot: {cue:?}, {highlighted:?}"
    );
    let content = target_visual.debug_bounds("panel-tab-content-0-1").unwrap();
    assert!(
        (cue.center().y - content.center().y).abs() < px(1.0),
        "the marker must align with the title row: {cue:?}, {content:?}"
    );
    visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
    assert_eq!(
        tabs(target, cx),
        vec![
            PanelTab::New(100),
            PanelTab::Chat("chat-a".into()),
            PanelTab::New(101)
        ]
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_stale_source_clears_the_other_windows_drop_feedback(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let (target, mut target_visual) = empty_rejoin_target(source, cx);
    let local = target_visual
        .debug_bounds("workspace-panel-body-0")
        .unwrap()
        .center();
    let global = target
        .update(cx, |_, window, _| window.bounds().origin + local)
        .unwrap();
    let outside = source
        .update(cx, |_, window, _| global - window.bounds().origin)
        .unwrap();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    source
        .update(cx, |shell, _, cx| {
            shell.panel_layout_mut(cx).panels[0]
                .tabs
                .retain(|tab| tab != &PanelTab::Chat("chat-a".into()));
        })
        .unwrap();
    visual.simulate_mouse_move(
        outside + point(px(1.0), px(1.0)),
        Some(MouseButton::Left),
        Default::default(),
    );
    target
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.window_drop_hover.is_none())
        })
        .unwrap();
    assert!(tabs(target, cx).is_empty());
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_below_pickup_threshold_remains_a_normal_tab_click(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let before = tabs(source, cx);
    let target = visual.debug_bounds("panel-tab-0-1").unwrap().center();
    visual.simulate_mouse_down(target, MouseButton::Left, Default::default());
    let release = target + point(px(1.0), px(0.0));
    visual.simulate_mouse_move(release, Some(MouseButton::Left), Default::default());
    assert!(!cx.update(|cx| cx.has_active_drag()));
    source
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.window_drag.is_none())
        })
        .unwrap();
    visual.simulate_mouse_up(release, MouseButton::Left, Default::default());
    assert_eq!(tabs(source, cx), before);
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    source
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            );
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_outside_then_reentry_preserves_tabs_and_live_input(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let before = tabs(source, cx);
    let start = pickup(source, &mut visual);
    let outside =
        visual.update(|window, _| point(window.viewport_size().width + px(32.0), px(200.0)));
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    source
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.drag_outside.get())
        })
        .unwrap();
    assert_eq!(
        cx.update(|cx| cx.windows().len()),
        1,
        "crossing the boundary only previews a window"
    );
    visual.simulate_mouse_move(start, Some(MouseButton::Left), Default::default());
    assert!(cx.update(|cx| cx.has_active_drag()));
    source
        .read_with(cx, |shell, _| {
            assert!(!shell.workspace_panels.drag_outside.get())
        })
        .unwrap();
    assert_eq!(tabs(source, cx), before);
    visual.simulate_mouse_up(start, MouseButton::Left, Default::default());
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    source
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_escape_in_root_capture_cancels_later_outside_release(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let before = tabs(source, cx);
    pickup(source, &mut visual);
    let outside = point(px(-32.0), px(200.0));
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    source
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.drag_outside.get())
        })
        .unwrap();
    // This reaches Shell's capture handler through the focused composer path.
    visual.simulate_keystrokes("escape");
    assert!(!cx.update(|cx| cx.has_active_drag()));
    visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
    assert_eq!(tabs(source, cx), before);
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_ignores_hover_moves_without_the_initiating_left_button(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let start = pickup(source, &mut visual);
    let outside = point(px(-32.0), px(200.0));
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    visual.simulate_mouse_move(start, None, Default::default());
    source
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.drag_outside.get())
        })
        .unwrap();
    assert!(cx.update(|cx| cx.has_active_drag()));
    visual.simulate_mouse_move(start, Some(MouseButton::Left), Default::default());
    visual.simulate_mouse_move(outside, None, Default::default());
    source
        .read_with(cx, |shell, _| {
            assert!(!shell.workspace_panels.drag_outside.get())
        })
        .unwrap();
    visual.simulate_mouse_up(start, MouseButton::Left, Default::default());
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_release_just_inside_boundary_cancels(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx);
    let before = tabs(source, cx);
    pickup(source, &mut visual);
    let width = visual.update(|window, _| window.viewport_size().width);
    visual.simulate_mouse_move(
        point(width + px(32.0), px(200.0)),
        Some(MouseButton::Left),
        Default::default(),
    );
    let inside = point(width - px(1.0), px(200.0));
    visual.simulate_mouse_move(inside, Some(MouseButton::Left), Default::default());
    visual.simulate_mouse_up(inside, MouseButton::Left, Default::default());
    assert_eq!(tabs(source, cx), before);
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_edge_preview_survives_outside_reentry_and_commits_an_internal_split(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx);
    let original = visual.debug_bounds("workspace-panel-body-0").unwrap();
    let edge = point(original.right() - px(4.0), original.center().y);
    pickup(source, &mut visual);
    visual.simulate_mouse_move(edge, Some(MouseButton::Left), Default::default());
    let preview = visual
        .debug_bounds("panel-split-ghost-0-right")
        .expect("internal split preview");
    let outside =
        visual.update(|window, _| point(window.viewport_size().width + px(32.0), px(200.0)));
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    assert!(visual.debug_bounds("panel-split-ghost-0-right").is_none());
    assert_eq!(
        visual.debug_bounds("workspace-panel-body-0").unwrap(),
        original
    );
    visual.simulate_mouse_move(edge, Some(MouseButton::Left), Default::default());
    assert_eq!(
        visual.debug_bounds("panel-split-ghost-0-right").unwrap(),
        preview
    );
    visual.simulate_mouse_up(edge, MouseButton::Left, Default::default());
    source
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(
                layout.location(&PanelTab::Chat("chat-b".into())).unwrap().0,
                0
            );
            assert_ne!(
                layout.location(&PanelTab::Chat("chat-a".into())).unwrap().0,
                0
            );
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    assert_eq!(
        cx.update(|cx| cx.windows().len()),
        1,
        "the internal drop must not detach a window"
    );
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_internal_panel_body_drop_reaches_the_existing_transfer_handler(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx);
    source
        .update(cx, |shell, _, cx| {
            shell.workspace_split(SplitAxis::Horizontal, cx)
        })
        .unwrap();
    visual.update(|window, cx| window.draw(cx).clear());
    visual.run_until_parked();
    let body = visual
        .debug_bounds("workspace-panel-body-1")
        .unwrap()
        .center();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(body, Some(MouseButton::Left), Default::default());
    visual.simulate_mouse_up(body, MouseButton::Left, Default::default());
    source
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(
                layout.location(&PanelTab::Chat("chat-a".into())),
                Some((1, 1))
            );
            assert_eq!(
                layout.location(&PanelTab::Chat("chat-b".into())),
                Some((0, 0))
            );
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    assert_drag_cleared(source, &mut visual);
}

fn release_outside_at(cx: &mut TestAppContext, edge: PanelEdge, distance: f32, arm_first: bool) {
    let (_dir, source, mut visual) = setup(cx);
    let source_state = source
        .read_with(cx, |shell, _| shell.state.entity_id())
        .unwrap();
    let source_session = source
        .read_with(cx, |shell, _| shell.chat_tabs[shell.chat_tab].id.clone())
        .unwrap();
    pickup(source, &mut visual);
    let edge_point = |size: gpui::Size<Pixels>, distance: f32| match edge {
        PanelEdge::Left => point(px(-distance), px(200.0)),
        PanelEdge::Right => point(size.width + px(distance), px(200.0)),
        PanelEdge::Top => point(px(400.0), px(-distance)),
        PanelEdge::Bottom => point(px(400.0), size.height + px(distance)),
    };
    let size = visual.update(|window, _| window.viewport_size());
    if arm_first {
        visual.simulate_mouse_move(
            edge_point(size, 32.0),
            Some(MouseButton::Left),
            Default::default(),
        );
    }
    let outside = edge_point(size, distance);
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
    let windows = cx.update(|cx| cx.windows());
    assert_eq!(windows.len(), 2);
    let destination = windows
        .into_iter()
        .filter(|window| window.window_id() != source.window_id())
        .find_map(|window| window.downcast::<Shell>())
        .unwrap();
    assert_eq!(tabs(source, cx), vec![PanelTab::Chat("chat-b".into())]);
    destination
        .read_with(cx, |shell, cx| {
            assert_ne!(shell.state.entity_id(), source_state);
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, source_session);
            assert_eq!(
                shell.panel_layout(cx).unwrap().panels[0].tabs,
                vec![PanelTab::Chat("chat-a".into())]
            );
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-a")
            );
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    source
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            )
        })
        .unwrap();
    // A duplicate/native late release cannot consume the transfer twice.
    visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_left_release_creates_exactly_one_independent_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Left, 32.0, false);
}
#[gpui::test]
fn window_tab_drag_right_release_creates_exactly_one_independent_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Right, 32.0, false);
}
#[gpui::test]
fn window_tab_drag_top_release_creates_exactly_one_independent_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Top, 32.0, false);
}
#[gpui::test]
fn window_tab_drag_bottom_release_creates_exactly_one_independent_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Bottom, 32.0, false);
}

#[gpui::test]
fn window_tab_drag_release_over_existing_workspace_rejects_without_a_third_window(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx);
    let before = tabs(source, cx);
    let target = source
        .update(cx, |shell, _, cx| {
            let state = cx.new(|cx| AppState::for_window(&shell.state, cx));
            let mut record = settings::SavedWorkspaceWindow::from_settings(
                "existing-target".into(),
                &shell.settings,
            );
            record.geometry = Some(settings::WindowGeometry {
                display_uuid: None,
                x: 1300.0,
                y: 30.0,
                width: 900.0,
                height: 700.0,
            });
            crate::open_workspace_window(state, shell.boot.clone(), record, cx).unwrap()
        })
        .unwrap();
    let mut target_visual = VisualTestContext::from_window(target.into(), cx);
    target_visual.update(|window, cx| window.draw(cx).clear());
    target_visual.run_until_parked();
    let target_before = tabs(target, cx);
    let global = target
        .update(cx, |_, window, _| window.bounds().center())
        .unwrap();
    let outside = source
        .update(cx, |_, window, _| global - window.bounds().origin)
        .unwrap();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    source
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.drag_outside.get())
        })
        .unwrap();
    visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_eq!(tabs(source, cx), before);
    assert_eq!(tabs(target, cx), target_before);
    assert_drag_cleared(source, &mut visual);
}

#[gpui::test]
fn window_tab_drag_keeps_destination_metadata_title_at_its_resting_baseline(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut source_visual) = setup(cx);
    let (target, mut target_visual) = empty_rejoin_target(source, cx);
    target
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, _| {
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "chat-b")
                    .unwrap()
                    .config = Some(
                    serde_json::from_value(serde_json::json!({
                        "harness": "graff", "model": "fixture-model",
                        "reasoning": null, "sandbox": "workspace-write"
                    }))
                    .unwrap(),
                );
            });
            shell.focus_workspace_tab(0, PanelTab::Chat("chat-b".into()), window, cx);
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Chat("chat-b".into())];
            layout.panels[0].active = 0;
            cx.notify();
        })
        .unwrap();
    target_visual.update(|window, cx| window.draw(cx).clear());
    target_visual.run_until_parked();
    let body = target_visual
        .debug_bounds("workspace-panel-body-0")
        .unwrap()
        .center();
    target_visual.simulate_mouse_move(body, None, Default::default());
    target_visual.run_until_parked();
    let tab = target_visual.debug_bounds("panel-tab-0-0").unwrap();
    let resting_title = target_visual.debug_bounds("panel-tab-0-0-title").unwrap();
    let resting_icon = target_visual.debug_bounds("panel-tab-icon-0-0").unwrap();
    let content = target_visual.debug_bounds("panel-tab-content-0-0").unwrap();
    assert!((resting_title.center().y - content.center().y).abs() < px(0.5));
    assert!((resting_icon.center().y - content.center().y).abs() < px(0.5));

    // Ordinary pointer hover still reveals this destination's real metadata.
    target_visual.simulate_mouse_move(tab.center(), None, Default::default());
    target_visual.run_until_parked();
    let revealed_title = target_visual.debug_bounds("panel-tab-0-0-title").unwrap();
    assert!((resting_title.top() - revealed_title.top() - px(6.5)).abs() < px(0.5));
    // Keyboard focus can keep metadata revealed even after hover is cleared.
    let tab_focus = target
        .update(cx, |shell, window, cx| {
            let focus = shell.workspace_panels.controls["panel-tab-0-0"].clone();
            window.focus(&focus, cx);
            cx.notify();
            focus
        })
        .unwrap();

    let local = point(tab.left() + px(24.0), content.center().y);
    let global = target
        .update(cx, |_, window, _| window.bounds().origin + local)
        .unwrap();
    let outside = source
        .update(cx, |_, window, _| global - window.bounds().origin)
        .unwrap();
    pickup(source, &mut source_visual);
    source_visual.simulate_mouse_move(outside, Some(MouseButton::Left), Default::default());
    // GPUI clears hover during a drag; the tab's logical keyboard focus still
    // exists when the incoming move is delivered to the receiving window.
    target_visual.simulate_mouse_move(local, Some(MouseButton::Left), Default::default());
    target_visual.run_until_parked();
    target_visual.update(|window, cx| window.draw(cx).clear());
    target
        .update(cx, |shell, window, _| {
            assert!(
                tab_focus.is_focused(window),
                "the destination tab's logical focus must remain pinned"
            );
            assert!(
                shell
                    .workspace_panels
                    .window_drop_hover
                    .as_ref()
                    .is_some_and(|hover| hover.header)
            );
        })
        .unwrap();
    let dragging_title = target_visual.debug_bounds("panel-tab-0-0-title").unwrap();
    let dragging_icon = target_visual.debug_bounds("panel-tab-icon-0-0").unwrap();
    let cue = target_visual
        .debug_bounds("window-rejoin-tab-cue-0")
        .unwrap();
    assert!(
        (dragging_title.center().y - resting_title.center().y).abs() < px(0.5),
        "a foreign tab drag must keep the destination title at rest: {resting_title:?}, {dragging_title:?}"
    );
    assert!((dragging_icon.center().y - resting_icon.center().y).abs() < px(0.5));
    assert!((cue.center().y - dragging_title.center().y).abs() < px(0.5));

    source_visual.simulate_keystrokes("escape");
    source_visual.simulate_mouse_up(outside, MouseButton::Left, Default::default());
    assert_drag_cleared(source, &mut source_visual);
    target
        .update(cx, |shell, window, cx| {
            window.focus(&shell.composer.focus_handle(cx), cx);
            cx.notify();
        })
        .unwrap();
    target_visual.simulate_mouse_move(body, None, Default::default());
    target_visual.run_until_parked();
    assert_eq!(
        target_visual.debug_bounds("panel-tab-0-0-title"),
        Some(resting_title)
    );
    target_visual.simulate_mouse_move(tab.center(), None, Default::default());
    target_visual.run_until_parked();
    let after_drag = target_visual.debug_bounds("panel-tab-0-0-title").unwrap();
    assert!(
        (resting_title.top() - after_drag.top() - px(6.5)).abs() < px(0.5),
        "normal metadata hover must resume after the drag"
    );
}

#[gpui::test]
fn window_tab_drag_just_outside_left_creates_a_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Left, 1.0, false);
}

#[gpui::test]
fn window_tab_drag_just_outside_right_creates_a_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Right, 1.0, false);
}

#[gpui::test]
fn window_tab_drag_just_outside_top_creates_a_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Top, 1.0, false);
}

#[gpui::test]
fn window_tab_drag_just_outside_bottom_creates_a_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Bottom, 1.0, false);
}

#[gpui::test]
fn window_tab_drag_returning_to_outer_buffer_still_creates_a_window(cx: &mut TestAppContext) {
    release_outside_at(cx, PanelEdge::Right, 12.0, true);
}
