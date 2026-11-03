use super::*;
use crate::markdown::{render, selection};

const QUESTION: &str = "Which synthetic approach should we use?";
const ANSWER: &str = "Keep this unfinished answer";

#[gpui::test]
fn agent_question_selection_copies_with_keyboard_and_menu(cx: &mut gpui::TestAppContext) {
    let _lock = selection::test_state_lock();
    for width in [600.0, 200.0] {
        for focus in ["panel", "answer", "none"] {
            let (_dir, handle) = super::tests::composer_focus_window(cx);
            cx.update(|cx| init(cx, ComposerSendBehavior::Enter));
            let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
            visual.simulate_resize(size(px(1000.0), px(700.0)));
            let input = handle
                .update(cx, |composer, window, cx| {
                    composer.set_available_width(width, cx);
                    composer.set_available_height(700.0, cx);
                    composer.wizard = Some(Wizard::new(
                        "synthetic-question".into(),
                        vec![UserInputQuestion {
                            id: "approach".into(),
                            header: "Agent question".into(),
                            question: QUESTION.into(),
                            options: vec!["First approach".into(), "Second approach".into()],
                            prefill: None,
                            multiline: false,
                            multi_select: false,
                        }],
                    ));
                    composer.wizard_expanded = true;
                    composer.input.update(cx, |input, cx| {
                        input.set_text(ANSWER, cx);
                        input.selected_range = 0..ANSWER.len();
                    });
                    match focus {
                        "panel" => window.focus(&composer.wizard_focus, cx),
                        "answer" => window.focus(&composer.input.focus_handle(cx), cx),
                        _ => window.blur(),
                    }
                    cx.notify();
                    composer.input.clone()
                })
                .unwrap();
            visual.run_until_parked();
            visual.update(|window, cx| {
                window.refresh();
                window.draw(cx).clear();
            });
            let bounds = render::selection_test_entries()
                .into_iter()
                .rev()
                .find(|(key, text, _)| key.starts_with("composer-question:") && text == QUESTION)
                .expect("question text must be painted")
                .2;
            let position = bounds.origin + point(px(3.0), px(8.0));
            visual.simulate_event(MouseDownEvent {
                button: MouseButton::Left,
                position,
                click_count: 3,
                ..Default::default()
            });
            visual.simulate_event(MouseUpEvent {
                button: MouseButton::Left,
                position,
                ..Default::default()
            });
            visual.run_until_parked();
            assert_eq!(selection::selected_text().as_deref(), Some(QUESTION));
            visual.update(|window, cx| {
                let input = input.read(cx);
                assert!(
                    input.focus_handle.is_focused(window),
                    "Copy route lacks focus: claim {:?}, range {:?}",
                    input.markdown_selection,
                    input.selected_range
                );
                assert_eq!(input.markdown_selection, selection::current_claim());
            });
            for shortcut in ["cmd-c", "ctrl-c", "menu"] {
                visual.update(|_, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string("unchanged".into()));
                });
                if shortcut == "menu" {
                    visual.update(|window, cx| window.dispatch_action(Box::new(Copy), cx));
                } else {
                    visual.simulate_keystrokes(shortcut);
                }
                visual.run_until_parked();
                assert_eq!(
                    visual.update(|_, cx| cx.read_from_clipboard().and_then(|item| item.text())),
                    Some(QUESTION.into()),
                    "{shortcut}, initial focus {focus}, width {width}"
                );
            }
            input.read_with(&visual, |input, _| assert_eq!(input.text(), ANSWER));
            // Selecting the answer again must return Copy ownership to the editor.
            visual.update(|window, cx| {
                window.focus(&input.focus_handle(cx), cx);
                window.dispatch_action(Box::new(SelectAll), cx);
            });
            visual.run_until_parked();
            visual.simulate_keystrokes("cmd-c");
            visual.run_until_parked();
            assert_eq!(
                visual.update(|_, cx| cx.read_from_clipboard().and_then(|item| item.text())),
                Some(ANSWER.into())
            );
            assert!(selection::selected_text().is_none());
        }
    }
}
