//! macOS image previews and annotation share one canvas and reserved footer.

use gpui::{AnyElement, Bounds, FocusHandle, Pixels, Size, div, point, prelude::*, px, size};

use super::PreviewImage;
use crate::theme::Theme;

pub(crate) struct ImagePreviewLayout {
    pub frame: Bounds<Pixels>,
    pub footer_top: Pixels,
    pub compact: bool,
    pub gutter: Pixels,
}

/// Reserve room for the viewer's actions and the editor's two toolbar groups.
/// Using the same canvas keeps portrait images fixed when annotation begins.
pub(crate) fn image_preview_layout(viewport: Size<Pixels>) -> ImagePreviewLayout {
    let width = f32::from(viewport.width);
    let height = f32::from(viewport.height);
    let compact = width < 560.0;
    let gutter = if compact { 16.0 } else { 24.0 };
    let footer_height = if compact { 200.0 } else { 148.0 };
    let frame_width = (width * 0.9).min(width - 2.0 * gutter).max(1.0);
    let frame_height = (height - gutter - footer_height).max(40.0);
    let frame = Bounds::new(
        point(px((width - frame_width) / 2.0), px(gutter)),
        size(px(frame_width), px(frame_height)),
    );
    ImagePreviewLayout {
        footer_top: frame.bottom() + px(12.0),
        frame,
        compact,
        gutter: px(gutter),
    }
}

pub(super) fn annotation_actions(
    prefix: &'static str,
    preview: &PreviewImage,
    focus: &FocusHandle,
    window: &gpui::Window,
    cx: &gpui::App,
) -> Option<gpui::Stateful<gpui::Div>> {
    use crate::annotate::editor::EditorMode;
    if preview.edit_unavailable() {
        return Some(
            div()
                .id(gpui::SharedString::from(format!("{prefix}-actions")))
                .max_w_full()
                .px(px(12.0))
                .py(px(8.0))
                .rounded(px(12.0))
                .bg(Theme::of(cx).surface_overlay.alpha(1.0))
                .text_color(Theme::of(cx).text)
                .text_size(crate::typography::ui_rems(12.0))
                .child("The original image is unavailable. Reattach it to edit these marks."),
        );
    }
    preview.annotate.as_ref()?;
    let owner = window.current_view();
    let theme = Theme::of(cx);
    let mut actions = div()
        .id(gpui::SharedString::from(format!("{prefix}-actions")))
        .debug_selector(move || format!("{prefix}-actions"))
        .flex()
        .items_center()
        .gap(px(4.0))
        .p(px(4.0))
        .rounded(px(22.0))
        .bg(theme.surface_overlay.alpha(1.0))
        .border_1()
        .border_color(theme.border)
        .shadow_md()
        .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation());
    for (mode, suffix, label, icon) in [
        (EditorMode::Markup, "markup", "Markup", crate::icons::PEN),
        (
            EditorMode::Comment,
            "comment",
            "Comment",
            crate::icons::CHAT_ROUND_LINE,
        ),
    ] {
        let preview = preview.clone();
        let keyboard_preview = preview.clone();
        let focus = focus.clone();
        let keyboard_focus = focus.clone();
        actions = actions.child(
            div()
                .id(gpui::SharedString::from(format!("{prefix}-{suffix}")))
                .debug_selector(move || format!("{prefix}-{suffix}"))
                .h(px(36.0))
                .px(px(12.0))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .gap(px(6.0))
                .rounded(px(18.0))
                .text_size(crate::typography::ui_rems(12.0))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(theme.text)
                .role(gpui::Role::Button)
                .aria_label(label)
                .tab_index(0)
                .cursor_pointer()
                .border_1()
                .border_color(gpui::transparent_black())
                .focus_visible(|style| style.border_color(theme.accent))
                .hover(|style| style.bg(theme.element_hover))
                .on_click(move |_, window, cx| {
                    cx.stop_propagation();
                    preview.open_annotate_mode(mode, owner, focus.clone(), window, cx);
                })
                .on_key_down(move |event, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        cx.stop_propagation();
                        keyboard_preview.open_annotate_mode(
                            mode,
                            owner,
                            keyboard_focus.clone(),
                            window,
                            cx,
                        );
                    }
                })
                .child(
                    crate::icons::icon(icon)
                        .size(px(14.0))
                        .text_color(theme.text),
                )
                .child(label),
        );
    }
    Some(actions)
}

pub(super) fn lightbox(
    window: &mut gpui::Window,
    preview: &PreviewImage,
    focus: &FocusHandle,
    natural_size: Option<Size<Pixels>>,
    on_close: impl Fn(&mut gpui::Window, &mut gpui::App) + 'static,
    cx: &mut gpui::App,
) -> AnyElement {
    if let Some(editor) = preview.annotate_editor() {
        return gpui::deferred(
            gpui::anchored()
                .position(point(px(0.0), px(0.0)))
                .child(editor),
        )
        .priority(3)
        .into_any_element();
    }
    let viewport = window.viewport_size();
    let layout = image_preview_layout(viewport);
    let button = annotation_actions("attachment-lightbox", preview, focus, window, cx);
    let natural_size = natural_size.or_else(|| {
        preview
            .image
            .clone()
            .use_render_image(window, cx)
            .map(|image| {
                let dimensions = image.size(0);
                size(
                    px(dimensions.width.0 as f32),
                    px(dimensions.height.0 as f32),
                )
            })
    });
    let content = match natural_size {
        Some(natural) => preview
            .viewer
            .render(preview.image.clone(), natural, None, window, cx),
        None => div().child("Loading image…").into_any_element(),
    };
    let theme = Theme::of(cx);
    let on_close = std::rc::Rc::new(on_close);
    let close_on_key = on_close.clone();
    let press_state = preview.viewer.clone();
    let click_state = preview.viewer.clone();
    gpui::deferred(
        gpui::anchored().position(point(px(0.0), px(0.0))).child(
            div()
                .id("attachment-lightbox")
                .occlude()
                .track_focus(focus)
                .w(viewport.width)
                .h(viewport.height)
                .relative()
                .bg(crate::popover::scrim_alpha(0.7))
                .text_color(theme.text)
                .on_key_down(move |event: &gpui::KeyDownEvent, window, cx| {
                    if event.keystroke.key == "escape" {
                        cx.stop_propagation();
                        close_on_key(window, cx);
                    }
                })
                .capture_any_mouse_down(move |event, _, _| {
                    if event.button == gpui::MouseButton::Left {
                        press_state.begin_click();
                    }
                })
                .on_click(move |_, window, cx| {
                    cx.stop_propagation();
                    if !click_state.dragged() {
                        on_close(window, cx);
                    }
                })
                .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
                .child(
                    div()
                        .id("attachment-lightbox-frame")
                        .debug_selector(|| "attachment-lightbox-frame".into())
                        .absolute()
                        .left(layout.frame.origin.x)
                        .top(layout.frame.origin.y)
                        .w(layout.frame.size.width)
                        .h(layout.frame.size.height)
                        .child(content),
                )
                .child(
                    div()
                        .absolute()
                        .top(layout.footer_top)
                        .left(layout.gutter)
                        .right(layout.gutter)
                        .flex()
                        .flex_col()
                        .items_center()
                        .gap(px(8.0))
                        .child(
                            div()
                                .max_w(layout.frame.size.width)
                                .h(px(18.0))
                                .px(px(8.0))
                                .rounded(px(4.0))
                                .bg(theme.surface_overlay.alpha(1.0))
                                .overflow_hidden()
                                .text_ellipsis()
                                .whitespace_nowrap()
                                .text_size(crate::typography::ui_rems(11.0))
                                .line_height(px(18.0))
                                .text_color(theme.text)
                                .child(preview.name.clone()),
                        )
                        .children(button),
                ),
        ),
    )
    .priority(3)
    .into_any_element()
}
