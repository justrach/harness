use gpui::{AsyncApp, Entity, WindowHandle};
use harness_ui::{browser::BrowserSurface, shell::Shell, typography};

async fn expect_zoom(
    page: &Entity<BrowserSurface>,
    expected: f64,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    super::pause(cx, 150).await;
    let actual = page.read_with(cx, |page, _| page.fixture_page_zoom());
    anyhow::ensure!(
        (actual - expected).abs() < 1e-10,
        "expected page zoom {expected}, got {actual}"
    );
    Ok(())
}

pub async fn exercise(
    window: WindowHandle<Shell>,
    origin: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let (_, page) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(origin.into()), window, cx)
    })?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(25);
    while !page.read_with(cx, |page, _| {
        !page.page.loading && page.fixture_native_visible()
    }) {
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "zoom page did not load"
        );
        super::pause(cx, 50).await;
    }
    let app_size = window.update(cx, |_, _, cx| typography::font_size(cx))?;
    page.read_with(cx, |page, _| page.fixture_focus());
    super::pause(cx, 100).await;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_focused()),
        "page did not take native keyboard focus"
    );
    // Post real AppKit events: WebKit has first responder, not GPUI.
    for (key, shift, expected) in [
        ("-", false, 1.0 / 1.1),
        ("=", false, 1.0),
        ("+", true, 1.1),
        ("0", false, 1.0),
    ] {
        page.read_with(cx, |page, _| page.fixture_zoom_key(key, shift));
        if key == "-"
            && let Some(directory) = std::env::var_os("HARNESS_BROWSER_ZOOM_CAPTURE_DIR")
        {
            super::pause(cx, 300).await;
            let directory = std::path::PathBuf::from(directory);
            super::capture(&directory, "browser-zoom")?;
            let (x, y) = page.read_with(cx, |page, _| page.fixture_origin());
            let (width, _, _) = page.read_with(cx, |page, _| page.fixture_geometry());
            std::fs::write(
                directory.join("crop.json"),
                serde_json::to_vec(&[x, y, width, 680.0 - y])?,
            )?;
        }
        expect_zoom(&page, expected, cx).await?;
        anyhow::ensure!(
            page.read_with(cx, |page, _| page.fixture_focused()),
            "zoom moved native keyboard focus"
        );
    }
    // Cmd+L moves focus to GPUI's address input. The same keys must still
    // resize the page rather than the surrounding Harness interface.
    gpui::AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        window.dispatch_keystroke(gpui::Keystroke::parse("cmd-l").unwrap(), cx);
    })?;
    super::pause(cx, 100).await;
    anyhow::ensure!(
        !page.read_with(cx, |page, _| page.fixture_focused()),
        "address focus did not release WebKit"
    );
    for (key, expected) in [("cmd--", 1.0 / 1.1), ("cmd-=", 1.0), ("cmd-0", 1.0)] {
        gpui::AnyWindowHandle::from(window).update(cx, |_, window, cx| {
            window.dispatch_keystroke(gpui::Keystroke::parse(key).unwrap(), cx);
        })?;
        expect_zoom(&page, expected, cx).await?;
    }
    anyhow::ensure!(
        window.update(cx, |_, _, cx| typography::font_size(cx))? == app_size,
        "browser zoom changed the app's text size"
    );
    Ok(())
}
