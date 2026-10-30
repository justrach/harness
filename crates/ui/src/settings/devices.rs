//! Settings → Devices (feature-inventory §1.5): the device registry — name,
//! platform, last-seen, presence dot, a "This device" badge, click-to-copy id,
//! a Rename dialog (Mutate renameDevice), and Remove for offline devices (Mutate forgetDevice).

use chrono::{DateTime, Utc};
use gpui::{
    AnyElement, ClipboardItem, Context, Entity, Focusable, SharedString, Subscription, Task,
    Window, div, prelude::*, px,
};
use std::time::Duration;

use harness_proto::WorkspaceScope;
use harness_rpc::methods;

use crate::composer::{ComposerInput, ComposerInputEvent};
use crate::popover;
use crate::settings::{self, widgets};
use crate::state::AppState;
use crate::theme::Theme;

mod updates;

/// A device that pinged within this window shows a presence dot (engines
/// heartbeat every 15s; 70s tolerates a couple of missed beats).
pub const DEVICE_ONLINE_WINDOW_SECS: i64 = 70;

/// Presence: last-seen within the online window (future timestamps count). Pure.
pub fn device_online(last_seen: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
    last_seen
        .is_some_and(|at| now.signed_duration_since(at).num_seconds() <= DEVICE_ONLINE_WINDOW_SECS)
}

/// Compact last-seen line. Pure.
pub fn format_last_seen(last_seen: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let Some(at) = last_seen else {
        return "never seen".to_string();
    };
    let secs = now.signed_duration_since(at).num_seconds();
    if secs < 60 {
        "just now".to_string()
    } else if secs < 3600 {
        format!("{}m ago", secs / 60)
    } else if secs < 86_400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86_400)
    }
}

/// Scope-aware copy: a local registry describes only the active local
/// workspace and must not imply that account device metadata is already live.
pub fn devices_subtitle(scope: Option<WorkspaceScope>) -> &'static str {
    match scope {
        Some(WorkspaceScope::Local) => "Manage device details stored in this local workspace.",
        Some(WorkspaceScope::Synced) => "Manage device names and inspect synced device metadata.",
        Some(WorkspaceScope::Development) | None => "Manage device names for this workspace.",
    }
}

/// What the version card offers next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateAction {
    Check,
    /// Download and restart into this version.
    Update(String),
    /// A download is running: a disabled "Downloading…" button.
    Downloading,
    /// Staged: restart into it, as the titlebar update control does.
    Restart(String),
    /// The download failed: try it again.
    Retry(String),
    None,
}

/// How far this window's desktop update has come — the shell's update flow,
/// published so the version card offers the same next step as the titlebar
/// control instead of starting a download that is already running or done.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum UpdatePhase {
    #[default]
    Idle,
    Downloading,
    Ready(String),
    Failed(String),
}

/// The shell's [`UpdatePhase`], as a global the Devices page observes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SharedUpdatePhase(pub UpdatePhase);

impl gpui::Global for SharedUpdatePhase {}

/// The version card's status line and button. `desktop` = this install can
/// update itself (the macOS app, the portable Windows package). Pure.
pub fn update_summary(
    status: Option<&harness_update::UpdateStatus>,
    desktop: bool,
    phase: &UpdatePhase,
    checking: bool,
    now: DateTime<Utc>,
) -> (String, UpdateAction) {
    let Some(status) = status.filter(|_| desktop) else {
        return (
            "This build doesn't update itself. Install the latest release to update.".into(),
            UpdateAction::None,
        );
    };
    let latest = status
        .latest_version
        .clone()
        .filter(|_| status.update_available);
    match (phase, latest) {
        (UpdatePhase::Ready(version), _) => {
            return (
                format!("Harness v{version} is downloaded and ready to install."),
                UpdateAction::Restart(version.clone()),
            );
        }
        (UpdatePhase::Downloading, Some(latest)) => {
            return (format!("Downloading v{latest}…"), UpdateAction::Downloading);
        }
        (UpdatePhase::Failed(message), Some(latest)) => {
            return (
                format!("Updating to v{latest} failed: {message}"),
                UpdateAction::Retry(latest),
            );
        }
        _ => {}
    }
    if checking {
        return ("Checking for updates…".into(), UpdateAction::None);
    }
    if status.update_available
        && let Some(latest) = status.latest_version.clone()
    {
        return (
            format!("Harness v{latest} is available."),
            UpdateAction::Update(latest),
        );
    }
    if let Some(error) = &status.error {
        return (
            format!("Couldn't check for updates: {error}"),
            UpdateAction::Check,
        );
    }
    let checked = status
        .checked_at
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .map(|at| format!("Up to date · checked {}", format_last_seen(Some(at), now)))
        .unwrap_or_else(|| "Not checked yet.".into());
    (checked, UpdateAction::Check)
}

/// A manual check stops showing "Checking…" once the status changes, or
/// after this long.
const UPDATE_CHECK_TIMEOUT: Duration = Duration::from_secs(30);

struct RenameDialog {
    device_id: String,
    input: Entity<ComposerInput>,
    /// The field takes the keys on the dialog's first frame.
    focus_pending: bool,
    _events: Subscription,
}

pub struct DevicesPage {
    state: Entity<AppState>,
    scroll: widgets::PageScroll,
    rename: Option<RenameDialog>,
    /// Device id whose id-chip shows "Copied" right now.
    copied: Option<String>,
    /// Device id whose Remove asks for a second click.
    confirm_remove: Option<String>,
    error: Option<SharedString>,
    task: Option<Task<()>>,
    copy_task: Option<Task<()>>,
    /// A manual update check in flight: the status it started from.
    checking: Option<Option<harness_update::UpdateStatus>>,
    check_task: Option<Task<()>>,
    desktop_update: bool,
    remote_update: updates::RemoteUpdate,
    _observe: Subscription,
    _observe_phase: Subscription,
}

impl DevicesPage {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&state, |page: &mut Self, _, cx| {
            page.reconcile_remote_update(cx);
            cx.notify();
        });
        let observe_phase = cx.observe_global::<SharedUpdatePhase>(|_, cx| cx.notify());
        Self {
            state,
            scroll: widgets::PageScroll::default(),
            rename: None,
            copied: None,
            confirm_remove: None,
            error: None,
            task: None,
            copy_task: None,
            checking: None,
            check_task: None,
            desktop_update: harness_update::detect_install().supports_desktop_update(),
            remote_update: updates::RemoteUpdate::default(),
            _observe: observe,
            _observe_phase: observe_phase,
        }
    }

    /// Ask the engine to check for a release now; the answer comes back on
    /// the UpdateStatus stream this page already watches.
    fn check_for_updates(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.error = Some("Engine not connected".into());
            cx.notify();
            return;
        };
        self.checking = Some(self.state.read(cx).update.clone());
        self.check_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::CHECK_FOR_UPDATES, serde_json::json!({}))
                .await;
            if let Err(err) = result {
                this.update(cx, |page, cx| {
                    page.checking = None;
                    page.error = Some(format!("Update check failed: {err}").into());
                    cx.notify();
                })
                .ok();
                return;
            }
            cx.background_executor().timer(UPDATE_CHECK_TIMEOUT).await;
            this.update(cx, |page, cx| {
                page.checking = None;
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn render_version_card(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let status = self.state.read(cx).update.clone();
        // The check is over once the status moves.
        if self.checking.as_ref().is_some_and(|before| *before != status) {
            self.checking = None;
        }
        let current = status
            .as_ref()
            .map(|status| status.current_version.clone())
            .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string());
        let phase = cx
            .try_global::<SharedUpdatePhase>()
            .map(|shared| shared.0.clone())
            .unwrap_or_default();
        let (line, action) = update_summary(
            status.as_ref(),
            self.desktop_update,
            &phase,
            self.checking.is_some(),
            Utc::now(),
        );
        // The titlebar control's click: download, retry, or restart into the
        // staged update (unsaved edits are resolved first, as there).
        let start = |id: &'static str, label: String| {
            popover::btn_primary(theme, &label)
                .id(id)
                .debug_selector(move || id.into())
                .cursor_pointer()
                .on_click(|_, window, cx| {
                    window.dispatch_action(Box::new(crate::shell::StartAppUpdate), cx)
                })
                .into_any_element()
        };
        let button = match action {
            UpdateAction::Check => Some(
                popover::btn_ghost(theme, "Check for updates", "check-for-updates-fade")
                    .id("check-for-updates")
                    .on_click(cx.listener(|page, _, _, cx| page.check_for_updates(cx)))
                    .into_any_element(),
            ),
            UpdateAction::Update(latest) => {
                Some(start("start-app-update", format!("Update to v{latest}")))
            }
            UpdateAction::Restart(_) => {
                Some(start("restart-app-update", "Restart to update".into()))
            }
            UpdateAction::Retry(_) => Some(start("retry-app-update", "Try again".into())),
            UpdateAction::Downloading => Some(
                popover::btn_ghost(theme, "Downloading…", "app-update-downloading-fade")
                    .id("app-update-downloading")
                    .debug_selector(|| "app-update-downloading".into())
                    .opacity(0.6)
                    .into_any_element(),
            ),
            UpdateAction::None => None,
        };
        widgets::card_row(theme, true)
            .child(widgets::row_tile(theme, crate::icons::REFRESH))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(widgets::row_title(theme, format!("Harness v{current}")))
                    .child(widgets::meta_line(
                        theme,
                        vec![div().child(SharedString::from(line)).into_any_element()],
                    )),
            )
            .children(button)
            .into_any_element()
    }

    /// "Restart automatically to install updates", under the version card on
    /// installs that update themselves.
    fn render_auto_restart_row(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.desktop_update {
            return None;
        }
        let env_on = harness_update::desktop_auto_update_enabled();
        let on = env_on && settings::with_current(cx, |s| s.restart_to_install_updates);
        let accent = theme.accent;
        let description = if env_on {
            "Once an update has downloaded, Harness restarts into it when no agent is running, \
             nothing is unsaved and you've stepped away. Your windows, tabs and chats come back. \
             Off, it installs when you quit."
        } else {
            "Automatic updates are off (HARNESS_AUTO_UPDATE=0)."
        };
        let toggle = widgets::toggle_switch(theme, on)
            .id("restart-to-install-updates")
            .debug_selector(|| "restart-to-install-updates".into())
            .role(gpui::Role::Switch)
            .aria_label("Restart automatically to install updates")
            .aria_toggled(if on {
                gpui::Toggled::True
            } else {
                gpui::Toggled::False
            })
            .tab_index(0)
            .focus_visible(move |style| style.border_2().border_color(accent))
            .when(!env_on, |el| el.opacity(0.45))
            .when(env_on, |el| {
                el.cursor_pointer().on_click(cx.listener(|_, _, _, cx| {
                    settings::update(settings::SavePolicy::Immediate, cx, |s| {
                        s.restart_to_install_updates = !s.restart_to_install_updates;
                    });
                    cx.notify();
                }))
            });
        Some(
            widgets::card_row(theme, false)
                .child(widgets::row_tile(theme, crate::icons::RESTART))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(4.0))
                        .child(widgets::row_title(
                            theme,
                            "Restart automatically to install updates",
                        ))
                        .child(
                            div()
                                .text_size(crate::typography::ui_rems(12.0))
                                .line_height(px(18.0))
                                .text_color(theme.text_muted)
                                .child(SharedString::from(description)),
                        ),
                )
                .child(toggle)
                .into_any_element(),
        )
    }

    /// App update QA: show the toggle as a desktop install would.
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_desktop_update(&mut self, cx: &mut Context<Self>) {
        self.desktop_update = true;
        cx.notify();
    }

    fn open_rename(&mut self, device_id: String, current: String, cx: &mut Context<Self>) {
        let input = cx.new(|cx| ComposerInput::new("Device name", cx));
        input.update(cx, |input, cx| input.set_text(current, cx));
        let events = cx.subscribe(&input, |this: &mut Self, _, event, cx| {
            if matches!(event, ComposerInputEvent::Submitted) {
                this.submit_rename(cx);
            }
        });
        self.rename = Some(RenameDialog {
            device_id,
            input,
            focus_pending: true,
            _events: events,
        });
        cx.notify();
    }

    fn submit_rename(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.rename.take() else {
            return;
        };
        let name = dialog.input.read(cx).text().trim().to_string();
        if name.is_empty() {
            cx.notify();
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = serde_json::json!({
            "op": "renameDevice",
            "deviceId": dialog.device_id,
            "name": name,
        });
        self.task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(methods::MUTATE, params).await;
            this.update(cx, |page, cx| {
                if let Err(err) = result {
                    page.error = Some(format!("Rename failed: {err}").into());
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// Remove an offline device from the list (a finished cloud sandbox, a computer that is gone).
    /// It comes back by itself if that device starts Harness again.
    fn forget_device(&mut self, device_id: String, cx: &mut Context<Self>) {
        self.confirm_remove = None;
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = serde_json::json!({ "op": "forgetDevice", "deviceId": device_id });
        self.task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(methods::MUTATE, params).await;
            this.update(cx, |page, cx| {
                if let Err(err) = result {
                    page.error = Some(format!("Couldn't remove the device: {err}").into());
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn copy_id(&mut self, device_id: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(device_id.clone()));
        self.copied = Some(device_id);
        self.copy_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1500))
                .await;
            this.update(cx, |page, cx| {
                page.copied = None;
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// Escape closes the Rename dialog (the shell routes it here while
    /// Settings → Devices is open). False when no dialog was open.
    pub(crate) fn dismiss_on_escape(&mut self, cx: &mut Context<Self>) -> bool {
        if self.rename.take().is_none() {
            return false;
        }
        cx.notify();
        true
    }

    fn render_rename_dialog(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let viewport = window.viewport_size();
        let theme = Theme::of(cx).for_popup();
        let dialog = self.rename.as_mut()?;
        if std::mem::take(&mut dialog.focus_pending) {
            window.focus(&dialog.input.focus_handle(cx), cx);
        }
        let input = dialog.input.clone();
        let card = popover::dialog_card(&theme)
            .child(popover::dialog_title(&theme, "Rename device"))
            .child(
                div()
                    .mt(px(12.0))
                    .child(popover::dialog_field(input.into_any_element())),
            )
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(&theme, "Cancel", "rename-cancel")
                            .id("rename-cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.rename = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        popover::btn_primary(&theme, "Rename")
                            .id("rename-save")
                            .on_click(cx.listener(|this, _, _, cx| this.submit_rename(cx))),
                    ),
            )
            .into_any_element();
        Some(popover::modal("rename-device-dialog", viewport, card))
    }

    fn on_scroll_hovered(&mut self, hovered: &bool, _: &mut Window, cx: &mut Context<Self>) {
        if self.scroll.set_list_hovered(*hovered) {
            cx.notify();
        }
    }
}

impl popover::ScrollRailHost for DevicesPage {
    fn rail_bar(&mut self) -> &mut popover::MenuScrollbarState {
        self.scroll.rail_bar()
    }

    fn rail_scroll(&self) -> Option<gpui::ScrollHandle> {
        self.scroll.rail_scroll()
    }
}

/// Human platform label (harness settings.devices.tsx `platformLabel`).
pub fn platform_label(platform: &str) -> &str {
    match platform {
        "macos" | "darwin" => "macOS",
        "linux" => "Linux",
        "windows" => "Windows",
        "web" => "Web",
        "ios" => "iOS",
        "android" => "Android",
        other => other,
    }
}

/// Short device id for the click-to-copy chip (`abcd1234…wxyz`).
pub fn short_id(id: &str) -> String {
    if id.len() > 12 {
        format!("{}…{}", &id[..8], &id[id.len() - 4..])
    } else {
        id.to_string()
    }
}

impl Render for DevicesPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let now = Utc::now();
        let (devices, local_id, workspace_scope) = {
            let state = self.state.read(cx);
            (
                state.devices.clone(),
                state.local_device_id.clone(),
                state.workspace_scope,
            )
        };
        let copied = self.copied.clone();
        let confirm_remove = self.confirm_remove.clone();
        let dialog = self.render_rename_dialog(window, cx);
        let emerald = theme.success; // emerald-400
        let count = devices.len();

        let rows: Vec<AnyElement> = devices
            .into_iter()
            .enumerate()
            .map(|(ix, device)| {
                let online = device_online(device.last_seen_at, now);
                let is_local = local_id.as_deref() == Some(device.id.as_str());
                let id_copied = copied.as_deref() == Some(device.id.as_str());
                let copy_id = device.id.clone();
                let rename_id = device.id.clone();
                let rename_name = device.name.clone();
                let remove_id = device.id.clone();
                let confirming_remove = confirm_remove.as_deref() == Some(device.id.as_str());
                let update_controls =
                    self.render_remote_update(&device, is_local, online, &theme, cx);
                let platform_icon = match device.platform.as_str() {
                    "macos" | "darwin" => crate::icons::LAPTOP,
                    "web" => crate::icons::GLOBAL,
                    "ios" | "android" => crate::icons::SMARTPHONE,
                    _ => crate::icons::MONITOR,
                };
                // Presence lives ON the identity tile: a corner dot (emerald
                // online with a soft glow, faint offline), ringed by the card
                // tone so it "cuts" the tile — harness settings.devices.tsx
                // `border-2 border-[var(--card)]` +
                // `shadow-[0_0_6px_rgba(52,211,153,0.55)]`.
                let tile = widgets::row_tile(&theme, platform_icon).relative().child(
                    div()
                        .absolute()
                        .bottom(px(-3.0))
                        .right(px(-3.0))
                        .size(px(9.0))
                        .rounded_full()
                        .border_2()
                        .border_color(theme.surface)
                        .when(online, |el| {
                            el.bg(emerald).shadow(vec![gpui::BoxShadow {
                                color: emerald.opacity(0.55),
                                offset: gpui::point(px(0.0), px(0.0)),
                                blur_radius: px(6.0),
                                spread_radius: px(0.0),
                                inset: false,
                            }])
                        })
                        .when(!online, |el| el.bg(crate::theme::ink(0.22))),
                );
                // One quiet meta line: platform · version · (offline: last
                // seen) · id chip.
                let mut meta: Vec<AnyElement> = vec![
                    div()
                        .child(SharedString::from(
                            platform_label(&device.platform).to_string(),
                        ))
                        .into_any_element(),
                ];
                if let Some(version) = device.version.as_deref().filter(|v| !v.is_empty()) {
                    meta.push(
                        div()
                            .child(SharedString::from(format!("v{version}")))
                            .into_any_element(),
                    );
                }
                if !online {
                    meta.push(
                        div()
                            .child(SharedString::from(format!(
                                "Last seen {}",
                                format_last_seen(device.last_seen_at, now)
                            )))
                            .into_any_element(),
                    );
                }
                // "Added {time ago}" — always present (harness settings.devices.tsx).
                if let Some(created) = device.created_at {
                    meta.push(
                        div()
                            .child(SharedString::from(format!(
                                "Added {}",
                                format_last_seen(Some(created), now)
                            )))
                            .into_any_element(),
                    );
                }
                meta.push(
                    div()
                        .id(("device-id", ix))
                        .font_family(theme.font_mono.clone())
                        .text_size(crate::typography::ui_rems(10.5))
                        .text_color(if id_copied {
                            theme.success_muted.opacity(0.9)
                        } else {
                            theme.text_muted.opacity(0.5)
                        })
                        .cursor_pointer()
                        .hover(|s| s.text_color(theme.text_muted))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.copy_id(copy_id.clone(), cx);
                        }))
                        .child(SharedString::from(if id_copied {
                            "Copied".to_string()
                        } else {
                            short_id(&device.id)
                        }))
                        .into_any_element(),
                );

                let row = widgets::card_row(&theme, ix == 0)
                    .child(tile)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(widgets::row_title(&theme, device.name.clone()))
                            .child(widgets::meta_line(&theme, meta)),
                    )
                    .when(is_local, |el| {
                        el.child(
                            div()
                                .flex_none()
                                .text_size(px(10.5))
                                .text_color(theme.text_muted)
                                .child(if workspace_scope == Some(WorkspaceScope::Local) {
                                    "Local only"
                                } else {
                                    "This device"
                                }),
                        )
                    })
                    .child(
                        // `opacity-70 hover:opacity-100` (harness: also rises on
                        // row hover — gpui has no group-hover, so the button's
                        // own hover carries the reveal).
                        widgets::ghost_action(&theme)
                            .id(("device-rename", ix))
                            .opacity(0.7)
                            .hover(|s| {
                                s.opacity(1.0)
                                    .bg(crate::theme::ink(0.06))
                                    .text_color(theme.text)
                            })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.open_rename(rename_id.clone(), rename_name.clone(), cx);
                            }))
                            .child(
                                crate::icons::icon(crate::icons::PEN)
                                    .size(px(14.0))
                                    .text_color(theme.text_muted),
                            )
                            .child(SharedString::from("Rename")),
                    )
                    // Only offline devices, never this one: the engine refuses an online device,
                    // which would vanish until it restarted.
                    .when(!online && !is_local, |el| {
                        el.child(
                            widgets::ghost_action(&theme)
                                .id(("device-remove", ix))
                                .opacity(if confirming_remove { 1.0 } else { 0.7 })
                                .hover(|s| {
                                    s.opacity(1.0)
                                        .bg(crate::theme::ink(0.06))
                                        .text_color(theme.text)
                                })
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if this.confirm_remove.as_deref() == Some(remove_id.as_str()) {
                                        this.forget_device(remove_id.clone(), cx);
                                    } else {
                                        this.confirm_remove = Some(remove_id.clone());
                                        cx.notify();
                                    }
                                }))
                                .when(confirming_remove, |el| el.text_color(theme.danger))
                                .child(SharedString::from(if confirming_remove {
                                    "Remove?"
                                } else {
                                    "Remove"
                                })),
                        )
                    });
                div()
                    .child(row)
                    .children(update_controls)
                    .into_any_element()
            })
            .collect();

        let card = widgets::section_card(&theme);
        let card = if rows.is_empty() {
            card.child(
                div()
                    .px(px(20.0))
                    .py(px(40.0))
                    .text_center()
                    .text_size(crate::typography::ui_rems(14.0))
                    .text_color(theme.text_muted.opacity(0.6))
                    .child(SharedString::from("No devices registered")),
            )
        } else {
            card.children(rows)
        };

        let scrollbar = popover::rail(self, "devices-page-scrollbar", &theme, cx);
        div()
            .id("devices-page-host")
            .relative()
            .size_full()
            .on_hover(cx.listener(Self::on_scroll_hovered))
            .child(
                div()
                    .id("devices-page")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll.scroll)
                    .child(
                        widgets::page_column()
                            .child(widgets::page_header(
                                &theme,
                                "Devices",
                                (count > 0).then_some(count),
                            ))
                            .child(widgets::page_subtitle(
                                &theme,
                                devices_subtitle(workspace_scope),
                            ))
                            .child(self.render_version_card(&theme, cx))
                            .children(self.render_auto_restart_row(&theme, cx))
                            .when_some(self.error.clone(), |el, message| {
                                el.child(
                                    widgets::error_strip(&theme, message)
                                        .id("devices-error")
                                        .cursor_pointer()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.error = None;
                                            cx.notify();
                                        })),
                                )
                            })
                            .child(card),
                    ),
            )
            .children(scrollbar)
            .when_some(dialog, |el, dialog| el.child(dialog))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeDelta;

    #[test]
    fn version_card_offers_the_right_next_step() {
        let now = Utc::now();
        let idle = UpdatePhase::Idle;
        let status = |latest: Option<&str>, available: bool, error: Option<&str>| {
            harness_update::UpdateStatus {
                current_version: "0.2.92".into(),
                latest_version: latest.map(Into::into),
                update_available: available,
                checked_at: Some(now.timestamp_millis() - 120_000),
                error: error.map(Into::into),
                host: None,
            }
        };
        let up_to_date = status(Some("0.2.92"), false, None);
        assert_eq!(
            update_summary(Some(&up_to_date), true, &idle, false, now),
            ("Up to date · checked 2m ago".into(), UpdateAction::Check)
        );
        assert_eq!(
            update_summary(Some(&up_to_date), true, &idle, true, now).1,
            UpdateAction::None,
            "no second check while one is running"
        );
        let newer = status(Some("0.2.93"), true, None);
        assert_eq!(
            update_summary(Some(&newer), true, &idle, false, now),
            (
                "Harness v0.2.93 is available.".into(),
                UpdateAction::Update("0.2.93".into())
            )
        );
        let failed = status(None, false, Some("offline"));
        assert_eq!(
            update_summary(Some(&failed), true, &idle, false, now),
            ("Couldn't check for updates: offline".into(), UpdateAction::Check)
        );
        assert_eq!(
            update_summary(Some(&newer), false, &idle, false, now).1,
            UpdateAction::None
        );
        assert_eq!(
            update_summary(None, true, &idle, false, now).1,
            UpdateAction::None
        );
    }

    #[test]
    fn version_card_follows_the_download_the_titlebar_started() {
        let now = Utc::now();
        let newer = harness_update::UpdateStatus {
            current_version: "0.2.134".into(),
            latest_version: Some("0.2.135".into()),
            update_available: true,
            checked_at: Some(now.timestamp_millis()),
            error: None,
            host: None,
        };
        let summary =
            |phase: UpdatePhase, desktop| update_summary(Some(&newer), desktop, &phase, false, now);
        assert_eq!(
            summary(UpdatePhase::Downloading, true),
            ("Downloading v0.2.135…".into(), UpdateAction::Downloading),
            "no second download while one runs"
        );
        assert_eq!(
            summary(UpdatePhase::Ready("0.2.135".into()), true),
            (
                "Harness v0.2.135 is downloaded and ready to install.".into(),
                UpdateAction::Restart("0.2.135".into())
            )
        );
        assert_eq!(
            summary(UpdatePhase::Failed("offline".into()), true),
            (
                "Updating to v0.2.135 failed: offline".into(),
                UpdateAction::Retry("0.2.135".into())
            )
        );
        // A staged update still restarts even while a check is running.
        assert_eq!(
            update_summary(
                Some(&newer),
                true,
                &UpdatePhase::Ready("0.2.135".into()),
                true,
                now
            )
            .1,
            UpdateAction::Restart("0.2.135".into())
        );
        // Report-only installs never get a download button.
        assert_eq!(
            summary(UpdatePhase::Ready("0.2.135".into()), false).1,
            UpdateAction::None
        );
    }

    #[test]
    fn presence_window() {
        let now = Utc::now();
        assert!(device_online(Some(now - TimeDelta::seconds(10)), now));
        assert!(device_online(Some(now - TimeDelta::seconds(70)), now));
        assert!(!device_online(Some(now - TimeDelta::seconds(71)), now));
        assert!(!device_online(None, now));
        // Clock skew (future) counts as online.
        assert!(device_online(Some(now + TimeDelta::seconds(30)), now));
    }

    #[test]
    fn last_seen_formatting() {
        let now = Utc::now();
        assert_eq!(format_last_seen(None, now), "never seen");
        assert_eq!(
            format_last_seen(Some(now - TimeDelta::seconds(30)), now),
            "just now"
        );
        assert_eq!(
            format_last_seen(Some(now - TimeDelta::minutes(5)), now),
            "5m ago"
        );
        assert_eq!(
            format_last_seen(Some(now - TimeDelta::hours(3)), now),
            "3h ago"
        );
        assert_eq!(
            format_last_seen(Some(now - TimeDelta::days(2)), now),
            "2d ago"
        );
    }

    #[gpui::test]
    fn escape_closes_the_rename_dialog(cx: &mut gpui::TestAppContext) {
        let state = cx.new(|_| crate::state::AppState::new());
        let page = cx.new(|cx| DevicesPage::new(state, cx));
        page.update(cx, |page, cx| {
            assert!(!page.dismiss_on_escape(cx), "nothing open, nothing closed");
            page.open_rename("d2".into(), "Laptop".into(), cx);
            assert!(page.rename.as_ref().is_some_and(|d| d.focus_pending));
            assert!(page.dismiss_on_escape(cx));
            assert!(page.rename.is_none());
        });
    }

    #[test]
    fn local_subtitle_does_not_claim_synced_metadata() {
        let copy = devices_subtitle(Some(WorkspaceScope::Local));
        assert!(copy.contains("local workspace"));
        assert!(!copy.contains("synced"));
    }
}
