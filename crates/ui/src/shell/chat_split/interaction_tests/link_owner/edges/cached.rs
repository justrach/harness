use super::*;

#[gpui::test]
fn cached_peer_links_survive_role_changes_without_content_updates(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(
        cx,
        vec![reply(&format!("[Docs]({URL})"))],
        |shell, peer, _, cx| {
            let captured = links(&peer, cx);
            for round in 0..3 {
                promote(&shell, cx);
                let before = shell.read_with(cx, |shell, _| shell.browsers.len());
                cx.simulate_click(text_point(&peer, "reply#text.0:0"), Default::default());
                draw(cx);
                shell.read_with(cx, |shell, _| {
                    assert_eq!(shell.transcript, peer);
                    assert_eq!(
                        shell.browsers.len(),
                        before + 1,
                        "cached click failed on round {round}"
                    );
                    assert_eq!(shell.right_tabs["peer"].len(), round + 1);
                });
                shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(1, cx)));
                draw(cx);
                cx.update(|window, cx| {
                    assert_eq!(
                        (captured.handler)(
                            &activation(&captured, LinkAction::External),
                            window,
                            cx
                        ),
                        LinkOutcome::External(URL.into())
                    );
                });
                shell.read_with(cx, |shell, _| {
                    assert_eq!(
                        shell.active_chat, "current",
                        "external routing must not steal focus"
                    );
                });
            }
        },
    );
}
