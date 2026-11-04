//! What a pointer costs with several panels open. A hover belongs to the view
//! that shows it: nothing here should rebuild the sidebar or another panel's
//! transcript, whose cost grows with every panel and session.
use super::*;
use crate::shell::SIDEBAR_RENDERS;
use crate::transcript::render_total;
use gpui::{TestAppContext, VisualTestContext};

fn two_panels(cx: &mut TestAppContext) -> (tempfile::TempDir, gpui::WindowHandle<Shell>, u64, u64) {
    let (dir, host) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
    let (first, second) = host
        .update(cx, |shell, _, cx| {
            shell.debug_gate = Some(GatePhase::Ready);
            shell.splash = SplashPhase::Gone;
            shell.boot_restored = true;
            crate::settings::set_sidebar_task_view(false, cx);
            shell.sync_independent_settings(cx);
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
            let layout = shell.panel_layout_mut(cx);
            let first = layout.focused;
            let second = layout.add_panel(first);
            layout.insert(second, PanelTab::Chat("peer".into()));
            layout.focused = first;
            cx.notify();
            (first, second)
        })
        .unwrap();
    (dir, host, first, second)
}

fn settle(visual: &mut VisualTestContext) {
    for _ in 0..4 {
        visual.update(|window, cx| {
            window.simulate_next_frame(cx);
        });
        visual.run_until_parked();
    }
}

fn body_center(visual: &mut VisualTestContext, panel: u64) -> gpui::Point<Pixels> {
    let name: &'static str = Box::leak(format!("workspace-panel-body-{panel}").into_boxed_str());
    visual.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    visual.debug_bounds(name).unwrap().center()
}

fn renders() -> (usize, u64) {
    (
        SIDEBAR_RENDERS.with(|n| n.get()),
        render_total("transcript"),
    )
}

#[gpui::test]
fn the_pointer_crossing_panels_leaves_the_sidebar_and_transcripts_cached(cx: &mut TestAppContext) {
    let (_dir, host, first, second) = two_panels(cx);
    let mut visual = VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(1400.0), px(800.0)));
    settle(&mut visual);
    let (a, b) = (
        body_center(&mut visual, first),
        body_center(&mut visual, second),
    );
    visual.simulate_mouse_move(a, None, Default::default());
    settle(&mut visual);

    let before = renders();
    for at in [b, a, b, a, b, a] {
        visual.simulate_mouse_move(at, None, Default::default());
        // A fade's frames, as the display would deliver them.
        settle(&mut visual);
    }
    let (sidebars, transcripts) = renders();
    assert_eq!(
        sidebars - before.0,
        0,
        "the sidebar has nothing to show for this"
    );
    // Six crossings of two panels: rebuilding both per frame would be ~48.
    assert!(
        transcripts - before.1 <= 12,
        "rebuilt transcripts {} times",
        transcripts - before.1
    );
}

#[gpui::test]
fn typing_with_the_pointer_on_a_panel_leaves_the_sidebar_cached(cx: &mut TestAppContext) {
    let (_dir, host, first, _) = two_panels(cx);
    let mut visual = VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(1400.0), px(800.0)));
    settle(&mut visual);
    let at = body_center(&mut visual, first);
    visual.simulate_mouse_move(at, None, Default::default());
    settle(&mut visual);
    host.update(cx, |shell, window, cx| {
        let focus = shell.composer.focus_handle(cx);
        window.focus(&focus, cx);
    })
    .unwrap();
    visual.simulate_keystrokes("right");
    settle(&mut visual);

    let before = renders();
    for key in ["h", "e", "l", "l", "o"] {
        visual.simulate_keystrokes(key);
        visual.run_until_parked();
    }
    let (sidebars, transcripts) = renders();
    assert_eq!(
        sidebars - before.0,
        0,
        "the pointer resting on a panel rebuilt the sidebar"
    );
    assert_eq!(transcripts - before.1, 0);
}

/// Typing happens in one panel. The composer drawn in each of the others shows
/// nothing that changed, and rebuilding it costs a text layout per panel.
#[gpui::test]
fn typing_leaves_a_parked_panels_composer_cached(cx: &mut TestAppContext) {
    let (_dir, host, _, _) = two_panels(cx);
    let mut visual = VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(1400.0), px(800.0)));
    settle(&mut visual);
    host.update(cx, |shell, window, cx| {
        let focus = shell.composer.focus_handle(cx);
        window.focus(&focus, cx);
    })
    .unwrap();
    visual.simulate_keystrokes("right");
    settle(&mut visual);
    assert!(
        render_total("inactive-composer") > 0,
        "the parked panel drew its composer"
    );

    let before = render_total("inactive-composer");
    for key in ["h", "e", "l", "l", "o"] {
        visual.simulate_keystrokes(key);
        visual.run_until_parked();
    }
    assert_eq!(render_total("inactive-composer") - before, 0);
}

#[gpui::test]
fn a_parked_composer_still_grows_with_its_own_draft(cx: &mut TestAppContext) {
    let (_dir, host, _, _) = two_panels(cx);
    let mut visual = VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(1400.0), px(800.0)));
    settle(&mut visual);
    let parked = host
        .update(cx, |shell, _, _| {
            shell.workspace_panels.inactive_composers[&PanelTab::Chat("peer".into())].clone()
        })
        .unwrap();
    let height = |visual: &mut VisualTestContext| {
        visual.run_until_parked();
        visual.update(|window, cx| {
            window.draw(cx).clear();
            parked.read(cx).surface_bounds().unwrap().size.height
        })
    };
    let compact = height(&mut visual);
    let before = render_total("inactive-composer");
    host.update(cx, |shell, _, cx| {
        shell.composer.update(cx, |composer, _| {
            composer.set_parked_draft_for_test("peer", "one\ntwo\nthree\nfour")
        });
        // A draft reaches the shell as a notification, like any other change.
        cx.notify();
    })
    .unwrap();
    assert!(height(&mut visual) > compact, "the draft has four lines");
    assert!(render_total("inactive-composer") > before);
}
