//! AppKit boundary for the browser. Wry owns the native child and its UI
//! delegate; our navigation delegate supplies browser policy and state. All
//! callbacks enqueue events, never re-enter GPUI. No page-to-engine IPC.
mod user_agent;

use super::model::{PageState, Presentation, allowed_navigation};
use super::saved_view::{
    VIEW_CSP, VIEW_SCHEME, ViewReadError, allowed_view_navigation, read_view, view_csp, view_from_url,
};
use harness_proto::ToolViewKind;
use gpui::{Bounds, Pixels, Window};
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, class, define_class, msg_send, sel,
};
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSColor, NSEvent, NSEventMask, NSEventModifierFlags, NSImage,
    NSView, NSWindowOrderingMode,
};
use objc2_foundation::{
    NSArray, NSDictionary, NSError, NSKeyValueChangeKey, NSKeyValueObservingOptions, NSNumber,
    NSObject, NSObjectNSKeyValueObserverRegistration, NSObjectProtocol, NSString, NSURL,
};
use objc2_web_kit::{
    WKFrameInfo, WKMediaCaptureType, WKNavigation, WKNavigationAction, WKNavigationActionPolicy,
    WKNavigationDelegate, WKNavigationResponse, WKNavigationResponsePolicy, WKOpenPanelParameters,
    WKPermissionDecision, WKSecurityOrigin, WKSnapshotConfiguration, WKUIDelegate, WKWebView,
};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use wry::{WebView, WebViewBuilderExtMacos, WebViewExtMacOS};

#[derive(Default)]
struct BrowserStore {
    store: Option<Retained<objc2_web_kit::WKWebsiteDataStore>>,
    preview_hosts: std::collections::BTreeSet<String>,
}
#[derive(Clone, Default)]
pub(super) struct BrowserData(Rc<RefCell<BrowserStore>>);
impl BrowserData {
    fn configuration(
        &self,
        mtm: MainThreadMarker,
    ) -> Retained<objc2_web_kit::WKWebViewConfiguration> {
        let mut data = self.0.borrow_mut();
        if data.store.is_none() {
            // Persistent, so sign-ins survive a restart. WebKit keeps the
            // default store per app (not Safari's); Harness → Clear Browsing
            // Data empties it.
            data.store = Some(unsafe { objc2_web_kit::WKWebsiteDataStore::defaultDataStore(mtm) });
            if let Err(error) =
                configure_preview_proxy(data.store.as_ref().unwrap(), &data.preview_hosts)
            {
                tracing::warn!(%error, "preview hostname proxy unavailable");
            }
        }
        let configuration = unsafe { objc2_web_kit::WKWebViewConfiguration::new(mtm) };
        unsafe {
            configuration.setWebsiteDataStore(data.store.as_ref().unwrap());
            #[cfg(feature = "browser-fixture")]
            if std::env::var_os("HARNESS_BROWSER_INSPECTOR_FIXTURE_ONLY").is_some() {
                configuration.setWebsiteDataStore(
                    &objc2_web_kit::WKWebsiteDataStore::nonPersistentDataStore(mtm),
                );
            }
        }
        user_agent::configure(&configuration);
        configuration
    }
    pub(super) fn register_preview(&self, address: &str) {
        let Ok(url) = url::Url::parse(address) else {
            return;
        };
        let Some(host) = url.host_str() else {
            return;
        };
        if url.scheme() != "http"
            || url.port() != Some(harness_proto::PREVIEW_PROXY_PORT)
            || !host.ends_with(".localhost")
        {
            return;
        }
        let mut data = self.0.borrow_mut();
        if !data.preview_hosts.insert(host.into()) {
            return;
        }
        if let Some(store) = &data.store {
            if let Err(error) = configure_preview_proxy(store, &data.preview_hosts) {
                tracing::warn!(%error, "preview hostname proxy unavailable");
            }
        }
    }
}

/// Remove everything the browser pane has stored — cookies (sign-ins), local
/// storage and caches — from this app's WebKit store. Open pages keep
/// running; their next request goes out signed out.
pub fn clear_browsing_data() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    unsafe {
        let store = objc2_web_kit::WKWebsiteDataStore::defaultDataStore(mtm);
        let types = objc2_web_kit::WKWebsiteDataStore::allWebsiteDataTypes(mtm);
        let since = objc2_foundation::NSDate::distantPast();
        let done = block2::RcBlock::new(|| {});
        store.removeDataOfTypes_modifiedSince_completionHandler(&types, &since, &done);
    }
}

/// Network.framework objects are Objective-C OS objects. Resolve the newer API
/// dynamically so older systems can still open ordinary browser tabs. Match
/// only discovered/opened preview hostnames; other websites retain normal routing.
fn configure_preview_proxy(
    store: &objc2_web_kit::WKWebsiteDataStore,
    hosts: &std::collections::BTreeSet<String>,
) -> Result<(), String> {
    if hosts.is_empty() {
        return Ok(());
    }
    use objc2_foundation::{NSArray, NSObject};
    use std::ffi::{CStr, CString, c_char};
    unsafe {
        let supported: bool = msg_send![store, respondsToSelector: sel!(setProxyConfigurations:)];
        if !supported {
            return Err("Automatic preview hostnames require macOS 14 or later".into());
        }
        static NETWORK: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
        let handle = *NETWORK.get_or_init(|| {
            libc::dlopen(
                c"/System/Library/Frameworks/Network.framework/Network".as_ptr(),
                libc::RTLD_LAZY,
            ) as usize
        });
        let symbol = |name: &CStr| -> Result<*mut std::ffi::c_void, String> {
            let value = libc::dlsym(handle as *mut _, name.as_ptr());
            if handle == 0 || value.is_null() {
                Err("Preview proxy API unavailable".into())
            } else {
                Ok(value)
            }
        };
        let endpoint: unsafe extern "C" fn(*const c_char, *const c_char) -> *mut NSObject =
            std::mem::transmute(symbol(c"nw_endpoint_create_host")?);
        let proxy: unsafe extern "C" fn(*mut NSObject, *mut NSObject) -> *mut NSObject =
            std::mem::transmute(symbol(c"nw_proxy_config_create_http_connect")?);
        let match_domain: unsafe extern "C" fn(*mut NSObject, *const c_char) =
            std::mem::transmute(symbol(c"nw_proxy_config_add_match_domain")?);
        let endpoint = Retained::from_raw(endpoint(c"127.0.0.1".as_ptr(), c"7331".as_ptr()))
            .ok_or("Could not create preview endpoint")?;
        let config = Retained::from_raw(proxy(
            Retained::as_ptr(&endpoint) as *mut _,
            std::ptr::null_mut(),
        ))
        .ok_or("Could not create preview proxy")?;
        for host in hosts {
            let host = CString::new(host.as_str()).map_err(|_| "Invalid preview hostname")?;
            match_domain(Retained::as_ptr(&config) as *mut _, host.as_ptr());
        }
        let proxies = NSArray::arrayWithObject(&*config);
        let _: () = msg_send![store, setProxyConfigurations: &*proxies];
    }
    Ok(())
}

type Sender = tokio::sync::mpsc::Sender<NativeEvent>;
const OBSERVED: [&str; 6] = [
    "URL",
    "title",
    "loading",
    "canGoBack",
    "canGoForward",
    "underPageBackgroundColor",
];

pub(super) enum NativeEvent {
    Changed,
    Finished,
    NewTab(String),
    /// A shortcut pressed while WebKit had the keyboard. `app` marks an app
    /// shortcut (not a browser one like ⌘L or ⌘[): the keyboard goes back to
    /// the app with it.
    Key { key: gpui::Keystroke, app: bool },
    Favicon { page: String, url: String },
}

struct ObserverState {
    tx: Sender,
    pending: Cell<bool>,
    error: RefCell<Option<String>>,
    requested_url: RefCell<Option<String>>,
    /// A saved-view page of this kind: it may load only its own
    /// `graff-view:` frame and the inline frames its kind needs.
    view: Option<ToolViewKind>,
    document: Cell<bool>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "HarnessBrowserObserver"]
    #[ivars = ObserverState]
    struct Observer;
    unsafe impl NSObjectProtocol for Observer {}
    impl Observer {
        #[unsafe(method(observeValueForKeyPath:ofObject:change:context:))]
        fn observe(&self, _key: Option<&NSString>, _object: Option<&AnyObject>, _change: Option<&NSDictionary<NSKeyValueChangeKey, AnyObject>>, _context: *mut std::ffi::c_void) {
            self.changed();
        }
    }
    // Installed only for in-memory previews. Do not permit a file picker or
    // permission prompt to punch through the document's scripts-only boundary.
    unsafe impl WKUIDelegate for Observer {
        #[unsafe(method(webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:))]
        fn upload(&self, _view: &WKWebView, _parameters: &WKOpenPanelParameters,
            _frame: &WKFrameInfo, completion: &block2::Block<dyn Fn(*mut NSArray<NSURL>)>) {
            completion.call((std::ptr::null_mut(),));
        }
        #[unsafe(method(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:))]
        fn media_permission(&self, _view: &WKWebView, _origin: &WKSecurityOrigin,
            _frame: &WKFrameInfo, _kind: WKMediaCaptureType,
            decision: &block2::Block<dyn Fn(WKPermissionDecision)>) {
            decision.call((WKPermissionDecision::Deny,));
        }
    }
    unsafe impl WKNavigationDelegate for Observer {
        #[unsafe(method(webView:decidePolicyForNavigationAction:decisionHandler:))]
        fn policy(&self, _view: &WKWebView, action: &WKNavigationAction, decision: &block2::Block<dyn Fn(WKNavigationActionPolicy)>) {
            let url = unsafe { action.request().URL() }.and_then(|u| u.absoluteString()).map(|u| u.to_string()).unwrap_or_default();
            let main_frame = unsafe { action.targetFrame() }.is_some_and(|frame| unsafe { frame.isMainFrame() });
            let allowed = if self.ivars().document.get() {
                super::model::allowed_document_navigation(&url)
            } else {
                match self.ivars().view { Some(kind) => allowed_view_navigation(kind, &url, main_frame), None => allowed_navigation(&url) }
            };
            if allowed && main_frame {
                *self.ivars().requested_url.borrow_mut() = Some(url.clone());
            }
            decision.call((if allowed { WKNavigationActionPolicy::Allow } else { WKNavigationActionPolicy::Cancel },));
        }
        #[unsafe(method(webView:decidePolicyForNavigationResponse:decisionHandler:))]
        fn response(&self, _view: &WKWebView, response: &WKNavigationResponse, decision: &block2::Block<dyn Fn(WKNavigationResponsePolicy)>) {
            let displayable = unsafe { response.canShowMIMEType() };
            if !displayable { self.fail("This file can’t be previewed here. Open it in your default browser."); }
            decision.call((if displayable { WKNavigationResponsePolicy::Allow } else { WKNavigationResponsePolicy::Cancel },));
        }
        #[unsafe(method(webView:didStartProvisionalNavigation:))]
        fn start(&self, _view: &WKWebView, _navigation: Option<&WKNavigation>) {
            self.ivars().error.borrow_mut().take(); self.changed();
        }
        #[unsafe(method(webView:didCommitNavigation:))]
        fn commit(&self, _view: &WKWebView, _navigation: Option<&WKNavigation>) {
            self.ivars().requested_url.borrow_mut().take(); self.changed();
        }
        #[unsafe(method(webView:didFinishNavigation:))]
        fn finish(&self, _view: &WKWebView, _navigation: Option<&WKNavigation>) {
            self.changed(); let _ = self.ivars().tx.try_send(NativeEvent::Finished);
        }
        #[unsafe(method(webView:didFailProvisionalNavigation:withError:))]
        fn provisional_error(&self, _view: &WKWebView, _navigation: Option<&WKNavigation>, error: &NSError) {
            if error.code() != -999 {
                tracing::warn!(domain = %error.domain(), code = error.code(), "browser provisional navigation failed");
                self.fail("Check the address and make sure your server is running, then try again.");
            }
        }
        #[unsafe(method(webView:didFailNavigation:withError:))]
        fn navigation_error(&self, _view: &WKWebView, _navigation: Option<&WKNavigation>, error: &NSError) {
            if error.code() != -999 {
                tracing::warn!(domain = %error.domain(), code = error.code(), "browser navigation failed");
                self.fail("The connection was interrupted. Try loading this page again.");
            }
        }
        #[unsafe(method(webViewWebContentProcessDidTerminate:))]
        fn terminated(&self, _view: &WKWebView) {
            self.fail("The page stopped responding. Reload to continue.");
        }
    }
);

impl Observer {
    fn new(
        tx: Sender,
        view: Option<ToolViewKind>,
        document: bool,
        mtm: MainThreadMarker,
    ) -> Retained<Self> {
        let object = mtm.alloc().set_ivars(ObserverState {
            tx,
            pending: Cell::new(false),
            error: RefCell::new(None),
            requested_url: RefCell::new(None),
            view,
            document: Cell::new(document),
        });
        unsafe { msg_send![super(object), init] }
    }
    fn changed(&self) {
        if !self.ivars().pending.replace(true) {
            if self.ivars().tx.try_send(NativeEvent::Changed).is_err() {
                self.ivars().pending.set(false);
            }
        }
    }
    fn fail(&self, message: &str) {
        *self.ivars().error.borrow_mut() = Some(message.into());
        self.changed();
    }
}

struct ClipState {
    dragging: Cell<bool>,
    region: Cell<objc2_foundation::NSRect>,
    resize_inset: Cell<f64>,
    page: Cell<PageClip>,
}

/// The page sits below a toolbar, so only its lower corners belong to the
/// rounded card. Keep these corners anchored to the full page when GPUI clips
/// part of it for a popup, sidebar, or split-view transition.
#[derive(Clone, Copy, PartialEq)]
struct PageClip {
    region: objc2_foundation::NSRect,
    radius: f64,
    bottom_at_max_y: bool,
}

impl PageClip {
    fn new(region: objc2_foundation::NSRect, radius: f64, flipped: bool) -> Self {
        Self {
            region,
            radius: radius
                .max(0.)
                .min(region.size.width.max(0.) / 2.)
                .min(region.size.height.max(0.) / 2.),
            bottom_at_max_y: flipped,
        }
    }

    fn mask_frame(self, visible: objc2_foundation::NSRect) -> objc2_foundation::NSRect {
        objc2_foundation::NSRect::new(
            objc2_foundation::NSPoint::new(
                self.region.origin.x - visible.origin.x,
                self.region.origin.y - visible.origin.y,
            ),
            self.region.size,
        )
    }

    fn contains(self, point: objc2_foundation::NSPoint) -> bool {
        let left = point.x - self.region.origin.x;
        let right = self.region.size.width - left;
        if left < 0.
            || right <= 0.
            || point.y < self.region.origin.y
            || point.y >= self.region.origin.y + self.region.size.height
        {
            return false;
        }
        let lower = if self.bottom_at_max_y {
            self.region.origin.y + self.region.size.height - point.y
        } else {
            point.y - self.region.origin.y
        };
        let edge = left.min(right);
        if edge >= self.radius || lower >= self.radius {
            return true;
        }
        (self.radius - edge).powi(2) + (self.radius - lower).powi(2) <= self.radius.powi(2)
    }

    fn masked_corners(self) -> usize {
        // CACornerMask: MinXMinY | MaxXMinY, or MinXMaxY | MaxXMaxY.
        if self.bottom_at_max_y { 0b1100 } else { 0b0011 }
    }
}

// Clips native content to GPUI's current paint mask. During app drags the
// entire native subtree passes pointer events back to GPUI, without hiding it.
define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "HarnessBrowserClipView"]
    #[ivars = ClipState]
    struct BrowserClipView;
    impl BrowserClipView {
        #[unsafe(method(hitTest:))]
        fn hit_test(&self, point: objc2_foundation::NSPoint) -> *mut NSView {
            let region = self.ivars().region.get();
            if self.ivars().dragging.get()
                || point.x < region.origin.x + self.ivars().resize_inset.get() || point.x >= region.origin.x + region.size.width
                || point.y < region.origin.y || point.y >= region.origin.y + region.size.height
                || !self.ivars().page.get().contains(point)
            { std::ptr::null_mut() }
            else { unsafe { msg_send![super(self), hitTest: point] } }
        }
    }
);

pub(super) struct NativePage(Rc<RefCell<Host>>);

pub(super) struct Host {
    web: WebView,
    data: BrowserData,
    view: Retained<WKWebView>,
    observer: Retained<Observer>,
    clip: Retained<BrowserClipView>,
    viewport: Retained<NSView>,
    clip_mask: Retained<AnyObject>,
    page_mask: Retained<AnyObject>,
    parent: Retained<NSView>,
    visible_bounds: Option<Bounds<Pixels>>,
    background_color: Option<Retained<NSColor>>,
    monitor: Option<Retained<AnyObject>>,
    shortcuts: Rc<RefCell<Vec<String>>>,
    bounds: Option<Bounds<Pixels>>,
    presentation: Presentation,
    page_had_focus: bool,
    restore_page_focus: bool,
    drag_focus_recorded: bool,
    pointer_focus_candidate: bool,
    tx: Sender,
    #[cfg(feature = "browser-fixture")]
    visibility_changes: Cell<u64>,
}

/// Serve a saved view: only from graff's directories, always under its CSP.
fn view_response(address: &str) -> wry::http::Response<std::borrow::Cow<'static, [u8]>> {
    let result = std::env::home_dir()
        .ok_or(ViewReadError::NotFound)
        .and_then(|home| read_view(&home, address));
    let (status, body): (u16, Vec<u8>) = match result {
        Ok(body) => (200, body),
        Err(ViewReadError::NotFound) => (404, b"This view is no longer on this computer.".to_vec()),
        Err(ViewReadError::TooLarge) => (413, b"This view is too large to open.".to_vec()),
        Err(ViewReadError::Invalid) => (400, b"This view can't be opened.".to_vec()),
    };
    let content_type = if status == 200 { "text/html; charset=utf-8" } else { "text/plain; charset=utf-8" };
    let csp = view_from_url(address).map_or(VIEW_CSP, |view| view_csp(view.kind));
    wry::http::Response::builder()
        .status(status)
        .header("Content-Type", content_type)
        .header("Content-Security-Policy", csp)
        .header("X-Content-Type-Options", "nosniff")
        .header("Cache-Control", "no-store")
        .header("Referrer-Policy", "no-referrer")
        .body(std::borrow::Cow::Owned(body))
        .unwrap_or_else(|_| {
            let mut empty = wry::http::Response::new(std::borrow::Cow::Borrowed(&[][..]));
            *empty.status_mut() = wry::http::StatusCode::INTERNAL_SERVER_ERROR;
            empty
        })
}

impl NativePage {
    pub fn new(window: &Window, data: &BrowserData, tx: Sender) -> Result<Self, String> {
        let mtm = MainThreadMarker::new().ok_or("Browser must be created on the main thread")?;
        Self::build(window, data, data.configuration(mtm), None, false, tx, mtm)
    }

    /// A saved tool view: its own throwaway website data, pages served only
    /// on [`VIEW_SCHEME`] from graff's directories, and no way onto the web.
    pub fn new_view(window: &Window, kind: ToolViewKind, tx: Sender) -> Result<Self, String> {
        let mtm = MainThreadMarker::new().ok_or("Browser must be created on the main thread")?;
        let configuration = unsafe { objc2_web_kit::WKWebViewConfiguration::new(mtm) };
        unsafe {
            configuration
                .setWebsiteDataStore(&objc2_web_kit::WKWebsiteDataStore::nonPersistentDataStore(mtm));
        }
        Self::build(
            window,
            &BrowserData::default(),
            configuration,
            Some(kind),
            false,
            tx,
            mtm,
        )
    }

    /// A preview never shares website cookies, scheme handlers or profiles.
    pub fn new_document(window: &Window, tx: Sender) -> Result<Self, String> {
        let mtm = MainThreadMarker::new().ok_or("Browser must be created on the main thread")?;
        let configuration = unsafe { objc2_web_kit::WKWebViewConfiguration::new(mtm) };
        unsafe {
            configuration.setWebsiteDataStore(
                &objc2_web_kit::WKWebsiteDataStore::nonPersistentDataStore(mtm),
            );
        }
        // CSP does not cover WebRTC data-channel/STUN traffic. Fail closed if
        // this WebKit lacks the native switch; JS API masking is bypassable.
        let preferences = unsafe { configuration.preferences() };
        if !preferences.respondsToSelector(sel!(_setPeerConnectionEnabled:))
            || !preferences.respondsToSelector(sel!(_setDNSPrefetchingEnabled:))
        {
            return Err(
                "This WebKit cannot isolate preview networking. Open the source file instead."
                    .into(),
            );
        }
        unsafe {
            let _: () = msg_send![&*preferences, _setPeerConnectionEnabled: false];
            let _: () = msg_send![&*preferences, _setDNSPrefetchingEnabled: false];
        }
        // Link preconnect bypasses CSP on WebKit. Disable speculative loads in
        // native preferences before creating any page, including child realms.
        let features_available: bool =
            unsafe { msg_send![class!(WKPreferences), respondsToSelector: sel!(_features)] };
        if !features_available
            || !preferences.respondsToSelector(sel!(_setEnabled:forFeature:))
            || !preferences.respondsToSelector(sel!(_isEnabledForFeature:))
        {
            return Err("This WebKit cannot isolate speculative preview networking.".into());
        }
        let features: Retained<NSArray<AnyObject>> =
            unsafe { msg_send![class!(WKPreferences), _features] };
        let mut preconnect_disabled = false;
        for feature in &features {
            let key: Retained<NSString> = unsafe { msg_send![&*feature, key] };
            let key = key.to_string();
            if matches!(
                key.as_str(),
                "LinkPreconnect"
                    | "LinkPreconnectEarlyHintsEnabled"
                    | "LinkPrefetchEnabled"
                    | "SpeculationRulesPrefetchEnabled"
            ) {
                unsafe {
                    let _: () = msg_send![&*preferences, _setEnabled: false, forFeature: &*feature];
                    let enabled: bool = msg_send![&*preferences, _isEnabledForFeature: &*feature];
                    if enabled {
                        return Err(
                            "This WebKit cannot disable speculative preview networking.".into()
                        );
                    }
                }
                preconnect_disabled |= key == "LinkPreconnect";
            }
        }
        if !preconnect_disabled {
            return Err("This WebKit has no isolated preview preconnect setting.".into());
        }
        Self::build(
            window,
            &BrowserData::default(),
            configuration,
            None,
            true,
            tx,
            mtm,
        )
    }

    fn build(
        window: &Window,
        data: &BrowserData,
        configuration: Retained<objc2_web_kit::WKWebViewConfiguration>,
        view_page: Option<ToolViewKind>,
        document: bool,
        tx: Sender,
        mtm: MainThreadMarker,
    ) -> Result<Self, String> {
        let new_tab = tx.clone();
        let mut builder = wry::WebViewBuilder::new()
            .with_webview_configuration(configuration)
            .with_visible(false)
            .with_focused(false)
            .with_new_window_req_handler(move |url, _| {
                // A view page never opens anything else.
                if view_page.is_none() && !document && allowed_navigation(&url) {
                    let _ = new_tab.try_send(NativeEvent::NewTab(url));
                }
                wry::NewWindowResponse::Deny
            })
            .with_download_started_handler(|_, _| false);
        if document {
            builder = builder.with_permission_handler(|_| wry::PermissionResponse::Deny);
        }
        if view_page.is_some() {
            builder = builder.with_custom_protocol(VIEW_SCHEME.into(), |_, request| {
                view_response(&request.uri().to_string())
            });
        }
        let web = builder.build_as_child(window).map_err(|e| e.to_string())?;
        let view = Retained::into_super(web.webview());
        window
            .enable_scene_overlay()
            .map_err(|error| error.to_string())?;
        let parent = unsafe { view.superview() }.ok_or("Browser parent is missing")?;
        let clip: Retained<BrowserClipView> = unsafe {
            let object = mtm.alloc().set_ivars(ClipState {
                dragging: Cell::new(false),
                region: Cell::new(objc2_foundation::NSRect::ZERO),
                resize_inset: Cell::new(0.0),
                page: Cell::new(PageClip::new(objc2_foundation::NSRect::ZERO, 0., false)),
            });
            msg_send![super(object), initWithFrame: objc2_foundation::NSRect::ZERO]
        };
        clip.setWantsLayer(true);
        clip.setAutoresizesSubviews(false);
        let clip_mask: Retained<AnyObject> = unsafe { msg_send![class!(CALayer), new] };
        let page_mask: Retained<AnyObject> = unsafe { msg_send![class!(CALayer), new] };
        unsafe {
            let color = NSColor::blackColor().CGColor();
            let _: () = msg_send![&*page_mask, setBackgroundColor: &*color];
            // A transparent container clips the rounded shape to GPUI's
            // rectangle. Core Animation does not support masks of masks.
            let _: () = msg_send![&*clip_mask, setMasksToBounds: true];
            let _: () = msg_send![&*clip_mask, addSublayer: &*page_mask];
            let layer: *mut AnyObject = msg_send![&*clip, layer];
            let _: () = msg_send![layer, setMasksToBounds: true];
            let _: () = msg_send![layer, setMask: &*clip_mask];
        }
        clip.setHidden(true);
        parent.addSubview(&clip);
        // Keep every native tab beneath the shared GPUI overlay plane.
        for sibling in parent.subviews() {
            if sibling.class().name() == c"GPUIOverlayView" {
                parent.addSubview_positioned_relativeTo(
                    &clip,
                    NSWindowOrderingMode::Below,
                    Some(&sibling),
                );
                break;
            }
        }
        // WebKit docks its inspector beside the inspected view and lays out
        // both using their shared parent's bounds. The stationary clip spans
        // the entire window, so give WebKit a parent matching the browser body.
        let viewport = NSView::initWithFrame(mtm.alloc(), objc2_foundation::NSRect::ZERO);
        viewport.setAutoresizesSubviews(true);
        clip.addSubview(&viewport);
        view.setFrame(viewport.bounds());
        view.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewWidthSizable
                | NSAutoresizingMaskOptions::ViewHeightSizable,
        );
        viewport.addSubview(&view);

        let observer = Observer::new(tx.clone(), view_page, document, mtm);
        unsafe {
            view.setNavigationDelegate(Some(ProtocolObject::from_ref(&*observer)));
            if document {
                view.setUIDelegate(Some(ProtocolObject::from_ref(&*observer)));
            }
            for key in OBSERVED {
                view.addObserver_forKeyPath_options_context(
                    &observer,
                    &NSString::from_str(key),
                    NSKeyValueObservingOptions::empty(),
                    std::ptr::null_mut(),
                );
            }
        }
        let shortcuts = Rc::new(RefCell::new(Vec::<String>::new()));
        let monitor_view = view.clone();
        let monitor_tx = tx.clone();
        let monitor_shortcuts = shortcuts.clone();
        let callback = block2::RcBlock::new(move |event: std::ptr::NonNull<NSEvent>| {
            let e = unsafe { event.as_ref() };
            if monitor_view.isHidden()
                || !has_focus(&monitor_view)
                || e.window(mtm) != monitor_view.window()
            {
                return event.as_ptr();
            }
            let mods = e.modifierFlags();
            let key = e
                .charactersIgnoringModifiers()
                .map(|s| s.to_string().to_lowercase())
                .unwrap_or_default();
            let mut combo = String::new();
            if mods.contains(NSEventModifierFlags::Command) {
                combo.push_str("cmd-");
            }
            if mods.contains(NSEventModifierFlags::Control) {
                combo.push_str("ctrl-");
            }
            if mods.contains(NSEventModifierFlags::Option) {
                combo.push_str("alt-");
            }
            if mods.contains(NSEventModifierFlags::Shift) {
                combo.push_str("shift-");
            }
            combo.push_str(&key);
            let Ok(keystroke) = gpui::Keystroke::parse(&combo) else {
                return event.as_ptr();
            };
            let browser_key = matches!(
                combo.as_str(),
                "cmd-l" | "cmd-t" | "cmd-w" | "cmd-[" | "cmd-]" | "cmd-shift-r" | "cmd-k" | "cmd-,"
            );
            let app_key = monitor_shortcuts
                .borrow()
                .iter()
                .any(|s| gpui::Keystroke::parse(s).is_ok_and(|s| s == keystroke));
            if browser_key || app_key {
                let forwarded = NativeEvent::Key {
                    key: keystroke,
                    app: !browser_key,
                };
                if monitor_tx.try_send(forwarded).is_ok() {
                    std::ptr::null_mut()
                } else {
                    event.as_ptr()
                }
            } else {
                event.as_ptr()
            }
        });
        let monitor = unsafe {
            NSEvent::addLocalMonitorForEventsMatchingMask_handler(NSEventMask::KeyDown, &callback)
        };
        Ok(Self(Rc::new(RefCell::new(Host {
            data: data.clone(),
            web,
            view,
            observer,
            clip,
            viewport,
            clip_mask,
            page_mask,
            parent,
            visible_bounds: None,
            background_color: None,
            monitor,
            shortcuts,
            bounds: None,
            presentation: Presentation::Hidden,
            page_had_focus: false,
            restore_page_focus: false,
            drag_focus_recorded: false,
            pointer_focus_candidate: false,
            #[cfg(feature = "browser-fixture")]
            visibility_changes: Cell::new(0),
            tx,
        }))))
    }
    pub fn handle(&self) -> Rc<RefCell<Host>> {
        self.0.clone()
    }
    /// Reparent the retained native hierarchy; never rebuild or reload WebKit.
    pub fn move_to_window(&self, window: &Window) -> Result<(), String> {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};

        let handle = HasWindowHandle::window_handle(window).map_err(|error| error.to_string())?;
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
            return Err("Browser destination is not an AppKit window".into());
        };
        let parent = unsafe { Retained::retain(handle.ns_view.as_ptr().cast::<NSView>()) }
            .ok_or("Browser destination view is missing")?;
        window
            .enable_scene_overlay()
            .map_err(|error| error.to_string())?;
        let mut host = self.0.borrow_mut();
        if std::ptr::eq(&*host.parent, &*parent) {
            return Ok(());
        }
        host.restore_page_focus =
            host.page_had_focus || host.pointer_focus_candidate || has_focus(&host.view);
        host.page_had_focus = host.restore_page_focus;
        host.drag_focus_recorded = false;
        host.pointer_focus_candidate = false;
        host.release_focus();
        // Hide until destination layout supplies valid clipping and bounds.
        // This prevents a frame painted at the source window's coordinates.
        host.clip.setHidden(true);
        parent.addSubview(&host.clip);
        for sibling in parent.subviews() {
            if sibling.class().name() == c"GPUIOverlayView" {
                parent.addSubview_positioned_relativeTo(
                    &host.clip,
                    NSWindowOrderingMode::Below,
                    Some(&sibling),
                );
                break;
            }
        }
        host.parent = parent;
        host.bounds = None;
        host.visible_bounds = None;
        host.clip.ivars().region.set(objc2_foundation::NSRect::ZERO);
        host.update_visibility();
        Ok(())
    }

    /// WebKit snapshots include native page content absent from GPUI captures.
    pub fn snapshot(&self) -> tokio::sync::oneshot::Receiver<Option<Vec<u8>>> {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let Some(mtm) = MainThreadMarker::new() else {
            let _ = sender.send(None);
            return receiver;
        };
        let host = self.0.borrow();
        if host.view.bounds().size.width <= 0. || host.view.bounds().size.height <= 0. {
            let _ = sender.send(None);
            return receiver;
        }
        let configuration = unsafe { WKSnapshotConfiguration::new(mtm) };
        unsafe {
            configuration.setSnapshotWidth(Some(&NSNumber::new_f64(440.)));
            configuration.setAfterScreenUpdates(false);
        }
        let sender = RefCell::new(Some(sender));
        let completion = block2::RcBlock::new(move |image: *mut NSImage, error: *mut NSError| {
            let bytes = if error.is_null() {
                unsafe { image.as_ref() }
                    .and_then(|image| image.TIFFRepresentation())
                    .map(|data| data.to_vec())
            } else {
                None
            };
            if let Some(sender) = sender.borrow_mut().take() {
                let _ = sender.send(bytes);
            }
        });
        unsafe {
            host.view
                .takeSnapshotWithConfiguration_completionHandler(Some(&configuration), &completion);
        }
        receiver
    }

    pub fn focus_chrome(&self) {
        let mut host = self.0.borrow_mut();
        // Activating a newly reparented tab focuses its chrome as part of the
        // ordinary tab path. Preserve the pending return to the live page.
        if !host.restore_page_focus && !host.drag_focus_recorded {
            host.page_had_focus = false;
            host.drag_focus_recorded = false;
            host.pointer_focus_candidate = false;
        }
        host.focus_parent();
    }
    /// Hand the keyboard back to the app if WebKit holds it.
    pub fn release_focus(&self) {
        let mut host = self.0.borrow_mut();
        host.page_had_focus = false;
        host.restore_page_focus = false;
        host.drag_focus_recorded = false;
        host.pointer_focus_candidate = false;
        host.release_focus();
    }
    pub fn will_restore_page_focus(&self) -> bool {
        self.0.borrow().restore_page_focus
    }
    pub fn prepare_window_drag(&self) {
        let mut host = self.0.borrow_mut();
        host.page_had_focus = host.pointer_focus_candidate || has_focus(&host.view);
        host.pointer_focus_candidate = false;
        host.drag_focus_recorded = true;
    }
    pub fn restore_page_focus_after_drag(&self) -> bool {
        let mut host = self.0.borrow_mut();
        host.restore_page_focus = host.page_had_focus;
        host.drag_focus_recorded = false;
        host.pointer_focus_candidate = false;
        host.restore_page_focus
    }
    pub fn discard_page_focus_after_drag(&self) {
        let mut host = self.0.borrow_mut();
        host.page_had_focus = false;
        host.restore_page_focus = false;
        host.drag_focus_recorded = false;
        host.pointer_focus_candidate = false;
    }
    pub fn set_shortcuts(&self, shortcuts: Vec<String>) {
        *self.0.borrow().shortcuts.borrow_mut() = shortcuts;
    }
    pub fn present(&mut self, presentation: Presentation) {
        self.0.borrow_mut().present(presentation);
    }
    pub fn load(&self, url: &str) -> Result<(), String> {
        let host = self.0.borrow();
        host.data.register_preview(url);
        host.observer.ivars().error.borrow_mut().take();
        *host.observer.ivars().requested_url.borrow_mut() = Some(url.into());
        host.web.load_url(url).map_err(|e| e.to_string())
    }
    pub fn load_html(&self, html: &str) -> Result<(), String> {
        let host = self.0.borrow();
        host.observer.ivars().document.set(true);
        host.observer.ivars().error.borrow_mut().take();
        host.web.load_html(html).map_err(|error| error.to_string())
    }
    pub fn reload(&self) {
        let host = self.0.borrow();
        host.observer.ivars().error.borrow_mut().take();
        // Retrying the requested URL also works after a failed provisional load.
        unsafe {
            host.view.reload();
        }
        host.observer.changed();
    }
    pub fn history(&self, forward: bool) {
        let host = self.0.borrow();
        unsafe {
            if forward {
                host.view.goForward();
            } else {
                host.view.goBack();
            }
        }
    }
    pub fn state(&self) -> PageState {
        let host = self.0.borrow();
        host.observer.ivars().pending.set(false);
        unsafe {
            PageState {
                url: host
                    .observer
                    .ivars()
                    .requested_url
                    .borrow()
                    .clone()
                    .or_else(|| {
                        host.view
                            .URL()
                            .and_then(|u| u.absoluteString())
                            .map(|u| u.to_string())
                    }),
                title: host.view.title().map(|s| s.to_string()).unwrap_or_default(),
                loading: host.view.isLoading(),
                can_back: host.view.canGoBack(),
                can_forward: host.view.canGoForward(),
                error: host.observer.ivars().error.borrow().clone(),
            }
        }
    }
    pub fn discover_favicon(&self, page: String) {
        let host = self.0.borrow();
        let tx = host.tx.clone();
        // Our navigation delegate owns readiness, so Wry's private pending-
        // script queue is intentionally bypassed. This runs only after finish.
        let completion = block2::RcBlock::new(move |value: *mut AnyObject, error: *mut NSError| {
            if !error.is_null() {
                return;
            }
            if let Some(url) =
                unsafe { value.as_ref() }.and_then(|value| value.downcast_ref::<NSString>())
            {
                let _ = tx.try_send(NativeEvent::Favicon {
                    page: page.clone(),
                    url: url.to_string(),
                });
            }
        });
        unsafe {
            host.view.evaluateJavaScript_completionHandler(
                &NSString::from_str("(() => { const link = document.querySelector('link[rel~=icon]'); return link ? link.href : new URL('/favicon.ico', location.href).href; })()"),
                Some(&completion),
            );
        }
    }
}

fn has_focus(view: &NSView) -> bool {
    view.window()
        .and_then(|w| w.firstResponder())
        .and_then(|r| r.downcast::<NSView>().ok())
        .is_some_and(|v| v.isDescendantOf(view))
}

impl Host {
    /// The tab press reaches this capture listener before GPUI can recognize
    /// a drag. Keep its responder candidate only for this pointer gesture.
    pub fn release_focus_for_pointer(&mut self) {
        self.pointer_focus_candidate = has_focus(&self.view);
        self.release_focus();
    }

    pub fn end_pointer_focus_candidate(&mut self) {
        self.pointer_focus_candidate = false;
    }

    // Wry retains the original parent view, even after native reparenting.
    // Hand focus to our current host instead of Wry's original NSView.
    fn focus_parent(&self) {
        if let Some(window) = self.view.window() {
            window.makeFirstResponder(Some(&self.parent));
        }
    }

    /// GPUI's view never takes first responder on a click, so once WebKit
    /// has the keyboard it keeps it until someone hands it back.
    pub fn release_focus(&self) {
        if has_focus(&self.view) {
            self.focus_parent();
        }
    }

    pub fn sync(
        &mut self,
        bounds: Bounds<Pixels>,
        mask: Bounds<Pixels>,
        dragging: bool,
        resize_inset: Pixels,
        bottom_radius: Pixels,
    ) {
        // WebKit may fill newly exposed tiles a frame after a viewport change.
        // Match its page background beneath those tiles instead of exposing
        // the application's dark window background at the resize edge.
        unsafe {
            let color = self.view.underPageBackgroundColor();
            let unchanged = self
                .background_color
                .as_ref()
                .is_some_and(|previous| msg_send![&**previous, isEqual: &*color]);
            if !unchanged {
                // WebKit's native backing otherwise uses controlBackgroundColor,
                // independently of the CSS page background. Exposed resize tiles
                // must use the page color while the remote content catches up.
                let _: () = msg_send![&*self.view, _setBackgroundColor: &*color];
                let cg_color = color.CGColor();
                let layer: *mut AnyObject = msg_send![&*self.clip, layer];
                let _: () = msg_send![layer, setBackgroundColor: &*cg_color];
                self.background_color = Some(color);
            }
        }
        let visible = bounds.intersect(&mask);
        self.clip.ivars().dragging.set(dragging);
        self.clip
            .ivars()
            .resize_inset
            .set(f64::from(f32::from(resize_inset)));
        let parent_bounds = self.parent.bounds();
        let flipped = self.parent.isFlipped();
        let web_height = f64::from(f32::from(bounds.size.height)).max(0.);
        let web_y = f64::from(f32::from(bounds.origin.y));
        let web_y = if flipped {
            web_y
        } else {
            parent_bounds.size.height - web_y - web_height
        };
        let page = PageClip::new(
            objc2_foundation::NSRect::new(
                objc2_foundation::NSPoint::new(f64::from(f32::from(bounds.origin.x)), web_y),
                objc2_foundation::NSSize::new(
                    f64::from(f32::from(bounds.size.width)).max(0.),
                    web_height,
                ),
            ),
            f64::from(f32::from(bottom_radius)),
            flipped,
        );
        if self.bounds != Some(bounds)
            || self.visible_bounds != Some(visible)
            || self.clip.ivars().page.get() != page
            || self.clip.frame() != parent_bounds
        {
            self.bounds = Some(bounds);
            self.visible_bounds = Some(visible);
            let x = f64::from(f32::from(visible.origin.x));
            let y = f64::from(f32::from(visible.origin.y));
            let width = f64::from(f32::from(visible.size.width)).max(0.);
            let height = f64::from(f32::from(visible.size.height)).max(0.);
            let y = if flipped {
                y
            } else {
                parent_bounds.size.height - y - height
            };
            let actions_disabled: bool = unsafe {
                let previous = msg_send![class!(CATransaction), disableActions];
                let _: () = msg_send![class!(CATransaction), setDisableActions: true];
                previous
            };
            // Keep the host stationary. Moving it while WebKit updates its
            // remote layer tree can combine the old origin with the new size.
            self.clip.setFrame(parent_bounds);
            let region = objc2_foundation::NSRect::new(
                objc2_foundation::NSPoint::new(x, y),
                objc2_foundation::NSSize::new(width, height),
            );
            self.clip.ivars().region.set(region);
            self.clip.ivars().page.set(page);
            unsafe {
                let _: () = msg_send![&*self.clip_mask, setFrame: region];
                let _: () = msg_send![&*self.page_mask, setFrame: page.mask_frame(region)];
                let _: () = msg_send![&*self.page_mask, setCornerRadius: page.radius];
                let _: () = msg_send![&*self.page_mask, setMaskedCorners: page.masked_corners()];
            }
            // Preserve fractional GPUI geometry. Resize the shared viewport,
            // not WKWebView: WebKit owns the page/inspector split while docked.
            // The outer clip stays stationary to keep native/Metal updates aligned.
            self.viewport.setFrame(page.region);
            unsafe {
                // Leave the implicit transaction open for the matching Metal
                // presentation. Committing here would expose native geometry early.
                let _: () = msg_send![class!(CATransaction), setDisableActions: actions_disabled];
            }
            #[cfg(feature = "browser-fixture")]
            unsafe {
                let layer: *mut AnyObject = msg_send![&*self.clip, layer];
                let frame: objc2_foundation::NSRect = msg_send![layer, frame];
                let presentation: *mut AnyObject = msg_send![layer, presentationLayer];
                let presented: objc2_foundation::NSRect = if presentation.is_null() {
                    frame
                } else {
                    msg_send![presentation, frame]
                };
                eprintln!(
                    "Browser geometry: bounds={bounds:?} mask={mask:?} clip={:?} layer={frame:?} presented={presented:?} web={:?} background={:?}",
                    self.clip.frame(),
                    self.view.frame(),
                    self.view.underPageBackgroundColor()
                );
            }
        }
        self.update_visibility();
    }
    fn update_visibility(&mut self) {
        let visible = self.presentation != Presentation::Hidden
            && self.observer.ivars().error.borrow().is_none()
            && self
                .visible_bounds
                .is_some_and(|b| f32::from(b.size.width) > 0. && f32::from(b.size.height) > 0.);
        if (!visible || self.presentation == Presentation::Passthrough) && has_focus(&self.view) {
            self.focus_parent();
        }
        if self.view.isHidden() == visible {
            #[cfg(feature = "browser-fixture")]
            self.visibility_changes
                .set(self.visibility_changes.get() + 1);
            let _ = self.web.set_visible(visible);
        }
        self.clip.setHidden(!visible);
        if visible && self.presentation == Presentation::Live && self.restore_page_focus {
            if let Some(window) = self.view.window()
                && window.makeFirstResponder(Some(&self.view))
            {
                self.restore_page_focus = false;
                self.page_had_focus = false;
                self.drag_focus_recorded = false;
            }
        }
    }
    fn present(&mut self, presentation: Presentation) {
        if presentation == Presentation::Passthrough
            && self.presentation == Presentation::Live
            && !self.drag_focus_recorded
        {
            self.page_had_focus = self.pointer_focus_candidate || has_focus(&self.view);
        } else if presentation == Presentation::Live
            && !self.restore_page_focus
            && !self.drag_focus_recorded
        {
            // A normal menu/address transition never restores native focus.
            // Only reparenting or explicit drag cancellation arms restoration.
            self.page_had_focus = false;
            self.drag_focus_recorded = false;
        } else if presentation == Presentation::Hidden
            && !self.drag_focus_recorded
            && !self.restore_page_focus
        {
            self.page_had_focus = false;
        }
        self.presentation = presentation;
        self.clip
            .ivars()
            .dragging
            .set(presentation == Presentation::Passthrough);
        self.update_visibility();
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        if has_focus(&self.view) {
            self.focus_parent();
        }
        unsafe {
            if let Some(monitor) = self.monitor.take() {
                NSEvent::removeMonitor(&monitor);
            }
            for key in OBSERVED {
                self.view
                    .removeObserver_forKeyPath(&self.observer, &NSString::from_str(key));
            }
            self.view.setNavigationDelegate(None);
            self.view.stopLoading();
        }
        self.view.removeFromSuperview();
        self.clip.removeFromSuperview();
    }
}

#[cfg(test)]
mod clipping_tests {
    use super::PageClip;
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    fn page(flipped: bool) -> PageClip {
        PageClip::new(
            NSRect::new(NSPoint::new(20., 30.), NSSize::new(100., 80.)),
            10.,
            flipped,
        )
    }

    #[test]
    fn browser_page_only_lower_corners_pass_pointer_events_through() {
        let page = page(false);
        assert!(!page.contains(NSPoint::new(20.5, 30.5)));
        assert!(!page.contains(NSPoint::new(119.5, 30.5)));
        assert!(page.contains(NSPoint::new(20.5, 109.5)));
        assert!(page.contains(NSPoint::new(119.5, 109.5)));
        assert!(page.contains(NSPoint::new(70., 30.5)));
        assert!(page.contains(NSPoint::new(25., 35.)));
    }

    #[test]
    fn browser_page_flipped_parent_preserves_screen_bottom_corners() {
        let page = page(true);
        assert!(!page.contains(NSPoint::new(20.5, 109.5)));
        assert!(!page.contains(NSPoint::new(119.5, 109.5)));
        assert!(page.contains(NSPoint::new(20.5, 30.5)));
        assert!(page.contains(NSPoint::new(119.5, 30.5)));
        assert_eq!(page.masked_corners(), 0b1100);
    }

    #[test]
    fn browser_page_occlusion_does_not_move_card_corners() {
        let page = page(false);
        let visible = NSRect::new(NSPoint::new(25., 35.), NSSize::new(70., 65.));
        assert_eq!(
            page.mask_frame(visible),
            NSRect::new(NSPoint::new(-5., -5.), NSSize::new(100., 80.))
        );
        assert!(page.contains(visible.origin));
    }

    #[test]
    fn browser_page_zero_radius_preserves_rectangular_previews() {
        let page = PageClip::new(page(false).region, 0., false);
        assert!(page.contains(NSPoint::new(20., 30.)));
        assert!(page.contains(NSPoint::new(119.5, 109.5)));
        assert!(!page.contains(NSPoint::new(19.5, 30.)));
    }
}

#[cfg(feature = "browser-fixture")]
impl NativePage {
    /// Fixture-only access to WebKit's real inspector, not a simulated split.
    pub fn fixture_inspector(&self, action: &str) -> bool {
        let host = self.0.borrow();
        unsafe {
            let inspector: Retained<AnyObject> = msg_send![&*host.view, _inspector];
            match action {
                "show" => {
                    let _: () = msg_send![&*inspector, show];
                    return true;
                }
                "close" => {
                    let _: () = msg_send![&*inspector, close];
                    return true;
                }
                "detach" => {
                    let _: () = msg_send![&*inspector, detach];
                    return true;
                }
                _ => {}
            }
            let frontend: Option<Retained<WKWebView>> = msg_send![&*inspector, inspectorWebView];
            let Some(frontend) = frontend else {
                return false;
            };
            if frontend.isLoading() {
                return false;
            }
            let script = match action {
                "bottom" | "left" | "right" => format!(
                    "InspectorFrontendHost.requestSetDockSide({});", serde_json::to_string(action).unwrap()
                ),
                "resize" => "InspectorFrontendHost.setAttachedWindowHeight(280); InspectorFrontendHost.setAttachedWindowWidth(420);".to_owned(),
                _ => return false,
            };
            frontend.evaluateJavaScript_completionHandler(&NSString::from_str(&script), None);
            true
        }
    }
    pub fn fixture_inspector_geometry(&self) -> serde_json::Value {
        let host = self.0.borrow();
        let rect =
            |r: objc2_foundation::NSRect| [r.origin.x, r.origin.y, r.size.width, r.size.height];
        let page = host
            .clip
            .convertRect_fromView(host.view.bounds(), Some(&host.view));
        let expected = host.clip.ivars().page.get().region;
        unsafe {
            let inspector: Retained<AnyObject> = msg_send![&*host.view, _inspector];
            let frontend: Option<Retained<WKWebView>> = msg_send![&*inspector, inspectorWebView];
            serde_json::json!({
                "expected": rect(expected),
                "page": rect(page),
                "inspector": frontend.as_ref().map(|view| rect(host.clip.convertRect_fromView(view.bounds(), Some(view)))),
                "attached": frontend.as_ref().is_some_and(|view| view.isDescendantOf(&host.clip)),
                "visible": frontend.as_ref().is_some_and(|view| !view.isHidden()),
            })
        }
    }
    pub fn fixture_identity(&self) -> usize {
        std::ptr::from_ref(&*self.0.borrow().view) as usize
    }
    pub fn fixture_move_cursor(&self, x: f64, y: f64) {
        #[link(name = "CoreGraphics", kind = "framework")]
        unsafe extern "C" {
            fn CGWarpMouseCursorPosition(point: objc2_foundation::NSPoint) -> i32;
        }
        let host = self.0.borrow();
        let window = host.view.window().unwrap();
        let height = host.parent.clone().bounds().size.height;
        let p = window.convertPointToScreen(objc2_foundation::NSPoint::new(x, height - y));
        let screen = objc2_app_kit::NSScreen::mainScreen(host.view.mtm()).unwrap();
        unsafe {
            CGWarpMouseCursorPosition(objc2_foundation::NSPoint::new(
                p.x,
                screen.frame().size.height - p.y,
            ));
        }
    }
    pub fn fixture_backdrop_layers(&self) -> String {
        unsafe fn describe(layer: *mut AnyObject, depth: usize, out: &mut String) {
            if layer.is_null() || depth > 8 {
                return;
            }
            unsafe {
                let desc: Retained<NSString> = msg_send![layer, description];
                out.push_str(&format!("{}{}\n", " ".repeat(depth), desc));
                let layers: *mut AnyObject = msg_send![layer, sublayers];
                if !layers.is_null() {
                    let count: usize = msg_send![layers, count];
                    for i in 0..count.min(30) {
                        let child: *mut AnyObject = msg_send![layers, objectAtIndex:i];
                        describe(child, depth + 1, out);
                    }
                }
            }
        }
        let host = self.0.borrow();
        let mut out = String::new();
        for view in host.parent.subviews() {
            if view.class().name() == c"GPUIBackdropView" {
                unsafe {
                    let layer: *mut AnyObject = msg_send![&*view, layer];
                    describe(layer, 0, &mut out);
                }
            }
        }
        out
    }
    pub fn fixture_page_hit(&self, x: f64, y: f64) -> bool {
        let host = self.0.borrow();
        let point = objc2_foundation::NSPoint::new(x, host.parent.bounds().size.height - y);
        host.parent
            .hitTest(point)
            .is_some_and(|hit| hit.isDescendantOf(&host.clip))
    }
    pub fn fixture_backdrops(&self) -> Vec<(f64, f64, f64, f64)> {
        let host = self.0.borrow();
        host.parent
            .subviews()
            .iter()
            .filter(|view| view.class().name() == c"GPUIBackdropView" && !view.isHidden())
            .map(|view| {
                let r = view.frame();
                (
                    r.origin.x,
                    host.parent.bounds().size.height - r.origin.y - r.size.height,
                    r.size.width,
                    r.size.height,
                )
            })
            .collect()
    }
    pub fn fixture_geometry(&self) -> (f32, f32, f32) {
        let host = self.0.borrow();
        (
            host.bounds.unwrap().size.width.into(),
            host.view.frame().size.width as f32,
            host.visible_bounds.unwrap().size.width.into(),
        )
    }
    pub fn fixture_origin(&self) -> (f32, f32) {
        let b = self.0.borrow().bounds.unwrap();
        (b.origin.x.into(), b.origin.y.into())
    }
    pub fn fixture_overlay_visible(&self) -> bool {
        let host = self.0.borrow();
        host.parent
            .clone()
            .subviews()
            .iter()
            .any(|v| v.class().name() == c"GPUIOverlayView" && !v.isHidden())
    }
    pub fn fixture_visibility_changes(&self) -> u64 {
        let host = self.0.borrow();
        host.visibility_changes.get()
    }
    pub fn fixture_focus(&self) {
        let _ = self.0.borrow().web.focus();
    }
    pub fn fixture_focused(&self) -> bool {
        has_focus(&self.0.borrow().view)
    }
    pub fn fixture_focus_state(&self) -> serde_json::Value {
        let host = self.0.borrow();
        serde_json::json!({
            "nativeFocused": has_focus(&host.view),
            "pageHadFocus": host.page_had_focus,
            "dragRecorded": host.drag_focus_recorded,
            "pointerCandidate": host.pointer_focus_candidate,
            "restorePending": host.restore_page_focus,
            "live": host.presentation == Presentation::Live,
            "visible": !host.view.isHidden()
        })
    }
    pub fn fixture_overlay_at(&self, x: f64, y: f64) -> bool {
        let host = self.0.borrow();
        let parent = host.parent.clone();
        let point = objc2_foundation::NSPoint::new(
            x,
            if parent.isFlipped() {
                y
            } else {
                parent.bounds().size.height - y
            },
        );
        parent
            .hitTest(point)
            .is_some_and(|hit| hit.class().name() == c"GPUIOverlayView")
    }
    pub fn fixture_click(&self, x: f64, y: f64) {
        self.fixture_move_cursor(x, y);
        let host = self.0.borrow();
        let parent = host.parent.clone();
        let window = host.view.window().unwrap();
        let point = objc2_foundation::NSPoint::new(x, parent.bounds().size.height - y);
        let app = objc2_app_kit::NSApplication::sharedApplication(host.view.mtm());
        for kind in [
            objc2_app_kit::NSEventType::LeftMouseDown,
            objc2_app_kit::NSEventType::LeftMouseUp,
        ] {
            let event = NSEvent::mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure(kind, point, NSEventModifierFlags::empty(), 0., window.windowNumber(), None, 0, 1, 1.).unwrap();
            app.postEvent_atStart(&event, false);
        }
    }
    pub fn fixture_visible(&self) -> bool {
        !self.0.borrow().view.isHidden()
    }
    pub fn fixture_eval(&self, script: &str) {
        unsafe {
            self.0
                .borrow()
                .view
                .evaluateJavaScript_completionHandler(&NSString::from_str(script), None);
        }
    }
    pub fn fixture_set_user_agent(&self, user_agent: Option<&str>) {
        let user_agent = user_agent.map(NSString::from_str);
        unsafe {
            self.0.borrow().view.setCustomUserAgent(user_agent.as_deref());
        }
    }
}
