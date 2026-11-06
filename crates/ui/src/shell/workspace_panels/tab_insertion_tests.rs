//! Internal placement cues and commits use the same pointer-selected tab slot.
use super::*;
use gpui::{AppContext as _, Bounds, TestAppContext, VisualTestContext, WindowHandle};

fn setup(
    cx: &mut TestAppContext,
    stacked: bool,
    empty_lower: bool,
) -> (tempfile::TempDir, WindowHandle<Shell>, VisualTestContext) {
    let (dir, source) = super::window_transfer_tests::setup(cx);
    source
        .update(cx, |shell, window, cx| {
            shell.settings.sidebar_collapsed = true;
            shell.sidebar_tween = None;
            shell.reduced_motion = true;
            shell.state.update(cx, |state, cx| {
                for id in ["chat-c", "chat-d"] {
                    state.chats.push(
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "fixture-device", "title": id,
                            "archived": false, "createdAt": "2026-10-31T00:00:00Z"
                        }))
                        .unwrap(),
                    );
                }
                cx.notify();
            });
            if stacked {
                let layout = shell.panel_layout_mut(cx);
                layout.axis = SplitAxis::Vertical;
                let lower = layout.add_panel(0);
                assert_eq!(lower, 1);
                if !empty_lower {
                    layout.insert(lower, PanelTab::Chat("chat-c".into()));
                    layout.insert(lower, PanelTab::Chat("chat-d".into()));
                    layout.panel_mut(lower).unwrap().active = 0;
                }
                layout.focused = 0;
                layout.equalize();
            }
            window.focus(&shell.composer.focus_handle(cx), cx);
            cx.notify();
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(source.into(), cx);
    visual.simulate_resize(gpui::size(px(1200.0), px(1000.0)));
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
        .unwrap_or_else(|| panic!("missing {selector}"))
}

fn panel_tabs(source: WindowHandle<Shell>, panel: u64, cx: &mut TestAppContext) -> Vec<PanelTab> {
    source
        .read_with(cx, |shell, cx| {
            shell
                .panel_layout(cx)
                .unwrap()
                .panel(panel)
                .unwrap()
                .tabs
                .clone()
        })
        .unwrap()
}

fn pickup(source: WindowHandle<Shell>, visual: &mut VisualTestContext) {
    let start = visual
        .debug_bounds("panel-tab-content-0-0")
        .or_else(|| visual.debug_bounds("instrument-slot-0"))
        .unwrap()
        .center();
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
}

fn assert_cleared(source: WindowHandle<Shell>, visual: &mut VisualTestContext) {
    settle(visual);
    assert!(!visual.cx.update(|cx| cx.has_active_drag()));
    assert!(visual.debug_bounds("window-rejoin-tab-cue-0").is_none());
    assert!(visual.debug_bounds("window-rejoin-tab-cue-1").is_none());
    source
        .read_with(&mut visual.cx, |shell, _| {
            assert!(shell.workspace_panels.window_drag.is_none())
        })
        .unwrap();
}

/// A tab dropped on another panel's slot joins the end of that panel, without
/// losing what was being typed in it.
#[gpui::test]
fn panel_tab_insertion_a_slot_takes_a_dropped_tab_at_the_end(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx, true, false);
    let pointer = bounds(&mut visual, "instrument-slot-1").center();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(pointer, Some(MouseButton::Left), Default::default());
    settle(&mut visual);
    assert_eq!(
        panel_tabs(source, 1, cx),
        vec![
            PanelTab::Chat("chat-c".into()),
            PanelTab::Chat("chat-d".into())
        ],
        "hover cannot mutate placement"
    );
    visual.simulate_mouse_up(pointer, MouseButton::Left, Default::default());
    settle(&mut visual);
    assert_eq!(
        panel_tabs(source, 1, cx),
        vec![
            PanelTab::Chat("chat-c".into()),
            PanelTab::Chat("chat-d".into()),
            PanelTab::Chat("chat-a".into())
        ]
    );
    assert_eq!(
        panel_tabs(source, 0, cx),
        vec![PanelTab::Chat("chat-b".into())]
    );
    source
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(layout.panel(1).unwrap().active, 2);
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
    assert_cleared(source, &mut visual);
}

#[gpui::test]
fn panel_tab_insertion_an_empty_panels_slot_accepts_the_tab(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx, true, true);
    let pointer = bounds(&mut visual, "instrument-slot-1").center();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(pointer, Some(MouseButton::Left), Default::default());
    settle(&mut visual);
    visual.simulate_mouse_up(pointer, MouseButton::Left, Default::default());
    settle(&mut visual);
    assert_eq!(
        panel_tabs(source, 1, cx),
        vec![PanelTab::Chat("chat-a".into())]
    );
    assert_eq!(
        panel_tabs(source, 0, cx),
        vec![PanelTab::Chat("chat-b".into())]
    );
    assert_cleared(source, &mut visual);
}

#[gpui::test]
fn panel_tab_insertion_escape_over_another_panel_leaves_the_tabs_alone(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx, true, false);
    let before = (panel_tabs(source, 0, cx), panel_tabs(source, 1, cx));
    pickup(source, &mut visual);
    let body = bounds(&mut visual, "workspace-panel-body-1").center();
    visual.simulate_mouse_move(body, Some(MouseButton::Left), Default::default());
    settle(&mut visual);
    assert_eq!(
        (panel_tabs(source, 0, cx), panel_tabs(source, 1, cx)),
        before
    );
    visual.simulate_keystrokes("escape");
    visual.simulate_mouse_up(body, MouseButton::Left, Default::default());
    assert_cleared(source, &mut visual);
    assert_eq!(
        (panel_tabs(source, 0, cx), panel_tabs(source, 1, cx)),
        before
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}

#[gpui::test]
fn panel_tab_insertion_same_panel_reorder_commits_after_the_marked_last_tab(
    cx: &mut TestAppContext,
) {
    let (_dir, source, mut visual) = setup(cx, false, false);
    let last = bounds(&mut visual, "panel-tab-0-1");
    let content = bounds(&mut visual, "panel-tab-content-0-1");
    let pointer = point(last.right() - px(4.0), content.center().y);
    pickup(source, &mut visual);
    visual.simulate_mouse_move(pointer, Some(MouseButton::Left), Default::default());
    settle(&mut visual);
    let marker = bounds(&mut visual, "window-rejoin-tab-cue-0");
    assert!((marker.left() - last.right()).abs() < px(0.5));
    assert!((marker.center().y - content.center().y).abs() < px(0.5));
    visual.simulate_mouse_up(pointer, MouseButton::Left, Default::default());
    settle(&mut visual);
    assert_eq!(
        panel_tabs(source, 0, cx),
        vec![
            PanelTab::Chat("chat-b".into()),
            PanelTab::Chat("chat-a".into())
        ]
    );
    assert_cleared(source, &mut visual);
}

#[gpui::test]
fn panel_tab_insertion_shared_header_session_controls_are_not_a_drop_slot(cx: &mut TestAppContext) {
    let (_dir, source, mut visual) = setup(cx, false, false);
    let before = panel_tabs(source, 0, cx);
    let prefix = bounds(&mut visual, "workspace-session-quick-switcher").center();
    pickup(source, &mut visual);
    visual.simulate_mouse_move(prefix, Some(MouseButton::Left), Default::default());
    settle(&mut visual);
    assert!(visual.debug_bounds("window-rejoin-tab-cue-0").is_none());
    visual.simulate_mouse_up(prefix, MouseButton::Left, Default::default());
    assert_cleared(source, &mut visual);
    assert_eq!(panel_tabs(source, 0, cx), before);
    source
        .read_with(cx, |shell, _| {
            assert!(!shell.session_quick_switcher.is_open())
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}
