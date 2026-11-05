//! Internal stacked-panel tab placement through real production event dispatch.
use super::shared_header::{bounds, capture_native, dispatch};
use super::*;
use gpui::{AnyWindowHandle, MouseButton, Pixels, PlatformInput, Point, WindowHandle};

fn move_drag(
    handle: WindowHandle<shell::Shell>,
    position: Point<Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    dispatch(
        handle,
        PlatformInput::MouseMove(gpui::MouseMoveEvent {
            position,
            pressed_button: Some(MouseButton::Left),
            ..Default::default()
        }),
        cx,
    )
}

fn pickup(handle: WindowHandle<shell::Shell>, cx: &mut AsyncApp) -> anyhow::Result<()> {
    let tab = bounds(handle, "panel-tab-0-0", cx)?;
    let content = bounds(handle, "panel-tab-content-0-0", cx)?;
    let position = point(tab.center().x, content.center().y);
    dispatch(
        handle,
        PlatformInput::MouseDown(gpui::MouseDownEvent {
            position,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )?;
    move_drag(handle, position + point(px(12.0), px(4.0)), cx)?;
    anyhow::ensure!(
        cx.update(|cx| cx.has_active_drag()),
        "tab pickup did not start a production drag"
    );
    Ok(())
}

fn release(
    handle: WindowHandle<shell::Shell>,
    position: Point<Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    dispatch(
        handle,
        PlatformInput::MouseUp(gpui::MouseUpEvent {
            position,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )
}

fn state(
    handle: WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
) -> anyhow::Result<serde_json::Value> {
    Ok(handle.read_with(cx, |shell, cx| shell.fixture_tab_insertion_state(cx))?)
}

fn marker(
    handle: WindowHandle<shell::Shell>,
    before: usize,
    x: Pixels,
    center_y: Pixels,
    cx: &mut AsyncApp,
) -> anyhow::Result<serde_json::Value> {
    let value = state(handle, cx)?;
    anyhow::ensure!(
        value["hover"]["panel"] == 1
            && value["hover"]["before"] == before
            && value["hover"]["header"] == true,
        "wrong internal insertion target: {value}"
    );
    let cue = bounds(handle, "window-rejoin-tab-cue-1", cx)?;
    // The first marker is clamped a few pixels inside the rounded panel edge.
    anyhow::ensure!(
        (cue.left() - x).abs() <= px(4.0),
        "insertion marker is not at slot {before}: {cue:?}, x={x:?}"
    );
    anyhow::ensure!(
        (cue.center().y - center_y).abs() < px(1.0),
        "insertion marker is not aligned with its destination title row: {cue:?}"
    );
    Ok(
        serde_json::json!({"target":value["hover"],"cue":[f32::from(cue.left()),f32::from(cue.top()),f32::from(cue.size.width),f32::from(cue.size.height)]}),
    )
}

fn assert_clean(handle: WindowHandle<shell::Shell>, cx: &mut AsyncApp) -> anyhow::Result<()> {
    let value = state(handle, cx)?;
    anyhow::ensure!(
        value["drag"] == false && value["windowDrag"] == false && value["hover"].is_null(),
        "tab placement left drag feedback: {value}"
    );
    let cue = AnyWindowHandle::from(handle).update(cx, |_, window, cx| {
        window.draw(cx).clear();
        window.debug_bounds("window-rejoin-tab-cue-1")
    })?;
    anyhow::ensure!(
        cue.is_none(),
        "tab placement left its insertion marker behind"
    );
    anyhow::ensure!(
        cx.update(|cx| cx.windows().len()) == 1,
        "internal placement created another window"
    );
    Ok(())
}

async fn reset(
    handle: WindowHandle<shell::Shell>,
    empty: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    handle.update(cx, |shell, window, cx| {
        shell.fixture_tab_insertion_case(empty, window, cx);
    })?;
    pause(cx, 260).await;
    Ok(())
}

async fn run(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<Vec<serde_json::Value>> {
    reset(handle, false, cx).await?;
    let original = state(handle, cx)?;
    let first = bounds(handle, "panel-tab-1-0", cx)?;
    let middle = bounds(handle, "panel-tab-1-1", cx)?;
    let last = bounds(handle, "panel-tab-1-2", cx)?;
    let row = bounds(handle, "panel-tab-content-1-0", cx)?;
    capture_native(handle, output, &format!("tab-insertion-{tone}-before"), cx).await?;
    pickup(handle, cx)?;
    let positions = [
        (
            "first",
            0,
            point(first.left() + first.size.width * 0.25, row.center().y),
            first.left(),
        ),
        (
            "middle",
            1,
            point(middle.left() + middle.size.width * 0.25, row.center().y),
            middle.left(),
        ),
        (
            "append",
            3,
            point(last.left() + last.size.width * 0.75, row.center().y),
            last.right(),
        ),
    ];
    let mut samples = vec![];
    for (name, before, position, x) in positions {
        move_drag(handle, position, cx)?;
        pause(cx, 100).await;
        let geometry = marker(handle, before, x, row.center().y, cx)?;
        capture_native(handle, output, &format!("tab-insertion-{tone}-{name}"), cx).await?;
        samples.push(serde_json::json!({"name":name,"geometry":geometry}));
    }
    // Keep the center-grab quarter samples above: normal floating-tab
    // occlusion is intentional. This blank-space point also exposes the cue.
    let mut append = point(last.left() + last.size.width * 0.75, row.center().y);
    let strip = bounds(handle, "workspace-panel-tab-strip-1", cx)?;
    let exposed_append = point(last.right() + px(140.0), row.center().y);
    if exposed_append.x < strip.right() - px(12.0) {
        move_drag(handle, exposed_append, cx)?;
        pause(cx, 100).await;
        let geometry = marker(handle, 3, last.right(), row.center().y, cx)?;
        capture_native(
            handle,
            output,
            &format!("tab-insertion-{tone}-append-exposed"),
            cx,
        )
        .await?;
        samples.push(serde_json::json!({"name":"append-exposed","geometry":geometry}));
        append = exposed_append;
    }
    release(handle, append, cx)?;
    pause(cx, 220).await;
    assert_clean(handle, cx)?;
    let after = state(handle, cx)?;
    anyhow::ensure!(
        after["upper"] == serde_json::json!(["launch-2"])
            && after["lower"] == serde_json::json!(["new-100", "new-101", "new-102", "launch-0"]),
        "append did not use the highlighted slot: {after}"
    );
    anyhow::ensure!(
        after["draft"] == original["draft"],
        "internal transfer lost the unsent draft"
    );
    capture_native(
        handle,
        output,
        &format!("tab-insertion-{tone}-after-drop"),
        cx,
    )
    .await?;

    reset(handle, false, cx).await?;
    let before_cancel = state(handle, cx)?;
    pickup(handle, cx)?;
    let cancel_at = point(middle.left() + middle.size.width * 0.25, row.center().y);
    move_drag(handle, cancel_at, cx)?;
    pause(cx, 100).await;
    marker(handle, 1, middle.left(), row.center().y, cx)?;
    dispatch(
        handle,
        PlatformInput::KeyDown(gpui::KeyDownEvent {
            keystroke: gpui::Keystroke::parse("escape")?,
            is_held: false,
            prefer_character_input: false,
        }),
        cx,
    )?;
    release(handle, cancel_at, cx)?;
    pause(cx, 100).await;
    assert_clean(handle, cx)?;
    anyhow::ensure!(
        state(handle, cx)? == before_cancel,
        "Escape changed the stacked panels or draft"
    );
    capture_native(
        handle,
        output,
        &format!("tab-insertion-{tone}-cancel-cleanup"),
        cx,
    )
    .await?;

    reset(handle, true, cx).await?;
    let label = bounds(handle, "panel-empty-label-1", cx)?;
    let header = bounds(handle, "workspace-panel-header-1", cx)?;
    let empty_point = point(header.left() + header.size.width * 0.6, label.center().y);
    pickup(handle, cx)?;
    move_drag(handle, empty_point, cx)?;
    pause(cx, 100).await;
    let empty = marker(handle, 0, label.left() + px(8.0), label.center().y, cx)?;
    capture_native(
        handle,
        output,
        &format!("tab-insertion-{tone}-empty-header"),
        cx,
    )
    .await?;
    release(handle, empty_point, cx)?;
    pause(cx, 220).await;
    assert_clean(handle, cx)?;
    let after_empty = state(handle, cx)?;
    anyhow::ensure!(
        after_empty["upper"] == serde_json::json!(["launch-2"])
            && after_empty["lower"] == serde_json::json!(["launch-0"]),
        "empty header did not adopt the tab: {after_empty}"
    );
    capture_native(
        handle,
        output,
        &format!("tab-insertion-{tone}-empty-after-drop"),
        cx,
    )
    .await?;
    samples.push(serde_json::json!({"name":"empty","geometry":empty}));
    Ok(samples)
}

pub(super) async fn exercise(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let result = run(handle, tone, output, cx).await;
    let report = match &result {
        Ok(samples) => serde_json::json!({
            "passed":true,
            "scope":"Production event dispatch and own native window captures using synthetic content; OS pointer input is separate.",
            "checks":["upper to lower stacked header", "first/middle/append insertion marker", "marker aligns with title row", "drop uses highlighted slot", "empty header placement", "Escape cleanup", "unsent draft retained", "no extra window"],
            "samples":samples
        }),
        Err(error) => serde_json::json!({"passed":false,"error":format!("{error:#}")}),
    };
    std::fs::write(
        output.join(format!("tab-insertion-{tone}-result.json")),
        serde_json::to_vec_pretty(&report)?,
    )?;
    result.map(|_| ())
}
