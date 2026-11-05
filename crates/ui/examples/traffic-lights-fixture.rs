//! Owned native window regression: AppKit button resets must retain the 42px
//! custom header alignment. No user data, services, or external app access.
//! cargo run -p harness-ui --example traffic-lights-fixture --features browser-fixture

#[cfg(target_os = "macos")]
mod fixture {
    use gpui::{
        AppContext, AsyncApp, Bounds, Context, IntoElement, Render, TitlebarOptions, Window,
        WindowBounds, WindowHandle, WindowOptions, div, point, prelude::*, px, rgb, size,
    };
    use objc2::rc::Retained;
    use objc2_app_kit::{NSButton, NSView, NSWindow, NSWindowButton, NSWindowStyleMask};
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use std::{cell::RefCell, rc::Rc, time::Duration};

    pub(super) struct Header;

    impl Render for Header {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().bg(rgb(0xfaf8f3)).child(
                div()
                    .h(px(42.))
                    .pl(px(92.))
                    .flex()
                    .items_center()
                    .text_size(px(12.))
                    .text_color(rgb(0x29251f))
                    .child("Sidebar   ·   Synthetic session"),
            )
        }
    }

    fn native_window(window: &Window) -> Retained<NSWindow> {
        let handle = HasWindowHandle::window_handle(window).unwrap().as_raw();
        let RawWindowHandle::AppKit(handle) = handle else {
            unreachable!("macOS fixture requires AppKit")
        };
        let view = unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() };
        view.window().expect("fixture view has a native window")
    }

    fn buttons(window: &NSWindow) -> [Retained<NSButton>; 3] {
        [
            NSWindowButton::CloseButton,
            NSWindowButton::MiniaturizeButton,
            NSWindowButton::ZoomButton,
        ]
        .map(|kind| window.standardWindowButton(kind).unwrap())
    }

    fn frames(window: &NSWindow) -> [NSRect; 3] {
        buttons(window).map(|button| button.convertRect_toView(button.bounds(), None))
    }

    fn assert_aligned(window: &NSWindow, label: &str) -> anyhow::Result<[NSRect; 3]> {
        let frames = frames(window);
        for frame in &frames {
            let center_from_top =
                window.frame().size.height - frame.origin.y - frame.size.height / 2.;
            anyhow::ensure!(
                (center_from_top - 21.).abs() < 0.1,
                "{label}: native center {center_from_top} differs from synthetic header center 21"
            );
        }
        let close_center = frames[0].origin.x + frames[0].size.width / 2.;
        let expected_close_center = 14. + frames[0].size.width / 2.;
        anyhow::ensure!(
            (close_center - expected_close_center).abs() < 0.1,
            "{label}: close x={close_center}"
        );
        Ok(frames)
    }

    fn assert_same_centers(before: [NSRect; 3], after: [NSRect; 3]) -> anyhow::Result<()> {
        for (before, after) in before.into_iter().zip(after) {
            anyhow::ensure!(
                (before.origin.x - after.origin.x).abs() < 0.01
                    && (before.origin.y - after.origin.y).abs() < 0.01,
                "repeated native updates drifted button placement: {before:?} → {after:?}"
            );
        }
        Ok(())
    }

    fn reset_to_native_placement(window: &NSWindow) {
        let buttons = buttons(window);
        let container = unsafe { buttons[0].superview().unwrap().superview().unwrap() };
        let mut frame = container.frame();
        frame.size.height = 28.;
        frame.origin.y = window.frame().size.height - frame.size.height;
        container.setFrame(frame);
        for (index, button) in buttons.into_iter().enumerate() {
            button.setFrameOrigin(NSPoint::new(9. + 20. * index as f64, 7.));
        }
    }

    async fn exercise(window: WindowHandle<Header>, cx: &mut AsyncApp) -> anyhow::Result<()> {
        cx.background_executor()
            .timer(Duration::from_millis(250))
            .await;
        let native = window.update(cx, |_, window, _| native_window(window))?;
        assert_aligned(&native, "initial")?;

        // The late reset has no GPUI resize/title/appearance notification.
        // Use AppKit's real update method to exercise the delegate repair.
        reset_to_native_placement(&native);
        anyhow::ensure!(assert_aligned(&native, "injected reset").is_err());
        native.update();
        let repaired = assert_aligned(&native, "after AppKit update")?;
        for _ in 0..16 {
            native.update();
            assert_same_centers(repaired, assert_aligned(&native, "repeat")?)?;
        }

        // A partial native reset must not change spacing of the other buttons.
        let close = &buttons(&native)[0];
        close.setFrameOrigin(NSPoint::new(9., 7.));
        native.update();
        assert_same_centers(repaired, assert_aligned(&native, "partial reset")?)?;

        native.setTitle(&NSString::from_str("Synthetic native title update"));
        native.update();
        assert_aligned(&native, "title reset")?;
        native.setContentSize(NSSize::new(980., 700.));
        native.update();
        let resized = assert_aligned(&native, "resize")?;
        for _ in 0..8 {
            native.update();
            assert_same_centers(resized, assert_aligned(&native, "resized repeat")?)?;
        }
        reset_to_native_placement(&native);
        native.update();
        assert_aligned(&native, "reset after resize")?;
        println!(
            "PASS: native button reset, partial reset, repeated update, title change and resize retain center 21"
        );
        if std::env::var("HARNESS_TRAFFIC_LIGHTS_FULLSCREEN").as_deref() == Ok("1") {
            for fullscreen in [true, false] {
                native.toggleFullScreen(None);
                cx.background_executor()
                    .timer(Duration::from_millis(1200))
                    .await;
                let deadline = std::time::Instant::now() + Duration::from_secs(5);
                while native.styleMask().contains(NSWindowStyleMask::FullScreen) != fullscreen {
                    anyhow::ensure!(
                        std::time::Instant::now() < deadline,
                        "native fullscreen transition did not reach requested state {fullscreen}"
                    );
                    cx.background_executor()
                        .timer(Duration::from_millis(100))
                        .await;
                }
                eprintln!("Native fullscreen state reached: {fullscreen}");
            }
            // Allow the did-exit callback and final titlebar layout to settle.
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            native.update();
            assert_aligned(&native, "fullscreen exit")?;
            println!("PASS: real native fullscreen entry and exit restore header alignment");
        }
        if let Some(directory) = std::env::var_os("HARNESS_TRAFFIC_LIGHTS_CAPTURE") {
            let directory = std::path::PathBuf::from(directory);
            std::fs::create_dir_all(&directory)?;
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            let status = std::process::Command::new("/usr/sbin/screencapture")
                .args(["-x", "-o", "-l", &native.windowNumber().to_string()])
                .arg(directory.join("traffic-lights-aligned.png"))
                .status()?;
            anyhow::ensure!(status.success(), "native fixture capture failed");
        }
        if let Some(hold_ms) = std::env::var("HARNESS_TRAFFIC_LIGHTS_HOLD_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
        {
            cx.background_executor()
                .timer(Duration::from_millis(hold_ms.min(60_000)))
                .await;
        }
        Ok(())
    }

    pub(super) fn run() -> anyhow::Result<()> {
        let result = Rc::new(RefCell::new(None));
        let output = result.clone();
        gpui_platform::application().run(move |cx| {
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            point(px(80.), px(80.)),
                            size(px(800.), px(600.)),
                        ))),
                        titlebar: Some(TitlebarOptions {
                            title: Some("Harness native header fixture".into()),
                            appears_transparent: true,
                            traffic_light_position: Some(point(px(14.), px(14.))),
                        }),
                        app_owns_titlebar_drag: true,
                        ..Default::default()
                    },
                    |window, cx| {
                        harness_ui::fixture_align_main_window_traffic_lights(window);
                        cx.new(|_| Header)
                    },
                )
                .unwrap();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let outcome = exercise(window, cx).await;
                if let Err(error) = &outcome {
                    eprintln!("FAIL: {error:#}");
                    // NSApplication.terminate exits without returning from run.
                    std::process::exit(1);
                }
                output.replace(Some(outcome));
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
        let outcome = result.borrow_mut().take().expect("fixture completed");
        outcome
    }
}

fn main() -> anyhow::Result<()> {
    #[cfg(target_os = "macos")]
    return fixture::run();
    #[cfg(not(target_os = "macos"))]
    anyhow::bail!("traffic-lights-fixture requires macOS")
}
