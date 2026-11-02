//! Production GPUI dispatch with synthetic data and real native preview windows.
use super::*;
use gpui::{AnyWindowHandle, MouseButton, Pixels, PlatformInput, Point};

fn dispatch(
    source: WindowHandle<shell::Shell>,
    event: PlatformInput,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    AnyWindowHandle::from(source).update(cx, |_, window, cx| {
        window.dispatch_event(event, cx);
        window.draw(cx).clear();
    })?;
    Ok(())
}

fn move_pointer(
    source: WindowHandle<shell::Shell>,
    pointer: Point<Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    dispatch(
        source,
        PlatformInput::MouseMove(gpui::MouseMoveEvent {
            position: pointer,
            pressed_button: Some(MouseButton::Left),
            modifiers: Default::default(),
        }),
        cx,
    )
}

fn pickup(
    source: WindowHandle<shell::Shell>,
    panel: u64,
    right_edge: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<Point<Pixels>> {
    AnyWindowHandle::from(source).update(cx, |_, window, cx| window.draw(cx).clear())?;
    let bounds = source
        .read_with(cx, |shell, cx| {
            shell.fixture_active_drag_tab_bounds(panel, cx)
        })?
        .ok_or_else(|| anyhow::anyhow!("active tab has no measured bounds"))?;
    let start = point(
        if right_edge {
            bounds.right() - px(12.)
        } else {
            bounds.left() + px(12.)
        },
        bounds.top() + px(12.),
    );
    dispatch(
        source,
        PlatformInput::MouseDown(gpui::MouseDownEvent {
            position: start,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )?;
    move_pointer(source, start + point(px(12.), px(3.)), cx)?;
    anyhow::ensure!(
        cx.update(|cx| cx.has_active_drag()),
        "tab pickup did not start production drag"
    );
    Ok(start)
}

fn visual_status(
    source: WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
) -> anyhow::Result<serde_json::Value> {
    Ok(source.read_with(cx, |shell, cx| shell.fixture_drag_visual_status(cx))?)
}

async fn expanded_preview(
    source: WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
) -> anyhow::Result<AnyWindowHandle> {
    let deadline = std::time::Instant::now() + Duration::from_secs(4);
    loop {
        let status = visual_status(source, cx)?;
        if status["preview"]["hasImage"] == true
            && status["preview"]["morph"]
                .as_f64()
                .is_some_and(|t| t >= 0.999)
        {
            return source
                .read_with(cx, |shell, _| shell.fixture_drag_preview_window())?
                .ok_or_else(|| anyhow::anyhow!("expanded preview has no native window"));
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "native preview did not expand with actual contents: {status}"
        );
        pause(cx, 30).await;
    }
}

async fn capture_preview(
    handle: AnyWindowHandle,
    output: &Path,
    name: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        #[cfg(target_os = "macos")]
        {
            use raw_window_handle::{HasWindowHandle, RawWindowHandle};
            let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(window)?.as_raw()
            else {
                anyhow::bail!("expected a native preview window");
            };
            let view = unsafe { &*handle.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
            let native = view
                .window()
                .ok_or_else(|| anyhow::anyhow!("native preview disappeared"))?;
            anyhow::ensure!(
                native.ignoresMouseEvents(),
                "preview receives pointer events"
            );
            anyhow::ensure!(
                !native.isKeyWindow() && !native.isMainWindow(),
                "preview stole window focus"
            );
        }
        Ok(())
    })??;
    capture_window(handle, output, name, cx).await
}

fn shell_windows(cx: &mut AsyncApp) -> Vec<WindowHandle<shell::Shell>> {
    cx.update(|cx| {
        cx.windows()
            .into_iter()
            .filter_map(|handle| handle.downcast::<shell::Shell>())
            .collect()
    })
}

fn window_exists(handle: AnyWindowHandle, cx: &mut AsyncApp) -> bool {
    cx.update(|cx| cx.windows().contains(&handle))
}

fn record_focus(
    source: WindowHandle<shell::Shell>,
    page: &gpui::Entity<browser::BrowserSurface>,
    output: &Path,
    phase: &str,
    trace: &mut Vec<serde_json::Value>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    trace.push(serde_json::json!({
        "phase": phase,
        "page": page.read_with(cx, |page, _| page.fixture_focus_state()),
        "drag": visual_status(source, cx)?
    }));
    std::fs::write(
        output.join("drag-focus-trace.json"),
        serde_json::to_string_pretty(trace)?,
    )?;
    Ok(())
}

fn assert_pointer_anchor(
    source: WindowHandle<shell::Shell>,
    preview: AnyWindowHandle,
    status: &serde_json::Value,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let pointer = status["pointer"].as_array().unwrap();
    let expected =
        AnyWindowHandle::from(source).update(cx, |_, source, _| -> anyhow::Result<_> {
            let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(source)?.as_raw()
            else {
                anyhow::bail!("source is not AppKit")
            };
            let view = unsafe { &*handle.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
            let y = pointer[1].as_f64().unwrap();
            let local = objc2_foundation::NSPoint::new(
                pointer[0].as_f64().unwrap(),
                if view.isFlipped() {
                    y
                } else {
                    view.bounds().size.height - y
                },
            );
            Ok(view
                .window()
                .unwrap()
                .convertPointToScreen(view.convertPoint_toView(local, None)))
        })??;
    let actual = preview.update(cx, |_, preview, _| -> anyhow::Result<_> {
        let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(preview)?.as_raw()
        else {
            anyhow::bail!("preview is not AppKit")
        };
        let view = unsafe { &*handle.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
        let frame = view.window().unwrap().frame();
        let card = &status["preview"]["card"];
        let anchor = &status["preview"]["anchor"];
        Ok((
            frame.origin.x + card[0].as_f64().unwrap() + anchor[0].as_f64().unwrap(),
            frame.origin.y + frame.size.height
                - card[1].as_f64().unwrap()
                - anchor[1].as_f64().unwrap(),
        ))
    })??;
    anyhow::ensure!(
        (expected.x - actual.0).abs() < 1.5 && (expected.y - actual.1).abs() < 1.5,
        "native pointer anchor drifted: expected {expected:?}, actual {actual:?}"
    );
    Ok(())
}

pub(super) async fn exercise(
    source: WindowHandle<shell::Shell>,
    panel: u64,
    page: gpui::Entity<browser::BrowserSurface>,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        cfg!(target_os = "macos"),
        "desktop preview fixture currently requires macOS"
    );
    let before = source.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    let native_identity = page.read_with(cx, |page, _| page.fixture_native_identity());
    let mut focus_trace = Vec::new();
    record_focus(source, &page, output, "before-pickup", &mut focus_trace, cx)?;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_focused()),
        "native page was not focused before tab pickup"
    );
    let outside = source.update(cx, |_, window, _| {
        point(window.viewport_size().width + px(48.), px(160.))
    })?;
    pickup(source, panel, true, cx)?;
    record_focus(source, &page, output, "after-pickup", &mut focus_trace, cx)?;
    capture(source, output, "drag-pickup-source", cx).await?;
    move_pointer(source, outside, cx)?;
    let first_preview = expanded_preview(source, cx).await?;
    let expanded = visual_status(source, cx)?;
    let grab_x = expanded["grab"][0].as_f64().unwrap();
    let anchor_x = expanded["preview"]["anchor"][0].as_f64().unwrap();
    anyhow::ensure!(
        (grab_x - anchor_x).abs() < 1.,
        "right-edge pickup changed pointer anchor: {expanded}"
    );
    assert_pointer_anchor(source, first_preview, &expanded, cx)?;
    capture_preview(first_preview, output, "drag-expanded-preview", cx).await?;
    capture(source, output, "drag-expanded-source", cx).await?;
    move_pointer(source, point(px(180.), px(150.)), cx)?;
    pause(cx, 200).await;
    let reentered = visual_status(source, cx)?;
    record_focus(source, &page, output, "reentered", &mut focus_trace, cx)?;
    anyhow::ensure!(
        reentered["preview"]["window"] == expanded["preview"]["window"],
        "reentry recreated the preview"
    );
    anyhow::ensure!(
        reentered["preview"]["expanded"] == false
            && reentered["preview"]["morph"]
                .as_f64()
                .is_some_and(|t| t < 0.001),
        "reentry failed to collapse: {reentered}"
    );
    capture_preview(first_preview, output, "drag-reentry-preview", cx).await?;
    assert_pointer_anchor(source, first_preview, &reentered, cx)?;
    capture(source, output, "drag-reentry-source", cx).await?;
    move_pointer(source, outside, cx)?;
    pause(cx, 35).await;
    move_pointer(source, point(px(180.), px(150.)), cx)?;
    pause(cx, 25).await;
    move_pointer(source, outside, cx)?;
    let reversed = visual_status(source, cx)?;
    anyhow::ensure!(
        reversed["preview"]["window"] == expanded["preview"]["window"],
        "reversal recreated the preview"
    );
    pause(cx, 170).await;
    record_focus(source, &page, output, "before-escape", &mut focus_trace, cx)?;
    let source_active_at_cancel = source.update(cx, |_, window, _| window.is_window_active())?;
    dispatch(
        source,
        PlatformInput::KeyDown(gpui::KeyDownEvent {
            keystroke: gpui::Keystroke::parse("escape")?,
            is_held: false,
            prefer_character_input: false,
        }),
        cx,
    )?;
    dispatch(
        source,
        PlatformInput::MouseUp(gpui::MouseUpEvent {
            position: outside,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )?;
    pause(cx, 100).await;
    record_focus(source, &page, output, "after-escape", &mut focus_trace, cx)?;
    anyhow::ensure!(
        !window_exists(first_preview, cx),
        "Escape left the native preview open"
    );
    let focused_after_cancel = page.read_with(cx, |page, _| page.fixture_focused());
    anyhow::ensure!(
        focused_after_cancel == source_active_at_cancel,
        "Escape focus disagreed with source activation (active={source_active_at_cancel}, focused={focused_after_cancel}): page={} visual={}",
        page.read_with(cx, |page, _| page.fixture_focus_state()),
        visual_status(source, cx)?
    );
    anyhow::ensure!(
        source.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))? == before,
        "Escape changed tab resources or drafts"
    );
    anyhow::ensure!(
        shell_windows(cx).len() == 1 && !cx.update(|cx| cx.has_active_drag()),
        "Escape committed an unexpected window"
    );
    capture(source, output, "drag-cancelled-source", cx).await?;

    // The release case is independent of cancellation. An inactive source must
    // not regain focus on Escape; seed its native responder explicitly here.
    page.read_with(cx, |page, _| page.fixture_focus());
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_focused()),
        "native page was not focused before the independent release case"
    );
    pickup(source, panel, false, cx)?;
    move_pointer(source, outside, cx)?;
    let release_preview = expanded_preview(source, cx).await?;
    capture_preview(release_preview, output, "drag-release-preview", cx).await?;
    dispatch(
        source,
        PlatformInput::MouseUp(gpui::MouseUpEvent {
            position: outside,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )?;
    let destination = shell_windows(cx)
        .into_iter()
        .find(|handle| AnyWindowHandle::from(*handle) != AnyWindowHandle::from(source))
        .ok_or_else(|| anyhow::anyhow!("outside release did not create a real destination"))?;
    pause(cx, 35).await;
    if window_exists(release_preview, cx) {
        let capture = capture_preview(release_preview, output, "drag-release-handoff", cx).await;
        match capture {
            Ok(()) => {
                let image = image::open(output.join("drag-release-handoff.png"))?.to_rgba8();
                let pixel = image.get_pixel(8, image.height() / 2);
                anyhow::ensure!(
                    pixel[3] < 128,
                    "release canvas became opaque outside the card: pixel {pixel:?}"
                );
            }
            Err(error) if window_exists(release_preview, cx) => return Err(error),
            Err(_) => {} // The short handoff may finish during native capture.
        }
    }
    pause(cx, 350).await;
    anyhow::ensure!(
        !window_exists(release_preview, cx),
        "release handoff left a preview behind"
    );
    let adopted = destination
        .read_with(cx, |shell, _| shell.fixture_browser_entity())?
        .ok_or_else(|| anyhow::anyhow!("drag destination has no browser"))?;
    anyhow::ensure!(
        page.entity_id() == adopted.entity_id(),
        "drag recreated the browser entity"
    );
    anyhow::ensure!(
        adopted.read_with(cx, |page, _| page.fixture_native_identity()) == native_identity,
        "drag recreated WebKit"
    );
    anyhow::ensure!(
        adopted.read_with(cx, |page, _| page.fixture_focused()),
        "drag transfer lost native keyboard focus"
    );
    capture(destination, output, "drag-release-window", cx).await?;
    capture(source, output, "drag-release-source", cx).await?;

    // Exercise destination-close cleanup before the scheduled preview handoff.
    // The existing browser window occupies the right-hand desktop drop area.
    let chat_outside = point(px(-48.), px(160.));
    source.update(cx, |shell, window, cx| {
        window.activate_window();
        shell.fixture_transfer_select_chat("fixture-b", window, cx)
    })?;
    pause(cx, 60).await;
    pickup(source, panel, false, cx)?;
    move_pointer(source, chat_outside, cx)?;
    let closing_preview = expanded_preview(source, cx).await?;
    dispatch(
        source,
        PlatformInput::MouseUp(gpui::MouseUpEvent {
            position: chat_outside,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )?;
    let closing = shell_windows(cx)
        .into_iter()
        .find(|handle| {
            let handle = AnyWindowHandle::from(*handle);
            handle != AnyWindowHandle::from(source) && handle != AnyWindowHandle::from(destination)
        })
        .ok_or_else(|| anyhow::anyhow!("chat drag did not create its destination"))?;
    closing.update(cx, |shell, window, cx| -> anyhow::Result<()> {
        anyhow::ensure!(
            shell.prepare_window_close(cx),
            "synthetic destination close blocked"
        );
        window.remove_window();
        Ok(())
    })??;
    pause(cx, 100).await;
    anyhow::ensure!(
        !window_exists(closing_preview, cx),
        "destination close before scheduled handoff orphaned its preview"
    );
    source.update(cx, |shell, window, cx| -> anyhow::Result<()> {
        anyhow::ensure!(
            shell.prepare_window_close(cx),
            "synthetic source close blocked"
        );
        window.remove_window();
        Ok(())
    })??;
    adopted.update(cx, |page, _| page.fixture_eval("document.title=(window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note'&&document.activeElement?.id==='notes')?'PASS: drag source closed':'FAIL: drag lost live state';"));
    wait_title(&adopted, "PASS: drag source closed", cx).await?;
    capture(destination, output, "drag-browser-after-source-close", cx).await?;
    std::fs::write(
        output.join("drag-result.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "passed": true,
            "scope": "Production GPUI event dispatch and actual native popup windows; OS delivery beyond the source still needs manual pointer verification.",
            "cancelFocus": {
                "sourceActiveAtCancel": source_active_at_cancel,
                "nativeFocusedAfterCancel": focused_after_cancel,
                "checked": if source_active_at_cancel { "active source restores native page focus" } else { "inactive source does not steal native page focus" }
            },
            "checks": ["right-edge pointer anchor", "actual native content snapshot", "preview ignores input and focus", "same preview through reentry and reversal", "Escape rollback", "outside release through production handlers", "release popup cleanup", "destination close before scheduled preview handoff", "same browser and WebKit entity", "form and JS after source close"],
            "expanded": expanded, "reentered": reentered, "reversed": reversed,
            "destination": destination.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?
        }))?,
    )?;
    Ok(())
}
