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

#[cfg(target_os = "macos")]
mod desktop;

/// Two distinct ways to describe an image: draw into it, or pin a comment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EditorMode {
    #[default]
    Markup,
    Comment,
}

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
#[cfg(not(target_os = "macos"))]
const BOX_W: f32 = 0.9;
#[cfg(not(target_os = "macos"))]
const BOX_H: f32 = 0.85;
const CAPTION_GAP: f32 = 12.0;

pub(crate) fn tabular() -> FontFeatures {
    FontFeatures(Arc::new(vec![("tnum".into(), 1)]))
}

fn rgb(value: u32) -> Hsla {
    gpui::rgb(value).into()
}

fn editor_surface(theme: &Theme) -> Hsla {
    if cfg!(target_os = "macos") {
        theme.surface_overlay.alpha(1.0)
    } else {
        crate::popover::surface_bg(theme)
    }
}

fn editor_border(theme: &Theme) -> Hsla {
    if cfg!(target_os = "macos") {
        theme.border
    } else {
        hairline(0.10)
    }
}

/// Clamp the editor card in window space, then return image-relative bounds.
/// A small image may be narrower than the card; its parent must not be used as
/// the clipping boundary for the input.
#[cfg(target_os = "macos")]
pub(super) fn note_popover_bounds(
    preferred: (f32, f32),
    image_origin: gpui::Point<Pixels>,
    frame: Bounds<Pixels>,
    viewport: gpui::Size<Pixels>,
    gutter: Pixels,
) -> Bounds<Pixels> {
    let width = px(POPOVER_WIDTH).min((viewport.width - gutter * 2.0).max(px(1.0)));
    let height = px(HIT + 2.0 * POPOVER_PAD);
    let left = (image_origin.x + px(preferred.0))
        .clamp(gutter, (viewport.width - gutter - width).max(gutter));
    let top =
        (image_origin.y + px(preferred.1)).clamp(gutter, (frame.bottom() - height).max(gutter));
    Bounds::new(
        gpui::point(left - image_origin.x, top - image_origin.y),
        gpui::size(width, height),
    )
}

/// Prefer the side of a point pin, then move above/below when a narrow window
/// forces the field over its anchor. The pin remains visible while typing.
#[cfg(target_os = "macos")]
pub(super) fn comment_popover_bounds(
    pin: (f32, f32),
    diameter: f32,
    image_origin: gpui::Point<Pixels>,
    frame: Bounds<Pixels>,
    viewport: gpui::Size<Pixels>,
    gutter: Pixels,
) -> Bounds<Pixels> {
    let height = HIT + 2.0 * POPOVER_PAD;
    let clearance = diameter / 2.0 + POPOVER_GAP;
    let mut card = note_popover_bounds(
        (pin.0 + clearance, pin.1 - height / 2.0),
        image_origin,
        frame,
        viewport,
        gutter,
    );
    let left = f32::from(card.origin.x);
    let right = left + f32::from(card.size.width);
    if left < pin.0 + clearance && right > pin.0 - clearance {
        let above = image_origin.y + px(pin.1 - clearance - height);
        let below = image_origin.y + px(pin.1 + clearance);
        let top = if above >= gutter { above } else { below };
        card.origin.y =
            top.clamp(gutter, (frame.bottom() - px(height)).max(gutter)) - image_origin.y;
    }
    card
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
        #[cfg(target_os = "macos")]
        {
            self.open_mode(
                name,
                image,
                None,
                EditorMode::Markup,
                owner,
                return_focus,
                window,
                cx,
            );
            return;
        }
        #[cfg(not(target_os = "macos"))]
        self.open_legacy(name, image, owner, return_focus, window, cx);
    }

    #[cfg(target_os = "macos")]
    pub fn open_mode(
        &self,
        name: SharedString,
        image: Arc<Image>,
        editable: Option<crate::annotate::EditableAnnotation>,
        mode: EditorMode,
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
        let editor = cx.new(|cx| {
            let (name, image) = editable
                .as_ref()
                .map(|state| (state.original_name.clone().into(), state.original.clone()))
                .unwrap_or((name, image));
            let mut editor = AnnotateEditor::new(name, image, finish, on_cancel, window, cx);
            if let Some(state) = editable {
                editor.doc = state.document;
                editor.had_editable = true;
            }
            editor.mode = mode;
            editor.tool = if mode == EditorMode::Comment {
                Tool::Comment
            } else {
                Tool::Pen
            };
            editor
        });
        let focus = editor.read(cx).focus.clone();
        *self.editor.borrow_mut() = Some(editor);
        window.focus(&focus, cx);
        cx.notify(owner);
    }

    #[cfg(not(target_os = "macos"))]
    fn open_legacy(
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
    #[cfg(target_os = "macos")]
    mode: EditorMode,
    #[cfg(target_os = "macos")]
    had_editable: bool,
    #[cfg(target_os = "macos")]
    desktop: desktop::DesktopTools,
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
            #[cfg(target_os = "macos")]
            if matches!(event, ComposerInputEvent::Edited) {
                cx.notify();
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
            #[cfg(target_os = "macos")]
            mode: EditorMode::Markup,
            #[cfg(target_os = "macos")]
            had_editable: false,
            #[cfg(target_os = "macos")]
            desktop: desktop::DesktopTools::new(cx),
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
        #[cfg(target_os = "macos")]
        {
            if self.editing == Some(id) {
                window.focus(&self.note.read(cx).focus_handle(cx), cx);
                return;
            }
            if self.editing.is_some() {
                self.finish_editing(window, cx);
            }
        }
        let Some(item) = self.doc.get(id) else {
            return;
        };
        #[cfg(target_os = "macos")]
        {
            self.mode = if item.is_comment() {
                EditorMode::Comment
            } else {
                EditorMode::Markup
            };
            self.tool = if item.is_comment() {
                Tool::Comment
            } else {
                Tool::Text
            };
            self.desktop.width_hovered = false;
            self.desktop.color_open = false;
        }
        let (text, placeholder) = if item.is_comment() {
            (
                item.text.clone(),
                if cfg!(target_os = "macos") {
                    "Add a comment…"
                } else {
                    "Add a note…"
                },
            )
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
        let can_save_empty = cfg!(target_os = "macos") && {
            #[cfg(target_os = "macos")]
            {
                self.had_editable
            }
            #[cfg(not(target_os = "macos"))]
            {
                false
            }
        };
        if self.doc.is_empty() && !can_save_empty {
            self.cancel(window, cx);
            return;
        }
        match flatten(&self.image.bytes, &self.doc, self.image_px()) {
            Ok(png) => {
                let name = annotated_name(&self.name);
                let notes = prompt_block(&name, &self.doc);
                (self.on_done.clone())(
                    Annotated {
                        name,
                        png,
                        notes,
                        #[cfg(target_os = "macos")]
                        editable: Some(crate::annotate::EditableAnnotation {
                            original_name: self.name.to_string(),
                            original: self.image.clone(),
                            document: self.doc.clone(),
                        }),
                    },
                    window,
                    cx,
                );
            }
            Err(err) => {
                self.error = Some(format!("Couldn't save the annotations: {err}").into());
                cx.notify();
            }
        }
    }

    fn undo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        #[cfg(target_os = "macos")]
        {
            self.finish_gesture();
            let cancelled_empty_note = self.editing.is_some_and(|id| {
                self.doc.get(id).is_some_and(|item| {
                    !item.is_rect()
                        && item.text.is_empty()
                        && self.note.read(cx).text().trim().is_empty()
                })
            });
            if self.editing.is_some() {
                self.finish_editing(window, cx);
            }
            if cancelled_empty_note {
                return;
            }
        }
        self.editing = None;
        self.doc.undo();
        window.focus(&self.focus, cx);
        cx.notify();
    }

    #[cfg(target_os = "macos")]
    fn redo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.finish_gesture();
        if self.editing.is_some() {
            self.finish_editing(window, cx);
        }
        self.editing = None;
        self.doc.redo();
        window.focus(&self.focus, cx);
        cx.notify();
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_document(&self) -> Annotations {
        self.doc.clone()
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
        #[cfg(target_os = "macos")]
        {
            self.mode = if tool == Tool::Comment {
                EditorMode::Comment
            } else {
                EditorMode::Markup
            };
            self.desktop.width_hovered = false;
            self.desktop.color_open = false;
        }
        cx.notify();
    }

    pub fn pick_color(&mut self, color: MarkColor, cx: &mut Context<Self>) {
        self.set_color(color, cx);
    }

    /// Fixture entry: run Done.
    pub fn press_done(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.done(window, cx);
    }

    #[cfg(not(target_os = "macos"))]
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
            _ => {}
        }
        cx.notify();
    }

    #[cfg(not(target_os = "macos"))]
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

    #[cfg(not(target_os = "macos"))]
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

    #[cfg(not(target_os = "macos"))]
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
        .bg(editor_surface(theme))
        .border_1()
        .border_color(editor_border(theme))
        .when(cfg!(target_os = "macos") || !theme.is_frost(), |el| {
            el.shadow_lg()
        })
        .text_color(theme.text)
}

fn divider() -> gpui::Div {
    div().w(px(1.0)).h(px(16.0)).mx(px(4.0)).bg(hairline(0.12))
}

impl Render for AnnotateEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let viewport = window.viewport_size();
        #[cfg(target_os = "macos")]
        let layout = crate::attachments::image_preview_layout(viewport);
        #[cfg(target_os = "macos")]
        let (box_w, box_h, frame) = (
            f32::from(layout.frame.size.width),
            f32::from(layout.frame.size.height),
            layout.frame,
        );
        #[cfg(not(target_os = "macos"))]
        let box_w = f32::from(viewport.width) * BOX_W;
        #[cfg(not(target_os = "macos"))]
        let box_h = f32::from(viewport.height) * BOX_H;
        #[cfg(not(target_os = "macos"))]
        let frame = self.frame.get();
        #[cfg(not(target_os = "macos"))]
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
        #[cfg(target_os = "macos")]
        marks.extend(self.desktop_marks(scale));
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
            #[cfg(target_os = "macos")]
            let stroke = self.width_value();
            #[cfg(not(target_os = "macos"))]
            let stroke = m.stroke;
            marks.push(
                div()
                    .absolute()
                    .left(px(r.x * scale))
                    .top(px(r.y * scale))
                    .w(px(r.w * scale))
                    .h(px(r.h * scale))
                    .border(px(stroke))
                    .border_color(rgb(self.color.rgb()))
                    .rounded(px(m.box_radius))
                    .into_any_element(),
            );
        }
        for item in self.doc.items() {
            let id = item.id;
            match &item.shape {
                Shape::Rect(ImageRect { x, y, .. }) | Shape::Comment { x, y } => {
                    let number = self.doc.number(id).unwrap_or(0);
                    let d = m.pin_diameter;
                    let cx_ = (x * scale).clamp(d / 2.0, (image_w - d / 2.0).max(d / 2.0));
                    let cy_ = (y * scale).clamp(d / 2.0, (image_h - d / 2.0).max(d / 2.0));
                    marks.push(
                        div()
                            .id(("annotate-pin", id))
                            .debug_selector(move || format!("annotate-comment-{id}"))
                            .role(gpui::Role::Button)
                            .aria_label(format!("Edit comment {number}"))
                            .tab_index(0)
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
                            .when(cfg!(target_os = "macos"), |el| {
                                el.focus_visible(|style| {
                                    style.border_2().border_color(gpui::white())
                                })
                                .on_key_down(cx.listener(
                                    move |this, event: &KeyDownEvent, window, cx| {
                                        if matches!(event.keystroke.key.as_str(), "enter" | "space")
                                        {
                                            cx.stop_propagation();
                                            this.begin_editing(id, window, cx);
                                        }
                                    },
                                ))
                            })
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
                                cx.listener(move |this, event, window, cx| {
                                    cx.stop_propagation();
                                    #[cfg(target_os = "macos")]
                                    if this.tool == Tool::Eraser {
                                        this.on_image_down(event, window, cx);
                                        return;
                                    }
                                    this.begin_editing(id, window, cx);
                                }),
                            )
                            .child(item.text.clone())
                            .into_any_element(),
                    );
                }
                Shape::Stroke { .. } | Shape::MarkupRect { .. } => {}
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
                    #[cfg(target_os = "macos")]
                    let viewport_bottom = box_h - offset.1;
                    #[cfg(not(target_os = "macos"))]
                    let viewport_bottom =
                        f32::from(viewport.height) - f32::from(frame.origin.y) - offset.1 - 64.0;
                    let top = if below + height > viewport_bottom {
                        r.y * scale - POPOVER_GAP - height
                    } else {
                        below
                    };
                    (r.x * scale, top)
                }
                Shape::Text { x, y, .. } => (x * scale, y * scale),
                Shape::Comment { x, y } => (x * scale + 22.0, y * scale - 20.0),
                Shape::Stroke { .. } | Shape::MarkupRect { .. } => (0.0, 0.0),
            };
            #[cfg(not(target_os = "macos"))]
            let left = left.min((image_w - POPOVER_WIDTH).max(0.0)).max(0.0);
            #[cfg(not(target_os = "macos"))]
            let width = POPOVER_WIDTH;
            #[cfg(target_os = "macos")]
            let (left, top, width) = {
                let image_origin = frame.origin + gpui::point(px(offset.0), px(offset.1));
                let bounds = if let Shape::Comment { x, y } = item.shape {
                    let radius = m.pin_diameter / 2.0;
                    let pin = (
                        (x * scale).clamp(radius, (image_w - radius).max(radius)),
                        (y * scale).clamp(radius, (image_h - radius).max(radius)),
                    );
                    comment_popover_bounds(
                        pin,
                        m.pin_diameter,
                        image_origin,
                        frame,
                        viewport,
                        layout.gutter,
                    )
                } else {
                    note_popover_bounds((left, top), image_origin, frame, viewport, layout.gutter)
                };
                (
                    f32::from(bounds.origin.x),
                    f32::from(bounds.origin.y),
                    f32::from(bounds.size.width),
                )
            };
            marks.push(
                div()
                    .id("annotate-note")
                    .debug_selector(|| "annotate-note".into())
                    .absolute()
                    .left(px(left))
                    .top(px(top))
                    .w(px(width))
                    .h(px(height))
                    .p(px(POPOVER_PAD))
                    .rounded(px(POPOVER_RADIUS))
                    .bg(editor_surface(&theme))
                    .border_1()
                    .border_color(editor_border(&theme))
                    .when(cfg!(target_os = "macos") || !theme.is_frost(), |el| {
                        el.shadow_lg()
                    })
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
                    .when(cfg!(target_os = "macos") && item.is_comment(), |el| {
                        el.child(
                            icon_button(
                                "annotate-note-save",
                                icons::CHECK,
                                "Save comment",
                                false,
                                true,
                                &theme,
                            )
                            .debug_selector(|| "annotate-note-save".into())
                            .role(gpui::Role::Button)
                            .tab_index(0)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.finish_editing(window, cx)),
                            )
                            .on_key_down(cx.listener(
                                |this, event: &KeyDownEvent, window, cx| {
                                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                        cx.stop_propagation();
                                        this.finish_editing(window, cx);
                                    }
                                },
                            )),
                        )
                    })
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
                            .when(cfg!(target_os = "macos"), |el| {
                                el.role(gpui::Role::Button)
                                    .tab_index(0)
                                    .focus_visible(|style| style.bg(theme.element_hover))
                                    .on_key_down(cx.listener(
                                        move |this, event: &KeyDownEvent, window, cx| {
                                            if matches!(
                                                event.keystroke.key.as_str(),
                                                "enter" | "space"
                                            ) {
                                                cx.stop_propagation();
                                                this.remove(id, window, cx);
                                            }
                                        },
                                    ))
                            })
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
            .debug_selector(|| "annotate-image".into())
            .absolute()
            .left(px(offset.0))
            .top(px(offset.1))
            .w(px(image_w))
            .h(px(image_h))
            .cursor(match self.tool {
                Tool::Rect => CursorStyle::Crosshair,
                Tool::Text => CursorStyle::IBeam,
                _ => CursorStyle::Crosshair,
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

        #[cfg(not(target_os = "macos"))]
        let toolbar = {
            let tool_button =
                |tool: Tool, icon: &'static str, label: &'static str, cx: &mut Context<Self>| {
                    icon_button(
                        match tool {
                            Tool::Text => "annotate-tool-text",
                            Tool::Rect => "annotate-tool-rect",
                            _ => "annotate-legacy-tool",
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
            let tools = tools
                .id("annotate-tools")
                .debug_selector(|| "annotate-tools".into());
            let has_marks = !self.doc.is_empty();
            let actions = bar(&theme)
                .id("annotate-actions")
                .debug_selector(|| "annotate-actions".into())
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
            let controls = div()
                .flex()
                .items_center()
                .gap(px(8.0))
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(tools)
                .child(actions);
            #[cfg(target_os = "macos")]
            let controls = controls.when(layout.compact, |el| el.flex_col());
            let inline_error = if cfg!(target_os = "macos") {
                None
            } else {
                self.error.clone()
            };
            let toolbar = div()
                .absolute()
                .when(!cfg!(target_os = "macos"), |el| el.bottom(px(16.0)))
                .left_0()
                .right_0()
                .flex()
                .flex_col()
                .items_center()
                .gap(px(8.0))
                .when_some(inline_error, |el, err| {
                    el.child(
                        div()
                            .px(px(12.0))
                            .py(px(6.0))
                            .rounded(px(Theme::CONTROL_RADIUS))
                            .bg(editor_surface(&theme))
                            .text_size(ui_rems(TEXT_CAPTION))
                            .text_color(theme.text)
                            .child(err),
                    )
                });
            #[cfg(target_os = "macos")]
            let toolbar = toolbar.top(layout.footer_top).px(layout.gutter).child(
                div()
                    .id("annotate-filename")
                    .debug_selector(|| "annotate-filename".into())
                    .max_w(viewport.width - layout.gutter * 2.0)
                    .h(px(18.0))
                    .px(px(8.0))
                    .rounded(px(4.0))
                    .bg(editor_surface(&theme))
                    .truncate()
                    .text_size(ui_rems(TEXT_CAPTION))
                    .line_height(px(18.0))
                    .text_color(theme.text)
                    .child(self.name.clone()),
            );
            let toolbar = toolbar.child(controls);
            let toolbar: AnyElement = if motion::reduced_motion(cx) {
                toolbar.into_any_element()
            } else {
                toolbar
                    .with_animation("annotate-enter", ENTER.animation(), |el, t| {
                        el.opacity(t).mb(px((1.0 - t) * -8.0))
                    })
                    .into_any_element()
            };
            toolbar
        };
        #[cfg(target_os = "macos")]
        let toolbar = self.desktop_toolbar(viewport, &theme, window, cx);
        #[cfg(target_os = "macos")]
        let error_banner = self.error.clone().map(|error| {
            div()
                .absolute()
                .top((layout.footer_top - px(44.0)).max(layout.gutter))
                .max_w(viewport.width - layout.gutter * 2.0)
                .h(px(32.0))
                .px(px(12.0))
                .rounded(px(Theme::CONTROL_RADIUS))
                .bg(editor_surface(&theme))
                .border_1()
                .border_color(editor_border(&theme))
                .shadow_lg()
                .truncate()
                .text_size(ui_rems(TEXT_CAPTION))
                .line_height(px(30.0))
                .text_color(theme.text)
                .child(error)
                .into_any_element()
        });
        #[cfg(not(target_os = "macos"))]
        let error_banner: Option<AnyElement> = None;

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
                    #[cfg(target_os = "macos")]
                    {
                        this.desktop.width_hovered = false;
                        this.desktop.color_open = false;
                        this.desktop.width_dragging = false;
                        cx.notify();
                    }
                    if this.editing.is_some() {
                        this.finish_editing(window, cx);
                    }
                }),
            )
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .id("annotate-frame")
                    .debug_selector(|| "annotate-frame".into())
                    .w(px(box_w))
                    .h(px(box_h))
                    .relative()
                    .when(cfg!(target_os = "macos"), |el| {
                        el.absolute().left(frame.origin.x).top(frame.origin.y)
                    })
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
            .when(!cfg!(target_os = "macos"), |el| {
                // Keeps the legacy lightbox's caption line so the image does not shift.
                el.child(
                    div()
                        .text_size(ui_rems(TEXT_CAPTION))
                        .text_color(gpui::transparent_black())
                        .child(self.name.clone()),
                )
            })
            .children(error_banner)
            .child(toolbar)
            .when(cfg!(target_os = "macos"), |el| {
                #[cfg(target_os = "macos")]
                {
                    el.children(self.desktop_width_control(viewport, &theme, window, cx))
                        .children(self.desktop_popover(viewport, &theme, window, cx))
                }
                #[cfg(not(target_os = "macos"))]
                {
                    el
                }
            })
    }
}
