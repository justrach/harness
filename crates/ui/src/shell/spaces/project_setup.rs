//! Name-first project setup. Folder browsing edits the draft and never creates a project.
use super::*;

/// Capture the existing production views at each step, with synthetic folder
/// listings. The save acknowledgement is simulated; no real project is created.
#[cfg(feature = "project-palette-fixture")]
impl Shell {
    pub fn fixture_project_walkthrough(
        &mut self,
        step: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        settings::update(SavePolicy::Immediate, cx, |settings| {
            settings
                .project_folders_by_device
                .entry("local".into())
                .or_default()
                .override_path = Some("/projects".into());
        });
        if step == "menu" {
            self.open_spaces_menu(window, cx);
            return;
        }
        self.open_add_space(cx);
        if step == "empty" {
            return;
        }
        self.add_space
            .as_ref()
            .unwrap()
            .name
            .clone()
            .update(cx, |input, cx| input.set_text("Website launch", cx));
        if step == "named" {
            return;
        }
        self.add_space_begin_folder(cx);
        self.fixture_project_responses(cx);
        if step == "devices" {
            self.add_space_back_to(ProjectStep::Devices, cx);
            return;
        }
        if step == "locations" {
            let device = self.state.read(cx).devices[1].clone();
            self.add_space_pick_device(device, cx);
            self.fixture_project_responses(cx);
            return;
        }
        if step == "folders" {
            self.add_space.as_mut().unwrap().active = 2;
            return;
        }
        self.add_space_descend("/projects/website".into(), true, cx);
        self.fixture_project_responses(cx);
        if step == "folder-open" {
            return;
        }
        self.add_space_use_folder(cx);
        if step == "ready" {
            return;
        }
        if step == "existing" {
            let existing = self.state.read(cx).spaces[0].clone();
            let flow = self.add_space.as_mut().unwrap();
            flow.folder.as_mut().unwrap().path = existing.path;
            return;
        }
        if step == "error" {
            self.submit_add_space(cx);
            return;
        }
        // Hold the transient state for a legible screenshot. This mirrors the
        // optimistic row and completion path in submit_add_space, with no RPC.
        let flow = self.add_space.as_mut().unwrap();
        flow.submit_busy = true;
        let folder = flow.folder.clone().unwrap();
        let space = Space {
            id: "walkthrough-project".into(),
            device_id: folder.device.id,
            path: folder.path,
            name: Some(flow.name.read(cx).text().trim().into()),
            git_detected: folder.git_detected,
            git_checked_at: None,
            checkout_id: None,
            created_at: Utc::now(),
        };
        self.state.update(cx, |state, cx| {
            state.spaces.push(space);
            cx.notify();
        });
        if step == "created" {
            self.add_space = None;
            self.land_in_space("walkthrough-project".into(), cx);
            self.composer
                .read(cx)
                .pickers()
                .clone()
                .update(cx, |pickers, cx| pickers.fixture_model_catalog(cx));
        }
        cx.notify();
    }
}

/// Mouse and keyboard share the same guards and actions.
fn setup_button(
    button: gpui::Div,
    id: &'static str,
    enabled: bool,
    action: fn(&mut Shell, &mut Context<Shell>),
    theme: &Theme,
    cx: &mut Context<Shell>,
) -> gpui::Stateful<gpui::Div> {
    button
        .id(id)
        .role(gpui::Role::Button)
        .tab_index(0)
        .tab_stop(enabled)
        .border_1()
        .border_color(theme.border.opacity(0.0))
        .focus(|style| style.border_color(theme.accent))
        .when(!enabled, |el| el.opacity(0.45).cursor_default())
        .when(enabled, |el| {
            el.on_click(cx.listener(move |this, _, _, cx| action(this, cx)))
                .on_key_down(cx.listener(move |this, event: &gpui::KeyDownEvent, _, cx| {
                    if event.keystroke.key == "enter" || event.keystroke.key == "space" {
                        action(this, cx);
                        cx.stop_propagation();
                    }
                }))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup(cx: &mut gpui::TestAppContext, data: &std::path::Path) -> gpui::WindowHandle<Shell> {
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
            settings::init(settings::UiSettings::default(), data, cx);
            crate::history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            crate::composer::init(cx, Default::default());
        });
        cx.add_window(|_, cx| {
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.local_device_id = Some("local".into());
                state.devices = serde_json::from_value(serde_json::json!([
                    {"id":"remote", "name":"Build server", "platform":"linux", "lastSeenAt":null},
                    {"id":"local", "name":"Studio", "platform":"macos", "lastSeenAt":null}
                ]))
                .unwrap();
                state
            });
            let mut shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: data.into(),
                    ipc_port: 0,
                    edge_url: String::new(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.debug_gate = Some(GatePhase::Ready);
            shell.open_add_space(cx);
            shell
        })
    }

    #[gpui::test]
    fn project_setup_keeps_name_and_folder_as_a_draft(cx: &mut gpui::TestAppContext) {
        let data = tempfile::tempdir().unwrap();
        let window = setup(cx, data.path());
        window.update(cx, |shell, _, cx| {
            assert_eq!(shell.add_space.as_ref().unwrap().step, ProjectStep::Details);
            shell.submit_add_space(cx);
            assert!(shell.add_space.as_ref().unwrap().error.is_none());
            let name = shell.add_space.as_ref().unwrap().name.clone();
            name.update(cx, |input, cx| input.set_text("Fieldnotes launch", cx));
            shell.submit_add_space(cx);
            assert!(shell.add_space.as_ref().unwrap().error.is_none(), "a folder is required before submission");
            shell.add_space_begin_folder(cx);
            let flow = shell.add_space.as_mut().unwrap();
            assert_eq!(flow.device.as_ref().unwrap().id, "local", "browse this computer first");
            flow.browser = Loadable::Ready(FolderListing { path: "/projects/fieldnotes".into(), entries: vec![], truncated: false });
            flow.browser_repo = true;
            shell.add_space_use_folder(cx);
            let flow = shell.add_space.as_ref().unwrap();
            assert_eq!(flow.step, ProjectStep::Details);
            assert_eq!(flow.name.read(cx).text(), "Fieldnotes launch");
            assert_eq!(flow.folder.as_ref().unwrap().path, "/projects/fieldnotes");
            assert!(flow.folder.as_ref().unwrap().git_detected);
            assert!(shell.state.read(cx).spaces.is_empty(), "choosing a folder must not create a project");

            // Canceling a replacement keeps the last confirmed folder and name.
            shell.add_space_begin_folder(cx);
            shell.add_space_pick_device(serde_json::from_value(serde_json::json!({"id":"remote", "name":"Build server", "platform":"linux", "lastSeenAt":null})).unwrap(), cx);
            shell.add_space_show_details(cx);
            let flow = shell.add_space.as_ref().unwrap();
            assert_eq!(flow.folder.as_ref().unwrap().device.id, "local");
            assert_eq!(flow.name.read(cx).text(), "Fieldnotes launch");
            name.update(cx, |input, cx| input.set_text("   ", cx));
            shell.submit_add_space(cx);
            assert!(shell.add_space.as_ref().unwrap().error.is_none(), "a blank name cannot submit");
            shell.cancel_project_setup(cx);
            assert!(shell.add_space.is_none());
            assert!(shell.state.read(cx).spaces.is_empty());
        }).unwrap();
    }

    #[gpui::test]
    fn project_setup_keyboard_opens_folder_browser_and_escape_returns_to_name(
        cx: &mut gpui::TestAppContext,
    ) {
        let data = tempfile::tempdir().unwrap();
        let window = setup(cx, data.path());
        cx.update_window(window.into(), |_, window, cx| window.draw(cx).clear())
            .unwrap();
        cx.simulate_keystrokes(window.into(), "tab enter");
        cx.run_until_parked();
        window
            .update(cx, |shell, _, _| {
                assert_ne!(shell.add_space.as_ref().unwrap().step, ProjectStep::Details);
            })
            .unwrap();
        cx.update_window(window.into(), |_, window, cx| window.draw(cx).clear())
            .unwrap();
        cx.simulate_keystrokes(window.into(), "escape");
        cx.run_until_parked();
        cx.update_window(window.into(), |_, window, cx| window.draw(cx).clear())
            .unwrap();
        window
            .update(cx, |shell, window, cx| {
                let flow = shell.add_space.as_ref().unwrap();
                assert_eq!(flow.step, ProjectStep::Details);
                assert!(flow.name.focus_handle(cx).is_focused(window));
            })
            .unwrap();
        cx.simulate_keystrokes(window.into(), "escape");
        window
            .update(cx, |shell, _, _| assert!(shell.add_space.is_none()))
            .unwrap();
    }

    #[gpui::test]
    fn project_setup_opens_existing_folder_without_renaming_it(cx: &mut gpui::TestAppContext) {
        let data = tempfile::tempdir().unwrap();
        let window = setup(cx, data.path());
        window.update(cx, |shell, _, cx| {
            shell.state.update(cx, |state, _| state.spaces.push(serde_json::from_value(serde_json::json!({
                "id":"existing", "deviceId":"local", "path":"/projects/fieldnotes", "name":"Fieldnotes", "createdAt":"2026-10-24T00:00:00Z"
            })).unwrap()));
            let name = shell.add_space.as_ref().unwrap().name.clone();
            name.update(cx, |input, cx| input.set_text("Another name", cx));
            shell.add_space_begin_folder(cx);
            shell.add_space.as_mut().unwrap().browser = Loadable::Ready(FolderListing { path: "/projects/fieldnotes".into(), entries: vec![], truncated: false });
            shell.add_space_use_folder(cx);
            shell.submit_add_space(cx);
            assert!(shell.add_space.is_none());
            let state = shell.state.read(cx);
            assert_eq!(state.spaces.len(), 1);
            assert_eq!(state.spaces[0].display_name(), "Fieldnotes");
            assert_eq!(state.selected_space.as_deref(), Some("existing"));
        }).unwrap();
    }
}

impl Shell {
    pub(in crate::shell) fn dismiss_project_setup(&mut self, cx: &mut Context<Self>) {
        if self.add_space.as_ref().is_none_or(|flow| flow.submit_busy) {
            return;
        }
        if self.add_space.as_ref().unwrap().step == ProjectStep::Details {
            self.cancel_project_setup(cx);
        } else {
            self.add_space_show_details(cx);
        }
    }

    fn cancel_project_setup(&mut self, cx: &mut Context<Self>) {
        if self.add_space.as_ref().is_some_and(|flow| flow.submit_busy) {
            return;
        }
        self.add_space = None;
        cx.notify();
    }

    pub(super) fn add_space_show_details(&mut self, cx: &mut Context<Self>) {
        if let Some(flow) = self.add_space.as_mut() {
            flow.step = ProjectStep::Details;
            flow.focus_pending = true;
            flow.load_task = None;
            flow.drives_task = None;
            flow.error = None;
        }
        cx.notify();
    }

    pub(super) fn add_space_begin_folder(&mut self, cx: &mut Context<Self>) {
        let Some(flow) = self.add_space.as_ref().filter(|flow| !flow.submit_busy) else {
            return;
        };
        if flow.requested_device_id.is_some() && flow.device.is_none() && flow.folder.is_none() {
            self.add_space_back_to(ProjectStep::Devices, cx);
            if let Some(flow) = self.add_space.as_mut() {
                flow.error = Some("This computer is unavailable. Choose another device.".into());
            }
            cx.notify();
            return;
        }
        let folder = flow.folder.clone();
        let state = self.state.read(cx);
        let device = folder
            .as_ref()
            .map(|folder| folder.device.clone())
            .or_else(|| flow.device.clone())
            .or_else(|| {
                state
                    .devices
                    .iter()
                    .find(|device| Some(device.id.as_str()) == state.local_device_id.as_deref())
                    .or_else(|| {
                        state
                            .selected_space
                            .as_deref()
                            .and_then(|id| state.space_row(id))
                            .and_then(|space| {
                                state
                                    .devices
                                    .iter()
                                    .find(|device| device.id == space.device_id)
                            })
                    })
                    .or_else(|| (state.devices.len() == 1).then(|| &state.devices[0]))
                    .cloned()
            });
        if let Some(device) = device {
            self.add_space_pick_device(device, cx);
            if let Some(folder) = folder {
                self.add_space_goto_location("Selected folder".into(), Some(folder.path), cx);
            } else if self
                .add_space
                .as_ref()
                .is_some_and(|flow| flow.step == ProjectStep::Locations)
            {
                self.add_space_goto_location("Home".into(), None, cx);
            }
        } else {
            self.add_space_back_to(ProjectStep::Devices, cx);
        }
    }

    pub(super) fn add_space_use_folder(&mut self, cx: &mut Context<Self>) {
        let Some(flow) = self
            .add_space
            .as_mut()
            .filter(|flow| !flow.submit_busy && flow.step == ProjectStep::Folders)
        else {
            return;
        };
        let (Some(device), Some(listing)) = (flow.device.clone(), flow.browser.ready()) else {
            return;
        };
        flow.folder = Some(ProjectFolder {
            device,
            path: listing.path.clone(),
            git_detected: flow.browser_repo,
        });
        self.add_space_show_details(cx);
    }

    pub(super) fn render_project_setup(
        &mut self,
        viewport: gpui::Size<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let theme = Theme::of(cx).for_popup();
        let flow = self.add_space.as_mut()?;
        if std::mem::take(&mut flow.focus_pending) {
            window.focus(&flow.name.focus_handle(cx), cx);
        }
        let name = flow.name.clone();
        let folder = flow.folder.clone();
        let busy = flow.submit_busy;
        let error = flow.error.clone();
        let focus = flow.focus.clone().tab_stop(false);
        name.update(cx, |input, _| input.read_only = busy);
        let existing = folder.as_ref().filter(|_| !busy).and_then(|folder| {
            self.state
                .read(cx)
                .spaces
                .iter()
                .find(|space| space.device_id == folder.device.id && space.path == folder.path)
                .map(|space| space.display_name().to_string())
        });
        let can_submit = !busy
            && folder.is_some()
            && (existing.is_some() || !name.read(cx).text().trim().is_empty());
        let label = |text: &'static str| {
            div()
                .text_size(crate::typography::ui_rems(13.0))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(theme.text)
                .child(text)
        };
        let mut folder_field = div()
            .flex()
            .flex_col()
            .gap(px(8.0))
            .child(label("Working folder"));
        if let Some(folder) = folder {
            folder_field = folder_field.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.0))
                    .child(
                        icon(icons::FOLDER)
                            .size(px(18.0))
                            .flex_none()
                            .text_color(theme.text_muted),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(13.0))
                                    .child(folder.path),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(12.0))
                                    .text_color(theme.text_muted)
                                    .child(folder.device.name),
                            ),
                    )
                    .child(
                        setup_button(
                            popover::btn_ghost(&theme, "Change…", "project-folder-change"),
                            "project-folder-change",
                            !busy,
                            Self::add_space_begin_folder,
                            &theme,
                            cx,
                        )
                        .aria_label("Change working folder"),
                    ),
            );
        } else {
            folder_field = folder_field.child(
                setup_button(
                    div()
                        .px(px(12.0))
                        .py(px(8.0))
                        .rounded(px(8.0))
                        .text_size(crate::typography::ui_rems(13.0))
                        .text_color(theme.text_muted)
                        .cursor_pointer()
                        .hover(|el| el.bg(theme.element_hover).text_color(theme.text))
                        .flex()
                        .items_center()
                        .gap(px(8.0))
                        .child(
                            icon(icons::PLUS)
                                .size(px(14.0))
                                .text_color(theme.text_muted),
                        )
                        .child("Add folder…"),
                    "project-folder-choose",
                    !busy,
                    Self::add_space_begin_folder,
                    &theme,
                    cx,
                )
                .aria_label("Add working folder")
                .border_color(theme.border),
            );
        }
        let card = popover::popover_card(&theme)
            .p(px(20.0))
            .gap(px(0.0))
            .rounded(px(16.0))
            .id("new-project-form")
            .role(gpui::Role::Dialog)
            .aria_label("New project")
            .track_focus(&focus)
            .tab_group()
            .w(px(460.0_f32.min(f32::from(viewport.width) - 32.0)))
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if this.add_space.as_ref().is_some_and(|flow| flow.submit_busy) {
                    return;
                }
                if event.keystroke.key == "escape" {
                    this.cancel_project_setup(cx);
                    cx.stop_propagation();
                } else if event.keystroke.key == "tab" {
                    let focus = this.add_space.as_ref().unwrap().focus.clone();
                    if event.keystroke.modifiers.shift {
                        window.focus_prev(cx);
                    } else {
                        window.focus_next(cx);
                    }
                    if !focus.contains_focused(window, cx) {
                        window.focus(&focus, cx);
                        if event.keystroke.modifiers.shift {
                            window.focus_prev(cx);
                        } else {
                            window.focus_next(cx);
                        }
                    }
                    cx.stop_propagation();
                }
            }))
            .child(popover::dialog_title(&theme, "New project"))
            .child(
                popover::dialog_body(&theme, "Keep related chats together in one project.")
                    .mt(px(6.0)),
            )
            .child(
                div()
                    .mt(px(24.0))
                    .flex()
                    .flex_col()
                    .gap(px(8.0))
                    .child(label("Project name"))
                    .child(popover::dialog_field(name.into_any_element())),
            )
            .child(folder_field.mt(px(20.0)))
            .child(popover::dialog_body(&theme, "New chats will work in this folder.").mt(px(8.0)))
            .when_some(existing.clone(), |el, existing| {
                el.child(
                    popover::dialog_body(
                        &theme,
                        format!(
                            "This folder is already in “{existing}”. Open that project to continue."
                        ),
                    )
                    .mt(px(12.0)),
                )
            })
            .when_some(error, |el, error| {
                el.child(
                    popover::dialog_body(&theme, error)
                        .text_color(theme.danger)
                        .mt(px(12.0)),
                )
            })
            .child(
                div()
                    .mt(px(24.0))
                    .flex()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        setup_button(
                            popover::btn_ghost(&theme, "Cancel", "project-setup-cancel"),
                            "project-setup-cancel",
                            !busy,
                            Self::cancel_project_setup,
                            &theme,
                            cx,
                        )
                        .aria_label("Cancel project creation"),
                    )
                    .child(
                        setup_button(
                            popover::btn_primary(
                                &theme,
                                if busy {
                                    "Creating…"
                                } else if existing.is_some() {
                                    "Open project"
                                } else {
                                    "Create project"
                                },
                            ),
                            "project-create",
                            can_submit,
                            Self::submit_add_space,
                            &theme,
                            cx,
                        )
                        .aria_label(if existing.is_some() {
                            "Open project"
                        } else {
                            "Create project"
                        }),
                    ),
            );
        Some(popover::modal(
            "new-project-dialog",
            viewport,
            card.into_any_element(),
        ))
    }
}
