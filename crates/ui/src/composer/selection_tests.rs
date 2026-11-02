use super::*;
use crate::markdown::{render, selection};
use gpui::{TestAppContext, VisualTestContext, WindowHandle};

const OUTPUT: &str = "Synthetic café output 👩🏽‍💻";
const DRAFT: &str = "Synthetic café draft 👩🏽‍💻";

struct SelectionCleanup;
impl Drop for SelectionCleanup {
    fn drop(&mut self) {
        selection::end_active_drag();
        if let Some(key) = selection::anchor_key() {
            selection::clear_if_owner(&key);
        }
    }
}

struct SelectionHost {
    input: Entity<ComposerInput>,
    other: Entity<ComposerInput>,
    input_first: bool,
    show_output: bool,
    focus_other_on_output: bool,
    owner: u64,
}

impl Drop for SelectionHost {
    fn drop(&mut self) {
        render::release_selection_owner(self.owner);
    }
}

impl Render for SelectionHost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx);
        let owner = cx.entity_id().as_u64();
        self.owner = owner;
        let other_focus = self
            .focus_other_on_output
            .then(|| self.other.read(cx).focus_handle.clone());
        let output = div()
            .id("selection-edge-output")
            .p(px(16.0))
            .on_mouse_down(MouseButton::Left, move |event, window, cx| {
                if !selection::is_dragging() {
                    render::begin_drag_in_whitespace(owner, event.position);
                }
                if let Some(focus) = &other_focus {
                    window.focus(focus, cx);
                }
            })
            .child(render::render_tree(
                &crate::markdown::parse_full(OUTPUT),
                &render::RenderOptions::settled("selection-edge-output".into()),
                theme,
                window,
                &|_| None,
            ));
        div()
            .size_full()
            .p(px(24.0))
            .flex()
            .flex_col()
            .gap(px(24.0))
            .child(render::selection_owner_reset(owner))
            .when(self.input_first, |el| el.child(self.input.clone()))
            .when(self.show_output, |el| el.child(output))
            .when(!self.input_first, |el| el.child(self.input.clone()))
            .child(self.other.clone())
            .child(div().id("selection-edge-blank").h(px(80.0)))
            .child(render::selection_owner_end())
    }
}

fn fixture(
    cx: &mut TestAppContext,
    input_first: bool,
) -> (tempfile::TempDir, WindowHandle<SelectionHost>) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        crate::app_menus::init(cx);
        init(cx, ComposerSendBehavior::Enter);
    });
    let window = cx.add_window(|_, cx| SelectionHost {
        input: cx.new(|cx| {
            let mut input = ComposerInput::new("Draft", cx);
            input.set_text(DRAFT, cx);
            input
        }),
        other: cx.new(|cx| ComposerInput::new("Other input", cx)),
        input_first,
        show_output: true,
        focus_other_on_output: false,
        owner: 0,
    });
    (dir, window)
}

fn redraw(cx: &mut VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
}

fn click(cx: &mut VisualTestContext, position: Point<Pixels>, count: usize) {
    cx.simulate_event(MouseDownEvent {
        button: MouseButton::Left,
        position,
        click_count: count,
        ..Default::default()
    });
    cx.simulate_event(MouseUpEvent {
        button: MouseButton::Left,
        position,
        ..Default::default()
    });
}

fn input_position(input: &Entity<ComposerInput>, cx: &VisualTestContext) -> Point<Pixels> {
    input.read_with(cx, |input, _| {
        input.last_bounds.unwrap().origin + point(px(2.0), px(8.0))
    })
}

fn output_bounds() -> Bounds<Pixels> {
    render::selection_test_entries()
        .into_iter()
        .rev()
        .find(|(_, text, _)| text == OUTPUT)
        .unwrap()
        .2
}

fn select_output(input: &Entity<ComposerInput>, cx: &mut VisualTestContext) {
    redraw(cx);
    click(cx, input_position(input, cx), 3);
    let position = output_bounds().origin + point(px(2.0), px(8.0));
    click(cx, position, 3);
    assert_eq!(selection::selected_text().as_deref(), Some(OUTPUT));
}

fn action(cx: &mut VisualTestContext, action: impl gpui::Action) {
    cx.update(|window, cx| window.dispatch_action(Box::new(action), cx));
    cx.run_until_parked();
}

fn clipboard(cx: &mut VisualTestContext) -> Option<String> {
    cx.update(|_, cx| cx.read_from_clipboard().and_then(|item| item.text()))
}

#[gpui::test]
fn selection_handoff_keyboard_selection_retires_output(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    for input_first in [false, true] {
        let (_dir, window) = fixture(cx, input_first);
        let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
        let cx = &mut VisualTestContext::from_window(window.into(), cx);
        for movement in ["all", "grapheme", "line"] {
            select_output(&input, cx);
            match movement {
                "all" => action(cx, SelectAll),
                "grapheme" => action(cx, SelectLeft),
                _ => action(cx, SelectHome),
            }
            assert!(
                selection::selected_text().is_none(),
                "{movement} must retire the output wash"
            );
            let expected = if movement == "grapheme" {
                "👩🏽‍💻"
            } else {
                DRAFT
            };
            input.read_with(cx, |input, _| {
                assert_eq!(&input.text()[input.selected_range.clone()], expected);
            });
            action(cx, Copy);
            assert_eq!(clipboard(cx).as_deref(), Some(expected));
        }
    }
}

#[gpui::test]
fn selection_handoff_typing_paste_and_ime_retire_output(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for operation in ["typing", "paste", "ime"] {
        input.update(cx, |input, cx| input.set_text(DRAFT, cx));
        select_output(&input, cx);
        cx.update(|window, cx| {
            input.update(cx, |input, cx| match operation {
                "typing" => input.replace_text_in_range(None, "!", window, cx),
                "paste" => {
                    cx.write_to_clipboard(ClipboardItem::new_string("!".into()));
                    input.paste(&Paste, window, cx);
                }
                _ => input.replace_and_mark_text_in_range(None, "!", None, window, cx),
            })
        });
        assert!(
            selection::selected_text().is_none(),
            "{operation} left an output highlight"
        );
        input.read_with(cx, |input, _| assert_eq!(input.text(), format!("{DRAFT}!")));
    }
}

#[gpui::test]
fn selection_handoff_unmounted_output_does_not_keep_a_second_highlight(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select_output(&input, cx);
    window
        .update(cx, |host, _, cx| {
            host.show_output = false;
            cx.notify();
        })
        .unwrap();
    // Unmount the old frame's text listeners, as virtualization can do.
    redraw(cx);
    assert!(
        !render::selection_test_entries()
            .iter()
            .any(|(_, text, _)| text == OUTPUT)
    );
    click(cx, input_position(&input, cx), 3);
    assert!(selection::selected_text().is_none());
    action(cx, Copy);
    assert_eq!(clipboard(cx).as_deref(), Some(DRAFT));
}

#[gpui::test]
fn selection_handoff_does_not_react_to_an_older_drag(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    redraw(cx);
    click(cx, input_position(&input, cx), 3);
    // An active selection elsewhere must not make an unrelated click claim
    // output ownership in this window. It predates this mouse-down.
    selection::begin_with_span("older-synthetic-drag", "old", 0..3);
    let other = window.read_with(cx, |host, _| host.other.clone()).unwrap();
    let blank = other.read_with(cx, |other, _| {
        let bounds = other.last_bounds.unwrap();
        point(bounds.left(), bounds.bottom() + px(40.0))
    });
    click(cx, blank, 1);
    input.read_with(cx, |input, _| {
        assert_eq!(input.selected_range, 0..DRAFT.len())
    });
    cx.update(|window, cx| assert!(window.focused(cx).is_none()));
}

#[gpui::test]
fn selection_handoff_does_not_steal_focus_from_a_clicked_control(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    for input_first in [false, true] {
        let (_dir, window) = fixture(cx, input_first);
        let (input, other) = window
            .read_with(cx, |host, _| (host.input.clone(), host.other.clone()))
            .unwrap();
        window
            .update(cx, |host, _, cx| {
                host.focus_other_on_output = true;
                cx.notify();
            })
            .unwrap();
        let cx = &mut VisualTestContext::from_window(window.into(), cx);
        select_output(&input, cx);
        cx.update(|window, cx| assert!(other.read(cx).focus_handle.is_focused(window)));
        input.read_with(cx, |input, _| assert!(input.selected_range.is_empty()));
        assert_eq!(selection::selected_text().as_deref(), Some(OUTPUT));
        selection::end_active_drag();
        selection::clear_if_owner(&selection::anchor_key().unwrap());
    }
}

#[gpui::test]
fn selection_handoff_whitespace_drag_works_in_both_directions_and_paint_orders(
    cx: &mut TestAppContext,
) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    for input_first in [false, true] {
        let (_dir, window) = fixture(cx, input_first);
        let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
        let cx = &mut VisualTestContext::from_window(window.into(), cx);
        for reverse in [false, true] {
            redraw(cx);
            click(cx, input_position(&input, cx), 3);
            let bounds = output_bounds();
            let left = point(bounds.left() - px(8.0), bounds.top() + px(8.0));
            let right = point(bounds.right() + px(8.0), left.y);
            let (start, end) = if reverse {
                (right, left)
            } else {
                (left, right)
            };
            cx.simulate_event(MouseDownEvent {
                button: MouseButton::Left,
                position: start,
                click_count: 1,
                ..Default::default()
            });
            assert!(selection::is_dragging());
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
            assert_eq!(selection::selected_text().as_deref(), Some(OUTPUT));
            input.read_with(cx, |input, _| assert!(input.selected_range.is_empty()));
            cx.update(|window, cx| assert!(input.read(cx).focus_handle.is_focused(window)));
            action(cx, Copy);
            assert_eq!(clipboard(cx).as_deref(), Some(OUTPUT));
        }
    }
}

#[gpui::test]
fn selection_handoff_preserves_the_active_caret_and_never_cuts_the_draft(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    for reverse in [false, true] {
        input.update(cx, |input, cx| input.set_text(DRAFT, cx));
        redraw(cx);
        click(cx, input_position(&input, cx), 3);
        if reverse {
            input.update(cx, |input, cx| {
                input.move_to(DRAFT.len(), cx);
                input.select_to(0, cx);
            });
        }
        click(cx, output_bounds().origin + point(px(2.0), px(8.0)), 3);
        input.read_with(cx, |input, _| {
            let caret = if reverse { 0 } else { DRAFT.len() };
            assert_eq!(input.selected_range, caret..caret);
            assert!(!input.selection_reversed);
        });
        cx.update(|_, cx| {
            cx.write_to_clipboard(ClipboardItem::new_string("synthetic sentinel".into()))
        });
        action(cx, Cut);
        assert_eq!(clipboard(cx).as_deref(), Some("synthetic sentinel"));
        input.read_with(cx, |input, _| assert_eq!(input.text(), DRAFT));
        cx.update(|_, cx| cx.write_to_clipboard(ClipboardItem::new_string("!".into())));
        action(cx, Paste);
        input.read_with(cx, |input, _| {
            let expected = if reverse {
                format!("!{DRAFT}")
            } else {
                format!("{DRAFT}!")
            };
            assert_eq!(input.text(), expected);
        });
        assert!(
            selection::selected_text().is_none(),
            "editing should retire the output highlight"
        );
    }
}

#[gpui::test]
fn selection_handoff_single_click_and_secondary_click_have_distinct_ownership(
    cx: &mut TestAppContext,
) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    redraw(cx);
    click(cx, input_position(&input, cx), 3);
    let output = output_bounds().origin + point(px(2.0), px(8.0));
    for button in [MouseButton::Right, MouseButton::Middle] {
        cx.simulate_event(MouseDownEvent {
            button,
            position: output,
            click_count: 1,
            ..Default::default()
        });
        cx.simulate_event(MouseUpEvent {
            button,
            position: output,
            ..Default::default()
        });
        input.read_with(cx, |input, _| {
            assert_eq!(input.selected_range, 0..DRAFT.len())
        });
        cx.update(|window, cx| assert!(input.read(cx).focus_handle.is_focused(window)));
        assert!(selection::selected_text().is_none());
    }
    click(cx, output, 1);
    input.read_with(cx, |input, _| assert!(input.selected_range.is_empty()));
    assert!(selection::selected_text().is_none());
    cx.update(|_, cx| {
        cx.write_to_clipboard(ClipboardItem::new_string("synthetic sentinel".into()))
    });
    action(cx, Copy);
    assert_eq!(clipboard(cx).as_deref(), Some("synthetic sentinel"));
}

#[gpui::test]
fn selection_handoff_does_not_clear_a_newer_foreign_selection(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select_output(&input, cx);
    // A different surface can take the process-global claim before this
    // editor receives another key. It must not revoke that newer selection.
    selection::begin_with_span("newer-synthetic-selection", "newer", 0..5);
    selection::end_active_drag();
    action(cx, SelectAll);
    assert_eq!(selection::selected_text().as_deref(), Some("newer"));
}

#[gpui::test]
fn selection_handoff_undo_and_redo_revoke_the_output_claim(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    cx.update(|window, cx| {
        input.update(cx, |input, cx| {
            input.replace_text_in_range(None, "!", window, cx);
        })
    });
    select_output(&input, cx);
    action(cx, Undo);
    assert!(selection::selected_text().is_none());
    input.read_with(cx, |input, _| assert_eq!(input.text(), DRAFT));
    select_output(&input, cx);
    action(cx, Redo);
    assert!(selection::selected_text().is_none());
    input.read_with(cx, |input, _| assert_eq!(input.text(), format!("{DRAFT}!")));
}

#[gpui::test]
fn selection_handoff_ignored_read_only_edits_preserve_output_selection(cx: &mut TestAppContext) {
    let _lock = selection::test_state_lock();
    let _cleanup = SelectionCleanup;
    let (_dir, window) = fixture(cx, false);
    let input = window.read_with(cx, |host, _| host.input.clone()).unwrap();
    input.update(cx, |input, _| input.read_only = true);
    let cx = &mut VisualTestContext::from_window(window.into(), cx);
    select_output(&input, cx);
    cx.update(|_, cx| cx.write_to_clipboard(ClipboardItem::new_string("!".into())));
    action(cx, Paste);
    action(cx, Cut);
    cx.update(|window, cx| {
        input.update(cx, |input, cx| {
            input.replace_text_in_range(None, "!", window, cx);
            input.replace_and_mark_text_in_range(None, "!", None, window, cx);
        })
    });
    assert_eq!(selection::selected_text().as_deref(), Some(OUTPUT));
    input.read_with(cx, |input, _| assert_eq!(input.text(), DRAFT));
    action(cx, Copy);
    assert_eq!(clipboard(cx).as_deref(), Some(OUTPUT));
}
