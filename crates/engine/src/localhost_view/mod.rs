//! Pages this computer serves on localhost, viewed and used from the phone.
//!
//! A dev server an agent started (`http://localhost:3000`) only answers on
//! this computer. Instead of forwarding ports or proxying HTTP, the engine
//! opens the page in a headless Chromium-family browser here, where
//! `localhost` already means this computer (its HMR sockets and all), and
//! streams what it draws: `WatchLocalhostPage` carries JPEG frames from the
//! DevTools screencast, and `LocalhostPageInput` sends taps, scrolls, typing,
//! and navigation back as DevTools input.
//!
//! - One browser per engine, started by the first viewer, with a throwaway
//!   profile and a DevTools connection only this engine holds ([`browser`]).
//! - One tab per watched page, shared by its viewers. The screencast runs
//!   while anyone watches; each frame is acked only after the fastest
//!   viewer's frame gap, so the browser keeps one frame in flight. Viewers
//!   get the newest frame at their own rate, and a frame repeats its JPEG
//!   only when the picture changed.
//! - A tab nobody has watched for [`IDLE_STOP`] closes; the browser exits
//!   with its last tab, and with the engine.
//! - Only http(s) pages on loopback open ([`url_rule`]). The tab's own
//!   top-level navigations are held to the same rule (the browser's request
//!   interception fails them), and windows a page opens are closed, with the
//!   page sent to their address instead when it is on loopback. Subresources
//!   and frames inside a page load as the page asks, like on the computer.

mod browser;
mod cdp;
mod input;
mod url_rule;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use futures::StreamExt;
use futures::stream::BoxStream;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::watch;
use tokio::time::Instant;

pub use browser::BROWSER_ENV;
pub use input::PageInput;
pub use url_rule::loopback_url;

use browser::Transport;
use cdp::Cdp;
use input::{Plan, Viewport};

/// A page nobody has watched for this long closes; the browser exits with
/// its last page.
pub const IDLE_STOP: Duration = Duration::from_secs(60);
/// How long a newly watched or resized page has to paint a screencast frame
/// before a still is taken instead (an idle page doesn't repaint for one).
const STILL_AFTER: Duration = Duration::from_millis(400);
/// How long the browser has to start and answer.
const START_TIMEOUT: Duration = Duration::from_secs(25);
/// What the browser answers while a page's renderer is being swapped.
const SWAPPING: &str = "Not attached to an active page";
/// The most pages open at once.
const MAX_TABS: usize = 8;
/// The most servers listed.
#[cfg(feature = "preview")]
const MAX_SERVERS: usize = 30;

/// One frame of a page, as a viewer gets it.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PageFrame {
    /// Names the page for `LocalhostPageInput` and for watching it again.
    pub view_id: String,
    pub seq: u64,
    /// Base64 JPEG; absent when the picture hasn't changed since this
    /// viewer's last frame (only the page's state did).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jpeg: Option<String>,
    /// The page's visible size in CSS pixels: what tap and scroll
    /// coordinates are measured in.
    pub width: u32,
    pub height: u32,
    pub url: String,
    pub title: String,
    pub can_go_back: bool,
    pub can_go_forward: bool,
    pub loading: bool,
    /// Something the viewer should be told (a blocked navigation, a dialog
    /// the page showed, nothing answering at the address).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
}

/// An item of `WatchLocalhostPage`.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PageEvent {
    Frame(PageFrame),
    /// The page is gone (the browser closed or crashed); the stream ends.
    Ended {
        message: String,
    },
}

/// A server listening on this computer's loopback.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LocalServer {
    pub port: u16,
    pub url: String,
    /// What it looks like it is (`Vite`, `Next.js`, `HTTP server`).
    pub name: String,
    /// The folder it runs in (its name only).
    pub folder: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct WatchRequest {
    pub url: String,
    /// Watch this page again (after a dropped connection) if it is still open.
    pub view_id: Option<String>,
    pub width: f64,
    pub height: f64,
    pub scale: Option<f64>,
    pub quality: Option<u32>,
    pub fps: Option<u32>,
}

/// A page's state, shared by its viewers.
#[derive(Debug, Clone, Default)]
struct PageState {
    seq: u64,
    image_seq: u64,
    jpeg: Option<Arc<str>>,
    width: u32,
    height: u32,
    url: String,
    title: String,
    can_go_back: bool,
    can_go_forward: bool,
    loading: bool,
    notice: Option<String>,
    ended: Option<String>,
}

/// What a viewer is sent for `state`: nothing before the first picture, the
/// JPEG only when it changed since `last_image` (which this updates).
fn viewer_event(state: &PageState, view_id: &str, last_image: &mut u64) -> Option<PageEvent> {
    if let Some(message) = &state.ended {
        return Some(PageEvent::Ended {
            message: message.clone(),
        });
    }
    let jpeg = state.jpeg.as_ref()?;
    let fresh = state.image_seq != *last_image;
    *last_image = state.image_seq;
    Some(PageEvent::Frame(PageFrame {
        view_id: view_id.to_string(),
        seq: state.seq,
        jpeg: fresh.then(|| jpeg.to_string()),
        width: state.width,
        height: state.height,
        url: state.url.clone(),
        title: state.title.clone(),
        can_go_back: state.can_go_back,
        can_go_forward: state.can_go_forward,
        loading: state.loading,
        notice: state.notice.clone(),
    }))
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// View ids are the engine's own (`page-<n>`); nothing else is looked up.
fn check_view_id(id: &str) -> Result<(), String> {
    let ok = id
        .strip_prefix("page-")
        .is_some_and(|n| !n.is_empty() && n.len() <= 20 && n.bytes().all(|b| b.is_ascii_digit()));
    ok.then_some(())
        .ok_or_else(|| format!("not a page id: {id:?}"))
}

pub fn no_browser_message(device: &str) -> String {
    format!(
        "Viewing localhost on your phone needs {} on {device}.",
        browser::BROWSER_NAMES
    )
}

struct Settings {
    viewport: Viewport,
    quality: u32,
}

struct Tab {
    id: String,
    /// The address it was opened at; a viewer asking for it again shares it.
    opened_at: String,
    target_id: String,
    session_id: String,
    cdp: Cdp,
    device: String,
    state: watch::Sender<Arc<PageState>>,
    settings: Mutex<Settings>,
    /// Each viewer's frame rate.
    viewers: Mutex<HashMap<u64, u32>>,
    idle_since: Mutex<Option<Instant>>,
    casting: AtomicBool,
}

impl Tab {
    fn session(&self) -> Option<&str> {
        Some(&self.session_id)
    }

    fn update(&self, change: impl FnOnce(&mut PageState)) {
        self.state.send_modify(|state| {
            let mut next = (**state).clone();
            change(&mut next);
            next.seq += 1;
            *state = Arc::new(next);
        });
    }

    fn ended(&self) -> bool {
        self.state.borrow().ended.is_some()
    }

    fn end(&self, message: String) {
        if !self.ended() {
            self.update(|s| s.ended = Some(message));
        }
    }

    fn publish_image(&self, jpeg: &str, width: Option<u32>, height: Option<u32>) {
        let viewport = lock(&self.settings).viewport;
        self.update(|s| {
            s.image_seq += 1;
            s.jpeg = Some(Arc::from(jpeg));
            s.width = width.unwrap_or(viewport.width);
            s.height = height.unwrap_or(viewport.height);
        });
    }

    /// The fastest viewer's frame rate.
    fn fps(&self) -> u32 {
        lock(&self.viewers)
            .values()
            .copied()
            .max()
            .unwrap_or_else(|| input::fps(None))
    }

    /// A command to the page. While a navigation swaps the page's renderer
    /// the session briefly has no page to talk to; those calls are retried.
    async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let mut attempt = 0;
        loop {
            match self.cdp.call(self.session(), method, params.clone()).await {
                Err(e) if attempt < 10 && e.contains(SWAPPING) => {
                    attempt += 1;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                result => return result,
            }
        }
    }

    async fn start_cast(&self) -> Result<(), String> {
        let params = {
            let settings = lock(&self.settings);
            settings.viewport.screencast(settings.quality)
        };
        self.call("Page.startScreencast", params).await.map(|_| ())
    }

    /// If nothing paints soon, a still stands in for the first frame.
    fn still_soon(self: &Arc<Self>) {
        let tab = Arc::downgrade(self);
        let before = self.state.borrow().image_seq;
        tokio::spawn(async move {
            tokio::time::sleep(STILL_AFTER).await;
            let Some(tab) = tab.upgrade() else { return };
            if tab.state.borrow().image_seq != before || tab.ended() {
                return;
            }
            let quality = lock(&tab.settings).quality;
            if let Ok(shot) = tab
                .call(
                    "Page.captureScreenshot",
                    json!({ "format": "jpeg", "quality": quality }),
                )
                .await
                && let Some(data) = shot["data"].as_str()
                && tab.state.borrow().image_seq == before
            {
                tab.publish_image(data, None, None);
            }
        });
    }

    async fn apply_viewport(self: &Arc<Self>, viewport: Viewport) -> Result<(), String> {
        let changed = {
            let mut settings = lock(&self.settings);
            let changed = settings.viewport != viewport;
            settings.viewport = viewport;
            changed
        };
        if !changed {
            return Ok(());
        }
        self.call(
            "Emulation.setDeviceMetricsOverride",
            viewport.metrics_override(),
        )
        .await?;
        if self.casting.load(Ordering::SeqCst) {
            // A running screencast keeps its size; restart it at the new one.
            let _ = self.call("Page.stopScreencast", json!({})).await;
            self.call("Page.startScreencast", {
                let settings = lock(&self.settings);
                settings.viewport.screencast(settings.quality)
            })
            .await?;
        }
        self.still_soon();
        Ok(())
    }

    async fn refresh_history(&self) {
        let Ok(history) = self.call("Page.getNavigationHistory", json!({})).await else {
            return;
        };
        let entries = history["entries"].as_array().cloned().unwrap_or_default();
        let index = history["currentIndex"].as_u64().unwrap_or(0) as usize;
        let Some(current) = entries.get(index) else {
            return;
        };
        let url = current["url"].as_str().unwrap_or_default().to_string();
        let title = current["title"].as_str().unwrap_or_default().to_string();
        let back = index > 0;
        let forward = index + 1 < entries.len();
        self.update(|s| {
            s.url = url;
            s.title = title;
            s.can_go_back = back;
            s.can_go_forward = forward;
        });
    }

    async fn navigate(&self, url: &str) -> Result<(), String> {
        let reply = self.call("Page.navigate", json!({ "url": url })).await?;
        if let Some(error) = reply["errorText"].as_str()
            && !error.is_empty()
        {
            let notice = navigation_notice(url, error, &self.device);
            self.update(|s| s.notice = Some(notice));
        }
        Ok(())
    }
}

/// What to tell a viewer when the browser couldn't load `url`.
fn navigation_notice(url: &str, error: &str, device: &str) -> String {
    let place = reqwest::Url::parse(url)
        .ok()
        .and_then(|u| {
            Some(match u.port() {
                Some(port) => format!("{}:{port}", u.host_str()?),
                None => u.host_str()?.to_string(),
            })
        })
        .unwrap_or_else(|| url.to_string());
    if error.contains("ERR_CONNECTION_REFUSED") {
        format!("Nothing is running at {place} on {device}.")
    } else {
        format!("{place} didn't load on {device} ({error}).")
    }
}

/// The host of a top-level page load the tab must refuse, if this paused
/// request is one: a document for the tab's own frame, off loopback.
fn refused_navigation(paused: &Value, main_frame: &str) -> Option<String> {
    if paused["resourceType"].as_str() != Some("Document")
        || paused["frameId"].as_str() != Some(main_frame)
    {
        return None;
    }
    let url = paused["request"]["url"].as_str().unwrap_or_default();
    if url_rule::allowed_navigation(url) {
        return None;
    }
    Some(
        reqwest::Url::parse(url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_string))
            .unwrap_or_else(|| "That page".to_string()),
    )
}

/// One viewer's hold on a tab.
struct ViewerGuard {
    tab: Arc<Tab>,
    viewer: u64,
    inner: Weak<Inner>,
}

impl Drop for ViewerGuard {
    fn drop(&mut self) {
        let empty = {
            let mut viewers = lock(&self.tab.viewers);
            viewers.remove(&self.viewer);
            viewers.is_empty()
        };
        if let Some(inner) = self.inner.upgrade() {
            inner.touch();
        }
        if !empty {
            return;
        }
        *lock(&self.tab.idle_since) = Some(Instant::now());
        if self.tab.casting.swap(false, Ordering::SeqCst)
            && let Ok(handle) = tokio::runtime::Handle::try_current()
        {
            let tab = self.tab.clone();
            handle.spawn(async move {
                if lock(&tab.viewers).is_empty() {
                    let _ = tab.call("Page.stopScreencast", json!({})).await;
                }
            });
        }
    }
}

struct Running {
    cdp: Cdp,
    child: tokio::process::Child,
    /// Removed after the browser exits (field order: the child is killed first).
    _profile: tempfile::TempDir,
    user_agent: Option<String>,
}

impl Running {
    fn alive(&mut self) -> bool {
        !self.cdp.is_closed() && matches!(self.child.try_wait(), Ok(None))
    }

    async fn stop(mut self) {
        let _ = tokio::time::timeout(
            Duration::from_secs(2),
            self.cdp.call(None, "Browser.close", json!({})),
        )
        .await;
        if tokio::time::timeout(Duration::from_secs(3), self.child.wait())
            .await
            .is_err()
        {
            let _ = self.child.kill().await;
        }
    }
}

type FindBrowser = Box<dyn Fn() -> Option<PathBuf> + Send + Sync>;

struct Inner {
    device: String,
    idle_stop: Duration,
    find_browser: FindBrowser,
    transport: Transport,
    browser: tokio::sync::Mutex<Option<Running>>,
    tabs: Mutex<HashMap<String, Arc<Tab>>>,
    next: AtomicU64,
    last_used: Mutex<Instant>,
}

impl Inner {
    fn touch(&self) {
        *lock(&self.last_used) = Instant::now();
    }

    fn tab(&self, view_id: &str) -> Option<Arc<Tab>> {
        lock(&self.tabs)
            .get(view_id)
            .filter(|t| !t.ended())
            .cloned()
    }

    fn remove_tab(&self, tab: &Arc<Tab>) {
        let mut tabs = lock(&self.tabs);
        if tabs.get(&tab.id).is_some_and(|t| Arc::ptr_eq(t, tab)) {
            tabs.remove(&tab.id);
        }
    }
}

#[derive(Clone)]
pub struct LocalhostView {
    inner: Arc<Inner>,
}

impl LocalhostView {
    /// `device` names this computer in what viewers are told.
    pub fn new(device: String) -> Self {
        Self::build(
            device,
            IDLE_STOP,
            Box::new(browser::find),
            Transport::preferred(),
        )
    }

    fn build(
        device: String,
        idle_stop: Duration,
        find_browser: FindBrowser,
        transport: Transport,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                device,
                idle_stop,
                find_browser,
                transport,
                browser: tokio::sync::Mutex::new(None),
                tabs: Mutex::new(HashMap::new()),
                next: AtomicU64::new(1),
                last_used: Mutex::new(Instant::now()),
            }),
        }
    }

    /// The running browser's connection, started if it isn't.
    async fn browser(&self) -> Result<(Cdp, Option<String>), String> {
        let mut browser = self.inner.browser.lock().await;
        if let Some(running) = browser.as_mut()
            && running.alive()
        {
            return Ok((running.cdp.clone(), running.user_agent.clone()));
        }
        if let Some(stale) = browser.take() {
            stale.stop().await;
        }
        let executable =
            (self.inner.find_browser)().ok_or_else(|| no_browser_message(&self.inner.device))?;
        let launched = browser::launch(&executable, self.inner.transport).await?;
        let cdp = Cdp::start(launched.tx, launched.rx);
        let mut running = Running {
            cdp: cdp.clone(),
            child: launched.child,
            _profile: launched.profile,
            user_agent: None,
        };
        let version = match tokio::time::timeout(
            START_TIMEOUT,
            cdp.call(None, "Browser.getVersion", json!({})),
        )
        .await
        {
            Ok(Ok(version)) => version,
            Ok(Err(e)) => {
                running.stop().await;
                return Err(format!(
                    "The browser on {} didn't start: {e}",
                    self.inner.device
                ));
            }
            Err(_) => {
                running.stop().await;
                return Err(format!(
                    "The browser on {} didn't start.",
                    self.inner.device
                ));
            }
        };
        // Pages see an ordinary browser, not a headless one.
        running.user_agent = version["userAgent"]
            .as_str()
            .map(|ua| ua.replace("HeadlessChrome", "Chrome"));
        // Windows a page opens are closed (their tab follows them instead).
        let mut created = cdp.events("");
        let closer = cdp.clone();
        tokio::spawn(async move {
            while let Some(event) = created.recv().await {
                let info = &event.params["targetInfo"];
                if event.method == "Target.targetCreated"
                    && info["type"] == "page"
                    && info["openerId"].as_str().is_some()
                    && let Some(id) = info["targetId"].as_str()
                {
                    let _ = closer
                        .call(None, "Target.closeTarget", json!({ "targetId": id }))
                        .await;
                }
            }
        });
        let _ = cdp
            .call(
                None,
                "Target.setDiscoverTargets",
                json!({ "discover": true }),
            )
            .await;
        let user_agent = running.user_agent.clone();
        *browser = Some(running);
        tokio::spawn(idle_watchdog(Arc::downgrade(&self.inner)));
        Ok((cdp, user_agent))
    }

    async fn open_tab(
        &self,
        url: &str,
        viewport: Viewport,
        quality: u32,
    ) -> Result<Arc<Tab>, String> {
        if lock(&self.inner.tabs).len() >= MAX_TABS {
            return Err("Too many pages are open; close one first.".into());
        }
        let (cdp, user_agent) = self.browser().await?;
        let created = cdp
            .call(None, "Target.createTarget", json!({ "url": "about:blank" }))
            .await?;
        let target_id = created["targetId"]
            .as_str()
            .ok_or("the browser didn't open a page")?
            .to_string();
        let opened = self
            .attach_tab(&cdp, &target_id, user_agent, url, viewport, quality)
            .await;
        if opened.is_err() {
            let _ = cdp
                .call(None, "Target.closeTarget", json!({ "targetId": target_id }))
                .await;
        }
        opened
    }

    async fn attach_tab(
        &self,
        cdp: &Cdp,
        target_id: &str,
        user_agent: Option<String>,
        url: &str,
        viewport: Viewport,
        quality: u32,
    ) -> Result<Arc<Tab>, String> {
        let attached = cdp
            .call(
                None,
                "Target.attachToTarget",
                json!({ "targetId": target_id, "flatten": true }),
            )
            .await?;
        let session_id = attached["sessionId"]
            .as_str()
            .ok_or("the browser didn't attach to the page")?
            .to_string();
        let events = cdp.events(&session_id);
        let id = format!("page-{}", self.inner.next.fetch_add(1, Ordering::Relaxed));
        let (state, _) = watch::channel(Arc::new(PageState {
            url: url.to_string(),
            width: viewport.width,
            height: viewport.height,
            loading: true,
            ..PageState::default()
        }));
        let tab = Arc::new(Tab {
            id: id.clone(),
            opened_at: url.to_string(),
            target_id: target_id.to_string(),
            session_id,
            cdp: cdp.clone(),
            device: self.inner.device.clone(),
            state,
            settings: Mutex::new(Settings { viewport, quality }),
            viewers: Mutex::new(HashMap::new()),
            idle_since: Mutex::new(Some(Instant::now())),
            casting: AtomicBool::new(false),
        });
        tokio::spawn(tab_events(tab.clone(), events, Arc::downgrade(&self.inner)));
        let setup = async {
            tab.call("Page.enable", json!({})).await?;
            // Top-level page loads pause here so off-loopback ones can be refused.
            tab.call(
                "Fetch.enable",
                json!({ "patterns": [{ "urlPattern": "*", "resourceType": "Document", "requestStage": "Request" }] }),
            )
            .await?;
            tab.call(
                "Emulation.setDeviceMetricsOverride",
                viewport.metrics_override(),
            )
            .await?;
            tab.call(
                "Emulation.setTouchEmulationEnabled",
                json!({ "enabled": true, "maxTouchPoints": 5 }),
            )
            .await?;
            if let Some(user_agent) = user_agent {
                let _ = tab
                    .call(
                        "Emulation.setUserAgentOverride",
                        json!({ "userAgent": user_agent }),
                    )
                    .await;
            }
            Ok::<(), String>(())
        };
        if let Err(e) = setup.await {
            tab.end(e.clone());
            cdp.forget(&tab.session_id);
            return Err(e);
        }
        lock(&self.inner.tabs).insert(id, tab.clone());
        // Not awaited: a slow page must not hold up its first frames.
        let navigating = tab.clone();
        let url = url.to_string();
        tokio::spawn(async move {
            let _ = navigating.navigate(&url).await;
        });
        Ok(tab)
    }

    /// Watch a page: open `url` (or rejoin `view_id`) and stream its frames.
    pub async fn watch(
        &self,
        request: WatchRequest,
    ) -> Result<BoxStream<'static, PageEvent>, String> {
        let viewport = Viewport::clamped(request.width, request.height, request.scale)?;
        let quality = input::quality(request.quality);
        let fps = input::fps(request.fps);
        self.inner.touch();
        let rejoin = match &request.view_id {
            Some(id) => {
                check_view_id(id)?;
                self.inner.tab(id)
            }
            None => None,
        };
        let tab = match rejoin {
            Some(tab) => tab,
            None => {
                let url = loopback_url(&request.url)?.to_string();
                let shared = lock(&self.inner.tabs)
                    .values()
                    .find(|t| t.opened_at == url && !t.ended())
                    .cloned();
                match shared {
                    Some(tab) => tab,
                    None => self.open_tab(&url, viewport, quality).await?,
                }
            }
        };
        let viewer = self.inner.next.fetch_add(1, Ordering::Relaxed);
        lock(&tab.viewers).insert(viewer, fps);
        *lock(&tab.idle_since) = None;
        let guard = ViewerGuard {
            tab: tab.clone(),
            viewer,
            inner: Arc::downgrade(&self.inner),
        };
        lock(&tab.settings).quality = quality;
        tab.apply_viewport(viewport).await?;
        if !tab.casting.swap(true, Ordering::SeqCst) {
            if let Err(e) = tab.start_cast().await {
                tab.casting.store(false, Ordering::SeqCst);
                return Err(e);
            }
            tab.still_soon();
        }
        Ok(viewer_events(
            tab.state.subscribe(),
            tab.id.clone(),
            fps,
            guard,
        ))
    }

    /// Carry out a viewer's input on a page it watches.
    pub async fn input(&self, view_id: &str, input: PageInput) -> Result<(), String> {
        check_view_id(view_id)?;
        let tab = self
            .inner
            .tab(view_id)
            .ok_or("That page has closed. Open it again.")?;
        self.inner.touch();
        let viewport = lock(&tab.settings).viewport;
        match input::plan(&input, &viewport)? {
            Plan::Send(commands) => {
                for command in commands {
                    tab.call(command.method, command.params).await?;
                }
            }
            Plan::Navigate(url) => {
                tab.update(|s| s.notice = None);
                tab.navigate(&url).await?;
            }
            Plan::History(delta) => {
                let history = tab.call("Page.getNavigationHistory", json!({})).await?;
                if let Some(entry) = input::history_target(&history, delta)? {
                    tab.call("Page.navigateToHistoryEntry", json!({ "entryId": entry }))
                        .await?;
                }
            }
            Plan::Resize(viewport) => tab.apply_viewport(viewport).await?,
        }
        Ok(())
    }

    /// Servers listening on this computer's loopback that answer HTTP.
    #[cfg(feature = "preview")]
    pub async fn servers(&self) -> Vec<LocalServer> {
        let listeners = tokio::task::spawn_blocking(harness_preview::discovery::listeners)
            .await
            .unwrap_or_default();
        let own = std::process::id();
        let mut seen = std::collections::HashSet::new();
        let candidates: Vec<_> = listeners
            .into_iter()
            .filter(|l| l.pid != own)
            .filter(|l| l.address.ip().is_loopback() || l.address.ip().is_unspecified())
            .filter(|l| seen.insert(l.address.port()))
            .collect();
        let probes = candidates.into_iter().map(|l| async move {
            let probe = std::net::SocketAddr::new(
                if l.address.is_ipv6() && !l.address.ip().is_unspecified() {
                    std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)
                } else {
                    std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
                },
                l.address.port(),
            );
            harness_preview::discovery::is_http(probe)
                .await
                .then(|| LocalServer {
                    port: l.address.port(),
                    url: format!("http://localhost:{}", l.address.port()),
                    name: harness_preview::discovery::framework(&l.args).0.to_string(),
                    folder: l
                        .cwd
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .filter(|n| !n.is_empty()),
                })
        });
        let mut servers: Vec<LocalServer> = futures::future::join_all(probes)
            .await
            .into_iter()
            .flatten()
            .collect();
        servers.sort_by_key(|s| s.port);
        servers.truncate(MAX_SERVERS);
        servers
    }

    /// Servers listening on this computer's loopback that answer HTTP.
    #[cfg(not(feature = "preview"))]
    pub async fn servers(&self) -> Vec<LocalServer> {
        Vec::new()
    }

    /// Close every page and the browser.
    pub async fn shutdown(&self) {
        let tabs: Vec<_> = lock(&self.inner.tabs).drain().map(|(_, t)| t).collect();
        for tab in tabs {
            tab.end(format!("Harness on {} stopped.", self.inner.device));
            tab.cdp.forget(&tab.session_id);
        }
        let running = self.inner.browser.lock().await.take();
        if let Some(running) = running {
            running.stop().await;
        }
    }

    #[cfg(test)]
    fn tab_count(&self) -> usize {
        lock(&self.inner.tabs).len()
    }
}

/// A viewer's events: the newest state now, then at most `fps` a second,
/// always the newest, ending after the page does.
fn viewer_events(
    rx: watch::Receiver<Arc<PageState>>,
    view_id: String,
    fps: u32,
    guard: ViewerGuard,
) -> BoxStream<'static, PageEvent> {
    let gap = Duration::from_secs(1) / fps.max(1);
    struct Cursor {
        rx: watch::Receiver<Arc<PageState>>,
        view_id: String,
        last_sent: Option<Instant>,
        last_seq: Option<u64>,
        last_image: u64,
        done: bool,
        _guard: ViewerGuard,
    }
    let cursor = Cursor {
        rx,
        view_id,
        last_sent: None,
        last_seq: None,
        last_image: 0,
        done: false,
        _guard: guard,
    };
    futures::stream::unfold(cursor, move |mut c| async move {
        if c.done {
            return None;
        }
        if let Some(last) = c.last_sent {
            tokio::time::sleep_until(last + gap).await;
        }
        loop {
            let state = c.rx.borrow_and_update().clone();
            if c.last_seq != Some(state.seq)
                && let Some(event) = viewer_event(&state, &c.view_id, &mut c.last_image)
            {
                c.last_seq = Some(state.seq);
                c.last_sent = Some(Instant::now());
                c.done = matches!(event, PageEvent::Ended { .. });
                return Some((event, c));
            }
            if c.rx.changed().await.is_err() {
                return None;
            }
        }
    })
    .boxed()
}

/// Follow one tab's DevTools events until its session ends.
async fn tab_events(
    tab: Arc<Tab>,
    mut events: tokio::sync::mpsc::UnboundedReceiver<cdp::Event>,
    inner: Weak<Inner>,
) {
    let main = tab.target_id.clone();
    let is_main = |params: &Value, key: &str| params[key].as_str() == Some(main.as_str());
    while let Some(event) = events.recv().await {
        let params = &event.params;
        match event.method.as_str() {
            "Page.screencastFrame" => {
                let arrived = Instant::now();
                let meta = &params["metadata"];
                let size = |key: &str| {
                    meta[key]
                        .as_f64()
                        .map(|v| v.round() as u32)
                        .filter(|v| *v > 0)
                };
                if let Some(data) = params["data"].as_str() {
                    tab.publish_image(data, size("deviceWidth"), size("deviceHeight"));
                }
                // The browser sends nothing new until this ack: holding it
                // to the fastest viewer's gap keeps one frame in flight.
                if let Some(frame) = params["sessionId"].as_i64() {
                    let tab = tab.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(input::ack_delay(arrived.elapsed(), tab.fps())).await;
                        let _ = tab
                            .call("Page.screencastFrameAck", json!({ "sessionId": frame }))
                            .await;
                    });
                }
            }
            "Page.frameStartedLoading" if is_main(params, "frameId") => {
                tab.update(|s| s.loading = true);
            }
            "Page.frameStoppedLoading" if is_main(params, "frameId") => {
                tab.update(|s| s.loading = false);
                tab.refresh_history().await;
            }
            "Page.frameNavigated" if params["frame"]["parentId"].is_null() => {
                let url = params["frame"]["url"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string();
                let web = url.starts_with("http:") || url.starts_with("https:");
                tab.update(|s| {
                    if web {
                        s.notice = None;
                    }
                    s.url = url;
                });
                tab.refresh_history().await;
            }
            "Page.navigatedWithinDocument" if is_main(params, "frameId") => {
                tab.refresh_history().await;
            }
            "Page.loadEventFired" | "Page.domContentEventFired" => {
                tab.refresh_history().await;
            }
            "Fetch.requestPaused" => {
                let request = params["requestId"].clone();
                match refused_navigation(params, &main) {
                    Some(host) => {
                        tab.update(|s| {
                            s.notice = Some(format!(
                                "{host} isn't on {}, so it doesn't open here.",
                                tab.device
                            ));
                        });
                        let _ = tab
                            .call(
                                "Fetch.failRequest",
                                json!({ "requestId": request, "errorReason": "BlockedByClient" }),
                            )
                            .await;
                    }
                    None => {
                        let _ = tab
                            .call("Fetch.continueRequest", json!({ "requestId": request }))
                            .await;
                    }
                }
            }
            "Page.javascriptDialogOpening" => {
                // Nobody on this computer can answer it; accept so the page goes on.
                let message: String = params["message"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(200)
                    .collect();
                if !message.is_empty() {
                    tab.update(|s| s.notice = Some(format!("The page said: {message}")));
                }
                let _ = tab
                    .call("Page.handleJavaScriptDialog", json!({ "accept": true }))
                    .await;
            }
            "Page.windowOpen" => {
                let url = params["url"].as_str().unwrap_or_default().to_string();
                if url_rule::allowed_navigation(&url) && url.starts_with("http") {
                    let _ = tab.navigate(&url).await;
                } else {
                    tab.update(|s| {
                        s.notice = Some(format!(
                            "The page tried to open a window that isn't on {}.",
                            tab.device
                        ));
                    });
                }
            }
            "Inspector.targetCrashed" => {
                tab.end(format!("The page crashed on {}.", tab.device));
                break;
            }
            "Inspector.detached" => break,
            _ => {}
        }
    }
    tab.end(format!("The browser on {} closed the page.", tab.device));
    if let Some(inner) = inner.upgrade() {
        inner.remove_tab(&tab);
    }
}

/// Runs beside the browser: closes pages nobody watches, and the browser
/// once no page is left.
async fn idle_watchdog(inner: Weak<Inner>) {
    loop {
        let Some(strong) = inner.upgrade() else {
            return;
        };
        let check =
            (strong.idle_stop / 4).clamp(Duration::from_millis(50), Duration::from_secs(15));
        drop(strong);
        tokio::time::sleep(check).await;
        let Some(inner) = inner.upgrade() else { return };
        let idle: Vec<Arc<Tab>> = lock(&inner.tabs)
            .values()
            .filter(|t| {
                lock(&t.viewers).is_empty()
                    && lock(&t.idle_since).is_some_and(|since| since.elapsed() >= inner.idle_stop)
            })
            .cloned()
            .collect();
        for tab in idle {
            inner.remove_tab(&tab);
            tab.end("Nobody was watching, so the page closed.".into());
            tab.cdp.forget(&tab.session_id);
            let _ = tab
                .cdp
                .call(
                    None,
                    "Target.closeTarget",
                    json!({ "targetId": tab.target_id }),
                )
                .await;
        }
        let mut browser = inner.browser.lock().await;
        if browser.is_none() {
            return;
        }
        let quiet =
            lock(&inner.tabs).is_empty() && lock(&inner.last_used).elapsed() >= inner.idle_stop;
        if quiet {
            if let Some(running) = browser.take() {
                tracing::debug!("localhost view: nobody watching; closing the browser");
                running.stop().await;
            }
            return;
        }
    }
}

#[cfg(test)]
mod tests;
