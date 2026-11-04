//! Device-local browser tabs. GPUI owns chrome; the native host owns pages.
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "linux")]
use linux as native;
#[cfg(target_os = "macos")]
use macos as native;
#[cfg(target_os = "macos")]
pub use macos::clear_browsing_data;
mod document;
pub mod model;
pub mod saved_view;
mod view;

use crate::composer::{ComposerInput, ComposerInputEvent};
use gpui::{
    App, AppContext, Context, Entity, EventEmitter, FocusHandle, Focusable, Subscription, Window,
};
use model::{PageState, Presentation};
gpui::actions!(
    browser,
    [Reload, FocusAddress, NewTab, CloseTab, Back, Forward]
);

pub(crate) fn bind_keys(cx: &mut App, keymap: &crate::settings::KeymapConfig) {
    use crate::settings::{ShortcutId, platform_combo};
    // Existing customized app chords win. In particular old settings may
    // already assign mod-shift-r to the right pane.
    let available = |combo: &str, own: Option<ShortcutId>| {
        !combo.is_empty()
            && !ShortcutId::ALL.iter().any(|id| {
                Some(*id) != own
                    // The default new-chat key remains contextual: in a browser,
                    // Cmd+T opens a browser tab. Custom app chords still win.
                    && !(*id == ShortcutId::NewSession
                        && keymap.get(*id) == id.default_combo())
                    && gpui::Keystroke::parse(&platform_combo(keymap.get(*id))).ok()
                        == gpui::Keystroke::parse(&platform_combo(combo)).ok()
            })
    };
    macro_rules! bind {
        ($combo:literal, $action:ident) => {
            if available($combo, None) {
                cx.bind_keys([gpui::KeyBinding::new(
                    &platform_combo($combo),
                    $action,
                    Some("Browser"),
                )]);
            }
        };
    }
    bind!("mod-l", FocusAddress);
    bind!("mod-t", NewTab);
    bind!("mod-w", CloseTab);
    bind!("mod-[", Back);
    bind!("mod-]", Forward);
    let reload = keymap.get(ShortcutId::BrowserReload);
    if available(reload, Some(ShortcutId::BrowserReload))
        && gpui::Keystroke::parse(&platform_combo(reload)).is_ok()
    {
        cx.bind_keys([gpui::KeyBinding::new(
            &platform_combo(reload),
            Reload,
            Some("Browser"),
        )]);
    }
}

#[derive(Clone, Debug)]
pub enum BrowserEvent {
    Changed,
    NewTab(Option<String>),
    OpenSource(String),
    Close,
}

/// A window/profile's ephemeral website data, allocated on first navigation.
#[derive(Clone, Default)]
pub struct BrowserContext {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    data: native::BrowserData,
}

pub struct BrowserSurface {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    context: BrowserContext,
    address: Entity<ComposerInput>,
    focus: FocusHandle,
    pub page: PageState,
    pub favicon: Option<std::sync::Arc<gpui::Image>>,
    address_edited: bool,
    validation: Option<String>,
    remote: bool,
    /// Set when the tab shows a saved tool view instead of the web.
    view: Option<harness_proto::ToolView>,
    document: Option<document::HtmlDocument>,
    document_task: Option<gpui::Task<()>>,
    preview_request: Option<(
        crate::files::client::WorkspaceFilesClient,
        crate::markdown::content_reference::HtmlPreview,
        String,
    )>,
    previews: harness_proto::PreviewSnapshot,
    previews_loading: bool,
    previews_task: Option<gpui::Task<()>>,
    #[cfg(feature = "browser-fixture")]
    fixture_preview_open: std::rc::Rc<std::cell::Cell<Option<gpui::Point<gpui::Pixels>>>>,
    presentation: Presentation,
    #[cfg(target_os = "macos")]
    resize_inset: gpui::Pixels,
    #[cfg(target_os = "macos")]
    right_occlusion: gpui::Pixels,
    _input_sub: Subscription,
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    native: Option<native::NativePage>,
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    native_tx: tokio::sync::mpsc::Sender<native::NativeEvent>,
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    _native_task: gpui::Task<()>,
    #[cfg(target_os = "macos")]
    favicon_task: Option<gpui::Task<()>>,
    #[cfg(target_os = "macos")]
    favicon_generation: u64,
}

impl EventEmitter<BrowserEvent> for BrowserSurface {}
impl Focusable for BrowserSurface {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl BrowserSurface {
    pub fn new(
        context: BrowserContext,
        remote: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let address = cx.new(|cx| {
            ComposerInput::with_context("Website or localhost:3000", "PaletteSearch", cx)
                .with_text_metrics(11.0, 16.0)
                .with_single_line()
                .with_accessibility_role(gpui::Role::TextInput)
        });
        let input_sub = cx.subscribe(&address, |this, _, event, cx| {
            if matches!(event, ComposerInputEvent::Edited) {
                this.address_edited =
                    this.address.read(cx).text() != this.page.url.as_deref().unwrap_or_default();
                this.validation = None;
                cx.notify();
            }
        });
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        let (native_tx, mut events) = tokio::sync::mpsc::channel(64);
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        let native_task = cx.spawn_in(window, async move |this, cx| {
            while let Some(event) = events.recv().await {
                if this
                    .update_in(cx, |this, window, cx| {
                        this.on_native_event(event, window, cx)
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let _ = (window, context);
        Self {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            context,
            address,
            focus: cx.focus_handle(),
            page: PageState::default(),
            favicon: None,
            address_edited: false,
            validation: None,
            remote,
            view: None,
            document: None,
            document_task: None,
            preview_request: None,
            previews: harness_proto::PreviewSnapshot::default(),
            previews_loading: true,
            previews_task: None,
            #[cfg(feature = "browser-fixture")]
            fixture_preview_open: Default::default(),
            presentation: Presentation::Hidden,
            #[cfg(target_os = "macos")]
            resize_inset: gpui::px(0.0),
            #[cfg(target_os = "macos")]
            right_occlusion: gpui::px(0.0),
            _input_sub: input_sub,
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            native: None,
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            native_tx,
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            _native_task: native_task,
            #[cfg(target_os = "macos")]
            favicon_task: None,
            #[cfg(target_os = "macos")]
            favicon_generation: 0,
        }
    }

    pub fn title(&self) -> gpui::SharedString {
        // A view's URL host is its kind ("html"), not a site name.
        if self.view.is_some() && self.page.title.trim().is_empty() {
            return "Saved view".into();
        }
        self.page.label().into()
    }
    pub fn set_remote(&mut self, remote: bool) {
        self.remote = remote;
    }
    pub fn set_shortcuts(&mut self, keymap: &crate::settings::KeymapConfig) {
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            native.set_shortcuts(
                crate::settings::ShortcutId::ALL
                    .iter()
                    .filter(|id| **id != crate::settings::ShortcutId::SaveFile)
                    .map(|id| crate::settings::platform_combo(keymap.get(*id)))
                    .collect(),
            );
        }
        #[cfg(not(target_os = "macos"))]
        let _ = keymap;
    }

    pub fn focus_address(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            native.focus_chrome();
        }
        window.focus(&self.address.focus_handle(cx), cx);
        window.dispatch_action(Box::new(crate::composer::SelectAll), cx);
    }

    /// Reserve the overlapping part of the shell divider for GPUI hit testing.
    #[cfg(target_os = "macos")]
    pub fn set_resize_inset(&mut self, inset: gpui::Pixels, cx: &mut Context<Self>) {
        if self.resize_inset != inset {
            self.resize_inset = inset;
            cx.notify();
        }
    }

    /// Crop a GPUI overlay out of both native painting and native hit testing.
    #[cfg(target_os = "macos")]
    pub fn set_right_occlusion(&mut self, width: gpui::Pixels, cx: &mut Context<Self>) {
        if self.right_occlusion != width {
            self.right_occlusion = width;
            cx.notify();
        }
    }

    pub fn set_presentation(&mut self, presentation: Presentation, cx: &mut Context<Self>) {
        if self.presentation == presentation {
            return;
        }
        self.presentation = presentation;
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        if let Some(native) = &mut self.native {
            native.present(presentation);
        }
        cx.notify();
    }

    #[cfg(feature = "browser-fixture")]
    pub fn fixture_previews(&self) -> harness_proto::PreviewSnapshot {
        self.previews.clone()
    }
    #[cfg(feature = "browser-fixture")]
    pub fn fixture_preview_open_position(&self) -> Option<gpui::Point<gpui::Pixels>> {
        self.fixture_preview_open.get()
    }

    /// The daemon resolves the session's current cwd for every update, so a
    /// checkout change cannot leave this tab discovering the previous project.
    pub fn watch_previews(
        &mut self,
        handle: crate::state::EngineHandle,
        chat_id: String,
        cx: &mut Context<Self>,
    ) {
        self.previews_task = Some(cx.spawn(async move |this, cx| {
            loop {
                let subscription = handle
                    .client()
                    .subscribe_scoped(
                        harness_rpc::methods::WATCH_PREVIEWS,
                        serde_json::json!({"chatId": chat_id}),
                    )
                    .await;
                if let Ok(mut updates) = subscription {
                    while let Some(value) = updates.recv().await {
                        if let Ok(snapshot) =
                            serde_json::from_value::<harness_proto::PreviewSnapshot>(value)
                        {
                            if this
                                .update(cx, |this, cx| {
                                    #[cfg(target_os = "macos")]
                                    for service in &snapshot.services {
                                        this.context
                                            .data
                                            .register_preview(&service.url(snapshot.proxy_port));
                                    }
                                    this.previews = snapshot;
                                    this.previews_loading = false;
                                    cx.notify();
                                })
                                .is_err()
                            {
                                return;
                            }
                        }
                    }
                }
                if this
                    .update(cx, |this, cx| {
                        this.previews.services.clear();
                        this.previews.error = Some("Connecting to preview discovery…".into());
                        this.previews_loading = false;
                        cx.notify();
                    })
                    .is_err()
                {
                    return;
                }
                cx.background_executor()
                    .timer(std::time::Duration::from_secs(2))
                    .await;
            }
        }));
    }

    pub fn navigate(&mut self, input: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.preview_request.is_some() || self.view.is_some() {
            return;
        }
        let url = match model::normalize_address(input) {
            Ok(url) => url,
            Err(message) => {
                self.validation = Some(message.into());
                cx.notify();
                return;
            }
        };
        self.validation = None;
        self.address
            .update(cx, |input, cx| input.set_text(url.clone(), cx));
        self.address_edited = false;
        self.page.url = Some(url.clone());
        self.page.title.clear();
        self.page.error = None;
        self.clear_favicon(cx);
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            #[cfg(target_os = "macos")]
            {
                self.favicon_generation += 1;
                self.favicon_task = None;
            }
            let result = if let Some(native) = &self.native {
                native.load(&url)
            } else {
                native::NativePage::new(window, &self.context.data, self.native_tx.clone())
                    .map(|mut native| {
                        native.present(self.presentation);
                        self.native = Some(native);
                    })
                    .and_then(|_| self.native.as_ref().unwrap().load(&url))
            };
            self.page.loading = result.is_ok();
            if let Err(error) = result {
                self.page.error = Some(format!("Could not open this page: {error}"));
            }
            window.focus(&self.focus, cx);
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            let _ = window;
            cx.open_url(&url);
        }
        cx.emit(BrowserEvent::Changed);
        cx.notify();
    }

    /// Show a page a tool saved on this device. The tab stays on it: typed
    /// addresses are ignored and the page cannot navigate anywhere else.
    pub fn open_view(
        &mut self,
        view: harness_proto::ToolView,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let url = saved_view::view_url(&view);
        self.view = Some(view);
        self.validation = None;
        self.address
            .update(cx, |input, cx| input.set_text(url.clone(), cx));
        self.address_edited = false;
        self.page.url = Some(url.clone());
        self.page.title.clear();
        self.page.error = None;
        #[cfg(target_os = "macos")]
        {
            let kind = self.view.as_ref().map(|view| view.kind).unwrap_or(harness_proto::ToolViewKind::Html);
            let result = native::NativePage::new_view(window, kind, self.native_tx.clone()).and_then(
                |mut native| {
                    native.present(self.presentation);
                    let loaded = native.load(&url);
                    self.native = Some(native);
                    loaded
                },
            );
            self.page.loading = result.is_ok();
            if let Err(error) = result {
                self.page.error = Some(format!("Could not open this view: {error}"));
            }
            window.focus(&self.focus, cx);
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = window;
            self.page.error = Some("Saved views open in the browser pane on macOS for now.".into());
        }
        cx.emit(BrowserEvent::Changed);
        cx.notify();
    }

    /// Read only through the originating chat's workspace/device RPC. Every
    /// reload destroys the old page and its state before asking for new bytes.
    pub fn read_preview(
        &mut self,
        client: crate::files::client::WorkspaceFilesClient,
        request: crate::markdown::content_reference::HtmlPreview,
        path: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.document_task = None;
        self.preview_request = Some((client.clone(), request.clone(), path.clone()));
        self.document = None;
        self.view = None;
        self.previews_task = None;
        self.clear_favicon(cx);
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            self.native = None;
            self.context = BrowserContext::default();
        }
        self.page = PageState {
            url: Some(request.path.clone()),
            title: request
                .path
                .rsplit(['/', '\\'])
                .next()
                .unwrap_or("HTML preview")
                .into(),
            loading: true,
            ..Default::default()
        };
        self.address
            .update(cx, |input, cx| input.set_text(request.path.clone(), cx));
        self.address_edited = false;
        self.validation = None;
        let read = gpui_tokio::Tokio::spawn(cx, async move {
            let file = client
                .read_file(harness_proto::ReadWorkspaceFileRequest {
                    target: client.target().clone(),
                    path,
                })
                .await
                .map_err(|_| "Could not read this HTML preview from its chat device.".to_owned())?;
            if file.truncated {
                return Err("This HTML preview is too large. Open the source file instead.".into());
            }
            let text = file
                .text
                .ok_or_else(|| "This file is not a UTF-8 HTML document.".to_owned())?;
            document::HtmlDocument::new(&request, &text)
        });
        self.document_task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = read.await.map_err(|error| error.to_string()).and_then(|result| result);
            let _ = this.update_in(cx, |this, window, cx| {
                let result: Result<(), String> = result.and_then(|document| {
                    #[cfg(any(target_os = "macos", target_os = "linux"))]
                    {
                        let mut native = native::NativePage::new_document(window, this.native_tx.clone())?;
                        native.present(this.presentation);
                        native.load_html(&document.html)?;
                        this.document = Some(document);
                        this.native = Some(native);
                        Ok(())
                    }
                    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
                    {
                        let _ = (document, window);
                        Err("HTML previews are not available on this platform. Open the source file instead.".to_owned())
                    }
                });
                this.page.loading = result.is_ok();
                this.page.error = result.err();
                cx.emit(BrowserEvent::Changed);
                cx.notify();
            });
        }));
        cx.emit(BrowserEvent::Changed);
        cx.notify();
    }

    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.view.is_some() || self.preview_request.is_some() {
            return;
        }
        let url = self.address.read(cx).text().to_owned();
        self.navigate(&url, window, cx);
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some((client, request, path)) = self.preview_request.clone() {
            self.read_preview(client, request, path, window, cx);
            return;
        }
        let _ = window;
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        if let Some(native) = &self.native {
            if self.page.error.is_some() {
                if let Some(url) = &self.page.url {
                    let _ = native.load(url);
                }
            } else {
                native.reload();
            }
            self.page.error = None;
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        self.open_external(cx);
        cx.notify();
    }

    fn open_external(&self, cx: &mut Context<Self>) {
        if let Some((_, request, _)) = &self.preview_request {
            cx.emit(BrowserEvent::OpenSource(
                crate::markdown::content_reference::file_destination(&request.path),
            ));
            return;
        }
        if let Some(url) = self
            .page
            .url
            .as_deref()
            .filter(|url| model::allowed_navigation(url))
        {
            cx.open_url(url);
        }
    }

    fn history(&mut self, forward: bool) {
        if self.preview_request.is_some() {
            return;
        }
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        if let Some(native) = &self.native {
            native.history(forward);
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let _ = forward;
    }

    /// Explicitly close even if an async callback temporarily retains an entity.
    fn clear_favicon(&mut self, cx: &mut Context<Self>) {
        if let Some(image) = self.favicon.take() {
            cx.defer(move |cx| gpui::ImageSource::Image(image).evict(None, cx));
        }
    }

    pub fn close(&mut self, cx: &mut Context<Self>) {
        self.document_task = None;
        self.preview_request = None;
        self.document = None;
        self.set_presentation(Presentation::Hidden, cx);
        self.clear_favicon(cx);
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            if let Some(native) = &mut self.native {
                native.present(Presentation::Hidden);
            }
            #[cfg(target_os = "linux")]
            if let Some(image) = self.native.as_mut().and_then(|native| native.image.take()) {
                cx.defer(move |cx| gpui::ImageSource::Render(image).evict(None, cx));
            }
            self.native = None;
            #[cfg(target_os = "macos")]
            {
                self.favicon_task = None;
                self.favicon_generation += 1;
            }
        }
    }
}

#[cfg(target_os = "macos")]
impl BrowserSurface {
    fn on_native_event(
        &mut self,
        event: native::NativeEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(native) = &mut self.native else {
            return;
        };
        match event {
            native::NativeEvent::Changed | native::NativeEvent::Finished => {
                let finished = matches!(event, native::NativeEvent::Finished);
                let mut page = native.state();
                if let Some(document) = &self.document {
                    page.url = Some(document.path.clone());
                    #[cfg(feature = "browser-fixture")]
                    let fixture_status = page.title.starts_with("preview:");
                    #[cfg(not(feature = "browser-fixture"))]
                    let fixture_status = false;
                    if !fixture_status {
                        page.title = document.title.clone();
                    }
                    page.can_back = false;
                    page.can_forward = false;
                }
                // A failed provisional request has no committed WebKit URL.
                if page.url.is_none() {
                    page.url = self.page.url.clone();
                }
                if page.error.is_some() {
                    page.loading = false;
                }
                if page.url != self.page.url || (!self.page.loading && page.loading) {
                    if let Some(image) = self.favicon.take() {
                        cx.defer(move |cx| gpui::ImageSource::Image(image).evict(None, cx));
                    }
                    self.favicon_generation += 1;
                    self.favicon_task = None;
                }
                if !self.address.focus_handle(cx).is_focused(window) {
                    if let Some(url) = &page.url {
                        if self.address.read(cx).text() != url {
                            self.address
                                .update(cx, |input, cx| input.set_text(url.clone(), cx));
                        }
                    }
                    self.address_edited = false;
                }
                native.present(self.presentation);
                // A saved view has no site to fetch an icon from.
                if finished
                    && self.view.is_none()
                    && self.preview_request.is_none()
                    && self.document.is_none()
                    && let Some(url) = &page.url
                {
                    native.discover_favicon(url.clone());
                }
                if page != self.page {
                    self.page = page;
                    cx.emit(BrowserEvent::Changed);
                }
                cx.notify();
            }
            native::NativeEvent::NewTab(url) => {
                if self.presentation == Presentation::Live && self.preview_request.is_none() {
                    cx.emit(BrowserEvent::NewTab(Some(url)));
                }
            }
            native::NativeEvent::Key { key, app } => {
                if self.presentation == Presentation::Live {
                    // An app shortcut (switch chat tab, split, …) moves on from
                    // the page: take the keyboard back, or the next Space or
                    // arrow still scrolls it.
                    if app {
                        native.release_focus();
                    }
                    window.focus(&self.focus, cx);
                    window.defer(cx, move |window, cx| {
                        window.dispatch_keystroke(key, cx);
                    });
                }
            }
            native::NativeEvent::Favicon { page, url } => {
                if self.page.url.as_deref() != Some(&page) || !model::allowed_navigation(&url) {
                    return;
                }
                let generation = self.favicon_generation;
                // reqwest's system proxy has no loopback exemption; a local dev
                // server's favicon must be fetched directly.
                let direct = url::Url::parse(&url).is_ok_and(|parsed| model::loopback(&parsed));
                let download = gpui_tokio::Tokio::spawn(cx, async move {
                    let mut builder = reqwest::Client::builder()
                        .timeout(std::time::Duration::from_secs(5))
                        .redirect(reqwest::redirect::Policy::limited(3));
                    if direct {
                        builder = builder.no_proxy();
                    }
                    let client = builder.build().ok()?;
                    let mut response =
                        client.get(url).send().await.ok()?.error_for_status().ok()?;
                    if response.content_length().is_some_and(|n| n > 1024 * 1024) {
                        return None;
                    }
                    let mut bytes = Vec::new();
                    while let Some(chunk) = response.chunk().await.ok()? {
                        if bytes.len() + chunk.len() > 1024 * 1024 {
                            return None;
                        }
                        bytes.extend_from_slice(&chunk);
                    }
                    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
                        .with_guessed_format()
                        .ok()?;
                    let mut limits = image::Limits::default();
                    limits.max_image_width = Some(1024);
                    limits.max_image_height = Some(1024);
                    limits.max_alloc = Some(8 * 1024 * 1024);
                    reader.limits(limits);
                    let icon = reader.decode().ok()?.thumbnail(32, 32);
                    let mut png = std::io::Cursor::new(Vec::new());
                    icon.write_to(&mut png, image::ImageFormat::Png).ok()?;
                    Some(png.into_inner())
                });
                self.favicon_task = Some(cx.spawn(async move |this, cx| {
                    let Ok(Some(bytes)) = download.await else {
                        return;
                    };
                    let _ = this.update(cx, |this, cx| {
                        if this.favicon_generation == generation
                            && this.page.url.as_deref() == Some(&page)
                        {
                            this.favicon = Some(std::sync::Arc::new(gpui::Image::from_bytes(
                                gpui::ImageFormat::Png,
                                bytes,
                            )));
                            cx.emit(BrowserEvent::Changed);
                            cx.notify();
                        }
                    });
                }));
            }
        }
    }
}

#[cfg(feature = "browser-fixture")]
impl BrowserSurface {
    /// Bypass only the file RPC for a synthetic fixture; document construction,
    /// native contexts, navigation policy and sandbox are production paths.
    pub fn fixture_document(
        &mut self,
        content: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        let request = crate::markdown::content_reference::HtmlPreview {
            path: "/workspace/fixture.html".into(),
            wide: true,
            compatibility: crate::markdown::content_reference::HtmlCompatibility::CodexVisualize,
        };
        let document = document::HtmlDocument::new(&request, content)?;
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            self.native = None;
            let mut native = native::NativePage::new_document(window, self.native_tx.clone())?;
            native.present(self.presentation);
            native.load_html(&document.html)?;
            self.page.url = Some(document.path.clone());
            self.page.title = document.title.clone();
            self.page.loading = true;
            self.document = Some(document);
            self.native = Some(native);
            cx.notify();
            Ok(())
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            let _ = (document, window, cx);
            Err("Native HTML previews are unavailable on this platform".into())
        }
    }
    pub fn fixture_history(&mut self, forward: bool) {
        self.history(forward);
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_move_cursor(&self, x: f64, y: f64) {
        self.native.as_ref().unwrap().fixture_move_cursor(x, y);
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_origin(&self) -> (f32, f32) {
        self.native.as_ref().unwrap().fixture_origin()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_overlay_visible(&self) -> bool {
        self.native.as_ref().unwrap().fixture_overlay_visible()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_visibility_changes(&self) -> u64 {
        self.native.as_ref().unwrap().fixture_visibility_changes()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_focus(&self) {
        self.native.as_ref().unwrap().fixture_focus();
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_navigation_gestures_enabled(&self) -> bool {
        self.native
            .as_ref()
            .unwrap()
            .fixture_navigation_gestures_enabled()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_focused(&self) -> bool {
        self.native.as_ref().unwrap().fixture_focused()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_overlay_at(&self, x: f64, y: f64) -> bool {
        self.native.as_ref().unwrap().fixture_overlay_at(x, y)
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_click(&self, x: f64, y: f64) {
        self.native.as_ref().unwrap().fixture_click(x, y);
    }
    pub fn fixture_native_visible(&self) -> bool {
        #[cfg(target_os = "macos")]
        {
            self.native
                .as_ref()
                .is_some_and(|native| native.fixture_visible())
        }
        #[cfg(target_os = "linux")]
        {
            self.presentation != Presentation::Hidden
                && self.native.as_ref().is_some_and(|n| n.image.is_some())
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            false
        }
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_backdrop_layers(&self) -> String {
        self.native.as_ref().unwrap().fixture_backdrop_layers()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_page_hit(&self, x: f64, y: f64) -> bool {
        self.native.as_ref().unwrap().fixture_page_hit(x, y)
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_backdrops(&self) -> Vec<(f64, f64, f64, f64)> {
        self.native.as_ref().unwrap().fixture_backdrops()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_geometry(&self) -> (f32, f32, f32) {
        self.native.as_ref().unwrap().fixture_geometry()
    }
    pub fn fixture_eval(&self, script: &str) {
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            native.fixture_eval(script);
        }
        #[cfg(target_os = "linux")]
        if let Some(native) = &self.native {
            native.evaluate(script);
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let _ = script;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[gpui::test]
    fn address_enter_rejects_unsupported_schemes_and_escape_restores_url(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(|cx| {
            gpui_base::init(cx);
            crate::composer::init(cx, Default::default());
            cx.set_global(crate::theme::Theme::default());
            bind_keys(cx, &crate::settings::KeymapConfig::default());
        });
        let window = cx.add_window(|window, cx| {
            BrowserSurface::new(BrowserContext::default(), false, window, cx)
        });
        window
            .update(cx, |browser, window, cx| {
                browser.page.url = Some("https://example.com/".into());
                browser
                    .address
                    .update(cx, |input, cx| input.set_text("javascript:alert(1)", cx));
                browser.focus_address(window, cx);
            })
            .unwrap();
        cx.simulate_keystrokes(window.into(), "enter");
        window
            .update(cx, |browser, _, _| {
                assert!(
                    browser.validation.is_some(),
                    "Enter did not reach browser address handling"
                );
                assert_eq!(browser.page.url.as_deref(), Some("https://example.com/"));
            })
            .unwrap();
        cx.simulate_keystrokes(window.into(), "escape");
        window
            .update(cx, |browser, window, cx| {
                assert!(browser.validation.is_none());
                assert_eq!(browser.address.read(cx).text(), "https://example.com/");
                assert!(browser.focus.is_focused(window));
                window.blur();
            })
            .unwrap();
    }

    #[gpui::test]
    fn customized_app_shortcuts_win_over_browser_defaults(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            let mut config = crate::settings::KeymapConfig::default();
            bind_keys(cx, &config);
            assert_eq!(
                cx.key_bindings()
                    .borrow()
                    .bindings_for_action(&FocusAddress)
                    .count(),
                1
            );
            assert_eq!(
                cx.key_bindings()
                    .borrow()
                    .bindings_for_action(&Reload)
                    .count(),
                1
            );
            cx.clear_key_bindings();
            config.toggle_sidebar = crate::settings::platform_combo("mod-l");
            config.toggle_changes = "mod-shift-r".into();
            bind_keys(cx, &config);
            assert_eq!(
                cx.key_bindings()
                    .borrow()
                    .bindings_for_action(&FocusAddress)
                    .count(),
                0
            );
            assert_eq!(
                cx.key_bindings()
                    .borrow()
                    .bindings_for_action(&Reload)
                    .count(),
                0
            );
            assert_eq!(
                cx.key_bindings()
                    .borrow()
                    .bindings_for_action(&NewTab)
                    .count(),
                1
            );
        });
    }

    /// The live "browser-frames" reader threads in this process.
    #[cfg(target_os = "linux")]
    fn browser_frame_threads() -> usize {
        std::fs::read_dir("/proc/self/task")
            .into_iter()
            .flatten()
            .flatten()
            .filter(|task| {
                std::fs::read_to_string(task.path().join("comm"))
                    .is_ok_and(|name| name.trim_end() == "browser-frames")
            })
            .count()
    }

    /// Stops every WebKit helper this process started, as a crash or a
    /// missing display does.
    #[cfg(target_os = "linux")]
    fn stop_webkit_helpers() {
        let parent = std::process::id().to_string();
        for process in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
            // "pid (comm) state ppid ..."; comm may itself contain ") ".
            let Ok(stat) = std::fs::read_to_string(process.path().join("stat")) else {
                continue;
            };
            let Some((head, tail)) = stat.rsplit_once(") ") else {
                continue;
            };
            let helper = head
                .split_once(" (")
                .is_some_and(|(_, comm)| comm.starts_with("webkit-"));
            if helper && tail.split(' ').nth(1) == Some(parent.as_str()) {
                let _ = std::process::Command::new("kill")
                    .args(["-9", &process.file_name().to_string_lossy()])
                    .status();
            }
        }
    }

    /// A WebKit helper that stops while its page is open (it crashed, or found
    /// no display, as on CI) is reported by its "browser-frames" reader
    /// thread, which wakes the page's event task from that thread. GPUI's test
    /// scheduler fails a test when that happens, so tests that open a page,
    /// such as `queued_browser_navigation_and_close_batches_obey_delivery_order`,
    /// failed whenever a helper exited before they finished. Here the helper
    /// always stops mid-test.
    #[cfg(target_os = "linux")]
    #[gpui::test]
    fn a_browser_helper_stopping_mid_test_cannot_wake_the_test_scheduler(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(|cx| {
            gpui_base::init(cx);
            crate::composer::init(cx, Default::default());
            cx.set_global(crate::theme::Theme::default());
        });
        let window = cx.add_window(|window, cx| {
            BrowserSurface::new(BrowserContext::default(), false, window, cx)
        });
        window
            .update(cx, |browser, window, cx| {
                browser.navigate("https://example.com/", window, cx)
            })
            .unwrap();
        // The page's event task now waits on its channel, as it does between
        // any two steps of a test.
        cx.run_until_parked();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            stop_webkit_helpers();
            if browser_frame_threads() == 0 {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "a browser-frames thread outlived its helper"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        cx.run_until_parked();
    }
}
