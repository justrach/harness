use super::*;

#[gpui::test]
fn selection_lifecycle_copy_in_an_untouched_window_does_not_copy_another_windows_output(
    cx: &mut TestAppContext,
) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_first_dir, first) = fixture(cx, false);
    let (_second_dir, second) = fixture(cx, true);
    let first_input = first.read_with(cx, |host, _| host.input.clone()).unwrap();
    let second_input = second.read_with(cx, |host, _| host.input.clone()).unwrap();
    {
        let cx = &mut VisualTestContext::from_window(first.into(), cx);
        select_output(&first_input, cx);
    }
    let claim = selection::current_claim();
    {
        let cx = &mut VisualTestContext::from_window(second.into(), cx);
        redraw(cx);
        // Moving keyboard focus between windows is not a click on the first
        // window's rendered text and must not silently adopt its selection.
        cx.update(|window, cx| {
            let focus = second_input.read(cx).focus_handle.clone();
            window.focus(&focus, cx);
            cx.write_to_clipboard(ClipboardItem::new_string("synthetic sentinel".into()));
        });
        action(cx, Copy);
        assert_eq!(clipboard(cx).as_deref(), Some("synthetic sentinel"));
        assert_eq!(selection::current_claim(), claim);
    }
    {
        let cx = &mut VisualTestContext::from_window(first.into(), cx);
        action(cx, Copy);
        assert_eq!(clipboard(cx).as_deref(), Some(OUTPUT));
    }
}

#[gpui::test]
fn selection_lifecycle_copy_cannot_follow_a_superseding_claim_into_another_window(
    cx: &mut TestAppContext,
) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_first_dir, first) = fixture(cx, false);
    let (_second_dir, second) = fixture(cx, true);
    let first_input = first.read_with(cx, |host, _| host.input.clone()).unwrap();
    let second_input = second.read_with(cx, |host, _| host.input.clone()).unwrap();
    {
        let cx = &mut VisualTestContext::from_window(first.into(), cx);
        select_output(&first_input, cx);
    }
    let old_claim = selection::current_claim();
    {
        let cx = &mut VisualTestContext::from_window(second.into(), cx);
        select_output(&second_input, cx);
    }
    let new_claim = selection::current_claim();
    assert_ne!(
        old_claim, new_claim,
        "both windows intentionally reuse the same row key"
    );
    {
        let cx = &mut VisualTestContext::from_window(first.into(), cx);
        cx.update(|window, cx| {
            let focus = first_input.read(cx).focus_handle.clone();
            window.focus(&focus, cx);
            cx.write_to_clipboard(ClipboardItem::new_string("synthetic sentinel".into()));
        });
        action(cx, Copy);
        assert_eq!(clipboard(cx).as_deref(), Some("synthetic sentinel"));
        assert_eq!(selection::current_claim(), new_claim);
    }
    {
        let cx = &mut VisualTestContext::from_window(second.into(), cx);
        action(cx, Copy);
        assert_eq!(clipboard(cx).as_deref(), Some(OUTPUT));
    }
}

#[gpui::test]
fn selection_lifecycle_replacement_editor_retires_unmounted_output_on_click(
    cx: &mut TestAppContext,
) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let original = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select_output(&original, cx);
    let replacement = cx.new(|cx| {
        let mut input = ComposerInput::new("Replacement", cx);
        input.set_text("Replacement draft", cx);
        input
    });
    window
        .update(cx, |host, _, cx| {
            host.input = replacement.clone();
            host.show_output = false;
            cx.notify();
        })
        .unwrap();
    redraw(cx);
    assert!(
        !render::selection_test_entries()
            .iter()
            .any(|(_, text, _)| text == OUTPUT)
    );
    click(cx, input_position(&replacement, cx), 3);
    assert!(selection::selected_text().is_none());
    action(cx, Copy);
    assert_eq!(clipboard(cx).as_deref(), Some("Replacement draft"));
}

#[gpui::test]
fn selection_lifecycle_replacement_editor_retires_output_on_keyboard_selection(
    cx: &mut TestAppContext,
) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, true);
    let original = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select_output(&original, cx);
    let replacement = cx.new(|cx| {
        let mut input = ComposerInput::new("Replacement", cx);
        input.set_text("Replacement draft", cx);
        input
    });
    window
        .update(cx, |host, _, cx| {
            host.input = replacement.clone();
            cx.notify();
        })
        .unwrap();
    redraw(cx);
    cx.update(|window, cx| {
        let focus = replacement.read(cx).focus_handle.clone();
        window.focus(&focus, cx);
    });
    action(cx, SelectAll);
    assert!(selection::selected_text().is_none());
    action(cx, Copy);
    assert_eq!(clipboard(cx).as_deref(), Some("Replacement draft"));
}

#[gpui::test]
fn selection_lifecycle_batched_press_and_release_still_handoff_copy(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for count in [1, 2, 3] {
        redraw(cx);
        click(cx, input_position(&input, cx), 3);
        let position = output_bounds().origin + point(px(2.0), px(8.0));
        // Native fixtures and automation can dispatch a complete gesture in
        // one app update, so deferred ownership sees an already-settled claim.
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
        let expected = match count {
            1 => None,
            2 => Some("Synthetic"),
            _ => Some(OUTPUT),
        };
        assert_eq!(selection::selected_text().as_deref(), expected);
        input.read_with(cx, |input, _| assert!(input.selected_range.is_empty()));
        cx.update(|window, cx| {
            assert!(input.read(cx).focus_handle.is_focused(window));
            cx.write_to_clipboard(ClipboardItem::new_string("synthetic sentinel".into()));
        });
        action(cx, Copy);
        assert_eq!(
            clipboard(cx).as_deref(),
            Some(expected.unwrap_or("synthetic sentinel"))
        );
    }
}

#[gpui::test]
fn selection_lifecycle_no_op_undo_and_redo_preserve_the_output_claim(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select_output(&input, cx);
    let claim = selection::current_claim();
    for redo in [false, true] {
        if redo {
            action(cx, Redo);
        } else {
            action(cx, Undo);
        }
        assert_eq!(selection::current_claim(), claim);
        assert_eq!(selection::selected_text().as_deref(), Some(OUTPUT));
        input.read_with(cx, |input, _| assert_eq!(input.text(), DRAFT));
    }
    action(cx, Copy);
    assert_eq!(clipboard(cx).as_deref(), Some(OUTPUT));
}
