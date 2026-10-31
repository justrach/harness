//! The annotate view: the preview image with a drawing surface, a floating
//! toolbar (tools, colors, undo, Cancel, Done) and the note popover.
//!
//! It opens from the lightbox's Annotate button ([`AnnotateHook`]) and keeps
//! the lightbox's geometry, so the image does not move when annotating starts.
//! Design: DESIGN.md "Annotate" (32px hit areas, tabular pin digits, one
//! ease-out curve, concentric radii, three type sizes and two weights).

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use gpui::AnimationExt as _;
use gpui::{
    AnyElement, App, Bounds, Context, CursorStyle, Entity, EventEmitter, FocusHandle, Focusable,
    FontFeatures, FontWeight, Hsla, Image, KeyDownEvent, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, Pixels, SharedString, Window, div, prelude::*, px,
};

use super::{
    Annotated, Annotations, ImageRect, MarkColor, SCREEN_METRICS, Shape, TEXT_MARK_SIZE, Tool,
    annotated_name, flatten, image_size, prompt_block,
};
use crate::composer::{ComposerInput, ComposerInputEvent};
use crate::icons;
use crate::motion;
use crate::theme::{Theme, hairline, ink};
use crate::typography::ui_rems;

/// The rules' type sizes (DESIGN.md typography): body and caption here;
/// text marks use the title size (TEXT_MARK_SIZE).
const TEXT_BODY: f32 = 12.0;
const TEXT_CAPTION: f32 = 11.0;
/// Smallest hit area for any control.
const HIT: f32 = 32.0;
/// Padding inside a floating bar or popover; nested radii are
/// `outer - PAD`, so corners stay concentric.
const PAD: f32 = 5.0;
const BAR_RADIUS: f32 = (HIT + 2.0 * PAD) / 2.0;
const POPOVER_PAD: f32 = 4.0;
const POPOVER_RADIUS: f32 = 10.0;
const POPOVER_WIDTH: f32 = 260.0;
const POPOVER_GAP: f32 = 8.0;
/// The one entry tween: short, ease-out, snapped under reduced motion.
const ENTER: motion::MotionSpec = motion::MotionSpec::new(180, motion::EASE_OUT_QUINT);
/// Lightbox layout this view mirrors (attachments::lightbox_with_size).
const BOX_W: f32 = 0.9;
const BOX_H: f32 = 0.85;
const CAPTION_GAP: f32 = 12.0;

pub(crate) fn tabular() -> FontFeatures {
    FontFeatures(Arc::new(vec![("tnum".into(), 1)]))
}

fn rgb(value: u32) -> Hsla {
    gpui::rgb(value).into()
}

/// Called with the flattened result when Done is pressed.
type OnDone = Rc<dyn Fn(Annotated, &mut Window, &mut App)>;
/// Called when the editor closes without a result.
type OnCancel = Rc<dyn Fn(&mut Window, &mut App)>;
/// Where an open editor lives so the lightbox can render it.
pub(crate) type EditorSlot = Rc<RefCell<Option<Entity<AnnotateEditor>>>>;

/// Lets a lightbox offer Annotate. `on_done` receives the flattened image;
/// the editor lives in `editor` while open so the lightbox can render it.
#[derive(Clone)]
pub struct AnnotateHook {
    on_done: OnDone,
    pub(crate) editor: EditorSlot,
}

impl AnnotateHook {
    pub fn new(on_done: impl Fn(Annotated, &mut Window, &mut App) + 'static) -> Self {
        Self {
            on_done: Rc::new(on_done),
            editor: Rc::default(),
        }
    }

    pub fn is_open(&self) -> bool {
        self.editor.borrow().is_some()
    }

    pub fn editor(&self) -> Option<Entity<AnnotateEditor>> {
        self.editor.borrow().clone()
    }

    /// Enter annotate mode for `image`. `owner` is the view rendering the
    /// lightbox; `return_focus` gets focus back on Cancel.
    pub fn open(
        &self,
        name: SharedString,
        image: Arc<Image>,
        owner: gpui::EntityId,
        return_focus: FocusHandle,
        window: &mut Window,
        cx: &mut App,
    ) {
        let cell = self.editor.clone();
        let on_cancel: OnCancel = Rc::new(move |window, cx| {
            cell.borrow_mut().take();
            window.focus(&return_focus, cx);
            cx.notify(owner);
        });
        let cell = self.editor.clone();
        let on_done = self.on_done.clone();
        let finish: OnDone = Rc::new(move |annotated, window, cx| {
            cell.borrow_mut().take();
            on_done(annotated, window, cx);
            cx.notify(owner);
        });
        let editor = cx.new(|cx| AnnotateEditor::new(name, image, finish, on_cancel, window, cx));
        let focus = editor.read(cx).focus.clone();
        *self.editor.borrow_mut() = Some(editor);
        window.focus(&focus, cx);
        cx.notify(owner);
    }
}

#[derive(Clone, Copy, Debug)]
struct Drag {
    start: (f32, f32),
    current: (f32, f32),
}

pub struct AnnotateEditor {
    name: SharedString,
    image: Arc<Image>,
    /// Natural size in image pixels.
    size: (f32, f32),
    pub(crate) doc: Annotations,
    pub(crate) tool: Tool,
    pub(crate) color: MarkColor,
    drag: Option<Drag>,
    /// The mark whose words the popover edits.
    pub(crate) editing: Option<u64>,
    note: Entity<ComposerInput>,
    focus: FocusHandle,
    /// The image box's window bounds, measured at prepaint.
    pub(super) frame: Rc<Cell<Bounds<Pixels>>>,
    scale: f32,
    error: Option<SharedString>,
    on_done: OnDone,
    on_cancel: OnCancel,
    _note_events: gpui::Subscription,
}

impl EventEmitter<()> for AnnotateEditor {}

impl Focusable for AnnotateEditor {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl AnnotateEditor {
    fn new(
        name: SharedString,
        image: Arc<Image>,
        on_done: OnDone,
        on_cancel: OnCancel,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let note = cx.new(|cx| {
            ComposerInput::new("Add a note…", cx)
                .with_single_line()
                .with_text_metrics(TEXT_BODY, 18.0)
        });
        let subscription = cx.subscribe_in(&note, window, |this, _, event, window, cx| {
            if matches!(
                event,
                ComposerInputEvent::Submitted | ComposerInputEvent::ModifiedSubmitted
            ) {
                this.finish_editing(window, cx);
            }
        });
        let size = image_size(&image.bytes).unwrap_or((1.0, 1.0));
        Self {
            name,
            image,
            size,
            doc: Annotations::default(),
            tool: Tool::Rect,
            color: MarkColor::Red,
            drag: None,
            editing: None,
            note,
            focus: cx.focus_handle(),
            frame: Rc::default(),
            scale: 1.0,
            error: None,
            on_done,
            on_cancel,
            _note_events: subscription,
        }
    }

    /// Image pixels per screen pixel.
    fn image_px(&self) -> f32 {
        1.0 / self.scale.max(0.0001)
    }

    fn fit(&self, frame: Bounds<Pixels>) -> (f32, (f32, f32)) {
        let (bw, bh) = (f32::from(frame.size.width), f32::from(frame.size.height));
        let scale = (bw / self.size.0).min(bh / self.size.1).clamp(0.0001, 1.0);
        let (w, h) = (self.size.0 * scale, self.size.1 * scale);
        (scale, ((bw - w) / 2.0, (bh - h) / 2.0))
    }

    /// Window position to image pixels.
    fn to_image(&self, position: gpui::Point<Pixels>) -> (f32, f32) {
        let frame = self.frame.get();
        let (scale, offset) = self.fit(frame);
        let x = (f32::from(position.x) - f32::from(frame.origin.x) - offset.0) / scale;
        let y = (f32::from(position.y) - f32::from(frame.origin.y) - offset.1) / scale;
        (x, y)
    }

    fn begin_editing(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(item) = self.doc.get(id) else {
            return;
        };
        let (text, placeholder) = if item.is_rect() {
            (item.text.clone(), "Add a note…")
        } else {
            (item.text.clone(), "Add text…")
        };
        self.doc.select(Some(id));
        self.editing = Some(id);
        self.note.update(cx, |input, cx| {
            input.set_placeholder(placeholder, cx);
            input.set_text(text, cx);
        });
        let focus = self.note.read(cx).focus_handle(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    /// Commit the popover's words to the mark it edits and close it.
    pub(crate) fn finish_editing(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self.editing.take() {
            let text = self.note.read(cx).text().to_string();
            self.doc.commit_text(id, &text);
        }
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        (self.on_cancel.clone())(window, cx);
    }

    fn done(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self.editing.take() {
            let text = self.note.read(cx).text().to_string();
            self.doc.commit_text(id, &text);
        }
        if self.doc.is_empty() {
            self.cancel(window, cx);
            return;
        }
        match flatten(&self.image.bytes, &self.doc, self.image_px()) {
            Ok(png) => {
                let name = annotated_name(&self.name);
                let notes = prompt_block(&name, &self.doc);
                (self.on_done.clone())(Annotated { name, png, notes }, window, cx);
            }
            Err(err) => {
                self.error = Some(format!("Couldn't save the annotations: {err}").into());
                cx.notify();
            }
        }
    }

    fn undo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.editing = None;
        self.doc.undo();
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn remove(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        if self.editing == Some(id) {
            self.editing = None;
        }
        self.doc.remove(id);
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn set_color(&mut self, color: MarkColor, cx: &mut Context<Self>) {
        self.color = color;
        // Recolor the mark whose note is open; otherwise the color is for
        // the next mark.
        if let Some(id) = self.editing {
            self.doc.recolor(id, color);
        }
        cx.notify();
    }

    /// Test and fixture entry: draw a box in image pixels as a drag would.
    pub fn drag_rect(
        &mut self,
        from: (f32, f32),
        to: (f32, f32),
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<u64> {
        let rect = ImageRect::from_drag(from, to, self.size);
        let id = self.doc.add_rect(rect, self.color)?;
        self.begin_editing(id, window, cx);
        Some(id)
    }

    /// Test and fixture entry: commit the open popover as Enter does.
    pub fn commit_note(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.finish_editing(window, cx);
    }

    /// Test and fixture entry: type into the open popover.
    pub fn type_note(&mut self, text: &str, cx: &mut Context<Self>) {
        self.note.update(cx, |input, cx| input.set_text(text, cx));
    }

    /// Test and fixture entry: place a text mark as a click would.
    pub fn place_text(&mut self, at: (f32, f32), window: &mut Window, cx: &mut Context<Self>) {
        let id = self
            .doc
            .add_text(at, TEXT_MARK_SIZE * self.image_px(), self.color);
        self.begin_editing(id, window, cx);
    }

    pub fn set_tool(&mut self, tool: Tool, cx: &mut Context<Self>) {
        self.tool = tool;
        cx.notify();
    }

    pub fn pick_color(&mut self, color: MarkColor, cx: &mut Context<Self>) {
        self.set_color(color, cx);
    }

    /// Fixture entry: run Done.
    pub fn press_done(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.done(window, cx);
    }

    fn on_image_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.stop_propagation();
        window.prevent_default();
        if self.editing.is_some() {
            self.finish_editing(window, cx);
        }
        let at = self.to_image(event.position);
        match self.tool {
            Tool::Rect => {
                self.drag = Some(Drag {
                    start: at,
                    current: at,
                });
            }
            Tool::Text => {
                let at = (at.0.clamp(0.0, self.size.0), at.1.clamp(0.0, self.size.1));
                self.place_text(at, window, cx);
            }
        }
        cx.notify();
    }

    fn on_move(&mut self, event: &MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.drag.is_none() || event.pressed_button != Some(MouseButton::Left) {
            return;
        }
        let at = self.to_image(event.position);
        if let Some(drag) = &mut self.drag {
            drag.current = at;
        }
        cx.notify();
    }

    fn on_up(&mut self, _: &MouseUpEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(drag) = self.drag.take() else {
            return;
        };
        let rect = ImageRect::from_drag(drag.start, drag.current, self.size);
        if let Some(id) = self.doc.add_rect(rect, self.color) {
            self.begin_editing(id, window, cx);
            return;
        }
        // A click: select the top box under it, or clear the selection.
        let (x, y) = drag.start;
        let hit = self
            .doc
            .items()
            .iter()
            .rev()
            .find_map(|item| match &item.shape {
                Shape::Rect(r) if x >= r.x && x <= r.right() && y >= r.y && y <= r.bottom() => {
                    Some(item.id)
                }
                _ => None,
            });
        match hit {
            Some(id) => self.begin_editing(id, window, cx),
            None => {
                self.doc.select(None);
                cx.notify();
            }
        }
    }

    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let key = event.keystroke.key.as_str();
        let note_focused = self.note.read(cx).focus_handle(cx).is_focused(window);
        match key {
            "escape" => {
                cx.stop_propagation();
                if self.editing.is_some() {
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
                self.undo(window, cx);
            }
            _ => {}
        }
    }
}

fn icon_button(
    id: impl Into<gpui::ElementId>,
    icon: &'static str,
    label: &'static str,
    active: bool,
    enabled: bool,
    theme: &Theme,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .size(px(HIT))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(BAR_RADIUS - PAD))
        .aria_label(label)
        .when(active, |el| el.bg(ink(0.12)))
        .when(enabled && !active, |el| {
            el.hover(|s| s.bg(ink(0.06))).cursor_pointer()
        })
        .when(!enabled, |el| el.opacity(0.4))
        .child(icons::icon(icon).size(px(16.0)).text_color(if active {
            theme.text
        } else {
            theme.text_muted
        }))
}

fn bar(theme: &Theme) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .h(px(HIT + 2.0 * PAD))
        .p(px(PAD))
        .gap(px(2.0))
        .rounded(px(BAR_RADIUS))
        .bg(crate::popover::surface_bg(theme))
        .border_1()
        .border_color(hairline(0.10))
        .when(!theme.is_frost(), |el| el.shadow_lg())
        .text_color(theme.text)
}

fn divider() -> gpui::Div {
    div().w(px(1.0)).h(px(16.0)).mx(px(4.0)).bg(hairline(0.12))
}

impl Render for AnnotateEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let viewport = window.viewport_size();
        let box_w = f32::from(viewport.width) * BOX_W;
        let box_h = f32::from(viewport.height) * BOX_H;
        let frame = self.frame.get();
        let frame = if frame.size.width > px(0.0) {
            frame
        } else {
            Bounds::new(
                gpui::point(px(0.0), px(0.0)),
                gpui::size(px(box_w), px(box_h)),
            )
        };
        let (scale, offset) = self.fit(frame);
        self.scale = scale;
        let image_w = self.size.0 * scale;
        let image_h = self.size.1 * scale;
        let m = SCREEN_METRICS;
        let selected = self.doc.selected();

        // Marks, in screen pixels relative to the image's top-left.
        let mut marks: Vec<AnyElement> = Vec::new();
        for item in self.doc.items() {
            if let Shape::Rect(r) = &item.shape {
                let color = rgb(item.color.rgb());
                marks.push(
                    div()
                        .absolute()
                        .left(px(r.x * scale))
                        .top(px(r.y * scale))
                        .w(px(r.w * scale))
                        .h(px(r.h * scale))
                        .border(px(m.stroke))
                        .border_color(color)
                        .rounded(px(m.box_radius))
                        .when(selected == Some(item.id), |el| el.bg(color.opacity(0.10)))
                        .into_any_element(),
                );
            }
        }
        if let Some(drag) = self.drag {
            let r = ImageRect::from_drag(drag.start, drag.current, self.size);
            marks.push(
                div()
                    .absolute()
                    .left(px(r.x * scale))
                    .top(px(r.y * scale))
                    .w(px(r.w * scale))
                    .h(px(r.h * scale))
                    .border(px(m.stroke))
                    .border_color(rgb(self.color.rgb()))
                    .rounded(px(m.box_radius))
                    .into_any_element(),
            );
        }
        for item in self.doc.items() {
            let id = item.id;
            match &item.shape {
                Shape::Rect(r) => {
                    let number = self.doc.number(id).unwrap_or(0);
                    let d = m.pin_diameter;
                    let cx_ = (r.x * scale).clamp(d / 2.0, (image_w - d / 2.0).max(d / 2.0));
                    let cy_ = (r.y * scale).clamp(d / 2.0, (image_h - d / 2.0).max(d / 2.0));
                    marks.push(
                        div()
                            .id(("annotate-pin", id))
                            .absolute()
                            .left(px(cx_ - d / 2.0))
                            .top(px(cy_ - d / 2.0))
                            .size(px(d))
                            .rounded_full()
                            .bg(rgb(item.color.rgb()))
                            .when(selected == Some(id), |el| {
                                el.border_2().border_color(rgb(item.color.on_rgb()))
                            })
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(ui_rems(m.pin_text))
                            .line_height(ui_rems(m.pin_text))
                            .font_weight(FontWeight::MEDIUM)
                            .font_features(tabular())
                            .text_color(rgb(item.color.on_rgb()))
                            .cursor_pointer()
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(move |this, _, window, cx| {
                                    cx.stop_propagation();
                                    this.begin_editing(id, window, cx);
                                }),
                            )
                            .child(number.to_string())
                            .into_any_element(),
                    );
                }
                Shape::Text { x, y, size } => {
                    if self.editing == Some(id) || item.text.is_empty() {
                        continue;
                    }
                    let size = size * scale;
                    marks.push(
                        div()
                            .id(("annotate-text", id))
                            .absolute()
                            .left(px(x * scale))
                            .top(px(y * scale))
                            .px(px(m.chip_pad_x))
                            .py(px(m.chip_pad_y))
                            .rounded(px(m.chip_radius))
                            .bg(rgb(item.color.rgb()))
                            .when(selected == Some(id), |el| {
                                el.border_1().border_color(rgb(item.color.on_rgb()))
                            })
                            .text_size(ui_rems(size))
                            .line_height(ui_rems(size * 1.4))
                            .font_weight(FontWeight::MEDIUM)
                            .whitespace_nowrap()
                            .text_color(rgb(item.color.on_rgb()))
                            .cursor_pointer()
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(move |this, _, window, cx| {
                                    cx.stop_propagation();
                                    this.begin_editing(id, window, cx);
                                }),
                            )
                            .child(item.text.clone())
                            .into_any_element(),
                    );
                }
            }
        }

        // The note popover: below its box (above when the box sits low).
        if let Some(id) = self.editing
            && let Some(item) = self.doc.get(id)
        {
            let height = HIT + 2.0 * POPOVER_PAD;
            let (left, top) = match &item.shape {
                Shape::Rect(r) => {
                    let below = r.bottom() * scale + POPOVER_GAP;
                    let viewport_bottom =
                        f32::from(viewport.height) - f32::from(frame.origin.y) - offset.1;
                    let top = if below + height > viewport_bottom - 64.0 {
                        r.y * scale - POPOVER_GAP - height
                    } else {
                        below
                    };
                    (r.x * scale, top)
                }
                Shape::Text { x, y, .. } => (x * scale, y * scale),
            };
            let left = left.min((image_w - POPOVER_WIDTH).max(0.0)).max(0.0);
            marks.push(
                div()
                    .id("annotate-note")
                    .absolute()
                    .left(px(left))
                    .top(px(top))
                    .w(px(POPOVER_WIDTH))
                    .h(px(height))
                    .p(px(POPOVER_PAD))
                    .rounded(px(POPOVER_RADIUS))
                    .bg(crate::popover::surface_bg(&theme))
                    .border_1()
                    .border_color(hairline(0.10))
                    .when(!theme.is_frost(), |el| el.shadow_lg())
                    .flex()
                    .items_center()
                    .gap(px(2.0))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .pl(px(8.0))
                            .child(self.note.clone()),
                    )
                    .child(
                        div()
                            .id("annotate-note-delete")
                            .size(px(HIT))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(POPOVER_RADIUS - POPOVER_PAD))
                            .aria_label("Delete annotation")
                            .cursor_pointer()
                            .hover(|s| s.bg(ink(0.06)))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.remove(id, window, cx);
                            }))
                            .child(
                                icons::icon(icons::CLOSE)
                                    .size(px(16.0))
                                    .text_color(theme.text_muted),
                            ),
                    )
                    .into_any_element(),
            );
        }

        let measure = self.frame.clone();
        let owner = cx.entity_id();
        let image_layer = div()
            .id("annotate-image")
            .absolute()
            .left(px(offset.0))
            .top(px(offset.1))
            .w(px(image_w))
            .h(px(image_h))
            .cursor(match self.tool {
                Tool::Rect => CursorStyle::Crosshair,
                Tool::Text => CursorStyle::IBeam,
            })
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_image_down))
            .child(
                gpui::img(self.image.clone())
                    .absolute()
                    .inset_0()
                    .size_full()
                    .object_fit(gpui::ObjectFit::Contain),
            )
            .children(marks);

        let tool_button =
            |tool: Tool, icon: &'static str, label: &'static str, cx: &mut Context<Self>| {
                icon_button(
                    match tool {
                        Tool::Text => "annotate-tool-text",
                        Tool::Rect => "annotate-tool-rect",
                    },
                    icon,
                    label,
                    self.tool == tool,
                    true,
                    &theme,
                )
                .on_click(cx.listener(move |this, _, _, cx| this.set_tool(tool, cx)))
            };
        let mut tools = bar(&theme)
            .child(tool_button(Tool::Text, icons::ANNOTATE_TEXT, "Text", cx))
            .child(tool_button(
                Tool::Rect,
                icons::ANNOTATE_RECT,
                "Rectangle",
                cx,
            ))
            .child(divider());
        for color in MarkColor::ALL {
            let active = self.color == color;
            tools = tools.child(
                div()
                    .id(("annotate-color", color as usize))
                    .size(px(HIT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_full()
                    .aria_label(color.label())
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| this.set_color(color, cx)))
                    .child(
                        div()
                            .size(px(20.0))
                            .rounded_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .border_2()
                            .border_color(if active {
                                theme.text
                            } else {
                                gpui::transparent_black()
                            })
                            .child(div().size(px(12.0)).rounded_full().bg(rgb(color.rgb()))),
                    ),
            );
        }
        let can_undo = self.doc.can_undo();
        tools = tools.child(divider()).child(
            icon_button(
                "annotate-undo",
                icons::UNDO,
                "Undo",
                false,
                can_undo,
                &theme,
            )
            .when(can_undo, |el| {
                el.on_click(cx.listener(|this, _, window, cx| this.undo(window, cx)))
            }),
        );
        let has_marks = !self.doc.is_empty();
        let actions = bar(&theme)
            .gap(px(PAD))
            .child(
                div()
                    .id("annotate-cancel")
                    .h(px(HIT))
                    .px(px(12.0))
                    .flex()
                    .items_center()
                    .rounded(px(BAR_RADIUS - PAD))
                    .text_size(ui_rems(TEXT_BODY))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.text_muted)
                    .cursor_pointer()
                    .hover(|s| s.bg(ink(0.06)))
                    .on_click(cx.listener(|this, _, window, cx| this.cancel(window, cx)))
                    .child("Cancel"),
            )
            .child(
                div()
                    .id("annotate-done")
                    .h(px(HIT))
                    .px(px(14.0))
                    .flex()
                    .items_center()
                    .rounded(px(BAR_RADIUS - PAD))
                    .bg(theme.solid)
                    .text_size(ui_rems(TEXT_BODY))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.on_solid)
                    .when(has_marks, |el| {
                        el.cursor_pointer().hover(|s| s.opacity(0.9))
                    })
                    .when(!has_marks, |el| el.opacity(0.5))
                    .on_click(cx.listener(|this, _, window, cx| this.done(window, cx)))
                    .child("Done"),
            );
        let toolbar = div()
            .absolute()
            .bottom(px(16.0))
            .left_0()
            .right_0()
            .flex()
            .flex_col()
            .items_center()
            .gap(px(8.0))
            .when_some(self.error.clone(), |el, err| {
                el.child(
                    div()
                        .px(px(12.0))
                        .py(px(6.0))
                        .rounded(px(Theme::CONTROL_RADIUS))
                        .bg(crate::popover::surface_bg(&theme))
                        .text_size(ui_rems(TEXT_CAPTION))
                        .text_color(theme.text)
                        .child(err),
                )
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.0))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(tools)
                    .child(actions),
            );
        let toolbar: AnyElement = if motion::reduced_motion(cx) {
            toolbar.into_any_element()
        } else {
            toolbar
                .with_animation("annotate-enter", ENTER.animation(), |el, t| {
                    el.opacity(t).mb(px((1.0 - t) * -8.0))
                })
                .into_any_element()
        };

        div()
            .id("annotate-editor")
            .occlude()
            .track_focus(&self.focus)
            .key_context("AnnotateEditor")
            .w(viewport.width)
            .h(viewport.height)
            .relative()
            .bg(crate::popover::scrim_alpha(0.7))
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap(px(CAPTION_GAP))
            .on_key_down(cx.listener(Self::on_key))
            .on_mouse_move(cx.listener(Self::on_move))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_up))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    if this.editing.is_some() {
                        this.finish_editing(window, cx);
                    }
                }),
            )
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .w(px(box_w))
                    .h(px(box_h))
                    .relative()
                    .child(image_layer)
                    .child(
                        gpui::canvas(
                            move |bounds, window, cx| {
                                if measure.get() != bounds {
                                    measure.set(bounds);
                                    window.defer(cx, move |_, cx| cx.notify(owner));
                                }
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .inset_0(),
                    ),
            )
            // Keeps the lightbox's caption line so the image does not shift.
            .child(
                div()
                    .text_size(ui_rems(TEXT_CAPTION))
                    .text_color(gpui::transparent_black())
                    .child(self.name.clone()),
            )
            .child(toolbar)
    }
}
