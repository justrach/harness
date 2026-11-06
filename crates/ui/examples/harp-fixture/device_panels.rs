//! Isolated native device and panel coverage. No UI engine handle or cloud RPC.
use super::*;
use gpui::{AnyWindowHandle, Entity, Pixels, WindowHandle};

type Handle = WindowHandle<shell::Shell>;

fn bounds(handle: Handle, selector: &str, cx: &mut AsyncApp) -> anyhow::Result<Bounds<Pixels>> {
    AnyWindowHandle::from(handle)
        .update(cx, |_, window, cx| {
            // Cached native scenes can replay without repopulating debug
            // selectors. Measure a fresh frame, as the history fixture does.
            window.refresh();
            window.draw(cx).clear();
            window.debug_bounds(selector)
        })?
        .ok_or_else(|| anyhow::anyhow!("missing rendered selector {selector:?}"))
}

async fn settle_away(
    handle: Handle,
    width: f32,
    height: f32,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    cloud_pointer_move(handle, point(px(width - 24.), px(height / 2.)), cx)?;
    pause(cx, 450).await;
    Ok(())
}

async fn hover_selector(
    handle: Handle,
    selector: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<Bounds<Pixels>> {
    let bounds = bounds(handle, selector, cx)?;
    cloud_pointer_move(handle, bounds.center(), cx)?;
    pause(cx, 500).await;
    Ok(bounds)
}

fn click_selector(handle: Handle, selector: &str, cx: &mut AsyncApp) -> anyhow::Result<()> {
    let bounds = bounds(handle, selector, cx)?;
    cloud_pointer_move(handle, bounds.center(), cx)?;
    cloud_pointer_click(handle, bounds.center(), cx)
}

pub(super) async fn review(
    handle: Handle,
    local_device: &str,
    cx: &mut AsyncApp,
    output: &Path,
    tone: &str,
) -> anyhow::Result<()> {
    for (width, height) in [(1440., 900.), (980., 700.)] {
        for count in [1, 3, 6] {
            for collapsed in [false, true] {
                handle.update(cx, |shell, window, cx| {
                    window.resize(size(px(width), px(height)));
                    shell.fixture_cloud_devices(count, collapsed, window, cx);
                })?;
                settle_away(handle, width, height, cx).await?;
                let sidebar = if collapsed { "collapsed" } else { "sidebar" };
                let prefix = format!("devices-{count}-{sidebar}-{tone}-{width}");
                capture(handle.into(), cx, output, &format!("{prefix}-base"))?;
                let trigger = if collapsed {
                    "cloud-sandbox-chip"
                } else {
                    "cloud-computer-fixture-studio"
                };
                let anchor = hover_selector(handle, trigger, cx).await?;
                anyhow::ensure!(
                    handle.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
                    "{prefix}: hover must show the preview"
                );
                let popup = bounds(handle, "cloud-computer-detail", cx)?;
                if collapsed {
                    let gap = f32::from(popup.top() - anchor.bottom());
                    anyhow::ensure!(
                        (0.0..=12.0).contains(&gap),
                        "{prefix}: popover must sit immediately below its trigger; gap={gap}"
                    );
                    anyhow::ensure!(
                        f32::from(popup.left() - anchor.left()).abs() <= 2.,
                        "{prefix}: popover must align with its trigger"
                    );
                }
                capture(handle.into(), cx, output, &format!("{prefix}-hover"))?;
                cloud_pointer_move(handle, popup.center(), cx)?;
                pause(cx, 300).await;
                anyhow::ensure!(
                    handle.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
                    "{prefix}: pointer can enter the preview"
                );
                let target = if count == 1 {
                    "fixture-studio"
                } else {
                    "fixture-render"
                };
                let click_target = if collapsed && count > 1 {
                    format!("cloud-list-{target}")
                } else if collapsed {
                    "cloud-sandbox-chip".into()
                } else {
                    format!("cloud-computer-{target}")
                };
                click_selector(handle, &click_target, cx)?;
                pause(cx, 450).await;
                anyhow::ensure!(
                    handle
                        .update(cx, |shell, _, cx| shell.fixture_cloud_settings_selected(cx))?
                        .as_deref()
                        == Some(target),
                    "{prefix}: click must reveal the exact chosen computer in Settings"
                );
                anyhow::ensure!(
                    !handle.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
                    "{prefix}: Settings navigation must close the preview"
                );
                if count == 3 {
                    capture(handle.into(), cx, output, &format!("{prefix}-settings"))?;
                }
            }
        }
        review_panel_choices(handle, local_device, width, height, cx, output, tone).await?;
    }
    eprintln!("Device panel review passed: {tone}");
    Ok(())
}

async fn review_panel_choices(
    handle: Handle,
    local_device: &str,
    width: f32,
    height: f32,
    cx: &mut AsyncApp,
    output: &Path,
    tone: &str,
) -> anyhow::Result<()> {
    handle.update(cx, |shell, window, cx| {
        window.resize(size(px(width), px(height)));
        shell.fixture_cloud_devices(3, false, window, cx);
        shell.fixture_device_panel_prepare(window, cx);
    })?;
    settle_away(handle, width, height, cx).await?;
    let panel = handle.update(cx, |shell, _, cx| shell.fixture_device_panel_id(cx))?;
    let trigger = format!("panel-device-trigger-{panel}");
    anyhow::ensure!(
        handle
            .update(cx, |shell, _, cx| shell.fixture_device_panel_selected(cx))?
            .as_deref()
            == Some("cloud-fixture-studio"),
        "new panel must inherit the originating panel's Studio computer"
    );
    capture(
        handle.into(),
        cx,
        output,
        &format!("panel-device-inherited-{tone}-{width}"),
    )?;
    click_selector(handle, &trigger, cx)?;
    pause(cx, 300).await;
    capture(
        handle.into(),
        cx,
        output,
        &format!("panel-device-menu-{tone}-{width}"),
    )?;
    click_selector(handle, &format!("panel-device-option-{local_device}"), cx)?;
    pause(cx, 250).await;
    anyhow::ensure!(
        handle
            .update(cx, |shell, _, cx| shell.fixture_device_panel_selected(cx))?
            .as_deref()
            == Some(local_device),
        "choosing This Mac must update only the new panel's destination"
    );
    capture(
        handle.into(),
        cx,
        output,
        &format!("panel-device-local-{tone}-{width}"),
    )?;
    click_selector(handle, &trigger, cx)?;
    pause(cx, 250).await;
    click_selector(handle, "panel-device-option-cloud-fixture-studio", cx)?;
    pause(cx, 200).await;
    anyhow::ensure!(
        handle
            .update(cx, |shell, _, cx| shell.fixture_device_panel_selected(cx))?
            .as_deref()
            == Some("cloud-fixture-studio"),
        "choosing Studio must preserve its explicit device identity"
    );
    click_selector(handle, &format!("panel-start-chat-{panel}"), cx)?;
    pause(cx, 400).await;
    anyhow::ensure!(
        handle.update(cx, |shell, _, cx| shell
            .fixture_cloud_chat_is_empty_and_targeted(cx))?,
        "Chat must create an empty unsent draft on the selected computer"
    );
    let selector = bounds(handle, "draft-device-target", cx)
        .or_else(|_| bounds(handle, "composer-device-selector", cx))?;
    let caret = bounds(handle, "composer-device-caret", cx)?;
    anyhow::ensure!(
        caret.left() >= selector.left()
            && caret.right() <= selector.right()
            && caret.top() >= selector.top()
            && caret.bottom() <= selector.bottom(),
        "the remote composer device selector must contain its visible caret"
    );
    capture(
        handle.into(),
        cx,
        output,
        &format!("composer-device-remote-{tone}-{width}"),
    )?;
    Ok(())
}

pub(super) async fn interactive(
    handle: Handle,
    state: Entity<state::AppState>,
    cx: &mut AsyncApp,
    output: &Path,
    tone: &str,
) -> anyhow::Result<()> {
    handle.update(cx, |shell, window, cx| {
        window.resize(size(px(1200.), px(800.)));
        shell.fixture_cloud_devices(3, false, window, cx);
        shell.fixture_device_panel_prepare(window, cx);
        window.activate_window();
        cx.activate(true);
    })?;
    pause(cx, 500).await;
    capture(
        handle.into(),
        cx,
        output,
        &format!("devices-interactive-{tone}"),
    )?;
    let mut ticks = 0_u32;
    loop {
        pause(cx, 250).await;
        if handle.update(cx, |_, _, _| ()).is_err() {
            break;
        }
        ticks += 1;
        if ticks % 20 == 0 {
            state.update(cx, |state, _| {
                assert!(
                    state.engine().is_none(),
                    "synthetic device controls must have no engine handle"
                );
                let running: std::collections::HashSet<String> = state
                    .cloud_sandboxes()
                    .into_iter()
                    .flat_map(|list| list.sandboxes.iter())
                    .filter(|sandbox| sandbox.state == "running")
                    .filter_map(|sandbox| sandbox.device_name.clone())
                    .collect();
                for device in &mut state.devices {
                    if device.name.starts_with("Harness cloud fixture-") {
                        device.last_seen_at = running.contains(&device.name).then(chrono::Utc::now);
                    }
                }
            });
        }
    }
    Ok(())
}
