//! Native menu bar + app-level window actions (macOS-first).
//!
//! harness never called `cx.set_menus`, so on macOS `NSApp.mainMenu` stayed nil:
//! no app menu, no ⌘Q quit, and nothing for the auto-hidden system menu bar to
//! reveal on hover (gpui only calls `setMainMenu_` from `set_menus` —
//! gpui_macos/src/platform.rs `fn set_menus`). Structure ported from zed's
//! `crates/zed/src/zed/app_menus.rs` and the gpui `set_menus.rs` example at the
//! pinned rev (f14fea9bf3c9).
//!
//! Wiring: [`init`] registers the global action handlers (run once at boot),
//! [`bind_keys`] installs the fixed application shortcuts (re-run by
//! `shell::apply_keymap`, which clears every binding first), and
//! [`app_menus`] builds the menu bar handed to `cx.set_menus` in `run_app`.

use gpui::{App, KeyBinding, Menu, MenuItem, OsAction, SystemMenuType, Window, actions};

use crate::appearance::{self, AppearanceMode};
use crate::composer;
use crate::quit_hold;
use crate::shell;

actions!(
    harness,
    [
        About,
        Quit,
        Hide,
        HideOthers,
        ShowAll,
        NewWindow,
        Minimize,
        Zoom,
        CloseTab,
        CloseTabWithoutArchiving,
        CloseWindow,
        AppearanceSystem,
        AppearanceLight,
        AppearanceDark,
        ClearBrowsingData,
        IncreaseFontSize,
        DecreaseFontSize,
        ResetFontSize,
    ]
);

/// Register the global handlers backing the menu bar and its shortcuts. Call
/// once at boot, before `cx.set_menus`.
pub fn init(cx: &mut App) {
    #[cfg(all(target_os = "macos", not(test)))]
    native_quit::init(cx);
    register_actions(cx);
}

/// The menu verbs' handlers alone, without the native quit hook (which needs
/// AppKit's application delegate): headless renders (examples/ui-scenes.rs)
/// register these so ⌘W, ⌘= and the rest act as they do in the app.
pub fn register_actions(cx: &mut App) {
    cx.on_action(quit);
    #[cfg(target_os = "macos")]
    cx.on_action(|_: &About, _| about_panel::show());
    // The browser pane keeps sign-ins across restarts; this forgets them.
    #[cfg(target_os = "macos")]
    cx.on_action(|_: &ClearBrowsingData, _| crate::browser::clear_browsing_data());
    // Application-menu verbs — gpui wraps NSApp `hide` / `hideOtherApplications`
    // / `unhideAllApplications` (zed registers the same trio in
    // crates/zed/src/zed.rs `init`).
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
    cx.on_action(|_: &NewWindow, cx| {
        // Native menu and key dispatch can hold the current window's lease.
        cx.defer(|cx| {
            if let Err(error) = crate::open_new_workspace_window(cx) {
                tracing::error!(%error, "could not open a new workspace window");
            }
        });
    });
    // Window verbs route to the active window.
    cx.on_action(|_: &Minimize, cx| with_active_window(cx, |window| window.minimize_window()));
    cx.on_action(|_: &Zoom, cx| with_active_window(cx, |window| window.zoom_window()));
    cx.on_action(close_tab);
    cx.on_action(|_: &CloseTabWithoutArchiving, cx| {
        cx.defer(|cx| close_active_tab_with_archive(false, cx));
    });
    cx.on_action(close_window);
    // Appearance. Each verb persists and repaints every window; see
    // `appearance::set_mode`.
    cx.on_action(|_: &AppearanceSystem, cx| appearance::set_mode(AppearanceMode::System, cx));
    cx.on_action(|_: &AppearanceLight, cx| appearance::set_mode(AppearanceMode::Light, cx));
    cx.on_action(|_: &AppearanceDark, cx| appearance::set_mode(AppearanceMode::Dark, cx));
    // Text size, like a browser's zoom keys: steps through the sizes Settings
    // offers, persisted the same way.
    cx.on_action(|_: &IncreaseFontSize, cx| change_font_size(cx, |size| size.stepped(1)));
    cx.on_action(|_: &DecreaseFontSize, cx| change_font_size(cx, |size| size.stepped(-1)));
    cx.on_action(|_: &ResetFontSize, cx| change_font_size(cx, |_| Default::default()));
}

fn change_font_size(
    cx: &mut App,
    next: impl FnOnce(crate::typography::UiFontSize) -> crate::typography::UiFontSize + 'static,
) {
    // Harness is single-window; without a key window (tests, a window that
    // lost focus) the first one still takes the size.
    let Some(handle) = cx.active_window().or_else(|| cx.windows().first().copied()) else {
        return;
    };
    // A key binding dispatches this while its window is mid-update, so the
    // window can't be borrowed here; apply the size once the event is done.
    cx.defer(move |cx| {
        handle
            .update(cx, |_, window, cx| {
                let size = next(crate::typography::font_size(cx));
                crate::typography::set_font_size(size, window, cx);
            })
            .ok();
    });
}

fn with_active_window(cx: &mut App, f: impl FnOnce(&mut Window)) {
    if let Some(window) = cx.active_window() {
        window.update(cx, |_, window, _| f(window)).ok();
    }
}

/// All app-owned quit paths must flush file buffers before GPUI destroys windows.
fn quit(_: &Quit, cx: &mut App) {
    let running = quit_hold::chat_is_running(cx);
    match quit_hold::quit_press(native_quit::key_press(), running, quit_hold::holding(cx)) {
        quit_hold::QuitPress::Now => request_quit(cx),
        quit_hold::QuitPress::Ignore => {}
        quit_hold::QuitPress::StartHold(key) => {
            native_quit::watch_key(key);
            quit_hold::begin(cx, native_quit::key_still_down, request_quit);
        }
    }
}

pub(crate) fn request_quit(cx: &mut App) {
    // Actions may arrive while GPUI has the active window borrowed. Inspect
    // roots only after that dispatch completes.
    cx.defer(prepare_quit);
}

fn prepare_quit(cx: &mut App) {
    let mut ready = true;
    for window in cx.windows() {
        if let Some(window) = window.downcast::<shell::Shell>() {
            ready &= window
                .update(cx, |shell, _, cx| shell.prepare_quit(cx))
                .unwrap_or(false);
        }
    }
    if ready {
        // Every window agreed: install staged updates now, not inside each
        // prepare_quit — a window that installs before another window vetoes
        // the quit would leave the running app on a replaced bundle.
        for window in cx.windows() {
            if let Some(window) = window.downcast::<shell::Shell>() {
                let _ = window.update(cx, |shell, _, _| {
                    shell.install_staged_update_on_quit();
                });
            }
        }
        quit_after_save(cx);
    }
}

/// How long quitting waits for the in-process engine to settle its runs and
/// record what it cut short. One interrupt's settle wait (5 s, every run at
/// once) plus the flush, with margin; a hung engine still lets the app quit.
const QUIT_DRAIN: std::time::Duration = std::time::Duration::from_secs(8);

/// Set once a quit has started draining the engine: a second quit request
/// (⌘Q again) exits at once instead of waiting a second time.
static QUIT_DRAINING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Every app-owned quit ends here: ⌘Q, the menu, Dock or system quit,
/// "Restart now" into an update, install-on-quit, relaunch.
///
/// An in-process engine is shut down first, and the app quits once that
/// finishes (or after [`QUIT_DRAIN`]). GPUI gives `on_app_quit` handlers only
/// a fraction of a second before the process exits, which cut the drain
/// short whenever a run was live: its journal was left without a `Done`, the
/// next boot took the crash path ("Run interrupted by engine restart"), and a
/// run waiting on a question was re-sent and asked it again. A remote engine
/// (a daemon) outlives the app and isn't drained.
pub(crate) fn quit_after_save(cx: &mut App) {
    use std::sync::atomic::Ordering;
    #[cfg(target_os = "macos")]
    native_quit::allow();
    let engine = cx
        .try_global::<crate::ReopenState>()
        .and_then(|reopen| reopen.state.read(cx).engine().cloned())
        .filter(|engine| matches!(engine.mode(), crate::state::EngineMode::InProcess));
    let Some(engine) = engine.filter(|_| !QUIT_DRAINING.swap(true, Ordering::SeqCst)) else {
        cx.quit();
        return;
    };
    // The app looks gone at once; the engine settles behind it.
    #[cfg(target_os = "macos")]
    cx.hide();
    let drain = gpui_tokio::Tokio::spawn(cx, async move {
        // Its own task: the deadline stops the wait, not the shutdown, which
        // keeps going until the process exits.
        let shutdown = tokio::spawn(async move { engine.shutdown().await });
        if tokio::time::timeout(QUIT_DRAIN, shutdown).await.is_err() {
            tracing::warn!("engine shutdown outlasted the quit drain; quitting anyway");
        }
    });
    cx.spawn(async move |cx| {
        let _ = drain.await;
        let _ = cx.update(|cx| cx.quit());
    })
    .detach();
}

fn close_tab(_: &CloseTab, cx: &mut App) {
    cx.defer(close_active_tab);
}

/// ⌘W: close the innermost thing open and never the window. Closing the
/// window ends the app's session for every chat, so a stray ⌘W in an empty
/// chat must not take running agents down with it (⌘⇧W closes the window).
/// The first ⌘W that would close a session asks for a default; later closes
/// follow the saved preference (`shell/archive_choice.rs`).
/// ⌘⌥W closes the same way without archiving or asking.
fn close_active_tab(cx: &mut App) {
    close_active_tab_with_archive(true, cx);
}

fn close_active_tab_with_archive(archive: bool, cx: &mut App) {
    if let Some(window) = cx
        .active_window()
        .and_then(|window| window.downcast::<shell::Shell>())
    {
        close_tab_in_with_archive(window, archive, cx);
    }
}

pub(crate) fn close_tab_in(window: gpui::WindowHandle<shell::Shell>, cx: &mut App) {
    close_tab_in_with_archive(window, true, cx);
}

fn close_tab_in_with_archive(
    window: gpui::WindowHandle<shell::Shell>,
    archive: bool,
    cx: &mut App,
) {
    window
        .update(cx, |shell, window, cx| {
            // The right pane's active surface (the tab the user just opened),
            // then the focused split pane or chat tab, Ghostty-style, then
            // the chat itself, back to a new session.
            if shell.close_side_surface_by_shortcut(window, cx) {
                return;
            }
            if archive && shell.close_focused_panel_chat_by_shortcut(window, cx) {
                return;
            }
            if shell.workspace_close_focused(window, cx) || shell.close_active_surface(window, cx) {
                return;
            }
            if archive {
                shell.close_chat_view_by_shortcut(window, cx);
            } else {
                shell.close_chat_view_with_archive(false, window, cx);
            }
        })
        .ok();
}

fn close_window(_: &CloseWindow, cx: &mut App) {
    cx.defer(close_active_window);
}

fn close_active_window(cx: &mut App) {
    if let Some(window) = cx.active_window() {
        if let Some(window) = window.downcast::<shell::Shell>() {
            window
                .update(cx, |shell, window, cx| {
                    // Unsaved files hold the close until they are dealt with.
                    if shell.prepare_window_close(cx) {
                        window.remove_window();
                    }
                })
                .ok();
        } else {
            window
                .update(cx, |_, window, _| window.remove_window())
                .ok();
        }
    }
}

/// Fixed app-level shortcuts backing the menu key equivalents. These live
/// outside the customizable keymap; `shell::apply_keymap` calls this after its
/// `clear_key_bindings` so they survive keymap re-application. Settings follows
/// the platform convention everywhere (Cmd+, on macOS, Ctrl+, elsewhere);
/// window/application lifecycle shortcuts remain macOS-only.
pub fn bind_keys(cx: &mut App) {
    cx.bind_keys(app_key_bindings(cfg!(target_os = "macos")));
}

/// The binding table behind [`bind_keys`] — `KeyBinding` construction is pure
/// (no `App`), so unit tests can inspect it directly.
fn app_key_bindings(macos: bool) -> Vec<KeyBinding> {
    let mut bindings = vec![KeyBinding::new(
        if macos { "cmd-," } else { "ctrl-," },
        shell::OpenSettings,
        None,
    )];
    let primary = if macos { "cmd" } else { "ctrl" };
    bindings.extend([
        KeyBinding::new(&format!("{primary}-n"), NewWindow, None),
        KeyBinding::new(&format!("{primary}-="), IncreaseFontSize, None),
        KeyBinding::new(&format!("{primary}-+"), IncreaseFontSize, None),
        KeyBinding::new(&format!("{primary}--"), DecreaseFontSize, None),
        KeyBinding::new(&format!("{primary}-0"), ResetFontSize, None),
    ]);
    // A shell needs Ctrl+N. On a Mac this is ⌘N, which never reaches one.
    if !macos {
        bindings.push(KeyBinding::new("ctrl-n", gpui::NoAction, Some("Terminal")));
    }
    if macos {
        bindings.extend([
            KeyBinding::new("cmd-q", Quit, None),
            KeyBinding::new("cmd-h", Hide, None),
            KeyBinding::new("alt-cmd-h", HideOthers, None),
            KeyBinding::new("cmd-m", Minimize, None),
            KeyBinding::new("cmd-w", CloseTab, None),
            KeyBinding::new("cmd-shift-w", CloseWindow, None),
        ]);
    } else {
        // Ghostty's GTK key for closing a split, beside its Ctrl+Shift+O/E
        // split keys. Without it nothing closed a pane off macOS: there is no
        // native menu bar there to offer Close Tab. Alt+F4 still closes the
        // window, and inside the terminal its own Ctrl+Shift+W wins.
        bindings.push(KeyBinding::new("ctrl-shift-w", CloseTab, None));
    }
    bindings
}

/// The harness menu bar. macOS renders this natively; mac-only entries are gated
/// at runtime (`cfg!`) so the whole module compiles and tests on Linux.
pub fn app_menus() -> Vec<Menu> {
    let macos = cfg!(target_os = "macos");

    // macOS titles the first menu with the bundle/process name regardless of
    // what we pass, but gpui still wants a name.
    let mut app_items = vec![
        // The native AppKit about panel; no equivalent elsewhere yet.
        MenuItem::action("About Harness", About).disabled(!macos),
        MenuItem::separator(),
        MenuItem::action("Settings", shell::OpenSettings),
        MenuItem::separator(),
    ];
    if macos {
        app_items.extend([
            MenuItem::action("Clear Browsing Data", ClearBrowsingData),
            MenuItem::separator(),
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::action("Hide Harness", Hide),
            MenuItem::action("Hide Others", HideOthers),
            MenuItem::action("Show All", ShowAll),
            MenuItem::separator(),
        ]);
    }
    app_items.push(MenuItem::action("Quit Harness", Quit));

    let mut menus = vec![
        Menu::new("Harness").items(app_items),
        Menu::new("File").items([MenuItem::action("New Window", NewWindow)]),
        // Standard clipboard verbs tied to the composer's existing actions via
        // their native selectors (`OsAction` → cut:/copy:/paste:/selectAll:),
        // so the OS Edit menu routes through the responder chain to the focused
        // input — zed wires its editor actions identically
        // (crates/zed/src/zed/app_menus.rs, Edit/Selection menus).
        Menu::new("Edit").items([
            // Undo/Redo have no `OsAction` counterpart — they dispatch as plain
            // actions to the focused input, same as the composer keymap.
            MenuItem::action("Undo", composer::Undo),
            MenuItem::action("Redo", composer::Redo),
            MenuItem::separator(),
            MenuItem::os_action("Cut", composer::Cut, OsAction::Cut),
            MenuItem::os_action("Copy", composer::Copy, OsAction::Copy),
            MenuItem::os_action("Paste", composer::Paste, OsAction::Paste),
            MenuItem::separator(),
            MenuItem::os_action("Select All", composer::SelectAll, OsAction::SelectAll),
        ]),
    ];
    // Appearance lives under View on every platform — it is the only View verb
    // today, but "Appearance" as a top-level menu would read oddly next to Edit.
    menus.push(Menu::new("View").items([
        MenuItem::action("Appearance: System", AppearanceSystem),
        MenuItem::action("Appearance: Light", AppearanceLight),
        MenuItem::action("Appearance: Dark", AppearanceDark),
        MenuItem::separator(),
        MenuItem::action("Bigger Text", IncreaseFontSize),
        MenuItem::action("Smaller Text", DecreaseFontSize),
        MenuItem::action("Actual Size", ResetFontSize),
    ]));
    if macos {
        // Standard Window menu; macOS appends the open-window list itself.
        menus.push(Menu::new("Window").items([
            MenuItem::action("New Tab", shell::NewTab),
            MenuItem::separator(),
            MenuItem::action("Minimize", Minimize),
            MenuItem::action("Zoom", Zoom),
            MenuItem::separator(),
            MenuItem::action("Close Tab", CloseTab),
            MenuItem::action("Reopen Closed Tab", shell::ReopenClosedChatTab),
            MenuItem::action("Close Window", CloseWindow),
        ]));
    }
    menus
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{Action as _, Keystroke};

    fn action_names(menu: &Menu) -> Vec<&'static str> {
        menu.items
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action { action, .. } => Some(action.name()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn native_file_menu_offers_new_window() {
        let menus = app_menus();
        let file = menus
            .iter()
            .find(|menu| menu.name.as_ref() == "File")
            .expect("File menu must let people open a new window");
        assert!(file.items.iter().any(|item| matches!(
            item,
            MenuItem::Action { name, .. }
                if name.as_ref() == "New Window" && !item.is_disabled()
        )));
    }

    #[test]
    fn app_menu_ends_with_quit() {
        let menus = app_menus();
        assert_eq!(menus[0].name.as_ref(), "Harness");
        let Some(MenuItem::Action { name, action, .. }) = menus[0].items.last() else {
            panic!("last app-menu item must be an action");
        };
        assert_eq!(name.as_ref(), "Quit Harness");
        assert_eq!(action.name(), Quit.name());
    }

    #[test]
    fn app_menu_offers_settings() {
        let menus = app_menus();
        assert!(
            menus[0].items.iter().any(|item| matches!(
                item,
                MenuItem::Action { name, action, .. }
                    if name.as_ref() == "Settings" && action.name() == shell::OpenSettings.name()
            )),
            "the application menu should expose Settings"
        );
    }

    #[test]
    fn native_new_tab_menu_uses_the_panel_tab_action() {
        if !cfg!(target_os = "macos") {
            return;
        }
        let menus = app_menus();
        let window = menus
            .iter()
            .find(|menu| menu.name.as_ref() == "Window")
            .unwrap();
        assert!(window.items.iter().any(|item| matches!(
            item,
            MenuItem::Action { name, action, .. }
                if name.as_ref() == "New Tab" && action.name() == shell::NewTab.name()
        )));
    }

    #[test]
    fn about_enabled_only_on_macos() {
        let menus = app_menus();
        let Some(first @ MenuItem::Action { action, .. }) = menus[0].items.first() else {
            panic!("first app-menu item must be an action");
        };
        assert_eq!(action.name(), About.name());
        assert_eq!(first.is_disabled(), !cfg!(target_os = "macos"));
    }

    #[test]
    fn edit_menu_uses_composer_clipboard_os_actions() {
        let menus = app_menus();
        let edit = menus
            .iter()
            .find(|m| m.name.as_ref() == "Edit")
            .expect("Edit menu present");
        // `OsAction` has no `Debug` impl at the pinned rev, so compare
        // per-field.
        let expect = [
            (composer::Cut.name(), OsAction::Cut),
            (composer::Copy.name(), OsAction::Copy),
            (composer::Paste.name(), OsAction::Paste),
            (composer::SelectAll.name(), OsAction::SelectAll),
        ];
        let got: Vec<(&str, OsAction)> = edit
            .items
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action {
                    action,
                    os_action: Some(os_action),
                    ..
                } => Some((action.name(), *os_action)),
                _ => None,
            })
            .collect();
        assert_eq!(got.len(), expect.len());
        for ((got_name, got_os), (want_name, want_os)) in got.iter().zip(expect.iter()) {
            assert_eq!(got_name, want_name);
            assert!(got_os == want_os, "OsAction mismatch for {want_name}");
        }
    }

    #[test]
    fn view_menu_offers_all_three_appearance_modes() {
        let menus = app_menus();
        let view = menus
            .iter()
            .find(|m| m.name.as_ref() == "View")
            .expect("View menu present");
        assert_eq!(
            action_names(view),
            vec![
                AppearanceSystem.name(),
                AppearanceLight.name(),
                AppearanceDark.name(),
                IncreaseFontSize.name(),
                DecreaseFontSize.name(),
                ResetFontSize.name(),
            ]
        );
    }

    #[test]
    fn app_bindings_use_platform_settings_convention() {
        // `KeyBinding::new` panics on unparseable combos, so constructing the
        // table is itself the parse check.
        let find = |bindings: &[KeyBinding], name: &str| {
            bindings
                .iter()
                .find(|binding| binding.action().name() == name)
                .map(|binding| {
                    binding
                        .keystrokes()
                        .iter()
                        .map(|ks| ks.inner().clone())
                        .collect::<Vec<_>>()
                })
        };
        let combo = |source: &str| vec![Keystroke::parse(source).unwrap()];
        let macos = app_key_bindings(true);
        assert_eq!(
            find(&macos, shell::OpenSettings.name()),
            Some(combo("cmd-,"))
        );
        assert_eq!(find(&macos, Quit.name()), Some(combo("cmd-q")));
        // ⌘W closes a tab and never the window; ⌘⇧W closes the window.
        assert_eq!(find(&macos, CloseTab.name()), Some(combo("cmd-w")));
        assert_eq!(find(&macos, CloseWindow.name()), Some(combo("cmd-shift-w")));
        assert_eq!(find(&macos, Minimize.name()), Some(combo("cmd-m")));
        assert_eq!(find(&macos, NewWindow.name()), Some(combo("cmd-n")));

        let other = app_key_bindings(false);
        assert_eq!(
            find(&other, shell::OpenSettings.name()),
            Some(combo("ctrl-,"))
        );
        assert_eq!(find(&other, Quit.name()), None);
        // Off macOS the same close-the-innermost-thing action needs a key too.
        assert_eq!(find(&other, CloseTab.name()), Some(combo("ctrl-shift-w")));
        assert_eq!(find(&other, NewWindow.name()), Some(combo("ctrl-n")));

        // Text size: the browser zoom keys, Cmd on macOS and Ctrl elsewhere.
        let all = |bindings: &[KeyBinding], name: &str| -> Vec<Keystroke> {
            bindings
                .iter()
                .filter(|binding| binding.action().name() == name)
                .flat_map(|binding| binding.keystrokes().iter().map(|ks| ks.inner().clone()))
                .collect()
        };
        for (bindings, primary) in [(&macos, "cmd"), (&other, "ctrl")] {
            assert_eq!(
                all(bindings, IncreaseFontSize.name()),
                vec![
                    Keystroke::parse(&format!("{primary}-=")).unwrap(),
                    Keystroke::parse(&format!("{primary}-+")).unwrap()
                ]
            );
            assert_eq!(
                all(bindings, DecreaseFontSize.name()),
                vec![Keystroke::parse(&format!("{primary}--")).unwrap()]
            );
            assert_eq!(
                all(bindings, ResetFontSize.name()),
                vec![Keystroke::parse(&format!("{primary}-0")).unwrap()]
            );
        }
    }
}

// Standard AppKit about panel. Icon and copyright still come from the bundle's
// Info.plist; name and version are passed explicitly so unbundled dev builds
// (`cargo run`) show "Harness" and the crate version instead of the process name.
#[cfg(target_os = "macos")]
mod about_panel {
    use objc2::MainThreadMarker;
    use objc2::runtime::AnyObject;
    use objc2_app_kit::{
        NSAboutPanelOptionApplicationName, NSAboutPanelOptionApplicationVersion,
        NSAboutPanelOptionVersion, NSApplication,
    };
    use objc2_foundation::{NSDictionary, NSString};

    pub(super) fn show() {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let name = NSString::from_str("Harness");
        let version = NSString::from_str(env!("CARGO_PKG_VERSION"));
        // Empty build version: CFBundleVersion equals the marketing version, and
        // AppKit would otherwise render "Version 0.2.61 (0.2.61)".
        let build = NSString::from_str("");
        let values: [&AnyObject; 3] = [&name, &version, &build];
        unsafe {
            let options = NSDictionary::from_slices(
                &[
                    NSAboutPanelOptionApplicationName,
                    NSAboutPanelOptionApplicationVersion,
                    NSAboutPanelOptionVersion,
                ],
                &values,
            );
            NSApplication::sharedApplication(mtm).orderFrontStandardAboutPanelWithOptions(&options);
        }
    }
}

/// Off macOS a Quit request is never held: nothing here reports a key press.
#[cfg(not(target_os = "macos"))]
mod native_quit {
    use super::quit_hold;

    pub(super) fn key_press() -> Option<quit_hold::KeyPress> {
        None
    }

    pub(super) fn watch_key(_: u16) {}

    pub(super) fn key_still_down() -> bool {
        false
    }
}

// GPUI's on_app_quit runs after AppKit has committed to termination. Catch
// Dock / system Quit at the earlier delegate decision, just like our menu
// action, so failed saves can still cancel termination. The pinned GPUI
// delegate does not implement applicationShouldTerminate:.
#[cfg(target_os = "macos")]
mod native_quit {
    use super::*;
    use block::ConcreteBlock;
    use objc::runtime::{Class, Object, Sel, class_addMethod};
    use objc::{class, msg_send, sel, sel_impl};
    use std::cell::{Cell, RefCell};

    const NS_EVENT_TYPE_KEY_DOWN: u64 = 10;
    const NS_EVENT_MASK_KEY_UP: u64 = 1 << 11;
    const NS_EVENT_MASK_FLAGS_CHANGED: u64 = 1 << 12;
    const NS_EVENT_TYPE_KEY_UP: u64 = 11;
    const NS_EVENT_MODIFIER_COMMAND: u64 = 1 << 20;

    thread_local! {
        static ALLOWED: Cell<bool> = const { Cell::new(false) };
        /// The key of a hold in progress, until it or Command is let go.
        static HELD_KEY: Cell<Option<u16>> = const { Cell::new(None) };
        static REQUEST: RefCell<Option<Box<dyn Fn()>>> = const { RefCell::new(None) };
    }

    extern "C" fn should_terminate(_: &Object, _: Sel, _: *mut Object) -> usize {
        if ALLOWED.get() {
            return 1; // NSTerminateNow
        }
        REQUEST.with_borrow(|request| {
            if let Some(request) = request {
                request();
            }
        });
        0 // NSTerminateCancel; re-request only after buffers are safe.
    }

    pub(super) fn allow() {
        ALLOWED.set(true);
    }

    /// The key press being handled right now, if a key press is what's being
    /// handled: a menu click or a Dock quit has none.
    pub(super) fn key_press() -> Option<quit_hold::KeyPress> {
        unsafe {
            let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
            let event: *mut Object = msg_send![app, currentEvent];
            if event.is_null() {
                return None;
            }
            let kind: u64 = msg_send![event, type];
            if kind != NS_EVENT_TYPE_KEY_DOWN {
                return None;
            }
            let code: u16 = msg_send![event, keyCode];
            let repeat: objc::runtime::BOOL = msg_send![event, isARepeat];
            Some(quit_hold::KeyPress {
                code,
                repeat: repeat == objc::runtime::YES,
            })
        }
    }

    pub(super) fn watch_key(code: u16) {
        HELD_KEY.set(Some(code));
    }

    pub(super) fn key_still_down() -> bool {
        HELD_KEY.get().is_some()
    }

    /// AppKit drops the key-up of a key pressed with Command before it reaches
    /// a window, so watch for it ahead of that. If this ever saw nothing, the
    /// hold would simply complete: quitting can't get stuck behind it.
    fn watch_for_release() {
        let monitor = ConcreteBlock::new(|event: *mut Object| -> *mut Object {
            if HELD_KEY.get().is_some() {
                unsafe {
                    let kind: u64 = msg_send![event, type];
                    let released = if kind == NS_EVENT_TYPE_KEY_UP {
                        let code: u16 = msg_send![event, keyCode];
                        HELD_KEY.get() == Some(code)
                    } else {
                        let flags: u64 = msg_send![event, modifierFlags];
                        flags & NS_EVENT_MODIFIER_COMMAND == 0
                    };
                    if released {
                        HELD_KEY.set(None);
                    }
                }
            }
            event
        })
        .copy();
        unsafe {
            let _: *mut Object = msg_send![
                class!(NSEvent),
                addLocalMonitorForEventsMatchingMask: NS_EVENT_MASK_KEY_UP | NS_EVENT_MASK_FLAGS_CHANGED
                handler: &*monitor
            ];
        }
        // AppKit copied it, and this watches for as long as the app runs.
        std::mem::forget(monitor);
    }

    pub(super) fn init(cx: &mut App) {
        watch_for_release();
        let executor = cx.foreground_executor().clone();
        let app = cx.to_async();
        REQUEST.with_borrow_mut(|request| {
            *request = Some(Box::new(move || {
                let mut app = app.clone();
                executor
                    .spawn(async move {
                        let _ = app.update(request_quit);
                    })
                    .detach();
            }));
        });
        // AppKit invokes delegate methods on the main thread. Add only the
        // missing selector: never replace GPUI's existing quit observer.
        unsafe {
            let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
            let delegate: *mut Object = msg_send![app, delegate];
            assert!(!delegate.is_null(), "GPUI application delegate must exist");
            let class = (*delegate).class() as *const Class as *mut Class;
            let added = class_addMethod(
                class,
                sel!(applicationShouldTerminate:),
                std::mem::transmute::<
                    extern "C" fn(&Object, Sel, *mut Object) -> usize,
                    unsafe extern "C" fn(),
                >(should_terminate),
                c"Q@:@".as_ptr(),
            );
            assert!(
                added == objc::runtime::YES,
                "GPUI termination delegate contract changed"
            );
        }
    }

    #[test]
    fn ctrl_n_stays_with_a_focused_terminal_off_macos() {
        let keymap = gpui::Keymap::new(app_key_bindings(false));
        let resolve = |contexts: &[&str]| {
            let stack: Vec<gpui::KeyContext> = contexts
                .iter()
                .map(|c| gpui::KeyContext::parse(c).unwrap())
                .collect();
            let (matched, _) =
                keymap.bindings_for_input(&[gpui::Keystroke::parse("ctrl-n").unwrap()], &stack);
            matched.first().map(|b| b.action().name())
        };
        assert_eq!(resolve(&["Shell", "Terminal"]), None);
        assert_eq!(resolve(&["Shell"]), Some(gpui::Action::name(&NewWindow)));
    }
}
