//! One titlebar entry for several computers; each row retains its exact identity.
use super::*;

impl Shell {
    pub(super) fn activate_cloud_header(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let single = self
            .state
            .read(cx)
            .cloud_sandboxes()
            .filter(|list| list.enabled && list.sandboxes.len() == 1)
            .map(|list| list.sandboxes[0].id.clone());
        if let Some(id) = single {
            self.close_cloud_computer(window, cx);
            self.open_cloud_computer_settings(&id, window, cx);
        } else {
            self.cloud_computers.dismissed = None;
            self.show_cloud_preview(HEADER_TRIGGER.into(), cx);
            let focus = self.cloud_control_focus(HEADER_TRIGGER, cx);
            window.focus(&focus, cx);
        }
    }

    pub(super) fn render_cloud_computer_rows(
        &mut self,
        theme: &Theme,
        computers: &[CodegraffSandbox],
        viewport: gpui::Size<Pixels>,
        cx: &mut Context<Self>,
    ) -> (AnyElement, Vec<FocusHandle>) {
        let mut focus_order = Vec::new();
        let mut rows = div()
            .id("cloud-computer-list")
            .max_h(px((f32::from(viewport.height) - 160.).clamp(100., 360.)))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(2.));
        if computers.is_empty() {
            rows = rows.child(
                div()
                    .p(px(8.))
                    .text_color(theme.text_muted)
                    .child("No cloud computers are available."),
            );
        }
        for computer in computers {
            let id = computer.id.clone();
            let key_id = id.clone();
            let selector = format!("cloud-list-{id}");
            let focus = self.cloud_control_focus(&selector, cx);
            focus_order.push(focus.clone());
            let title = cloud::sandbox_title(computer);
            let mut specs = div().flex().flex_wrap().items_center().gap(px(10.));
            if let Some(cpu) = computer.cpu.filter(|v| v.is_finite() && *v > 0.) {
                specs = specs.child(fact(theme, icons::CPU, "Processor", format!("{cpu} vCPU")));
            }
            if let Some(memory) = computer.memory_gib.filter(|v| v.is_finite() && *v > 0.) {
                specs = specs.child(fact(theme, icons::MEMORY, "Memory", format!("{memory} GB")));
            }
            if let Some(disk) = computer.disk_gib.filter(|v| v.is_finite() && *v > 0.) {
                specs = specs.child(fact(
                    theme,
                    icons::HARD_DRIVE,
                    "Storage capacity",
                    format!("{disk} GB"),
                ));
            }
            rows = rows.child(
                div()
                    .id(SharedString::from(selector.clone()))
                    .debug_selector(move || selector.clone())
                    .flex_none()
                    .px(px(8.))
                    .py(px(9.))
                    .rounded(px(7.))
                    .flex()
                    .items_center()
                    .gap(px(9.))
                    .cursor_pointer()
                    .hover(|el| el.bg(theme.element_hover))
                    .role(gpui::Role::Button)
                    .aria_label(format!(
                        "{title}, {}. Manage computer in Settings",
                        status(computer)
                    ))
                    .track_focus(&focus)
                    .focus_visible(|el| el.bg(theme.element_hover))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.close_cloud_computer(window, cx);
                        this.open_cloud_computer_settings(&id, window, cx);
                    }))
                    .on_key_down(cx.listener(
                        move |this, event: &gpui::KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.close_cloud_computer(window, cx);
                                this.open_cloud_computer_settings(&key_id, window, cx);
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(3.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(13.))
                                    .text_color(theme.text)
                                    .child(title),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(5.))
                                    .child(
                                        div()
                                            .size(px(5.))
                                            .flex_none()
                                            .rounded_full()
                                            .bg(status_tone(computer, theme)),
                                    )
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(crate::typography::ui_rems(11.))
                                            .text_color(theme.text_muted)
                                            .child(status_line(computer)),
                                    ),
                            )
                            .child(specs),
                    )
                    .child(
                        icon(icons::ALT_ARROW_RIGHT)
                            .size(px(13.))
                            .flex_none()
                            .text_color(theme.text_faint),
                    ),
            );
        }
        (rows.into_any_element(), focus_order)
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_trigger_center(&self, _window: &Window, _cx: &App) -> Point<Pixels> {
        let key = if self.settings.sidebar_collapsed {
            HEADER_TRIGGER
        } else {
            "fixture-studio"
        };
        self.cloud_computers
            .card_bounds
            .borrow()
            .get(key)
            .expect("cloud trigger painted")
            .center()
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_devices(
        &mut self,
        count: usize,
        collapsed: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.fixture_session_hierarchy(0, window, cx);
        self.fixture_cloud_refinement("card", window, cx);
        let fixtures = [
            ("fixture-studio", "Studio computer", "running"),
            ("fixture-render", "Render computer", "paused"),
            ("fixture-test", "Test computer", "error"),
            ("fixture-build", "Build computer", "running"),
            (
                "fixture-long",
                "Design and accessibility computer",
                "starting",
            ),
            ("fixture-idle", "Weekend computer", "paused"),
        ];
        let computers: Vec<_> = fixtures
            .into_iter()
            .take(count.min(6))
            .map(|(id, name, state)| CodegraffSandbox {
                id: id.into(),
                name: Some(name.into()),
                provider: "fleet".into(),
                state: state.into(),
                device_name: Some(format!("Harness cloud {id}")),
                harness: true,
                keep_running: Some(true),
                cpu: Some(2.),
                memory_gib: Some(4.),
                disk_gib: Some(40.),
                price_per_hour_micro_usd: Some(100_000),
                ..Default::default()
            })
            .collect();
        self.state.update(cx, |state, cx| {
            state
                .devices
                .retain(|d| !d.id.starts_with("cloud-fixture-"));
            for computer in &computers {
                state.devices.push(harness_proto::Device {
                    id: format!("cloud-{}", computer.id),
                    name: computer.device_name.clone().unwrap(),
                    platform: "linux".into(),
                    last_seen_at: (computer.state == "running").then(Utc::now),
                    created_at: None,
                    version: None,
                    cursor_sdk_version: None,
                    capabilities: vec![],
                });
            }
            state.apply_cloud_sandboxes(
                Some(cloud::CodegraffSandboxes {
                    enabled: true,
                    sandboxes: computers,
                    ..Default::default()
                }),
                cx,
            );
        });
        self.settings.sidebar_collapsed = collapsed;
        self.sidebar_tween = None;
        cx.notify();
    }
}
