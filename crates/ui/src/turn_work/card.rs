use super::TurnChanges;

/// The completed turn's changes cue. Shared by the shell and synthetic layout checks.
pub fn changes_cue(
    changes: &TurnChanges,
    showing: bool,
    theme: &crate::theme::Theme,
    on_click: impl Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + 'static,
) -> gpui::AnyElement {
    use crate::{
        icons::{self, icon},
        motion,
        theme::Theme,
    };
    use gpui::{SharedString, div, prelude::*, px};
    let card = div()
        .id("turn-changes-card")
        .debug_selector(|| "turn-changes-card".into())
        .role(gpui::Role::Button)
        .aria_label(format!("{}, show changes", changes.title()))
        .min_h(px(44.0))
        .py(px(Theme::SPACE_SM))
        .px(px(Theme::SPACE_MD))
        .flex()
        .flex_row()
        .flex_wrap()
        .items_center()
        .gap(px(Theme::SPACE_SM))
        .rounded(px(Theme::PANEL_RADIUS))
        .border_1()
        .border_color(theme.border)
        .bg(motion::hover_blend(
            "turn-changes-card",
            theme.surface_card,
            theme.surface_raised_hover,
        ))
        .on_hover(motion::hover_listener("turn-changes-card"))
        .shadow_sm()
        .cursor_pointer()
        .child(
            icon(icons::DOCUMENT)
                .size(px(16.0))
                .flex_none()
                .text_color(theme.accent),
        )
        .child(
            div()
                .flex_1()
                .min_w(crate::typography::ui_rems(64.0))
                .flex()
                .flex_col()
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(13.0))
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .text_color(theme.text)
                        .debug_selector(|| "turn-changes-title".into())
                        .child(SharedString::from(changes.title())),
                )
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted)
                        .debug_selector(|| "turn-changes-names".into())
                        .child(SharedString::from(changes.names())),
                ),
        )
        .when(changes.additions + changes.deletions > 0, |el| {
            el.child(
                div()
                    .debug_selector(|| "turn-changes-counts".into())
                    .flex_none()
                    .whitespace_nowrap()
                    .flex()
                    .gap(px(6.0))
                    .font_family(theme.font_mono.clone())
                    .text_size(crate::typography::ui_rems(12.0))
                    .child(
                        div()
                            .text_color(theme.success)
                            .child(SharedString::from(format!("+{}", changes.additions))),
                    )
                    .child(
                        div()
                            .text_color(theme.danger)
                            .child(SharedString::from(format!("-{}", changes.deletions))),
                    ),
            )
        })
        .child(
            div()
                .debug_selector(|| "turn-changes-review".into())
                .flex_none()
                .whitespace_nowrap()
                .min_h(px(24.0))
                .py(px(4.0))
                .px(px(8.0))
                .flex()
                .items_center()
                .rounded(px(Theme::CONTROL_RADIUS))
                .bg(if showing {
                    theme.accent_wash
                } else {
                    theme.surface_raised
                })
                .text_size(crate::typography::ui_rems(11.0))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(if showing {
                    theme.accent
                } else {
                    theme.text_muted
                })
                .child(SharedString::from(if showing {
                    "Showing"
                } else {
                    "Review"
                })),
        );
    div()
        .absolute()
        // Grow upward from the composer instead of overlapping it as text wraps.
        .bottom_full()
        .mb(px(Theme::SPACE_SM))
        .left(px(Theme::SPACE_SM))
        .right(px(Theme::SPACE_SM))
        .child(card.on_click(on_click))
        .into_any_element()
}

#[cfg(test)]
mod layout_tests {
    use super::*;
    use gpui::{div, prelude::*, px};

    struct CueFixture {
        width: f32,
        rem_size: f32,
        changes: TurnChanges,
    }

    impl gpui::Render for CueFixture {
        fn render(
            &mut self,
            window: &mut gpui::Window,
            cx: &mut gpui::Context<Self>,
        ) -> impl IntoElement {
            window.set_rem_size(px(self.rem_size));
            div().p(px(200.0)).child(
                div()
                    .relative()
                    .w(px(self.width))
                    .h(px(60.0))
                    .debug_selector(|| "fixture-composer".into())
                    .child(changes_cue(
                        &self.changes,
                        self.width >= 600.0,
                        crate::theme::Theme::of(cx),
                        |_, _, _| {},
                    )),
            )
        }
    }

    #[gpui::test]
    fn changes_card_contains_wrapped_content_above_composer(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        for (width, rem_size, counts) in [
            (176.0, 16.0, false),
            (260.0, 20.0, true),
            (600.0, 16.0, true),
        ] {
            let (_, cx) = cx.add_window_view(move |_, _| CueFixture {
                width,
                rem_size,
                changes: TurnChanges {
                    files: if counts {
                        vec![
                            "src/lexer.rs".into(),
                            "src/parser.rs".into(),
                            "src/empty_input.rs".into(),
                        ]
                    } else {
                        vec!["src/example.md".into()]
                    },
                    additions: if counts { 12345 } else { 0 },
                    deletions: if counts { 6789 } else { 0 },
                },
            });
            cx.update(|window, cx| window.draw(cx).clear());
            let card = cx.debug_bounds("turn-changes-card").unwrap();
            for selector in [
                "turn-changes-title",
                "turn-changes-names",
                "turn-changes-review",
            ]
            .into_iter()
            .chain(counts.then_some("turn-changes-counts"))
            {
                let content = cx.debug_bounds(selector).unwrap();
                assert!(
                    content.top() >= card.top() + px(4.0)
                        && content.bottom() <= card.bottom() - px(4.0),
                    "{selector} {content:?} escapes card {card:?} at width {width}, rem {rem_size}"
                );
                assert!(
                    content.left() >= card.left() && content.right() <= card.right(),
                    "{selector} escapes the card horizontally at width {width}, rem {rem_size}"
                );
            }
            let composer = cx.debug_bounds("fixture-composer").unwrap();
            assert_eq!(
                card.bottom(),
                composer.top() - px(crate::theme::Theme::SPACE_SM)
            );
        }
    }
}
