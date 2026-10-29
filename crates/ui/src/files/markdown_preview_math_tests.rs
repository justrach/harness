//! Exercise the actual file-preview lifecycle, not just the shared renderer.
use super::*;
use gpui::{TestAppContext, WindowHandle, point, size};

fn settle(cx: &mut TestAppContext, window: WindowHandle<MarkdownPreview>) {
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_secs(1));
    cx.run_until_parked();
    cx.update_window(window.into(), |_, window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    })
    .unwrap();
}

fn open(cx: &mut TestAppContext, source: &str, width: f32) -> WindowHandle<MarkdownPreview> {
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
    });
    let window = cx.open_window(size(px(width), px(600.)), |_, cx| {
        MarkdownPreview::new(
            "notes/Week 9 Lecture Notes.md".into(),
            Rc::new(|_, _, _| {}),
            cx,
        )
    });
    window
        .update(cx, |view, _, cx| view.set_source(source.into(), false, cx))
        .unwrap();
    settle(cx, window);
    window
}

fn entries(
    cx: &mut TestAppContext,
    window: WindowHandle<MarkdownPreview>,
) -> Vec<(String, String, gpui::Bounds<gpui::Pixels>)> {
    let scope = window.update(cx, |view, _, _| view.scope.clone()).unwrap();
    render::selection_test_entries()
        .into_iter()
        .filter(|(key, _, _)| key.starts_with(&scope))
        .collect()
}

#[gpui::test]
fn file_preview_math_delimiters_typeset_and_keep_latex_for_copy(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    for (source, copied) in [
        (r"Inline $\frac{1}{n}$ tail.", r"$\frac{1}{n}$"),
        (r"Inline \(\frac{1}{n}\) tail.", r"$\frac{1}{n}$"),
        (r"$$\frac{1}{n}$$", "\n$$\\frac{1}{n}$$\n"),
        (r"\[\frac{1}{n}\]", "\n$$\\frac{1}{n}$$\n"),
    ] {
        let window = open(cx, source, 320.);
        let entries = entries(cx, window);
        let equation = entries.iter().find(|(_, text, _)| text == copied).unwrap();
        assert!(
            equation.2.size.height > px(20.),
            "stacked fraction must have native equation geometry: {source}: {entries:?}"
        );
        assert!(
            equation.2.size.width < px(70.),
            "a source string must not masquerade as typeset math: {source}: {entries:?}"
        );
        assert!(equation.2.left() >= px(24.) && equation.2.right() <= px(296.));
    }
}

#[gpui::test]
fn file_preview_math_keeps_currency_code_and_unsupported_tex_literal(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = "Price $5 and $10; code `$x^2$`.\n\n```latex\n\\frac{a}{b}\n```\n\nValid $x^2$; unsupported $\\unsupported{x}$.";
    let window = open(cx, source, 480.);
    let entries = entries(cx, window);
    let text: String = entries.iter().map(|(_, text, _)| text.as_str()).collect();
    assert!(
        text.contains("Price $5 and $10; code $x^2$."),
        "{entries:?}"
    );
    assert!(text.contains(r"\frac{a}{b}"));
    assert!(text.contains(r"$\unsupported{x}$"));
    assert!(
        entries
            .iter()
            .any(|(_, text, bounds)| text == "$x^2$" && bounds.size.width < px(50.))
    );
    window
        .update(cx, |view, _, _| {
            assert_eq!(view.parsed_source.as_ref(), source);
            assert!(matches!(view.tree.blocks[1].block, Block::CodeBlock { .. }));
        })
        .unwrap();
}

#[gpui::test]
fn file_preview_math_reparse_discards_stale_equations_and_selection(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let window = open(cx, r"Old $\frac{1}{n}$.", 320.);
    let old = entries(cx, window)
        .into_iter()
        .find(|(_, text, _)| text == r"$\frac{1}{n}$")
        .unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position: old.2.center(),
                click_count: 3,
                ..Default::default()
            }),
            cx,
        );
    })
    .unwrap();
    assert!(crate::markdown::selection::selected_text().is_some());
    window
        .update(cx, |view, _, cx| {
            view.set_source(r"Intermediate $x^2$.".into(), false, cx);
            view.set_source(r"Final $\sqrt{a+b}$.".into(), false, cx);
        })
        .unwrap();
    // A settled old frame remains visible during the parsing debounce; its
    // active selection must still clear immediately when the buffer changes.
    assert!(crate::markdown::selection::selected_text().is_none());
    settle(cx, window);
    let entries = entries(cx, window);
    assert!(entries.iter().any(|(_, text, _)| text == r"$\sqrt{a+b}$"));
    assert!(
        !entries.iter().any(|(_, text, _)| text.contains("frac")
            || text.contains("x^2")
            || text.contains("Old"))
    );
    window
        .update(cx, |view, _, _| {
            assert_eq!(view.parsed_source.as_ref(), r"Final $\sqrt{a+b}$.");
            assert!(!view.loading);
        })
        .unwrap();
}

#[gpui::test]
fn file_preview_source_byte_limit_preserves_utf8_and_truncation_state(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let view = cx.new(|cx| MarkdownPreview::new("Boundary.md".into(), Rc::new(|_, _, _| {}), cx));
    // Parse at the real byte limit without asking the native text shaper to
    // lay out a multi-megabyte unbroken word.
    for (source, flag, expected_len, expected_truncated) in [
        (
            "a".repeat(MAX_MARKDOWN_BYTES),
            false,
            MAX_MARKDOWN_BYTES,
            false,
        ),
        (
            format!("{}🦀", "a".repeat(MAX_MARKDOWN_BYTES - 1)),
            false,
            MAX_MARKDOWN_BYTES - 1,
            true,
        ),
        ("Short $x$.".into(), true, "Short $x$.".len(), true),
        ("Short $y$.".into(), false, "Short $y$.".len(), false),
    ] {
        let expected = source[..expected_len].to_string();
        view.update(cx, |view, cx| view.set_source(source, flag, cx));
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.run_until_parked();
        view.read_with(cx, |view, _| {
            assert_eq!(view.parsed_source.len(), expected_len);
            assert!(view.parsed_source.as_ref() == expected);
            assert_eq!(view.truncated, expected_truncated);
            assert!(!view.loading);
            assert_eq!(view.parsed_epoch, view.epoch);
        });
    }
}

#[gpui::test]
fn file_preview_clipped_math_does_not_invent_a_closing_delimiter(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let view = cx.new(|cx| MarkdownPreview::new("Boundary.md".into(), Rc::new(|_, _, _| {}), cx));
    let source = format!("{}\n\n$x^2$", "a".repeat(MAX_MARKDOWN_BYTES - 5));
    view.update(cx, |view, cx| view.set_source(source, false, cx));
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_secs(1));
    cx.run_until_parked();
    view.read_with(cx, |view, _| {
        assert!(view.truncated);
        assert_eq!(view.parsed_source.len(), MAX_MARKDOWN_BYTES);
        assert!(view.parsed_source.ends_with("\n\n$x^"));
        let Block::Paragraph { runs } = &view.tree.blocks.last().unwrap().block else {
            panic!("missing clipped paragraph");
        };
        assert!(runs.iter().all(|run| run.style.math.is_none()));
        assert_eq!(
            runs.iter().map(|run| run.text.as_str()).collect::<String>(),
            "$x^"
        );
    });
}

#[gpui::test]
fn file_preview_empty_replacement_resets_scrolled_math_and_can_render_again(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = format!(
        "# Start\n\n{}## Target\n\n$\\frac{{1}}{{n}}$\n\n{}",
        "Filler $x$.\n\n".repeat(40),
        "Tail paragraph.\n\n".repeat(40)
    );
    let window = open(cx, &source, 320.);
    window
        .update(cx, |view, _, cx| view.request_anchor("target".into(), cx))
        .unwrap();
    settle(cx, window);
    assert!(
        entries(cx, window)
            .iter()
            .any(|(_, text, _)| text == r"$\frac{1}{n}$")
    );
    window
        .update(cx, |view, _, cx| {
            assert!(view.list.logical_scroll_top().item_ix > 0);
            view.set_source(String::new(), false, cx);
        })
        .unwrap();
    settle(cx, window);
    assert!(entries(cx, window).is_empty());
    window
        .update(cx, |view, _, cx| {
            assert!(view.tree.is_empty() && view.anchors.is_empty());
            assert!(view.parsed_source.is_empty());
            assert!(!view.loading);
            view.set_source("# Fresh\n\n$\\frac{7}{q}$".into(), false, cx);
        })
        .unwrap();
    settle(cx, window);
    assert!(
        entries(cx, window)
            .iter()
            .any(|(_, text, bounds)| text == r"$\frac{7}{q}$" && bounds.size.height > px(20.))
    );
}

#[gpui::test]
fn file_preview_resume_replaces_cancelled_math_and_uses_only_the_new_anchor(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let window = open(cx, "# Old\n\n$z$", 320.);
    let source = format!(
        "# Resume\n\n{}## Final target\n\n$\\frac{{7}}{{q}}$\n\n{}",
        "Filler $x$.\n\n".repeat(40),
        "Tail paragraph.\n\n".repeat(40)
    );
    window
        .update(cx, |view, _, cx| {
            view.set_source("# Cancelled\n\n$\\frac{1}{n}$".into(), false, cx);
            view.request_anchor("cancelled".into(), cx);
            view.suspend(cx);
        })
        .unwrap();
    settle(cx, window);
    assert!(entries(cx, window).is_empty());
    window
        .update(cx, |view, _, cx| {
            assert!(view.suspended && view.pending_anchor.is_none());
            view.activate(
                "notes/Week 9 Lecture Notes.md",
                &(None, "synthetic-checkout".into()),
                cx,
            );
            view.set_source(source, false, cx);
            view.request_anchor("final-target".into(), cx);
        })
        .unwrap();
    settle(cx, window);
    let visible = entries(cx, window);
    assert!(visible.iter().any(|(_, text, _)| text == r"$\frac{7}{q}$"));
    assert!(
        !visible
            .iter()
            .any(|(_, text, _)| text.contains("Cancelled") || text.contains("frac{1}"))
    );
    window
        .update(cx, |view, _, _| {
            assert!(!view.suspended && !view.loading);
            assert!(view.pending_anchor.is_none());
            assert_eq!(view.parsed_epoch, view.epoch);
        })
        .unwrap();
}

#[gpui::test]
fn file_preview_reference_links_with_spaced_filenames_open_from_native_clicks(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    for label in [
        "[Week 9 formulas][review]",
        "[Week 9 formulas][]",
        "[Week 9 formulas]",
    ] {
        let reference = if label.contains("[review]") {
            "review"
        } else {
            "Week 9 formulas"
        };
        let source = format!(
            "Read {label} beside $x_i$.\n\n[{reference}]: <../Revision%20Notes/Cheatsheet.md#standard-error> \"Review formulas\""
        );
        let window = open(cx, &source, 320.);
        let opened = Rc::new(RefCell::new(Vec::new()));
        window
            .update(cx, |view, _, _| {
                let opened = opened.clone();
                view.open_file =
                    Rc::new(move |path, anchor, _| opened.borrow_mut().push((path, anchor)));
            })
            .unwrap();
        settle(cx, window);
        let visible = entries(cx, window);
        let link = visible
            .iter()
            .find(|(_, text, _)| text.trim() == "formulas")
            .unwrap_or_else(|| panic!("missing reference label: {label}: {visible:?}"));
        cx.update_window(window.into(), |_, window, cx| {
            let position = link.2.center();
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position,
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                    button: gpui::MouseButton::Left,
                    position,
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                    button: gpui::MouseButton::Left,
                    position,
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
        })
        .unwrap();
        assert_eq!(
            &*opened.borrow(),
            &[(
                "Revision Notes/Cheatsheet.md".into(),
                Some("standard-error".into())
            )],
            "reference links must use the file route and preserve their section: {label}"
        );
    }
}

#[gpui::test]
fn file_preview_relative_notes_link_then_cheatsheet_uses_math_preview(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let window = open(
        cx,
        "[Week 9 Lecture Notes](Cheat%73heet.md#fractions)",
        480.,
    );
    let opened = Rc::new(RefCell::new(Vec::new()));
    let ui = window
        .update(cx, |view, _, cx| {
            let observed = opened.clone();
            view.open_file = Rc::new(move |path, anchor, _| {
                let target =
                    anchor.map_or_else(|| path.clone(), |anchor| format!("{path}#{anchor}"));
                observed.borrow_mut().push(target);
            });
            view.link_ui(cx)
        })
        .unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        render::activate_link(
            render::LinkTarget::new("Week 9 Lecture Notes", "Cheat%73heet.md#fractions"),
            render::LinkAction::Primary,
            Some(&ui),
            window,
            cx,
        );
    })
    .unwrap();
    assert_eq!(
        &*opened.borrow(),
        &["notes/Cheatsheet.md#fractions"],
        "cross-file navigation must not discard the requested section"
    );
    // The file host supplies the loaded buffer through the normal preview API.
    window
        .update(cx, |view, _, cx| {
            view.activate(
                "notes/Cheatsheet.md",
                &(None, "synthetic-checkout".into()),
                cx,
            );
            view.set_source("# Fractions\n\n$\\frac{a+b}{n}$".into(), false, cx);
        })
        .unwrap();
    settle(cx, window);
    let entries = entries(cx, window);
    assert!(
        entries
            .iter()
            .any(|(_, text, bounds)| text == r"$\frac{a+b}{n}$" && bounds.size.width < px(80.)),
        "{entries:?}"
    );
}

#[gpui::test]
fn file_preview_reference_section_links_reveal_headings_inside_quotes_and_lists(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    for destination in [
        "> ## Details\n>\n> Formula $\\frac{7}{q}$.",
        "- ## Details\n\n  Formula $\\frac{7}{q}$.",
        "- Quoted lecture extract\n\n  > ## Details\n  >\n  > Formula $\\frac{7}{q}$.",
    ] {
        let filler = "Revision paragraph.\n\n".repeat(40);
        let source = format!(
            "Read [Jump to details][section] beside $x$.\n\n[section]: #details-1\n\n# Details\n\n{filler}{destination}\n\n{filler}"
        );
        let window = open(cx, &source, 320.);
        let visible = entries(cx, window);
        let link = visible
            .iter()
            .find(|(_, text, _)| text.trim() == "details")
            .unwrap();
        {
            let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
            visual.simulate_click(link.2.center(), gpui::Modifiers::default());
        }
        settle(cx, window);
        let visible = entries(cx, window);
        assert!(
            visible
                .iter()
                .any(|(_, text, bounds)| text == r"$\frac{7}{q}$" && bounds.size.height > px(20.)),
            "section link must reveal a nested heading and its typeset formula: {destination}: {visible:?}"
        );
        window
            .update(cx, |view, _, _| {
                assert!(view.list.logical_scroll_top().item_ix > 0);
                assert_eq!(view.anchors.get("details"), Some(&1));
                assert!(
                    view.anchors.contains_key("details-1"),
                    "nested headings share the document's duplicate-slug order"
                );
            })
            .unwrap();
    }
}

#[gpui::test]
fn file_preview_encoded_duplicate_headings_reveal_the_matching_equations(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let filler = "Filler $x$ paragraph.\n\n".repeat(40);
    let source = format!(
        "# Start\n\n{filler}## Café\n\n$\\frac{{1}}{{a}}$\n\n{filler}## Café\n\n$\\frac{{2}}{{b}}$\n\n{filler}## Café-1\n\n$\\frac{{3}}{{c}}$\n\n{filler}"
    );
    for width in [220., 480.] {
        let window = open(cx, &source, width);
        for (target, equation) in [
            ("#caf%C3%A9", r"$\frac{1}{a}$"),
            ("#caf%C3%A9-1", r"$\frac{2}{b}$"),
            ("#caf%C3%A9-1-1", r"$\frac{3}{c}$"),
        ] {
            let ui = window.update(cx, |view, _, cx| view.link_ui(cx)).unwrap();
            cx.update_window(window.into(), |_, window, cx| {
                render::activate_link(
                    render::LinkTarget::new("Section", target),
                    render::LinkAction::Primary,
                    Some(&ui),
                    window,
                    cx,
                );
            })
            .unwrap();
            settle(cx, window);
            let visible = entries(cx, window);
            assert!(
                visible
                    .iter()
                    .any(|(_, text, bounds)| text == equation && bounds.size.height > px(20.)),
                "{target}, width={width}: {visible:?}"
            );
        }
    }
}

#[gpui::test]
fn file_preview_empty_fragment_returns_to_document_top(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = format!(
        "# Start\n\n{}\n## Last section\n\n$y$",
        "Filler $x$ paragraph.\n\n".repeat(40)
    );
    let window = open(cx, &source, 320.);
    for target in ["#last-section", "#"] {
        let ui = window.update(cx, |view, _, cx| view.link_ui(cx)).unwrap();
        cx.update_window(window.into(), |_, window, cx| {
            render::activate_link(
                render::LinkTarget::new("Jump", target),
                render::LinkAction::Primary,
                Some(&ui),
                window,
                cx,
            );
        })
        .unwrap();
        settle(cx, window);
        let offset = window
            .update(cx, |view, _, _| view.list.logical_scroll_top())
            .unwrap();
        if target == "#" {
            assert_eq!(
                offset.item_ix, 0,
                "an explicit empty fragment must return to the top"
            );
        } else {
            assert!(offset.item_ix > 0, "probe must actually scroll first");
        }
    }
}

#[gpui::test]
fn file_preview_anchor_during_reparse_waits_for_the_new_headings(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let window = open(cx, "# Old\n\n$z$", 320.);
    let source = format!(
        "# Start\n\n{}\n## New target\n\n$\\frac{{7}}{{q}}$",
        "Filler $x$ paragraph.\n\n".repeat(40)
    );
    let ui = window
        .update(cx, |view, _, cx| {
            view.set_source(source, false, cx);
            view.link_ui(cx)
        })
        .unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        render::activate_link(
            render::LinkTarget::new("Jump", "#new-target"),
            render::LinkAction::Primary,
            Some(&ui),
            window,
            cx,
        );
    })
    .unwrap();
    settle(cx, window);
    assert!(
        entries(cx, window)
            .iter()
            .any(|(_, text, _)| text == r"$\frac{7}{q}$"),
        "navigation during the parse debounce must not be lost"
    );
}

#[gpui::test]
fn file_preview_pending_anchor_uses_latest_request_and_is_cancelled_on_suspend(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let window = open(cx, "# Old\n\n$z$", 320.);
    let source = format!(
        "# Start\n\n{}## Target\n\n$y$",
        "Filler $x$.\n\n".repeat(40)
    );
    window
        .update(cx, |view, _, cx| {
            view.set_source(source.clone(), false, cx);
            view.request_anchor("target".into(), cx);
            view.request_anchor(String::new(), cx);
        })
        .unwrap();
    settle(cx, window);
    window
        .update(cx, |view, _, cx| {
            assert_eq!(view.list.logical_scroll_top().item_ix, 0);
            assert!(view.pending_anchor.is_none());
            view.request_anchor("missing-heading".into(), cx);
            assert_eq!(view.list.logical_scroll_top().item_ix, 0);
            view.set_source(source, false, cx);
            view.request_anchor("target".into(), cx);
            view.suspend(cx);
            assert!(view.pending_anchor.is_none());
            view.rename_path("renamed/Cheatsheet.md", cx);
            assert!(
                view.suspended,
                "renaming a cached document must not resume it"
            );
            assert!(view.pending_anchor.is_none());
        })
        .unwrap();
}

#[gpui::test]
fn file_preview_math_anchor_navigation_virtualizes_without_offpane_hit_regions(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = format!(
        "# Start\n\n{}\n## Target equations\n\n${}z$\n\nTail $\\frac{{7}}{{q}}$.",
        "Filler $x_i$ paragraph.\n\n".repeat(40),
        "x+".repeat(60)
    );
    let window = open(cx, &source, 220.);
    let ui = window.update(cx, |view, _, cx| view.link_ui(cx)).unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        render::activate_link(
            render::LinkTarget::new("Jump", "#target-equations"),
            render::LinkAction::Primary,
            Some(&ui),
            window,
            cx,
        );
    })
    .unwrap();
    settle(cx, window);
    let entries = entries(cx, window);
    assert!(
        entries.iter().any(|(_, text, _)| text == r"$\frac{7}{q}$"),
        "anchor must reveal the destination equations: {entries:?}"
    );
    for (_, text, bounds) in entries {
        assert!(
            bounds.left() >= px(0.) && bounds.right() <= px(220.),
            "{text}: {bounds:?}"
        );
    }
}

#[gpui::test]
fn file_preview_suspension_cancels_its_drag_without_touching_another_document(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let left = open(cx, "Left $x$.", 320.);
    let right = open(cx, "Right $y$.", 320.);
    let equation = entries(cx, left)
        .into_iter()
        .find(|(_, text, _)| text == "$x$")
        .unwrap();
    cx.update_window(left.into(), |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position: equation.2.center(),
                click_count: 2,
                ..Default::default()
            }),
            cx,
        );
    })
    .unwrap();
    assert!(crate::markdown::selection::is_dragging());
    right
        .update(cx, |view, _, cx| {
            view.set_source("Changed $z$.".into(), false, cx);
            view.suspend(cx);
        })
        .unwrap();
    assert_eq!(
        crate::markdown::selection::selected_text().as_deref(),
        Some("$x$")
    );
    assert!(crate::markdown::selection::is_dragging());
    left.update(cx, |view, _, cx| view.suspend(cx)).unwrap();
    assert!(crate::markdown::selection::selected_text().is_none());
    assert!(!crate::markdown::selection::is_dragging());
}

#[gpui::test]
fn file_preview_copy_in_another_window_does_not_steal_the_first_notes_selection(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let first = open(cx, r"Week 9 $\frac{a}{b}$ notes.", 320.);
    let second = open(cx, "Week 10 $y$ notes.", 320.);
    let equation = entries(cx, first)
        .into_iter()
        .find(|(_, text, _)| text == r"$\frac{a}{b}$")
        .unwrap();
    cx.update_window(first.into(), |_, window, cx| {
        let position = equation.2.center();
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position,
                click_count: 2,
                ..Default::default()
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                button: gpui::MouseButton::Left,
                position,
                click_count: 2,
                ..Default::default()
            }),
            cx,
        );
    })
    .unwrap();
    assert_eq!(
        crate::markdown::selection::selected_text().as_deref(),
        Some(r"$\frac{a}{b}$")
    );
    let focus = second.update(cx, |view, _, _| view.focus.clone()).unwrap();
    cx.update_window(second.into(), |_, window, cx| window.focus(&focus, cx))
        .unwrap();
    cx.update(|cx| {
        cx.write_to_clipboard(gpui::ClipboardItem::new_string("Existing clipboard".into()))
    });
    cx.simulate_keystrokes(second.into(), "cmd-c");
    cx.update(|cx| {
        assert_eq!(
            cx.read_from_clipboard().unwrap().text().as_deref(),
            Some("Existing clipboard"),
            "Copy in notes with no selection must not copy another window's equation"
        )
    });
    let focus = first.update(cx, |view, _, _| view.focus.clone()).unwrap();
    cx.update_window(first.into(), |_, window, cx| window.focus(&focus, cx))
        .unwrap();
    cx.simulate_keystrokes(first.into(), "cmd-c");
    cx.update(|cx| {
        assert_eq!(
            cx.read_from_clipboard().unwrap().text().as_deref(),
            Some(r"$\frac{a}{b}$")
        )
    });
}

#[gpui::test]
fn file_preview_lecture_notes_copy_math_from_quotes_lists_and_tables(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = "# Week 9\n\n> Use $\\frac{a}{b}$ here.\n\n- Revise $\\sqrt{x+y}$.\n\n| Quantity | Formula |\n| --- | --- |\n| Error | $\\frac{1}{n}$ |\n\nPrinting costs $5 and $10. Code: `$x^2$`.";
    for width in [320., 600.] {
        let window = open(cx, source, width);
        for expected in [r"$\frac{a}{b}$", r"$\sqrt{x+y}$", r"$\frac{1}{n}$"] {
            let visible = entries(cx, window);
            let equation = visible
                .iter()
                .find(|(_, text, bounds)| text == expected && bounds.size.width < px(80.))
                .unwrap_or_else(|| {
                    panic!("missing equation {expected}, width={width}: {visible:?}")
                });
            cx.update_window(window.into(), |_, window, cx| {
                let position = equation.2.center();
                window.dispatch_event(
                    gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                        button: gpui::MouseButton::Left,
                        position,
                        click_count: 2,
                        ..Default::default()
                    }),
                    cx,
                );
                window.dispatch_event(
                    gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                        button: gpui::MouseButton::Left,
                        position,
                        click_count: 2,
                        ..Default::default()
                    }),
                    cx,
                );
            })
            .unwrap();
            cx.simulate_keystrokes(window.into(), "cmd-c");
            cx.update(|cx| {
                assert_eq!(
                    cx.read_from_clipboard().unwrap().text().as_deref(),
                    Some(expected)
                )
            });
        }
        let visible = entries(cx, window);
        let text: String = visible.iter().map(|(_, text, _)| text.as_str()).collect();
        assert!(
            text.contains("$5 and $10") && text.contains("$x^2$"),
            "{visible:?}"
        );
    }
}

#[gpui::test]
fn file_preview_resizing_selected_study_paragraph_reflows_without_changing_copy(
    cx: &mut TestAppContext,
) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = "Review **naïve estimates** with $\\frac{a+b}{n}$ and compare the café notes before tomorrow's lecture.";
    let expected = "Review naïve estimates with $\\frac{a+b}{n}$ and compare the café notes before tomorrow's lecture.";
    let window = open(cx, source, 720.);
    let equation = entries(cx, window)
        .into_iter()
        .find(|(_, text, _)| text == r"$\frac{a+b}{n}$")
        .unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        let position = equation.2.center();
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position,
                click_count: 3,
                ..Default::default()
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                button: gpui::MouseButton::Left,
                position,
                click_count: 3,
                ..Default::default()
            }),
            cx,
        );
    })
    .unwrap();
    let mut narrow_height = None;
    for width in [280., 720., 360.] {
        cx.simulate_window_resize(window.into(), size(px(width), px(600.)));
        settle(cx, window);
        let visible = entries(cx, window);
        let copied: String = visible.iter().map(|(_, text, _)| text.as_str()).collect();
        assert_eq!(
            copied, expected,
            "reflow must neither drop nor duplicate fragments"
        );
        for (_, text, bounds) in &visible {
            assert!(
                bounds.left() >= px(24.) && bounds.right() <= px(width - 24.),
                "resized fragment escaped the preview: {text}: {bounds:?}"
            );
        }
        let height = window
            .update(cx, |view, _, _| view.test_block_bounds(0).size.height)
            .unwrap();
        if width == 280. {
            narrow_height = Some(height);
        } else if width == 720. {
            assert!(
                height < narrow_height.unwrap(),
                "widening must actually reflow the paragraph"
            );
        }
        cx.simulate_keystrokes(window.into(), "cmd-c");
        cx.update(|cx| {
            assert_eq!(
                cx.read_from_clipboard().unwrap().text().as_deref(),
                Some(expected)
            );
        });
    }
}

#[gpui::test]
fn file_preview_math_mouse_and_keyboard_copy_preserve_latex_source(cx: &mut TestAppContext) {
    let _guard = crate::markdown::selection::test_state_lock();
    let source = "# Cheatsheet\n\nBefore $\\frac{a}{b}$ after.\n\nOther $x$.";
    let window = open(cx, source, 320.);
    let equation = entries(cx, window)
        .into_iter()
        .find(|(_, text, _)| text == r"$\frac{a}{b}$")
        .unwrap();
    for (click_count, expected) in [(2, r"$\frac{a}{b}$"), (3, r"Before $\frac{a}{b}$ after.")] {
        cx.update_window(window.into(), |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                    button: gpui::MouseButton::Left,
                    position: point(equation.2.center().x, equation.2.center().y),
                    click_count,
                    ..Default::default()
                }),
                cx,
            );
        })
        .unwrap();
        assert_eq!(
            crate::markdown::selection::selected_text().as_deref(),
            Some(expected)
        );
        cx.simulate_keystrokes(window.into(), "cmd-c");
        cx.update(|cx| {
            assert_eq!(
                cx.read_from_clipboard().unwrap().text().as_deref(),
                Some(expected)
            )
        });
        crate::markdown::selection::end_active_drag();
        crate::markdown::selection::clear_if_owner(&equation.0);
    }
}
