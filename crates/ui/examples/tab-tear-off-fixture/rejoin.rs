//! Existing-window rejoin through production dispatch, using synthetic content.
use super::*;
use gpui::{AnyWindowHandle, MouseButton, Pixels, PlatformInput, Point};
use objc2_app_kit::NSView;
use objc2_foundation::NSPoint;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

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
    position: Point<Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    dispatch(
        source,
        PlatformInput::MouseMove(gpui::MouseMoveEvent {
            position,
            pressed_button: Some(MouseButton::Left),
            modifiers: Default::default(),
        }),
        cx,
    )
}

fn release(
    source: WindowHandle<shell::Shell>,
    position: Point<Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    dispatch(
        source,
        PlatformInput::MouseUp(gpui::MouseUpEvent {
            position,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )
}

async fn pickup(
    source: WindowHandle<shell::Shell>,
    page: &gpui::Entity<browser::BrowserSurface>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    source.update(cx, |_, window, _| window.activate_window())?;
    pause(cx, 70).await;
    page.read_with(cx, |page, _| page.fixture_focus());
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_focused()),
        "rejoin pickup has no native browser responder"
    );
    AnyWindowHandle::from(source).update(cx, |_, window, cx| window.draw(cx).clear())?;
    let bounds = source
        .read_with(cx, |shell, cx| shell.fixture_rejoin_active_tab_bounds(cx))?
        .ok_or_else(|| anyhow::anyhow!("rejoin browser tab has no measured bounds"))?;
    let start = point(bounds.left() + px(18.), bounds.top() + px(12.));
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
        "production rejoin pickup did not start a drag"
    );
    Ok(())
}

fn native_view(window: &gpui::Window) -> anyhow::Result<&NSView> {
    let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(window)?.as_raw() else {
        anyhow::bail!("rejoin fixture requires an AppKit window");
    };
    Ok(unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() })
}

fn to_screen(window: &gpui::Window, point: Point<Pixels>) -> anyhow::Result<NSPoint> {
    let view = native_view(window)?;
    let native = view
        .window()
        .ok_or_else(|| anyhow::anyhow!("no native window"))?;
    let y = if view.isFlipped() {
        f64::from(f32::from(point.y))
    } else {
        view.bounds().size.height - f64::from(f32::from(point.y))
    };
    Ok(native.convertPointToScreen(
        view.convertPoint_toView(NSPoint::new(f64::from(f32::from(point.x)), y), None),
    ))
}

fn from_screen(window: &gpui::Window, screen: NSPoint) -> anyhow::Result<Point<Pixels>> {
    let view = native_view(window)?;
    let native = view
        .window()
        .ok_or_else(|| anyhow::anyhow!("no native window"))?;
    let point = view.convertPoint_fromView(native.convertPointFromScreen(screen), None);
    Ok(gpui::point(
        px(point.x as f32),
        px(if view.isFlipped() {
            point.y
        } else {
            view.bounds().size.height - point.y
        } as f32),
    ))
}

/// Choose a visible destination edge outside the source. The native windows
/// may overlap on a laptop display; their content centers need not be usable.
fn target_pointer(
    source: WindowHandle<shell::Shell>,
    target: WindowHandle<shell::Shell>,
    tab_bar: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<Point<Pixels>> {
    let bounds = target
        .read_with(cx, |shell, cx| shell.fixture_rejoin_panel_bounds(cx))?
        .ok_or_else(|| anyhow::anyhow!("rejoin destination panel is not measured"))?;
    let y = if tab_bar {
        bounds.top() + px(16.)
    } else {
        bounds.top() + bounds.size.height * 0.55
    };
    let candidates = [
        point(bounds.left() + px(24.), y),
        point(bounds.right() - px(24.), y),
    ];
    let source_size = source.update(cx, |_, window, _| window.viewport_size())?;
    for target_point in candidates {
        let screen = target.update(cx, |_, window, _| to_screen(window, target_point))??;
        let local = source.update(cx, |_, window, _| from_screen(window, screen))??;
        if local.x < px(-28.)
            || local.y < px(-28.)
            || local.x > source_size.width + px(28.)
            || local.y > source_size.height + px(28.)
        {
            return Ok(local);
        }
    }
    anyhow::bail!("neither destination edge is outside the source window")
}

fn shell_windows(cx: &mut AsyncApp) -> Vec<WindowHandle<shell::Shell>> {
    cx.update(|cx| {
        cx.windows()
            .into_iter()
            .filter_map(|handle| handle.downcast::<shell::Shell>())
            .collect()
    })
}

async fn assert_live(
    owner: WindowHandle<shell::Shell>,
    page: &gpui::Entity<browser::BrowserSurface>,
    native: Option<usize>,
    phase: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    pause(cx, 350).await;
    let adopted = owner
        .read_with(cx, |shell, _| shell.fixture_browser_entity())?
        .ok_or_else(|| anyhow::anyhow!("{phase}: destination has no browser"))?;
    anyhow::ensure!(
        adopted.entity_id() == page.entity_id(),
        "{phase}: browser entity was recreated"
    );
    anyhow::ensure!(
        adopted.read_with(cx, |page, _| page.fixture_native_identity()) == native,
        "{phase}: native WebKit page was recreated"
    );
    anyhow::ensure!(
        adopted.read_with(cx, |page, _| page.fixture_focused()),
        "{phase}: native browser keyboard focus was lost"
    );
    let title = format!("PASS: {phase}");
    let script = format!(
        "document.title=(window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note'&&history.state?.transfer===true&&location.hash==='#checkpoint'&&window.scrollY>=400&&document.activeElement?.id==='notes')?{}:'FAIL: rejoin lost live page state';",
        serde_json::to_string(&title)?
    );
    adopted.update(cx, |page, _| page.fixture_eval(&script));
    wait_title(&adopted, &title, cx).await?;
    Ok(())
}

async fn rejoin(
    source: WindowHandle<shell::Shell>,
    target: WindowHandle<shell::Shell>,
    page: &gpui::Entity<browser::BrowserSurface>,
    tab_bar: bool,
    output: &Path,
    label: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<serde_json::Value> {
    pickup(source, page, cx).await?;
    let pointer = target_pointer(source, target, tab_bar, cx)?;
    move_pointer(source, pointer, cx)?;
    pause(cx, 190).await;
    let hover = source.read_with(cx, |shell, cx| shell.fixture_drag_visual_status(cx))?;
    capture(target, output, &format!("{label}-target-hover"), cx).await?;
    capture(source, output, &format!("{label}-source-hover"), cx).await?;
    release(source, pointer, cx)?;
    pause(cx, 350).await;
    anyhow::ensure!(
        shell_windows(cx).len() == 2,
        "{label}: existing-window drop created a third window"
    );
    anyhow::ensure!(
        cx.update(|cx| cx.windows().len()) == 2,
        "{label}: release left an auxiliary preview window open"
    );
    anyhow::ensure!(
        !cx.update(|cx| cx.has_active_drag()),
        "{label}: release left an active drag"
    );
    anyhow::ensure!(
        source
            .read_with(cx, |shell, _| shell.fixture_browser_entity())?
            .is_none(),
        "{label}: source retained browser ownership"
    );
    capture(target, output, &format!("{label}-target-after"), cx).await?;
    capture(source, output, &format!("{label}-source-after"), cx).await?;
    Ok(hover)
}

pub(super) async fn exercise(
    original: WindowHandle<shell::Shell>,
    page: gpui::Entity<browser::BrowserSurface>,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    checkpoint(output, "rejoin-preparing-browser-only")?;
    original.update(cx, |shell, _, cx| shell.fixture_rejoin_browser_only(cx))?;
    pause(cx, 150).await;
    let native = page.read_with(cx, |page, _| page.fixture_native_identity());
    anyhow::ensure!(native.is_some(), "rejoin browser has no native page");
    capture(original, output, "rejoin-original-before", cx).await?;
    pickup(original, &page, cx).await?;
    let outside = original.update(cx, |_, window, _| {
        point(window.viewport_size().width + px(48.), px(160.))
    })?;
    move_pointer(original, outside, cx)?;
    pause(cx, 190).await;
    release(original, outside, cx)?;
    let detached = shell_windows(cx)
        .into_iter()
        .find(|window| AnyWindowHandle::from(*window) != AnyWindowHandle::from(original))
        .ok_or_else(|| anyhow::anyhow!("initial tear-off did not create a second window"))?;
    anyhow::ensure!(
        shell_windows(cx).len() == 2,
        "initial tear-off created extra windows"
    );
    assert_live(detached, &page, native, "initial tear-off", cx).await?;
    let empty_original = original.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    anyhow::ensure!(
        empty_original["browsers"] == 0 && empty_original["tabs"] == 0,
        "original window was not empty after its last tab moved: {empty_original}"
    );
    capture(original, output, "rejoin-empty-original", cx).await?;
    capture(detached, output, "rejoin-detached-browser", cx).await?;
    checkpoint(output, "rejoin-empty-target")?;
    let empty_hover = rejoin(detached, original, &page, false, output, "rejoin-empty", cx).await?;
    assert_live(original, &page, native, "empty original rejoined", cx).await?;
    let empty_rejoined = original.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    anyhow::ensure!(
        empty_rejoined["browsers"] == 1 && empty_rejoined["tabs"] == 1,
        "empty original did not adopt exactly one browser: {empty_rejoined}"
    );
    detached.update(cx, |shell, window, cx| {
        shell.fixture_rejoin_populate("Keep the destination review draft", window, cx)
    })?;
    pause(cx, 150).await;
    let populated_before = detached.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    anyhow::ensure!(
        populated_before["draft"] == "Keep the destination review draft"
            && populated_before["attachmentBytes"]
                .as_u64()
                .is_some_and(|bytes| bytes > 0),
        "populated target draft was not seeded: {populated_before}"
    );
    capture(detached, output, "rejoin-populated-target-before", cx).await?;
    checkpoint(output, "rejoin-populated-target")?;
    let populated_hover = rejoin(
        original,
        detached,
        &page,
        true,
        output,
        "rejoin-populated",
        cx,
    )
    .await?;
    assert_live(detached, &page, native, "populated target rejoined", cx).await?;
    let populated_after = detached.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    anyhow::ensure!(
        populated_after["draft"] == populated_before["draft"]
            && populated_after["attachmentBytes"] == populated_before["attachmentBytes"]
            && populated_after["sessionId"] == populated_before["sessionId"]
            && populated_after["tabs"] == 2,
        "existing target tabs, draft, attachment or session changed: before={populated_before}, after={populated_after}"
    );
    page.update(cx, |page, _| page.fixture_eval(
        "window.addEventListener('popstate',()=>{document.title=(!history.state?.transfer&&location.hash===''&&window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note')?'PASS: rejoin history back':'FAIL: rejoin back history lost';},{once:true});document.title='Ready: rejoin history back';"
    ));
    wait_title(&page, "Ready: rejoin history back", cx).await?;
    page.update(cx, |page, _| page.fixture_history(false));
    wait_title(&page, "PASS: rejoin history back", cx).await?;
    page.update(cx, |page, _| page.fixture_eval(
        "window.addEventListener('popstate',()=>{document.title=(history.state?.transfer===true&&location.hash==='#checkpoint'&&window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note')?'PASS: rejoin history forward':'FAIL: rejoin forward history lost';},{once:true});document.title='Ready: rejoin history forward';"
    ));
    wait_title(&page, "Ready: rejoin history forward", cx).await?;
    page.update(cx, |page, _| page.fixture_history(true));
    wait_title(&page, "PASS: rejoin history forward", cx).await?;
    capture(detached, output, "rejoin-history-retained", cx).await?;
    std::fs::write(
        output.join("result.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "passed": true,
            "scope": "Production GPUI event dispatch, actual native windows and own-window captures. OS pointer delivery and typing are separate manual checks.",
            "checks": ["tear sole browser into second window", "rejoin empty original body", "rejoin populated existing tab bar", "no third Shell or orphan preview", "same browser entity and WebKit page", "JS heap, unsent form, back/forward history, scroll and native focus", "existing target draft, attachment and session preserved"],
            "emptyOriginal": empty_original,
            "emptyHover": empty_hover,
            "emptyRejoined": empty_rejoined,
            "populatedHover": populated_hover,
            "populatedBefore": populated_before,
            "populatedAfter": populated_after
        }))?,
    )?;
    checkpoint(output, "complete")?;
    Ok(())
}
