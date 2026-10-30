use super::*;
use std::{cell::RefCell, rc::Rc};

#[gpui::test]
fn promoted_links_route_pointer_menu_actions_and_external_default(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        promote(&shell, cx);
        navigate(&shell, "next", cx);
        let original = links(&peer, cx);
        assert_eq!(original.source_session.as_deref(), Some("next"));
        let seen = Rc::new(RefCell::new(Vec::new()));
        let capture = seen.clone();
        peer.update(cx, |transcript, _| {
            transcript.set_workspace_link_handler(LinkUi {
                source_session: None,
                handler: Rc::new(move |activation, window, cx| {
                    let outcome = (original.handler)(activation, window, cx);
                    capture.borrow_mut().push((activation.clone(), outcome));
                    // Observe real shell routing without launching an OS browser.
                    LinkOutcome::Rejected
                }),
            });
        });
        cx.update(|_, cx| {
            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                settings.open_web_links_in_harness = false;
            });
        });
        draw(cx);
        cx.simulate_click(
            text_point(&peer, "next-link-reply#text.0:0"),
            Default::default(),
        );
        draw(cx);
        assert_eq!(seen.borrow().last().unwrap().0.action, LinkAction::Primary);
        assert_eq!(
            seen.borrow().last().unwrap().1,
            LinkOutcome::External(URL.into())
        );

        for (label, action) in [
            ("Open in Harness", LinkAction::Internal),
            ("Open in external browser", LinkAction::External),
            ("Copy link address", LinkAction::Copy),
        ] {
            open_menu(&peer, "next", cx);
            let before = seen.borrow().len();
            let row = cx.debug_bounds(label).unwrap();
            cx.simulate_click(row.center(), Default::default());
            draw(cx);
            if action == LinkAction::Copy {
                assert_eq!(seen.borrow().len(), before);
                cx.update(|_, cx| {
                    assert_eq!(
                        cx.read_from_clipboard().unwrap().text().as_deref(),
                        Some(URL)
                    );
                });
            } else {
                let seen = seen.borrow();
                assert_eq!(seen.len(), before + 1);
                let (activation, outcome) = seen.last().unwrap();
                assert_eq!(activation.action, action);
                assert_eq!(activation.source_session.as_deref(), Some("next"));
                assert_eq!(
                    *outcome,
                    if action == LinkAction::Internal {
                        LinkOutcome::Internal
                    } else {
                        LinkOutcome::External(URL.into())
                    }
                );
            }
        }
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.browsers.len(), 1);
            assert_eq!(shell.right_tabs["next"].len(), 1);
        });
    });
}

#[gpui::test]
fn keyboard_menu_open_after_promotion_ignores_external_default(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        promote(&shell, cx);
        navigate(&shell, "next", cx);
        cx.update(|_, cx| {
            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                settings.open_web_links_in_harness = false;
            });
        });
        open_menu(&peer, "next", cx);
        cx.update(|window, cx| {
            let keystroke = gpui::Keystroke::parse("enter").unwrap();
            window.dispatch_event(
                gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                    keystroke: keystroke.clone(),
                    is_held: false,
                    prefer_character_input: false,
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke }),
                cx,
            );
        });
        draw(cx);
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.browsers.len(), 1);
            assert_eq!(shell.right_tabs["next"].len(), 1);
            assert_eq!(
                shell.browsers[&shell.browser_seq]
                    .read(cx)
                    .page
                    .url
                    .as_deref(),
                Some(URL)
            );
        });
    });
}
