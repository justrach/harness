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
            Rc::new(|_, _| {}),
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
            view.open_file = Rc::new(move |path, _| observed.borrow_mut().push(path));
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
    assert_eq!(&*opened.borrow(), &["notes/Cheatsheet.md"]);
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
