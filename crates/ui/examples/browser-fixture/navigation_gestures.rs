use gpui::{AsyncApp, Entity, WindowHandle};
use harness_proto::ToolViewKind;
use harness_ui::{browser::BrowserSurface, shell::Shell};

async fn wait_for_page(
    page: &Entity<BrowserSurface>,
    title: &str,
    back: bool,
    forward: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(25);
    loop {
        let state = page.read_with(cx, |page, _| page.page.clone());
        anyhow::ensure!(
            state.error.is_none(),
            "navigation failed: {:?}",
            state.error
        );
        if state.title == title
            && !state.loading
            && state.can_back == back
            && state.can_forward == forward
            && page.read_with(cx, |page, _| page.fixture_native_visible())
        {
            return Ok(());
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "expected {title} with history ({back}, {forward}), got {state:?}"
        );
        super::pause(cx, 50).await;
    }
}

async fn history_boundary_is_inert(
    page: &Entity<BrowserSurface>,
    forward: bool,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let before = page.read_with(cx, |page, _| page.page.clone());
    page.update(cx, |page, _| page.fixture_history(forward));
    super::pause(cx, 150).await;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.page == before),
        "history navigation changed the page at a history boundary"
    );
    Ok(())
}

pub async fn exercise(
    window: WindowHandle<Shell>,
    origin: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let (id, page) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(origin.into()), window, cx)
    })?;
    wait_for_page(&page, "Fieldnotes", false, false, cx).await?;
    // Read the real WebKit setting; do not duplicate the builder's policy.
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_navigation_gestures_enabled()),
        "native browser back/forward swipe gestures are disabled"
    );
    history_boundary_is_inert(&page, false, cx).await?;
    history_boundary_is_inert(&page, true, cx).await?;

    // Real DOM navigation, both history boundaries, and reload at a nonempty
    // history position. Reload must neither discard history nor add an entry.
    page.read_with(cx, |page, _| {
        page.fixture_eval("document.getElementById('details').click()");
    });
    wait_for_page(&page, "Details", true, false, cx).await?;
    history_boundary_is_inert(&page, true, cx).await?;
    page.read_with(cx, |page, _| page.fixture_eval("location.reload()"));
    super::pause(cx, 200).await;
    wait_for_page(&page, "Details", true, false, cx).await?;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_navigation_gestures_enabled()),
        "reload disabled native gestures"
    );
    page.update(cx, |page, _| page.fixture_history(false));
    wait_for_page(&page, "Fieldnotes", false, true, cx).await?;
    history_boundary_is_inert(&page, false, cx).await?;
    page.update(cx, |page, _| page.fixture_history(true));
    wait_for_page(&page, "Details", true, false, cx).await?;

    // Same-document SPA entries have no network response to drive readiness.
    // popstate updates the title so the test observes the actual history step.
    page.read_with(cx, |page, _| {
        page.fixture_eval(
            "addEventListener('popstate', () => document.title = location.hash || 'Details'); \
             history.pushState({}, '', '#first'); document.title = '#first'; \
             history.pushState({}, '', '#second'); document.title = '#second';",
        );
    });
    wait_for_page(&page, "#second", true, false, cx).await?;
    page.update(cx, |page, _| page.fixture_history(false));
    wait_for_page(&page, "#first", true, true, cx).await?;
    page.update(cx, |page, _| page.fixture_history(false));
    wait_for_page(&page, "Details", true, true, cx).await?;
    page.update(cx, |page, _| page.fixture_history(true));
    wait_for_page(&page, "#first", true, true, cx).await?;

    // A fresh navigation after Back must discard the old forward branch.
    window.update(cx, |_, window, cx| {
        page.update(cx, |page, cx| {
            page.navigate(&format!("{origin}/new-branch"), window, cx);
        });
    })?;
    wait_for_page(&page, "Fieldnotes", true, false, cx).await?;
    history_boundary_is_inert(&page, true, cx).await?;

    // New tabs do not inherit another tab's history, and hide/restore/close
    // cannot change the retained tab's history or native gesture preference.
    let (other_id, other) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(origin.into()), window, cx)
    })?;
    wait_for_page(&other, "Fieldnotes", false, false, cx).await?;
    anyhow::ensure!(
        !page.read_with(cx, |page, _| page.fixture_native_visible()),
        "background tab retained native content"
    );
    anyhow::ensure!(
        other.read_with(cx, |page, _| page.fixture_navigation_gestures_enabled()),
        "new tab did not enable native gestures"
    );
    history_boundary_is_inert(&other, false, cx).await?;
    window.update(cx, |shell, _, cx| shell.fixture_select_browser(id, cx))?;
    wait_for_page(&page, "Fieldnotes", true, false, cx).await?;
    anyhow::ensure!(
        page.read_with(cx, |page, _| page.fixture_navigation_gestures_enabled()),
        "restored tab disabled native gestures"
    );
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(other_id, window, cx);
    })?;
    anyhow::ensure!(
        !other.read_with(cx, |page, _| page.fixture_native_visible()),
        "closed tab retained native content"
    );
    page.update(cx, |page, _| page.fixture_history(false));
    wait_for_page(&page, "#first", true, true, cx).await?;

    // Construct the real saved-view hosts without loading any saved file or
    // consulting a person's views. Both kinds must leave gestures disabled.
    for kind in [ToolViewKind::Html, ToolViewKind::McpApp] {
        let enabled = window.update(cx, |_, window, cx| {
            page.read(cx)
                .fixture_saved_view_navigation_gestures(kind, window)
        })??;
        anyhow::ensure!(!enabled, "isolated saved view enabled history gestures");
    }

    // Replacing a web host with an isolated document must not carry over the
    // web tab's gesture preference or back/forward list.
    window.update(cx, |_, window, cx| {
        page.update(cx, |page, cx| {
            page.fixture_document("<!doctype html><p>Synthetic document</p>", window, cx)
                .map_err(anyhow::Error::msg)
        })
    })??;
    wait_for_page(&page, "fixture.html", false, false, cx).await?;
    anyhow::ensure!(
        !page.read_with(cx, |page, _| page.fixture_navigation_gestures_enabled()),
        "isolated document inherited web navigation gestures"
    );
    history_boundary_is_inert(&page, false, cx).await?;
    history_boundary_is_inert(&page, true, cx).await?;
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(id, window, cx);
    })?;
    anyhow::ensure!(
        !page.read_with(cx, |page, _| page.fixture_native_visible()),
        "closed document retained native content"
    );
    Ok(())
}
