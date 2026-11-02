//! Focused native browser chrome review. Run the browser-fixture example with
//! HARNESS_BROWSER_CHROME_FIXTURE_ONLY=1; all page content stays on loopback.
use super::*;
use gpui::{Focusable, WindowHandle};
#[path = "forward.rs"]
mod forward;
#[cfg(target_os = "macos")]
#[path = "inspector.rs"]
mod inspector;
#[path = "search.rs"]
mod search;

pub(super) async fn exercise(
    window: WindowHandle<shell::Shell>,
    origin: &str,
    output: &std::path::Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, _| {
        window.resize(size(px(1200.0), px(760.0)));
        window.activate_window();
    })?;
    pause(cx, 200).await;
    let (id, page) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(origin.to_owned()), window, cx)
    })?;
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    loop {
        let ready = page.read_with(cx, |page, _| {
            page.page.title == "Fieldnotes" && !page.page.loading && page.fixture_native_visible()
        });
        if ready {
            break;
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "chrome fixture page did not load: {:?}",
            page.read_with(cx, |page, _| page.page.clone())
        );
        pause(cx, 50).await;
    }
    #[cfg(target_os = "linux")]
    super::linux::wait_for_fixture_window(cx).await?;

    #[cfg(target_os = "macos")]
    if std::env::var_os("HARNESS_BROWSER_INSPECTOR_FIXTURE_ONLY").is_some() {
        return inspector::exercise(window, page.clone(), output, cx).await;
    }

    if std::env::var_os("HARNESS_BROWSER_SEARCH_FIXTURE_ONLY").is_some() {
        search::exercise(window, page.clone(), origin, output, cx).await?;
        window.update(cx, |shell, window, cx| {
            shell.fixture_close_browser(id, window, cx);
        })?;
        std::fs::write(output.join("result.txt"), search::PASS)?;
        return Ok(());
    }

    forward::exercise(window, page.clone(), origin, output, cx).await?;
    if std::env::var_os("HARNESS_BROWSER_FORWARD_FIXTURE_ONLY").is_some() {
        window.update(cx, |shell, window, cx| {
            shell.fixture_close_browser(id, window, cx);
        })?;
        std::fs::write(output.join("result.txt"), forward::PASS)?;
        return Ok(());
    }

    let mut geometry: Vec<serde_json::Value> = Vec::new();
    let standard_sizes: &[(f32, f32)] = &[(1200.0, 760.0), (980.0, 700.0), (760.0, 700.0)];
    let large_font_sizes: &[(f32, f32)] = &[(980.0, 700.0)];
    for (tone, mode, variant, font_size, sizes) in [
        (
            "light",
            appearance::AppearanceMode::Light,
            theme::Appearance::Light,
            typography::UiFontSize::default(),
            standard_sizes,
        ),
        (
            "dark",
            appearance::AppearanceMode::Dark,
            theme::Appearance::Dark,
            typography::UiFontSize::default(),
            standard_sizes,
        ),
        (
            "light",
            appearance::AppearanceMode::Light,
            theme::Appearance::Light,
            typography::UiFontSize::default().stepped(2),
            large_font_sizes,
        ),
    ] {
        cx.update(|cx| {
            appearance::set_theme(variant, format!("warm-harp-{tone}"), cx);
            appearance::set_mode(mode, cx);
            appearance::set_surface(harness_theme::SurfacePreference::Frosted, cx);
        });
        window.update(cx, |_, window, cx| {
            typography::set_font_size(font_size, window, cx);
        })?;
        for &(width, height) in sizes {
            window.update(cx, |_, window, _| {
                window.resize(size(px(width), px(height)));
            })?;
            pause(cx, 350).await;
            for (name, editing) in [("rest", false), ("address-focused", true)] {
                window.update(cx, |_, window, cx| {
                    if editing {
                        page.update(cx, |page, cx| page.focus_address(window, cx));
                    } else {
                        window.focus(&page.focus_handle(cx), cx);
                        #[cfg(target_os = "macos")]
                        page.read(cx).fixture_focus();
                    }
                    window.refresh();
                })?;
                pause(cx, 350).await;
                anyhow::ensure!(
                    page.read_with(cx, |page, _| page.fixture_native_visible()),
                    "address focus or resize hid the page at {tone}/{width}/{name}"
                );
                #[cfg(target_os = "macos")]
                {
                    let (layout, native, clip) =
                        page.read_with(cx, |page, _| page.fixture_geometry());
                    let (x, y) = page.read_with(cx, |page, _| page.fixture_origin());
                    anyhow::ensure!(
                        layout > 100.0 && (layout - native).abs() < 1.1 && clip <= layout + 1.0,
                        "native page width disagrees with its layout at {tone}/{width}/{name}"
                    );
                    anyhow::ensure!(
                        page.read_with(cx, |page, _| {
                            page.fixture_page_hit((x + layout / 2.0) as f64, (y + 60.0) as f64)
                                && !page
                                    .fixture_page_hit((x + layout / 2.0) as f64, (y - 12.0) as f64)
                        }),
                        "native page hit testing escapes into the browser toolbar"
                    );
                    if editing {
                        anyhow::ensure!(
                            !page.read_with(cx, |page, _| page.fixture_focused()),
                            "WebKit retained keyboard focus while editing the address"
                        );
                    }
                    geometry.push(serde_json::json!({
                        "tone": tone,
                        "ui_font_size": font_size.pixels(),
                        "window": [width, height],
                        "state": name,
                        "page_origin": [x, y],
                        "layout_width": layout,
                        "native_width": native,
                        "clip_width": clip,
                    }));
                }
                let font_suffix = if font_size == typography::UiFontSize::default() {
                    String::new()
                } else {
                    format!("-font{:.0}", font_size.pixels())
                };
                capture(
                    output,
                    &format!("browser-chrome-{tone}-{width:.0}{font_suffix}-{name}"),
                )?;
            }
        }
    }
    std::fs::write(
        output.join("chrome-geometry.json"),
        serde_json::to_string_pretty(&geometry)?,
    )?;
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(id, window, cx);
    })?;
    pause(cx, 100).await;
    anyhow::ensure!(
        !page.read_with(cx, |page, _| page.fixture_native_visible()),
        "closing the browser retained its native content"
    );
    cx.update(|cx| {
        appearance::set_theme(theme::Appearance::Light, "warm-harp-light", cx);
        appearance::set_mode(appearance::AppearanceMode::Light, cx);
    });
    let (empty_id, empty) = window.update(cx, |shell, window, cx| {
        typography::set_font_size(typography::UiFontSize::default(), window, cx);
        window.resize(size(px(1200.0), px(760.0)));
        shell.fixture_open_browser(None, window, cx)
    })?;
    window.update(cx, |_, window, cx| {
        empty.update(cx, |page, cx| page.focus_address(window, cx));
        window.refresh();
    })?;
    pause(cx, 350).await;
    anyhow::ensure!(
        empty.read_with(cx, |page, _| {
            page.page.url.is_none() && !page.fixture_native_visible()
        }),
        "empty browser unexpectedly retained a page instead of its address placeholder"
    );
    capture(output, "browser-chrome-light-1200-empty")?;
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(empty_id, window, cx);
    })?;
    std::fs::write(
        output.join("result.txt"),
        "PASS: browser chrome; Warm Harp light/dark at 1200×760, 980×700 and 760×700; resting/focused address, live native layout and toolbar/page hit-test separation; light 980×700 at UI font20 resting/focused; light 1200×760 empty address placeholder at UI font16.\n",
    )?;
    Ok(())
}
