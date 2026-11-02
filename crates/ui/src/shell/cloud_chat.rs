//! Open a fresh, unsent conversation on an explicitly identified cloud device.
use super::*;
use crate::codegraff_sandboxes::{CodegraffSandbox, is_temporary};

fn online_destination<'a>(
    sandbox: &CodegraffSandbox,
    devices: &'a [harness_proto::Device],
    now: chrono::DateTime<Utc>,
) -> Result<&'a harness_proto::Device, &'static str> {
    if is_temporary(sandbox) || sandbox.provider != "fleet" {
        return Err("This sandbox cannot host a Harness chat.");
    }
    if sandbox.state != "running" {
        return Err("Resume this computer and wait for it to connect.");
    }
    if !sandbox.harness {
        return Err("Set up Harness on this computer first.");
    }
    let name = sandbox
        .device_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .ok_or("This computer has not reported its Harness device yet.")?;
    // The gateway explicitly associates this registration name with this
    // sandbox. Never guess from a display title, a prefix, or a generic name.
    // An ambiguous registration is not enough evidence to choose a computer.
    let mut matches = devices
        .iter()
        .filter(|device| device.name == name && device.platform == "linux");
    let device = matches
        .next()
        .ok_or("Waiting for this computer to connect to Harness.")?;
    if matches.next().is_some() || device.id.trim().is_empty() {
        return Err("The device for this computer is ambiguous. Check it in Settings.");
    }
    if !crate::settings::devices::device_online(device.last_seen_at, now) {
        return Err("Waiting for this computer to reconnect to Harness.");
    }
    Ok(device)
}

impl Shell {
    /// The exact reachable registration, or a short reason the action is disabled.
    /// A machine being Running by itself does not prove Harness is reachable.
    pub(super) fn cloud_chat_destination(
        &self,
        sandbox_id: &str,
        cx: &App,
    ) -> Result<String, &'static str> {
        let state = self.state.read(cx);
        let list = state
            .cloud_sandboxes()
            .filter(|list| list.enabled)
            .ok_or("Cloud computers are unavailable.")?;
        let mut matches = list
            .sandboxes
            .iter()
            .filter(|sandbox| sandbox.id == sandbox_id);
        let sandbox = matches
            .next()
            .ok_or("This computer is no longer available.")?;
        if matches.next().is_some() {
            return Err("This computer could not be identified. Refresh it in Settings.");
        }
        if let Some(name) = sandbox.device_name.as_deref().map(str::trim)
            && list
                .sandboxes
                .iter()
                .filter(|other| other.device_name.as_deref().map(str::trim) == Some(name))
                .count()
                != 1
        {
            return Err("More than one computer names this device. Check them in Settings.");
        }
        online_destination(sandbox, &state.devices, Utc::now()).map(|device| device.id.clone())
    }

    /// Park all existing work and open one empty, projectless cloud draft in its
    /// own workspace session. No engine conversation or prompt is created/sent.
    pub(super) fn new_chat_on_cloud_computer(
        &mut self,
        sandbox_id: &str,
        cx: &mut Context<Self>,
    ) -> Result<(), &'static str> {
        // Re-check on activation: a rendered enabled button can become stale.
        let device = self.cloud_chat_destination(sandbox_id, cx)?;
        self.ensure_workspace_sessions(cx);
        self.sync_panel_workspace(cx);
        self.park_workspace_draft(cx);
        let mut draft = self.current_canvas_draft(cx).fresh();
        draft.target = Some(crate::pickers::CanvasTarget {
            space: None,
            no_project: true,
            device: Some(device),
        });
        self.chat_tabs[self.chat_tab] = self.park_chat_tab(cx);
        let tab = chat_tabs::ChatTab {
            project: None,
            draft: Some(draft),
            ..Default::default()
        };
        self.session_overview = false;
        self.command_palette = None;
        self.route = Route::Chat;
        self.close_spaces_menu(cx);
        self.chat_tab = self.chat_tabs.len();
        self.chat_tabs.push(tab.clone());
        self.boot_restored = true;
        self.load_chat_tab_without_window(tab, cx);
        self.sync_panel_workspace(cx);
        self.persist_chat_tabs(cx);
        self.focus_composer(cx);
        cx.notify();
        Ok(())
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_chat_ready(&mut self, cx: &mut Context<Self>) {
        // Explicitly synthetic registration; never probes or starts a real host.
        self.state.update(cx, |state, cx| {
            state
                .devices
                .retain(|device| device.id != "cloud-fixture-studio");
            state.devices.push(harness_proto::Device {
                id: "cloud-fixture-studio".into(),
                name: "Harness cloud fixture-studio".into(),
                platform: "linux".into(),
                last_seen_at: Some(Utc::now()),
                created_at: None,
                version: None,
                cursor_sdk_version: None,
                capabilities: vec![],
            });
            cx.notify();
        });
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_chat_is_empty_and_targeted(&self, cx: &App) -> bool {
        let state = self.state.read(cx);
        let input = self.composer.read(cx).canvas_input(cx);
        state.selected_chat.is_none()
            && state.selected_space.is_none()
            && state.no_project
            && state.selected_device.as_deref() == Some("cloud-fixture-studio")
            && input.text.is_empty()
            && input.stage.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codegraff_sandboxes::CodegraffSandboxes;

    fn sandbox() -> CodegraffSandbox {
        CodegraffSandbox {
            id: "cloud-fixture".into(),
            provider: "fleet".into(),
            state: "running".into(),
            harness: true,
            device_name: Some("Harness cloud fixture-studio".into()),
            tier: Some("standard".into()),
            ..Default::default()
        }
    }

    fn device(now: chrono::DateTime<Utc>) -> harness_proto::Device {
        harness_proto::Device {
            id: "cloud-fixture-studio".into(),
            name: "Harness cloud fixture-studio".into(),
            platform: "linux".into(),
            last_seen_at: Some(now),
            created_at: None,
            version: None,
            cursor_sdk_version: None,
            capabilities: vec![],
        }
    }

    fn seed(shell: &mut Shell, cx: &mut Context<Shell>) {
        shell.state.update(cx, |state, cx| {
            state.devices.push(device(Utc::now()));
            state.apply_cloud_sandboxes(
                Some(CodegraffSandboxes {
                    enabled: true,
                    sandboxes: vec![sandbox()],
                    sizes: vec![],
                }),
                cx,
            );
        });
    }

    #[test]
    fn cloud_chat_destination_requires_a_unique_explicit_live_device() {
        let now = Utc::now();
        let cloud = sandbox();
        let registered = device(now);
        assert_eq!(
            online_destination(&cloud, std::slice::from_ref(&registered), now)
                .unwrap()
                .id,
            "cloud-fixture-studio"
        );
        assert!(online_destination(&cloud, &[], now).is_err());
        assert!(
            online_destination(&cloud, &[registered.clone(), registered.clone()], now).is_err()
        );
        for bad in [
            harness_proto::Device {
                platform: "macos".into(),
                ..registered.clone()
            },
            harness_proto::Device {
                name: "Same visible title".into(),
                ..registered.clone()
            },
            harness_proto::Device {
                last_seen_at: None,
                ..registered.clone()
            },
            harness_proto::Device {
                last_seen_at: Some(now - chrono::TimeDelta::seconds(71)),
                ..registered.clone()
            },
        ] {
            assert!(online_destination(&cloud, &[bad], now).is_err());
        }
        for bad in [
            CodegraffSandbox {
                state: "paused".into(),
                ..cloud.clone()
            },
            CodegraffSandbox {
                state: "starting".into(),
                ..cloud.clone()
            },
            CodegraffSandbox {
                harness: false,
                ..cloud.clone()
            },
            CodegraffSandbox {
                device_name: None,
                ..cloud.clone()
            },
            CodegraffSandbox {
                tier: Some("ephemeral".into()),
                ..cloud.clone()
            },
            CodegraffSandbox {
                provider: "daytona".into(),
                ..cloud
            },
        ] {
            assert!(online_destination(&bad, std::slice::from_ref(&registered), now).is_err());
        }
    }

    #[gpui::test]
    fn cloud_chat_quick_action_preserves_the_original_session_and_draft(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, _, cx| {
                shell.boot_restored = true;
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                shell.workspace_new_chat(cx);
                shell.composer.update(cx, |composer, cx| {
                    composer.set_canvas_input(
                        crate::pickers::CanvasInput {
                            text: "Keep my local project draft".into(),
                            ..Default::default()
                        },
                        cx,
                    )
                });
                let original_id = shell.chat_tabs[shell.chat_tab].id.clone();
                let original_draft = shell.current_canvas_draft(cx);
                let original_tabs = shell.panel_layout(cx).unwrap().panels[0].tabs.clone();
                let chats = shell.state.read(cx).chats.clone();
                let spaces = shell.state.read(cx).spaces.clone();
                let count = shell.chat_tabs.len();
                seed(shell, cx);

                shell
                    .new_chat_on_cloud_computer("cloud-fixture", cx)
                    .unwrap();
                assert_eq!(shell.chat_tabs.len(), count + 1);
                assert_ne!(shell.chat_tabs[shell.chat_tab].id, original_id);
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("cloud-fixture-studio")
                );
                assert!(shell.state.read(cx).selected_chat.is_none());
                assert!(shell.state.read(cx).selected_space.is_none());
                assert!(shell.state.read(cx).no_project);
                assert!(shell.composer.read(cx).canvas_input(cx).text.is_empty());
                assert!(shell.composer.read(cx).canvas_input(cx).stage.is_empty());
                assert_eq!(shell.state.read(cx).chats, chats);
                assert_eq!(shell.state.read(cx).spaces, spaces);
                let parked = shell
                    .chat_tabs
                    .iter()
                    .find(|tab| tab.id == original_id)
                    .unwrap();
                assert_eq!(parked.project.as_deref(), Some("a"));
                assert_eq!(parked.draft.as_ref(), Some(&original_draft));

                shell.activate_workspace_session(&original_id, cx);
                assert_eq!(shell.state.read(cx).selected_space.as_deref(), Some("a"));
                assert_eq!(shell.current_canvas_draft(cx), original_draft);
                assert_eq!(
                    shell.panel_layout(cx).unwrap().panels[0].tabs,
                    original_tabs
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn cloud_chat_rechecks_reachability_without_touching_work(cx: &mut gpui::TestAppContext) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, _, cx| {
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                seed(shell, cx);
                assert!(shell.cloud_chat_destination("cloud-fixture", cx).is_ok());
                let tabs = shell.chat_tabs.clone();
                let draft = shell.current_canvas_draft(cx);
                let selected = shell.state.read(cx).selected_chat.clone();
                shell.state.update(cx, |state, _| {
                    state
                        .devices
                        .iter_mut()
                        .find(|device| device.id == "cloud-fixture-studio")
                        .unwrap()
                        .last_seen_at = Some(Utc::now() - chrono::TimeDelta::seconds(71));
                });
                assert!(
                    shell
                        .new_chat_on_cloud_computer("cloud-fixture", cx)
                        .is_err()
                );
                assert_eq!(shell.chat_tabs, tabs);
                assert_eq!(shell.current_canvas_draft(cx), draft);
                assert_eq!(shell.state.read(cx).selected_chat, selected);
                shell.state.update(cx, |state, cx| {
                    state
                        .devices
                        .iter_mut()
                        .find(|device| device.id == "cloud-fixture-studio")
                        .unwrap()
                        .last_seen_at = Some(Utc::now());
                    state.apply_cloud_sandboxes(
                        Some(CodegraffSandboxes {
                            enabled: true,
                            sandboxes: vec![
                                sandbox(),
                                CodegraffSandbox {
                                    id: "different-computer".into(),
                                    ..sandbox()
                                },
                            ],
                            sizes: vec![],
                        }),
                        cx,
                    );
                });
                assert!(
                    shell
                        .new_chat_on_cloud_computer("cloud-fixture", cx)
                        .is_err()
                );
                assert_eq!(shell.chat_tabs, tabs);
                assert_eq!(shell.current_canvas_draft(cx), draft);
                assert_eq!(shell.state.read(cx).selected_chat, selected);
            })
            .unwrap();
    }
}
