//! A DialKit-style tuning panel: compact rows that show their value as a fill,
//! named presets instead of dropdowns, and a copy-as-code row. This is the
//! dev-only **Tune** panel for Harness's own motion and shape tokens; it
//! floats over the app, so it is the one glass layer on screen.
//!
//! Pure render functions over plain data, so a fixture can render any state.
//! Idea from DialKit (MIT, https://github.com/joshpuckett/dialkit) and the fork
//! lab at https://scaena.darkroom.engineering. No code is shared with either.
use crate::icons;
use crate::motion::{CubicBezier, EASE, EASE_IN_OUT, EASE_OUT, EASE_OUT_EXPO, EASE_OUT_QUINT};
use crate::popover::{CARD_INSET, CARD_RADIUS, nested_radius};
use crate::theme::Theme;
use crate::typography::{
    TEXT_BODY, TEXT_CAPTION, TEXT_TITLE, TabularNums, WEIGHT_REGULAR, WEIGHT_STRONG,
};
use gpui::{
    Div, Hsla, IntoElement, PathBuilder, SharedString, canvas, div, point, prelude::*, px, relative,
};

/// Panel width: DialKit's panel is about this wide, and every row below is
/// laid out against it.
pub const PANEL_WIDTH: f32 = 296.0;
/// Row height. Rows are drawn 28 px tall; [`crate::theme::Theme::HIT_TARGET`]
/// is met by the 2 px gaps the panel puts between them.
pub const ROW_HEIGHT: f32 = 28.0;
/// Rows sit one inset inside the panel's 12 px corner: 12 - 1 - 4 = 7 px.
pub const ROW_RADIUS: f32 = nested_radius(CARD_RADIUS, 1.0, CARD_INSET);
/// Segments sit 2 px inside a row: 7 - 0 - 2 = 5 px.
pub const SEGMENT_RADIUS: f32 = nested_radius(ROW_RADIUS, 0.0, 2.0);

/// The curves Harness already ships, by the name a designer would pick them.
pub const CURVE_PRESETS: [(&str, CubicBezier); 6] = [
    ("Quint", EASE_OUT_QUINT),
    ("Expo", EASE_OUT_EXPO),
    ("Ease", EASE),
    ("Out", EASE_OUT),
    ("In-out", EASE_IN_OUT),
    ("Linear", CubicBezier::new(0.0, 0.0, 1.0, 1.0)),
];

fn track(theme: &Theme) -> Hsla {
    theme.ink(0.05)
}

/// The floating panel. `glass` is for the dev Tune panel, which floats over
/// the app; a panel used as a popover passes `false` and stays solid.
pub fn panel(theme: &Theme, glass: bool) -> Div {
    div()
        .w(px(PANEL_WIDTH))
        .flex()
        .flex_col()
        .gap(px(2.0))
        .p(px(CARD_INSET))
        .rounded(px(CARD_RADIUS))
        .border_1()
        .border_color(theme.border)
        .bg(if glass {
            theme.glass()
        } else {
            theme.surface_dialog
        })
        .shadow_lg()
        .text_size(px(TEXT_BODY))
        .font_weight(WEIGHT_REGULAR)
        .text_color(theme.text)
}

fn icon_button(theme: &Theme, path: &'static str) -> Div {
    // 12 px glyph centred in a 28 px cell, so its edge sits 8 px in, like
    // every label and chevron; the panel gap carries the cell to 32.
    div()
        .size(px(ROW_HEIGHT))
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(ROW_RADIUS))
        .child(
            icons::icon(path)
                .size(px(12.0))
                .text_color(theme.text_muted),
        )
}

/// Title row: a name, an optional muted subtitle, and trailing icon buttons.
pub fn header(
    theme: &Theme,
    title: impl Into<SharedString>,
    subtitle: Option<SharedString>,
    actions: Vec<&'static str>,
) -> Div {
    div()
        .h(px(ROW_HEIGHT + 4.0))
        .pl(px(8.0))
        .flex()
        .items_center()
        .gap(px(6.0))
        .child(
            div()
                .text_size(px(TEXT_TITLE))
                .font_weight(WEIGHT_STRONG)
                .child(title.into()),
        )
        .children(subtitle.map(|s| div().text_color(theme.text_faint).child(s)))
        .child(div().flex_1())
        .children(actions.into_iter().map(|path| icon_button(theme, path)))
}

/// A folder heading: caption text and a chevron.
pub fn section(theme: &Theme, label: impl Into<SharedString>, open: bool) -> Div {
    div()
        .h(px(ROW_HEIGHT))
        .px(px(8.0))
        .mt(px(2.0))
        .flex()
        .items_center()
        .justify_between()
        .text_size(px(TEXT_CAPTION))
        .text_color(theme.text_muted)
        .child(label.into())
        .child(
            icons::icon(if open {
                icons::ALT_ARROW_UP
            } else {
                icons::ALT_ARROW_DOWN
            })
            .size(px(12.0))
            .text_color(theme.text_faint),
        )
}

/// A slider row in DialKit's shape: the value is a fill behind the label,
/// with a thin handle on its edge, and the number sits at the right in
/// tabular figures. `focused` draws the edge handle stronger, as while
/// dragging.
pub fn dial_row(
    theme: &Theme,
    label: impl Into<SharedString>,
    value: impl Into<SharedString>,
    fraction: f32,
    focused: bool,
) -> Div {
    let fraction = fraction.clamp(0.0, 1.0);
    div()
        .relative()
        .h(px(ROW_HEIGHT))
        .rounded(px(ROW_RADIUS))
        .bg(track(theme))
        .overflow_hidden()
        .child(
            div()
                .absolute()
                .left_0()
                .top_0()
                .bottom_0()
                .w(relative(fraction))
                .bg(theme.ink(if focused { 0.10 } else { 0.07 })),
        )
        .child(
            div()
                .absolute()
                .top(px(8.0))
                .left(relative(fraction))
                .ml(px(-4.0))
                .w(px(2.0))
                .h(px(12.0))
                .rounded_full()
                .bg(theme.ink(if focused { 0.55 } else { 0.22 })),
        )
        .child(
            div()
                .relative()
                .size_full()
                .px(px(8.0))
                .flex()
                .items_center()
                .justify_between()
                .child(div().text_color(theme.text_muted).child(label.into()))
                .child(div().tabular_nums().child(value.into())),
        )
}

/// A row of mutually exclusive choices, the selected one raised.
pub fn segmented(theme: &Theme, options: &[&str], selected: usize) -> Div {
    div()
        .h(px(ROW_HEIGHT))
        .p(px(2.0))
        .rounded(px(ROW_RADIUS))
        .bg(track(theme))
        .flex()
        .gap(px(2.0))
        .children(options.iter().enumerate().map(|(ix, label)| {
            let on = ix == selected;
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(SEGMENT_RADIUS))
                .when(on, |el| el.bg(theme.ink(0.10)))
                .text_color(if on { theme.text } else { theme.text_muted })
                .when(on, |el| el.font_weight(WEIGHT_STRONG))
                .child(label.to_string())
        }))
}

fn curve_path(curve: CubicBezier, w: f32, h: f32, steps: usize) -> Vec<(f32, f32)> {
    (0..=steps)
        .map(|i| {
            let t = i as f32 / steps as f32;
            let u = 1.0 - t;
            let x = 3.0 * u * u * t * curve.x1 + 3.0 * u * t * t * curve.x2 + t * t * t;
            let y = 3.0 * u * u * t * curve.y1 + 3.0 * u * t * t * curve.y2 + t * t * t;
            (x * w, h - y * h)
        })
        .collect()
}

fn stroke(points: &[(f32, f32)], ox: gpui::Pixels, oy: gpui::Pixels, width: f32) -> PathBuilder {
    let mut path = PathBuilder::stroke(px(width));
    for (i, (x, y)) in points.iter().enumerate() {
        let p = point(ox + px(*x), oy + px(*y));
        if i == 0 {
            path.move_to(p);
        } else {
            path.line_to(p);
        }
    }
    path
}

/// A small glyph of a curve, for preset pills.
pub fn curve_glyph(curve: CubicBezier, color: Hsla) -> impl IntoElement {
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let pts = curve_path(curve, 12.0, 12.0, 24);
            if let Ok(path) = stroke(
                &pts,
                bounds.origin.x + px(1.0),
                bounds.origin.y + px(1.0),
                1.3,
            )
            .build()
            {
                window.paint_path(path, color);
            }
        },
    )
    .size(px(14.0))
    .flex_none()
}

/// The curve editor's face: the curve, its two handles, and the four
/// control-point numbers under it.
pub fn curve_card(theme: &Theme, curve: CubicBezier) -> Div {
    let line = theme.text;
    let faint = theme.ink(0.10);
    let handle = theme.text_muted;
    let graph = canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let (w, h) = (
                f32::from(bounds.size.width) - 48.0,
                f32::from(bounds.size.height) - 28.0,
            );
            let ox = bounds.origin.x + px(24.0);
            let oy = bounds.origin.y + px(14.0);
            // Baseline diagonal.
            if let Ok(p) = stroke(&[(0.0, h), (w, 0.0)], ox, oy, 1.0).build() {
                window.paint_path(p, faint);
            }
            // Handle arms.
            let p1 = (curve.x1 * w, h - curve.y1 * h);
            let p2 = (curve.x2 * w, h - curve.y2 * h);
            for (from, to) in [((0.0, h), p1), ((w, 0.0), p2)] {
                if let Ok(p) = stroke(&[from, to], ox, oy, 1.0).build() {
                    window.paint_path(p, handle.opacity(0.6));
                }
            }
            if let Ok(p) = stroke(&curve_path(curve, w, h, 64), ox, oy, 2.0).build() {
                window.paint_path(p, line);
            }
            for (x, y) in [p1, p2] {
                let mut ring = PathBuilder::stroke(px(1.5));
                for i in 0..=24 {
                    let a = std::f32::consts::TAU * i as f32 / 24.0;
                    let q = point(ox + px(x + 4.0 * a.cos()), oy + px(y + 4.0 * a.sin()));
                    if i == 0 {
                        ring.move_to(q)
                    } else {
                        ring.line_to(q)
                    }
                }
                if let Ok(p) = ring.build() {
                    window.paint_path(p, line);
                }
            }
        },
    )
    .w_full()
    .h(px(104.0));
    let numbers = [curve.x1, curve.y1, curve.x2, curve.y2];
    div()
        .rounded(px(ROW_RADIUS))
        .bg(track(theme))
        .flex()
        .flex_col()
        .child(graph)
        .child(
            div()
                .h(px(ROW_HEIGHT))
                .px(px(8.0))
                .flex()
                .items_center()
                .justify_between()
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text_muted)
                .tabular_nums()
                .children(numbers.iter().map(|n| div().child(format!("{n:.2}")))),
        )
}

/// Named preset pills in two columns, a curve glyph in each.
pub fn curve_presets(theme: &Theme, selected: usize) -> Div {
    div()
        .flex()
        .flex_wrap()
        .gap(px(2.0))
        .children(CURVE_PRESETS.iter().enumerate().map(|(ix, (name, curve))| {
            let on = ix == selected;
            div()
                .w(px((PANEL_WIDTH - 2.0 * CARD_INSET - 2.0 - 2.0) / 2.0))
                .h(px(ROW_HEIGHT))
                .px(px(8.0))
                .rounded(px(ROW_RADIUS))
                .flex()
                .items_center()
                .gap(px(8.0))
                .bg(if on { theme.accent_wash } else { track(theme) })
                .text_color(if on {
                    theme.accent_strong
                } else {
                    theme.text_muted
                })
                .child(curve_glyph(
                    *curve,
                    if on {
                        theme.accent_strong
                    } else {
                        theme.text_muted
                    },
                ))
                .child(name.to_string())
        }))
}

/// Several numbers in one row, like DialKit fork's X Y Z scale: each cell is
/// scrubbed by dragging its letter, and the lock ties them together.
pub fn axis_row(theme: &Theme, cells: &[(&str, &str)], locked: bool) -> Div {
    div()
        .h(px(ROW_HEIGHT))
        .flex()
        .gap(px(2.0))
        .children(cells.iter().map(|(axis, value)| {
            div()
                .flex_1()
                .h_full()
                .px(px(8.0))
                .rounded(px(ROW_RADIUS))
                .bg(track(theme))
                .flex()
                .items_center()
                .justify_between()
                .child(div().text_color(theme.text_faint).child(axis.to_string()))
                .child(div().tabular_nums().child(value.to_string()))
        }))
        .child(
            div()
                .w(px(ROW_HEIGHT))
                .h_full()
                .rounded(px(ROW_RADIUS))
                .bg(if locked {
                    theme.accent_wash
                } else {
                    track(theme)
                })
                .flex()
                .items_center()
                .justify_center()
                .child(
                    icons::icon(icons::LOCK)
                        .size(px(13.0))
                        .text_color(if locked {
                            theme.accent_strong
                        } else {
                            theme.text_faint
                        }),
                ),
        )
}

/// A live preview of concentric corners: an outer card and the element
/// inset inside it, rounded by [`nested_radius`].
pub fn concentric_preview(theme: &Theme, outer: f32, border: f32, inset: f32) -> Div {
    let inner = nested_radius(outer, border, inset).max(0.0);
    div()
        .h(px(88.0))
        .rounded(px(ROW_RADIUS))
        .bg(track(theme))
        .flex()
        .items_center()
        .justify_center()
        .gap(px(16.0))
        .child(
            div()
                .w(px(132.0))
                .h(px(64.0))
                .rounded(px(outer))
                .border(px(border))
                .border_color(theme.border_strong)
                .bg(theme.surface_card)
                .p(px(inset))
                .child(
                    div()
                        .size_full()
                        .rounded(px(inner))
                        .bg(theme.accent_wash)
                        .border_1()
                        .border_color(theme.accent.opacity(0.35)),
                ),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(1.0))
                .child(
                    div()
                        .text_size(px(TEXT_TITLE))
                        .font_weight(WEIGHT_STRONG)
                        .tabular_nums()
                        .child(format!("{inner:.0} px")),
                )
                .child(
                    div()
                        .text_size(px(TEXT_CAPTION))
                        .text_color(theme.text_faint)
                        .child("inner"),
                ),
        )
}

/// The value as code, ready to paste, with a copy button.
pub fn code_row(theme: &Theme, code: impl Into<SharedString>) -> Div {
    div()
        .mt(px(2.0))
        .h(px(ROW_HEIGHT + 2.0))
        .pl(px(8.0))
        .rounded(px(ROW_RADIUS))
        .bg(theme.ink(0.035))
        .border_1()
        .border_color(theme.border)
        .flex()
        .items_center()
        .gap(px(8.0))
        .child(
            div()
                .flex_1()
                .overflow_hidden()
                .font_family(theme.font_mono.clone())
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text)
                .child(code.into()),
        )
        .child(icon_button(theme, icons::COPY))
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_are_concentric_with_the_panel() {
        assert_eq!(ROW_RADIUS, 7.0);
        assert_eq!(SEGMENT_RADIUS, 5.0);
    }

    #[test]
    fn curve_presets_are_the_shipped_curves() {
        assert_eq!(CURVE_PRESETS[0].1, EASE_OUT_QUINT);
        let pts = curve_path(EASE_OUT_QUINT, 100.0, 100.0, 10);
        assert_eq!(pts.first().copied(), Some((0.0, 100.0)));
        let (x, y) = pts.last().copied().unwrap();
        assert!((x - 100.0).abs() < 1e-3 && y.abs() < 1e-3);
    }
}
