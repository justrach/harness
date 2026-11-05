//! Opaque desktop annotation controls and their anchored tool popovers.

use super::*;

const WIDTH_RAIL_HEIGHT: f32 = 216.0;
const WIDTH_RAIL_WIDTH: f32 = 44.0;
const WIDTH_SLIDER_WIDTH: f32 = 32.0;
const WIDTH_THUMB: f32 = 16.0;

fn activates(event: &KeyDownEvent) -> bool {
    matches!(event.keystroke.key.as_str(), "enter" | "space")
}

fn history_button(
    id: &'static str,
    icon: &'static str,
    label: &'static str,
    enabled: bool,
    action: fn(&mut AnnotateEditor, &mut Window, &mut Context<AnnotateEditor>),
    theme: &Theme,
    cx: &mut Context<AnnotateEditor>,
) -> gpui::Stateful<gpui::Div> {
    icon_button(id, icon, label, false, enabled, theme)
        .debug_selector(move || id.into())
        .role(gpui::Role::Button)
        .when(enabled, |el| el.tab_index(0))
        .focus_visible(|style| style.bg(theme.element_hover))
        .on_click(cx.listener(move |this, _, window, cx| {
            cx.stop_propagation();
            if enabled {
                action(this, window, cx);
            }
        }))
        .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
            if enabled && activates(event) {
                cx.stop_propagation();
                action(this, window, cx);
            }
        }))
}

fn tool_button(
    tool: Tool,
    icon: &'static str,
    label: &'static str,
    selected: Tool,
    theme: &Theme,
    cx: &mut Context<AnnotateEditor>,
) -> gpui::Stateful<gpui::Div> {
    let id = match tool {
        Tool::Pen => "annotate-tool-pen",
        Tool::Rect => "annotate-tool-rect",
        Tool::Text => "annotate-tool-text",
        Tool::Eraser => "annotate-tool-eraser",
        Tool::Comment => "annotate-tool-comment",
    };
    icon_button(id, icon, label, selected == tool, true, theme)
        .debug_selector(move || id.into())
        .role(gpui::Role::Button)
        .tab_index(0)
        .focus_visible(|style| style.bg(theme.element_hover))
        .on_click(cx.listener(move |this, _, window, cx| {
            cx.stop_propagation();
            this.select_tool(tool, window, cx);
        }))
        .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
            if activates(event) {
                cx.stop_propagation();
                this.select_tool(tool, window, cx);
            }
        }))
}

fn mode_button(
    mode: EditorMode,
    selected: EditorMode,
    theme: &Theme,
    cx: &mut Context<AnnotateEditor>,
) -> gpui::Stateful<gpui::Div> {
    let (id, icon, label) = match mode {
        EditorMode::Markup => ("annotate-mode-markup", icons::PEN, "Markup"),
        EditorMode::Comment => ("annotate-mode-comment", icons::CHAT_ROUND_LINE, "Comment"),
    };
    div()
        .id(id)
        .debug_selector(move || id.into())
        .h(px(28.0))
        .px(px(12.0))
        .flex()
        .items_center()
        .justify_center()
        .gap(px(6.0))
        .rounded(px(14.0))
        .when(mode == selected, |el| el.bg(theme.element_active))
        .text_size(ui_rems(TEXT_BODY))
        .font_weight(FontWeight::MEDIUM)
        .text_color(if mode == selected {
            theme.text
        } else {
            theme.text_muted
        })
        .role(gpui::Role::Button)
        .aria_label(label)
        .tab_index(0)
        .cursor_pointer()
        .hover(|style| style.bg(theme.element_hover))
        .focus_visible(|style| style.bg(theme.element_hover))
        .on_click(cx.listener(move |this, _, window, cx| {
            cx.stop_propagation();
            this.switch_mode(mode, window, cx);
        }))
        .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
            if activates(event) {
                cx.stop_propagation();
                this.switch_mode(mode, window, cx);
            }
        }))
        .child(
            icons::icon(icon)
                .size(px(14.0))
                .text_color(if mode == selected {
                    theme.text
                } else {
                    theme.text_muted
                }),
        )
        .child(label)
}

fn action_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    primary: bool,
    action: fn(&mut AnnotateEditor, &mut Window, &mut Context<AnnotateEditor>),
    theme: &Theme,
    cx: &mut Context<AnnotateEditor>,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .debug_selector(move || id.into())
        .h(px(HIT))
        .px(px(14.0))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(BAR_RADIUS - PAD))
        .when(primary, |el| el.bg(theme.solid))
        .text_size(ui_rems(TEXT_BODY))
        .font_weight(FontWeight::MEDIUM)
        .text_color(if primary { theme.on_solid } else { theme.text })
        .role(gpui::Role::Button)
        .aria_label(label)
        .when(enabled, |el| {
            el.tab_index(0).cursor_pointer().hover(|style| {
                if primary {
                    style.opacity(0.9)
                } else {
                    style.bg(theme.element_hover)
                }
            })
        })
        .when(!enabled, |el| el.opacity(0.45))
        .focus_visible(|style| style.border_1().border_color(theme.accent))
        .on_click(cx.listener(move |this, _, window, cx| {
            cx.stop_propagation();
            if enabled {
                action(this, window, cx);
            }
        }))
        .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
            if enabled && activates(event) {
                cx.stop_propagation();
                action(this, window, cx);
            }
        }))
        .child(label)
}

impl AnnotateEditor {
    pub(in super::super) fn desktop_toolbar(
        &mut self,
        viewport: gpui::Size<Pixels>,
        theme: &Theme,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let layout = crate::attachments::image_preview_layout(viewport);
        let mut tools = bar(theme).p(px(4.0));
        if self.mode == EditorMode::Markup {
            let color_anchor = self.desktop.color_anchor.clone();
            let color_trigger = div()
                .id("annotate-color-trigger")
                .debug_selector(|| "annotate-color-trigger".into())
                .relative()
                .size(px(HIT))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded_full()
                .when(self.desktop.color_open, |el| el.bg(theme.element_active))
                .role(gpui::Role::Button)
                .aria_label("Markup color")
                .tab_index(0)
                .cursor_pointer()
                .hover(|style| style.bg(theme.element_hover))
                .focus_visible(|style| style.bg(theme.element_hover))
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(cx.listener(|this, _, _, cx| {
                    cx.stop_propagation();
                    this.desktop.color_open = !this.desktop.color_open;
                    this.desktop.width_hovered = false;
                    cx.notify();
                }))
                .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                    if activates(event) {
                        cx.stop_propagation();
                        this.desktop.color_open = !this.desktop.color_open;
                        this.desktop.width_hovered = false;
                        cx.notify();
                    }
                }))
                .child(
                    div()
                        .size(px(16.0))
                        .rounded_full()
                        .bg(rgb(self.color.rgb()))
                        .border_1()
                        .border_color(theme.border_strong),
                )
                .child(
                    gpui::canvas(
                        move |bounds, _, _| color_anchor.set(bounds),
                        |_, _, _, _| {},
                    )
                    .absolute()
                    .inset_0(),
                );
            tools = tools
                .child(tool_button(
                    Tool::Pen,
                    icons::PEN,
                    "Pen",
                    self.tool,
                    theme,
                    cx,
                ))
                .child(tool_button(
                    Tool::Rect,
                    icons::ANNOTATE_RECT,
                    "Rectangle",
                    self.tool,
                    theme,
                    cx,
                ))
                .child(tool_button(
                    Tool::Text,
                    icons::ANNOTATE_TEXT,
                    "Text",
                    self.tool,
                    theme,
                    cx,
                ))
                .child(color_trigger)
                .child(tool_button(
                    Tool::Eraser,
                    icons::ERASER,
                    "Erase markup",
                    self.tool,
                    theme,
                    cx,
                ))
                .child(divider());
        } else {
            tools = tools
                .child(
                    div()
                        .px(px(8.0))
                        .text_size(ui_rems(TEXT_CAPTION))
                        .text_color(theme.text_muted)
                        .child("Click image to add comments"),
                )
                .child(divider());
        }
        let tools = tools
            .child(history_button(
                "annotate-undo",
                icons::UNDO,
                "Undo",
                self.doc.can_undo()
                    || self.editing.is_some_and(|id| {
                        self.doc
                            .get(id)
                            .is_some_and(|mark| mark.text != self.note.read(cx).text().trim())
                    }),
                Self::undo,
                theme,
                cx,
            ))
            .child(history_button(
                "annotate-redo",
                icons::REDO,
                "Redo",
                self.doc.can_redo()
                    && !self.editing.is_some_and(|id| {
                        self.doc
                            .get(id)
                            .is_some_and(|mark| mark.text != self.note.read(cx).text().trim())
                    }),
                Self::redo,
                theme,
                cx,
            ))
            .id("annotate-tools")
            .debug_selector(|| "annotate-tools".into())
            .flex_none();
        let actions = bar(theme)
            .p(px(4.0))
            .id("annotate-actions")
            .debug_selector(|| "annotate-actions".into())
            .flex_none()
            .gap(px(PAD))
            .child(action_button(
                "annotate-cancel",
                "Cancel",
                true,
                false,
                Self::cancel,
                theme,
                cx,
            ))
            .child(action_button(
                "annotate-done",
                "Done",
                !self.doc.is_empty() || self.had_editable,
                true,
                Self::done,
                theme,
                cx,
            ));
        let modes = div()
            .h(px(34.0))
            .p(px(2.0))
            .flex_none()
            .flex()
            .items_center()
            .rounded(px(17.0))
            .bg(editor_surface(theme))
            .border_1()
            .border_color(editor_border(theme))
            .shadow_md()
            .child(mode_button(EditorMode::Markup, self.mode, theme, cx))
            .child(mode_button(EditorMode::Comment, self.mode, theme, cx));
        div()
            .absolute()
            .top(layout.footer_top)
            .left_0()
            .right_0()
            .px(layout.gutter)
            .flex()
            .flex_col()
            .items_center()
            .gap(px(8.0))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    cx.stop_propagation();
                    if this.desktop.width_focus.is_focused(window) || this.desktop.color_open {
                        this.desktop.width_hovered = false;
                        this.desktop.color_open = false;
                        this.desktop.width_dragging = false;
                        window.focus(&this.focus, cx);
                        cx.notify();
                    }
                }),
            )
            .child(
                div()
                    .id("annotate-filename")
                    .debug_selector(|| "annotate-filename".into())
                    .h(px(18.0))
                    .px(px(8.0))
                    .rounded(px(4.0))
                    .bg(editor_surface(theme))
                    .max_w(viewport.width - layout.gutter * 2.0)
                    .truncate()
                    .text_size(ui_rems(TEXT_CAPTION))
                    .line_height(px(18.0))
                    .text_color(theme.text)
                    .child(self.name.clone()),
            )
            .child(modes)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.0))
                    .when(layout.compact, |el| el.flex_col())
                    .child(tools)
                    .child(actions),
            )
            .when_some(self.error.clone(), |el, error| {
                el.child(
                    div()
                        .absolute()
                        .top(px(-42.0))
                        .left(layout.gutter)
                        .right(layout.gutter)
                        .h(px(32.0))
                        .px(px(12.0))
                        .rounded(px(Theme::CONTROL_RADIUS))
                        .bg(editor_surface(theme))
                        .border_1()
                        .border_color(editor_border(theme))
                        .shadow_md()
                        .truncate()
                        .text_size(ui_rems(TEXT_CAPTION))
                        .line_height(px(30.0))
                        .text_color(theme.text)
                        .child(error),
                )
            })
            .into_any_element()
    }

    pub(in super::super) fn desktop_width_control(
        &mut self,
        viewport: gpui::Size<Pixels>,
        theme: &Theme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.width_control_visible() {
            return None;
        }
        let layout = crate::attachments::image_preview_layout(viewport);
        let height = px(WIDTH_RAIL_HEIGHT).min((layout.frame.size.height - px(16.0)).max(px(96.0)));
        let slider_height = f32::from(height) - 24.0;
        let top = layout.frame.center().y - height / 2.0;
        let value = self.width_value();
        let (minimum, maximum) = self.width_limits();
        let fraction = ((value - minimum) / (maximum - minimum)).clamp(0.0, 1.0);
        let keyboard_focus =
            self.desktop.width_focus.is_focused(window) && window.last_input_was_keyboard();
        let active = self.desktop.width_hovered || self.desktop.width_dragging || keyboard_focus;
        let now = std::time::Instant::now();
        let expansion = self.desktop.width_motion.transition_at(
            "width",
            active,
            motion::reduced_motion(cx),
            now,
        );
        if self.desktop.width_motion.tick_at(now) {
            window.request_animation_frame();
        }
        let track_width = 2.0 + 18.0 * expansion;
        let thumb_size = WIDTH_THUMB * (1.0 + expansion * 0.1);
        let measured = self.desktop.width_bounds.clone();
        let track_color = theme.text.opacity(0.28);
        let slider = div()
            .id("annotate-width-slider")
            .debug_selector(|| "annotate-width-slider".into())
            .track_focus(&self.desktop.width_focus)
            .relative()
            .w(px(WIDTH_SLIDER_WIDTH))
            .h(px(slider_height))
            .flex_none()
            .role(gpui::Role::Slider)
            .aria_label(format!(
                "{}: {value:.0} pixels",
                if self.tool == Tool::Eraser {
                    "Eraser size"
                } else {
                    "Stroke width"
                }
            ))
            .tab_index(0)
            .cursor_pointer()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    window.prevent_default();
                    this.finish_gesture();
                    this.desktop.color_open = false;
                    this.desktop.pointer = None;
                    window.focus(&this.desktop.width_focus, cx);
                    this.desktop.width_dragging = true;
                    this.update_width(event.position, cx);
                }),
            )
            .child(
                gpui::canvas(move |bounds, _, _| measured.set(bounds), |_, _, _, _| {})
                    .absolute()
                    .inset_0(),
            )
            .child(
                div()
                    .id("annotate-width-track")
                    .debug_selector(|| "annotate-width-track".into())
                    .absolute()
                    .left(px((WIDTH_SLIDER_WIDTH - track_width) / 2.0))
                    .top(px(WIDTH_TRACK_INSET))
                    .w(px(track_width))
                    .h(px(slider_height - WIDTH_TRACK_INSET * 2.0))
                    .child(
                        gpui::canvas(
                            |_, _, _| {},
                            move |bounds, _, window, _| {
                                let center = bounds.center().x;
                                let mut path = gpui::PathBuilder::fill();
                                path.move_to(gpui::point(bounds.left(), bounds.top()));
                                path.line_to(gpui::point(bounds.right(), bounds.top()));
                                path.line_to(gpui::point(center + px(1.0), bounds.bottom()));
                                path.line_to(gpui::point(center - px(1.0), bounds.bottom()));
                                path.close();
                                if let Ok(path) = path.build() {
                                    window.paint_path(path, track_color);
                                }
                            },
                        )
                        .absolute()
                        .inset_0(),
                    ),
            )
            .child(
                div()
                    .id("annotate-width-thumb")
                    .debug_selector(|| "annotate-width-thumb".into())
                    .absolute()
                    .left(px((WIDTH_SLIDER_WIDTH - thumb_size) / 2.0))
                    .top(px(WIDTH_TRACK_INSET - thumb_size / 2.0
                        + (1.0 - fraction)
                            * (slider_height - WIDTH_TRACK_INSET * 2.0)))
                    .size(px(thumb_size))
                    .rounded_full()
                    .bg(if theme.appearance.is_dark() {
                        theme.text
                    } else {
                        theme.element_active.alpha(1.0)
                    })
                    .border_1()
                    .border_color(if keyboard_focus {
                        theme.accent
                    } else {
                        theme.border_strong
                    })
                    .shadow_sm(),
            );
        Some(
            div()
                .id("annotate-width-rail")
                .debug_selector(|| "annotate-width-rail".into())
                .absolute()
                .left(layout.gutter)
                .top(top)
                .w(px(WIDTH_RAIL_WIDTH))
                .h(height)
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(WIDTH_RAIL_WIDTH / 2.0))
                .bg(editor_surface(theme))
                .border_1()
                .border_color(editor_border(theme))
                .shadow_md()
                .occlude()
                .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                    this.desktop.width_hovered = *hovered;
                    this.desktop.pointer = None;
                    cx.notify();
                }))
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(slider)
                .into_any_element(),
        )
    }

    pub(in super::super) fn desktop_popover(
        &mut self,
        viewport: gpui::Size<Pixels>,
        theme: &Theme,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let gutter = crate::attachments::image_preview_layout(viewport).gutter;
        if self.desktop.color_open {
            let width = px(180.0);
            let height = px(58.0);
            let anchor = self.desktop.color_anchor.get();
            let left = (anchor.center().x - width / 2.0)
                .clamp(gutter, (viewport.width - gutter - width).max(gutter));
            let top = (anchor.top() - height - px(8.0))
                .clamp(gutter, (viewport.height - gutter - height).max(gutter));
            let mut palette = div()
                .id("annotate-color-popover")
                .debug_selector(|| "annotate-color-popover".into())
                .absolute()
                .left(left)
                .top(top)
                .w(width)
                .h(height)
                .p(px(12.0))
                .flex()
                .items_center()
                .gap(px(8.0))
                .rounded(px(14.0))
                .bg(editor_surface(theme))
                .border_1()
                .border_color(editor_border(theme))
                .shadow_lg()
                .occlude()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation());
            for color in MarkColor::ALL {
                palette = palette.child(
                    div()
                        .id(("annotate-color", color as usize))
                        .debug_selector(move || {
                            format!("annotate-color-{}", color.label().to_lowercase())
                        })
                        .size(px(HIT))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_full()
                        .role(gpui::Role::Button)
                        .aria_label(color.label())
                        .tab_index(0)
                        .cursor_pointer()
                        .focus_visible(|style| style.bg(theme.element_hover))
                        .hover(|style| style.bg(theme.element_hover))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            cx.stop_propagation();
                            this.set_color(color, cx);
                            this.desktop.color_open = false;
                            window.focus(&this.focus, cx);
                            cx.notify();
                        }))
                        .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
                            if activates(event) {
                                cx.stop_propagation();
                                this.set_color(color, cx);
                                this.desktop.color_open = false;
                                window.focus(&this.focus, cx);
                                cx.notify();
                            }
                        }))
                        .child(
                            div()
                                .size(px(24.0))
                                .rounded_full()
                                .border_2()
                                .border_color(if self.color == color {
                                    theme.text
                                } else {
                                    gpui::transparent_black()
                                })
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(div().size(px(16.0)).rounded_full().bg(rgb(color.rgb()))),
                        ),
                );
            }
            return Some(palette.into_any_element());
        }
        None
    }
}
