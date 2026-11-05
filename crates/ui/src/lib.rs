//! harness-ui — the gpui viewport. Shell, sidebar, conversation, composer, terminal,
//! diff pane.
//!
//! Design: ARCHITECTURE.md §4; animation catalog docs/research/feature-inventory.md
//! §1.12; virtualization/markdown techniques docs/research/mugen-pretext.md.
//!
//! M3a foundation:
//! - [`theme`] — always-dark monochrome theme (oklch-derived neutrals), a gpui Global;
//! - [`motion`] — the harness animation catalog over gpui `Animation` + cubic-bezier;
//! - [`state`] — `AppState` entity + `EngineHandle` (connect-or-embed engine);
//! - [`settings`] — persisted pane widths/collapse flags;
//! - [`shell`] — sidebar + main panel + right-pane scaffold + gate;
//! - [`loaders`] — harness pulse loader, gradient spinner, boot splash.

mod agent_message;
pub mod agent_work;
pub mod tool_access;
pub mod tool_call_rows;
pub mod annotate;
pub mod app_menus;
pub mod appearance;
pub mod appshots;
pub mod attachments;
pub mod badges;
pub mod browser;
mod build_wait;
pub mod change_requests;
pub mod changes;
pub(crate) mod chat_mode;
pub(crate) mod chatgpt_plan;
pub mod codegraff_jobs;
pub mod codegraff_runners;
pub mod codegraff_sandboxes;
mod comment_ui;
pub mod comments;
pub mod composer;
mod composer_dock;
mod composer_markdown;
pub mod context_trajectory;
pub mod context_usage;
pub mod context_window;
pub mod dial_panel;
pub mod edge_fade;
pub mod file_icons;
pub mod files;
pub mod frost;
pub mod history;
pub mod icons;
pub(crate) mod image_media;
pub(crate) mod image_viewer;
pub mod links;
pub mod loaders;
pub mod markdown;
pub mod motion;
mod new_thread_background_effects;
mod new_thread_background_image;
mod new_thread_background_mask;
mod notice;
pub mod notify;
pub mod perf_stats;

/// Tests that stand up real native platform pieces (CoreText via
/// `current_platform`, the macOS dispatcher behind `background_executor`)
/// abort the whole test process when two initialize concurrently; each such
/// test holds this for its duration.
#[cfg(test)]
pub(crate) static NATIVE_PLATFORM_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
pub mod pickers;
pub mod popover;
pub mod project_actions;
pub mod queue;
pub mod reauth_recovery;
pub mod rail;
pub(crate) mod screen_access;
pub mod settings;
pub mod shell;
mod sidebar_motion;
pub mod sound;
pub mod stall_watch;
pub(crate) mod starters;
pub mod state;
pub(crate) mod surface_chrome;
pub mod syntax_cache;
pub mod terminal;
pub mod theme;
pub mod theme_library;
pub mod transcript;
mod transcript_paint_check;
pub mod typography;
pub mod visuals;
mod workspace_links;
pub mod write_markdown;

use std::path::PathBuf;

use futures::{FutureExt as _, StreamExt as _};
use gpui::{App, AppContext as _, Bounds, TitlebarOptions, WindowBounds, WindowOptions, px, size};

pub use state::EngineBootConfig;
pub use harness_proto::HarnessId;

/// Whether a control whose primary action is click activation may also start
/// a GPUI drag from the same hitbox. GPUI promotes pointer travel above 2 px
/// to a drag. Normal Windows click jitter can cross that threshold, cancel the
/// click, and leave the drag ghost following the pointer instead of activating
/// the control. Drag-first controls (resize handles, scrollbars, queue rows)
/// intentionally do not use this policy.
pub(crate) const fn click_activation_drag_enabled() -> bool {
    !cfg!(target_os = "windows")
}

/// Everything the headed binary passes in (config/env resolution lives in
/// `apps/harness`, not here).
#[derive(Debug, Clone)]
pub struct UiConfig {
    /// Data directory — engine stores + `ui-settings.json`.
    pub data_dir: PathBuf,
    /// Localhost IPC port: connect if an engine daemon is listening, embed if not.
    pub ipc_port: u16,
    /// Edge base URL for the embedded engine.
    pub edge_url: String,
    /// Edge bearer; `None` runs offline.
    pub edge_token: Option<String>,
    /// Workspace org override for explicit dev-mode runs.
    pub org_id: Option<String>,
    /// CodeGraff client id; `Some` makes the embedded headed engine require a
    /// production session before opening identity-scoped stores.
    pub codegraff_client_id: Option<String>,
    /// Harness for doc-command runs until per-chat config lands (M4).
    pub default_harness: HarnessId,
    /// Conversation URL passed by the OS on a cold launch.
    pub initial_url: Option<String>,
}

impl UiConfig {
    fn boot(&self) -> EngineBootConfig {
        EngineBootConfig {
            data_dir: self.data_dir.clone(),
            ipc_port: self.ipc_port,
            edge_url: self.edge_url.clone(),
            edge_token: self.edge_token.clone(),
            org_id: self.org_id.clone(),
            codegraff_client_id: self.codegraff_client_id.clone(),
            default_harness: self.default_harness,
        }
    }
}

/// What a dock-icon reopen needs to rebuild the main window after ⌘W closed it
/// (macOS keeps the process alive with just the menu bar, like zed).
struct ReopenState {
    state: gpui::Entity<state::AppState>,
    boot: EngineBootConfig,
}

impl gpui::Global for ReopenState {}

#[derive(Default)]
struct WorkspaceWindows {
    ids: std::collections::HashMap<gpui::WindowId, String>,
    quitting: bool,
}

impl gpui::Global for WorkspaceWindows {}

fn init_workspace_windows(cx: &mut App) {
    if cx.has_global::<WorkspaceWindows>() {
        return;
    }
    cx.set_global(WorkspaceWindows::default());
    cx.on_window_closed(|cx, window| {
        let windows = cx.global_mut::<WorkspaceWindows>();
        let id = windows.ids.remove(&window);
        if !windows.quitting
            && let Some(id) = id
        {
            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                settings.remove_workspace_window(&id);
            });
        }
    })
    .detach();
}

/// Run the headed app: tokio bridge up, engine bootstrap kicked off (probe →
/// connect-or-embed), 1320×880 window (min 900×600) with [`shell::Shell`] as the
/// root view, boot splash overlaid until the engine reports ready.
pub fn run_app(config: UiConfig) {
    perf_stats::mark_process_start();
    // Retain ownership for the whole application lifetime. The bridge's
    // default runtime has only two workers, insufficient for a desktop engine.
    let runtime = tokio::runtime::Runtime::new().expect("desktop Tokio runtime");
    let runtime_handle = runtime.handle().clone();
    let app = gpui_platform::application().with_assets(icons::Assets);
    let (url_tx, mut url_rx) = futures::channel::mpsc::unbounded::<String>();
    let callback_tx = url_tx.clone();
    app.on_open_urls(move |urls| {
        for url in urls {
            let _ = callback_tx.unbounded_send(url);
        }
    });
    if let Some(url) = config.initial_url.clone() {
        let _ = url_tx.unbounded_send(url);
    }
    // Dock-icon click with no window (⌘W closed it): rebuild the main window
    // around the still-running engine — zed does the same via `on_reopen`
    // (crates/zed/src/main.rs `app.on_reopen`).
    app.on_reopen(|cx| {
        if cx.windows().is_empty()
            && let Some(reopen) = cx.try_global::<ReopenState>()
        {
            let (state, boot) = (reopen.state.clone(), reopen.boot.clone());
            open_main_window(state, boot, cx);
        }
    });
    app.run(move |cx: &mut App| {
        gpui_tokio::init_from_handle(cx, runtime_handle);
        gpui_base::init(cx);
        let data_dir = config.boot().data_dir.clone();
        let ui_settings = settings::UiSettings::load(&data_dir);
        settings::init(ui_settings.clone(), data_dir.clone(), cx);
        let font_availability = typography::register_fonts(cx);
        // Typography first: theme installation reads the effective family, so
        // the first frame has the final font and palette without a flash.
        typography::init(
            ui_settings.ui_font_family.clone(),
            ui_settings.ui_font_size,
            ui_settings.terminal_font_family.clone(),
            ui_settings.terminal_font_size,
            ui_settings.code_font_family.clone(),
            ui_settings.code_font_size,
            font_availability,
            cx,
        );
        theme_library::init(data_dir.clone(), cx);
        appearance::init(
            ui_settings.appearance,
            ui_settings.theme_selection,
            ui_settings.accent,
            ui_settings.surface,
            cx,
        );
        history::init(
            ui_settings.git_history_columns,
            ui_settings.git_history_column_widths,
            ui_settings.git_history_column_order,
            ui_settings.git_history_author_display,
            cx,
        );
        motion::init(
            ui_settings.reduce_motion,
            ui_settings.pause_animations_in_background,
            cx,
        );
        composer::init(cx, ui_settings.composer_send_behavior);
        appshots::set_enabled(ui_settings.appshots_enabled);
        terminal::panel::init(cx);
        app_menus::init(cx);
        // An isolated local preview must never replace the installed app's link handler.
        if !(cfg!(debug_assertions)
            && std::env::var("HARNESS_RECONCILIATION_PREVIEW").as_deref() == Ok("1"))
        {
            cx.register_url_scheme("harness").detach();
        }

        let state = cx.new(|_| state::AppState::new());
        perf_stats::start(data_dir.clone(), state.clone(), cx);
        stall_watch::start(data_dir.join("logs"), cx);
        let url_state = state.clone();
        cx.spawn(async move |cx| {
            while let Some(url) = url_rx.next().await {
                let _ = cx.update(|cx| open_workspace_deep_link(&url, &url_state, cx));
            }
        })
        .detach();
        // Banner clicks land on the notified chat (or, for a CodeGraff job's
        // banner, open its https page). The AppKit delegate fires mid-event,
        // so hop through a channel rather than updating inline.
        let (click_tx, mut click_rx) = futures::channel::mpsc::unbounded::<String>();
        notify::on_click(move |chat_id| {
            let _ = click_tx.unbounded_send(chat_id);
        });
        let click_state = state.clone();
        cx.spawn(async move |cx| {
            while let Some(chat_id) = click_rx.next().await {
                let _ = cx.update(|cx| {
                    if chat_id.starts_with("https://") {
                        cx.open_url(&chat_id);
                    } else {
                        open_notified_chat(chat_id, &click_state, cx);
                    }
                });
            }
        })
        .detach();
        state::AppState::bootstrap(state.clone(), config.boot(), cx);
        codegraff_jobs::watch(state.clone(), cx);

        // Graceful teardown: an in-process engine drains live runs and flushes
        // doc snapshots before the process exits (remote engines outlive us).
        let quit_state = state.clone();
        cx.on_app_quit(move |cx| {
            if cx.has_global::<WorkspaceWindows>() {
                cx.global_mut::<WorkspaceWindows>().quitting = true;
            }
            for handle in cx.windows() {
                if let Some(handle) = handle.downcast::<shell::Shell>() {
                    let _ = handle.update(cx, |shell, window, cx| {
                        shell.save_window_record(cx);
                        save_workspace_window_geometry(shell.window_id(), window, cx);
                    });
                }
            }
            settings::flush(cx);
            let shutdown =
                quit_state.read(cx).engine().cloned().map(|handle| {
                    gpui_tokio::Tokio::spawn(cx, async move { handle.shutdown().await })
                });
            async move {
                if let Some(task) = shutdown {
                    let _ = task.await;
                }
            }
        })
        .detach();

        cx.set_global(ReopenState {
            state: state.clone(),
            boot: config.boot(),
        });
        // A restart into an update left a note: confirm the version once, and
        // come back behind the app the person was using if it restarted while
        // they were away from Harness.
        let relaunch = shell::take_relaunch_marker(&config.boot().data_dir);
        let relaunched_in_background = relaunch.as_ref().is_some_and(|marker| marker.background);
        cx.set_global(shell::UpdateRelaunched(relaunch));
        let records = settings::current(cx).restorable_workspace_windows();
        for error in restore_startup_windows(records, |record, primary| {
            let window_state = if primary {
                state.clone()
            } else {
                cx.new(|cx| state::AppState::for_window(&state, cx))
            };
            open_workspace_window(window_state, config.boot(), record, cx).map(|_| ())
        }) {
            tracing::error!(%error, "could not open startup workspace window");
        }
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        start_appshot_service(config.boot().data_dir, cx);
        // Native menu bar — macOS gets the standard app menu (About/Services/
        // Hide/Quit ⌘Q), Edit clipboard verbs routed to the focused input, and
        // a Window menu (⌘M/⌘W). Without this, `NSApp.mainMenu` stays nil: no
        // Cmd+Q, and nothing for the system menu bar to show. Set after
        // `open_main_window` because `Shell::new` ran `apply_keymap`
        // synchronously, so `set_menus` reads the final bindings for the ⌘-key
        // equivalents (gpui snapshots the keymap at set time).
        cx.set_menus(app_menus::app_menus());
        if !relaunched_in_background {
            cx.activate(true);
        }
    });
}

/// Try each saved window once, retaining failed records in settings. If none
/// opens, start an independent blank window instead of retrying a failed record.
fn restore_startup_windows<E>(
    records: Vec<settings::SavedWorkspaceWindow>,
    mut open: impl FnMut(settings::SavedWorkspaceWindow, bool) -> Result<(), E>,
) -> Vec<E> {
    let mut opened = 0;
    let mut errors = Vec::new();
    for record in records {
        match open(record, opened == 0) {
            Ok(()) => opened += 1,
            Err(error) => errors.push(error),
        }
    }
    if opened == 0 {
        let fresh = settings::SavedWorkspaceWindow {
            id: uuid::Uuid::new_v4().to_string(),
            ..Default::default()
        };
        if let Err(error) = open(fresh, true) {
            errors.push(error);
        }
    }
    errors
}

/// A clicked banner: bring Harness forward on that chat through the sidebar's
/// own path (chat route + composer focus), reopening the main window first if
/// ⌘W closed it.
fn open_notified_chat(chat_id: String, state: &gpui::Entity<state::AppState>, cx: &mut App) {
    cx.activate(true);
    if cx.windows().is_empty()
        && let Some(reopen) = cx.try_global::<ReopenState>()
    {
        let (state, boot) = (reopen.state.clone(), reopen.boot.clone());
        open_main_window(state, boot, cx);
    }
    match frontmost_workspace_window(cx) {
        Some(shell) => {
            let _ = shell.update(cx, |shell, window, cx| {
                if shell.reveal_chat_in_other_window(&chat_id, window, cx) {
                    return;
                }
                window.activate_window();
                shell.open_chat_preserving_tabs(chat_id, cx);
            });
        }
        None => state.update(cx, |state, cx| state.select_chat(Some(chat_id), cx)),
    }
}

fn frontmost_workspace_window(cx: &App) -> Option<gpui::WindowHandle<shell::Shell>> {
    cx.window_stack()
        .unwrap_or_else(|| cx.windows())
        .into_iter()
        .find_map(|window| window.downcast::<shell::Shell>())
}

fn open_workspace_deep_link(url: &str, state: &gpui::Entity<state::AppState>, cx: &mut App) {
    cx.activate(true);
    if frontmost_workspace_window(cx).is_none()
        && let Some(reopen) = cx.try_global::<ReopenState>()
    {
        let (state, boot) = (reopen.state.clone(), reopen.boot.clone());
        open_main_window(state, boot, cx);
    }
    if let Some(window) = frontmost_workspace_window(cx) {
        let _ = window.update(cx, |shell, window, cx| {
            window.activate_window();
            shell.open_window_deep_link(url, cx);
        });
    } else {
        state.update(cx, |state, cx| state.open_deep_link(url, cx));
    }
}

fn restored_workspace_window_bounds(
    saved: Option<settings::WindowGeometry>,
    cx: &App,
) -> (Bounds<gpui::Pixels>, Option<gpui::DisplayId>) {
    let fallback = (Bounds::centered(None, size(px(1320.), px(880.)), cx), None);
    let Some(saved) = saved else {
        return fallback;
    };
    let displays = cx.displays();
    let primary = cx
        .primary_display()
        .and_then(|primary| {
            displays
                .iter()
                .position(|display| display.id() == primary.id())
        })
        .unwrap_or(0);
    let geometries: Vec<_> = displays
        .iter()
        .map(|display| {
            let mut geometry = settings::WindowGeometry::from_bounds(display.visible_bounds());
            geometry.display_uuid = display.uuid().ok();
            geometry
        })
        .collect();
    saved
        .restore(&geometries, primary)
        .map_or(fallback, |(index, geometry)| {
            (geometry.bounds(), Some(displays[index].id()))
        })
}

fn save_workspace_window_geometry(id: &str, window: &gpui::Window, cx: &mut App) {
    if window.is_fullscreen() {
        return;
    }
    // macos infers maximization from screen-sized bounds, including ordinary
    // windows; other desktop backends report a distinct maximized variant.
    let WindowBounds::Windowed(bounds) = window.window_bounds() else {
        return;
    };
    let mut geometry = settings::WindowGeometry::from_bounds(bounds);
    geometry.display_uuid = window.display(cx).and_then(|display| display.uuid().ok());
    if geometry.is_valid() {
        settings::update(settings::SavePolicy::Debounced, cx, |settings| {
            if let Some(record) = settings
                .workspace_windows
                .as_mut()
                .and_then(|windows| windows.iter_mut().find(|window| window.id == id))
            {
                record.geometry = Some(geometry);
            }
        });
    }
}

fn observe_workspace_window_geometry<T: 'static>(
    id: String,
    window: &mut gpui::Window,
    cx: &gpui::Context<T>,
) {
    cx.observe_window_bounds(window, move |_, window, cx| {
        save_workspace_window_geometry(&id, window, cx);
    })
    .detach();
}

/// Resolve a release position into the target display's coordinate space.
/// AppKit's display bounds are local to each screen, so adding the source
/// window origin alone would place a cross-display drop on the wrong screen.
pub(crate) fn workspace_window_geometry_at(
    pointer: gpui::Point<gpui::Pixels>,
    anchor: gpui::Point<gpui::Pixels>,
    source: &gpui::Window,
    cx: &App,
) -> Option<settings::WindowGeometry> {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        use objc2::{MainThreadOnly, msg_send};
        use objc2_app_kit::{NSScreen, NSView};
        use objc2_foundation::{NSPoint, ns_string};
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};

        let handle = HasWindowHandle::window_handle(source).ok()?;
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
            return None;
        };
        let view = unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() };
        let native_window = view.window()?;
        let global = native_window.convertPointToScreen(NSPoint::new(
            f64::from(f32::from(pointer.x)),
            f64::from(f32::from(source.viewport_size().height - pointer.y)),
        ));
        let screen = NSScreen::screens(view.mtm())
            .iter()
            .find(|screen| {
                let frame = screen.frame();
                global.x >= frame.origin.x
                    && global.y >= frame.origin.y
                    && global.x < frame.origin.x + frame.size.width
                    && global.y < frame.origin.y + frame.size.height
            })
            .or_else(|| native_window.screen())?;
        let frame = screen.frame();
        let description: *mut objc2::runtime::AnyObject =
            unsafe { msg_send![&*screen, deviceDescription] };
        let number: *mut objc2::runtime::AnyObject =
            unsafe { msg_send![description, objectForKey: ns_string!("NSScreenNumber")] };
        if number.is_null() {
            return None;
        }
        let number: u32 = unsafe { msg_send![number, unsignedIntValue] };
        let display = cx
            .displays()
            .into_iter()
            .find(|display| display.id() == gpui::DisplayId::new(u64::from(number)))?;
        let mut visible = settings::WindowGeometry::from_bounds(display.visible_bounds());
        visible.display_uuid = display.uuid().ok();
        let bounds = source.bounds();
        Some(
            settings::WindowGeometry {
                display_uuid: visible.display_uuid,
                x: (global.x - frame.origin.x) as f32 - f32::from(anchor.x),
                y: (frame.origin.y + frame.size.height - global.y) as f32 - f32::from(anchor.y),
                width: bounds.size.width.into(),
                height: bounds.size.height.into(),
            }
            .fit(visible),
        )
    }
    #[cfg(any(not(target_os = "macos"), test))]
    {
        let global = source.bounds().origin + pointer;
        let display = cx
            .displays()
            .into_iter()
            .find(|display| display.bounds().contains(&global))
            .or_else(|| source.display(cx))?;
        let mut visible = settings::WindowGeometry::from_bounds(display.visible_bounds());
        visible.display_uuid = display.uuid().ok();
        let bounds = source.bounds();
        Some(
            settings::WindowGeometry {
                display_uuid: visible.display_uuid,
                x: f32::from(global.x) - f32::from(anchor.x),
                y: f32::from(global.y) - f32::from(anchor.y),
                width: bounds.size.width.into(),
                height: bounds.size.height.into(),
            }
            .fit(visible),
        )
    }
}

#[cfg(target_os = "macos")]
fn align_main_window_traffic_lights(window: &gpui::Window) {
    use objc2_app_kit::{NSView, NSWindowButton};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return;
    };
    let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
        return;
    };
    let view = unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() };
    let Some(button) = view
        .window()
        .and_then(|window| window.standardWindowButton(NSWindowButton::CloseButton))
    else {
        return;
    };
    // The drawn circle and its native frame have different sizes on some
    // AppKit versions. Center the live frame in Harness's header control lane.
    let height = button.frame().size.height as f32;
    let lane = theme::Theme::TITLEBAR_HEIGHT + theme::Theme::TITLEBAR_TOP_PAD;
    window.set_traffic_light_position(gpui::point(px(14.), px((lane - height) / 2.)));
}

#[cfg(all(target_os = "macos", feature = "browser-fixture"))]
#[doc(hidden)]
pub fn fixture_align_main_window_traffic_lights(window: &gpui::Window) {
    align_main_window_traffic_lights(window);
}

fn open_main_window(
    state: gpui::Entity<state::AppState>,
    boot: EngineBootConfig,
    cx: &mut App,
) -> gpui::WindowHandle<shell::Shell> {
    let record = settings::current(cx)
        .restorable_workspace_windows()
        .into_iter()
        .next()
        .unwrap_or_else(|| settings::SavedWorkspaceWindow {
            id: uuid::Uuid::new_v4().to_string(),
            ..Default::default()
        });
    open_workspace_window(state, boot, record, cx).expect("failed to open window")
}

/// Start an empty workspace while retaining the existing engine and catalogs.
/// Unlike Dock reopen, New Window must never restore a saved window's tabs.
fn open_new_workspace_window(cx: &mut App) -> Result<gpui::WindowHandle<shell::Shell>, String> {
    let source = frontmost_workspace_window(cx)
        .and_then(|handle| handle.read_with(cx, |shell, _| shell.window_runtime()).ok());
    let (source, boot) = source
        .or_else(|| {
            cx.try_global::<ReopenState>()
                .map(|reopen| (reopen.state.clone(), reopen.boot.clone()))
        })
        .ok_or_else(|| "The Harness runtime is not available yet.".to_string())?;
    let state = cx.new(|cx| state::AppState::for_window(&source, cx));
    let record = settings::SavedWorkspaceWindow {
        id: uuid::Uuid::new_v4().to_string(),
        project_tabs_version: 2,
        ..Default::default()
    };
    let handle = open_workspace_window(state, boot, record, cx)?;
    handle
        .update(cx, |_, window, _| window.activate_window())
        .map_err(|error| error.to_string())?;
    cx.activate(true);
    Ok(handle)
}

/// Prepare an independently navigable native window around an already shared
/// engine connection. The caller adopts live tab resources after this succeeds.
pub(crate) fn open_workspace_window(
    state: gpui::Entity<state::AppState>,
    boot: EngineBootConfig,
    record: settings::SavedWorkspaceWindow,
    cx: &mut App,
) -> Result<gpui::WindowHandle<shell::Shell>, String> {
    init_workspace_windows(cx);
    if record.id.trim().is_empty() {
        return Err("The destination window identity is missing.".into());
    }
    if cx
        .global::<WorkspaceWindows>()
        .ids
        .values()
        .any(|id| id == &record.id)
    {
        return Err("That workspace window is already open.".into());
    }
    let (bounds, display_id) = restored_workspace_window_bounds(record.geometry, cx);
    let window_id = record.id.clone();
    let initial_record = record.clone();
    let handle = cx
        .open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                display_id,
                window_min_size: Some(size(px(900.), px(600.))),
                // `kind` is deliberately left at its default `WindowKind::Normal`
                // (gpui platform.rs WindowOptions::default), which on macOS maps
                // to `NSNormalWindowLevel` (gpui_macos window.rs) — same as zed's
                // main window. Nothing here raises the window level or touches
                // presentation options; the "menu bar never appears" symptom came
                // from the missing `set_menus` call (nil `NSApp.mainMenu`), not
                // from window kind/level, and `appears_transparent` only affects
                // the titlebar, not the menu bar.
                // macOS: frameless-inset chrome like the original Electron app
                // (`titleBarStyle: "hiddenInset"`, traffic lights at 14,15 —
                // feature-inventory §1.1). The strip is custom-drawn. Windows
                // still needs a native title for taskbar previews and Alt+Tab. On
                // Linux/Windows `appears_transparent` hides the system titlebar
                // for our custom-drawn chrome; harmless where unsupported.
                titlebar: Some(TitlebarOptions {
                    title: cfg!(target_os = "windows").then(|| "Harness".into()),
                    appears_transparent: true,
                    // Calibrated to the live AppKit button frame below, once
                    // the native window exists; widget sizes vary by system.
                    traffic_light_position: Some(gpui::point(px(14.), px(14.))),
                }),
                // Our own titlebar strip drags the window (WindowControlArea::
                // Drag + start_window_move) — mark the content view app-owned
                // so AppKit neither dead-zones the strip nor delays clicks.
                app_owns_titlebar_drag: true,
                // Linux: request client-side decorations — harness draws its own
                // unified titlebar and (under CSD) its own caption buttons
                // (shell.rs `render_linux_caption_controls`). Leaving this unset
                // requests SERVER decorations, which stacked a compositor
                // titlebar on top of the app's chrome under sway/KDE, while
                // compositors without SSD support (GNOME) went client-side
                // anyway — frameless, and before the shell drew caption buttons,
                // with no window controls at all. The compositor can still
                // override via xdg-decoration negotiation; the shell re-resolves
                // what to draw every frame.
                window_decorations: cfg!(target_os = "linux")
                    .then_some(gpui::WindowDecorations::Client),
                // Frosted shell (macOS): blur the desktop behind the window; the
                // shell paints its frost surface translucent so the sidebar reads
                // as glass (shell.rs root). Elsewhere blur support is compositor
                // roulette — stay opaque.
                // One source of truth with the re-apply loop in `appearance::apply`
                // — if these two ever disagree, vibrancy dies on the first theme
                // change and never comes back.
                window_background: theme::Theme::of(cx).window_background_appearance(),
                app_id: Some("harness".into()),
                ..Default::default()
            },
            move |window, cx| {
                #[cfg(all(target_os = "macos", not(test)))]
                align_main_window_traffic_lights(window);
                window.set_rem_size(px(typography::font_size(cx).pixels()));
                // React to the user flipping macOS between light and dark. Detached:
                // the subscription lives as long as the window does, and the window
                // owns nothing that would drop it early.
                appearance::observe_window(window, cx).detach();
                window.on_next_frame(|_, _| perf_stats::first_window_frame());
                let id = record.id.clone();
                let shell = cx.new(|cx| {
                    observe_workspace_window_geometry(id.clone(), window, cx);
                    shell::Shell::new_for_window(state, boot, record, cx)
                });
                settings::update(settings::SavePolicy::Debounced, cx, |settings| {
                    if !settings.workspace_windows.as_ref().is_some_and(|windows| {
                        windows.iter().any(|window| window.id == initial_record.id)
                    }) {
                        settings.upsert_workspace_window(initial_record);
                    }
                });
                save_workspace_window_geometry(&id, window, cx);
                let weak_shell = shell.downgrade();
                window.on_window_should_close(cx, move |window, cx| {
                    let should_close = weak_shell
                        .update(cx, |shell, cx| shell.prepare_window_close(cx))
                        .unwrap_or(true);
                    if should_close {
                        save_workspace_window_geometry(&id, window, cx);
                        settings::flush(cx);
                    }
                    should_close
                });
                shell
            },
        )
        .map_err(|error| format!("Could not create a Harness window: {error}"))?;
    cx.global_mut::<WorkspaceWindows>()
        .ids
        .insert(handle.window_id(), window_id);
    // Belt and braces: assert the blur once the window actually exists. The
    // `WindowOptions` value is applied during creation, before the view is
    // attached; re-pushing it here means a window is never left opaque.
    appearance::reapply_window_background(cx);
    Ok(handle)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn start_appshot_service(activation_dir: std::path::PathBuf, cx: &mut App) {
    let mut shortcuts = appshots::start_global_shortcut(activation_dir);
    cx.spawn(async move |cx| {
        while shortcuts.next().await.is_some() {
            if !appshots::capture_allowed() {
                continue;
            }
            let Some(capture) = cx.update(start_appshot_capture) else {
                continue;
            };
            let capture = capture.await;
            // Coalesce presses made while capture was in flight. Delivery
            // focuses Harness; replaying old activations would capture the wrong
            // app or show a misleading self-capture error after success.
            while matches!(shortcuts.next().now_or_never(), Some(Some(()))) {}
            cx.update(|cx| deliver_appshot(capture, cx));
        }
    })
    .detach();
}

/// Check viewer focus on the UI thread before any native capture or portal
/// request. Portals do not identify the source window, so their backends cannot
/// reject Harness after the picker or capture has already started.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn start_appshot_capture(
    cx: &mut App,
) -> Option<gpui::Task<Result<appshots::CapturedAppshot, appshots::CaptureError>>> {
    if cx.active_window().is_some() {
        return None;
    }
    Some(
        cx.background_executor()
            .spawn(async { appshots::capture_active_window().await }),
    )
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod appshot_activation_tests {
    use super::*;

    struct ViewerWindow;

    impl gpui::Render for ViewerWindow {
        fn render(
            &mut self,
            _: &mut gpui::Window,
            _: &mut gpui::Context<Self>,
        ) -> impl gpui::IntoElement {
            gpui::div()
        }
    }

    #[gpui::test]
    fn appshot_capture_skips_any_focused_viewer_window(cx: &mut gpui::TestAppContext) {
        // The guard must cover every Harness window, not only a Shell/chat root.
        for _ in 0..2 {
            let window = cx.add_window(|_, _| ViewerWindow);
            window
                .update(cx, |_, window, _| window.activate_window())
                .unwrap();
            cx.run_until_parked();
            cx.update(|cx| {
                assert!(cx.active_window().is_some());
                assert!(start_appshot_capture(cx).is_none());
            });
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn deliver_appshot(
    result: Result<appshots::CapturedAppshot, appshots::CaptureError>,
    cx: &mut App,
) {
    use std::collections::VecDeque;
    use std::sync::{Mutex, OnceLock};

    fn pending() -> &'static Mutex<VecDeque<appshots::CapturedAppshot>> {
        static PENDING: OnceLock<Mutex<VecDeque<appshots::CapturedAppshot>>> = OnceLock::new();
        PENDING.get_or_init(|| Mutex::new(VecDeque::new()))
    }

    if matches!(
        result,
        Err(appshots::CaptureError::Cancelled | appshots::CaptureError::SelfCapture)
    ) {
        return;
    }
    let mut captures = pending()
        .lock()
        .map(|mut queue| queue.drain(..).collect::<VecDeque<_>>())
        .unwrap_or_default();
    let error = match result {
        Ok(appshot) => {
            captures.push_back(appshot);
            None
        }
        Err(error) => Some(error),
    };
    let handle = cx
        .window_stack()
        .unwrap_or_else(|| cx.windows())
        .into_iter()
        .find_map(|handle| handle.downcast::<shell::Shell>())
        .or_else(|| {
            let reopen = cx.try_global::<ReopenState>()?;
            Some(open_main_window(
                reopen.state.clone(),
                reopen.boot.clone(),
                cx,
            ))
        });
    let Some(handle) = handle else {
        if !captures.is_empty() {
            let count = captures.len();
            if let Ok(mut queue) = pending().lock() {
                queue.extend(captures);
            }
            tracing::warn!(
                count,
                "Appshot captured with no Harness window; preserving it for the next delivery"
            );
        }
        return;
    };
    let captured = !captures.is_empty();
    cx.activate(true);
    let _ = handle.update(cx, |shell, window, cx| {
        window.activate_window();
        for appshot in captures {
            shell.receive_appshot(appshot, window, cx);
        }
        if let Some(error) = error {
            shell.show_appshot_error(error.to_string(), window, cx);
        }
    });
    if captured {
        appshots::foreground_after_capture();
    }
}

#[cfg(feature = "appshots-fixture")]
pub mod menu_review;

#[cfg(test)]
mod startup_window_tests {
    use super::*;

    fn record(id: &str) -> settings::SavedWorkspaceWindow {
        settings::SavedWorkspaceWindow {
            id: id.into(),
            last_chat_id: Some(format!("{id}-chat")),
            ..Default::default()
        }
    }

    #[test]
    fn startup_restore_opens_fresh_window_after_all_saved_windows_fail() {
        let failed = vec![record("left"), record("right")];
        let mut settings = settings::UiSettings::default();
        settings.workspace_windows = Some(failed.clone());
        let mut attempts = Vec::new();
        let errors = restore_startup_windows(
            settings.restorable_workspace_windows(),
            |record, primary| {
                attempts.push((record.id.clone(), primary));
                if failed.iter().any(|saved| saved.id == record.id) {
                    return Err(record.id);
                }
                assert!(uuid::Uuid::parse_str(&record.id).is_ok());
                assert!(record.geometry.is_none());
                assert!(record.chat_tabs.is_empty() && record.last_chat_id.is_none());
                settings.upsert_workspace_window(record);
                Ok(())
            },
        );
        assert_eq!(errors, ["left", "right"]);
        assert_eq!(attempts.len(), 3);
        assert_eq!(
            &attempts[..2],
            &[("left".into(), true), ("right".into(), true)]
        );
        assert!(
            attempts[2].1,
            "the fresh window owns the original runtime view"
        );
        let saved = settings.restorable_workspace_windows();
        assert_eq!(
            &saved[..2],
            failed.as_slice(),
            "failed records remain recoverable"
        );
        assert_eq!(saved.len(), 3);
    }

    #[test]
    fn startup_restore_keeps_partial_success_without_an_extra_blank_window() {
        let mut attempts = Vec::new();
        let errors = restore_startup_windows(
            vec![record("failed"), record("first"), record("second")],
            |record, primary| {
                attempts.push((record.id.clone(), primary));
                if record.id == "failed" {
                    Err("unavailable")
                } else {
                    Ok(())
                }
            },
        );
        assert_eq!(errors, ["unavailable"]);
        assert_eq!(
            attempts,
            [
                ("failed".into(), true),
                ("first".into(), true),
                ("second".into(), false)
            ]
        );
    }

    #[test]
    fn startup_restore_tries_an_empty_window_once_when_no_records_exist() {
        let mut attempts = 0;
        let errors = restore_startup_windows(Vec::new(), |record, primary| {
            attempts += 1;
            assert!(primary && record.geometry.is_none());
            assert!(uuid::Uuid::parse_str(&record.id).is_ok());
            Err("native window unavailable")
        });
        assert_eq!(
            attempts, 1,
            "a native failure must not cause an unbounded retry"
        );
        assert_eq!(errors, ["native window unavailable"]);
    }
}
