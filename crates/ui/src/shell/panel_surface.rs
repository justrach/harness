//! One contour owns the selected horizontal tab and its panel. GPUI's native
//! blur primitive only accepts rounded rectangles, so the contour's shadow is
//! integrated from narrow, Gaussian-weighted strokes before its opaque fill.
//! This avoids two overlapping shadows and a dark line across the tab's foot.

use crate::theme::Theme;
use gpui::{Bounds, PathBuilder, Pixels, Point, Window, point, px};

pub(super) const BODY_RADIUS: f32 = 10.0;
const CAP_RADIUS: f32 = 10.0;
const SHOULDER_RADIUS: f32 = 8.0;

/// Coordinates are in the same window space as the panel body's bounds. The
/// tab's content/root height is deliberately independent of the surface shape;
/// the body's upper edge supplies its foot, including animated header layouts.
#[derive(Clone, Copy, Debug)]
pub(super) struct TabGeometry {
    pub left: Pixels,
    pub right: Pixels,
    pub top: Pixels,
    pub flush_left: bool,
    flush_right: bool,
}

impl TabGeometry {
    pub fn from_bounds(bounds: Bounds<Pixels>, flush_left: bool) -> Self {
        Self {
            left: bounds.left() + px(0.5),
            right: bounds.right() - px(0.5),
            top: bounds.top() + px(0.5),
            flush_left,
            flush_right: false,
        }
    }

    fn translated(self, offset: Point<Pixels>) -> Self {
        Self {
            left: self.left + offset.x,
            right: self.right + offset.x,
            top: self.top + offset.y,
            flush_left: self.flush_left,
            flush_right: self.flush_right,
        }
    }

    fn visible_on(self, body: Bounds<Pixels>) -> Option<Self> {
        let first_stem = body.left() + px(BODY_RADIUS + SHOULDER_RADIUS);
        let last_stem = body.right() - px(BODY_RADIUS + SHOULDER_RADIUS);
        let flush_left =
            (self.flush_left && self.left <= body.left() + px(0.5)) || self.left < first_stem;
        let flush_right = self.right > last_stem;
        let left = if flush_left {
            body.left()
        } else {
            self.left.max(first_stem)
        };
        // A visible trailing tab must keep its measured edge. Clamping its
        // silhouette to the rounded-body inset made it look narrower than its
        // label and shifted the terminal tab as it approached the strip edge.
        let right = if flush_right {
            body.right()
        } else {
            self.right
        };
        (right - left >= px(CAP_RADIUS * 2.0) && self.top < body.top() - px(8.0)).then_some(Self {
            left,
            right,
            flush_left,
            flush_right,
            ..self
        })
    }
}

/// Paint before panel content and tab labels, after every selected-tab recorder
/// has completed prepaint. The caller retains clipping for the scrollable tab
/// content and rounded panel content; this painter must be allowed into gutters.
pub(super) fn paint_surface(
    body: Bounds<Pixels>,
    active: Option<TabGeometry>,
    theme: &Theme,
    window: &mut Window,
) {
    if body.size.width <= px(BODY_RADIUS * 2.0) || body.size.height <= px(BODY_RADIUS * 2.0) {
        return;
    }
    // Place the one-pixel outline wholly inside the body's layout bounds.
    let body = body.inset(px(0.5));
    let active = active.and_then(|tab| tab.visible_on(body));
    let dark = theme.appearance.is_dark();
    let mut fill = PathBuilder::fill();
    outline(&mut fill, body, active);
    if let Ok(path) = fill.build() {
        window.paint_path(path, theme.bg);
    }
    let mut border = PathBuilder::stroke(px(1.0));
    outline(&mut border, body, active);
    if let Ok(path) = border.build() {
        // A quiet edge keeps the shadow from reading as a second border.
        window.paint_path(path, theme.border.opacity(if dark { 0.72 } else { 0.55 }));
    }
}

/// The workspace paints these from outside its scroll mask so the shadow can
/// fall across the sidebar. The opaque surface and its content stay clipped.
pub(super) fn paint_surface_shadow(
    body: Bounds<Pixels>,
    active: Option<TabGeometry>,
    theme: &Theme,
    window: &mut Window,
) {
    if body.size.width <= px(BODY_RADIUS * 2.0) || body.size.height <= px(BODY_RADIUS * 2.0) {
        return;
    }
    let body = body.inset(px(0.5));
    let active = active.and_then(|tab| tab.visible_on(body));
    let dark = theme.appearance.is_dark();
    for (offset_y, sigma, opacity) in [
        (3.0, 4.8, if dark { 0.20 } else { 0.055 }),
        (1.0, 1.4, if dark { 0.18 } else { 0.060 }),
    ] {
        paint_contour_shadow(body, active, offset_y, sigma, opacity, window);
    }
}

fn paint_contour_shadow(
    body: Bounds<Pixels>,
    active: Option<TabGeometry>,
    offset_y: f32,
    sigma: f32,
    opacity: f32,
    window: &mut Window,
) {
    let offset = point(px(0.0), px(offset_y));
    let body = body + offset;
    let active = active.map(|tab| tab.translated(offset));
    // A logical pixel between samples avoids a coarse stack of visible rings
    // at both 1x and 2x. Interior contributions are covered by the surface fill.
    let extent = (sigma * 2.5).ceil() as usize;
    let density = |radius: f32| opacity * (-radius * radius / (2.0 * sigma * sigma)).exp();
    let mut accumulated = 0.0;
    for radius in (1..=extent).rev() {
        let target = density(radius as f32 - 0.5);
        let alpha = ((target - accumulated) / (1.0 - accumulated)).clamp(0.0, 1.0);
        accumulated = target;
        let mut shadow = PathBuilder::stroke(px(radius as f32 * 2.0));
        outline(&mut shadow, body, active);
        if let Ok(path) = shadow.build() {
            window.paint_path(path, gpui::black().opacity(alpha));
        }
    }
}

fn outline(path: &mut PathBuilder, body: Bounds<Pixels>, active: Option<TabGeometry>) {
    let left = body.left();
    let right = body.right();
    let top = body.top();
    let bottom = body.bottom();
    let r = px(BODY_RADIUS);
    let flush = active.is_some_and(|tab| tab.flush_left);
    if let Some(tab) = active {
        let shoulder = px(SHOULDER_RADIUS);
        let cap = px(CAP_RADIUS).min((top - tab.top) / 2.0);
        if flush {
            // The first tab and panel share this vertical edge. Only the cap's
            // upper corner curves; there is no inset or lower-left shoulder.
            path.move_to(point(left, tab.top + cap));
        } else {
            path.move_to(point(left + r, top));
            path.line_to(point(tab.left - shoulder, top));
            path.curve_to(point(tab.left, top - shoulder), point(tab.left, top));
            path.line_to(point(tab.left, tab.top + cap));
        }
        path.curve_to(point(tab.left + cap, tab.top), point(tab.left, tab.top));
        path.line_to(point(tab.right - cap, tab.top));
        path.curve_to(point(tab.right, tab.top + cap), point(tab.right, tab.top));
        if !tab.flush_right {
            path.line_to(point(tab.right, top - shoulder));
            path.curve_to(point(tab.right + shoulder, top), point(tab.right, top));
        }
    } else {
        path.move_to(point(left + r, top));
    }
    if !active.is_some_and(|tab| tab.flush_right) {
        path.line_to(point(right - r, top));
        path.curve_to(point(right, top + r), point(right, top));
    }
    path.line_to(point(right, bottom - r));
    path.curve_to(point(right - r, bottom), point(right, bottom));
    path.line_to(point(left + r, bottom));
    path.curve_to(point(left, bottom - r), point(left, bottom));
    if let Some(tab) = active.filter(|_| flush) {
        let cap = px(CAP_RADIUS).min((top - tab.top) / 2.0);
        path.line_to(point(left, tab.top + cap));
    } else {
        path.line_to(point(left, top + r));
        path.curve_to(point(left + r, top), point(left, top));
    }
    path.close();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_tab_outline_does_not_inset_a_visible_label() {
        let body = Bounds::new(point(px(100.0), px(80.0)), gpui::size(px(500.0), px(400.0)));
        let tab = TabGeometry::from_bounds(
            Bounds::new(point(px(350.0), px(43.0)), gpui::size(px(240.0), px(37.0))),
            false,
        )
        .visible_on(body)
        .unwrap();
        assert_eq!(tab.left, px(350.5));
        assert_eq!(tab.right, body.right());
        assert!(tab.flush_right);
        assert!(!tab.flush_left);
    }

    #[test]
    fn scrolled_tab_keeps_visible_edge_flush_with_its_panel() {
        let body = Bounds::new(point(px(100.0), px(80.0)), gpui::size(px(500.0), px(400.0)));
        let tab = TabGeometry::from_bounds(
            Bounds::new(point(px(55.0), px(43.0)), gpui::size(px(240.0), px(37.0))),
            false,
        )
        .visible_on(body)
        .unwrap();
        assert_eq!(tab.left, body.left());
        assert!(tab.flush_left);
        assert_eq!(tab.right, px(294.5));
        assert!(!tab.flush_right);
    }
}
