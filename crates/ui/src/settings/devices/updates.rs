//! Per-device update controls. Only the expanded host is watched; closing the
//! page or selecting another host drops the scoped relay subscription.
use super::*;
use harness_update::{HostUpdateMode, HostUpdatePhase, UpdateStatus};

#[derive(Default)]
pub(super) struct RemoteUpdate {
    device: Option<String>,
    status: Option<UpdateStatus>,
    error: Option<String>,
    notice: Option<String>,
    watch: Option<Task<()>>,
    action: Option<Task<()>>,
    busy: bool,
    #[cfg(feature = "appshots-fixture")]
    legacy_fixture: bool,
}

fn host_platform(platform: &str) -> bool {
    matches!(platform, "linux" | "macos" | "darwin" | "windows")
}

/// Never infer remote-install capability from a version number or an OS.
fn remote_summary(status: &UpdateStatus) -> (String, bool) {
    let Some(host) = &status.host else {
        return (
            "This older host doesn't report update controls. Update Harness on it once to enable remote scheduling.".into(),
            false,
        );
    };
    match host.mode {
        HostUpdateMode::Desktop => {
            let text = if let Some(error) = &status.error {
                format!("Couldn't check for updates: {error}")
            } else if host.phase == HostUpdatePhase::Checking {
                "Checking for updates…".into()
            } else if !host.automatic {
                "Automatic downloads are disabled on this computer. Update from its desktop app; remote restarts aren't offered.".into()
            } else {
                "This computer's desktop app installs its own updates. Enable automatic restarts in its Settings → Devices; it waits for idle chats and unsaved work.".into()
            };
            return (text, false);
        }
        HostUpdateMode::Manual => return (
            "This is a source or package-managed install. Update it on that computer using its original installation method.".into(),
            false,
        ),
        HostUpdateMode::Managed => {}
    }
    let text = match host.phase {
        HostUpdatePhase::Checking => "Checking for updates…".into(),
        HostUpdatePhase::Downloading => "Downloading the update. Your chats can keep running.".into(),
        HostUpdatePhase::WaitingForIdle => "Update downloaded. Waiting for chats to finish and terminals to close before restarting.".into(),
        HostUpdatePhase::Restarting => "Restarting into the update. This device will reconnect.".into(),
        HostUpdatePhase::Failed => format!("Update failed: {}", status.error.as_deref().unwrap_or("refresh to try again")),
        HostUpdatePhase::Idle if host.automatic => "Automatic updates are on. This host installs updates when chats and terminals are idle.".into(),
        HostUpdatePhase::Idle => "Automatic updates are off on this host. You can request one update without changing that setting.".into(),
    };
    let can_queue = status.update_available
        && matches!(host.phase, HostUpdatePhase::Idle | HostUpdatePhase::Failed);
    (text, can_queue)
}

fn can_check(status: &UpdateStatus) -> bool {
    status.host.as_ref().is_some_and(|host| {
        host.mode != HostUpdateMode::Manual
            && matches!(host.phase, HostUpdatePhase::Idle | HostUpdatePhase::Failed)
    })
}

impl DevicesPage {
    pub(super) fn reconcile_remote_update(&mut self, cx: &mut Context<Self>) {
        let Some(id) = &self.remote_update.device else {
            return;
        };
        let online = self
            .state
            .read(cx)
            .devices
            .iter()
            .any(|d| &d.id == id && device_online(d.last_seen_at, Utc::now()));
        if !online {
            self.remote_update.watch = None;
            self.remote_update.action = None;
            self.remote_update.status = None;
            self.remote_update.notice = None;
            self.remote_update.busy = false;
            self.remote_update.error =
                Some("Offline. Open Harness on this computer to check its updates.".into());
        }
    }

    fn watch_remote_update(&mut self, id: String, cx: &mut Context<Self>) {
        self.remote_update = RemoteUpdate {
            device: Some(id.clone()),
            ..Default::default()
        };
        self.reconcile_remote_update(cx);
        if self.remote_update.error.is_some() {
            cx.notify();
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.remote_update.error = Some("Engine not connected".into());
            cx.notify();
            return;
        };
        self.remote_update.watch = Some(cx.spawn(async move |this, cx| {
            let result = async {
                let mut stream = engine.client().subscribe_scoped(
                    methods::UPDATE_STATUS, serde_json::json!({ "targetDeviceId": id }),
                ).await.map_err(|e| e.to_string())?;
                // A disconnected/old host must not leave an endless spinner.
                let first = {
                    let next = stream.recv();
                    let timeout = cx.background_executor().timer(UPDATE_CHECK_TIMEOUT);
                    futures::pin_mut!(next, timeout);
                    match futures::future::select(next, timeout).await {
                        futures::future::Either::Left((value, _)) => value,
                        futures::future::Either::Right(_) => return Err("The host didn't reply. Refresh when it is online.".to_string()),
                    }
                };
                let mut next = first;
                while let Some(value) = next {
                    let status: UpdateStatus = serde_json::from_value(value).map_err(|e| format!("Invalid update status: {e}"))?;
                    if this.update(cx, |page, cx| {
                        if page.remote_update.device.as_ref() == Some(&id) {
                            page.remote_update.status = Some(status);
                            page.remote_update.error = None;
                            cx.notify();
                        }
                    }).is_err() { return Ok(()) }
                    next = stream.recv().await;
                }
                Err("Connection closed. The host may be restarting; refresh to confirm its version.".into())
            }.await;
            if let Err(error) = result {
                this.update(cx, |page, cx| {
                    if page.remote_update.device.as_ref() == Some(&id) {
                        page.remote_update.error = Some(error);
                        page.remote_update.status = None;
                        page.remote_update.notice = None;
                        cx.notify();
                    }
                }).ok();
            }
        }));
        cx.notify();
    }

    fn remote_update_command(&mut self, queue: bool, cx: &mut Context<Self>) {
        if self.remote_update.busy {
            return;
        }
        let Some(id) = self.remote_update.device.clone() else {
            return;
        };
        self.reconcile_remote_update(cx);
        if self.remote_update.error.is_some() {
            return;
        }
        if !self.remote_update.status.as_ref().is_some_and(|status| {
            if queue {
                remote_summary(status).1
            } else {
                can_check(status)
            }
        }) {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.remote_update.busy = true;
        self.remote_update.notice = None;
        self.remote_update.action = Some(cx.spawn(async move |this, cx| {
            let method = if queue { methods::QUEUE_UPDATE } else { methods::CHECK_FOR_UPDATES };
            let result = engine.client().call(method, serde_json::json!({ "targetDeviceId": id })).await;
            this.update(cx, |page, cx| {
                if page.remote_update.device.as_ref() != Some(&id) { return }
                page.remote_update.busy = false;
                match result {
                    Ok(_) => page.remote_update.notice = Some(if queue {
                        "Update requested. The host will wait for chats and terminals to finish.".into()
                    } else { "Update check requested.".into() }),
                    Err(error) => page.remote_update.error = Some(format!("Request failed: {error}")),
                }
                cx.notify();
            }).ok();
        }));
        cx.notify();
    }

    pub(super) fn render_remote_update(
        &mut self,
        device: &harness_proto::Device,
        local: bool,
        online: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if local || !host_platform(&device.platform) {
            return None;
        }
        #[cfg(feature = "appshots-fixture")]
        if self.remote_update.legacy_fixture {
            return None;
        }
        let selected = self.remote_update.device.as_deref() == Some(&device.id);
        let id = device.id.clone();
        let older = device
            .version
            .as_deref()
            .zip(
                self.state
                    .read(cx)
                    .update
                    .as_ref()
                    .and_then(|s| s.latest_version.as_deref()),
            )
            .is_some_and(|(current, latest)| harness_update::version_newer(latest, current));
        let button_id = format!("device-updates-{}", device.id);
        let toggle = widgets::ghost_action(theme)
            .id(SharedString::from(button_id))
            .on_click(cx.listener(move |page, _, _, cx| {
                if page.remote_update.device.as_ref() == Some(&id) {
                    page.remote_update = RemoteUpdate::default();
                    cx.notify();
                } else {
                    page.watch_remote_update(id.clone(), cx);
                }
            }))
            .child(if selected {
                "Hide updates"
            } else if older {
                "Update available · Details"
            } else {
                "Updates"
            });
        let mut panel = div()
            .pl(px(66.0))
            .pr(px(16.0))
            .pb(px(12.0))
            .flex()
            .flex_col()
            .gap(px(6.0))
            .text_size(crate::typography::ui_rems(12.0))
            .text_color(theme.text_muted)
            .child(toggle);
        if selected {
            let (line, can_queue) = if !online {
                (
                    "Offline. Open Harness on this computer to check its updates.".into(),
                    false,
                )
            } else if let Some(error) = &self.remote_update.error {
                (error.clone(), false)
            } else if let Some(status) = &self.remote_update.status {
                remote_summary(status)
            } else {
                ("Reading this host's update status…".into(), false)
            };
            panel = panel.child(SharedString::from(line));
            if online && let Some(status) = &self.remote_update.status {
                let version = match (&status.latest_version, &status.error) {
                    (_, Some(_)) => format!(
                        "Installed v{} · last check needs attention",
                        status.current_version
                    ),
                    (Some(latest), None) if status.update_available => format!(
                        "Installed v{} · available v{latest}",
                        status.current_version
                    ),
                    (Some(_), None) => {
                        format!("Installed v{} · up to date", status.current_version)
                    }
                    (None, None) => {
                        format!("Installed v{} · not checked yet", status.current_version)
                    }
                };
                panel = panel.child(SharedString::from(version));
            }
            if let Some(notice) = &self.remote_update.notice {
                panel = panel.child(SharedString::from(notice.clone()));
            }
            if online && self.remote_update.busy {
                panel = panel.child("Contacting host…");
            }
            if online && !self.remote_update.busy {
                let refresh_id = device.id.clone();
                let mut actions = div().flex().gap(px(8.0)).child(
                    widgets::ghost_action(theme)
                        .id("remote-update-refresh")
                        .on_click(cx.listener(move |page, _, _, cx| {
                            page.watch_remote_update(refresh_id.clone(), cx)
                        }))
                        .child("Refresh status"),
                );
                if self.remote_update.status.as_ref().is_some_and(can_check)
                    && self.remote_update.error.is_none()
                {
                    actions = actions.child(
                        widgets::ghost_action(theme)
                            .id("remote-update-check")
                            .on_click(
                                cx.listener(|page, _, _, cx| page.remote_update_command(false, cx)),
                            )
                            .child("Check now"),
                    );
                }
                if can_queue {
                    actions = actions.child(
                        popover::btn_primary(theme, "Update when idle")
                            .id("remote-update-queue")
                            .debug_selector(|| "remote-update-queue".into())
                            .on_click(
                                cx.listener(|page, _, _, cx| page.remote_update_command(true, cx)),
                            ),
                    );
                }
                panel = panel.child(actions);
            }
        }
        Some(panel.into_any_element())
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_remote_update(
        &mut self,
        device: &str,
        status: Option<UpdateStatus>,
        cx: &mut Context<Self>,
    ) {
        self.remote_update = RemoteUpdate {
            device: status.as_ref().map(|_| device.to_string()),
            legacy_fixture: status.is_none(),
            status,
            ..Default::default()
        };
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_update::HostUpdateStatus;

    fn status(mode: HostUpdateMode, phase: HostUpdatePhase, automatic: bool) -> UpdateStatus {
        UpdateStatus {
            current_version: "1.0.0".into(),
            latest_version: Some("1.0.1".into()),
            update_available: true,
            checked_at: None,
            error: None,
            host: Some(HostUpdateStatus {
                mode,
                automatic,
                phase,
            }),
        }
    }

    #[test]
    fn remote_updates_require_explicit_managed_capability_and_available_release() {
        let mut s = status(HostUpdateMode::Managed, HostUpdatePhase::Idle, false);
        assert!(
            remote_summary(&s).1,
            "an explicit one-off request respects the opt-out"
        );
        assert!(remote_summary(&s).0.contains("off"));
        assert!(can_check(&s));
        s.update_available = false;
        assert!(!remote_summary(&s).1);
        s.update_available = true;
        s.host = None;
        assert!(!remote_summary(&s).1, "never use ApplyUpdate on old hosts");
        assert!(!can_check(&s), "older hosts cannot forward update checks");
        assert!(!can_check(&status(
            HostUpdateMode::Manual,
            HostUpdatePhase::Idle,
            true
        )));
        let mut desktop = status(HostUpdateMode::Desktop, HostUpdatePhase::Idle, false);
        assert!(remote_summary(&desktop).0.contains("disabled"));
        desktop.error = Some("offline".into());
        assert!(remote_summary(&desktop).0.contains("offline"));
        for mode in [HostUpdateMode::Desktop, HostUpdateMode::Manual] {
            assert!(!remote_summary(&status(mode, HostUpdatePhase::Idle, true)).1);
        }
        for phase in [
            HostUpdatePhase::Checking,
            HostUpdatePhase::Downloading,
            HostUpdatePhase::WaitingForIdle,
            HostUpdatePhase::Restarting,
        ] {
            let busy = status(HostUpdateMode::Managed, phase, true);
            assert!(!remote_summary(&busy).1);
            assert!(!can_check(&busy));
        }
        assert!(
            remote_summary(&status(
                HostUpdateMode::Managed,
                HostUpdatePhase::WaitingForIdle,
                true
            ))
            .0
            .contains("terminals")
        );
        assert!(!host_platform("ios"));
        assert!(!host_platform("android"));
        assert!(!host_platform("web"));
        assert!(host_platform("linux"));
    }
}
