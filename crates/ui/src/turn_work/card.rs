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
        .when(changes.additions > 0 || changes.deletions > 0, |el| {
            el.child(
                div()
                    .debug_selector(|| "turn-changes-counts".into())
                    .flex_none()
                    .max_w_full()
                    .flex()
                    .flex_wrap()
                    .gap(px(6.0))
                    .font_family(theme.font_mono.clone())
                    .text_size(crate::typography::ui_rems(12.0))
                    .child(
                        div()
                            .debug_selector(|| "turn-changes-additions".into())
                            .max_w_full()
                            .text_color(theme.success)
                            .child(SharedString::from(format!("+{}", changes.additions))),
                    )
                    .child(
                        div()
                            .debug_selector(|| "turn-changes-deletions".into())
                            .max_w_full()
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
        showing: bool,
        clicks: std::rc::Rc<std::cell::Cell<usize>>,
    }

    impl gpui::Render for CueFixture {
        fn render(
            &mut self,
            window: &mut gpui::Window,
            cx: &mut gpui::Context<Self>,
        ) -> impl IntoElement {
            window.set_rem_size(px(self.rem_size));
            let clicks = self.clicks.clone();
            div().p(px(200.0)).child(
                div()
                    .relative()
                    .w(px(self.width))
                    .h(px(60.0))
                    .debug_selector(|| "fixture-composer".into())
                    .child(changes_cue(
                        &self.changes,
                        self.showing,
                        crate::theme::Theme::of(cx),
                        move |_, _, _| clicks.set(clicks.get() + 1),
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
                showing: width >= 600.0,
                clicks: Default::default(),
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

    fn fixture(
        width: f32,
        rem_size: f32,
        files: Vec<String>,
        additions: u64,
        deletions: u64,
        showing: bool,
    ) -> CueFixture {
        CueFixture {
            width,
            rem_size,
            showing,
            changes: TurnChanges {
                files,
                additions,
                deletions,
            },
            clicks: Default::default(),
        }
    }

    fn assert_layout(cx: &mut gpui::VisualTestContext, counts: bool) {
        cx.update(|window, cx| window.draw(cx).clear());
        let card = cx.debug_bounds("turn-changes-card").unwrap();
        let composer = cx.debug_bounds("fixture-composer").unwrap();
        assert_eq!(
            card.bottom(),
            composer.top() - px(crate::theme::Theme::SPACE_SM)
        );
        assert!(card.left() >= composer.left() && card.right() <= composer.right());
        let mut content = vec![
            "turn-changes-title",
            "turn-changes-names",
            "turn-changes-review",
        ];
        if counts {
            content.extend([
                "turn-changes-counts",
                "turn-changes-additions",
                "turn-changes-deletions",
            ]);
        } else {
            assert!(
                cx.debug_bounds("turn-changes-counts").is_none(),
                "zero counts must not reserve space"
            );
        }
        for selector in content {
            let bounds = cx.debug_bounds(selector).unwrap();
            assert!(
                bounds.left() >= card.left() + px(4.0) && bounds.right() <= card.right() - px(4.0),
                "{selector} {bounds:?} escapes card {card:?} horizontally"
            );
            assert!(
                bounds.top() >= card.top() + px(4.0) && bounds.bottom() <= card.bottom() - px(4.0),
                "{selector} {bounds:?} escapes card {card:?} vertically"
            );
        }
        // Independent content must not overlap even when it moves to another row.
        let mut leaves = vec![
            "turn-changes-title",
            "turn-changes-names",
            "turn-changes-review",
        ];
        if counts {
            leaves.extend(["turn-changes-additions", "turn-changes-deletions"]);
        }
        for (index, first) in leaves.iter().enumerate() {
            let a = cx.debug_bounds(first).unwrap();
            for second in &leaves[index + 1..] {
                let b = cx.debug_bounds(second).unwrap();
                assert!(
                    a.right() <= b.left()
                        || b.right() <= a.left()
                        || a.bottom() <= b.top()
                        || b.bottom() <= a.top(),
                    "{first} {a:?} overlaps {second} {b:?}"
                );
            }
        }
    }

    #[gpui::test]
    fn changes_card_fits_every_interface_size_and_narrow_width(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        for width in [120.0, 144.0, 176.0, 260.0, 600.0] {
            for font in crate::typography::UiFontSize::ALL {
                for showing in [false, true] {
                    for (added, removed) in [(0, 0), (12, 3)] {
                        let (_, visual) = cx.add_window_view(move |_, _| {
                            fixture(
                                width,
                                font.pixels(),
                                vec!["src/example.md".into()],
                                added,
                                removed,
                                showing,
                            )
                        });
                        assert_layout(visual, added > 0 || removed > 0);
                    }
                }
            }
        }
    }

    #[gpui::test]
    fn changes_card_keeps_large_and_one_sided_counts_inside(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        for width in [144.0, 176.0, 260.0] {
            for (added, removed) in [
                (999_999_999, 0),
                (0, 999_999_999),
                (999_999_999_999_999_999, 999_999_999_999_999_999),
            ] {
                let (_, visual) = cx.add_window_view(move |_, _| {
                    fixture(
                        width,
                        20.0,
                        vec!["src/example.md".into()],
                        added,
                        removed,
                        true,
                    )
                });
                assert_layout(visual, true);
            }
        }
    }

    #[gpui::test]
    fn changes_card_handles_maximum_counts_without_overflow(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        let (_, visual) = cx.add_window_view(|_, _| {
            fixture(
                176.0,
                20.0,
                vec!["src/example.md".into()],
                u64::MAX,
                u64::MAX,
                false,
            )
        });
        assert_layout(visual, true);
    }

    #[gpui::test]
    fn changes_card_wraps_long_unicode_and_many_file_names(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        for files in [
            vec![format!("src/{}.rs", "long_unbroken_filename".repeat(5))],
            vec![
                "src/日本語のファイル名.rs".into(),
                "src/cafe\u{301}_😀_résumé.md".into(),
                "src/with spaces and words.md".into(),
            ],
            (0..100)
                .map(|n| format!("src/synthetic_file_{n}.rs"))
                .collect(),
        ] {
            for width in [144.0, 176.0, 260.0] {
                let files = files.clone();
                let (_, visual) =
                    cx.add_window_view(move |_, _| fixture(width, 20.0, files, 1, 1, false));
                assert_layout(visual, true);
            }
        }
    }

    #[gpui::test]
    fn changes_card_reflows_after_width_font_and_state_changes(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        let (view, visual) = cx
            .add_window_view(|_, _| fixture(600.0, 16.0, vec!["src/first.rs".into()], 1, 1, false));
        for (width, rem_size, showing, count) in [
            (600.0, 16.0, false, 1),
            (144.0, 20.0, true, 999_999_999),
            (260.0, 12.0, false, 0),
            (600.0, 20.0, true, 1),
        ] {
            view.update(visual, |view, cx| {
                view.width = width;
                view.rem_size = rem_size;
                view.showing = showing;
                view.changes.additions = count;
                view.changes.deletions = count;
                view.changes.files = vec!["src/first.rs".into(), "src/second.rs".into()];
                cx.notify();
            });
            assert_layout(visual, count > 0);
        }
    }

    #[gpui::test]
    fn changes_card_review_and_body_click_once_without_composer_hit(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| cx.set_global(crate::theme::Theme::default()));
        for showing in [false, true] {
            let (view, visual) = cx.add_window_view(move |_, _| {
                fixture(260.0, 20.0, vec!["src/example.md".into()], 12, 3, showing)
            });
            assert_layout(visual, true);
            for (selector, expected) in [
                ("turn-changes-review", 1),
                ("turn-changes-title", 2),
                ("fixture-composer", 2),
            ] {
                let target = visual.debug_bounds(selector).unwrap();
                visual.simulate_click(target.center(), Default::default());
                view.read_with(visual, |view, _| assert_eq!(view.clicks.get(), expected,
                    "clicking {selector} must invoke the card exactly once, and not from the composer"));
            }
        }
    }
}
