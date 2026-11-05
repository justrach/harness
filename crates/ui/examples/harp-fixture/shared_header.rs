//! Native captures and production pointer dispatch for the shared window row.
use super::*;
use gpui::{AnyWindowHandle, MouseButton, Pixels, PlatformInput, Point, WindowHandle};

pub(super) fn dispatch(
    handle: WindowHandle<shell::Shell>,
    event: PlatformInput,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    AnyWindowHandle::from(handle).update(cx, |_, window, cx| {
        window.dispatch_event(event, cx);
        window.draw(cx).clear();
    })?;
    Ok(())
}

fn move_pointer(
    handle: WindowHandle<shell::Shell>,
    position: Point<Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    dispatch(
        handle,
        PlatformInput::MouseMove(gpui::MouseMoveEvent {
            position,
            ..Default::default()
        }),
        cx,
    )
}

pub(super) fn bounds(
    handle: WindowHandle<shell::Shell>,
    selector: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<Bounds<Pixels>> {
    AnyWindowHandle::from(handle)
        .update(cx, |_, window, cx| {
            window.draw(cx).clear();
            window.debug_bounds(selector)
        })?
        .ok_or_else(|| anyhow::anyhow!("missing rendered selector {selector:?}"))
}

fn click(
    handle: WindowHandle<shell::Shell>,
    selector: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let position = bounds(handle, selector, cx)?.center();
    move_pointer(handle, position, cx)?;
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

fn escape(handle: WindowHandle<shell::Shell>, cx: &mut AsyncApp) -> anyhow::Result<()> {
    dispatch(
        handle,
        PlatformInput::KeyDown(gpui::KeyDownEvent {
            keystroke: gpui::Keystroke::parse("escape")?,
            is_held: false,
            prefer_character_input: false,
        }),
        cx,
    )
}

pub(super) async fn capture_native(
    handle: WindowHandle<shell::Shell>,
    output: &Path,
    name: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let path = output.join(format!("{name}.png"));
    #[cfg(target_os = "macos")]
    {
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            let native_id = AnyWindowHandle::from(handle).update(cx, |_, window, cx| {
                use raw_window_handle::{HasWindowHandle, RawWindowHandle};
                window.draw(cx).clear();
                let RawWindowHandle::AppKit(raw) = HasWindowHandle::window_handle(window)?.as_raw()
                else {
                    anyhow::bail!("expected an AppKit fixture window");
                };
                let view = unsafe { &*raw.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
                Ok(view.window().and_then(|native| {
                    (native.isVisible() && native.windowNumber() > 0)
                        .then(|| native.windowNumber().to_string())
                }))
            })??;
            if let Some(native_id) = native_id {
                let path = path.clone();
                let result = cx
                    .background_executor()
                    .spawn(async move {
                        std::process::Command::new("/usr/sbin/screencapture")
                            .args(["-x", "-o", "-l", &native_id])
                            .arg(path)
                            .output()
                    })
                    .await?;
                if result.status.success() {
                    return Ok(());
                }
            }
            anyhow::ensure!(
                std::time::Instant::now() < deadline,
                "native capture failed: {name}"
            );
            pause(cx, 100).await;
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        AnyWindowHandle::from(handle).update(cx, |_, window, cx| {
            window.draw(cx).clear();
            window.render_to_image()?.save(path)?;
            anyhow::Ok(())
        })??;
        Ok(())
    }
}

fn geometry(
    handle: WindowHandle<shell::Shell>,
    kind: &str,
    collapsed: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<serde_json::Value> {
    let body = bounds(handle, "workspace-panel-body-0", cx)?;
    let state = handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?;
    let shared = state["sharedHeader"].as_bool().unwrap_or(false);
    let wanted_top = if collapsed && !shared { 84.0 } else { 42.0 };
    anyhow::ensure!(
        (f32::from(body.top()) - wanted_top).abs() < 1.0,
        "{kind} sidebarCollapsed={collapsed}: body begins at {:?}, expected {wanted_top}",
        body.top()
    );
    let content = bounds(
        handle,
        if kind == "empty" {
            "panel-empty-label-0"
        } else {
            "panel-tab-content-0-0"
        },
        cx,
    )?;
    let toggle = bounds(handle, "toggle-sidebar", cx)?;
    if shared {
        anyhow::ensure!(
            (content.center().y - toggle.center().y).abs() < px(1.0),
            "one-panel title and native controls do not share a row: {content:?}, {toggle:?}"
        );
    }
    let session = AnyWindowHandle::from(handle).update(cx, |_, window, _| {
        window.debug_bounds("workspace-session-quick-switcher")
    })?;
    if shared && collapsed {
        let session = session
            .ok_or_else(|| anyhow::anyhow!("collapsed shared row has no session switcher"))?;
        let tab = bounds(
            handle,
            if kind == "empty" {
                "panel-empty-label-0"
            } else {
                "panel-tab-0-0"
            },
            cx,
        )?;
        anyhow::ensure!(
            tab.left() >= session.right(),
            "tabs overlap the retained left session section: {tab:?}, {session:?}"
        );
        anyhow::ensure!(
            (content.center().y - session.center().y).abs() < px(1.0),
            "session and panel label centerlines disagree"
        );
    }
    if !collapsed {
        anyhow::ensure!(
            session.is_none(),
            "expanded sidebar still renders the compact session switcher"
        );
    }
    let rect = |rect: Bounds<Pixels>| {
        [
            f32::from(rect.left()),
            f32::from(rect.top()),
            f32::from(rect.size.width),
            f32::from(rect.size.height),
        ]
    };
    Ok(serde_json::json!({
        "body": rect(body), "tabContent": rect(content), "sidebarToggle": rect(toggle),
        "sessionSwitcher": session.map(rect), "state": state
    }))
}

async fn run(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<Vec<serde_json::Value>> {
    let mut records = vec![];
    for (width, height, long_session) in [
        (1200.0, 760.0, false),
        (980.0, 700.0, true),
        (760.0, 700.0, true),
    ] {
        for collapsed in [true, false] {
            for kind in ["empty", "one-tab", "many-tabs", "split", "expanded-split"] {
                if width < 1200.0 && kind != "many-tabs" {
                    continue;
                }
                handle.update(cx, |shell, window, cx| {
                    window.resize(size(px(width), px(height)));
                    shell.fixture_shared_header_case(kind, collapsed, long_session, window, cx);
                })?;
                pause(cx, 220).await;
                move_pointer(handle, point(px(width * 0.5), px(300.0)), cx)?;
                pause(cx, 50).await;
                let name = format!(
                    "shared-header-{tone}-{width}-{kind}-{}",
                    if collapsed { "collapsed" } else { "expanded" }
                );
                let shape = geometry(handle, kind, collapsed, cx).map_err(|error| {
                    anyhow::anyhow!("{tone} {width} {kind} collapsed={collapsed}: {error:#}")
                })?;
                capture_native(handle, output, &name, cx).await?;
                records.push(serde_json::json!({"capture": name, "geometry": shape}));
            }
        }
    }
    handle.update(cx, |shell, window, cx| {
        window.resize(size(px(1200.0), px(760.0)));
        shell.fixture_shared_header_case("one-tab", true, false, window, cx);
    })?;
    pause(cx, 220).await;
    click(handle, "workspace-session-quick-switcher", cx)?;
    pause(cx, 200).await;
    anyhow::ensure!(
        handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?["sessionMenuOpen"]
            == true,
        "session control did not open its switcher"
    );
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-session-control"),
        cx,
    )
    .await?;
    escape(handle, cx)?;
    pause(cx, 200).await;
    move_pointer(handle, point(px(1170.0), px(21.0)), cx)?;
    pause(cx, 260).await;
    click(handle, "panel-placement-0", cx)?;
    pause(cx, 200).await;
    anyhow::ensure!(
        handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?["placementOpen"]
            == true,
        "shared-row placement control did not open its menu"
    );
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-placement-control"),
        cx,
    )
    .await?;
    escape(handle, cx)?;
    pause(cx, 200).await;
    move_pointer(handle, point(px(1170.0), px(21.0)), cx)?;
    pause(cx, 260).await;
    click(handle, "panel-add-tab-0", cx)?;
    pause(cx, 220).await;
    anyhow::ensure!(
        handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?["tabs"] == 2,
        "shared-row add control did not create exactly one tab"
    );
    geometry(handle, "one-tab", true, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-add-control"),
        cx,
    )
    .await?;
    click(handle, "toggle-sidebar", cx)?;
    pause(cx, 350).await;
    anyhow::ensure!(
        handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?["sidebarCollapsed"]
            == false,
        "retained left sidebar control did not reopen the sidebar"
    );
    geometry(handle, "one-tab", false, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-sidebar-control"),
        cx,
    )
    .await?;
    // Reverse the live sidebar tween before it reaches its collapsed target.
    click(handle, "toggle-sidebar", cx)?;
    pause(cx, 45).await;
    click(handle, "toggle-sidebar", cx)?;
    pause(cx, 350).await;
    anyhow::ensure!(
        handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?["sidebarCollapsed"]
            == false,
        "sidebar reversal did not retain the requested expanded state"
    );
    geometry(handle, "one-tab", false, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-sidebar-reversal"),
        cx,
    )
    .await?;
    click(handle, "toggle-sidebar", cx)?;
    pause(cx, 350).await;
    geometry(handle, "one-tab", true, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-sidebar-reclosed"),
        cx,
    )
    .await?;

    // Close a genuinely empty second panel through its real header control.
    handle.update(cx, |shell, window, cx| {
        shell.fixture_shared_header_case("split-empty", true, false, window, cx);
    })?;
    pause(cx, 220).await;
    geometry(handle, "split-empty", true, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-before-close-panel"),
        cx,
    )
    .await?;
    move_pointer(handle, point(px(570.0), px(63.0)), cx)?;
    pause(cx, 260).await;
    click(handle, "panel-expand-0", cx)?;
    pause(cx, 300).await;
    let expanded = handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?;
    anyhow::ensure!(
        expanded["panels"] == 2 && expanded["sharedHeader"] == true,
        "expanding a panel did not preserve both panels in a shared row"
    );
    geometry(handle, "expanded-split", true, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-expanded-panel-control"),
        cx,
    )
    .await?;
    move_pointer(handle, point(px(1170.0), px(21.0)), cx)?;
    pause(cx, 260).await;
    click(handle, "panel-expand-0", cx)?;
    pause(cx, 300).await;
    let restored = handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?;
    anyhow::ensure!(
        restored["panels"] == 2 && restored["expanded"].is_null(),
        "restoring panels did not retain the original two-panel layout"
    );
    geometry(handle, "split-empty", true, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-restored-panel-control"),
        cx,
    )
    .await?;
    move_pointer(handle, point(px(1170.0), px(63.0)), cx)?;
    pause(cx, 260).await;
    click(handle, "panel-close-1", cx)?;
    pause(cx, 220).await;
    anyhow::ensure!(
        handle.read_with(cx, |shell, cx| shell.fixture_shared_header_state(cx))?["panels"] == 1,
        "closing the second panel did not leave exactly one panel"
    );
    geometry(handle, "one-tab", true, cx)?;
    capture_native(
        handle,
        output,
        &format!("shared-header-{tone}-after-close-panel"),
        cx,
    )
    .await?;
    Ok(records)
}

pub(super) async fn exercise(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let result = run(handle, tone, output, cx).await;
    let report = match &result {
        Ok(cases) => serde_json::json!({
            "passed": true,
            "scope": "Production Shell rendering/event dispatch and synthetic native-window captures; actual OS input is a separate manual check.",
            "checks": ["one panel with zero/one/many tabs", "expanded panel uses shared row and restoring panels returns separate headers", "collapsed and expanded sidebar", "long session and narrow window", "session/placement/add/sidebar control clicks", "live sidebar reversal", "closing second panel restores shared row"],
            "cases": cases
        }),
        Err(error) => serde_json::json!({"passed":false,"error":format!("{error:#}")}),
    };
    std::fs::write(
        output.join(format!("shared-header-{tone}-result.json")),
        serde_json::to_vec_pretty(&report)?,
    )?;
    result.map(|_| ())
}
