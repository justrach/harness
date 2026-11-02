//! Deterministic completions through the real input/debounce/dropdown path.
use super::super::{capture, pause};
use gpui::{
    AnyWindowHandle, AsyncApp, Bounds, Entity, Pixels, PlatformInput, WindowHandle, px, size,
};
use harness_ui::{appearance, browser::BrowserSurface, shell, theme};

pub(super) const PASS: &str = "PASS: search words show the exact query and deterministic completions; native overlay rows, keyboard navigation/acceptance, row clicks, Escape/native-page dismissal, URL/localhost/credential suppression and latest-query wins. Light/dark/narrow native captures.\n";

const COMPLETIONS: [&str; 3] = [
    "fieldnotes workspace",
    "fieldnotes design",
    "fieldnotes examples",
];

fn input(
    window: WindowHandle<shell::Shell>,
    page: &Entity<BrowserSurface>,
    text: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        page.update(cx, |page, cx| page.fixture_search_input(text, window, cx));
    })?;
    Ok(())
}

fn key(window: WindowHandle<shell::Shell>, key: &str, cx: &mut AsyncApp) -> anyhow::Result<()> {
    let stroke = gpui::Keystroke::parse(key)?;
    // Input may emit BrowserEvent::Changed and update the owning Shell. Keep
    // the root entity unborrowed while dispatching through its actual tree.
    AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        window.dispatch_event(
            PlatformInput::KeyDown(gpui::KeyDownEvent {
                keystroke: stroke.clone(),
                is_held: false,
                prefer_character_input: false,
            }),
            cx,
        );
        window.dispatch_event(
            PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke: stroke }),
            cx,
        );
    })?;
    Ok(())
}

async fn rows(
    page: &Entity<BrowserSurface>,
    query: &str,
    expected: &[&str],
    cx: &mut AsyncApp,
) -> anyhow::Result<Vec<Bounds<Pixels>>> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let (state, bounds) = page.read_with(cx, |page, _| {
            (page.fixture_search_state(), page.fixture_search_bounds())
        });
        if state.0.as_deref() == Some(query)
            && state
                .1
                .iter()
                .map(String::as_str)
                .eq(expected.iter().copied())
            && bounds.len() == expected.len() + 1
        {
            anyhow::ensure!(
                bounds
                    .iter()
                    .all(|b| f32::from(b.size.width) >= 80. && f32::from(b.size.height) >= 24.),
                "completion rows have unusable bounds: {bounds:?}"
            );
            return Ok(bounds);
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "completion dropdown did not settle for {query}: state={state:?}, bounds={bounds:?}"
        );
        pause(cx, 25).await;
    }
}

async fn closed(page: &Entity<BrowserSurface>, cx: &mut AsyncApp) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        if page.read_with(cx, |page, _| {
            page.fixture_search_state().0.is_none() && page.fixture_search_bounds().is_empty()
        }) {
            return Ok(());
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "completion dropdown did not close"
        );
        pause(cx, 25).await;
    }
}

fn selected(page: &Entity<BrowserSurface>, expected: usize, cx: &AsyncApp) -> anyhow::Result<()> {
    let actual = page.read_with(cx, |page, _| page.fixture_search_state().2);
    anyhow::ensure!(
        actual == expected,
        "selected row {actual}, expected {expected}"
    );
    Ok(())
}

fn accept_and_restore(
    window: WindowHandle<shell::Shell>,
    page: &Entity<BrowserSurface>,
    click: Option<Bounds<Pixels>>,
    query: &str,
    origin: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let address = AnyWindowHandle::from(window).update(cx, |_, window, cx| {
        if let Some(bounds) = click {
            for event in [
                PlatformInput::MouseDown(gpui::MouseDownEvent {
                    position: bounds.center(),
                    button: gpui::MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
                PlatformInput::MouseUp(gpui::MouseUpEvent {
                    position: bounds.center(),
                    button: gpui::MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
            ] {
                window.dispatch_event(event, cx);
            }
        } else {
            window.dispatch_event(
                PlatformInput::KeyDown(gpui::KeyDownEvent {
                    keystroke: gpui::Keystroke::parse("enter").unwrap(),
                    is_held: false,
                    prefer_character_input: false,
                }),
                cx,
            );
        }
        // Observe the accepted destination synchronously, then cancel back to
        // the fixture page before relying on any remote page load or redirect.
        let address = page.read(cx).page.url.clone();
        page.update(cx, |page, cx| page.navigate(origin, window, cx));
        address
    })?;
    anyhow::ensure!(
        address.as_deref() == Some(harness_ui::browser::model::search_url(query).as_str()),
        "accepted search destination mismatch for {query}: {address:?}"
    );
    Ok(())
}

pub(super) async fn exercise(
    window: WindowHandle<shell::Shell>,
    page: Entity<BrowserSurface>,
    origin: &str,
    output: &std::path::Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    page.update(cx, |page, _| {
        page.fixture_search_provider(COMPLETIONS.map(str::to_owned).to_vec());
    });
    let mut evidence = Vec::new();
    for (tone, mode, variant, width) in [
        (
            "light",
            appearance::AppearanceMode::Light,
            theme::Appearance::Light,
            1200.,
        ),
        (
            "dark",
            appearance::AppearanceMode::Dark,
            theme::Appearance::Dark,
            1200.,
        ),
        (
            "light",
            appearance::AppearanceMode::Light,
            theme::Appearance::Light,
            980.,
        ),
    ] {
        cx.update(|cx| {
            appearance::set_theme(variant, format!("warm-harp-{tone}"), cx);
            appearance::set_mode(mode, cx);
        });
        window.update(cx, |_, window, _| window.resize(size(px(width), px(760.))))?;
        pause(cx, 150).await;
        input(window, &page, "fieldnotes", cx)?;
        let bounds = rows(&page, "fieldnotes", &COMPLETIONS, cx).await?;
        pause(cx, 50).await;
        anyhow::ensure!(
            bounds
                .iter()
                .all(|b| f32::from(b.left()) >= 0. && f32::from(b.right()) <= width),
            "suggestions escape narrow window"
        );
        #[cfg(target_os = "macos")]
        for row in &bounds {
            let center = row.center();
            let (x, y) = (f32::from(center.x) as f64, f32::from(center.y) as f64);
            anyhow::ensure!(
                page.read_with(cx, |page, _| page.fixture_overlay_at(x, y)
                    && !page.fixture_page_hit(x, y)),
                "WebKit covers the suggestion row"
            );
        }
        evidence.push(serde_json::json!({"tone":tone,"width":width,"rows":bounds.iter().map(|b|[f32::from(b.left()),f32::from(b.top()),f32::from(b.size.width),f32::from(b.size.height)]).collect::<Vec<_>>()}));
        pause(cx, 100).await;
        capture(output, &format!("browser-search-{tone}-{width:.0}"))?;
    }

    selected(&page, 0, cx)?;
    key(window, "down", cx)?;
    selected(&page, 1, cx)?;
    key(window, "down", cx)?;
    selected(&page, 2, cx)?;
    key(window, "up", cx)?;
    selected(&page, 1, cx)?;
    accept_and_restore(window, &page, None, COMPLETIONS[0], origin, cx)?;
    closed(&page, cx).await?;

    input(window, &page, "fieldnotes", cx)?;
    let bounds = rows(&page, "fieldnotes", &COMPLETIONS, cx).await?;
    accept_and_restore(window, &page, Some(bounds[2]), COMPLETIONS[1], origin, cx)?;
    closed(&page, cx).await?;
    input(window, &page, "fieldnotes", cx)?;
    rows(&page, "fieldnotes", &COMPLETIONS, cx).await?;
    accept_and_restore(window, &page, None, "fieldnotes", origin, cx)?;
    closed(&page, cx).await?;

    input(window, &page, "fieldnotes", cx)?;
    rows(&page, "fieldnotes", &COMPLETIONS, cx).await?;
    key(window, "escape", cx)?;
    closed(&page, cx).await?;
    for address in [
        "example.com",
        "localhost:3000",
        "https://user:pass@example.com",
        "user:pass@example.com",
        "http://localhost:bad",
    ] {
        input(window, &page, address, cx)?;
        closed(&page, cx).await?;
        pause(cx, 250).await;
        anyhow::ensure!(
            page.read_with(cx, |page, _| page.fixture_search_state().0.is_none()),
            "address reached suggestions: {address}"
        );
    }

    page.update(cx, |page, _| {
        page.fixture_search_provider(vec!["cedar notes".into()])
    });
    input(window, &page, "cedar", cx)?;
    pause(cx, 40).await;
    page.update(cx, |page, _| {
        page.fixture_search_provider(vec!["maple notes".into(), "maple plans".into()])
    });
    input(window, &page, "maple", cx)?;
    rows(&page, "maple", &["maple notes", "maple plans"], cx).await?;
    pause(cx, 300).await;
    rows(&page, "maple", &["maple notes", "maple plans"], cx).await?;

    #[cfg(target_os = "macos")]
    {
        let (left, _) = page.read_with(cx, |page, _| page.fixture_origin());
        let (width, _, _) = page.read_with(cx, |page, _| page.fixture_geometry());
        page.read_with(cx, |page, _| {
            page.fixture_click((left + width / 2.) as f64, 700.)
        });
        closed(&page, cx).await?;
        anyhow::ensure!(
            page.read_with(cx, |page, _| page
                .fixture_page_hit((left + width / 2.) as f64, 700.)),
            "dismissal did not restore native page input"
        );
    }
    #[cfg(target_os = "linux")]
    {
        key(window, "escape", cx)?;
        closed(&page, cx).await?;
    }
    std::fs::write(
        output.join("search-geometry.json"),
        serde_json::to_string_pretty(&evidence)?,
    )?;
    eprint!("{PASS}");
    Ok(())
}
