//! Settings → Appearance: choose the palette and the interface font.
//!
//! Uses [`widgets::option_card_row`] — a preview-card picker, because the choice
//! is a *look*, and a miniature of the result says more than a sentence about it.
//! The control itself is theme-agnostic; only the previews below know what a
//! theme is.
//!
use gpui::{
    AnyElement, Context, FocusHandle, Hsla, IntoElement, KeyDownEvent, MouseButton, Render,
    SharedString, Window, div, prelude::*, px,
};

use crate::appearance::{self, AppearanceMode};
use crate::popover;
use crate::settings::widgets;
use crate::theme::{Appearance, Theme};
use crate::typography::{self, FontAvailability, UiFontFamily};

pub struct AppearancePage {
    selected_font: UiFontFamily,
    font_focus: FocusHandle,
}

impl AppearancePage {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            selected_font: typography::effective(cx),
            font_focus: cx.focus_handle(),
        }
    }

    fn commit_font(&mut self, cx: &mut Context<Self>) {
        if typography::is_available(self.selected_font, cx) {
            typography::set_family(self.selected_font, cx);
            self.selected_font = typography::effective(cx);
            cx.notify();
        }
    }

    fn reset_font(&mut self, cx: &mut Context<Self>) {
        self.selected_font = UiFontFamily::Geist;
        self.commit_font(cx);
    }

    fn on_font_key_down(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let availability = typography::availability(cx);
        match event.keystroke.key.as_str() {
            "up" | "left" => {
                self.selected_font = step_font(self.selected_font, -1, availability);
                cx.notify();
            }
            "down" | "right" => {
                self.selected_font = step_font(self.selected_font, 1, availability);
                cx.notify();
            }
            "home" => {
                self.selected_font = first_available(availability);
                cx.notify();
            }
            "end" => {
                self.selected_font = last_available(availability);
                cx.notify();
            }
            "enter" | "space" => self.commit_font(cx),
            "escape" => {
                self.selected_font = typography::effective(cx);
                cx.notify();
            }
            _ => {}
        }
    }
}

fn step_font(current: UiFontFamily, delta: isize, availability: FontAvailability) -> UiFontFamily {
    let current = UiFontFamily::ALL
        .iter()
        .position(|family| *family == current)
        .unwrap_or_default() as isize;
    let mut ix = current + delta.signum();
    while (0..UiFontFamily::ALL.len() as isize).contains(&ix) {
        let candidate = UiFontFamily::ALL[ix as usize];
        if availability.is_available(candidate) {
            return candidate;
        }
        ix += delta.signum();
    }
    UiFontFamily::ALL[current as usize]
}

fn first_available(availability: FontAvailability) -> UiFontFamily {
    UiFontFamily::ALL
        .into_iter()
        .find(|family| availability.is_available(*family))
        .unwrap_or(UiFontFamily::System)
}

fn last_available(availability: FontAvailability) -> UiFontFamily {
    UiFontFamily::ALL
        .into_iter()
        .rev()
        .find(|family| availability.is_available(*family))
        .unwrap_or(UiFontFamily::System)
}

fn can_confirm(
    selected: UiFontFamily,
    effective: UiFontFamily,
    availability: FontAvailability,
) -> bool {
    selected != effective && availability.is_available(selected)
}

fn font_status(effective: UiFontFamily) -> SharedString {
    format!(
        "Current: {}. Use arrow keys, then Enter to apply.",
        effective.label()
    )
    .into()
}

/// One placeholder bar in the miniature, width given as a fraction of its
/// container.
///
/// Relative rather than fixed px because the System card renders this same
/// miniature into *half* a card. Fixed widths were wider than the squeezed
/// content pane and spilled out over the card edge.
fn bar(fraction: f32, tone: Hsla) -> gpui::Div {
    div()
        .h(px(5.0))
        .w(gpui::relative(fraction))
        .rounded(px(3.0))
        .bg(tone)
}

/// Which corners a miniature rounds — the split card needs each half to round
/// only its outer side so the two meet flush down the middle.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Corners {
    All,
    Left,
    Right,
}

/// A miniature of the app in `theme`: sidebar strip, inset content card, a few
/// placeholder lines. Built from the theme's own tokens rather than fixed
/// swatches, so the previews stay honest if the palette is retuned.
///
/// Rounds itself: the card frame cannot do it for us (see
/// [`widgets::OPTION_CARD_RADIUS`]). Only this root paints a background that
/// reaches the corners — the sidebar strip is transparent and the content card is
/// inset — so rounding here is enough.
fn miniature(theme: &Theme, corners: Corners) -> AnyElement {
    let line = theme.text.opacity(0.22);
    let strong = theme.text.opacity(0.34);
    let r = px(widgets::OPTION_CARD_RADIUS);
    let root = div().size_full().flex().flex_row().bg(theme.surface);
    let root = match corners {
        Corners::All => root.rounded(r),
        Corners::Left => root.rounded_tl(r).rounded_bl(r),
        Corners::Right => root.rounded_tr(r).rounded_br(r),
    };
    root.child(
        // Sidebar strip.
        div()
            .w(px(44.0))
            .h_full()
            .flex_none()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap(px(7.0))
            .px(px(8.0))
            .pt(px(14.0))
            .child(bar(0.70, strong))
            .child(bar(1.0, line))
            .child(bar(0.85, line))
            .child(bar(1.0, line)),
    )
    .child(
        // Inset content card — the same rounded plate the real shell floats.
        div()
            .flex_1()
            .min_w_0()
            .my(px(8.0))
            .mr(px(8.0))
            .rounded(px(6.0))
            .border_1()
            .border_color(theme.border)
            .bg(theme.bg)
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap(px(7.0))
            .p(px(10.0))
            .child(bar(0.62, strong))
            .child(bar(0.88, line))
            .child(bar(0.76, line))
            .child(bar(0.52, line)),
    )
    .into_any_element()
}

/// The System card: light on the left, dark on the right. Each half is a
/// complete miniature clipped to its side, which is what makes the card read as
/// "whichever one the system is on".
fn miniature_split() -> AnyElement {
    div()
        .size_full()
        .flex()
        .flex_row()
        .child(
            div()
                .w_1_2()
                .h_full()
                .overflow_hidden()
                .child(miniature(&Theme::light(), Corners::Left)),
        )
        .child(
            div()
                .w_1_2()
                .h_full()
                .overflow_hidden()
                .child(miniature(&Theme::dark(), Corners::Right)),
        )
        .into_any_element()
}

/// The preview graphic for a mode.
///
/// The one place `Theme::light()`/`Theme::dark()` are legitimately built outside
/// the installed global: a preview has to show the palette you are *not* using.
fn preview(mode: AppearanceMode) -> AnyElement {
    match mode {
        AppearanceMode::System => miniature_split(),
        AppearanceMode::Light => miniature(&Theme::light(), Corners::All),
        AppearanceMode::Dark => miniature(&Theme::dark(), Corners::All),
    }
}

/// Helper copy under the picker.
fn helper(mode: AppearanceMode, system: Appearance) -> SharedString {
    match mode {
        // Naming the resolved appearance makes "System" concrete — otherwise the
        // card says nothing about what you actually get right now.
        AppearanceMode::System => {
            let resolved = if system.is_dark() { "dark" } else { "light" };
            format!(
                "Following the system appearance — currently {resolved}. Comet switches with \
                 macOS, including scheduled changes."
            )
            .into()
        }
        AppearanceMode::Light => "Always light, whatever the system is set to.".into(),
        AppearanceMode::Dark => "Always dark, whatever the system is set to.".into(),
    }
}

impl Render for AppearancePage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let current = appearance::mode(cx);
        let system = cx
            .try_global::<appearance::AppearanceState>()
            .map(|state| state.system)
            .unwrap_or_default();
        let effective_font = typography::effective(cx);
        let requested_font = typography::requested(cx);
        let availability = typography::availability(cx);
        let fixed = theme.font_sans_fixed.clone();

        let cards = AppearanceMode::ALL.into_iter().map(|mode| {
            widgets::option_card(&theme, mode.label(), mode == current, preview(mode))
                .id(SharedString::from(format!("appearance-{}", mode.label())))
                .on_click(cx.listener(move |_, _, _, cx| {
                    appearance::set_mode(mode, cx);
                    cx.notify();
                }))
        });

        let font_rows: Vec<AnyElement> = UiFontFamily::ALL
            .into_iter()
            .enumerate()
            .map(|(ix, family)| {
                let selected = family == self.selected_font;
                let available = availability.is_available(family);
                let is_current = family == effective_font;
                div()
                    .id(("interface-font-option", ix))
                    .w_full()
                    .min_h(px(62.0))
                    .px(px(14.0))
                    .py(px(10.0))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(16.0))
                    .rounded(px(10.0))
                    .border_1()
                    .border_color(if selected { theme.accent } else { theme.border })
                    .bg(if selected {
                        theme.accent.opacity(0.055)
                    } else {
                        crate::theme::ink(0.02)
                    })
                    .font_family(fixed.clone())
                    .when(available, |row| {
                        row.cursor_pointer()
                            .hover(|s| s.bg(crate::theme::ink(0.055)))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.selected_font = family;
                                window.focus(&this.font_focus, cx);
                                cx.notify();
                            }))
                    })
                    .when(!available, |row| row.opacity(0.45))
                    .child(
                        div()
                            .w(px(188.0))
                            .flex_none()
                            .flex()
                            .flex_col()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .text_size(px(13.0))
                                    .font_weight(gpui::FontWeight::MEDIUM)
                                    .text_color(theme.text)
                                    .child(SharedString::from(family.label())),
                            )
                            .child(
                                div()
                                    .text_size(px(10.5))
                                    .text_color(theme.text_faint)
                                    .child(SharedString::from(if !available {
                                        "Unavailable"
                                    } else if is_current {
                                        "Current"
                                    } else {
                                        "Preview"
                                    })),
                            ),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_row()
                            .items_baseline()
                            .gap(px(14.0))
                            .font_family(family.family_name())
                            .text_size(px(15.0))
                            .text_color(theme.text)
                            .child(SharedString::from("Aa Bb Il1 O0 rn/m 0123"))
                            .child(
                                div()
                                    .flex_none()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(SharedString::from("Semibold")),
                            )
                            .child(
                                div()
                                    .flex_none()
                                    .italic()
                                    .child(SharedString::from("Italic")),
                            ),
                    )
                    .child(
                        div()
                            .w(px(18.0))
                            .flex_none()
                            .text_size(px(13.0))
                            .text_color(if selected {
                                theme.accent
                            } else {
                                gpui::transparent_black()
                            })
                            .child(SharedString::from("✓")),
                    )
                    .into_any_element()
            })
            .collect();

        let can_apply = can_confirm(self.selected_font, effective_font, availability);
        let apply_button = popover::btn_primary(&theme, "Apply font")
            .id("apply-interface-font")
            .font_family(fixed.clone())
            .when(can_apply, |button| {
                button.on_click(cx.listener(|this, _, _, cx| this.commit_font(cx)))
            })
            .when(!can_apply, |button| button.opacity(0.45));
        let reset_button = popover::btn_ghost(&theme, "Reset to Geist", "reset-interface-font")
            .id("reset-interface-font")
            .font_family(fixed.clone())
            .on_click(cx.listener(|this, _, _, cx| this.reset_font(cx)));

        div()
            .id("appearance-page")
            .size_full()
            .overflow_y_scroll()
            .child(
                widgets::page_column()
                    .child(widgets::page_header(&theme, "Appearance", None))
                    .child(
                        widgets::page_subtitle(
                            &theme,
                            "How comet picks between light and dark. This setting stays on this \
                             device.",
                        )
                        .max_w(px(512.0))
                        .line_height(px(20.0)),
                    )
                    .child(
                        div()
                            .mt(px(32.0))
                            .flex()
                            .flex_col()
                            .gap(px(12.0))
                            .child(widgets::field_label(&theme, "Theme"))
                            .child(widgets::option_card_row().children(cards)),
                    )
                    .child(
                        div()
                            .mt(px(16.0))
                            .text_size(px(12.0))
                            .text_color(theme.text_muted)
                            .line_height(px(18.0))
                            .child(helper(current, system)),
                    )
                    .child(
                        div()
                            .mt(px(36.0))
                            .flex()
                            .flex_col()
                            .gap(px(10.0))
                            .font_family(fixed.clone())
                            .track_focus(&self.font_focus)
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|this, _, window, cx| {
                                    window.focus(&this.font_focus, cx);
                                }),
                            )
                            .on_key_down(cx.listener(
                                |this, event: &KeyDownEvent, _, cx| {
                                    this.on_font_key_down(event, cx)
                                },
                            ))
                            .child(widgets::field_label(&theme, "Interface font"))
                            .child(
                                div()
                                    .max_w(px(600.0))
                                    .text_size(px(12.0))
                                    .line_height(px(18.0))
                                    .text_color(theme.text_muted)
                                    .child(SharedString::from(
                                        "Used across the interface and conversations. Code, diffs, and terminal keep their current fonts.",
                                    )),
                            )
                            .child(
                                div()
                                    .mt(px(4.0))
                                    .flex()
                                    .flex_col()
                                    .gap(px(8.0))
                                    .children(font_rows),
                            )
                            .child(
                                div()
                                    .mt(px(4.0))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(8.0))
                                    .child(apply_button)
                                    .child(reset_button)
                                    .child(
                                        div()
                                            .ml(px(4.0))
                                            .text_size(px(11.5))
                                            .text_color(theme.text_faint)
                                            .child(font_status(effective_font)),
                                    ),
                            )
                            .when(requested_font != effective_font, |section| {
                                section.child(
                                    widgets::error_strip(
                                        &theme,
                                        "This font could not be loaded. Comet is using Geist.",
                                    )
                                    .font_family(fixed.clone()),
                                )
                            }),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mode_gets_a_card() {
        assert_eq!(AppearanceMode::ALL.len(), 3);
        for mode in AppearanceMode::ALL {
            assert!(!mode.label().is_empty());
        }
    }

    #[test]
    fn system_helper_names_the_resolved_appearance() {
        let dark = helper(AppearanceMode::System, Appearance::Dark);
        let light = helper(AppearanceMode::System, Appearance::Light);
        assert!(dark.contains("currently dark"), "got {dark}");
        assert!(light.contains("currently light"), "got {light}");
    }

    /// The pinned modes must not claim to follow anything — that copy is the only
    /// thing telling the user the system setting is being ignored.
    #[test]
    fn pinned_helpers_do_not_mention_following() {
        for mode in [AppearanceMode::Light, AppearanceMode::Dark] {
            for system in [Appearance::Light, Appearance::Dark] {
                let copy = helper(mode, system).to_lowercase();
                assert!(!copy.contains("following"), "{mode:?}: {copy}");
                assert!(copy.contains("whatever the system"), "{mode:?}: {copy}");
            }
        }
    }

    /// The previews must differ from each other, or the picker is decoration.
    /// Comparing the tones they are built from is the closest we can get without
    /// a renderer.
    #[test]
    fn light_and_dark_previews_draw_from_different_palettes() {
        let (l, d) = (Theme::light(), Theme::dark());
        assert_ne!(l.surface.l, d.surface.l);
        assert_ne!(l.bg.l, d.bg.l);
    }

    #[test]
    fn font_options_appear_once_in_stable_order() {
        let labels = UiFontFamily::ALL.map(UiFontFamily::label);
        assert_eq!(labels.len(), 5);
        assert_eq!(
            labels,
            [
                "Geist",
                "Geist Mono",
                "System UI",
                "Inter",
                "Atkinson Hyperlegible Next"
            ]
        );
        let unique = labels.into_iter().collect::<std::collections::HashSet<_>>();
        assert_eq!(unique.len(), 5);
    }

    #[test]
    fn font_keyboard_navigation_stops_at_edges_and_skips_unavailable() {
        let all = FontAvailability::all();
        assert_eq!(step_font(UiFontFamily::Geist, -1, all), UiFontFamily::Geist);
        assert_eq!(
            step_font(UiFontFamily::AtkinsonHyperlegibleNext, 1, all),
            UiFontFamily::AtkinsonHyperlegibleNext
        );
        let without_inter = all.without(UiFontFamily::Inter);
        assert_eq!(
            step_font(UiFontFamily::System, 1, without_inter),
            UiFontFamily::AtkinsonHyperlegibleNext
        );
    }

    #[test]
    fn unavailable_or_current_font_cannot_be_confirmed() {
        let without_inter = FontAvailability::all().without(UiFontFamily::Inter);
        assert!(!can_confirm(
            UiFontFamily::Inter,
            UiFontFamily::Geist,
            without_inter
        ));
        assert!(!can_confirm(
            UiFontFamily::Geist,
            UiFontFamily::Geist,
            FontAvailability::all()
        ));
        assert!(font_status(UiFontFamily::Geist).contains("Current: Geist"));
    }
}
