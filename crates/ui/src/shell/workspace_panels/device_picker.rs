//! A new panel owns its destination choice. Merely choosing a device never
//! changes the active chat, its draft, or an already-open terminal or explorer.
use super::*;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct PanelDeviceContext {
    /// None is explicitly this computer, rather than the app's last device.
    pub(super) remote: Option<String>,
    pub(super) owner: String,
}

impl PanelDeviceContext {
    fn new(device: Option<String>, owner: String, state: &AppState) -> Self {
        Self {
            remote: device.filter(|id| Some(id.as_str()) != state.local_device_id.as_deref()),
            owner,
        }
    }

    fn local() -> Self {
        Self {
            remote: None,
            owner: crate::state::canvas_panel_key(None),
        }
    }

    pub(super) fn full_id(&self, state: &AppState) -> Option<String> {
        self.remote
            .clone()
            .or_else(|| state.local_device_id.clone())
    }

    pub(super) fn canvas_target(&self, state: &AppState) -> crate::pickers::CanvasTarget {
        let space = self
            .owner
            .strip_prefix("space-canvas:")
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .or_else(|| {
                state
                    .chats
                    .iter()
                    .find(|chat| chat.id == self.owner)
                    .and_then(|chat| chat.space_id.clone())
            })
            .filter(|id| {
                state.space_row(id).is_some_and(|space| {
                    Some(space.device_id.as_str()) == self.full_id(state).as_deref()
                })
            });
        crate::pickers::CanvasTarget {
            no_project: space.is_none(),
            space,
            device: self.full_id(state),
        }
    }

    pub(super) fn available(&self, state: &AppState) -> bool {
        let Some(id) = self.remote.as_deref() else {
            return true;
        };
        state.devices.iter().any(|device| device.id == id) && device_status(state, id) == "Online"
    }
}

#[derive(Clone)]
pub(crate) struct PanelDeviceMenu {
    workspace: String,
    panel: u64,
    focus: FocusHandle,
    active: usize,
}

#[derive(Clone)]
struct DeviceRow {
    context: PanelDeviceContext,
    id: String,
    name: String,
    status: &'static str,
    enabled: bool,
}

fn device_status(state: &AppState, id: &str) -> &'static str {
    if state.local_device_id.as_deref() == Some(id) {
        return "Online";
    }
    let Some(device) = state.devices.iter().find(|device| device.id == id) else {
        return "Unavailable";
    };
    // A known paused computer must not become selectable just because its last
    // heartbeat has not expired. Use only an unambiguous engine association.
    if device.platform == "linux" {
        let matching_devices = state
            .devices
            .iter()
            .filter(|other| other.platform == "linux" && other.name == device.name)
            .count();
        let mut sandboxes = state
            .cloud_sandboxes()
            .into_iter()
            .flat_map(|list| &list.sandboxes)
            .filter(|sandbox| {
                sandbox.device_name.as_deref() == Some(device.name.as_str())
                    && !crate::codegraff_sandboxes::is_temporary(sandbox)
            });
        if let Some(sandbox) = sandboxes.next().filter(|_| matching_devices == 1) {
            if sandboxes.next().is_none() {
                match sandbox.state.as_str() {
                    "paused" => return "Paused",
                    "starting" => return "Starting",
                    "stopping" => return "Stopping",
                    "error" => return "Needs attention",
                    _ => {}
                }
            }
        }
    }
    if state.device_online(id, Utc::now()) {
        "Online"
    } else {
        "Offline"
    }
}

impl Shell {
    fn panel_device_rows(&self, cx: &App) -> Vec<DeviceRow> {
        let state = self.state.read(cx);
        let mut rows = vec![DeviceRow {
            context: PanelDeviceContext::local(),
            id: state
                .local_device_id
                .clone()
                .unwrap_or_else(|| "local".into()),
            name: if cfg!(target_os = "macos") {
                "This Mac"
            } else {
                "This computer"
            }
            .into(),
            status: "Online",
            enabled: true,
        }];
        rows.extend(
            state
                .devices
                .iter()
                .filter(|device| Some(device.id.as_str()) != state.local_device_id.as_deref())
                .map(|device| {
                    let status = device_status(state, &device.id);
                    DeviceRow {
                        context: PanelDeviceContext::new(
                            Some(device.id.clone()),
                            crate::state::canvas_panel_key(None),
                            state,
                        ),
                        id: device.id.clone(),
                        name: crate::codegraff_sandboxes::friendly_device_name(state, &device.id),
                        status,
                        enabled: status == "Online",
                    }
                }),
        );
        rows
    }

    pub(super) fn workspace_panel_device(&self, panel: u64, cx: &App) -> PanelDeviceContext {
        let state = self.state.read(cx);
        let selected = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .and_then(WorkspacePanel::selected);
        if matches!(selected, None | Some(PanelTab::New(_) | PanelTab::Empty)) {
            if let Some(device) = self
                .workspace_panels
                .device_choices
                .get(&(self.workspace_layout_key(cx), panel))
            {
                return PanelDeviceContext::new(device.full_id(state), device.owner.clone(), state);
            }
        }
        match selected {
            Some(PanelTab::Chat(id)) => {
                state.chats.iter().find(|chat| &chat.id == id).map(|chat| {
                    PanelDeviceContext::new(Some(chat.device_id.clone()), id.clone(), state)
                })
            }
            Some(PanelTab::New(id) | PanelTab::Draft(id)) => self
                .workspace_panels
                .drafts
                .get(id)
                .and_then(|draft| draft.target.as_ref())
                .map(|target| {
                    PanelDeviceContext::new(
                        target.device.clone(),
                        crate::state::canvas_panel_key(target.space.as_deref()),
                        state,
                    )
                }),
            Some(PanelTab::Terminal(id)) => {
                self.workspace_panels.terminals.get(id).map(|terminal| {
                    let terminal = terminal.read(cx);
                    PanelDeviceContext::new(
                        terminal.device_target(cx),
                        terminal.session_owner(cx),
                        state,
                    )
                })
            }
            Some(PanelTab::FileTree(id)) => {
                self.workspace_panels
                    .explorers
                    .get(id)
                    .map(|(files, _, _)| {
                        let files = files.read(cx);
                        PanelDeviceContext::new(
                            files.preferred_device_id(cx),
                            files.session_owner().to_owned(),
                            state,
                        )
                    })
            }
            Some(PanelTab::Surface {
                surface: RightSurface::Browser(_),
                ..
            }) => None,
            Some(
                PanelTab::Surface { owner, .. }
                | PanelTab::Files(owner)
                | PanelTab::TerminalDock(owner),
            ) => Some(PanelDeviceContext::new(
                state.terminal_target_device(owner),
                owner.clone(),
                state,
            )),
            _ => None,
        }
        .unwrap_or_else(PanelDeviceContext::local)
    }

    pub(super) fn moving_new_tab_device(
        &self,
        panel: u64,
        tab: &PanelTab,
        cx: &App,
    ) -> Option<PanelDeviceContext> {
        let PanelTab::New(id) = tab else {
            return None;
        };
        self.workspace_panels
            .device_choices
            .get(&(self.workspace_layout_key(cx), panel))
            .cloned()
            .or_else(|| {
                self.workspace_panels
                    .drafts
                    .get(id)
                    .and_then(|draft| draft.target.as_ref())
                    .map(|target| {
                        PanelDeviceContext::new(
                            target.device.clone(),
                            crate::state::canvas_panel_key(target.space.as_deref()),
                            self.state.read(cx),
                        )
                    })
            })
    }

    pub(super) fn set_workspace_panel_device(
        &mut self,
        panel: u64,
        device: PanelDeviceContext,
        cx: &App,
    ) {
        self.workspace_panels.needs_persist = true;
        self.workspace_panels
            .device_choices
            .insert((self.workspace_layout_key(cx), panel), device);
    }

    pub(crate) fn saved_workspace_panel_device(
        &self,
        session: &str,
        panel: u64,
        cx: &App,
    ) -> Option<crate::settings::SavedCanvasTarget> {
        self.workspace_panels
            .device_choices
            .get(&(session.to_owned(), panel))
            .map(|context| {
                let target = context.canvas_target(self.state.read(cx));
                crate::settings::SavedCanvasTarget {
                    space: target.space,
                    no_project: target.no_project,
                    device: target.device,
                }
            })
    }

    pub(crate) fn restore_workspace_panel_device(
        &mut self,
        session: &str,
        panel: u64,
        target: &crate::settings::SavedCanvasTarget,
        cx: &App,
    ) {
        let context = PanelDeviceContext::new(
            target.device.clone(),
            crate::state::canvas_panel_key(target.space.as_deref()),
            self.state.read(cx),
        );
        self.workspace_panels
            .device_choices
            .insert((session.to_owned(), panel), context);
    }

    fn close_panel_device_menu(
        &mut self,
        restore: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(menu) = self.workspace_panels.device_menu.take() {
            if restore {
                if let Some(focus) = self
                    .workspace_panels
                    .controls
                    .get(&format!("panel-device-{}", menu.panel))
                {
                    window.focus(focus, cx);
                }
            }
            cx.notify();
        }
    }

    fn toggle_panel_device_menu(
        &mut self,
        panel: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .workspace_panels
            .device_menu
            .as_ref()
            .is_some_and(|menu| {
                menu.panel == panel && menu.workspace == self.workspace_layout_key(cx)
            })
        {
            self.close_panel_device_menu(true, window, cx);
            return;
        }
        let selected = self.workspace_panel_device(panel, cx);
        let active = self
            .panel_device_rows(cx)
            .iter()
            .position(|row| row.context.remote == selected.remote)
            .unwrap_or(0);
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        self.workspace_panels.device_menu = Some(PanelDeviceMenu {
            workspace: self.workspace_layout_key(cx),
            panel,
            focus,
            active,
        });
        cx.notify();
    }

    fn choose_panel_device(
        &mut self,
        device_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.workspace_panels.device_menu.clone() else {
            return;
        };
        if menu.workspace != self.workspace_layout_key(cx) {
            self.close_panel_device_menu(false, window, cx);
            return;
        }
        let Some(row) = self
            .panel_device_rows(cx)
            .into_iter()
            .find(|row| row.id == device_id && row.enabled)
        else {
            return;
        };
        let current = self.workspace_panel_device(menu.panel, cx);
        // A repeated pick retains the originating project. A different host
        // starts without a project, so no path can leak onto the wrong host.
        let context = if row.context.remote == current.remote {
            current
        } else {
            row.context
        };
        self.set_workspace_panel_device(menu.panel, context, cx);
        self.close_panel_device_menu(true, window, cx);
        cx.notify();
    }

    pub(super) fn panel_device_matches_current_project(
        &self,
        device: &PanelDeviceContext,
        cx: &App,
    ) -> bool {
        let state = self.state.read(cx);
        let target = device.canvas_target(state);
        target.space.is_some()
            && target.space == state.selected_space
            && device.full_id(state) == state.effective_device_id()
    }

    pub(super) fn render_panel_device_picker(
        &mut self,
        panel: u64,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).for_popup();
        let device = self.workspace_panel_device(panel, cx);
        let label = device
            .full_id(self.state.read(cx))
            .map(|id| crate::codegraff_sandboxes::friendly_device_name(self.state.read(cx), &id))
            .unwrap_or_else(|| {
                if cfg!(target_os = "macos") {
                    "This Mac"
                } else {
                    "This computer"
                }
                .into()
            });
        let status = device
            .remote
            .as_deref()
            .map(|id| device_status(self.state.read(cx), id));
        let focus = self
            .workspace_panels
            .controls
            .entry(format!("panel-device-{panel}"))
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let menu =
            self.workspace_panels.device_menu.clone().filter(|menu| {
                menu.panel == panel && menu.workspace == self.workspace_layout_key(cx)
            });
        let mut trigger = div()
            .id(("panel-device-trigger", panel))
            .debug_selector(move || format!("panel-device-trigger-{panel}"))
            .relative()
            .min_w_0()
            .max_w_full()
            .flex()
            .items_center()
            .gap(px(7.))
            .px(px(10.))
            .py(px(6.))
            .rounded(px(6.))
            .cursor_pointer()
            .text_size(crate::typography::ui_rems(12.))
            .text_color(theme.text_muted)
            .hover(|style| style.bg(theme.element_hover).text_color(theme.text))
            .focus_visible(|style| style.bg(theme.element_hover).text_color(theme.text))
            .track_focus(&focus)
            .role(gpui::Role::Button)
            .aria_label(format!("Device for this new panel: {label}. Change device"))
            .on_click(cx.listener(move |this, _, window, cx| {
                this.toggle_panel_device_menu(panel, window, cx);
                cx.stop_propagation();
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(
                        event.keystroke.key.as_str(),
                        "enter" | "space" | "down" | "arrowdown"
                    ) {
                        this.toggle_panel_device_menu(panel, window, cx);
                        cx.stop_propagation();
                    }
                }),
            )
            .child(
                icon(icons::MONITOR)
                    .size(px(14.))
                    .flex_none()
                    .text_color(theme.text_muted),
            )
            .child(div().min_w_0().truncate().child(label))
            .child(
                icon(icons::ALT_ARROW_DOWN)
                    .size(px(11.))
                    .flex_none()
                    .text_color(theme.text_muted),
            );
        if let Some(menu) = menu {
            let rows = self.panel_device_rows(cx);
            let mut card = popover::popover_card(&theme)
                .w(px(272.))
                .track_focus(&menu.focus)
                .flex()
                .flex_col()
                .on_mouse_down_out(cx.listener(|this, _, window, cx| {
                    this.close_panel_device_menu(false, window, cx)
                }))
                .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                    match event.keystroke.key.as_str() {
                        "escape" => this.close_panel_device_menu(true, window, cx),
                        "enter" | "space" => {
                            if let Some(menu) = this.workspace_panels.device_menu.as_ref() {
                                let id = this
                                    .panel_device_rows(cx)
                                    .get(menu.active)
                                    .map(|row| row.id.clone());
                                if let Some(id) = id {
                                    this.choose_panel_device(&id, window, cx);
                                }
                            }
                        }
                        "down" | "arrowdown" | "up" | "arrowup" => {
                            let rows = this.panel_device_rows(cx);
                            if let Some(menu) = this.workspace_panels.device_menu.as_mut() {
                                let step =
                                    if matches!(event.keystroke.key.as_str(), "down" | "arrowdown")
                                    {
                                        1
                                    } else {
                                        rows.len() - 1
                                    };
                                for _ in 0..rows.len() {
                                    menu.active = (menu.active + step) % rows.len();
                                    if rows[menu.active].enabled {
                                        break;
                                    }
                                }
                            }
                            cx.notify();
                        }
                        _ => return,
                    }
                    cx.stop_propagation();
                }));
            let mut list = div()
                .id(("panel-device-list", panel))
                .max_h(px(268.))
                .overflow_y_scroll()
                .flex()
                .flex_col();
            for (index, row) in rows.into_iter().enumerate() {
                let selected = row.context.remote == device.remote;
                let selector = format!("panel-device-option-{}", row.id);
                let pick_id = row.id.clone();
                list = list.child(
                    popover::menu_row_nav(&theme, selected, index == menu.active, selector.clone())
                        .id(SharedString::from(selector.clone()))
                        .debug_selector(move || selector.clone())
                        .min_h(px(36.))
                        .role(gpui::Role::Button)
                        .aria_label(format!("{}, {}", row.name, row.status))
                        .when(!row.enabled, |row| row.opacity(0.5))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.choose_panel_device(&pick_id, window, cx);
                            cx.stop_propagation();
                        }))
                        .child(
                            icon(icons::MONITOR)
                                .size(px(15.))
                                .flex_none()
                                .text_color(theme.text_muted),
                        )
                        .child(div().flex_1().min_w_0().truncate().child(row.name))
                        .child(
                            div()
                                .text_size(crate::typography::ui_rems(11.))
                                .text_color(theme.text_muted)
                                .child(row.status),
                        )
                        .child(div().w(px(14.)).flex_none().when(selected, |slot| {
                            slot.child(icon(icons::CHECK).size(px(14.)).text_color(theme.text))
                        })),
                );
            }
            card = card.child(list);
            trigger = trigger.child(popover::anchored_menu_below(
                format!("panel-device-menu-{panel}"),
                card.into_any_element(),
                None,
            ));
        }
        div()
            .flex_none()
            .mb(px(10.))
            .px(px(2.))
            .flex()
            .flex_col()
            .items_start()
            .child(trigger)
            .when_some(
                status.filter(|status| *status != "Online"),
                |column, status| {
                    column.child(
                        div()
                            .px(px(10.))
                            .pt(px(3.))
                            .text_size(crate::typography::ui_rems(11.))
                            .text_color(theme.text_muted)
                            .child(format!("{status} · choose an online device")),
                    )
                },
            )
            .into_any_element()
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_device_panel_prepare(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.close_cloud_computer(window, cx);
        let context = PanelDeviceContext {
            remote: Some("cloud-fixture-studio".into()),
            owner: crate::state::canvas_panel_key(None),
        };
        self.workspace_panels.target = Some(0);
        self.workspace_new_chat_for_device(Some(context.clone()), cx);
        let layout = self.panel_layout_mut(cx);
        let tab = layout
            .panel(0)
            .and_then(WorkspacePanel::selected)
            .unwrap()
            .clone();
        layout.panels.truncate(1);
        layout.panels[0].tabs = vec![tab];
        layout.panels[0].active = 0;
        layout.axis = SplitAxis::Horizontal;
        layout.focused = 0;
        let panel = layout.add_panel(0);
        self.set_workspace_panel_device(panel, context, cx);
        window.blur();
        cx.notify();
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_device_panel_id(&self, cx: &App) -> u64 {
        self.panel_layout(cx).unwrap().focused
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_device_panel_selected(&self, cx: &App) -> Option<String> {
        self.workspace_panel_device(self.fixture_device_panel_id(cx), cx)
            .full_id(self.state.read(cx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    fn install_devices(shell: &mut Shell, cx: &mut Context<Shell>) {
        shell.state.update(cx, |state, _| {
            state.local_device_id = Some("local".into());
            state.selected_device = Some("local".into());
            state.devices = [
                ("local", "This Mac"),
                ("remote", "Studio computer"),
                ("other", "Build computer"),
            ]
            .into_iter()
            .map(|(id, name)| harness_proto::Device {
                id: id.into(),
                name: name.into(),
                platform: "linux".into(),
                last_seen_at: Some(Utc::now()),
                created_at: None,
                version: None,
                cursor_sdk_version: None,
                capabilities: vec![],
            })
            .collect();
            for chat in &mut state.chats {
                chat.device_id = "remote".into();
            }
        });
    }

    fn add_empty(shell: &mut Shell, cx: &mut Context<Shell>) -> u64 {
        let device = shell.workspace_panel_device(0, cx);
        let panel = shell.panel_layout_mut(cx).add_panel(0);
        shell.set_workspace_panel_device(panel, device, cx);
        panel
    }

    #[gpui::test]
    fn panel_device_choice_is_scoped_and_new_chat_preserves_existing_input(
        cx: &mut TestAppContext,
    ) {
        let (_dir, shell) = super::super::window_transfer_tests::setup(cx);
        shell
            .update(cx, |shell, window, cx| {
                install_devices(shell, cx);
                shell.composer.update(cx, |composer, _| {
                    composer.attachments.insert(
                        "chat-a".into(),
                        vec![crate::attachments::StagedAttachment {
                            #[cfg(target_os = "macos")]
                            editable: None,
                            #[cfg(target_os = "macos")]
                            unavailable_editable: None,
                            unavailable: None,
                            annotations: None,
                            id: "preserved-file".into(),
                            name: "draft.txt".into(),
                            image: None,
                            file: Some(std::sync::Arc::from(&b"original bytes"[..])),
                        }],
                    );
                });
                let panel = add_empty(shell, cx);
                assert_eq!(
                    shell.workspace_panel_device(panel, cx).remote.as_deref(),
                    Some("remote")
                );
                shell.toggle_panel_device_menu(panel, window, cx);
                // Reordering live discovery must not change the identity chosen by
                // a row that was already painted.
                shell.state.update(cx, |state, _| state.devices.swap(1, 2));
                shell.choose_panel_device("other", window, cx);
                assert_eq!(
                    shell.workspace_panel_device(panel, cx).remote.as_deref(),
                    Some("other")
                );
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("local")
                );
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("chat-a")
                );
                assert_eq!(
                    shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                    "An unsent draft"
                );
                assert_eq!(
                    shell.workspace_panel_device(0, cx).remote.as_deref(),
                    Some("remote")
                );
                shell.activate_workspace_empty(panel, 0, window, cx);
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("other")
                );
                assert!(shell.composer.read(cx).canvas_input(cx).text.is_empty());
                assert!(shell.composer.read(cx).canvas_input(cx).stage.is_empty());
                shell.focus_workspace_tab(0, PanelTab::Chat("chat-a".into()), window, cx);
                assert_eq!(
                    shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                    "An unsent draft"
                );
                assert_eq!(
                    shell.composer.read(cx).attachments["chat-a"][0].bytes(),
                    b"original bytes"
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_device_terminal_and_files_keep_their_chosen_host(cx: &mut TestAppContext) {
        let (_dir, shell) = super::super::window_transfer_tests::setup(cx);
        shell
            .update(cx, |shell, window, cx| {
                install_devices(shell, cx);
                let panel = add_empty(shell, cx);
                shell.toggle_panel_device_menu(panel, window, cx);
                shell.choose_panel_device("other", window, cx);
                shell.activate_workspace_empty(panel, 2, window, cx);
                let terminal = shell
                    .workspace_panels
                    .terminals
                    .values()
                    .next()
                    .unwrap()
                    .clone();
                assert_eq!(
                    terminal.read(cx).device_target(cx).as_deref(),
                    Some("other")
                );
                assert_eq!(terminal.read(cx).session_owner(cx), "space-canvas:");
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("local")
                );
                // A later app-wide choice cannot retarget a pinned terminal.
                shell
                    .state
                    .update(cx, |state, _| state.selected_device = Some("remote".into()));
                assert_eq!(
                    terminal.read(cx).device_target(cx).as_deref(),
                    Some("other")
                );
                let panel = shell.panel_layout_mut(cx).add_panel(0);
                shell.set_workspace_panel_device(
                    panel,
                    PanelDeviceContext {
                        remote: Some("other".into()),
                        owner: "space-canvas:".into(),
                    },
                    cx,
                );
                shell.activate_workspace_empty(panel, 3, window, cx);
                let files = shell
                    .workspace_panels
                    .explorers
                    .values()
                    .next()
                    .unwrap()
                    .0
                    .clone();
                assert_eq!(
                    files.read(cx).preferred_device_id(cx).as_deref(),
                    Some("other")
                );
                assert_eq!(
                    shell.files_project_target_for_test().0.as_deref(),
                    Some("other")
                );
                shell.files_project_begin_folder_for_test(cx);
                assert_eq!(
                    shell.files_project_target_for_test().0.as_deref(),
                    Some("other")
                );
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("remote")
                );
                assert_eq!(
                    terminal.read(cx).device_target(cx).as_deref(),
                    Some("other")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_device_offline_and_unknown_hosts_do_not_open_local_content(cx: &mut TestAppContext) {
        let (_dir, shell) = super::super::window_transfer_tests::setup(cx);
        shell
            .update(cx, |shell, window, cx| {
                install_devices(shell, cx);
                let panel = add_empty(shell, cx);
                shell.state.update(cx, |state, _| {
                    state
                        .devices
                        .iter_mut()
                        .find(|device| device.id == "remote")
                        .unwrap()
                        .last_seen_at = None;
                });
                for action in [0, 2, 3] {
                    shell.activate_workspace_empty(panel, action, window, cx);
                }
                assert!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .panel(panel)
                        .unwrap()
                        .tabs
                        .is_empty()
                );
                assert!(shell.workspace_panels.terminals.is_empty());
                assert!(shell.workspace_panels.explorers.is_empty());
                assert!(shell.add_space.is_none());
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("local")
                );
                shell.state.update(cx, |state, _| {
                    state.devices.retain(|device| device.id != "remote")
                });
                shell.activate_workspace_empty(panel, 2, window, cx);
                assert!(shell.workspace_panels.terminals.is_empty());
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_device_missing_files_host_never_defaults_to_this_mac(cx: &mut TestAppContext) {
        let (_dir, shell) = super::super::window_transfer_tests::setup(cx);
        shell
            .update(cx, |shell, _, cx| {
                install_devices(shell, cx);
                let state = shell.state.clone();
                let files = cx.new(|cx| {
                    let mut files =
                        FilesSurface::new_explorer(state, "space-canvas:".into(), false, cx);
                    files.prefer_device(Some("removed-host".into()));
                    files
                });
                shell.open_files_project(&files, cx);
                shell.files_project_begin_folder_for_test(cx);
                let (device, error) = shell.files_project_target_for_test();
                assert!(
                    device.is_none(),
                    "an explicit missing host cannot turn into the local device"
                );
                assert!(
                    error,
                    "the folder picker explains that a different device must be selected"
                );
                assert_eq!(
                    files.read(cx).preferred_device_id(cx).as_deref(),
                    Some("removed-host")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_device_restart_preserves_tools_and_empty_panel_targets(cx: &mut TestAppContext) {
        let (_source_dir, source) = super::super::window_transfer_tests::setup(cx);
        let (session, saved, empty_panel) = source
            .update(cx, |shell, window, cx| {
                install_devices(shell, cx);
                let terminal_panel = add_empty(shell, cx);
                shell.set_workspace_panel_device(
                    terminal_panel,
                    PanelDeviceContext {
                        remote: Some("other".into()),
                        owner: "space-canvas:".into(),
                    },
                    cx,
                );
                shell.activate_workspace_empty(terminal_panel, 2, window, cx);
                let files_panel = shell.panel_layout_mut(cx).add_panel(terminal_panel);
                shell.set_workspace_panel_device(
                    files_panel,
                    PanelDeviceContext {
                        remote: Some("remote".into()),
                        owner: "space-canvas:".into(),
                    },
                    cx,
                );
                shell.activate_workspace_empty(files_panel, 3, window, cx);
                shell.add_space = None;
                let empty_panel = shell.panel_layout_mut(cx).add_panel(files_panel);
                shell.set_workspace_panel_device(
                    empty_panel,
                    PanelDeviceContext {
                        remote: Some("other".into()),
                        owner: "space-canvas:".into(),
                    },
                    cx,
                );
                let session = shell.workspace_layout_key(cx);
                let saved = shell.saved_workspace_panels(&session, cx).unwrap();
                let json = serde_json::to_value(&saved).unwrap();
                assert!(json["panels"].as_array().unwrap().iter().any(|panel| {
                    panel["tabs"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|tab| tab["kind"] == "terminal" && tab["targetDeviceId"] == "other")
                }));
                (
                    session,
                    serde_json::from_value::<crate::settings::SavedWorkspacePanels>(json).unwrap(),
                    empty_panel,
                )
            })
            .unwrap();
        let (_destination_dir, destination) = super::super::window_transfer_tests::setup(cx);
        destination
            .update(cx, |shell, window, cx| {
                install_devices(shell, cx);
                shell.chat_tabs[0].id = session.clone();
                shell.chat_tab = 0;
                // The app-wide device is local at restart; restored tools must not
                // borrow that unrelated default.
                shell.restore_workspace_panels(&session, &saved, cx);
                shell.restore_pending_workspace_tools(window, cx);
                assert_eq!(
                    shell
                        .workspace_panels
                        .terminals
                        .values()
                        .next()
                        .unwrap()
                        .read(cx)
                        .device_target(cx)
                        .as_deref(),
                    Some("other")
                );
                assert_eq!(
                    shell
                        .workspace_panels
                        .explorers
                        .values()
                        .next()
                        .unwrap()
                        .0
                        .read(cx)
                        .preferred_device_id(cx)
                        .as_deref(),
                    Some("remote")
                );
                assert_eq!(
                    shell
                        .workspace_panel_device(empty_panel, cx)
                        .remote
                        .as_deref(),
                    Some("other")
                );
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("local")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_device_new_tab_keeps_choice_when_detached(cx: &mut TestAppContext) {
        let (_dir, source) = super::super::window_transfer_tests::setup(cx);
        let destination = source
            .update(cx, |shell, window, cx| {
                install_devices(shell, cx);
                shell.workspace_new_tab_in_panel(0, cx);
                let tab = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panel(0)
                    .unwrap()
                    .selected()
                    .unwrap()
                    .clone();
                shell.toggle_panel_device_menu(0, window, cx);
                shell.choose_panel_device("other", window, cx);
                shell
                    .move_workspace_tab_to_new_window(0, tab, None, window, cx)
                    .unwrap()
            })
            .unwrap();
        destination
            .read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.workspace_panel_device(0, cx).remote.as_deref(),
                    Some("other")
                );
                let PanelTab::New(id) = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panel(0)
                    .unwrap()
                    .selected()
                    .unwrap()
                else {
                    panic!("expected New tab")
                };
                assert_eq!(
                    shell.workspace_panels.drafts[id]
                        .target
                        .as_ref()
                        .unwrap()
                        .device
                        .as_deref(),
                    Some("other")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_device_saving_inactive_dock_uses_its_own_host(cx: &mut TestAppContext) {
        let (_dir, source) = super::super::window_transfer_tests::setup(cx);
        source
            .update(cx, |shell, _, cx| {
                install_devices(shell, cx);
                let state = shell.state.clone();
                let terminal = cx.new(|cx| {
                    let mut terminal = TerminalPanel::new_embedded(state, cx);
                    terminal.pin_session("chat-a".into());
                    terminal.pin_device(Some("other".into()));
                    terminal.open_tab_for_selected(cx);
                    terminal.pin_session("chat-b".into());
                    terminal.pin_device(None);
                    terminal.open_tab_for_selected(cx);
                    terminal
                });
                shell.terminal = Some(terminal);
                shell.panel_layout_mut(cx).panels[0].tabs =
                    vec![PanelTab::TerminalDock("chat-a".into())];
                let saved = shell
                    .saved_workspace_panels(&shell.workspace_layout_key(cx), cx)
                    .unwrap();
                let crate::settings::SavedPanelTab::Terminal {
                    target_device_id, ..
                } = &saved.panels[0].tabs[0]
                else {
                    panic!("expected terminal")
                };
                assert_eq!(target_device_id.as_deref(), Some("other"));
            })
            .unwrap();
    }

    #[test]
    fn panel_device_legacy_saved_tools_remain_readable() {
        for kind in ["terminal", "files"] {
            let old = serde_json::json!({ "kind": kind, "owner": "space-canvas:" });
            let tab: crate::settings::SavedPanelTab = serde_json::from_value(old.clone()).unwrap();
            assert_eq!(serde_json::to_value(tab).unwrap(), old);
        }
        let old = serde_json::json!({ "id":0, "tabs":[], "active":0, "share":1.0 });
        let panel: crate::settings::SavedWorkspacePanel =
            serde_json::from_value(old.clone()).unwrap();
        assert!(panel.new_panel_target.is_none());
        assert_eq!(serde_json::to_value(panel).unwrap(), old);
    }

    #[test]
    fn panel_device_project_is_inherited_only_on_its_own_host() {
        let mut state = AppState::new();
        state.local_device_id = Some("local".into());
        state.spaces = vec![serde_json::from_value(serde_json::json!({
            "id":"project", "deviceId":"remote", "name":"Project", "path":"/remote/project", "createdAt":Utc::now()
        })).unwrap()];
        let context = PanelDeviceContext {
            remote: Some("remote".into()),
            owner: "space-canvas:project".into(),
        };
        assert_eq!(
            context.canvas_target(&state).space.as_deref(),
            Some("project")
        );
        let mismatched = PanelDeviceContext {
            remote: None,
            ..context
        };
        assert!(mismatched.canvas_target(&state).space.is_none());
        assert!(mismatched.canvas_target(&state).no_project);
        assert_eq!(
            mismatched.canvas_target(&state).device.as_deref(),
            Some("local")
        );
    }
}
