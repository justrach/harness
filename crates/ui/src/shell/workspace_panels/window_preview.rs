//! A desktop drag representation. It never owns tab state or receives input.

use crate::{icons, motion, theme::Theme, typography};
use gpui::{
    App, AppContext, Bounds, Context, IntoElement, ObjectFit, Pixels, Point, Render, RenderImage,
    SharedString, StyledImage, Window, WindowBackgroundAppearance, WindowBounds, WindowHandle,
    WindowKind, WindowOptions, div, img, point, prelude::*, px, size,
};
use std::{cell::Cell, rc::Rc, sync::Arc, time::Instant};

const PADDING: f32 = 12.0;
const PREVIEW_WIDTH: f32 = 352.0;
const HEADER_HEIGHT: f32 = 32.0;
const CONTENT_HEIGHT: f32 = 208.0;
const MORPH: motion::MotionSpec = motion::MotionSpec::new(140, motion::EASE_OUT_QUINT);
const HANDOFF: motion::MotionSpec = motion::MotionSpec::new(200, motion::EASE_OUT_QUINT);

#[derive(Clone, Copy)]
struct GrabAnchor {
    x: f32,
    y: f32,
}

fn grab_anchor(grab: Point<Pixels>, tab_width: f32) -> (GrabAnchor, f32) {
    let actual_width = if tab_width.is_finite() {
        tab_width.max(1.0)
    } else {
        220.0
    };
    let compact_width = actual_width.clamp(72.0, PREVIEW_WIDTH);
    let x = f32::from(grab.x) * compact_width / actual_width;
    let y = f32::from(grab.y);
    (
        GrabAnchor {
            x: if x.is_finite() {
                x.clamp(0.0, compact_width)
            } else {
                compact_width * 0.5
            },
            y: if y.is_finite() {
                y.clamp(0.0, HEADER_HEIGHT)
            } else {
                HEADER_HEIGHT * 0.5
            },
        },
        compact_width,
    )
}

#[derive(Clone, Copy)]
struct CardFrame {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

impl CardFrame {
    fn interpolate(self, to: Self, t: f32) -> Self {
        Self {
            x: self.x + (to.x - self.x) * t,
            y: self.y + (to.y - self.y) * t,
            width: self.width + (to.width - self.width) * t,
            height: self.height + (to.height - self.height) * t,
        }
    }
}

struct Handoff {
    started: Instant,
    from: CardFrame,
    to: CardFrame,
}

struct PreviewMorph {
    from: f32,
    to: f32,
    started: Instant,
}

impl PreviewMorph {
    fn opening(now: Instant, reduced: bool) -> Self {
        Self {
            from: if reduced { 1.0 } else { 0.0 },
            to: 1.0,
            started: now,
        }
    }

    fn value(&self, now: Instant, reduced: bool) -> f32 {
        self.from + (self.to - self.from) * animation_progress(MORPH, self.started, now, reduced)
    }

    fn animating(&self, now: Instant, reduced: bool) -> bool {
        !reduced
            && self.from != self.to
            && animation_progress(MORPH, self.started, now, false) < 1.0
    }

    fn retarget(&mut self, expanded: bool, now: Instant, reduced: bool) -> bool {
        let target = if expanded { 1.0 } else { 0.0 };
        if self.to == target && (!reduced || self.from == target) {
            return false;
        }
        self.from = if reduced {
            target
        } else {
            self.value(now, false)
        };
        self.to = target;
        self.started = now;
        true
    }
}

pub(super) struct WindowPreview {
    handle: WindowHandle<PreviewView>,
    anchor: GrabAnchor,
    alive: Rc<Cell<bool>>,
    #[cfg(all(target_os = "macos", not(test)))]
    native: native::PreviewNative,
}

impl WindowPreview {
    #[cfg(feature = "appshots-fixture")]
    pub(super) fn fixture_handle(&self) -> gpui::AnyWindowHandle {
        self.handle.into()
    }

    #[cfg(feature = "appshots-fixture")]
    pub(super) fn fixture_status(&self, cx: &App) -> serde_json::Value {
        self.handle
            .read_with(cx, |view, _| {
                let frame = view.frame(Instant::now());
                serde_json::json!({
                    "window": self.fixture_handle().window_id().as_u64(),
                    "anchor": [self.anchor.x, self.anchor.y],
                    "compactWidth": view.compact_width,
                    "expanded": view.morph.to == 1.0,
                    "morph": view.morph.value(Instant::now(), view.reduced),
                    "card": [frame.x, frame.y, frame.width, frame.height],
                    "hasImage": view.image.is_some(),
                    "reduced": view.reduced
                })
            })
            .unwrap_or(serde_json::Value::Null)
    }

    /// Unsupported platforms return None without creating a stray app window.
    pub(super) fn open(
        source: &Window,
        pointer: Point<Pixels>,
        grab: Point<Pixels>,
        tab_width: f32,
        title: SharedString,
        icon: &'static str,
        image: Option<Arc<RenderImage>>,
        cx: &mut App,
    ) -> Option<Self> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let screen_pointer = native::screen_pointer(source, pointer)?;
            let (anchor, compact_width) = grab_anchor(grab, tab_width);
            let theme = Theme::of(cx).clone();
            let reduced = motion::reduced_motion(cx);
            let font = typography::effective_family_name(cx);
            let alive = Rc::new(Cell::new(true));
            let view_alive = alive.clone();
            let handle = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            source.bounds().origin,
                            size(
                                px(PREVIEW_WIDTH + PADDING * 2.0),
                                px(HEADER_HEIGHT + CONTENT_HEIGHT + PADDING * 2.0),
                            ),
                        ))),
                        titlebar: None,
                        kind: WindowKind::PopUp,
                        focus: false,
                        show: false,
                        is_movable: false,
                        is_resizable: false,
                        is_minimizable: false,
                        window_background: WindowBackgroundAppearance::Transparent,
                        ..Default::default()
                    },
                    move |window, cx| {
                        window.set_rem_size(px(typography::font_size(cx).pixels()));
                        cx.new(|_| PreviewView {
                            title,
                            icon,
                            image,
                            theme,
                            font,
                            reduced,
                            morph: PreviewMorph::opening(Instant::now(), reduced),
                            image_arrived: Instant::now(),
                            compact_width,
                            handoff: None,
                            close_scheduled: false,
                            alive: view_alive,
                        })
                    },
                )
                .ok()?;
            let configured = handle
                .update(cx, |_, window, cx| {
                    native::PreviewNative::configure(
                        window,
                        screen_pointer,
                        anchor,
                        alive.clone(),
                        cx,
                    )
                })
                .ok()
                .flatten();
            let Some(native) = configured else {
                alive.set(false);
                let _ = handle.update(cx, |_, window, _| window.remove_window());
                return None;
            };
            Some(Self {
                handle,
                anchor,
                alive,
                native,
            })
        }
        #[cfg(any(not(target_os = "macos"), test))]
        {
            let _ = (source, pointer, grab, tab_width, title, icon, image, cx);
            None
        }
    }

    /// Pointer movement coalesces to the latest position outside GPUI's borrow.
    /// Animation only changes the representation inside that frame.
    pub(super) fn update(
        &self,
        source: &Window,
        pointer: Point<Pixels>,
        image: Option<Arc<RenderImage>>,
        cx: &mut App,
    ) {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let Some(screen_pointer) = native::screen_pointer(source, pointer) else {
                return;
            };
            self.native.position(screen_pointer, self.anchor, cx);
            let _ = self.handle.update(cx, |view, _, cx| {
                if let Some(image) = image
                    && view.image.as_ref() != Some(&image)
                {
                    view.image = Some(image);
                    view.image_arrived = Instant::now();
                    cx.notify();
                }
            });
        }
        #[cfg(any(not(target_os = "macos"), test))]
        let _ = (source, pointer, image, cx);
    }

    pub(super) fn close(self, cx: &mut App) {
        self.alive.set(false);
        let _ = self.handle.update(cx, |_, window, _| {
            window.remove_window();
        });
    }

    /// Re-entry reverses the current expansion instead of replacing the
    /// representation or restarting an animation from either endpoint.
    pub(super) fn set_expanded(&self, expanded: bool, cx: &mut App) {
        let reduced = motion::reduced_motion(cx);
        let _ = self.handle.update(cx, |view, _, cx| {
            if view.handoff.is_some() {
                return;
            }
            let changed = view.reduced != reduced;
            view.reduced = reduced;
            if view.morph.retarget(expanded, Instant::now(), reduced) || changed {
                cx.notify();
            }
        });
    }

    /// The real destination is already drawn underneath. Keep its snapshot
    /// continuous through the release, then reveal the live window in place.
    pub(super) fn finish_at(self, destination: &Window, cx: &mut App) {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let Some(target) = native::content_frame(destination) else {
                self.close(cx);
                return;
            };
            let finished = self.handle.update(cx, |view, window, cx| {
                if view.reduced {
                    view.alive.set(false);
                    window.remove_window();
                    return;
                }
                let now = Instant::now();
                let from = view.frame(now);
                if let Some((from, to)) = self.native.handoff_canvas(from, target, cx) {
                    view.handoff = Some(Handoff {
                        started: now,
                        from,
                        to,
                    });
                    cx.notify();
                } else {
                    view.alive.set(false);
                    window.remove_window();
                }
            });
            let _ = finished;
        }
        #[cfg(any(not(target_os = "macos"), test))]
        {
            let _ = destination;
            self.close(cx);
        }
    }
}

struct PreviewView {
    title: SharedString,
    icon: &'static str,
    image: Option<Arc<RenderImage>>,
    theme: Theme,
    font: SharedString,
    reduced: bool,
    morph: PreviewMorph,
    image_arrived: Instant,
    compact_width: f32,
    handoff: Option<Handoff>,
    close_scheduled: bool,
    alive: Rc<Cell<bool>>,
}

fn animation_progress(
    spec: motion::MotionSpec,
    since: Instant,
    now: Instant,
    reduced: bool,
) -> f32 {
    let duration = spec.total().mul_f32(motion::speed_scale());
    if reduced || duration.is_zero() {
        1.0
    } else {
        spec.progress(now.saturating_duration_since(since).as_secs_f32() / duration.as_secs_f32())
    }
}

impl PreviewView {
    fn frame(&self, now: Instant) -> CardFrame {
        if let Some(handoff) = &self.handoff {
            return handoff.from.interpolate(
                handoff.to,
                animation_progress(HANDOFF, handoff.started, now, self.reduced),
            );
        }
        let morph = self.morph.value(now, self.reduced);
        CardFrame {
            x: PADDING,
            y: PADDING,
            width: self.compact_width + (PREVIEW_WIDTH - self.compact_width) * morph,
            height: HEADER_HEIGHT + CONTENT_HEIGHT * morph,
        }
    }
}

impl Render for PreviewView {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let now = Instant::now();
        let morph = self.morph.value(now, self.reduced);
        let image_opacity = animation_progress(MORPH, self.image_arrived, now, self.reduced);
        let handoff = self
            .handoff
            .as_ref()
            .map(|handoff| animation_progress(HANDOFF, handoff.started, now, self.reduced));
        if handoff.is_some_and(|t| t < 1.0)
            || (handoff.is_none()
                && (self.morph.animating(now, self.reduced)
                    || (morph > 0.0 && self.image.is_some() && image_opacity < 1.0)))
        {
            window.request_animation_frame();
        }
        if handoff == Some(1.0) && !self.close_scheduled {
            self.close_scheduled = true;
            let alive = self.alive.clone();
            window.on_next_frame(move |window, _| {
                alive.set(false);
                window.remove_window();
            });
            window.request_animation_frame();
        }
        let frame = self.frame(now);
        // The last fifth crossfades the snapshot to the live destination.
        let opacity = handoff.map_or(1.0, |t| (1.0 - (t - 0.8) / 0.2).clamp(0.0, 1.0));
        let theme = &self.theme;
        let content = match &self.image {
            Some(image) => div().size_full().opacity(image_opacity).child(
                img(image.clone())
                    .size_full()
                    .object_fit(ObjectFit::Contain),
            ),
            None => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .child(
                    icons::icon(self.icon)
                        .size(px(32.0))
                        .text_color(theme.text_muted.opacity(0.35)),
                ),
        };
        div()
            .size_full()
            .relative()
            .font_family(self.font.clone())
            .child(
                div()
                    .absolute()
                    .left(px(frame.x))
                    .top(px(frame.y))
                    .w(px(frame.width))
                    .h(px(frame.height))
                    .opacity(opacity)
                    .overflow_hidden()
                    .rounded(px(10.0))
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.surface_overlay.alpha(1.0))
                    .shadow(vec![gpui::BoxShadow {
                        color: gpui::black().opacity(if theme.appearance.is_dark() {
                            0.36
                        } else {
                            0.18
                        }),
                        offset: point(px(0.0), px(3.0)),
                        blur_radius: px(10.0),
                        spread_radius: px(0.0),
                        inset: false,
                    }])
                    .child(
                        div()
                            .h(px(HEADER_HEIGHT))
                            .w_full()
                            .px(px(10.0))
                            .flex()
                            .items_center()
                            .gap(px(7.0))
                            .text_color(theme.text)
                            .text_size(typography::ui_rems(13.0))
                            .child(icons::icon(self.icon).size(px(14.0)).text_color(theme.text))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_ellipsis()
                                    .child(self.title.clone()),
                            ),
                    )
                    .child(
                        div()
                            .w(px(frame.width))
                            .h(px((frame.height - HEADER_HEIGHT).max(0.0)))
                            .opacity(if handoff.is_some() { 1.0 } else { morph })
                            .bg(theme.bg)
                            .child(content),
                    ),
            )
    }
}

#[cfg(all(target_os = "macos", not(test)))]
mod native {
    use super::{CardFrame, GrabAnchor, PADDING};
    use gpui::{App, Pixels, Point, Window};
    use objc2::rc::Retained;
    use objc2_app_kit::{NSView, NSWindow};
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use std::{cell::Cell, rc::Rc};

    fn view(window: &Window) -> Option<Retained<NSView>> {
        let handle = HasWindowHandle::window_handle(window).ok()?;
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
            return None;
        };
        unsafe { Retained::retain(handle.ns_view.as_ptr().cast::<NSView>()) }
    }

    fn window(window: &Window) -> Option<Retained<NSWindow>> {
        view(window)?.window()
    }

    pub(super) fn screen_pointer(source: &Window, pointer: Point<Pixels>) -> Option<NSPoint> {
        let source_view = view(source)?;
        let source_window = source_view.window()?;
        let y = f64::from(f32::from(pointer.y));
        let local = NSPoint::new(
            f64::from(f32::from(pointer.x)),
            if source_view.isFlipped() {
                y
            } else {
                source_view.bounds().size.height - y
            },
        );
        Some(source_window.convertPointToScreen(source_view.convertPoint_toView(local, None)))
    }

    fn place(window: &NSWindow, pointer: NSPoint, anchor: GrabAnchor) {
        window.setFrameTopLeftPoint(NSPoint::new(
            pointer.x - f64::from(anchor.x + PADDING),
            pointer.y + f64::from(anchor.y + PADDING),
        ));
    }

    /// AppKit sends move/resize notifications synchronously. Applying native
    /// frames inside a GPUI update would re-enter the borrowed App and discard
    /// those callbacks. The foreground task runs after that lease is released.
    #[derive(Clone)]
    pub(super) struct PreviewNative {
        window: Retained<NSWindow>,
        alive: Rc<Cell<bool>>,
        pending_position: Rc<Cell<Option<NSPoint>>>,
        position_queued: Rc<Cell<bool>>,
        generation: Rc<Cell<u64>>,
        configured: Rc<Cell<bool>>,
    }

    impl PreviewNative {
        pub(super) fn configure(
            preview: &Window,
            pointer: NSPoint,
            anchor: GrabAnchor,
            alive: Rc<Cell<bool>>,
            cx: &App,
        ) -> Option<Self> {
            let native = Self {
                window: window(preview)?,
                alive,
                pending_position: Rc::new(Cell::new(None)),
                position_queued: Rc::new(Cell::new(false)),
                generation: Rc::new(Cell::new(0)),
                configured: Rc::new(Cell::new(false)),
            };
            native.queue_position(pointer, anchor, cx);
            Some(native)
        }

        pub(super) fn position(&self, pointer: NSPoint, anchor: GrabAnchor, cx: &App) {
            self.queue_position(pointer, anchor, cx);
        }

        fn configure_once(&self) -> bool {
            if self.configured.replace(true) {
                return false;
            }
            self.window.setIgnoresMouseEvents(true);
            self.window.setHasShadow(false);
            true
        }

        fn queue_position(&self, pointer: NSPoint, anchor: GrabAnchor, cx: &App) {
            self.pending_position.set(Some(pointer));
            if self.position_queued.replace(true) {
                return;
            }
            let this = self.clone();
            let generation = self.generation.get();
            cx.foreground_executor()
                .spawn(async move {
                    this.position_queued.set(false);
                    if !this.alive.get() || this.generation.get() != generation {
                        return;
                    }
                    let Some(pointer) = this.pending_position.take() else {
                        return;
                    };
                    let show = this.configure_once();
                    place(&this.window, pointer, anchor);
                    if show {
                        this.window.orderFront(None);
                    }
                })
                .detach();
        }
    }

    pub(super) struct ScreenFrame {
        left: f64,
        top: f64,
        width: f64,
        height: f64,
    }

    pub(super) fn content_frame(destination: &Window) -> Option<ScreenFrame> {
        let view = view(destination)?;
        let window = view.window()?;
        let bounds = view.bounds();
        let top_left = NSPoint::new(
            bounds.origin.x,
            if view.isFlipped() {
                bounds.origin.y
            } else {
                bounds.origin.y + bounds.size.height
            },
        );
        let point = window.convertPointToScreen(view.convertPoint_toView(top_left, None));
        Some(ScreenFrame {
            left: point.x,
            top: point.y,
            width: bounds.size.width,
            height: bounds.size.height,
        })
    }

    /// Resize/reposition the transparent canvas once, then animate only the
    /// card inside it. No native frame events are generated every paint frame.
    impl PreviewNative {
        pub(super) fn handoff_canvas(
            &self,
            card: CardFrame,
            target: ScreenFrame,
            cx: &App,
        ) -> Option<(CardFrame, CardFrame)> {
            let frame = self.window.frame();
            let from = ScreenFrame {
                left: frame.origin.x + f64::from(card.x),
                top: frame.origin.y + frame.size.height - f64::from(card.y),
                width: f64::from(card.width),
                height: f64::from(card.height),
            };
            let padding = f64::from(PADDING);
            let left = from.left.min(target.left) - padding;
            let top = from.top.max(target.top) + padding;
            let right = (from.left + from.width).max(target.left + target.width) + padding;
            let bottom = (from.top - from.height).min(target.top - target.height) - padding;
            if !(right > left && top > bottom && right - left < 16384.0 && top - bottom < 16384.0) {
                return None;
            }
            let frame = NSRect::new(
                NSPoint::new(left, bottom),
                NSSize::new(right - left, top - bottom),
            );
            // Supersede pointer moves queued before release. They must not move
            // the handoff canvas back to an old pointer position or a closed host.
            let generation = self.generation.get().wrapping_add(1);
            self.generation.set(generation);
            self.pending_position.set(None);
            let this = self.clone();
            cx.foreground_executor()
                .spawn(async move {
                    if this.alive.get() && this.generation.get() == generation {
                        let show = this.configure_once();
                        this.window.setFrame_display(frame, false);
                        if show {
                            this.window.orderFront(None);
                        }
                    }
                })
                .detach();
            let local = |frame: ScreenFrame| CardFrame {
                x: (frame.left - left) as f32,
                y: (top - frame.top) as f32,
                width: frame.width as f32,
                height: frame.height as f32,
            };
            Some((local(from), local(target)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drag_preview_reverses_at_the_current_interpolated_size() {
        let start = Instant::now();
        let duration = MORPH.total().mul_f32(motion::speed_scale());
        let outward = start + duration.mul_f32(0.35);
        let mut morph = PreviewMorph::opening(start, false);
        let before_reentry = morph.value(outward, false);
        assert!((0.0..1.0).contains(&before_reentry));
        assert!(morph.retarget(false, outward, false));
        assert_eq!(morph.value(outward, false), before_reentry);
        let inward = outward + duration.mul_f32(0.2);
        let before_exit = morph.value(inward, false);
        assert!(before_exit < before_reentry);
        assert!(morph.retarget(true, inward, false));
        assert_eq!(morph.value(inward, false), before_exit);
        assert!(morph.value(inward + duration.mul_f32(0.2), false) > before_exit);
        assert!(
            !morph.retarget(true, inward, false),
            "same target restarted the animation"
        );
    }

    #[test]
    fn drag_preview_reduced_motion_snaps_both_directions() {
        let now = Instant::now();
        let mut morph = PreviewMorph::opening(now, false);
        assert!(morph.retarget(false, now, true));
        assert_eq!(morph.value(now, true), 0.0);
        assert!(!morph.animating(now, true));
        assert!(morph.retarget(true, now, true));
        assert_eq!(morph.value(now, true), 1.0);
        assert!(!morph.animating(now, true));
    }

    #[test]
    fn drag_preview_preserves_grab_positions_at_both_tab_edges() {
        for x in [0.0, 3.0, 90.0, 177.0, 180.0] {
            let (anchor, width) = grab_anchor(point(px(x), px(9.0)), 180.0);
            assert_eq!(width, 180.0);
            assert_eq!(anchor.x, x, "pickup shifted the tab under the pointer");
            assert_eq!(anchor.y, 9.0);
        }
    }

    #[test]
    fn drag_preview_scales_grab_with_bounded_tab_width() {
        let (anchor, width) = grab_anchor(point(px(600.0), px(12.0)), 700.0);
        assert_eq!(width, PREVIEW_WIDTH);
        assert!((anchor.x / width - 600.0 / 700.0).abs() < 0.0001);
        assert_eq!(anchor.y, 12.0);
    }

    #[test]
    fn drag_preview_bounds_invalid_or_outside_grab_coordinates() {
        for (grab, width) in [
            (point(px(-20.0), px(100.0)), 180.0),
            (point(px(f32::NAN), px(f32::INFINITY)), f32::NAN),
            (point(px(50.0), px(8.0)), 0.0),
        ] {
            let (anchor, width) = grab_anchor(grab, width);
            assert!((72.0..=PREVIEW_WIDTH).contains(&width));
            assert!((0.0..=width).contains(&anchor.x));
            assert!((0.0..=HEADER_HEIGHT).contains(&anchor.y));
        }
    }
}
