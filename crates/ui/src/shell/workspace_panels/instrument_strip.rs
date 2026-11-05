//! Dev tab layout: one panel keeps its folder tabs. Once the window splits, one
//! strip replaces every panel's tab row. Each panel gets one slot, showing its
//! active tab, with a + for another tab inside it; its other tabs and its
//! actions live in the slot's menu. Built only with `dev-tab-layout`.
use super::*;

pub(super) const INSTRUMENT_STRIP: bool = cfg!(feature = "dev-tab-layout");

const SLOT_MAX_WIDTH: f32 = 260.0;
const SLOT_HEIGHT: f32 = 32.0;
const SLOT_MIN_WIDTH: f32 = 72.0;
const NEW_TAB_ROOM: f32 = 24.0 + GUTTER;
/// What a single panel's tab row sets aside for the name of its computer.
pub(super) const PANEL_DEVICE_ROOM: f32 = 120.0;

/// The computer's name, the same wherever it appears.
pub(super) fn device_label(selector: String, device: SharedString, theme: &Theme) -> gpui::Div {
    div()
        .debug_selector(move || selector)
        .min_w_0()
        .flex()
        .items_center()
        .gap(px(3.0))
        .text_size(crate::typography::ui_rems(10.0))
        .line_height(px(12.0))
        .text_color(theme.text_muted)
        .child(
            icon(icons::MONITOR)
                .size(px(10.0))
                .flex_none()
                .text_color(theme.text_muted),
        )
        .child(div().min_w_0().truncate().child(device))
}

impl Shell {
    /// The computer a panel's active tab runs on, named as the device menu
    /// names it.
    pub(super) fn panel_device_label(&self, panel: u64, cx: &App) -> SharedString {
        let state = self.state.read(cx);
        self.workspace_panel_device(panel, cx)
            .full_id(state)
            .map_or_else(
                || {
                    if cfg!(target_os = "macos") {
                        "This Mac"
                    } else {
                        "This device"
                    }
                    .into()
                },
                |id| crate::codegraff_sandboxes::friendly_device_name(state, &id).into(),
            )
    }

    pub(super) fn render_instrument_strip(
        &mut self,
        layout: &WorkspaceLayout,
        left_inset: f32,
        right_inset: f32,
        columns: Option<Vec<f32>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let workspace = self.workspace_layout_key(cx);
        let mut strip = div()
            .debug_selector(|| "instrument-strip".into())
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .h(px(Theme::TITLEBAR_HEIGHT))
            .pt(px(Theme::TITLEBAR_TOP_PAD))
            .pl(px(left_inset))
            .pr(px(right_inset))
            .flex()
            .items_center()
            .gap(px(if columns.is_some() { GUTTER } else { 2.0 }));
        for (ix, panel) in layout.panels.iter().enumerate() {
            let focused = layout.focused == panel.id;
            let width = columns
                .as_ref()
                .and_then(|columns| columns.get(ix))
                .copied();
            strip = strip
                .child(self.render_strip_slot(panel, ix, focused, width, &workspace, window, cx));
        }
        strip
            .child(
                self.render_workspace_button(
                    "instrument-new-tab".to_string(),
                    icons::PLUS,
                    "New tab",
                    false,
                    move |this, window, cx| {
                        this.workspace_new_tab(cx);
                        this.focus_workspace_new_tab(window, cx);
                    },
                    cx,
                )
                .tooltip(|_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: "New tab".into(),
                    })
                    .into()
                }),
            )
            .into_any_element()
    }

    /// Slot widths that put each slot directly above its panel, so the strip
    /// reads as the panels' own titles. Panels in a row only, and only while
    /// they all fit: otherwise there is no column to line up with.
    pub(super) fn strip_columns(
        panel_widths: &[f32],
        left_of_first_panel: f32,
        left_inset: f32,
    ) -> Option<Vec<f32>> {
        let mut columns = panel_widths.to_vec();
        // The first slot starts after whatever sits at the window's corner,
        // and the last one leaves room for the new-tab button.
        *columns.first_mut()? -= left_inset - left_of_first_panel;
        *columns.last_mut()? -= NEW_TAB_ROOM;
        columns
            .iter()
            .all(|width| *width >= SLOT_MIN_WIDTH)
            .then_some(columns)
    }

    /// The most urgent thing any of this panel's tabs is asking for. Streaming
    /// is not attention: only an unanswered question or an error count.
    fn panel_attention(&self, panel: &WorkspacePanel, cx: &App) -> Option<TabAttention> {
        panel
            .tabs
            .iter()
            .enumerate()
            .filter_map(|(ix, tab)| self.tab_attention(panel.id, ix, tab, cx))
            .max_by_key(|attention| matches!(attention, TabAttention::Error))
    }

    fn tab_attention(
        &self,
        panel: u64,
        ix: usize,
        tab: &PanelTab,
        cx: &App,
    ) -> Option<TabAttention> {
        #[cfg(feature = "appshots-fixture")]
        if super::super::reconciliation_design_fixture::attention_icon(panel, ix, cx) {
            return Some(TabAttention::Input);
        }
        #[cfg(not(feature = "appshots-fixture"))]
        let _ = ix;
        let (title, _) = self.panel_tab_label(tab, cx);
        self.panel_tab_context(tab, panel, &title, cx)
            .as_ref()
            .and_then(TabContext::attention)
    }

    fn render_strip_slot(
        &mut self,
        panel: &WorkspacePanel,
        ix: usize,
        focused: bool,
        width: Option<f32>,
        workspace: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).clone();
        let id = panel.id;
        let selected = panel.selected().cloned();
        let (title, glyph) = selected
            .as_ref()
            .map_or((SharedString::from("New panel"), icons::PLUS), |tab| {
                self.panel_tab_label(tab, cx)
            });
        let attention = self.panel_attention(panel, cx);
        let tab_count = panel.tabs.len();
        let group = SharedString::from(format!("instrument-slot-{id}"));
        let focus = self
            .workspace_panels
            .controls
            .entry(format!("instrument-slot-{id}"))
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let drag = selected.clone().map(|tab| PanelTabDrag {
            workspace: workspace.into(),
            panel: id,
            tab,
            title: title.clone(),
        });
        let dragging_tab = self.workspace_panels.dragging_tab.clone();
        let drag_source = cx.weak_entity();
        let drag_outside = self.workspace_panels.drag_preview_visible.clone();
        let device = self.panel_device_label(id, cx);
        let tooltip_title = match attention {
            Some(attention) => format!("{title} · {device} · {}", attention.label()),
            None => format!("{title} · {device}"),
        };
        let shortcut = (ix < 6)
            .then(|| settings::badge_combo(&format!("cmd-alt-{}", ix + 1)))
            .unwrap_or_default();
        let leading = match attention {
            Some(attention) => div()
                .debug_selector(move || format!("instrument-slot-attention-{id}"))
                .size(px(7.0))
                .mx(px(3.5))
                .rounded_full()
                .flex_none()
                .bg(attention.color(&theme))
                .into_any_element(),
            None => icon(glyph)
                .size(px(14.0))
                .flex_none()
                .text_color(theme.text_muted)
                .into_any_element(),
        };
        let add_button = div()
            .id(("instrument-slot-add", id))
            .debug_selector(move || format!("instrument-slot-add-{id}"))
            .flex_none()
            .size(px(18.0))
            .rounded(px(4.0))
            .flex()
            .items_center()
            .justify_center()
            .role(gpui::Role::Button)
            .aria_label("New tab in this panel")
            .opacity(0.0)
            .group_hover(group.clone(), |style| style.opacity(1.0))
            .hover(|style| style.bg(theme.ink(0.10)))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _: &MouseDownEvent, window, cx| {
                    window.prevent_default();
                    this.workspace_panels.target = Some(id);
                    this.workspace_new_tab(cx);
                    this.focus_workspace_new_tab(window, cx);
                    cx.stop_propagation();
                }),
            )
            .child(
                icon(icons::PLUS)
                    .size(px(11.0))
                    .text_color(theme.text_muted),
            );
        let menu_button = div()
            .id(("instrument-slot-menu", id))
            .debug_selector(move || format!("instrument-slot-menu-{id}"))
            .flex_none()
            .h(px(18.0))
            .min_w(px(18.0))
            .px(px(3.0))
            .rounded(px(4.0))
            .flex()
            .items_center()
            .justify_center()
            .gap(px(2.0))
            .role(gpui::Role::Button)
            .aria_label("Panel menu")
            .text_size(crate::typography::ui_rems(11.0))
            .text_color(theme.text_muted)
            // A panel with one tab shows its menu only under the pointer.
            .when(tab_count <= 1, |button| {
                button
                    .opacity(0.0)
                    .group_hover(group.clone(), |style| style.opacity(1.0))
            })
            .hover(|style| style.bg(theme.ink(0.10)))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    window.prevent_default();
                    this.open_strip_menu(id, event.position, window, cx);
                    cx.stop_propagation();
                }),
            )
            .when(tab_count > 1, |button| button.child(tab_count.to_string()))
            .child(
                icon(icons::ALT_ARROW_DOWN)
                    .size(px(11.0))
                    .text_color(theme.text_muted),
            );
        div()
            .id(("instrument-slot", id))
            .debug_selector(move || format!("instrument-slot-{id}"))
            .group(group)
            .track_focus(&focus)
            .min_w_0()
            .map(|slot| match width {
                Some(width) => slot.flex_none().w(px(width)),
                None => slot.flex_1().max_w(px(SLOT_MAX_WIDTH)),
            })
            .h(px(SLOT_HEIGHT))
            .overflow_hidden()
            .pl(px(7.0))
            .pr(px(4.0))
            .rounded(px(6.0))
            .flex()
            .items_center()
            .gap(px(6.0))
            .cursor_pointer()
            .text_size(crate::typography::ui_rems(12.0))
            .text_color(if focused {
                theme.text
            } else {
                theme.text_muted
            })
            .role(gpui::Role::Button)
            .aria_label(tooltip_title.clone())
            .when(focused, |slot| slot.bg(theme.element_active))
            .when(!focused, |slot| {
                slot.hover(|style| style.bg(theme.element_hover))
            })
            .focus_visible(move |style| style.border_1().border_color(theme.accent))
            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                window.prevent_default();
                cx.stop_propagation();
            })
            .on_click(cx.listener(move |this, _, window, cx| {
                cx.stop_propagation();
                this.focus_strip_slot(id, window, cx);
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        this.focus_strip_slot(id, window, cx);
                        cx.stop_propagation();
                    }
                }),
            )
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    this.open_strip_menu(id, event.position, window, cx);
                    cx.stop_propagation();
                }),
            )
            .drag_over::<PanelTabDrag>(move |style, _, _, _| style.bg(theme.accent.opacity(0.14)))
            .on_drop::<PanelTabDrag>(cx.listener(move |this, drag: &PanelTabDrag, window, cx| {
                if drag.workspace == this.workspace_layout_key(cx) {
                    this.drop_workspace_tab(drag, id, None, window, cx);
                }
                cx.stop_propagation();
            }))
            .when_some(drag, |slot, drag| {
                slot.on_drag(drag, move |drag, grab, window, cx| {
                    dragging_tab.set(true);
                    cx.stop_propagation();
                    let title = drag.title.clone();
                    let _ = drag_source.update(cx, |this, cx| {
                        this.begin_window_tab_drag(drag.clone(), grab, SLOT_MAX_WIDTH, window, cx);
                    });
                    let source = window.window_handle().window_id();
                    let outside = drag_outside.clone();
                    cx.new(|_| window_drag::WindowTabGhost {
                        title,
                        icon: glyph,
                        source,
                        outside,
                        width: SLOT_MAX_WIDTH,
                    })
                })
            })
            .tooltip(move |_, cx| {
                popover::shortcut_tooltip(tooltip_title.clone(), shortcut.clone(), cx)
            })
            .child(leading)
            // Its own line, so a slot never has to choose between the title and
            // the computer however narrow it gets.
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .line_height(px(14.0))
                            .child(title),
                    )
                    .child(device_label(
                        format!("instrument-slot-device-{id}"),
                        device,
                        &theme,
                    )),
            )
            .child(add_button)
            .child(menu_button)
            .into_any_element()
    }

    /// Focus a panel from its slot. While one panel is expanded, the slot
    /// switches which panel is expanded, so every panel stays one press away.
    pub(in crate::shell) fn focus_strip_slot(
        &mut self,
        id: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let layout = self.panel_layout_mut(cx);
        if layout.expanded.is_some() {
            layout.expanded = Some(id);
        }
        match layout.panel(id).and_then(|panel| panel.selected().cloned()) {
            Some(tab) => self.focus_workspace_tab(id, tab, window, cx),
            None => {
                layout.focused = id;
                cx.notify();
            }
        }
    }

    /// `⌘⌥1`–`⌘⌥6`: the slot at this position. Plain `⌘1` stays the session
    /// jump and `⌃1` the chat tab.
    pub(in crate::shell) fn focus_strip_position(
        &mut self,
        position: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !INSTRUMENT_STRIP {
            return;
        }
        let panel = self
            .panel_layout(cx)
            .and_then(|layout| layout.panels.get(position))
            .map(|panel| panel.id);
        if let Some(id) = panel {
            self.focus_strip_slot(id, window, cx);
        }
    }

    /// `⌘⇧J`: the next tab asking for something, starting after the focused
    /// panel and wrapping around.
    pub(in crate::shell) fn focus_next_attention(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !INSTRUMENT_STRIP {
            return;
        }
        let Some(layout) = self.panel_layout(cx).cloned() else {
            return;
        };
        let start = layout
            .panels
            .iter()
            .position(|panel| panel.id == layout.focused)
            .map_or(0, |ix| ix + 1);
        let count = layout.panels.len();
        let target = (0..count)
            .map(|offset| &layout.panels[(start + offset) % count])
            .find_map(|panel| {
                panel.tabs.iter().enumerate().find_map(|(ix, tab)| {
                    self.tab_attention(panel.id, ix, tab, cx)
                        .map(|_| (panel.id, tab.clone()))
                })
            });
        if let Some((id, tab)) = target {
            let layout = self.panel_layout_mut(cx);
            if layout.expanded.is_some() {
                layout.expanded = Some(id);
            }
            self.focus_workspace_tab(id, tab, window, cx);
        }
    }

    pub(super) fn open_strip_menu(
        &mut self,
        id: u64,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.park_workspace_draft(cx);
        self.workspace_panels.target = None;
        let Some(layout) = self.panel_layout(cx).cloned() else {
            return;
        };
        let Some(panel) = layout.panel(id).cloned() else {
            return;
        };
        let vertical = layout.axis == SplitAxis::Vertical;
        let mut rows: Vec<(SharedString, &'static str, MenuAction)> = vec![];
        if panel.tabs.len() > 1 {
            for (ix, tab) in panel.tabs.iter().enumerate() {
                let (title, glyph) = self.panel_tab_label(tab, cx);
                rows.push((title, glyph, MenuAction::SelectTab(ix)));
            }
        }
        rows.push(("New tab".into(), icons::PLUS, MenuAction::NewTab));
        rows.push((
            "Split right".into(),
            icons::ALT_ARROW_RIGHT,
            MenuAction::AddPanel(SplitAxis::Horizontal),
        ));
        rows.push((
            "Split down".into(),
            icons::ALT_ARROW_DOWN,
            MenuAction::AddPanel(SplitAxis::Vertical),
        ));
        for after in [false, true] {
            if layout.neighbor(id, after).is_some() {
                let (label, glyph) = match (vertical, after) {
                    (false, false) => ("Move panel left", icons::ALT_ARROW_LEFT),
                    (false, true) => ("Move panel right", icons::ALT_ARROW_RIGHT),
                    (true, false) => ("Move panel up", icons::ALT_ARROW_UP),
                    (true, true) => ("Move panel down", icons::ALT_ARROW_DOWN),
                };
                rows.push((label.into(), glyph, MenuAction::MovePanel(after)));
            }
        }
        if layout.panels.len() > 1 {
            let expanded = layout.expanded == Some(id);
            rows.push((
                if expanded {
                    "Restore panels".into()
                } else {
                    "Expand panel".into()
                },
                if expanded {
                    icons::COLLAPSE_ARROWS
                } else {
                    icons::EXPAND_ARROWS
                },
                MenuAction::ToggleExpand,
            ));
        }
        if panel.selected().is_some() {
            rows.push((
                "Move tab to new window".into(),
                icons::ARROW_UP_RIGHT,
                MenuAction::MoveToWindow,
            ));
            rows.push(("Close tab".into(), icons::CLOSE, MenuAction::CloseTab));
        }
        if layout.panels.len() > 1 {
            rows.push(("Close panel".into(), icons::CLOSE, MenuAction::ClosePanel));
        }
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        self.workspace_panels.menu = Some(PanelMenu {
            panel: id,
            tab: panel.selected().cloned(),
            placement: false,
            position,
            rows,
            selected: if panel.tabs.len() > 1 {
                panel.active
            } else {
                0
            },
            focus,
        });
        cx.notify();
    }

    /// One panel holding two tabs: nothing has split, so no strip.
    #[cfg(feature = "appshots-fixture")]
    pub(in crate::shell) fn fixture_single_panel_tabs(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let layout = self.panel_layout_mut(cx);
        layout.axis = SplitAxis::Horizontal;
        layout.expanded = None;
        layout.panels.truncate(1);
        layout.panels[0].tabs = vec![
            PanelTab::Chat("launch-0".into()),
            PanelTab::Chat("launch-1".into()),
        ];
        layout.panels[0].active = 0;
        layout.equalize();
        self.focus_workspace_tab(0, PanelTab::Chat("launch-0".into()), window, cx);
    }

    #[cfg(feature = "appshots-fixture")]
    pub(in crate::shell) fn fixture_instrument_strip(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let chats = ["launch-0", "launch-1", "mobile-0", "launch-2", "mobile-1"];
        self.state.update(cx, |state, _| {
            state.devices.retain(|device| device.id != "studio");
            state.devices.push(harness_proto::Device {
                id: "studio".into(),
                name: "Studio computer".into(),
                platform: "macos".into(),
                last_seen_at: Some(Utc::now()),
                created_at: None,
                version: None,
                cursor_sdk_version: None,
                capabilities: vec![],
            });
            if let Some(chat) = state.chats.iter_mut().find(|chat| chat.id == "mobile-0") {
                chat.device_id = "studio".into();
            }
        });
        let layout = self.panel_layout_mut(cx);
        layout.axis = SplitAxis::Horizontal;
        layout.expanded = None;
        layout.panels.truncate(1);
        while layout.panels.len() < 4 {
            let last = layout.panels.last().unwrap().id;
            layout.add_panel(last);
        }
        layout.equalize();
        let tabs: [&[&str]; 4] = [&chats[..2], &chats[2..3], &chats[3..4], &chats[4..5]];
        for (panel, tabs) in layout.panels.iter_mut().zip(tabs) {
            panel.tabs = tabs
                .iter()
                .map(|chat| PanelTab::Chat((*chat).into()))
                .collect();
            panel.active = 0;
        }
        self.focus_workspace_tab(0, PanelTab::Chat(chats[0].into()), window, cx);
    }
}
