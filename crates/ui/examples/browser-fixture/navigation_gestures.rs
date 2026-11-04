use gpui::{AsyncApp, Entity, WindowHandle};
use harness_ui::{browser::BrowserSurface, shell::Shell};

async fn wait_for_page(
    page: &Entity<BrowserSurface>,
    title: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(25);
    while !page.read_with(cx, |page, _| {
        page.page.title == title && !page.page.loading && page.fixture_native_visible()
    }) {
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "navigation fixture did not reach {title}"
        );
        super::pause(cx, 50).await;
    }
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
    wait_for_page(&page, "Fieldnotes", cx).await?;
    // WebKit implements trackpad thresholds, scroll-edge arbitration, system
    // gesture preferences and the interactive transition. Check the real native
    // switch, not a duplicate of the builder configuration in a pure test.
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_navigation_gestures_enabled()),
        "native browser back/forward swipe gestures are disabled"
    );
    anyhow::ensure!(
        page.read_with(cx, |page, _| !page.page.can_back && !page.page.can_forward),
        "new page unexpectedly has history"
    );
    page.read_with(cx, |page, _| {
        page.fixture_eval("document.getElementById('details').click()");
    });
    wait_for_page(&page, "Details", cx).await?;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.page.can_back && !page.page.can_forward),
        "native navigation did not enable Back"
    );
    page.update(cx, |page, _| page.fixture_history(false));
    wait_for_page(&page, "Fieldnotes", cx).await?;
    anyhow::ensure!(
        page.read_with(cx, |page, _| !page.page.can_back && page.page.can_forward),
        "Back did not enable Forward"
    );
    page.update(cx, |page, _| page.fixture_history(true));
    wait_for_page(&page, "Details", cx).await?;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.page.can_back && !page.page.can_forward),
        "Forward did not restore the history position"
    );
    Ok(())
}
