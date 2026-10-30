use super::tests::composer_focus_window;
use super::*;

fn ink_bottom(input: &ComposerInput) -> f32 {
    input.ink_extent.map_or(0.0, |(_, bottom)| bottom)
}

impl ComposerInput {
    fn tested_fade_edges(&self, visible: f32) -> (bool, bool) {
        self.fade_edges(
            self.settled_viewport_height
                .unwrap_or(TEXTAREA_MAX - TEXTAREA_PAD_V),
            visible,
        )
    }
}

fn last_written_row_bottom(input: &ComposerInput) -> f32 {
    let display = input.projection.display.trim_end();
    let start = display.grapheme_indices(true).next_back().unwrap().0;
    input
        .bounds_for_display_range(start..display.len())
        .into_iter()
        .map(|bounds| f32::from(bounds.bottom()))
        .fold(0.0, f32::max)
}

#[gpui::test]
fn fade_extent_handles_unicode_and_whitespace_suffixes(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                for ending in ["e\u{301}", "👩🏽‍💻", "日本語", "مرحبا", "אבג", "a\u{200b}"]
                {
                    let written = format!("first\r\nsecond\r\nfinal {ending}");
                    for width in [24.0, 73.0, 140.0, 600.0] {
                        input.set_text(written.clone(), cx);
                        input.layout_text(px(width), &window.text_style(), window, cx);
                        let expected = input.content_height;
                        for suffix in ["", "\n", "\r\n", "\n \t\n\u{2003}", "\u{a0}\u{2003}\n"] {
                            input.set_text(format!("{written}{suffix}"), cx);
                            input.layout_text(px(width), &window.text_style(), window, cx);
                            assert_eq!(
                                ink_bottom(input),
                                last_written_row_bottom(input),
                                "ending {ending:?}, width {width}, suffix {suffix:?}"
                            );
                            // A no-break space can reflow the preceding word;
                            // explicit newline suffixes cannot move its glyphs.
                            if suffix.is_empty() || suffix.starts_with(['\n', '\r']) {
                                assert_eq!(ink_bottom(input), expected);
                            }
                            assert!(input.content_height >= ink_bottom(input));
                        }
                    }
                }
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_extent_follows_projected_mentions_and_active_source(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                let link = local_file_link("src/synthetic-long-file-name.rs", false);
                let written = format!("Review\n- nested text {}\nFinal {}", link, link);
                for width in [48.0, 140.0, 600.0] {
                    for caret in [0, written.len() - 4] {
                        input.set_text(written.clone(), cx);
                        input.move_to(caret, cx);
                        input.layout_text(px(width), &window.text_style(), window, cx);
                        // A chip's trailing NBSP can wrap its background onto a
                        // separate row; that padding is not hidden written text.
                        let expected = last_written_row_bottom(input);
                        let projection = input.projection.display.clone();
                        for suffix in ["\n", "\n\n\n", "\n\t \u{2003}"] {
                            let draft = format!("{written}{suffix}");
                            input.set_text(draft.clone(), cx);
                            input.move_to(caret, cx);
                            input.layout_text(px(width), &window.text_style(), window, cx);
                            assert_eq!(input.projection.display.trim_end(), projection.trim_end());
                            assert_eq!(
                                ink_bottom(input),
                                expected,
                                "width {width}, caret {caret}, suffix {suffix:?}"
                            );
                            assert_eq!(input.text(), draft);
                        }
                    }
                }
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_extent_updates_through_edits_undo_redo_and_clear(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                let draft = format!("{}\n\n", vec!["synthetic row"; 11].join("\n"));
                input.set_text(draft.clone(), cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                let expected = ink_bottom(input);
                input.replace_text_in_range(None, "new final row", window, cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                assert_eq!(ink_bottom(input), input.content_height);
                assert!(ink_bottom(input) > expected);
                input.undo(&Undo, window, cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                assert_eq!(input.text(), draft);
                assert_eq!(ink_bottom(input), expected);
                input.redo(&Redo, window, cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                assert_eq!(ink_bottom(input), input.content_height);
                input.select_all(&SelectAll, window, cx);
                input.backspace(&Backspace, window, cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                assert!(input.display_is_placeholder);
                assert_eq!(ink_bottom(input), 0.0);
                assert_eq!(input.tested_fade_edges(22.75), (false, false));
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_extent_rewraps_with_width_and_text_metrics(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                let written = vec!["synthetic words"; 30].join(" ");
                for line_height in [18.5, INPUT_LINE_HEIGHT, 31.0] {
                    input.configured_line_height = line_height;
                    for width in [600.0, 73.0, 240.0, 600.0] {
                        input.set_text(written.clone(), cx);
                        input.layout_text(px(width), &window.text_style(), window, cx);
                        let expected = input.content_height;
                        input.set_text(format!("{written}\n\n"), cx);
                        input.layout_text(px(width), &window.text_style(), window, cx);
                        assert_eq!(ink_bottom(input), expected);
                        assert_eq!(input.content_height, expected + 2.0 * line_height);
                        let rebuilds = input.layout_rebuilds;
                        input.scroll_top = line_height;
                        input.viewport_height = Some(45.5);
                        input.resizing = true;
                        input.layout_text(px(width), &window.text_style(), window, cx);
                        assert_eq!(ink_bottom(input), expected);
                        assert_eq!(
                            input.layout_rebuilds, rebuilds,
                            "viewport changes reuse shaping"
                        );
                    }
                }
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_blank_only_drafts_keep_their_scroll_extent(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                for draft in [
                    "\n".repeat(20),
                    " \t\u{2003}\n".repeat(20),
                    " ".repeat(2000),
                ] {
                    input.set_text(draft.clone(), cx);
                    input.layout_text(px(140.0), &window.text_style(), window, cx);
                    input.settled_viewport_height = Some(45.5);
                    input.clamp_scroll(45.5);
                    assert_eq!(ink_bottom(input), 0.0);
                    assert_eq!(input.scroll_top, (input.content_height - 45.5).max(0.0));
                    assert!(!input.tested_fade_edges(45.5).1);
                    assert_eq!(input.text(), draft);
                }
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_top_clip_uses_visible_height_without_a_settled_budget(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                input.set_text("first\nsecond\nthird", cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                let line = f32::from(input.line_height);
                input.settled_viewport_height = None;
                input.scroll_top = line;
                input.overflow_top_padding = 8.0;
                let bounds = Bounds::new(point(px(10.0), px(50.0)), size(px(400.0), px(line)));
                let painted = input.paint_bounds(bounds);
                assert_eq!(
                    painted.top(),
                    px(42.0),
                    "scroll clipping must retain the existing top inset"
                );
                assert_eq!(painted.bottom(), bounds.bottom());
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_extent_includes_the_final_glyph_at_rich_wrap_boundaries(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                for written in [
                    "- **synthetic** abcdefghijklmnop X".to_string(),
                    format!(
                        "- reference {} X",
                        local_file_link("synthetic_reference.rs", false)
                    ),
                ] {
                    let mut boundary_cases = 0;
                    for width in (20..=200).step_by(2) {
                        input.set_text(format!("{written}\n\n"), cx);
                        input.layout_text(px(width as f32), &window.text_style(), window, cx);
                        let trimmed = input.projection.display.trim_end();
                        let last = trimmed.grapheme_indices(true).next_back().unwrap().0;
                        let on_boundary = input.last_lines.iter().enumerate().any(|(i, line)| {
                            line.wrap_boundaries().iter().any(|boundary| {
                                input.line_starts[i]
                                    + line.runs()[boundary.run_ix].glyphs[boundary.glyph_ix].index
                                    == last
                            })
                        });
                        if !on_boundary {
                            continue;
                        }
                        boundary_cases += 1;
                        let extent = last_written_row_bottom(input);
                        assert_eq!(ink_bottom(input), extent);
                        let viewport = 2.0 * f32::from(input.line_height);
                        if extent > viewport + 1.25 {
                            input.settled_viewport_height = Some(viewport);
                            input.scroll_top = extent - viewport;
                            assert!(!input.tested_fade_edges(viewport).1);
                            input.scroll_top -= 1.25;
                            assert!(
                                input.tested_fade_edges(viewport).1,
                                "hidden final glyph still needs its fade"
                            );
                        }
                    }
                    assert!(
                        boundary_cases > 0,
                        "the width sweep must exercise an exact wrap boundary: {written}"
                    );
                }
            });
        })
        .unwrap();
}

#[gpui::test]
fn fade_edges_preserve_real_overflow_and_animation_guards(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = composer_focus_window(cx);
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                input.set_text(format!("{}\n\n", vec!["synthetic row"; 11].join("\n")), cx);
                input.layout_text(px(400.0), &window.text_style(), window, cx);
                input.settled_viewport_height = Some(240.0);
                let end = ink_bottom(input) - 240.0;
                for (offset, bottom) in [
                    (0.0, true),
                    (end - 1.25, true),
                    (end - 1.0, false),
                    (end, false),
                    (end + 10.0, false),
                ] {
                    input.scroll_top = offset;
                    assert_eq!(input.tested_fade_edges(240.0), (offset > 1.0, bottom));
                }
                // A genuine nonblank overflow can fade during its reveal, but
                // fitting text must not acquire a fade from the animated budget.
                input.settled_viewport_height = Some(input.content_height);
                for visible in [0.0, 20.0, 100.0, 240.0] {
                    input.scroll_top = 0.0;
                    assert!(!input.tested_fade_edges(visible).1);
                }
            });
        })
        .unwrap();
}
