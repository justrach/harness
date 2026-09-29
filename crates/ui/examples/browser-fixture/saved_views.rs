// Saved graff views through the real shell path: chip → open_tool_view →
// browser tab → graff-view scheme handler → CSP. Run with HOME pointing at
// a temp home holding `.graff/views/<id>.html` and `.graff/mcp-apps/<id>.html`,
// and the ids in HARNESS_VIEW_FIXTURE_HTML / HARNESS_VIEW_FIXTURE_APP.
use super::{capture, pause};
use gpui::{AsyncApp, Entity, WindowHandle};
use harness_proto::{ToolView, ToolViewKind};
use harness_ui::{browser::BrowserSurface, shell::Shell};
use std::{path::Path, time::Duration};

async fn wait(
    cx: &mut AsyncApp,
    browser: &Entity<BrowserSurface>,
    what: &str,
    ready: impl Fn(&BrowserSurface) -> bool,
) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while !browser.read_with(cx, |b, _| ready(b)) {
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "{what}: {:?}",
            browser.read_with(cx, |b, _| b.page.clone())
        );
        pause(cx, 50).await;
    }
    Ok(())
}

fn view(kind: ToolViewKind, var: &str) -> anyhow::Result<ToolView> {
    let id = std::env::var(var)?;
    ToolView::new(kind, &id).ok_or_else(|| anyhow::anyhow!("{var} is not a view id"))
}

pub async fn exercise(
    window: WindowHandle<Shell>,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    // The model-rendered page checks its own containment and prints
    // PASS/FAIL rows; every one must pass under the served CSP.
    let html = view(ToolViewKind::Html, "HARNESS_VIEW_FIXTURE_HTML")?;
    let (_, page) = window
        .update(cx, |shell, w, cx| shell.fixture_open_view(html, w, cx))?
        .ok_or_else(|| anyhow::anyhow!("the shell refused a local view"))?;
    wait(cx, &page, "html view did not load", |b| {
        b.page.title == "Graff view fixture" && !b.page.loading && b.fixture_native_visible()
    })
    .await?;
    pause(cx, 1500).await;
    capture(output, "view-html")?;
    // The page was written for an iframe host; here it IS the top document
    // in its own web view, so its "host document" row has nothing to probe.
    page.read_with(cx, |b, _| {
        b.fixture_eval(
            "(() => { const rows = [...document.querySelectorAll('#r li')].map(li => li.textContent); \
             const need = ['PASS inline script runs', 'PASS network fetch blocked', \
             'PASS no localStorage (opaque origin)']; \
             document.title = (need.every(n => rows.includes(n)) ? 'VIEW PASS: ' : 'VIEW FAIL: ') + rows.join(' | '); })()",
        )
    });
    wait(cx, &page, "containment rows did not report", |b| b.page.title.starts_with("VIEW ")).await?;
    let verdict = page.read_with(cx, |b, _| b.page.title.clone());
    std::fs::write(output.join("view-html-rows.txt"), &verdict)?;
    anyhow::ensure!(verdict.starts_with("VIEW PASS"), "html view containment: {verdict}");
    // The page cannot take its tab onto the web.
    page.read_with(cx, |b, _| b.fixture_eval("location.href = 'https://example.com/'"));
    pause(cx, 1500).await;
    let url = page.read_with(cx, |b, _| b.page.url.clone()).unwrap_or_default();
    anyhow::ensure!(url.starts_with("graff-view://html/"), "view navigated away to {url}");

    // An MCP App host page renders its app in an inner frame (no bridge yet).
    let app = view(ToolViewKind::McpApp, "HARNESS_VIEW_FIXTURE_APP")?;
    let (_, app_page) = window
        .update(cx, |shell, w, cx| shell.fixture_open_view(app, w, cx))?
        .ok_or_else(|| anyhow::anyhow!("the shell refused a local MCP App view"))?;
    wait(cx, &app_page, "MCP App view did not load", |b| {
        !b.page.loading && b.page.error.is_none() && b.fixture_native_visible()
    })
    .await?;
    pause(cx, 2000).await;
    capture(output, "view-mcp-app")?;
    // The host page's status flips once the app in its nested frames has
    // run ui/initialize and received the saved tool result.
    app_page.read_with(cx, |b, _| {
        b.fixture_eval("document.title = 'APP ' + document.querySelector('#status').textContent")
    });
    wait(cx, &app_page, "MCP App status did not report", |b| b.page.title.starts_with("APP ")).await?;
    let status = app_page.read_with(cx, |b, _| b.page.title.clone());
    std::fs::write(output.join("view-mcp-app-status.txt"), &status)?;
    anyhow::ensure!(status.contains("Result view"), "MCP App did not initialize: {status}");

    // A view whose file is gone opens a tab that says so, and nothing else.
    let gone = ToolView::new(ToolViewKind::Html, "ffffffffffffffffffffffffffffffff").unwrap();
    let (_, missing) = window
        .update(cx, |shell, w, cx| shell.fixture_open_view(gone, w, cx))?
        .ok_or_else(|| anyhow::anyhow!("the shell refused a local view"))?;
    wait(cx, &missing, "missing view did not settle", |b| !b.page.loading).await?;
    pause(cx, 500).await;
    capture(output, "view-missing")?;
    Ok(())
}
