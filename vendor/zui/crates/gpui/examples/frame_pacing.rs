//! Frame pacing fixture: scrolls a long synthetic list, idles, streams text,
//! runs a spinner-like animation in a key window and then in a window that
//! isn't key, idles again, and quits.
//!
//! Run with `GPUI_FRAME_STATS=1` on macOS to get one line of frame counters
//! per second on stderr. Phase changes print as
//! `frame-pacing phase=<name> at=<unix seconds>` so each stats line can be
//! matched to the phase it measured.
//!
//! The window is a small non-activating pop-up in the screen's corner, so it
//! stays visible (an occluded window gets no frames) without activating the
//! app. Scrolling is driven by real `ScrollWheel` events, one per frame, like
//! momentum scrolling.

use gpui::{
    App, Bounds, Context, PlatformInput, ScrollDelta, ScrollWheelEvent, SharedString, TouchPhase,
    Window, WindowBounds, WindowKind, WindowOptions, div, point, prelude::*, px, rgb, size,
    uniform_list,
};
use gpui_platform::application;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const ROWS: usize = 20_000;
const SETTLE: Duration = Duration::from_secs(1);
const SCROLL: Duration = Duration::from_secs(4);
const IDLE: Duration = Duration::from_secs(3);
const STREAM: Duration = Duration::from_secs(3);
/// Streaming text arrives in chunks about this far apart.
const STREAM_CHUNK: Duration = Duration::from_millis(33);
const ANIMATE: Duration = Duration::from_secs(3);

struct FramePacing {
    rendered: u64,
    streamed: String,
    /// Spin a progress bar with `request_animation_frame`, like a spinner.
    animating: bool,
    /// Scroll the list by one wheel event per frame.
    scrolling: bool,
}

impl Render for FramePacing {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.rendered += 1;
        if self.animating {
            window.request_animation_frame();
        }
        if self.scrolling {
            window.on_next_frame(|window, cx| {
                window.dispatch_event(
                    PlatformInput::ScrollWheel(ScrollWheelEvent {
                        position: point(px(260.), px(240.)),
                        delta: ScrollDelta::Pixels(point(px(0.), px(-6.))),
                        touch_phase: TouchPhase::Moved,
                        ..Default::default()
                    }),
                    cx,
                );
            });
        }
        let bar = (self.rendered % 100) as f32 * 4.;
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(rgb(0x1e1e22))
            .text_color(rgb(0xdedede))
            .text_sm()
            .child(
                div()
                    .h(px(48.))
                    .px_3()
                    .bg(rgb(0x2a2a30))
                    .child(SharedString::from(self.streamed.clone()))
                    .child(div().h(px(3.)).w(px(bar)).bg(rgb(0x5080e0))),
            )
            .child(
                uniform_list(
                    "rows",
                    ROWS,
                    cx.processor(|_, range: std::ops::Range<usize>, _, _| {
                        range
                            .map(|ix| {
                                div()
                                    .id(ix)
                                    .h(px(28.))
                                    .px_3()
                                    .flex()
                                    .gap_2()
                                    .items_center()
                                    .child(div().size(px(10.)).rounded_sm().bg(rgb(
                                        0x4060a0 + (ix as u32 % 7) * 0x101010,
                                    )))
                                    .child(format!("Message {ix}"))
                                    .child(
                                        div()
                                            .text_color(rgb(0x9a9aa0))
                                            .child("a synthetic transcript line, long enough to shape a few words"),
                                    )
                            })
                            .collect()
                    }),
                )
                .flex_1(),
            )
    }
}

struct Helper;

impl Render for Helper {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().bg(rgb(0x2a2a30))
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn phase(name: &str) {
    eprintln!("frame-pacing phase={name} at={:.3}", now());
}

fn report_active(window: &gpui::WindowHandle<FramePacing>, cx: &mut gpui::AsyncApp) {
    let active = window
        .update(cx, |_, window, _| window.is_window_active())
        .unwrap_or_default();
    eprintln!("frame-pacing window_active={active} at={:.3}", now());
}

fn run_example() {
    application().run(|cx: &mut App| {
        // A small pop-up in the screen's corner: visible (an occluded window
        // gets no frames) without taking focus from the app in front.
        let window_size = size(px(520.), px(400.));
        let bounds = match cx.primary_display() {
            Some(display) => {
                let screen = display.bounds();
                Bounds::new(
                    point(
                        screen.origin.x + screen.size.width - window_size.width - px(24.),
                        screen.origin.y + screen.size.height - window_size.height - px(72.),
                    ),
                    window_size,
                )
            }
            None => Bounds::centered(None, window_size, cx),
        };
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    focus: false,
                    kind: WindowKind::PopUp,
                    ..Default::default()
                },
                |_, cx| {
                    cx.new(|_| FramePacing {
                        rendered: 0,
                        streamed: String::new(),
                        animating: false,
                        scrolling: false,
                    })
                },
            )
            .unwrap();

        cx.spawn(async move |cx| {
            let executor = cx.background_executor().clone();
            // Key, so the scroll and the first animation run as in a focused
            // window. (A non-activating panel takes key without activating
            // the app.)
            window
                .update(cx, |_, window, _| window.activate_window())
                .ok();
            phase("settle");
            executor.timer(SETTLE).await;

            report_active(&window, cx);
            // One scroll event at the start of every frame, like momentum
            // scrolling, delivered from the frame itself so the measurement
            // doesn't depend on how timers interleave with frame callbacks.
            phase("scroll");
            window
                .update(cx, |view, _, cx| {
                    view.scrolling = true;
                    cx.notify();
                })
                .ok();
            executor.timer(SCROLL).await;
            window.update(cx, |view, _, _| view.scrolling = false).ok();

            report_active(&window, cx);
            phase("idle");
            executor.timer(IDLE).await;

            phase("stream");
            let start = std::time::Instant::now();
            let mut chunk = 0;
            while start.elapsed() < STREAM {
                chunk += 1;
                window
                    .update(cx, |view, _, cx| {
                        view.streamed = format!("streamed chunk {chunk}: lorem ipsum dolor");
                        cx.notify();
                    })
                    .ok();
                executor.timer(STREAM_CHUNK).await;
            }

            report_active(&window, cx);
            phase("animate");
            window
                .update(cx, |view, _, cx| {
                    view.animating = true;
                    cx.notify();
                })
                .ok();
            executor.timer(ANIMATE).await;

            // The same animation in a window that isn't key: a second small
            // pop-up takes key status for this phase.
            let helper = cx
                .update(|cx| {
                    let size = size(px(160.), px(60.));
                    let origin = bounds.origin + point(px(0.), bounds.size.height + px(8.));
                    cx.open_window(
                        WindowOptions {
                            window_bounds: Some(WindowBounds::Windowed(Bounds::new(origin, size))),
                            kind: WindowKind::PopUp,
                            ..Default::default()
                        },
                        |_, cx| cx.new(|_| Helper),
                    )
                })
                .ok();
            executor.timer(Duration::from_millis(300)).await;
            report_active(&window, cx);
            phase("animate_inactive");
            executor.timer(ANIMATE).await;
            report_active(&window, cx);
            if let Some(helper) = helper {
                helper
                    .update(cx, |_, window, _| window.remove_window())
                    .ok();
            }
            window.update(cx, |view, _, _| view.animating = false).ok();

            report_active(&window, cx);
            phase("idle2");
            executor.timer(IDLE).await;
            phase("done");
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
}

fn main() {
    run_example();
}
