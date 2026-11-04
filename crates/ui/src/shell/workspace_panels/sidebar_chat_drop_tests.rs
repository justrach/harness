//! Chats dragged from the sidebar and files dragged from the desktop reach
//! the panel they are released on. Runs through the whole Shell, as people
//! get it: the legacy split's drop tests paint a host the app no longer uses.
use super::*;
use gpui::{
    ExternalPaths, FileDropEvent, Modifiers, PlatformInput, TestAppContext, VisualTestContext,
};
use std::path::PathBuf;

fn fixture(cx: &mut TestAppContext) -> (tempfile::TempDir, gpui::WindowHandle<Shell>) {
    let (dir, host) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
    host.update(cx, |shell, _, cx| {
        shell.debug_gate = Some(GatePhase::Ready);
        shell.splash = SplashPhase::Gone;
        shell.boot_restored = true;
        shell.reduced_motion = true;
        crate::settings::set_sidebar_task_view(false, cx);
        shell.sync_independent_settings(cx);
        shell.settings.sidebar_all_projects = true;
        shell.ensure_workspace_sessions(cx);
        shell.sync_panel_workspace(cx);
        cx.notify();
    })
    .unwrap();
    (dir, host)
}

fn redraw(visual: &mut VisualTestContext) {
    visual.run_until_parked();
    // Cached views replay their scene, but test selectors need a fresh paint.
    visual.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
}

fn window(cx: &mut TestAppContext, host: gpui::WindowHandle<Shell>) -> VisualTestContext {
    let mut visual = VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(1200.0), px(760.0)));
    redraw(&mut visual);
    visual
}

fn selector(name: String) -> &'static str {
    Box::leak(name.into_boxed_str())
}

fn start_dragging_row(visual: &mut VisualTestContext, chat: &str) {
    let from = visual
        .debug_bounds(selector(format!("chat-{chat}")))
        .unwrap_or_else(|| panic!("the sidebar lists {chat}"))
        .center();
    visual.simulate_mouse_down(from, MouseButton::Left, Modifiers::default());
    visual.simulate_mouse_move(
        from + point(px(8.0), px(0.0)),
        Some(MouseButton::Left),
        Modifiers::default(),
    );
    redraw(visual);
}

fn release_on(visual: &mut VisualTestContext, target: &'static str) {
    let at = visual
        .debug_bounds(target)
        .unwrap_or_else(|| panic!("{target} shows during the drag"))
        .center();
    visual.simulate_mouse_move(at, Some(MouseButton::Left), Modifiers::default());
    visual.simulate_mouse_up(at, MouseButton::Left, Modifiers::default());
    redraw(visual);
}

fn zone(panel: u64, name: &str) -> &'static str {
    selector(format!("panel-chat-drop-{panel}-{name}"))
}

fn focused_panel(host: gpui::WindowHandle<Shell>, cx: &mut TestAppContext) -> u64 {
    host.update(cx, |shell, _, cx| shell.panel_layout(cx).unwrap().focused)
        .unwrap()
}

/// `(panel tabs per panel, axis, selected chat)` after a drop.
fn snapshot(
    host: gpui::WindowHandle<Shell>,
    cx: &mut TestAppContext,
) -> (Vec<Vec<PanelTab>>, SplitAxis, Option<String>) {
    host.update(cx, |shell, _, cx| {
        let layout = shell.panel_layout(cx).unwrap();
        (
            layout.panels.iter().map(|p| p.tabs.clone()).collect(),
            layout.axis,
            shell.state.read(cx).selected_chat.clone(),
        )
    })
    .unwrap()
}

fn chat(id: &str) -> PanelTab {
    PanelTab::Chat(id.into())
}

#[gpui::test]
fn a_sidebar_chat_dropped_on_a_panels_right_edge_opens_beside_it(cx: &mut TestAppContext) {
    let (_dir, host) = fixture(cx);
    let first = focused_panel(host, cx);
    let mut visual = window(cx, host);
    start_dragging_row(&mut visual, "target");
    release_on(&mut visual, zone(first, "right"));
    let (panels, axis, selected) = snapshot(host, cx);
    assert_eq!(panels, vec![vec![chat("current")], vec![chat("target")]]);
    assert_eq!(axis, SplitAxis::Horizontal);
    assert_eq!(selected.as_deref(), Some("target"));
    host.update(cx, |shell, _, _| {
        assert!(shell.split_drop_session.is_none());
        assert!(shell.sidebar_session_transfer.is_none());
    })
    .unwrap();
    assert!(
        visual.debug_bounds(zone(first, "right")).is_none(),
        "the zones go with the drag"
    );
}

#[gpui::test]
fn a_sidebar_chat_dropped_on_a_panels_bottom_edge_opens_below_it(cx: &mut TestAppContext) {
    let (_dir, host) = fixture(cx);
    let first = focused_panel(host, cx);
    let mut visual = window(cx, host);
    start_dragging_row(&mut visual, "target");
    release_on(&mut visual, zone(first, "below"));
    let (panels, axis, selected) = snapshot(host, cx);
    assert_eq!(panels, vec![vec![chat("current")], vec![chat("target")]]);
    assert_eq!(axis, SplitAxis::Vertical);
    assert_eq!(selected.as_deref(), Some("target"));
}

#[gpui::test]
fn a_sidebar_chat_dropped_on_a_panels_middle_becomes_its_tab(cx: &mut TestAppContext) {
    let (_dir, host) = fixture(cx);
    let first = focused_panel(host, cx);
    let mut visual = window(cx, host);
    start_dragging_row(&mut visual, "target");
    release_on(&mut visual, zone(first, "here"));
    let (panels, _, selected) = snapshot(host, cx);
    assert_eq!(panels, vec![vec![chat("current"), chat("target")]]);
    assert_eq!(selected.as_deref(), Some("target"));
}

#[gpui::test]
fn a_chat_removed_during_its_drag_opens_nothing(cx: &mut TestAppContext) {
    let (_dir, host) = fixture(cx);
    let first = focused_panel(host, cx);
    let mut visual = window(cx, host);
    start_dragging_row(&mut visual, "target");
    host.update(cx, |shell, _, cx| {
        shell.state.update(cx, |state, _| {
            let mut chats: Vec<harness_proto::Chat> = state.chats.iter().cloned().collect();
            chats.retain(|chat| chat.id != "target");
            state.chats = chats.into();
        });
        cx.notify();
    })
    .unwrap();
    redraw(&mut visual);
    release_on(&mut visual, zone(first, "right"));
    let (panels, _, selected) = snapshot(host, cx);
    assert_eq!(panels, vec![vec![chat("current")]]);
    assert_eq!(selected.as_deref(), Some("current"));
}

fn image_file(dir: &tempfile::TempDir, name: &str) -> PathBuf {
    let path = dir.path().join(name);
    image::RgbaImage::from_pixel(2, 2, image::Rgba([40, 80, 120, 255]))
        .save(&path)
        .unwrap();
    path
}

fn drop_file(visual: &mut VisualTestContext, at: Point<Pixels>, path: PathBuf) {
    visual.update(|window, cx| {
        window.dispatch_event(
            PlatformInput::FileDrop(FileDropEvent::Entered {
                position: at,
                paths: ExternalPaths(vec![path].into()),
            }),
            cx,
        );
    });
    redraw(visual);
    visual.update(|window, cx| {
        window.dispatch_event(
            PlatformInput::FileDrop(FileDropEvent::Submit { position: at }),
            cx,
        );
    });
    redraw(visual);
}

fn body(visual: &mut VisualTestContext, panel: u64) -> Point<Pixels> {
    visual
        .debug_bounds(selector(format!("workspace-panel-body-{panel}")))
        .unwrap()
        .center()
}

#[gpui::test]
fn a_file_dropped_on_an_unfocused_panel_attaches_to_that_panels_chat(cx: &mut TestAppContext) {
    // Drops dispatch mouse-up through real transcripts, which finish the
    // process-global markdown selection. Share its test lock.
    let _selection = crate::markdown::selection::test_state_lock();
    let (dir, host) = fixture(cx);
    let second = host
        .update(cx, |shell, _, cx| {
            let layout = shell.panel_layout_mut(cx);
            let first = layout.focused;
            let second = layout.add_panel(first);
            layout.insert(second, chat("peer"));
            layout.focused = first;
            cx.notify();
            second
        })
        .unwrap();
    let mut visual = window(cx, host);
    let at = body(&mut visual, second);
    drop_file(&mut visual, at, image_file(&dir, "one.png"));
    host.update(cx, |shell, _, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, second);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        let composer = shell.composer.read(cx);
        assert_eq!(composer.current_key, "peer");
        assert_eq!(composer.staged().len(), 1);
        assert!(
            composer
                .attachments
                .get("current")
                .is_none_or(|a| a.is_empty())
        );
    })
    .unwrap();

    // Now focused, the panel's own dropzone takes it: once, not twice.
    let at = body(&mut visual, second);
    drop_file(&mut visual, at, image_file(&dir, "two.png"));
    host.update(cx, |shell, _, cx| {
        assert_eq!(shell.composer.read(cx).staged().len(), 2);
    })
    .unwrap();
}

#[gpui::test]
fn a_file_dropped_on_an_empty_panel_starts_a_conversation_there(cx: &mut TestAppContext) {
    let _selection = crate::markdown::selection::test_state_lock();
    let (dir, host) = fixture(cx);
    let second = host
        .update(cx, |shell, _, cx| {
            let layout = shell.panel_layout_mut(cx);
            let first = layout.focused;
            let second = layout.add_panel(first);
            layout.focused = first;
            cx.notify();
            second
        })
        .unwrap();
    let mut visual = window(cx, host);
    let at = body(&mut visual, second);
    drop_file(&mut visual, at, image_file(&dir, "one.png"));
    host.update(cx, |shell, _, cx| {
        let layout = shell.panel_layout(cx).unwrap();
        assert_eq!(layout.focused, second);
        assert!(matches!(
            layout.panel(second).unwrap().selected(),
            Some(PanelTab::Draft(_))
        ));
        assert_eq!(shell.composer.read(cx).staged().len(), 1);
        assert!(
            shell
                .composer
                .read(cx)
                .attachments
                .get("current")
                .is_none_or(|a| a.is_empty()),
            "nothing lands on the conversation that had focus"
        );
    })
    .unwrap();
}

#[gpui::test]
fn a_file_from_the_tree_dropped_on_an_unfocused_panel_mentions_it_there(cx: &mut TestAppContext) {
    let _selection = crate::markdown::selection::test_state_lock();
    let (_dir, host) = fixture(cx);
    let second = host
        .update(cx, |shell, _, cx| {
            let layout = shell.panel_layout_mut(cx);
            let first = layout.focused;
            let second = layout.add_panel(first);
            layout.insert(second, chat("peer"));
            layout.focused = first;
            cx.notify();
            second
        })
        .unwrap();
    let mut visual = window(cx, host);
    host.update(cx, |shell, window, cx| {
        shell.drop_workspace_path_on_panel(
            second,
            Some(chat("peer")),
            &crate::files::WorkspacePathDrag::new("src/lib.rs".into(), false),
            window,
            cx,
        );
    })
    .unwrap();
    redraw(&mut visual);
    host.update(cx, |shell, _, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, second);
        let composer = shell.composer.read(cx);
        assert_eq!(composer.current_key, "peer");
        let text = composer.input.read(cx).text();
        assert!(text.contains("lib.rs"), "{text:?}");
    })
    .unwrap();
}
