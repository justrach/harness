//! Saved tool views (graff ADR 0107 / 0103) in the browser pane. A view is a
//! page a tool saved on this device; the pane serves it on its own scheme,
//! read only from graff's fixed directories, under graff's CSP. No native
//! handles here: the platform host wires [`read_view`] into its scheme
//! handler and [`allowed_view_navigation`] into its navigation policy.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use harness_proto::{ToolView, ToolViewKind};
use std::path::{Path, PathBuf};

/// `graff-view://html/<id>` or `graff-view://mcp-app/<id>`.
pub const VIEW_SCHEME: &str = "graff-view";

/// A rendered page gets graff's ADR 0107 policy: inline script and style
/// only, `data:`/`blob:` media, no network, no frames, and `sandbox` for an
/// opaque origin with no forms or popups.
pub const VIEW_CSP: &str = "default-src 'none'; script-src 'unsafe-inline'; \
    style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; \
    font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; \
    sandbox allow-scripts";

/// An MCP App host page (ADR 0103) runs the app in frames it builds itself: a
/// `data:` proxy that holds a `srcdoc` app. Those documents inherit this
/// policy, so it adds `data:` frames and nothing else — still no network.
pub const MCP_APP_CSP: &str = "default-src 'none'; script-src 'unsafe-inline'; \
    style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; \
    font-src data:; frame-src data:; child-src data:; connect-src 'none'; \
    form-action 'none'; base-uri 'none'; sandbox allow-scripts";

pub fn view_csp(kind: ToolViewKind) -> &'static str {
    match kind {
        ToolViewKind::Html => VIEW_CSP,
        ToolViewKind::McpApp => MCP_APP_CSP,
    }
}

/// Largest view file the pane will serve.
pub const VIEW_MAX_BYTES: u64 = 16 * 1024 * 1024;

fn host(kind: ToolViewKind) -> &'static str {
    match kind {
        ToolViewKind::Html => "html",
        ToolViewKind::McpApp => "mcp-app",
    }
}

pub fn view_url(view: &ToolView) -> String {
    format!("{VIEW_SCHEME}://{}/{}", host(view.kind), view.id)
}

/// The view a `graff-view://<kind>/<id>` URL names. Anything else — another
/// scheme, an unknown kind, more path, a query, or an id that isn't 32
/// lowercase hex — names nothing.
pub fn view_from_url(address: &str) -> Option<ToolView> {
    let url = url::Url::parse(address).ok()?;
    if url.scheme() != VIEW_SCHEME
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.port().is_some()
    {
        return None;
    }
    let kind = match url.host_str()? {
        "html" => ToolViewKind::Html,
        "mcp-app" => ToolViewKind::McpApp,
        _ => return None,
    };
    ToolView::new(kind, url.path().strip_prefix('/')?)
}

/// A view page may load its own main frame and inline frames; an MCP App
/// host page also its `data:` proxy frame. Nothing else, and never the web.
pub fn allowed_view_navigation(kind: ToolViewKind, address: &str, main_frame: bool) -> bool {
    if main_frame {
        view_from_url(address).is_some_and(|view| view.kind == kind)
    } else {
        matches!(address, "about:srcdoc" | "about:blank")
            || (kind == ToolViewKind::McpApp && address.starts_with("data:text/html"))
    }
}

/// Where graff saves a view on this device. Built from kind + id alone, never
/// from a path an agent reported.
pub fn view_file(home: &Path, view: &ToolView) -> PathBuf {
    let dir = match view.kind {
        ToolViewKind::Html => "views",
        ToolViewKind::McpApp => "mcp-apps",
    };
    home.join(".graff").join(dir).join(format!("{}.html", view.id))
}

#[derive(Debug, PartialEq, Eq)]
pub enum ViewReadError {
    /// Not a view URL, or the file is a symlink or not a regular file.
    Invalid,
    NotFound,
    TooLarge,
}

/// Read the page `address` names from the fixed graff directories under
/// `home`. The file itself must be a regular file, not a symlink.
#[cfg(target_os = "macos")]
pub fn read_view(home: &Path, address: &str) -> Result<Vec<u8>, ViewReadError> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let view = view_from_url(address).ok_or(ViewReadError::Invalid)?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        // A FIFO planted under the name must not block the open.
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(view_file(home, &view))
        .map_err(|error| match error.kind() {
            std::io::ErrorKind::NotFound => ViewReadError::NotFound,
            _ => ViewReadError::Invalid,
        })?;
    let meta = file.metadata().map_err(|_| ViewReadError::Invalid)?;
    if !meta.is_file() {
        return Err(ViewReadError::Invalid);
    }
    if meta.len() > VIEW_MAX_BYTES {
        return Err(ViewReadError::TooLarge);
    }
    let mut body = Vec::with_capacity(meta.len() as usize);
    file.take(VIEW_MAX_BYTES + 1)
        .read_to_end(&mut body)
        .map_err(|_| ViewReadError::Invalid)?;
    if body.len() as u64 > VIEW_MAX_BYTES {
        return Err(ViewReadError::TooLarge);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn view_urls_name_only_well_formed_saved_views() {
        let html = ToolView::new(ToolViewKind::Html, ID).unwrap();
        let app = ToolView::new(ToolViewKind::McpApp, ID).unwrap();
        assert_eq!(view_url(&html), format!("graff-view://html/{ID}"));
        assert_eq!(view_from_url(&view_url(&html)), Some(html.clone()));
        assert_eq!(view_from_url(&view_url(&app)), Some(app.clone()));
        for bad in [
            format!("https://html/{ID}"),
            format!("graff-view://pdf/{ID}"),
            format!("graff-view://html/{ID}/x"),
            format!("graff-view://html/{ID}?a=1"),
            format!("graff-view://html/{ID}#top"),
            format!("graff-view://html:80/{ID}"),
            format!("graff-view://html/{}", ID.to_uppercase()),
            "graff-view://html/..%2F..%2Fetc%2Fpasswd".into(),
            "graff-view://html/".into(),
        ] {
            assert_eq!(view_from_url(&bad), None, "{bad}");
        }
        use ToolViewKind::{Html, McpApp};
        assert!(allowed_view_navigation(Html, &view_url(&html), true));
        assert!(!allowed_view_navigation(Html, &view_url(&app), true), "a tab keeps its kind");
        assert!(!allowed_view_navigation(Html, "https://example.com/", true));
        assert!(!allowed_view_navigation(Html, "about:srcdoc", true));
        assert!(allowed_view_navigation(Html, "about:srcdoc", false));
        assert!(!allowed_view_navigation(Html, "https://example.com/", false));
        // Only an MCP App host page may build its data: proxy frame.
        assert!(allowed_view_navigation(McpApp, "data:text/html;base64,PHA+", false));
        assert!(!allowed_view_navigation(Html, "data:text/html;base64,PHA+", false));
        assert!(!allowed_view_navigation(McpApp, "https://example.com/", false));
        assert!(!view_csp(Html).contains("frame-src"));
        assert!(view_csp(McpApp).contains("frame-src data:;"));
        for kind in [Html, McpApp] {
            assert!(view_csp(kind).contains("connect-src 'none'") && view_csp(kind).ends_with("sandbox allow-scripts"));
        }
        let home = Path::new("/h");
        assert_eq!(view_file(home, &html), home.join(format!(".graff/views/{ID}.html")));
        assert_eq!(view_file(home, &app), home.join(format!(".graff/mcp-apps/{ID}.html")));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn views_are_read_only_from_regular_files_in_the_graff_dirs() {
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join(".graff/views");
        std::fs::create_dir_all(&dir).unwrap();
        let url = view_url(&ToolView::new(ToolViewKind::Html, ID).unwrap());
        assert_eq!(read_view(home.path(), &url), Err(ViewReadError::NotFound));
        std::fs::write(dir.join(format!("{ID}.html")), b"<p>hi</p>").unwrap();
        assert_eq!(read_view(home.path(), &url).unwrap(), b"<p>hi</p>");
        // A symlink planted in the views dir is refused, even to a real page.
        let other = "fedcba9876543210fedcba9876543210";
        std::os::unix::fs::symlink(dir.join(format!("{ID}.html")), dir.join(format!("{other}.html")))
            .unwrap();
        let linked = view_url(&ToolView::new(ToolViewKind::Html, other).unwrap());
        assert_eq!(read_view(home.path(), &linked), Err(ViewReadError::Invalid));
        assert_eq!(read_view(home.path(), "https://example.com/"), Err(ViewReadError::Invalid));
    }
}
