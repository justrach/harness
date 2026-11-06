//! Real history navigation through the conditional Forward toolbar control.
use super::super::{capture, pause};
use gpui::{AsyncApp, Entity, WindowHandle};
use harness_ui::{appearance, browser::BrowserSurface, motion, shell, theme};

pub(super) const PASS: &str = "PASS: browser Forward is absent initially and at the end of history, animates into view after Back, navigates through its real toolbar hit target, collapses without an active hit target, and snaps with reduced motion.\n";

async fn wait_for(
    page: &Entity<BrowserSurface>,
    title: &str,
    forward: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<Vec<f32>> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let mut samples = Vec::new();
    loop {
        let (state, (progress, bounds)) = page.read_with(cx, |page, _| {
            (page.page.clone(), page.fixture_forward_control())
        });
        samples.push(progress);
        if !state.can_forward && progress > 0.001 && progress < 0.999 {
            anyhow::ensure!(
                bounds.is_none(),
                "exiting Forward retained an interactive hit target"
            );
        }
        let settled = if forward {
            progress >= 0.999 && bounds.is_some()
        } else {
            progress <= 0.001 && bounds.is_none()
        };
        if state.title == title && !state.loading && state.can_forward == forward && settled {
            return Ok(samples);
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "Forward state did not settle: title={title}, forward={forward}, page={state:?}, progress={progress}, bounds={bounds:?}"
        );
        pause(cx, 16).await;
    }
}

fn click_forward(
    window: WindowHandle<shell::Shell>,
    page: &Entity<BrowserSurface>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let (_, bounds) = page.read_with(cx, |page, _| page.fixture_forward_control());
    let bounds = bounds.ok_or_else(|| anyhow::anyhow!("Forward has no interactive bounds"))?;
    anyhow::ensure!(
        f32::from(bounds.size.width) >= 27.5 && f32::from(bounds.size.height) >= 27.5,
        "Forward's settled hit target is too small: {bounds:?}"
    );
    let position = bounds.center();
    #[cfg(target_os = "macos")]
    {
        let (x, y) = (f32::from(position.x) as f64, f32::from(position.y) as f64);
        anyhow::ensure!(
            !page.read_with(cx, |page, _| page.fixture_page_hit(x, y)),
            "native page intercepted Forward's toolbar hit target"
        );
        page.read_with(cx, |page, _| page.fixture_click(x, y));
        let _ = window;
    }
    #[cfg(target_os = "linux")]
    window.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    })?;
    Ok(())
}

pub(super) async fn exercise(
    window: WindowHandle<shell::Shell>,
    page: Entity<BrowserSurface>,
    origin: &str,
    output: &std::path::Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let previous_motion = cx.update(|cx| {
        appearance::set_theme(theme::Appearance::Light, "warm-harp-light", cx);
        appearance::set_mode(appearance::AppearanceMode::Light, cx);
        let previous = motion::reduced_motion(cx);
        motion::set_reduced_motion(cx, false);
        previous
    });
    wait_for(&page, "Fieldnotes", false, cx).await?;
    pause(cx, 150).await;
    capture(output, "browser-forward-initial-hidden")?;
    page.read_with(cx, |page, _| {
        page.fixture_eval("document.getElementById('details').click()")
    });
    wait_for(&page, "Details", false, cx).await?;
    page.update(cx, |page, _| page.fixture_history(false));
    let entering = wait_for(&page, "Fieldnotes", true, cx).await?;
    anyhow::ensure!(
        entering
            .iter()
            .any(|progress| *progress > 0.001 && *progress < 0.999),
        "normal-motion Forward did not render an intermediate reveal frame"
    );
    capture(output, "browser-forward-after-back-visible")?;
    click_forward(window, &page, cx)?;
    let exiting = wait_for(&page, "Details", false, cx).await?;
    capture(output, "browser-forward-after-forward-hidden")?;

    cx.update(|cx| motion::set_reduced_motion(cx, true));
    page.update(cx, |page, _| page.fixture_history(false));
    let reduced_entering = wait_for(&page, "Fieldnotes", true, cx).await?;
    anyhow::ensure!(
        reduced_entering
            .iter()
            .all(|progress| *progress <= 0.001 || *progress >= 0.999),
        "reduced-motion Forward animated instead of snapping"
    );
    capture(output, "browser-forward-reduced-motion-visible")?;
    click_forward(window, &page, cx)?;
    let reduced_exiting = wait_for(&page, "Details", false, cx).await?;
    anyhow::ensure!(
        reduced_exiting
            .iter()
            .all(|progress| *progress <= 0.001 || *progress >= 0.999),
        "reduced-motion Forward animated while hiding"
    );
    std::fs::write(
        output.join("forward-motion.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "entering": entering,
            "exiting": exiting,
            "reduced_entering": reduced_entering,
            "reduced_exiting": reduced_exiting,
        }))?,
    )?;
    cx.update(|cx| motion::set_reduced_motion(cx, previous_motion));
    window.update(cx, |_, window, cx| {
        page.update(cx, |page, cx| page.navigate(origin, window, cx));
    })?;
    wait_for(&page, "Fieldnotes", false, cx).await?;
    eprint!("{PASS}");
    Ok(())
}
