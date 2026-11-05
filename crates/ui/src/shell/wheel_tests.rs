use super::*;
use gpui::{ScrollDelta, ScrollHandle, ScrollWheelEvent};

/// A wheel over a transcript scrolls that transcript. It passes through the
/// panel area on the way, which has nothing to scroll here; that must not
/// count as the shell changing, because the shell's observers are the sidebar,
/// the composer and every open transcript.
#[gpui::test]
fn a_wheel_over_a_transcript_leaves_the_shell_and_sidebar_alone(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = super::typing_tests::shell_with_chats(cx, &dir);
    let panels = cx.debug_bounds("workspace-panels").unwrap();
    let notified = std::rc::Rc::new(std::cell::Cell::new(0usize));
    let _sub = cx.update(|_, cx| {
        let count = notified.clone();
        cx.observe(&shell, move |_, _| count.set(count.get() + 1))
    });
    let before = crate::shell::SIDEBAR_RENDERS.with(|n| n.get());
    for _ in 0..10 {
        cx.simulate_event(ScrollWheelEvent {
            position: panels.center(),
            delta: ScrollDelta::Pixels(gpui::point(px(0.0), px(120.0))),
            ..Default::default()
        });
        cx.run_until_parked();
    }
    assert_eq!(notified.get(), 0, "a wheel tick notified the shell");
    // The shell's once-a-second heartbeat may land in the window; ten ticks
    // must not mean ten rebuilds.
    let renders = crate::shell::SIDEBAR_RENDERS.with(|n| n.get()) - before;
    assert!(
        renders <= 3,
        "scrolling re-rendered the sidebar {renders} times"
    );
}

/// The other half of the rule: a box that does have room still scrolls, stops
/// exactly at each end, and asks for a redraw only when it moved.
#[gpui::test]
fn a_scroller_redraws_only_when_the_wheel_moved_it(cx: &mut gpui::TestAppContext) {
    struct Scroller {
        handle: ScrollHandle,
        renders: usize,
    }
    impl Render for Scroller {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            self.renders += 1;
            div().size_full().child(
                div()
                    .id("scroller")
                    .debug_selector(|| "scroller".into())
                    .w(px(100.0))
                    .h(px(100.0))
                    .overflow_y_scroll()
                    .track_scroll(&self.handle)
                    .child(div().h(px(300.0))),
            )
        }
    }
    let (view, cx) = cx.add_window_view(|_, _| Scroller {
        handle: ScrollHandle::new(),
        renders: 0,
    });
    cx.run_until_parked();
    let center = cx.debug_bounds("scroller").unwrap().center();
    let mut wheel = |delta: f32| -> (f32, usize) {
        let before = view.read_with(cx, |view, _| view.renders);
        cx.simulate_event(ScrollWheelEvent {
            position: center,
            delta: ScrollDelta::Pixels(gpui::point(px(0.0), px(delta))),
            ..Default::default()
        });
        cx.run_until_parked();
        view.read_with(cx, |view, _| {
            (f32::from(view.handle.offset().y), view.renders - before)
        })
    };

    assert_eq!(wheel(50.0), (0.0, 0), "already at the top");
    let (offset, renders) = wheel(-50.0);
    assert_eq!(offset, -50.0);
    assert!(renders > 0, "it moved, so it has to redraw");
    let (offset, renders) = wheel(-500.0);
    assert_eq!(offset, -200.0, "stops at the bottom, not past it");
    assert!(renders > 0);
    assert_eq!(wheel(-50.0), (-200.0, 0), "already at the bottom");
    let (offset, renders) = wheel(40.0);
    assert_eq!(offset, -160.0, "turning back is immediate");
    assert!(renders > 0);
}
