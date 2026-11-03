use super::*;
use gpui::{TestAppContext, VisualTestContext, WindowHandle};

struct Cleanup;
impl Cleanup {
    fn new() -> Self {
        render::clear_selection_surface("composer-question");
        Self
    }
}
impl Drop for Cleanup {
    fn drop(&mut self) {
        render::clear_selection_surface("composer-question");
    }
}

fn fixture(
    cx: &mut TestAppContext,
    questions: &[&str],
) -> (tempfile::TempDir, WindowHandle<Composer>) {
    let (dir, handle) = super::super::tests::composer_focus_window(cx);
    cx.update(|cx| init(cx, ComposerSendBehavior::Enter));
    handle
        .update(cx, |composer, window, cx| {
            window.resize(size(px(1000.0), px(700.0)));
            composer.set_available_width(600.0, cx);
            composer.set_available_height(700.0, cx);
            composer.wizard = Some(Wizard::new(
                "synthetic-edge-question".into(),
                questions
                    .iter()
                    .enumerate()
                    .map(|(index, question)| UserInputQuestion {
                        id: format!("page-{index}"),
                        header: "Agent question".into(),
                        question: (*question).into(),
                        options: vec!["First approach".into(), "Second approach".into()],
                        prefill: None,
                        multiline: false,
                        multi_select: true,
                    })
                    .collect(),
            ));
            composer.wizard_expanded = true;
            composer.input.update(cx, |input, cx| {
                input.set_text(ANSWER, cx);
                input.selected_range = 0..ANSWER.len();
            });
            window.focus(&composer.wizard_focus, cx);
            cx.notify();
        })
        .unwrap();
    (dir, handle)
}

fn redraw(cx: &mut VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
}

fn bounds(text: &str) -> Bounds<Pixels> {
    render::selection_test_entries()
        .into_iter()
        .rev()
        .find(|(key, candidate, _)| key.starts_with("composer-question") && candidate == text)
        .expect("question text must be painted")
        .2
}

fn click(cx: &mut VisualTestContext, position: Point<Pixels>, button: MouseButton, count: usize) {
    cx.simulate_event(MouseDownEvent {
        button,
        position,
        click_count: count,
        ..Default::default()
    });
    cx.simulate_event(MouseUpEvent {
        button,
        position,
        ..Default::default()
    });
    cx.run_until_parked();
}

fn select(cx: &mut VisualTestContext, text: &str) {
    redraw(cx);
    click(
        cx,
        bounds(text).origin + point(px(2.0), px(8.0)),
        MouseButton::Left,
        3,
    );
    assert_eq!(selection::selected_text().as_deref(), Some(text));
}

fn copy(cx: &mut VisualTestContext) -> Option<String> {
    cx.update(|_, cx| cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into())));
    cx.simulate_keystrokes("cmd-c");
    cx.run_until_parked();
    cx.update(|_, cx| cx.read_from_clipboard().and_then(|item| item.text()))
}

#[gpui::test]
fn agent_question_edge_registry_replaces_repainted_text(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let (_dir, window) = fixture(cx, &[QUESTION]);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for _ in 0..4 {
        redraw(cx);
    }
    let entries = render::selection_test_entries();
    assert_eq!(
        entries
            .iter()
            .filter(|(_, text, _)| text == QUESTION)
            .count(),
        1,
        "a question repaint must replace its old selection geometry"
    );
}

#[gpui::test]
fn agent_question_edge_drag_across_markdown_in_both_directions(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let first = "First synthetic paragraph.";
    let second = "Second synthetic paragraph.";
    let (_dir, window) = fixture(
        cx,
        &["First synthetic paragraph.\n\nSecond **synthetic** paragraph."],
    );
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for reverse in [false, true] {
        redraw(cx);
        let a = bounds(first).origin + point(px(0.1), px(8.0));
        let b = point(
            bounds(second).right() - px(0.1),
            bounds(second).top() + px(8.0),
        );
        let (start, end) = if reverse { (b, a) } else { (a, b) };
        cx.simulate_event(MouseDownEvent {
            button: MouseButton::Left,
            position: start,
            ..Default::default()
        });
        redraw(cx);
        cx.simulate_event(MouseMoveEvent {
            position: end,
            pressed_button: Some(MouseButton::Left),
            ..Default::default()
        });
        cx.simulate_event(MouseUpEvent {
            button: MouseButton::Left,
            position: end,
            ..Default::default()
        });
        cx.run_until_parked();
        assert_eq!(
            copy(cx),
            Some(format!("{first}\n{second}")),
            "reverse={reverse}"
        );
    }
}

#[gpui::test]
fn agent_question_edge_unicode_double_click_and_batched_gestures(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let text = "café 👩🏽‍💻 e\u{301}lan";
    let (_dir, window) = fixture(cx, &[text]);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for (count, expected) in [(1, "sentinel"), (2, "café"), (3, text)] {
        redraw(cx);
        let position = bounds(text).origin + point(px(2.0), px(8.0));
        cx.update(|window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(MouseDownEvent {
                    button: MouseButton::Left,
                    position,
                    click_count: count,
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseUp(MouseUpEvent {
                    button: MouseButton::Left,
                    position,
                    ..Default::default()
                }),
                cx,
            );
        });
        cx.run_until_parked();
        assert_eq!(copy(cx).as_deref(), Some(expected), "click count {count}");
    }
}

#[gpui::test]
fn agent_question_edge_secondary_click_preserves_copy(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let (_dir, window) = fixture(cx, &[QUESTION]);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for button in [MouseButton::Right, MouseButton::Middle] {
        select(cx, QUESTION);
        let claim = selection::current_claim();
        click(
            cx,
            bounds(QUESTION).origin + point(px(2.0), px(8.0)),
            button,
            1,
        );
        assert_eq!(selection::current_claim(), claim);
        assert_eq!(copy(cx).as_deref(), Some(QUESTION), "{button:?}");
    }
}

#[gpui::test]
fn agent_question_edge_page_change_replaces_selection_geometry(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let next = "A different synthetic question?";
    let (_dir, window) = fixture(cx, &[QUESTION, next]);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select(cx, QUESTION);
    window
        .update(cx, |composer, _, cx| composer.wizard_advance(cx))
        .unwrap();
    redraw(cx);
    assert!(
        !render::selection_test_entries()
            .iter()
            .any(|(_, text, _)| text == QUESTION),
        "old page geometry must not remain a drag target"
    );
    assert!(
        selection::selected_text().is_none(),
        "the previous page's highlight must retire"
    );
    select(cx, next);
    assert_eq!(copy(cx).as_deref(), Some(next));
    window
        .update(cx, |composer, _, cx| composer.wizard_back(cx))
        .unwrap();
    select(cx, QUESTION);
    assert_eq!(copy(cx).as_deref(), Some(QUESTION));
}

#[gpui::test]
fn agent_question_edge_windows_do_not_clear_each_others_selection(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let other_text = "Another window's synthetic question?";
    let (_first_dir, first) = fixture(cx, &[QUESTION]);
    let (_second_dir, second) = fixture(cx, &[other_text]);
    {
        let cx = &mut VisualTestContext::from_window(first.into(), cx);
        select(cx, QUESTION);
        assert_eq!(copy(cx).as_deref(), Some(QUESTION));
    }
    let claim = selection::current_claim();
    {
        let cx = &mut VisualTestContext::from_window(second.into(), cx);
        redraw(cx);
        // Put the other window's question at different coordinates. A click
        // outside it must not clear a selected question in the first window.
        window_resize_and_redraw(cx, size(px(600.0), px(900.0)));
        cx.simulate_click(point(px(5.0), px(5.0)), Default::default());
        assert_eq!(selection::current_claim(), claim);
        for (key, text, _) in render::selection_test_entries() {
            if text == other_text {
                assert!(
                    selection::wash_range(&key).is_none(),
                    "a foreign question must not inherit the wash"
                );
            }
        }
        select(cx, other_text);
        assert_eq!(copy(cx).as_deref(), Some(other_text));
    }
    {
        let cx = &mut VisualTestContext::from_window(first.into(), cx);
        let input = first
            .read_with(cx, |composer, _| composer.input.clone())
            .unwrap();
        cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
        assert_eq!(
            copy(cx).as_deref(),
            Some("sentinel"),
            "a stale claim must not copy the other window's question"
        );
        select(cx, QUESTION);
        assert_eq!(copy(cx).as_deref(), Some(QUESTION));
    }
}

#[gpui::test]
fn agent_question_edge_replacement_and_removal_retire_old_copy(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    for replacement in ["request", "text", "removed"] {
        let (_dir, window) = fixture(cx, &[QUESTION]);
        let cx = &mut VisualTestContext::from_window(window.into(), cx);
        select(cx, QUESTION);
        window
            .update(cx, |composer, _, cx| {
                match replacement {
                    "request" => {
                        composer.wizard.as_mut().unwrap().request_id = "replacement-request".into()
                    }
                    "text" => {
                        composer.wizard.as_mut().unwrap().questions[0].question =
                            "Replacement synthetic text".into()
                    }
                    _ => composer.wizard = None,
                }
                cx.notify();
            })
            .unwrap();
        redraw(cx);
        assert!(
            selection::selected_text().is_none(),
            "{replacement} must retire the old snapshot"
        );
        assert_eq!(copy(cx).as_deref(), Some("sentinel"), "{replacement}");
    }
}

#[gpui::test]
fn agent_question_edge_selection_survives_inline_popover_resize(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let (_dir, window) = fixture(cx, &[QUESTION]);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select(cx, QUESTION);
    let claim = selection::current_claim();
    for width in [200.0, 600.0, 200.0] {
        window
            .update(cx, |composer, _, cx| {
                composer.set_available_width(width, cx)
            })
            .unwrap();
        redraw(cx);
        assert_eq!(
            selection::current_claim(),
            claim,
            "a resize is not a source replacement"
        );
        assert_eq!(copy(cx).as_deref(), Some(QUESTION));
    }
}

#[gpui::test]
fn agent_question_edge_independent_apps_cannot_retire_a_foreign_claim(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let (_dir, first) = fixture(cx, &[QUESTION]);
    {
        let visual = &mut VisualTestContext::from_window(first.into(), cx);
        select(visual, QUESTION);
    }
    let claim = selection::current_claim();
    let mut other = cx.new_app();
    let (_other_dir, second) = fixture(&mut other, &["Another app's synthetic question?"]);
    {
        let visual = &mut VisualTestContext::from_window(second.into(), &mut other);
        redraw(visual);
    }
    let after_render = selection::current_claim();
    other.quit();
    assert_eq!(
        after_render, claim,
        "another App can reuse an entity ID, not a selection surface"
    );
    assert_eq!(
        selection::current_claim(),
        claim,
        "releasing another App must not cancel this question"
    );
    let visual = &mut VisualTestContext::from_window(first.into(), cx);
    assert_eq!(copy(visual).as_deref(), Some(QUESTION));
}

#[gpui::test]
fn agent_question_edge_cut_never_deletes_the_unselected_answer(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = Cleanup::new();
    let (_dir, window) = fixture(cx, &[QUESTION]);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select(cx, QUESTION);
    cx.simulate_keystrokes("cmd-x");
    cx.run_until_parked();
    window
        .read_with(cx, |composer, cx| {
            assert_eq!(composer.input.read(cx).text(), ANSWER)
        })
        .unwrap();
    assert_eq!(copy(cx).as_deref(), Some(QUESTION));
}

fn window_resize_and_redraw(cx: &mut VisualTestContext, size: gpui::Size<Pixels>) {
    cx.simulate_resize(size);
    redraw(cx);
}
