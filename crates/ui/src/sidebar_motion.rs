//! The sidebar's looping animations (a working chat's spinner, a queued
//! build's breathing dot, the sync and reconnect spinners), painted outside
//! the sidebar view.
//!
//! gpui marks every ancestor of a notified view dirty, and a cached view that
//! re-renders re-renders everything inside it. A spinner anywhere inside the
//! sidebar therefore rebuilt and re-laid-out every chat row on each tick
//! (15Hz while any agent works) — most of the app's main-thread time while
//! agents ran. Instead, the sidebar draws an empty slot where each animation
//! goes and records the slot's bounds and clip while it prepaints;
//! [`SidebarMotion`], a sibling view outside the sidebar, paints the
//! animations into those slots. Only that small view is notified per tick,
//! so the cached sidebar is reused.
//!
//! A sidebar render starts a new set of slots ([`MotionSlots::begin_frame`]):
//! one it doesn't draw again stops painting. While the sidebar is reused from
//! its cache, its slots haven't moved.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gpui::{
    AnyElement, App, Bounds, ContentMask, Context, Hsla, IntoElement, ParentElement as _, Pixels,
    Render, SharedString, Styled, Window, canvas, div, point, px, size,
};

use crate::motion::{self, GRADIENT_SPIN};

/// What a slot animates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum MotionKind {
    /// The 2×3 snake ([`crate::loaders::mini_glyph_spinner`]), one tint per row.
    Spinner { cell_px: f32, tints: [Hsla; 3] },
    /// The queued-build breath ([`crate::loaders::build_wait_dot`]).
    WaitDot { color: Hsla },
}

impl MotionKind {
    /// The slot's footprint, the same as the element it replaces.
    fn size(self) -> (f32, f32) {
        match self {
            MotionKind::Spinner { cell_px, .. } => (cell_px * 2.5, cell_px * 4.0),
            MotionKind::WaitDot { .. } => (16.0, 16.0),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Slot {
    bounds: Bounds<Pixels>,
    mask: ContentMask<Pixels>,
    kind: MotionKind,
}

/// Where the sidebar's animations go, as of its last render.
#[derive(Debug, Default)]
pub(crate) struct MotionSlots {
    slots: HashMap<SharedString, Slot>,
}

pub(crate) type SharedMotionSlots = Rc<RefCell<MotionSlots>>;

impl MotionSlots {
    /// The sidebar is rendering again: it places every slot it still shows.
    pub(crate) fn begin_frame(&mut self) {
        self.slots.clear();
    }

    fn place(&mut self, key: SharedString, slot: Slot) {
        self.slots.insert(key, slot);
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.slots.len()
    }
}

/// An empty slot of the animation's size, for the sidebar to lay out in place
/// of the animation itself; [`SidebarMotion`] paints into it.
pub(crate) fn slot(
    slots: &SharedMotionSlots,
    key: impl Into<SharedString>,
    kind: MotionKind,
) -> AnyElement {
    let slots = slots.clone();
    let key = key.into();
    let (w, h) = kind.size();
    canvas(
        move |bounds, window, _| {
            slots.borrow_mut().place(
                key,
                Slot {
                    bounds,
                    mask: window.content_mask(),
                    kind,
                },
            );
        },
        |_, _, _, _| {},
    )
    .w(px(w))
    .h(px(h))
    .flex_none()
    .into_any_element()
}

/// Paints the sidebar's animations into the slots it placed. Mounted next to
/// the sidebar, never inside it, so its ticks leave the sidebar cached.
pub(crate) struct SidebarMotion {
    slots: SharedMotionSlots,
}

impl SidebarMotion {
    pub(crate) fn new(slots: SharedMotionSlots) -> Self {
        Self { slots }
    }
}

impl Render for SidebarMotion {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let slots = self.slots.clone();
        let view = cx.entity_id();
        // Positions are read at paint, after the sidebar prepainted this frame.
        div().absolute().inset_0().child(
            canvas(
                |_, _, _| (),
                move |_, _, window, cx| paint_slots(&slots.borrow(), view, window, cx),
            )
            .absolute()
            .inset_0(),
        )
    }
}

fn paint_slots(slots: &MotionSlots, view: gpui::EntityId, window: &mut Window, cx: &mut App) {
    if slots.slots.is_empty() {
        // No lease is renewed, so the clock parks.
        return;
    }
    let has = |want: fn(&MotionKind) -> bool| slots.slots.values().any(|slot| want(&slot.kind));
    let spin = has(|kind| matches!(kind, MotionKind::Spinner { .. }))
        .then(|| motion::pulse_delta_slow(&GRADIENT_SPIN, view, cx));
    let breath = has(|kind| matches!(kind, MotionKind::WaitDot { .. })).then(|| {
        let phase = motion::pulse_delta_slow(&crate::loaders::WAIT_PULSE, view, cx);
        crate::build_wait::pulse(phase, motion::reduced_motion(cx))
    });
    for slot in slots.slots.values() {
        window.with_content_mask(Some(slot.mask.clone()), |window| match slot.kind {
            MotionKind::Spinner { cell_px, tints } => crate::loaders::paint_mini_spinner(
                slot.bounds.origin,
                cell_px,
                tints,
                spin.unwrap_or_default(),
                window,
            ),
            MotionKind::WaitDot { color } => {
                if let Some(pulse) = breath {
                    paint_wait_dot(slot.bounds, color, pulse, window);
                }
            }
        });
    }
}

/// [`crate::loaders::build_wait_dot`], painted: a ring and a dot, centered.
fn paint_wait_dot(
    bounds: Bounds<Pixels>,
    color: Hsla,
    pulse: crate::build_wait::Pulse,
    window: &mut Window,
) {
    let center = bounds.center();
    let ring = 12.0 * pulse.ring_scale;
    window.paint_quad(gpui::quad(
        Bounds::new(
            point(center.x - px(ring / 2.0), center.y - px(ring / 2.0)),
            size(px(ring), px(ring)),
        ),
        px(ring / 2.0),
        gpui::transparent_black(),
        px(1.0),
        color.opacity(pulse.ring_opacity),
        gpui::BorderStyle::default(),
    ));
    let dot = 6.0 * pulse.dot_scale;
    window.paint_quad(
        gpui::fill(
            Bounds::new(
                point(center.x - px(dot / 2.0), center.y - px(dot / 2.0)),
                size(px(dot), px(dot)),
            ),
            color.opacity(pulse.dot_opacity),
        )
        .corner_radii(px(dot / 2.0)),
    );
}
