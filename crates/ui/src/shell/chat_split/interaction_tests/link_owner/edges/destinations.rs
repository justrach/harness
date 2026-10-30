use super::*;

fn display(shell: &Entity<Shell>, id: &str, text: &str, cx: &mut gpui::VisualTestContext) {
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, cx| {
            state.prepared_transcripts.remove("next");
            let mut entry = reply(text);
            entry.id = id.into();
            state.transcript = vec![entry];
            state.transcript_revision += 1;
            cx.notify();
        });
    });
    draw(cx);
}

#[gpui::test]
fn invalid_destinations_stay_rejected_and_copyable_after_promotion(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        promote(&shell, cx);
        navigate(&shell, "next", cx);
        let ui = links(&peer, cx);
        cx.update(|window, cx| {
            for url in [
                "javascript:alert",
                "data:text/plain,hello",
                "https://",
                "https:///missing-host",
                "https://example.com/%GG",
                "https://user:pass@example.com/",
                "https://example.com/white space",
                "https://example.com/\ncontrol",
                "https://example.com/\\backslash",
            ] {
                for action in [
                    LinkAction::Primary,
                    LinkAction::Internal,
                    LinkAction::External,
                ] {
                    let request = LinkActivation {
                        target: LinkTarget::new("Unsafe", url),
                        action,
                        source_session: ui.source_session.clone(),
                    };
                    assert_eq!(
                        (ui.handler)(&request, window, cx),
                        LinkOutcome::Rejected,
                        "accepted {url:?} with {action:?}"
                    );
                }
            }
        });
        display(&shell, "unsafe-link", "[Unsafe](javascript:alert)", cx);
        let source = text_point(&peer, "unsafe-link#text.0:0");
        for label in [
            "Open in Harness",
            "Open in external browser",
            "Copy link address",
        ] {
            cx.simulate_mouse_down(source, MouseButton::Right, Default::default());
            cx.simulate_mouse_up(source, MouseButton::Right, Default::default());
            draw(cx);
            let row = cx.debug_bounds(label).unwrap();
            cx.simulate_click(row.center(), Default::default());
            draw(cx);
            shell.read_with(cx, |shell, _| assert!(shell.browsers.is_empty()));
        }
        cx.update(|_, cx| {
            assert_eq!(
                cx.read_from_clipboard().unwrap().text().as_deref(),
                Some("javascript:alert")
            )
        });
    });
}

#[gpui::test]
fn wrapped_unicode_labels_keep_the_full_destination_after_resizing(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        promote(&shell, cx);
        navigate(&shell, "next", cx);
        shell.update(cx, |shell, _| {
            shell.chat_split.as_mut().unwrap().axis = SplitAxis::Vertical
        });
        let url = format!(
            "https://example.com/{}?query=%E6%96%87%E6%A1%A3#details",
            "long-segment/".repeat(60)
        );
        let markdown = format!(
            "[文档 🔗 — follow this documentation link across wrapped lines safely]({url})"
        );
        display(&shell, "wrapped-link", &markdown, cx);
        for (round, width) in [600.0, 960.0, 420.0].into_iter().enumerate() {
            cx.simulate_resize(gpui::size(px(width), px(640.0)));
            draw(cx);
            let point = text_point(&peer, "wrapped-link#text.0:0");
            cx.simulate_click(point, Default::default());
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.browsers.len(), round + 1);
                assert_eq!(
                    shell.browsers[&shell.browser_seq]
                        .read(cx)
                        .page
                        .url
                        .as_deref(),
                    Some(url.as_str())
                );
            });
            cx.simulate_mouse_down(point, MouseButton::Right, Default::default());
            cx.simulate_mouse_up(point, MouseButton::Right, Default::default());
            draw(cx);
            let copy = cx.debug_bounds("Copy link address").unwrap();
            cx.simulate_click(copy.center(), Default::default());
            draw(cx);
            cx.update(|_, cx| {
                assert_eq!(
                    cx.read_from_clipboard().unwrap().text().as_deref(),
                    Some(url.as_str())
                )
            });
        }
    });
}
