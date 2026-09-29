//! Settings → Devices (feature-inventory §1.5): the device registry — name,
//! platform, last-seen, presence dot, a "This device" badge, click-to-copy id,
//! a Rename dialog (Mutate renameDevice), and Remove for an offline device
//! (Mutate forgetDevice, behind a confirm).

use chrono::{DateTime, Utc};
use gpui::{
    AnyElement, ClipboardItem, Context, Entity, SharedString, Subscription, Task, Window, div,
    prelude::*, px,
};
use std::time::Duration;

use harness_proto::WorkspaceScope;
use harness_rpc::methods;

use crate::composer::{ComposerInput, ComposerInputEvent};
use crate::popover;
use crate::settings::widgets;
use crate::state::AppState;
use crate::theme::Theme;

/// A device that pinged within this window shows a presence dot (engines
/// heartbeat every 15s; 70s tolerates a couple of missed beats).
pub const DEVICE_ONLINE_WINDOW_SECS: i64 = 70;

/// Confirm-dialog copy for removing a device that hosts `sessions` chats. Pure.
pub fn remove_device_copy(name: &str, sessions: usize) -> String {
    let what = match sessions {
        0 => format!("Removing “{name}” takes it off your devices list."),
        1 => format!("Removing “{name}” also deletes its 1 session from every device."),
        n => format!("Removing “{name}” also deletes its {n} sessions from every device."),
    };
    format!("{what} If it comes back online it rejoins on its own, without them.")
}

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
    None,
}

/// The version card's status line and button. `desktop` = this install can
/// update itself (the macOS app, the portable Windows package). Pure.
pub fn update_summary(
    status: Option<&harness_update::UpdateStatus>,
    desktop: bool,
    checking: bool,
    now: DateTime<Utc>,
) -> (String, UpdateAction) {
    let Some(status) = status.filter(|_| desktop) else {
        return (
            "This build doesn't update itself. Install the latest release to update.".into(),
            UpdateAction::None,
        );
    };
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
    _events: Subscription,
}

pub struct DevicesPage {
    state: Entity<AppState>,
    scroll: widgets::PageScroll,
    rename: Option<RenameDialog>,
    /// Device id awaiting the Remove confirm.
    remove_confirm: Option<String>,
    /// Device id whose id-chip shows "Copied" right now.
    copied: Option<String>,
    error: Option<SharedString>,
    task: Option<Task<()>>,
    copy_task: Option<Task<()>>,
    /// A manual update check in flight: the status it started from.
    checking: Option<Option<harness_update::UpdateStatus>>,
    check_task: Option<Task<()>>,
    desktop_update: bool,
    _observe: Subscription,
}

impl DevicesPage {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&state, |_, _, cx| cx.notify());
        Self {
            state,
            scroll: widgets::PageScroll::default(),
            rename: None,
            remove_confirm: None,
            copied: None,
            error: None,
            task: None,
            copy_task: None,
            checking: None,
            check_task: None,
            desktop_update: harness_update::detect_install().supports_desktop_update(),
            _observe: observe,
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
        let (line, action) = update_summary(
            status.as_ref(),
            self.desktop_update,
            self.checking.is_some(),
            Utc::now(),
        );
        let button = match action {
            UpdateAction::Check => Some(
                popover::btn_ghost(theme, "Check for updates", "check-for-updates-fade")
                    .id("check-for-updates")
                    .on_click(cx.listener(|page, _, _, cx| page.check_for_updates(cx)))
                    .into_any_element(),
            ),
            UpdateAction::Update(latest) => Some(
                popover::btn_primary(theme, &format!("Update to v{latest}"))
                    .id("start-app-update")
                    .cursor_pointer()
                    .on_click(|_, window, cx| {
                        window.dispatch_action(Box::new(crate::shell::StartAppUpdate), cx)
                    })
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

    fn submit_remove(&mut self, cx: &mut Context<Self>) {
        let Some(device_id) = self.remove_confirm.take() else {
            return;
        };
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = serde_json::json!({
            "op": "forgetDevice",
            "deviceId": device_id,
        });
        self.task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(methods::MUTATE, params).await;
            this.update(cx, |page, cx| {
                if let Err(err) = result {
                    page.error = Some(format!("Remove failed: {err}").into());
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn render_remove_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let theme = Theme::of(cx).for_popup();
        let device_id = self.remove_confirm.as_deref()?;
        let (name, sessions) = {
            let state = self.state.read(cx);
            (
                state.device_name(device_id).unwrap_or("this device").to_string(),
                state.chats.iter().filter(|c| c.device_id == device_id).count(),
            )
        };
        let card = popover::dialog_card(&theme)
            .child(popover::dialog_title(&theme, "Remove device?"))
            .child(
                div()
                    .mt(px(6.0))
                    .child(popover::dialog_body(&theme, remove_device_copy(&name, sessions))),
            )
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(&theme, "Cancel", "remove-device-cancel")
                            .id("remove-device-cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.remove_confirm = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        popover::btn_danger(&theme, "Remove")
                            .id("remove-device-confirm")
                            .on_click(cx.listener(|this, _, _, cx| this.submit_remove(cx))),
                    ),
            )
            .into_any_element();
        Some(popover::modal("remove-device-dialog", viewport, card))
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

    fn render_rename_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let theme = Theme::of(cx).for_popup();
        let dialog = self.rename.as_ref()?;
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
        let dialog = match self.render_rename_dialog(window.viewport_size(), cx) {
            Some(dialog) => Some(dialog),
            None => self.render_remove_dialog(window.viewport_size(), cx),
        };
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
                // Only a device that is offline and not this one can go: this
                // device would re-register on its next boot, and a live one
                // is still hosting its sessions (the engine refuses both too).
                let removable = !online && !is_local;
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

                widgets::card_row(&theme, ix == 0)
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
                    .when(removable, |el| {
                        el.child(
                            widgets::ghost_action(&theme)
                                .id(("device-remove", ix))
                                .opacity(0.7)
                                .hover(|s| {
                                    s.opacity(1.0)
                                        .bg(crate::theme::ink(0.06))
                                        .text_color(theme.danger)
                                })
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.remove_confirm = Some(remove_id.clone());
                                    cx.notify();
                                }))
                                .child(
                                    crate::icons::icon(crate::icons::TRASH_BIN_MINIMALISTIC)
                                        .size(px(14.0))
                                        .text_color(theme.text_muted),
                                )
                                .child(SharedString::from("Remove")),
                        )
                    })
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
        let status = |latest: Option<&str>, available: bool, error: Option<&str>| {
            harness_update::UpdateStatus {
                current_version: "0.2.92".into(),
                latest_version: latest.map(Into::into),
                update_available: available,
                checked_at: Some(now.timestamp_millis() - 120_000),
                error: error.map(Into::into),
            }
        };
        let up_to_date = status(Some("0.2.92"), false, None);
        assert_eq!(
            update_summary(Some(&up_to_date), true, false, now),
            ("Up to date · checked 2m ago".into(), UpdateAction::Check)
        );
        assert_eq!(
            update_summary(Some(&up_to_date), true, true, now).1,
            UpdateAction::None,
            "no second check while one is running"
        );
        let newer = status(Some("0.2.93"), true, None);
        assert_eq!(
            update_summary(Some(&newer), true, false, now),
            (
                "Harness v0.2.93 is available.".into(),
                UpdateAction::Update("0.2.93".into())
            )
        );
        let failed = status(None, false, Some("offline"));
        assert_eq!(
            update_summary(Some(&failed), true, false, now),
            ("Couldn't check for updates: offline".into(), UpdateAction::Check)
        );
        assert_eq!(update_summary(Some(&newer), false, false, now).1, UpdateAction::None);
        assert_eq!(update_summary(None, true, false, now).1, UpdateAction::None);
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

    #[test]
    fn remove_copy_counts_what_goes_with_the_device() {
        let none = remove_device_copy("old sandbox", 0);
        assert!(none.contains("takes it off your devices list"));
        assert!(!none.contains("session"));
        assert!(remove_device_copy("mini", 1).contains("its 1 session from every device"));
        let many = remove_device_copy("mini", 4);
        assert!(many.contains("its 4 sessions from every device"));
        assert!(many.contains("rejoins on its own"));
    }

    #[test]
    fn local_subtitle_does_not_claim_synced_metadata() {
        let copy = devices_subtitle(Some(WorkspaceScope::Local));
        assert!(copy.contains("local workspace"));
        assert!(!copy.contains("synced"));
    }
}
