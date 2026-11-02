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
mod search;
mod search_suggestions;
mod view;

use crate::composer::{ComposerInput, ComposerInputEvent};
use gpui::{
    AnyWindowHandle, App, AppContext, Context, Entity, EventEmitter, FocusHandle, Focusable,
    Subscription, Window,
};
use model::{PageState, Presentation};

// Match the inside of the workspace panel's one-pixel outline.
const BROWSER_SURFACE_RADIUS: f32 = 9.0;
const BROWSER_ADDRESS_TEXT_SIZE: f32 = 13.0;
const BROWSER_ADDRESS_LINE_HEIGHT: f32 = 20.0;
gpui::actions!(
    browser,
    [Reload, FocusAddress, NewTab, CloseTab, Back, Forward]
);

fn shortcut_available(
    keymap: &crate::settings::KeymapConfig,
    combo: &str,
    own: Option<crate::settings::ShortcutId>,
) -> bool {
    use crate::settings::{ShortcutId, platform_combo};
    // Existing customized app chords win. In particular old settings may
    // already assign mod-shift-r to the right pane.
    !combo.is_empty()
        && gpui::Keystroke::parse(&platform_combo(combo)).is_ok()
        && !ShortcutId::ALL.iter().any(|id| {
            Some(*id) != own
                // The default new-chat key remains contextual: in a browser,
                // Cmd+T opens a browser tab. Custom app chords still win.
                && !(*id == ShortcutId::NewSession
                    && keymap.get(*id) == id.default_combo())
                && gpui::Keystroke::parse(&platform_combo(keymap.get(*id))).ok()
                    == gpui::Keystroke::parse(&platform_combo(combo)).ok()
        })
}

#[derive(Clone, Copy)]
enum NavigationShortcut {
    Back,
    Forward,
    Reload,
}

impl NavigationShortcut {
    /// Use the same availability rules for the hover hint and key registration.
    fn combo(self, keymap: &crate::settings::KeymapConfig) -> Option<&str> {
        use crate::settings::ShortcutId;
        let (combo, own) = match self {
            Self::Back => ("mod-[", None),
            Self::Forward => ("mod-]", None),
            Self::Reload => (
                keymap.get(ShortcutId::BrowserReload),
                Some(ShortcutId::BrowserReload),
            ),
        };
        shortcut_available(keymap, combo, own).then_some(combo)
    }
}

pub(crate) fn bind_keys(cx: &mut App, keymap: &crate::settings::KeymapConfig) {
    use crate::settings::platform_combo;
    macro_rules! bind {
        ($combo:literal, $action:ident) => {
            if shortcut_available(keymap, $combo, None) {
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
    macro_rules! bind_navigation {
        ($action:ident) => {
            if let Some(combo) = NavigationShortcut::$action.combo(keymap) {
                cx.bind_keys([gpui::KeyBinding::new(
                    &platform_combo(combo),
                    $action,
                    Some("Browser"),
                )]);
            }
        };
    }
    bind_navigation!(Back);
    bind_navigation!(Forward);
    bind_navigation!(Reload);
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
    forward_reveal: crate::motion::HoverFades,
    search: search::SearchSuggestions,
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
    #[cfg(feature = "browser-fixture")]
    fixture_forward_control:
        std::rc::Rc<std::cell::Cell<(f32, Option<gpui::Bounds<gpui::Pixels>>)>>,
    presentation: Presentation,
    #[cfg(target_os = "macos")]
    resize_inset: gpui::Pixels,
    #[cfg(target_os = "macos")]
    right_occlusion: gpui::Pixels,
    _input_sub: Subscription,
    _address_focus_subs: [Subscription; 2],
    owning_window: std::rc::Rc<std::cell::Cell<AnyWindowHandle>>,
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
            ComposerInput::with_context("Search or enter address", "PaletteSearch", cx)
                .with_text_metrics(BROWSER_ADDRESS_TEXT_SIZE, BROWSER_ADDRESS_LINE_HEIGHT)
                .with_single_line()
                .with_accessibility_role(gpui::Role::TextInput)
        });
        let input_sub = cx.subscribe(&address, |this, _, event, cx| {
            if matches!(event, ComposerInputEvent::Edited) {
                this.address_edited =
                    this.address.read(cx).text() != this.page.url.as_deref().unwrap_or_default();
                this.validation = None;
                this.update_search_suggestions(cx);
                cx.notify();
            } else if matches!(event, ComposerInputEvent::CursorMoved)
                && this.search.composing
                && !this.address.read(cx).has_marked_text()
            {
                this.update_search_suggestions(cx);
            }
        });
        let address_focus_subs = Self::observe_address_focus(&address, window, cx);
        let owning_window = std::rc::Rc::new(std::cell::Cell::new(window.window_handle()));
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        let (native_tx, mut events) = tokio::sync::mpsc::channel(64);
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        let event_window = owning_window.clone();
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        let native_task = cx.spawn(async move |this, cx| {
            while let Some(event) = events.recv().await {
                if this.upgrade().is_none() {
                    break;
                }
                // Resolve the current window for every event. A transferred
                // page outlives its original window, including pending loads.
                let _ = event_window.get().update(cx, |_, window, cx| {
                    this.update(cx, |this, cx| this.on_native_event(event, window, cx))
                });
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
            forward_reveal: crate::motion::HoverFades::with_spec(crate::motion::MotionSpec::new(
                180,
                crate::motion::EASE_OUT_QUINT,
            )),
            search: Default::default(),
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
            #[cfg(feature = "browser-fixture")]
            fixture_forward_control: Default::default(),
            presentation: Presentation::Hidden,
            #[cfg(target_os = "macos")]
            resize_inset: gpui::px(0.0),
            #[cfg(target_os = "macos")]
            right_occlusion: gpui::px(0.0),
            _input_sub: input_sub,
            _address_focus_subs: address_focus_subs,
            owning_window,
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

    fn observe_address_focus(
        address: &Entity<ComposerInput>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> [Subscription; 2] {
        let focus = address.focus_handle(cx);
        [
            cx.on_focus(&focus, window, |this, _, cx| {
                this.search.focused = true;
                this.update_search_suggestions(cx);
                cx.notify();
            }),
            cx.on_blur(&focus, window, |this, _, cx| {
                this.search.focused = false;
                this.dismiss_search_suggestions(cx);
            }),
        ]
    }

    /// Move the live page and its chrome to another app window. The same
    /// native page retains history, form values, scroll position and scripts.
    pub fn move_to_window(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        if self.owning_window.get() == window.window_handle() {
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            native.move_to_window(window)?;
        }
        self.owning_window.set(window.window_handle());
        self._address_focus_subs = Self::observe_address_focus(&self.address, window, cx);
        self.search.focused = false;
        self.dismiss_search_suggestions(cx);
        #[cfg(target_os = "linux")]
        if let Some(native) = &mut self.native {
            native.move_to_window();
        }
        cx.notify();
        Ok(())
    }

    /// Explicit drag cancellation may return the keyboard to the same live
    /// page. Normal modal and address focus paths never call this method.
    pub fn restore_page_focus_after_drag(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        #[cfg(target_os = "macos")]
        if self
            .native
            .as_ref()
            .is_some_and(|native| native.restore_page_focus_after_drag())
        {
            window.focus(&self.focus, cx);
            cx.notify();
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (window, cx);
    }

    pub fn prepare_window_drag(&self) {
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            native.prepare_window_drag();
        }
    }

    pub fn discard_page_focus_after_drag(&self) {
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            native.discard_page_focus_after_drag();
        }
    }

    /// Capture the actual page for a drag preview without creating another
    /// browser or navigating. The image can outlive either host window.
    pub fn snapshot(
        &self,
        cx: &mut Context<Self>,
    ) -> gpui::Task<Option<std::sync::Arc<gpui::RenderImage>>> {
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native {
            let capture = native.snapshot();
            return cx.background_executor().spawn(async move {
                let bytes = capture.await.ok().flatten()?;
                let mut image =
                    image::load_from_memory_with_format(&bytes, image::ImageFormat::Tiff)
                        .ok()?
                        .thumbnail(1200, 1200)
                        .into_rgba8();
                // GPUI's atlas consumes BGRA pixels, including RenderImage.
                for pixel in image.pixels_mut() {
                    pixel.0.swap(0, 2);
                }
                Some(std::sync::Arc::new(gpui::RenderImage::new([
                    image::Frame::new(image),
                ])))
            });
        }
        #[cfg(target_os = "linux")]
        if let Some(native) = &self.native {
            return gpui::Task::ready(native.image.clone());
        }
        let _ = cx;
        gpui::Task::ready(None)
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
        cx.notify();
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
        if presentation != Presentation::Live {
            self.dismiss_search_suggestions(cx);
        }
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
    #[cfg(feature = "browser-fixture")]
    pub fn fixture_forward_control(&self) -> (f32, Option<gpui::Bounds<gpui::Pixels>>) {
        self.fixture_forward_control.get()
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
        self.dismiss_search_suggestions(cx);
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
            let kind = self
                .view
                .as_ref()
                .map(|view| view.kind)
                .unwrap_or(harness_proto::ToolViewKind::Html);
            let result = native::NativePage::new_view(window, kind, self.native_tx.clone())
                .and_then(|mut native| {
                    native.present(self.presentation);
                    let loaded = native.load(&url);
                    self.native = Some(native);
                    loaded
                });
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
        _window: &mut Window,
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
        let document_window = self.owning_window.clone();
        self.document_task = Some(cx.spawn(async move |this, cx| {
            let result = read.await.map_err(|error| error.to_string()).and_then(|result| result);
            let _ = document_window.get().update(cx, |_, window, cx| this.update(cx, |this, cx| {
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
            }));
        }));
        cx.emit(BrowserEvent::Changed);
        cx.notify();
    }

    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.view.is_some() || self.preview_request.is_some() {
            return;
        }
        match model::address_or_search(self.address.read(cx).text()) {
            Ok(url) => self.navigate(&url, window, cx),
            Err(message) => {
                self.validation = Some(message.into());
                cx.notify();
            }
        }
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

    pub(crate) fn external_action_label(&self) -> Option<&'static str> {
        if self.preview_request.is_some() {
            Some("Open source file")
        } else if self
            .page
            .url
            .as_deref()
            .is_some_and(model::allowed_navigation)
        {
            Some("Open in default browser")
        } else {
            None
        }
    }

    pub(crate) fn open_external(&self, cx: &mut Context<Self>) {
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
    pub fn fixture_native_identity(&self) -> Option<usize> {
        self.native.as_ref().map(|native| native.fixture_identity())
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
    pub fn fixture_focused(&self) -> bool {
        self.native.as_ref().unwrap().fixture_focused()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_focus_state(&self) -> serde_json::Value {
        self.native
            .as_ref()
            .map(|native| native.fixture_focus_state())
            .unwrap_or_default()
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
    #[cfg(target_os = "macos")]
    pub fn fixture_inspector(&self, action: &str) -> bool {
        self.native.as_ref().unwrap().fixture_inspector(action)
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_inspector_geometry(&self) -> serde_json::Value {
        self.native.as_ref().unwrap().fixture_inspector_geometry()
    }
    #[cfg(target_os = "macos")]
    pub fn fixture_set_user_agent(&self, user_agent: Option<&str>) {
        if let Some(native) = &self.native {
            native.fixture_set_user_agent(user_agent);
        }
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
    fn browser_transfer_rebinds_address_focus_after_source_window_closes(
        cx: &mut gpui::TestAppContext,
    ) {
        use gpui::{ParentElement, Render, Styled, div};

        struct BrowserHost(Option<Entity<BrowserSurface>>);
        impl Render for BrowserHost {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl gpui::IntoElement {
                div().size_full().children(self.0.clone())
            }
        }
        fn draw(window: gpui::AnyWindowHandle, cx: &mut gpui::TestAppContext) {
            cx.update_window(window, |_, window, cx| window.draw(cx).clear())
                .unwrap();
            cx.run_until_parked();
        }

        cx.update(|cx| {
            gpui_base::init(cx);
            crate::composer::init(cx, Default::default());
            cx.set_global(crate::theme::Theme::default());
        });
        let source = cx.add_window(|window, cx| {
            BrowserHost(Some(cx.new(|cx| {
                BrowserSurface::new(BrowserContext::default(), false, window, cx)
            })))
        });
        let browser = source
            .update(cx, |host, window, cx| {
                window.activate_window();
                let browser = host.0.as_ref().unwrap().clone();
                browser.update(cx, |browser, cx| {
                    browser.page.url = Some("https://example.com/preserved".into());
                    browser
                        .address
                        .update(cx, |input, cx| input.set_text("an unfinished search", cx));
                    browser.focus_address(window, cx);
                });
                browser
            })
            .unwrap();
        draw(source.into(), cx);
        browser.read_with(cx, |browser, _| assert!(browser.search.focused));
        let destination = cx.add_window(|_, _| BrowserHost(None));
        draw(destination.into(), cx);
        destination
            .update(cx, |host, window, cx| {
                window.activate_window();
                browser.update(cx, |browser, cx| {
                    browser.move_to_window(window, cx).unwrap();
                    browser.focus_address(window, cx);
                });
                host.0 = Some(browser.clone());
                cx.notify();
            })
            .unwrap();
        source
            .update(cx, |host, _, cx| {
                host.0 = None;
                cx.notify();
            })
            .unwrap();
        draw(destination.into(), cx);
        browser.read_with(cx, |browser, cx| {
            assert!(browser.search.focused);
            assert_eq!(browser.address.read(cx).text(), "an unfinished search");
            assert_eq!(
                browser.page.url.as_deref(),
                Some("https://example.com/preserved")
            );
        });
        source
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        draw(destination.into(), cx);
        browser.read_with(cx, |browser, _| assert!(browser.search.focused));
        destination
            .update(cx, |_, window, _| window.blur())
            .unwrap();
        draw(destination.into(), cx);
        browser.read_with(cx, |browser, _| assert!(!browser.search.focused));
        destination
            .update(cx, |_, window, cx| {
                browser.update(cx, |browser, cx| browser.focus_address(window, cx));
            })
            .unwrap();
        draw(destination.into(), cx);
        browser.read_with(cx, |browser, _| assert!(browser.search.focused));
    }

    #[gpui::test]
    fn navigation_shortcut_hints_match_registered_keys(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            let mut config = crate::settings::KeymapConfig::default();
            let scenarios = [
                ("mod-shift-r", "mod-b", "mod-r", [true, true, true]),
                ("mod-alt-r", "mod-b", "mod-r", [true, true, true]),
                ("mod-alt-r", "mod-[", "mod-]", [false, false, true]),
                ("mod-alt-r", "mod-alt-r", "mod-r", [true, true, false]),
                ("", "mod-b", "mod-r", [true, true, false]),
                ("bogus-r", "mod-b", "mod-r", [true, true, false]),
            ];
            for (reload, sidebar, changes, expected) in scenarios {
                config.browser_reload = reload.into();
                config.toggle_sidebar = sidebar.into();
                config.toggle_changes = changes.into();
                cx.clear_key_bindings();
                bind_keys(cx, &config);
                let actions: [(NavigationShortcut, &dyn gpui::Action); 3] = [
                    (NavigationShortcut::Back, &Back),
                    (NavigationShortcut::Forward, &Forward),
                    (NavigationShortcut::Reload, &Reload),
                ];
                for ((shortcut, action), expected) in actions.into_iter().zip(expected) {
                    let advertised = shortcut.combo(&config);
                    assert_eq!(advertised.is_some(), expected);
                    let keymap = cx.key_bindings();
                    let keymap = keymap.borrow();
                    let bindings = keymap.bindings_for_action(action).collect::<Vec<_>>();
                    assert_eq!(bindings.len(), usize::from(expected));
                    if let Some(combo) = advertised {
                        assert_eq!(bindings[0].keystrokes().len(), 1);
                        assert_eq!(
                            bindings[0].keystrokes()[0].unparse(),
                            gpui::Keystroke::parse(&crate::settings::platform_combo(combo))
                                .unwrap()
                                .unparse(),
                        );
                    }
                }
                assert_eq!(
                    NavigationShortcut::Reload.combo(&config),
                    expected[2].then_some(reload),
                );
            }
        });
    }

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
}
