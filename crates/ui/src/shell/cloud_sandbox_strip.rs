//! Named cloud computers and their details. The Mac sidebar keeps identity and state
//! together; actions live in the opened detail so the pinned card stays calm.
use super::*;
use crate::codegraff_sandboxes::{self as cloud, CodegraffSandbox};

mod hover;
mod multiple;

const HEADER_TRIGGER: &str = "cloud-computers-header";
const HEADER_POPOVER_GAP: f32 = 6.;

#[cfg(not(target_os = "macos"))]
#[path = "cloud_sandbox_strip/legacy.rs"]
mod legacy;

#[derive(Default)]
pub(super) struct CloudComputerRuntime {
    selected: Option<String>,
    focus: Option<FocusHandle>,
    return_focus: Option<FocusHandle>,
    controls: std::collections::HashMap<String, FocusHandle>,
    detail_focus_order: Vec<FocusHandle>,
    action: Option<(String, &'static str)>,
    card_bounds:
        std::rc::Rc<std::cell::RefCell<std::collections::HashMap<String, gpui::Bounds<Pixels>>>>,
    detail_bounds: std::rc::Rc<std::cell::Cell<Option<gpui::Bounds<Pixels>>>>,
    anchor_id: Option<String>,
    hovered_trigger: Option<String>,
    hovered_detail: bool,
    focused_trigger: Option<String>,
    focused_detail: bool,
    dismissed: Option<String>,
    hover_task: Option<Task<()>>,
    hide_task: Option<Task<()>>,
    focus_subscriptions: std::collections::HashMap<String, Vec<Subscription>>,
    #[cfg(feature = "appshots-fixture")]
    fixture_only: bool,
    error: Option<(String, String)>,
}

impl CloudComputerRuntime {
    pub(super) fn is_open(&self) -> bool {
        self.selected.is_some()
    }
    pub(super) fn owns_keyboard(&self) -> bool {
        self.is_open() && (self.focused_trigger.is_some() || self.focused_detail)
    }
}

fn status(sandbox: &CodegraffSandbox) -> &'static str {
    match sandbox.state.as_str() {
        "running"
            if sandbox
                .renew_error
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty()) =>
        {
            "Needs attention"
        }
        "running" => "Running",
        "starting" => "Starting…",
        "stopping" => "Pausing…",
        "paused" => "Paused",
        "error" => "Needs attention",
        _ => "Status unavailable",
    }
}

fn status_tone(sandbox: &CodegraffSandbox, theme: &Theme) -> gpui::Hsla {
    match status(sandbox) {
        "Running" => theme.success,
        "Needs attention" => theme.warning,
        "Starting…" | "Pausing…" => theme.accent,
        _ => theme.text_muted,
    }
}

fn status_line(sandbox: &CodegraffSandbox) -> String {
    let label = status(sandbox);
    if matches!(sandbox.state.as_str(), "running" | "starting") {
        if let Some(price) = sandbox.price_per_hour_micro_usd {
            return format!("{label} · {}", cloud::format_rate(price));
        }
    }
    label.to_string()
}

fn fact(theme: &Theme, glyph: &'static str, label: &str, value: String) -> AnyElement {
    div()
        .id(SharedString::from(format!("cloud-spec-{label}")))
        .flex()
        .items_center()
        .gap(px(5.))
        .py(px(3.))
        .text_size(crate::typography::ui_rems(12.))
        .text_color(theme.text_muted)
        .aria_label(format!("{label}: {value}"))
        .tooltip(crate::settings::widgets::text_tooltip(format!(
            "{label}: {value}"
        )))
        .child(
            icon(glyph)
                .size(px(14.))
                .flex_none()
                .text_color(theme.text_muted),
        )
        .child(value)
        .into_any_element()
}

impl Shell {
    fn cloud_control_focus(&mut self, key: &str, cx: &mut Context<Self>) -> FocusHandle {
        self.cloud_computers
            .controls
            .entry(key.to_owned())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone()
    }
    #[cfg(target_os = "macos")]
    pub(super) fn render_cloud_sandbox_strip(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let list = self.state.read(cx).cloud_sandboxes()?.clone();
        if !list.enabled || list.sandboxes.is_empty() {
            return None;
        }
        // Never reorder machines in response to a transient state. The gateway's order is
        // retained, and paused computers stay available to start again.
        let mut cards = div()
            .id("cloud-sandbox-strip")
            .debug_selector(|| "cloud-sandbox-strip".into())
            .flex_none()
            .mx(px(SIDEBAR_GUTTER))
            .mt(px(8.))
            .mb(px(3.))
            .max_h(px(148.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(5.));
        for sandbox in &list.sandboxes {
            let id = sandbox.id.clone();
            let click_id = id.clone();
            let key_id = id.clone();
            let hover_id = id.clone();
            let bounds_id = id.clone();
            let focus = self
                .cloud_computers
                .controls
                .entry(id.clone())
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            let title = cloud::sandbox_title(sandbox);
            let tone = status_tone(sandbox, theme);
            let captured_bounds = self.cloud_computers.card_bounds.clone();
            cards = cards.child(
                div()
                    .relative()
                    .child(
                        gpui::canvas(
                            move |bounds, _, _| {
                                captured_bounds
                                    .borrow_mut()
                                    .insert(bounds_id.clone(), bounds);
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .inset_0(),
                    )
                    .id(SharedString::from(format!("cloud-computer-{id}")))
                    .debug_selector(move || format!("cloud-computer-{id}"))
                    .w_full()
                    .min_h(px(46.))
                    .flex_none()
                    .line_height(gpui::relative(1.2))
                    .px(px(10.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .when(list.sandboxes.len() == 1, |el| el.bg(theme.ink(0.025)))
                    .hover(|s| s.bg(theme.ink(0.065)))
                    .flex()
                    .items_center()
                    .gap(px(9.))
                    .cursor_pointer()
                    .role(gpui::Role::Button)
                    .aria_label(format!(
                        "{title}, {}. Manage computer in Settings",
                        status(sandbox)
                    ))
                    .track_focus(&focus)
                    .focus_visible(|s| s.bg(theme.ink(0.09)))
                    .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                        this.cloud_trigger_hover(hover_id.clone(), *hovered, cx);
                    }))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.close_cloud_computer(window, cx);
                        this.open_cloud_computer_settings(&click_id, window, cx);
                    }))
                    .on_key_down(
                        cx.listener(move |this, ev: &gpui::KeyDownEvent, window, cx| {
                            if matches!(ev.keystroke.key.as_str(), "enter" | "space") {
                                this.close_cloud_computer(window, cx);
                                this.open_cloud_computer_settings(&key_id, window, cx);
                                cx.stop_propagation();
                            }
                        }),
                    )
                    .child(
                        icon(if cloud::is_temporary(sandbox) {
                            icons::CLOUD
                        } else {
                            icons::MONITOR
                        })
                        .size(px(18.))
                        .flex_none()
                        .text_color(theme.text_muted),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .font_weight(gpui::FontWeight::MEDIUM)
                                    .text_size(crate::typography::ui_rems(12.5))
                                    .text_color(theme.text)
                                    .child(title),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(5.))
                                    .child(div().size(px(5.)).flex_none().rounded_full().bg(tone))
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(crate::typography::ui_rems(10.5))
                                            .text_color(theme.text_muted)
                                            .child(status_line(sandbox)),
                                    ),
                            ),
                    )
                    .child(
                        icon(icons::ALT_ARROW_RIGHT)
                            .size(px(13.))
                            .flex_none()
                            .text_color(theme.text_faint),
                    ),
            );
        }
        Some(
            div()
                .flex()
                .flex_col()
                .flex_none()
                .when(list.sandboxes.len() > 1, |el| {
                    el.child(
                        div()
                            .mx(px(SIDEBAR_GUTTER + 10.))
                            .mt(px(8.))
                            .flex()
                            .items_center()
                            .justify_between()
                            .text_size(crate::typography::ui_rems(10.5))
                            .text_color(theme.text_muted)
                            .child("Computers")
                            .child(list.sandboxes.len().to_string()),
                    )
                })
                .child(cards)
                .into_any_element(),
        )
    }

    /// Space reserved inside the titlebar, never an overlay over the first tab.
    pub(super) fn cloud_header_width(&self, cx: &App) -> f32 {
        if cfg!(target_os = "macos")
            && self.settings.sidebar_collapsed
            && matches!(self.route, Route::Chat)
            && self
                .state
                .read(cx)
                .cloud_sandboxes()
                .is_some_and(|list| list.enabled && !list.sandboxes.is_empty())
        {
            28. + TITLEBAR_CONTROL_GAP
        } else {
            0.
        }
    }

    #[cfg(target_os = "macos")]
    pub(super) fn render_cloud_sandbox_chip(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.cloud_header_width(cx) == 0. {
            return None;
        }
        let list = self.state.read(cx).cloud_sandboxes()?.clone();
        let sandbox = list.sandboxes.first()?;
        let title = cloud::sandbox_title(sandbox);
        let detail = if list.sandboxes.len() > 1 {
            format!("{} cloud computers. Show computers", list.sandboxes.len())
        } else {
            format!(
                "{title} · {}. Manage computer in Settings",
                status_line(sandbox)
            )
        };
        let focus = self.cloud_control_focus(HEADER_TRIGGER, cx);
        let captured_bounds = self.cloud_computers.card_bounds.clone();
        Some(
            div()
                .id("cloud-sandbox-chip")
                .debug_selector(|| "cloud-sandbox-chip".into())
                .relative()
                .size(px(28.))
                .ml(px(TITLEBAR_CONTROL_GAP))
                .flex_none()
                .rounded(px(6.))
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .role(gpui::Role::Button)
                .aria_label(detail)
                .track_focus(&focus)
                .focus_visible(|el| el.bg(theme.element_hover))
                .hover(|el| el.bg(theme.element_hover))
                .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                    this.cloud_trigger_hover(HEADER_TRIGGER.into(), *hovered, cx);
                }))
                .on_click(cx.listener(|this, _, window, cx| {
                    this.activate_cloud_header(window, cx);
                }))
                .on_key_down(
                    cx.listener(move |this, ev: &gpui::KeyDownEvent, window, cx| {
                        if matches!(ev.keystroke.key.as_str(), "enter" | "space") {
                            this.activate_cloud_header(window, cx);
                            cx.stop_propagation();
                        }
                    }),
                )
                .child(
                    gpui::canvas(
                        move |bounds, _, _| {
                            captured_bounds
                                .borrow_mut()
                                .insert(HEADER_TRIGGER.into(), bounds);
                        },
                        |_, _, _, _| {},
                    )
                    .absolute()
                    .inset_0(),
                )
                .child(
                    icon(if cloud::is_temporary(sandbox) {
                        icons::CLOUD
                    } else {
                        icons::MONITOR
                    })
                    .size(px(15.))
                    .text_color(theme.text_muted),
                )
                .when(list.sandboxes.len() == 1, |el| {
                    el.child(
                        div()
                            .absolute()
                            .right(px(3.))
                            .bottom(px(4.))
                            .size(px(5.))
                            .rounded_full()
                            .bg(status_tone(sandbox, theme)),
                    )
                })
                .when(list.sandboxes.len() > 1, |el| {
                    el.child(
                        div()
                            .absolute()
                            .right(px(-2.))
                            .bottom(px(0.))
                            .min_w(px(12.))
                            .h(px(12.))
                            .px(px(2.))
                            .rounded(px(3.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .bg(theme.surface_overlay)
                            .text_color(theme.text_muted)
                            .text_size(crate::typography::ui_rems(8.5))
                            .child(if list.sandboxes.len() > 9 {
                                "9+".into()
                            } else {
                                list.sandboxes.len().to_string()
                            }),
                    )
                })
                .into_any_element(),
        )
    }

    pub(super) fn advance_cloud_focus(
        &mut self,
        backwards: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let order = &self.cloud_computers.detail_focus_order;
        if order.is_empty() {
            return;
        }
        let current = window
            .focused(cx)
            .and_then(|focus| order.iter().position(|f| *f == focus));
        let next = match current {
            Some(ix) if backwards => (ix + order.len() - 1) % order.len(),
            Some(ix) => (ix + 1) % order.len(),
            None if backwards => order.len() - 1,
            None => 0,
        };
        window.focus(&order[next], cx);
    }

    fn open_cloud_computer(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.observe_cloud_focus(window, cx);
        self.show_cloud_preview(id, cx);
    }

    pub(super) fn close_cloud_computer(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.cloud_computers.hover_task = None;
        self.cloud_computers.hide_task = None;
        let selected = self.cloud_computers.selected.take();
        self.cloud_computers.dismissed = self
            .cloud_computers
            .anchor_id
            .clone()
            .or_else(|| self.cloud_computers.hovered_trigger.clone());
        self.cloud_computers.hovered_detail = false;
        if self
            .cloud_computers
            .focus
            .as_ref()
            .is_some_and(|f| f.contains_focused(window, cx))
        {
            if let Some(focus) = self.cloud_computers.return_focus.take() {
                window.focus(&focus, cx);
            }
        }
        cx.notify();
        selected.is_some()
    }

    pub(super) fn render_cloud_computer_detail(
        &mut self,
        viewport: gpui::Size<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.observe_cloud_focus(window, cx);
        if !matches!(self.route, Route::Chat) {
            self.cloud_computers.selected = None;
            self.cloud_computers.hover_task = None;
            return None;
        }
        let selected = self.cloud_computers.selected.clone()?;
        let focus = self.cloud_computers.focus.clone()?;
        let theme = Theme::of(cx).for_popup();
        let list = self
            .state
            .read(cx)
            .cloud_sandboxes()
            .cloned()
            .filter(|list| list.enabled);
        let sandbox = list
            .as_ref()
            .and_then(|list| list.sandboxes.iter().find(|s| s.id == selected))
            .cloned();
        let width = (f32::from(viewport.width) - 24.).min(304.);
        let close_focus = self.cloud_control_focus("cloud-detail-close", cx);
        let action_focus = self.cloud_control_focus("cloud-detail-action", cx);
        let refresh_focus = self.cloud_control_focus("cloud-detail-refresh", cx);
        let mut focus_order: Vec<_> = self
            .cloud_computers
            .return_focus
            .clone()
            .into_iter()
            .collect();
        focus_order.push(close_focus.clone());
        let mut identity = div().flex_1().min_w_0().flex().items_start().gap(px(9.));
        if selected == HEADER_TRIGGER {
            identity = identity
                .items_center()
                .child(
                    icon(icons::MONITOR)
                        .size(px(18.))
                        .text_color(theme.text_muted),
                )
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(14.))
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .text_color(theme.text)
                        .child("Computers"),
                );
        } else if let Some(sandbox) = sandbox.as_ref() {
            identity = identity
                .child(
                    icon(if cloud::is_temporary(sandbox) {
                        icons::CLOUD
                    } else {
                        icons::MONITOR
                    })
                    .size(px(20.))
                    .mt(px(2.))
                    .flex_none()
                    .text_color(theme.text_muted),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(crate::typography::ui_rems(14.))
                                .font_weight(gpui::FontWeight::MEDIUM)
                                .text_color(theme.text)
                                .child(cloud::sandbox_title(sandbox)),
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
                                        .bg(status_tone(sandbox, &theme)),
                                )
                                .child(
                                    div()
                                        .text_size(crate::typography::ui_rems(11.))
                                        .text_color(theme.text_muted)
                                        .child(if sandbox.state == "paused" {
                                            "Paused · Billing paused".to_string()
                                        } else {
                                            status_line(sandbox)
                                        }),
                                ),
                        ),
                );
        } else {
            identity = identity
                .text_size(crate::typography::ui_rems(14.))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(theme.text)
                .child("Computer unavailable");
        }
        let detail_bounds = self.cloud_computers.detail_bounds.clone();
        let mut card = popover::popover_card(&theme)
            .id("cloud-computer-detail")
            .debug_selector(|| "cloud-computer-detail".into())
            .relative()
            .child(
                gpui::canvas(
                    move |bounds, _, _| detail_bounds.set(Some(bounds)),
                    |_, _, _, _| {},
                )
                .absolute()
                .inset_0(),
            )
            .w(px(width))
            .max_h(px((f32::from(viewport.height) - 80.).max(200.)))
            .overflow_y_scroll()
            .p(px(14.))
            .flex()
            .flex_col()
            .gap(px(10.))
            .track_focus(&focus)
            .on_mouse_down_out(cx.listener(|this, _, window, cx| {
                this.close_cloud_computer(window, cx);
            }))
            .on_key_down(cx.listener(|this, ev: &gpui::KeyDownEvent, window, cx| {
                if ev.keystroke.key == "escape" {
                    this.close_cloud_computer(window, cx);
                    cx.stop_propagation();
                } else if ev.keystroke.key == "tab" {
                    this.advance_cloud_focus(ev.keystroke.modifiers.shift, window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex()
                    .items_start()
                    .justify_between()
                    .gap(px(8.))
                    .child(identity)
                    .child(
                        div()
                            .id("cloud-computer-close")
                            .debug_selector(|| "cloud-computer-close".into())
                            .size(px(24.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(6.))
                            .cursor_pointer()
                            .role(gpui::Role::Button)
                            .aria_label("Close computer details")
                            .track_focus(&close_focus)
                            .focus_visible(|el| el.bg(theme.element_hover))
                            .on_key_down(cx.listener(
                                |this, ev: &gpui::KeyDownEvent, window, cx| {
                                    if matches!(ev.keystroke.key.as_str(), "enter" | "space") {
                                        this.close_cloud_computer(window, cx);
                                        cx.stop_propagation();
                                    }
                                },
                            ))
                            .hover(|s| s.bg(theme.element_hover))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_cloud_computer(window, cx);
                            }))
                            .child(
                                icon(icons::CLOSE)
                                    .size(px(13.))
                                    .text_color(theme.text_muted),
                            ),
                    ),
            );
        if selected == HEADER_TRIGGER {
            let sandboxes = list
                .as_ref()
                .map(|list| list.sandboxes.as_slice())
                .unwrap_or_default();
            let (rows, row_focus) =
                self.render_cloud_computer_rows(&theme, sandboxes, viewport, cx);
            focus_order.extend(row_focus);
            card = card.child(rows);
        } else if let Some(sandbox) = sandbox {
            let temporary = cloud::is_temporary(&sandbox);
            let mut specs = div()
                .min_w_0()
                .flex()
                .flex_wrap()
                .items_center()
                .gap(px(10.));
            if let Some(cpu) = sandbox.cpu.filter(|v| v.is_finite() && *v > 0.) {
                specs = specs.child(fact(&theme, icons::CPU, "Processor", format!("{cpu} vCPU")));
            }
            if let Some(memory) = sandbox.memory_gib.filter(|v| v.is_finite() && *v > 0.) {
                specs = specs.child(fact(
                    &theme,
                    icons::MEMORY,
                    "Memory",
                    format!("{memory} GB"),
                ));
            }
            if let Some(disk) = sandbox.disk_gib.filter(|v| v.is_finite() && *v > 0.) {
                specs = specs.child(fact(
                    &theme,
                    icons::HARD_DRIVE,
                    "Storage capacity",
                    format!("{disk} GB"),
                ));
            }

            // Routine lifecycle copy lives on the action tooltip. Time limits and
            // problems remain visible, and temporary task machines stay distinct.
            if temporary
                || !matches!(sandbox.state.as_str(), "running" | "paused")
                || sandbox
                    .renew_error
                    .as_deref()
                    .is_some_and(|s| !s.trim().is_empty())
                || (sandbox.state == "running" && sandbox.keep_running != Some(true))
            {
                card = card.child(
                    div()
                        .text_size(crate::typography::ui_rems(12.))
                        .text_color(if sandbox.renew_error.is_some() {
                            theme.warning
                        } else {
                            theme.text_muted
                        })
                        .child(cloud::computer_lifecycle(&sandbox, chrono::Utc::now())),
                );
            }
            let destination = self.cloud_chat_destination(&sandbox.id, cx);
            if !temporary && sandbox.state == "running" {
                if let Err(reason) = destination.as_ref() {
                    card = card.child(
                        div()
                            .text_size(crate::typography::ui_rems(11.))
                            .text_color(theme.text_muted)
                            .child((*reason).to_owned()),
                    );
                }
            }
            if let Some((_, error)) = self
                .cloud_computers
                .error
                .clone()
                .filter(|(id, _)| *id == sandbox.id)
            {
                card = card.child(
                    div()
                        .p(px(8.))
                        .rounded(px(7.))
                        .bg(theme.warning.opacity(0.08))
                        .text_color(theme.warning)
                        .text_size(crate::typography::ui_rems(11.))
                        .child(error),
                );
            }
            let mut actions = div().flex().items_center().gap(px(8.));
            let action = if cloud::can_start(&sandbox) {
                Some((
                    "start",
                    if sandbox.state == "paused" {
                        "Resume computer"
                    } else {
                        "Set up Harness"
                    },
                    icons::ACTION_PLAY,
                ))
            } else if cloud::can_stop(&sandbox) {
                Some(("stop", "Pause computer", icons::PAUSE))
            } else {
                None
            };
            if let Some((action, label, glyph)) = action {
                let busy = self.cloud_turning_off;
                if !busy {
                    focus_order.push(action_focus.clone());
                }
                let id = sandbox.id.clone();
                let key_id = id.clone();
                let hint = if action == "stop" {
                    cloud::TURN_OFF_HINT.to_string()
                } else if sandbox.state == "paused" {
                    sandbox
                        .price_per_hour_micro_usd
                        .map(|rate| format!("Resume at {}.", cloud::format_rate(rate)))
                        .unwrap_or_else(|| {
                            "Resume this computer. Computer billing restarts.".into()
                        })
                } else {
                    "Set up Harness on this computer.".into()
                };
                actions = actions.child(
                    div()
                        .id("cloud-computer-action")
                        .debug_selector(|| "cloud-computer-action".into())
                        .size(px(34.))
                        .flex_none()
                        .rounded(px(8.))
                        .bg(theme.ink(0.06))
                        .flex()
                        .items_center()
                        .justify_center()
                        .role(gpui::Role::Button)
                        .aria_label(if busy { "Updating computer" } else { label })
                        .tooltip(crate::settings::widgets::text_tooltip(hint))
                        .child(
                            icon(if busy { icons::REFRESH } else { glyph })
                                .size(px(16.))
                                .text_color(theme.text_muted),
                        )
                        .when(busy, |el| el.opacity(0.45))
                        .when(!busy, |el| {
                            el.cursor_pointer()
                                .track_focus(&action_focus)
                                .focus_visible(|el| el.bg(theme.element_hover))
                                .hover(|el| el.bg(theme.element_hover))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.cloud_computer_action(id.clone(), action, cx)
                                }))
                                .on_key_down(cx.listener(
                                    move |this, ev: &gpui::KeyDownEvent, _, cx| {
                                        if matches!(ev.keystroke.key.as_str(), "enter" | "space") {
                                            this.cloud_computer_action(key_id.clone(), action, cx);
                                            cx.stop_propagation();
                                        }
                                    },
                                ))
                        }),
                );
            }
            card = card.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap(px(8.))
                    .child(specs)
                    .when(!temporary, |el| el.child(actions)),
            );
        } else {
            focus_order.push(refresh_focus.clone());
            card=card.child(div().text_size(crate::typography::ui_rems(12.)).text_color(theme.text_muted).child("This computer is no longer in the current account’s list. Refresh to check again."))
                .child(popover::btn_ghost(&theme,"Refresh","cloud-computer-refresh").id("cloud-computer-refresh").role(gpui::Role::Button).track_focus(&refresh_focus).focus_visible(|el|el.bg(theme.element_hover))
                    .on_key_down(cx.listener(|this,ev:&gpui::KeyDownEvent,_,cx| {
                        if matches!(ev.keystroke.key.as_str(),"enter"|"space") {this.state.update(cx,|s,cx|s.refresh_cloud_sandboxes(cx));cx.stop_propagation();}
                    })).on_click(cx.listener(|this,_,_,cx|this.state.update(cx,|s,cx|s.refresh_cloud_sandboxes(cx)))));
        }
        self.cloud_computers.detail_focus_order = focus_order;
        let collapsed = self.settings.sidebar_collapsed;
        let (x, y) = if collapsed {
            self.cloud_computers
                .card_bounds
                .borrow()
                .get(
                    self.cloud_computers
                        .anchor_id
                        .as_deref()
                        .unwrap_or(&selected),
                )
                .map(|bounds| (f32::from(bounds.left()), f32::from(bounds.bottom())))
                .unwrap_or((12., Theme::TITLEBAR_HEIGHT))
        } else {
            (
                self.settings.sidebar_width + 8.,
                self.cloud_computers
                    .card_bounds
                    .borrow()
                    .get(
                        self.cloud_computers
                            .anchor_id
                            .as_deref()
                            .unwrap_or(&selected),
                    )
                    .map(|bounds| f32::from(bounds.bottom()))
                    .unwrap_or(f32::from(viewport.height) - 48.),
            )
        };
        // Align the open details with the sidebar row regardless of its content height.
        // The collapsed titlebar button still opens downward.
        let position = gpui::point(
            px((x - if collapsed { 0. } else { 20. })
                .min((f32::from(viewport.width) - width - 32.).max(0.))),
            px(y),
        );
        // This is a non-modal hover preview. Standard menu layers consume the
        // first outside press, which would swallow a click on its own trigger.
        // Keep the pointer bridge transparent and only raise the actual card.
        Some(
            gpui::deferred(
                gpui::anchored()
                    .position(position)
                    .anchor(if collapsed {
                        gpui::Anchor::TopLeft
                    } else {
                        gpui::Anchor::BottomLeft
                    })
                    .snap_to_window_with_margin(px(8.))
                    .child(crate::motion::fade_quick(
                        "cloud-computer-detail-layer",
                        div()
                            .occlude()
                            .id("cloud-detail-hover-region")
                            .when(collapsed, |el| el.pt(px(HEADER_POPOVER_GAP)))
                            .when(!collapsed, |el| el.pl(px(20.)))
                            .on_hover(cx.listener(|this, entered: &bool, _, cx| {
                                this.cloud_computers.hovered_detail = *entered;
                                if *entered {
                                    this.cloud_computers.hide_task = None;
                                } else {
                                    this.hide_cloud_preview_soon(cx);
                                }
                            }))
                            .child(crate::frost::layered(card.into_any_element())),
                    )),
            )
            .priority(1)
            .into_any_element(),
        )
    }

    fn cloud_computer_action(&mut self, id: String, action: &'static str, cx: &mut Context<Self>) {
        if self.cloud_turning_off {
            return;
        }
        // Revalidate against the live account's list: a dismissed/replaced computer must
        // never turn into a command for a different account or an unsupported machine.
        let allowed = self
            .state
            .read(cx)
            .cloud_sandboxes()
            .filter(|l| l.enabled)
            .and_then(|l| l.sandboxes.iter().find(|s| s.id == id))
            .is_some_and(|s| match action {
                "start" => cloud::can_start(s),
                "stop" => cloud::can_stop(s),
                _ => false,
            });
        if !allowed {
            return;
        }
        #[cfg(feature = "appshots-fixture")]
        if self.cloud_computers.fixture_only {
            let mut list = self.state.read(cx).cloud_sandboxes().cloned().unwrap();
            if let Some(sandbox) = list.sandboxes.iter_mut().find(|s| s.id == id) {
                sandbox.state = if action == "stop" {
                    "paused"
                } else {
                    "running"
                }
                .into();
            }
            self.state
                .update(cx, |state, cx| state.apply_cloud_sandboxes(Some(list), cx));
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.cloud_computers.error = Some((id, "Reconnect to Harness, then try again.".into()));
            cx.notify();
            return;
        };
        self.cloud_turning_off = true;
        self.cloud_computers.action = Some((id.clone(), action));
        self.cloud_computers.error = None;
        cx.notify();
        self.cloud_turn_off_task = Some(cx.spawn(async move |this, cx| {
            let request_id = id.clone();
            let result = engine
                .client()
                .call(
                    methods::CODEGRAFF_SANDBOX_ACTION,
                    serde_json::json!({"id":id,"action":action}),
                )
                .await;
            this.update(cx, |shell, cx| {
                shell.cloud_turning_off = false;
                shell.cloud_computers.action = None;
                if let Err(error) = result {
                    shell.cloud_computers.error = Some((
                        request_id,
                        format!(
                            "Couldn’t {} this computer: {error}",
                            if action == "stop" { "pause" } else { "start" }
                        ),
                    ));
                }
                shell
                    .state
                    .update(cx, |state, cx| state.refresh_cloud_sandboxes(cx));
                cx.notify();
            })
            .ok();
        }));
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_card_center(&self, window: &Window, cx: &App) -> Point<Pixels> {
        self.fixture_cloud_trigger_center(window, cx)
    }
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_detail_center(&self, _window: &Window, _cx: &App) -> Point<Pixels> {
        self.cloud_computers
            .detail_bounds
            .get()
            .expect("cloud detail has painted")
            .center()
    }
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_detail_is_open(&self) -> bool {
        self.cloud_computers.is_open()
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_refinement(
        &mut self,
        variant: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if variant == "card" {
            self.fixture_attention_import("base", window, cx);
        }
        if variant == "detail" {
            assert!(
                self.cloud_computers.is_open(),
                "the native pointer opened the actual cloud detail"
            );
            return;
        }
        self.cloud_computers = Default::default();
        self.cloud_computers.fixture_only = true;
        self.cloud_turning_off = false;
        let mut sandbox = CodegraffSandbox {
            id: "fixture-studio".into(),
            provider: "fleet".into(),
            name: Some("Studio computer".into()),
            device_name: Some("Harness cloud fixture-studio".into()),
            state: "running".into(),
            harness: true,
            keep_running: Some(true),
            cpu: Some(2.),
            memory_gib: Some(4.),
            disk_gib: Some(40.),
            price_per_hour_micro_usd: Some(100_000),
            ..Default::default()
        };
        match variant {
            "stopped" => sandbox.state = "paused".into(),
            "loading" => sandbox.state = "starting".into(),
            "error" => {
                sandbox.renew_error = Some("insufficient_credit".into());
                sandbox.keep_running = Some(false);
            }
            "temporary" => {
                sandbox.name = Some("Image processing".into());
                sandbox.tier = Some("ephemeral".into());
                sandbox.harness = false;
                sandbox.keep_running = None;
            }
            _ => {}
        }
        self.state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(
                Some(cloud::CodegraffSandboxes {
                    enabled: true,
                    sandboxes: vec![sandbox],
                    ..Default::default()
                }),
                cx,
            )
        });
        self.fixture_cloud_chat_ready(cx);
        self.settings.sidebar_collapsed = variant == "sidebar-closed";
        if !matches!(variant, "card" | "sidebar-closed") {
            self.open_cloud_computer("fixture-studio".into(), window, cx);
        }
        if variant == "unavailable" {
            self.state
                .update(cx, |state, cx| state.apply_cloud_sandboxes(None, cx));
        }
        cx.notify();
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    #[test]
    fn named_cloud_states_do_not_invent_prices_or_persistence() {
        let mut sandbox = CodegraffSandbox {
            state: "running".into(),
            ..Default::default()
        };
        assert_eq!(status_line(&sandbox), "Running");
        sandbox.price_per_hour_micro_usd = Some(100_000);
        assert_eq!(status_line(&sandbox), "Running · $0.10/h");
        sandbox.state = "paused".into();
        assert_eq!(status_line(&sandbox), "Paused");
        sandbox.state = "future-state".into();
        assert_eq!(status(&sandbox), "Status unavailable");
    }
    /// The sidebar is a cached view: repaint the whole window, as a real frame would.
    fn redraw(cx: &mut gpui::VisualTestContext) {
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
    }

    /// A Ready shell in a window, its sidebar open or collapsed.
    fn open_shell<'a>(
        cx: &'a mut gpui::TestAppContext,
        dir: &std::path::Path,
        collapsed: bool,
    ) -> (
        Entity<AppState>,
        Entity<Shell>,
        &'a mut gpui::VisualTestContext,
    ) {
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
            crate::history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            settings::init(settings::UiSettings::expanded(), dir, cx);
        });
        let state = cx.new(|_| AppState::new());
        let shell_state = state.clone();
        let data_dir = dir.to_path_buf();
        let (shell, cx) = cx.add_window_view(|_, cx| {
            let mut shell = Shell::new(
                shell_state,
                EngineBootConfig {
                    data_dir,
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.debug_gate = Some(GatePhase::Ready);
            shell.settings.sidebar_collapsed = collapsed;
            shell
        });
        cx.update(|window, _| window.activate_window());
        (state, shell, cx)
    }

    #[gpui::test]
    fn cloud_header_reserves_space_and_does_not_cover_tabs(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), true);
        shell.read_with(cx, |shell, cx| assert_eq!(shell.cloud_header_width(cx), 0.));
        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(
                Some(cloud::CodegraffSandboxes {
                    enabled: true,
                    sandboxes: vec![CodegraffSandbox {
                        id: "studio".into(),
                        provider: "fleet".into(),
                        state: "paused".into(),
                        harness: true,
                        ..Default::default()
                    }],
                    ..Default::default()
                }),
                cx,
            )
        });
        redraw(cx);
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.cloud_header_width(cx), 30.)
        });
        let bounds = cx
            .debug_bounds("cloud-sandbox-chip")
            .expect("cloud control appears in titlebar");
        assert_eq!(bounds.size, gpui::size(px(28.), px(28.)));
        assert!(
            bounds.bottom() <= px(Theme::TITLEBAR_HEIGHT),
            "control stays above the tab strip"
        );
        shell.update(cx, |shell, cx| {
            shell.settings.sidebar_collapsed = false;
            cx.notify();
        });
        shell.read_with(cx, |shell, cx| assert_eq!(shell.cloud_header_width(cx), 0.));
    }

    fn assert_cloud_trigger_click_manages_open_preview(
        cx: &mut gpui::TestAppContext,
        collapsed: bool,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), collapsed);
        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(
                Some(cloud::CodegraffSandboxes {
                    enabled: true,
                    sandboxes: vec![CodegraffSandbox {
                        id: "studio".into(),
                        name: Some("Studio computer".into()),
                        provider: "fleet".into(),
                        state: "paused".into(),
                        harness: true,
                        ..Default::default()
                    }],
                    ..Default::default()
                }),
                cx,
            );
        });
        redraw(cx);
        let selector = if collapsed {
            "cloud-sandbox-chip"
        } else {
            "cloud-computer-studio"
        };
        let trigger = cx.debug_bounds(selector).unwrap();
        cx.simulate_mouse_move(trigger.center(), None, Default::default());
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(360));
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| {
            assert!(shell.cloud_computers.is_open());
            assert_eq!(shell.route, Route::Chat);
        });
        assert!(cx.debug_bounds("cloud-computer-detail").is_some());

        // The hover preview is not a modal menu: its outside-click handling
        // must let the same pointer click reach the card beneath it.
        cx.simulate_click(trigger.center(), Default::default());
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.route, Route::Settings(SettingsSection::Agents));
            assert!(!shell.cloud_computers.is_open());
            assert!(shell.accounts_page.is_some());
            assert!(!shell.cloud_turning_off);
        });
        assert!(cx.debug_bounds("codegraff-sandbox-studio").is_some());
    }

    #[gpui::test]
    fn cloud_sidebar_click_manages_while_hover_preview_is_open(cx: &mut gpui::TestAppContext) {
        assert_cloud_trigger_click_manages_open_preview(cx, false);
    }

    #[gpui::test]
    fn cloud_header_click_manages_while_hover_preview_is_open(cx: &mut gpui::TestAppContext) {
        assert_cloud_trigger_click_manages_open_preview(cx, true);
    }

    #[gpui::test]
    fn cloud_multiple_header_opens_a_nearby_list_before_managing_a_computer(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), true);
        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(
                Some(cloud::CodegraffSandboxes {
                    enabled: true,
                    sandboxes: ["studio", "render", "test"]
                        .into_iter()
                        .map(|id| CodegraffSandbox {
                            id: id.into(),
                            name: Some(id.into()),
                            provider: "fleet".into(),
                            state: "paused".into(),
                            harness: true,
                            ..Default::default()
                        })
                        .collect(),
                    ..Default::default()
                }),
                cx,
            )
        });
        redraw(cx);
        // A previously rendered sidebar row must never become the titlebar anchor.
        shell.update(cx, |shell, _| {
            shell.cloud_computers.card_bounds.borrow_mut().insert(
                "studio".into(),
                gpui::Bounds::new(gpui::point(px(8.), px(600.)), gpui::size(px(200.), px(46.))),
            );
        });
        let trigger = cx.debug_bounds("cloud-sandbox-chip").unwrap();
        cx.simulate_mouse_move(trigger.center(), None, Default::default());
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(360));
        cx.run_until_parked();
        redraw(cx);
        let detail = cx.debug_bounds("cloud-computer-detail").unwrap();
        assert_eq!(detail.top() - trigger.bottom(), px(HEADER_POPOVER_GAP));
        assert_eq!(detail.left(), trigger.left());
        assert!(cx.debug_bounds("cloud-computer-new-chat").is_none());
        for selector in ["cloud-list-studio", "cloud-list-render", "cloud-list-test"] {
            assert!(cx.debug_bounds(selector).is_some());
        }
        cx.simulate_click(trigger.center(), Default::default());
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| {
            assert_eq!(
                shell.route,
                Route::Chat,
                "the group button must not choose a computer"
            );
            assert!(shell.cloud_computers.is_open());
        });
        let row = cx.debug_bounds("cloud-list-render").unwrap();
        cx.simulate_click(row.center(), Default::default());
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.route, Route::Settings(SettingsSection::Agents));
            assert!(!shell.cloud_computers.is_open());
            assert!(!shell.cloud_turning_off);
        });
    }

    #[gpui::test]
    fn cloud_hover_previews_without_stealing_focus_and_click_manages(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), false);
        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(
                Some(cloud::CodegraffSandboxes {
                    enabled: true,
                    sandboxes: vec![CodegraffSandbox {
                        id: "studio".into(),
                        name: Some("Studio computer".into()),
                        provider: "fleet".into(),
                        state: "paused".into(),
                        harness: true,
                        ..Default::default()
                    }],
                    ..Default::default()
                }),
                cx,
            );
        });
        redraw(cx);
        let card = cx.debug_bounds("cloud-computer-studio").unwrap();
        let original_focus = cx.update(|window, cx| window.focused(cx));
        cx.simulate_mouse_move(card.center(), None, Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| assert!(!shell.cloud_computers.is_open()));
        cx.executor().advance_clock(Duration::from_millis(360));
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| {
            assert!(shell.cloud_computers.is_open());
            assert_eq!(shell.route, Route::Chat);
        });
        cx.update(|window, cx| {
            assert_eq!(
                window.focused(cx),
                original_focus,
                "hover must leave composer focus alone"
            )
        });
        let detail = cx.debug_bounds("cloud-computer-detail").unwrap();
        cx.simulate_mouse_move(detail.center(), None, Default::default());
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(300));
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            assert!(
                shell.cloud_computers.is_open(),
                "pointer can enter the preview"
            )
        });
        cx.simulate_mouse_move(gpui::point(px(700.), px(100.)), None, Default::default());
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(300));
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| assert!(!shell.cloud_computers.is_open()));
        // A passing pointer must never flash a card after it has already left.
        cx.simulate_mouse_move(card.center(), None, Default::default());
        cx.simulate_mouse_move(gpui::point(px(700.), px(100.)), None, Default::default());
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(400));
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| assert!(!shell.cloud_computers.is_open()));
        // Focus previews; Tab enters its controls; Escape closes once, returns focus,
        // and does not immediately reopen on that restored focus.
        let trigger = shell.read_with(cx, |shell, _| {
            shell.cloud_computers.controls["studio"].clone()
        });
        cx.update(|window, cx| window.focus(&trigger, cx));
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| assert!(shell.cloud_computers.is_open()));
        cx.simulate_keystrokes("tab");
        cx.run_until_parked();
        let close = shell.read_with(cx, |shell, _| {
            shell.cloud_computers.controls["cloud-detail-close"].clone()
        });
        cx.update(|window, cx| assert_eq!(window.focused(cx), Some(close)));
        cx.simulate_keystrokes("escape");
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| assert!(!shell.cloud_computers.is_open()));
        cx.update(|window, cx| assert_eq!(window.focused(cx), Some(trigger)));
        cx.simulate_click(card.center(), Default::default());
        cx.run_until_parked();
        redraw(cx);
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.route, Route::Settings(SettingsSection::Agents));
            assert!(!shell.cloud_computers.is_open());
        });
        shell.update(cx, |shell, cx| {
            shell.cloud_computer_action("missing".into(), "start", cx);
            shell.cloud_computer_action("studio".into(), "delete", cx);
            assert!(!shell.cloud_turning_off);
        });
    }
}
