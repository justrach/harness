use gpui::{AsyncApp, Entity, Focusable, WindowHandle};
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

async fn wait_for_page(
    page: &Entity<BrowserSurface>,
    title: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(25);
    loop {
        let state = page.read_with(cx, |page, _| page.page.clone());
        anyhow::ensure!(state.error.is_none(), "zoom page failed: {:?}", state.error);
        if state.title == title && !state.loading {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            if let Some(directory) = std::env::var_os("HARNESS_BROWSER_ZOOM_CAPTURE_DIR") {
                let _ = super::capture(&std::path::PathBuf::from(directory), "zoom-timeout");
            }
            anyhow::bail!("zoom page did not reach {title}: {state:?}");
        }
        super::pause(cx, 50).await;
    }
}

fn post_key(page: &Entity<BrowserSurface>, combo: &str, caps_lock: bool, cx: &mut AsyncApp) {
    let key = gpui::Keystroke::parse(combo).unwrap();
    page.read_with(cx, |page, _| {
        page.fixture_zoom_key_with_modifiers(&key.key, key.modifiers, caps_lock);
    });
}

pub async fn exercise(
    window: WindowHandle<Shell>,
    origin: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let (id, page) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(origin.into()), window, cx)
    })?;
    gpui::AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        window.activate_window();
        cx.activate(true);
        cx.refresh_windows();
    })?;
    wait_for_page(&page, "Fieldnotes", cx).await?;
    let app_size = window.update(cx, |_, _, cx| typography::font_size(cx))?;
    page.read_with(cx, |page, _| page.fixture_focus());
    super::pause(cx, 100).await;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_focused()),
        "page did not take native keyboard focus"
    );
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
    // Modifier rejection is covered by the pure resolver tests; unrelated
    // modified chords may legitimately invoke other app or system commands.
    post_key(&page, "cmd-=", true, cx);
    expect_zoom(&page, 1.1, cx).await?;
    post_key(&page, "cmd-0", true, cx);
    expect_zoom(&page, 1.0, cx).await?;

    // Exercise real AppKit punctuation translation, not just synthetic GPUI
    // chords that bypass macOS's normalization of Shift on the plus key.
    post_key(&page, "cmd-l", false, cx);
    super::pause(cx, 150).await;
    let address = window.update(cx, |_, window, cx| {
        page.read(cx).fixture_address_state(window, cx)
    })?;
    anyhow::ensure!(address.1, "Cmd+L did not focus the address input");
    for (combo, expected) in [
        ("cmd--", 1.0 / 1.1),
        ("cmd-=", 1.0),
        ("cmd-shift-=", 1.1),
        ("cmd-0", 1.0),
    ] {
        post_key(&page, combo, false, cx);
        expect_zoom(&page, expected, cx).await?;
        anyhow::ensure!(
            window.update(cx, |_, window, cx| {
                page.read(cx).fixture_address_state(window, cx)
            })? == address,
            "zoom edited the address or moved its keyboard focus"
        );
    }

    // A native tab retains its zoom across navigation, reload and history.
    page.read_with(cx, |page, _| page.fixture_focus());
    post_key(&page, "cmd-=", false, cx);
    expect_zoom(&page, 1.1, cx).await?;
    page.read_with(cx, |page, _| {
        page.fixture_eval("document.getElementById('details').click()");
    });
    wait_for_page(&page, "Details", cx).await?;
    expect_zoom(&page, 1.1, cx).await?;
    page.read_with(cx, |page, _| page.fixture_eval("location.reload()"));
    super::pause(cx, 200).await;
    wait_for_page(&page, "Details", cx).await?;
    expect_zoom(&page, 1.1, cx).await?;
    page.update(cx, |page, _| page.fixture_history(false));
    wait_for_page(&page, "Fieldnotes", cx).await?;
    expect_zoom(&page, 1.1, cx).await?;
    page.update(cx, |page, _| page.fixture_history(true));
    wait_for_page(&page, "Details", cx).await?;
    expect_zoom(&page, 1.1, cx).await?;

    anyhow::ensure!(
        window.update(cx, |_, _, cx| typography::font_size(cx))? == app_size,
        "browser shortcuts changed app text size before tab switching"
    );
    eprintln!(
        "PASS: native/address shortcuts, Caps Lock, Shift+Plus, navigation/reload/history zoom"
    );
    // HTML preview refresh rebuilds an isolated native host. Zoom is tab state,
    // not document/widget state, and must survive that host replacement.
    for _ in 0..2 {
        window.update(cx, |_, window, cx| {
            page.update(cx, |page, cx| {
                page.fixture_document("<p>Synthetic zoom document</p>", window, cx)
                    .map_err(anyhow::Error::msg)
            })
        })??;
        expect_zoom(&page, 1.1, cx).await?;
        wait_for_page(&page, "fixture.html", cx).await?;
    }
    // New/background tabs must neither inherit nor consume another tab's zoom.
    let (other_id, other) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(origin.into()), window, cx)
    })?;
    wait_for_page(&other, "Fieldnotes", cx).await?;
    expect_zoom(&other, 1.0, cx).await?;
    anyhow::ensure!(
        !page.read_with(cx, |page, _| page.fixture_native_visible()),
        "background tab stayed visible"
    );
    // The first tab exercises native keyboard input; use the browser's GPUI
    // action route here to check tab-local state independently of WebKit focus.
    gpui::AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        window.focus(&other.focus_handle(cx), cx);
        window.dispatch_keystroke(gpui::Keystroke::parse("cmd--").unwrap(), cx);
    })?;
    expect_zoom(&other, 1.0 / 1.1, cx).await?;
    expect_zoom(&page, 1.1, cx).await?;
    window.update(cx, |shell, _, cx| shell.fixture_select_browser(id, cx))?;
    wait_for_page(&page, "fixture.html", cx).await?;
    expect_zoom(&page, 1.1, cx).await?;
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(other_id, window, cx);
    })?;
    anyhow::ensure!(
        !other.read_with(cx, |page, _| page.fixture_native_visible()),
        "closed tab retained native content"
    );

    anyhow::ensure!(
        window.update(cx, |_, _, cx| typography::font_size(cx))? == app_size,
        "browser zoom changed the app's text size"
    );

    // No page: browser actions must fall back to the app's existing font-size
    // actions, rather than swallowing the key or attempting to access WebKit.
    let (empty_id, empty) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(None, window, cx)
    })?;
    super::pause(cx, 150).await;
    gpui::AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        window.focus(&empty.focus_handle(cx), cx);
        window.dispatch_keystroke(gpui::Keystroke::parse("cmd-=").unwrap(), cx);
    })?;
    super::pause(cx, 150).await;
    anyhow::ensure!(
        window.update(cx, |_, _, cx| typography::font_size(cx))? == app_size.stepped(1),
        "empty browser swallowed the app font-size shortcut"
    );
    expect_zoom(&page, 1.1, cx).await?;
    gpui::AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        window.dispatch_keystroke(gpui::Keystroke::parse("cmd-0").unwrap(), cx);
    })?;
    super::pause(cx, 150).await;
    anyhow::ensure!(
        window.update(cx, |_, _, cx| typography::font_size(cx))? == app_size,
        "empty browser swallowed the app font-size reset"
    );
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(empty_id, window, cx);
        shell.fixture_close_browser(id, window, cx);
    })?;
    Ok(())
}
