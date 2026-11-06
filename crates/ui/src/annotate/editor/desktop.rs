//! macOS markup gestures. The shared model stores geometry in image pixels.
use super::*;

mod toolbar;

// Thumb centers and pointer mapping use the same inset at both ends.
const WIDTH_TRACK_INSET: f32 = 16.0;

pub(super) struct DesktopTools {
    brush_width: f32,
    eraser_width: f32,
    pub(super) width_hovered: bool,
    width_motion: motion::HoverFades,
    pub(super) color_open: bool,
    pub(super) width_dragging: bool,
    width_bounds: Rc<Cell<Bounds<Pixels>>>,
    color_anchor: Rc<Cell<Bounds<Pixels>>>,
    width_focus: FocusHandle,
    stroke: Option<Vec<(f32, f32)>>,
    stroke_width: f32,
    erase_from: Option<(f32, f32)>,
    pointer: Option<(f32, f32)>,
}

impl DesktopTools {
    pub(super) fn new(cx: &mut Context<AnnotateEditor>) -> Self {
        Self {
            brush_width: 4.0,
            eraser_width: 20.0,
            width_hovered: false,
            width_motion: motion::HoverFades::with_spec(motion::MotionSpec::new(
                180,
                motion::EASE_OUT_QUINT,
            )),
            color_open: false,
            width_dragging: false,
            width_bounds: Rc::default(),
            color_anchor: Rc::default(),
            width_focus: cx.focus_handle(),
            stroke: None,
            stroke_width: 4.0,
            erase_from: None,
            pointer: None,
        }
    }
}

impl AnnotateEditor {
    fn clamped_point(&self, at: (f32, f32)) -> (f32, f32) {
        (at.0.clamp(0.0, self.size.0), at.1.clamp(0.0, self.size.1))
    }

    pub(super) fn width_value(&self) -> f32 {
        if self.tool == Tool::Eraser {
            self.desktop.eraser_width
        } else {
            self.desktop.brush_width
        }
    }

    pub(super) fn width_control_visible(&self) -> bool {
        self.mode == EditorMode::Markup
            && matches!(self.tool, Tool::Pen | Tool::Rect | Tool::Eraser)
    }

    fn width_limits(&self) -> (f32, f32) {
        if self.tool == Tool::Eraser {
            (8.0, 48.0)
        } else {
            (1.0, 20.0)
        }
    }

    fn set_width(&mut self, value: f32, cx: &mut Context<Self>) {
        let (min, max) = self.width_limits();
        let value = value.round().clamp(min, max);
        if self.tool == Tool::Eraser {
            self.desktop.eraser_width = value;
        } else {
            self.desktop.brush_width = value;
        }
        cx.notify();
    }

    fn update_width(&mut self, position: gpui::Point<Pixels>, cx: &mut Context<Self>) {
        let bounds = self.desktop.width_bounds.get();
        let height = (f32::from(bounds.size.height) - WIDTH_TRACK_INSET * 2.0).max(1.0);
        let fraction = ((f32::from(bounds.bottom() - position.y) - WIDTH_TRACK_INSET) / height)
            .clamp(0.0, 1.0);
        let (min, max) = self.width_limits();
        self.set_width(min + fraction * (max - min), cx);
    }

    pub(super) fn finish_gesture(&mut self) {
        if let Some(points) = self.desktop.stroke.take() {
            self.doc
                .add_stroke(points, self.desktop.stroke_width, self.color);
        }
        if self.desktop.erase_from.take().is_some() {
            self.doc.end_erase();
        }
    }

    fn switch_mode(&mut self, mode: EditorMode, window: &mut Window, cx: &mut Context<Self>) {
        self.finish_gesture();
        if self.editing.is_some() {
            self.finish_editing(window, cx);
        }
        self.mode = mode;
        self.tool = if mode == EditorMode::Comment {
            Tool::Comment
        } else {
            Tool::Pen
        };
        self.desktop.width_hovered = false;
        self.desktop.color_open = false;
        self.drag = None;
        self.doc.select(None);
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn select_tool(&mut self, tool: Tool, window: &mut Window, cx: &mut Context<Self>) {
        self.finish_gesture();
        if self.editing.is_some() {
            self.finish_editing(window, cx);
        }
        self.drag = None;
        self.set_tool(tool, cx);
        window.focus(&self.focus, cx);
    }

    pub(super) fn on_image_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.stop_propagation();
        window.prevent_default();
        self.desktop.width_hovered = false;
        self.desktop.color_open = false;
        if self.editing.is_some() {
            self.finish_editing(window, cx);
        }
        self.finish_gesture();
        let at = self.clamped_point(self.to_image(event.position));
        self.desktop.pointer = Some(at);
        window.focus(&self.focus, cx);
        match self.tool {
            Tool::Pen => {
                self.doc.select(None);
                self.desktop.stroke = Some(vec![at]);
                self.desktop.stroke_width = self.desktop.brush_width * self.image_px();
            }
            Tool::Eraser => {
                self.doc.select(None);
                self.doc.begin_erase();
                self.doc
                    .erase_segment(at, at, self.desktop.eraser_width * self.image_px() / 2.0);
                self.desktop.erase_from = Some(at);
            }
            Tool::Comment => {
                if let Some(id) = self.doc.add_comment(at, MarkColor::Blue) {
                    self.begin_editing(id, window, cx);
                }
            }
            Tool::Text => self.place_text(at, window, cx),
            Tool::Rect => {
                self.drag = Some(Drag {
                    start: at,
                    current: at,
                })
            }
        }
        cx.notify();
    }

    pub(super) fn on_move(
        &mut self,
        event: &MouseMoveEvent,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.desktop.width_dragging {
            if event.pressed_button == Some(MouseButton::Left) {
                self.update_width(event.position, cx);
            } else {
                self.desktop.width_dragging = false;
            }
            return;
        }
        let point = self.to_image(event.position);
        let in_image =
            point.0 >= 0.0 && point.1 >= 0.0 && point.0 <= self.size.0 && point.1 <= self.size.1;
        self.desktop.pointer = in_image.then_some(point);
        if event.pressed_button != Some(MouseButton::Left) {
            self.finish_gesture();
            if matches!(self.tool, Tool::Pen | Tool::Eraser) {
                cx.notify();
            }
            return;
        }
        let at = self.clamped_point(point);
        let min_distance = self.image_px() * 0.35;
        if let Some(points) = &mut self.desktop.stroke {
            if points.len() < super::super::MAX_STROKE_POINTS
                && points
                    .last()
                    .is_none_or(|p| (p.0 - at.0).hypot(p.1 - at.1) >= min_distance)
            {
                points.push(at);
            }
        }
        if let Some(from) = self.desktop.erase_from {
            self.doc
                .erase_segment(from, at, self.desktop.eraser_width * self.image_px() / 2.0);
            self.desktop.erase_from = Some(at);
        }
        if let Some(drag) = &mut self.drag {
            drag.current = at;
        }
        cx.notify();
    }

    pub(super) fn on_up(&mut self, event: &MouseUpEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.desktop.width_dragging {
            self.update_width(event.position, cx);
            self.desktop.width_dragging = false;
            return;
        }
        let at = self.clamped_point(self.to_image(event.position));
        if let Some(points) = &mut self.desktop.stroke {
            if points.len() < super::super::MAX_STROKE_POINTS && points.last() != Some(&at) {
                points.push(at);
            }
        }
        if let Some(from) = self.desktop.erase_from {
            self.doc
                .erase_segment(from, at, self.desktop.eraser_width * self.image_px() / 2.0);
        }
        self.finish_gesture();
        if let Some(drag) = self.drag.take() {
            let rect = ImageRect::from_drag(drag.start, at, self.size);
            self.doc
                .add_markup_rect(rect, self.desktop.brush_width * self.image_px(), self.color);
        }
        cx.notify();
    }

    pub(super) fn on_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = event.keystroke.key.as_str();
        let note_focused = self.note.read(cx).focus_handle(cx).is_focused(window);
        if self.width_control_visible() && self.desktop.width_focus.is_focused(window) {
            let (min, max) = self.width_limits();
            let value = match key {
                "up" | "right" => Some(self.width_value() + 1.0),
                "down" | "left" => Some(self.width_value() - 1.0),
                "pageup" => Some(self.width_value() + 5.0),
                "pagedown" => Some(self.width_value() - 5.0),
                "home" => Some(min),
                "end" => Some(max),
                _ => None,
            };
            if let Some(value) = value {
                cx.stop_propagation();
                self.set_width(value, cx);
                return;
            }
        }
        match key {
            "escape" => {
                cx.stop_propagation();
                if self.desktop.width_focus.is_focused(window) || self.desktop.color_open {
                    self.desktop.width_hovered = false;
                    self.desktop.color_open = false;
                    window.focus(&self.focus, cx);
                    cx.notify();
                } else if self.editing.is_some() {
                    self.finish_editing(window, cx);
                } else {
                    self.cancel(window, cx);
                }
            }
            "backspace" | "delete" if !note_focused => {
                cx.stop_propagation();
                if let Some(id) = self.doc.selected() {
                    self.remove(id, window, cx);
                }
            }
            "z" if event.keystroke.modifiers.secondary() && !note_focused => {
                cx.stop_propagation();
                self.finish_gesture();
                if event.keystroke.modifiers.shift {
                    self.redo(window, cx);
                } else {
                    self.undo(window, cx);
                }
            }
            "y" if event.keystroke.modifiers.secondary() && !note_focused => {
                cx.stop_propagation();
                self.finish_gesture();
                self.redo(window, cx);
            }
            _ => {}
        }
    }

    pub(super) fn desktop_marks(&self, scale: f32) -> Vec<AnyElement> {
        let mut marks = Vec::new();
        for mark in self.doc.items() {
            match &mark.shape {
                Shape::Stroke { points, width } => {
                    marks.push(stroke_layer(points.clone(), *width, mark.color, scale))
                }
                Shape::MarkupRect { rect, width } => marks.push(
                    div()
                        .absolute()
                        .left(px(rect.x * scale))
                        .top(px(rect.y * scale))
                        .w(px(rect.w * scale))
                        .h(px(rect.h * scale))
                        .border(px(width * scale))
                        .border_color(rgb(mark.color.rgb()))
                        .rounded(px(SCREEN_METRICS.box_radius))
                        .into_any_element(),
                ),
                _ => {}
            }
        }
        if let Some(points) = &self.desktop.stroke {
            marks.push(stroke_layer(
                points.clone(),
                self.desktop.stroke_width,
                self.color,
                scale,
            ));
        }
        if self.tool == Tool::Eraser
            && let Some((x, y)) = self.desktop.pointer
        {
            let diameter = self.desktop.eraser_width;
            marks.push(
                div()
                    .absolute()
                    .left(px(x * scale - diameter / 2.0))
                    .top(px(y * scale - diameter / 2.0))
                    .size(px(diameter))
                    .rounded_full()
                    .border_1()
                    .border_color(gpui::white())
                    .bg(gpui::black().opacity(0.18))
                    .into_any_element(),
            );
        }
        marks
    }
}

fn stroke_layer(points: Vec<(f32, f32)>, width: f32, color: MarkColor, scale: f32) -> AnyElement {
    gpui::canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let color = rgb(color.rgb());
            let width = width * scale;
            let mut path = gpui::PathBuilder::stroke(px(width));
            for (i, (x, y)) in points.iter().enumerate() {
                let point = bounds.origin + gpui::point(px(x * scale), px(y * scale));
                if i == 0 {
                    path.move_to(point);
                } else {
                    path.line_to(point);
                }
            }
            if points.len() > 1
                && let Ok(path) = path.build()
            {
                window.paint_path(path, color);
            }
            // Round end caps also render a tap as a visible dot.
            for (x, y) in points
                .first()
                .into_iter()
                .chain(points.last().filter(|_| points.len() > 1))
            {
                let origin = bounds.origin
                    + gpui::point(px(x * scale - width / 2.0), px(y * scale - width / 2.0));
                window.paint_quad(
                    gpui::fill(Bounds::new(origin, gpui::size(px(width), px(width))), color)
                        .corner_radii(px(width / 2.0)),
                );
            }
        },
    )
    .absolute()
    .inset_0()
    .into_any_element()
}
