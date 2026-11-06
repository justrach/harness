//! Real WebKit docking regression: both panes must tile the browser content
//! rectangle, including after window and inspector divider resizing.
use super::*;
use gpui::Entity;
use objc2::rc::Retained;
use objc2_app_kit::{NSApplication, NSAutoresizingMaskOptions, NSView};
use objc2_foundation::NSObjectProtocol;

fn browser_clip(view: Retained<NSView>) -> Option<Retained<NSView>> {
    if view.class().name() == c"HarnessBrowserClipView" && !view.isHidden() {
        return Some(view);
    }
    view.subviews().into_iter().find_map(browser_clip)
}

fn rect(value: &serde_json::Value, key: &str) -> [f64; 4] {
    std::array::from_fn(|i| value[key][i].as_f64().unwrap_or(f64::NAN))
}

fn contained(outer: [f64; 4], inner: [f64; 4]) -> bool {
    inner[2] > 0.
        && inner[3] > 0.
        && inner[0] >= outer[0] - 1.
        && inner[1] >= outer[1] - 1.
        && inner[0] + inner[2] <= outer[0] + outer[2] + 1.
        && inner[1] + inner[3] <= outer[1] + outer[3] + 1.
}

fn tiled(value: &serde_json::Value, side: &str) -> bool {
    let expected = rect(value, "expected");
    let page = rect(value, "page");
    let inspector = rect(value, "inspector");
    let near = |a: f64, b: f64| (a - b).abs() < 1.1;
    value["attached"] == true
        && contained(expected, page)
        && contained(expected, inspector)
        && match side {
            "bottom" => {
                near(page[2], expected[2])
                    && near(inspector[2], expected[2])
                    && near(page[3] + inspector[3], expected[3])
                    && near(inspector[1] + inspector[3], page[1])
            }
            "left" => {
                near(page[3], expected[3])
                    && near(inspector[3], expected[3])
                    && near(page[2] + inspector[2], expected[2])
                    && near(inspector[0] + inspector[2], page[0])
            }
            "right" => {
                near(page[3], expected[3])
                    && near(inspector[3], expected[3])
                    && near(page[2] + inspector[2], expected[2])
                    && near(page[0] + page[2], inspector[0])
            }
            _ => false,
        }
}

pub(super) async fn exercise(
    window: WindowHandle<shell::Shell>,
    page: Entity<browser::BrowserSurface>,
    output: &std::path::Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, cx| {
        window.focus(&page.focus_handle(cx), cx);
        window.dispatch_action(Box::new(shell::ToggleChatPaneZoom), cx);
    })?;
    pause(cx, 400).await;
    // Negative control: reconstruct the old native hierarchy in this synthetic
    // window, without replacing product source or touching another running app.
    // Docking directly into the window-sized clip must reproduce the cropping.
    let app = NSApplication::sharedApplication(objc2::MainThreadMarker::new().unwrap());
    let clip = app
        .windows()
        .into_iter()
        .filter_map(|window| window.contentView())
        .find_map(browser_clip)
        .ok_or_else(|| anyhow::anyhow!("browser native host is missing"))?;
    let viewport = clip.subviews().firstObject().unwrap();
    let inspected = viewport.subviews().firstObject().unwrap();
    clip.addSubview(&inspected);
    inspected.setFrame(viewport.frame());
    inspected.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinYMargin);
    page.read_with(cx, |page, _| page.fixture_inspector("show"));
    pause(cx, 1800).await;
    let mut baseline = Vec::new();
    for side in ["bottom", "right", "left"] {
        anyhow::ensure!(
            page.read_with(cx, |page, _| page.fixture_inspector(side)),
            "baseline inspector did not load"
        );
        pause(cx, 600).await;
        let geometry = page.read_with(cx, |page, _| page.fixture_inspector_geometry());
        anyhow::ensure!(
            geometry["attached"] == true,
            "baseline inspector did not dock: {geometry}"
        );
        anyhow::ensure!(
            !tiled(&geometry, side),
            "old host unexpectedly contained the inspector"
        );
        baseline.push(serde_json::json!({"side":side,"geometry":geometry}));
        capture(output, &format!("before-{side}"))?;
    }
    std::fs::write(
        output.join("before-geometry.json"),
        serde_json::to_string_pretty(&baseline)?,
    )?;
    page.read_with(cx, |page, _| page.fixture_inspector("close"));
    pause(cx, 250).await;
    viewport.addSubview(&inspected);
    inspected.setFrame(viewport.bounds());
    inspected.setAutoresizingMask(
        NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
    );
    page.read_with(cx, |page, _| page.fixture_inspector("show"));
    pause(cx, 1800).await;
    let mut records = Vec::new();
    let mut failures = Vec::new();
    for (tone, mode, variant, width, height) in [
        (
            "light",
            appearance::AppearanceMode::Light,
            theme::Appearance::Light,
            1200.,
            760.,
        ),
        (
            "dark",
            appearance::AppearanceMode::Dark,
            theme::Appearance::Dark,
            980.,
            700.,
        ),
    ] {
        cx.update(|cx| {
            appearance::set_theme(variant, format!("warm-harp-{tone}"), cx);
            appearance::set_mode(mode, cx);
        });
        window.update(cx, |_, window, _| {
            window.resize(size(px(width), px(height)))
        })?;
        pause(cx, 450).await;
        for side in ["bottom", "right", "left"] {
            let deadline = std::time::Instant::now() + Duration::from_secs(15);
            while !page.read_with(cx, |page, _| page.fixture_inspector(side)) {
                anyhow::ensure!(
                    std::time::Instant::now() < deadline,
                    "inspector frontend did not load"
                );
                pause(cx, 100).await;
            }
            pause(cx, 600).await;
            for stage in ["docked", "divider-resized", "window-resized"] {
                if stage == "divider-resized" {
                    page.read_with(cx, |page, _| page.fixture_inspector("resize"));
                } else if stage == "window-resized" {
                    window.update(cx, |_, window, _| {
                        window.resize(size(px(width - 80.), px(height - 40.)))
                    })?;
                }
                pause(cx, 450).await;
                let geometry = page.read_with(cx, |page, _| page.fixture_inspector_geometry());
                let name = format!("inspector-{tone}-{side}-{stage}");
                if !tiled(&geometry, side) {
                    failures.push(name.clone());
                }
                records.push(serde_json::json!({"case": name, "geometry": geometry}));
                if stage != "divider-resized" {
                    capture(output, &name)?;
                }
            }
            window.update(cx, |_, window, _| {
                window.resize(size(px(width), px(height)))
            })?;
            pause(cx, 250).await;
        }
    }
    page.read_with(cx, |page, _| page.fixture_inspector("close"));
    pause(cx, 350).await;
    let closed_attached = page.read_with(cx, |page, _| page.fixture_inspector_geometry());
    if !rect(&closed_attached, "expected")
        .into_iter()
        .zip(rect(&closed_attached, "page"))
        .all(|(a, b)| (a - b).abs() < 1.1)
    {
        failures.push("closed-attached-page-restoration".to_owned());
    }
    records.push(serde_json::json!({"case": "closed-attached", "geometry": closed_attached}));
    page.read_with(cx, |page, _| page.fixture_inspector("show"));
    pause(cx, 1800).await;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_inspector("right")),
        "inspector did not reopen"
    );
    pause(cx, 600).await;
    page.read_with(cx, |page, _| page.fixture_inspector("detach"));
    pause(cx, 400).await;
    let detached = page.read_with(cx, |page, _| page.fixture_inspector_geometry());
    anyhow::ensure!(detached["attached"] == false, "inspector did not detach");
    records.push(serde_json::json!({"case": "detached", "geometry": detached}));
    page.read_with(cx, |page, _| page.fixture_inspector("close"));
    pause(cx, 300).await;
    let closed = page.read_with(cx, |page, _| page.fixture_inspector_geometry());
    let expected = rect(&closed, "expected");
    let restored = rect(&closed, "page");
    if !expected
        .into_iter()
        .zip(restored)
        .all(|(a, b)| (a - b).abs() < 1.1)
    {
        failures.push("closed-page-restoration".to_owned());
    }
    records.push(serde_json::json!({"case": "closed", "geometry": closed}));
    std::fs::write(
        output.join("geometry.json"),
        serde_json::to_string_pretty(&records)?,
    )?;
    std::fs::write(
        output.join("failures.json"),
        serde_json::to_string_pretty(&failures)?,
    )?;
    anyhow::ensure!(
        failures.is_empty(),
        "inspector escaped browser content: {}",
        failures.join(", ")
    );
    std::fs::write(
        output.join("result.txt"),
        "PASS: real WebKit inspector; bottom/right/left docking, divider and window resizing in light/dark, detaching, and full page restoration.\n",
    )?;
    Ok(())
}
