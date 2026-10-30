use super::*;
use crate::markdown::render::{LinkAction, LinkActivation, LinkOutcome, LinkTarget};

mod edges;

#[gpui::test]
fn promoted_peer_links_follow_primary_navigation(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    const URL: &str = "https://example.com/docs";
    with_panes(
        cx,
        vec![reply(&format!("[Docs]({URL})"))],
        |shell, peer, current, cx| {
            shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(0, cx)));
            assert_peer_active(&shell, &peer, &current, cx);
            let old_link = peer.read_with(cx, |transcript, _| transcript.link_ui().unwrap());

            shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, cx| {
                    state.chats.push(
                        serde_json::from_value(serde_json::json!({
                            "id": "next", "deviceId": "local", "title": "Next",
                            "archived": false, "createdAt": Utc::now(),
                        }))
                        .unwrap(),
                    );
                    state.select_chat(Some("next".into()), cx);
                    let mut entry = reply(&format!("[Docs]({URL})"));
                    entry.id = "next-reply".into();
                    state.transcript = vec![entry];
                    state.transcript_replayed = true;
                    state.transcript_revision += 1;
                    cx.notify();
                });
            });
            draw(cx);
            let link = shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.transcript, peer,
                    "navigation must reuse the promoted entity"
                );
                assert_eq!(shell.active_chat, "next");
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("next"));
                shell.transcript.read(cx).link_ui().unwrap()
            });
            assert_eq!(link.source_session.as_deref(), Some("next"));

            // Exercise the actual rendered link, not only a fabricated activation.
            let before = shell.read_with(cx, |shell, _| shell.browsers.len());
            cx.simulate_click(text_point(&peer, "next-reply#text.0:0"), Default::default());
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.browsers.len(),
                    before + 1,
                    "the first click must open a tab"
                );
                assert_eq!(
                    shell.browsers[&shell.browser_seq]
                        .read(cx)
                        .page
                        .url
                        .as_deref(),
                    Some(URL)
                );
                assert_eq!(
                    shell.resolved_right_active(cx),
                    RightSurface::Browser(shell.browser_seq)
                );
            });

            cx.update(|window, cx| {
                for (action, expected) in [
                    (LinkAction::Primary, LinkOutcome::Internal),
                    (LinkAction::Internal, LinkOutcome::Internal),
                    (LinkAction::External, LinkOutcome::External(URL.into())),
                ] {
                    let activation = LinkActivation {
                        target: LinkTarget::new("Docs", URL),
                        action,
                        source_session: link.source_session.clone(),
                    };
                    assert_eq!((link.handler)(&activation, window, cx), expected);
                    let stale = LinkActivation {
                        source_session: old_link.source_session.clone(),
                        ..activation
                    };
                    assert_eq!(
                        (old_link.handler)(&stale, window, cx),
                        LinkOutcome::Rejected
                    );
                }
            });

            // Demotion must pin the new owner as well, without replacing its view.
            shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(1, cx)));
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.peer_chat_views["next"].transcript, peer);
                assert_eq!(
                    peer.read(cx).link_ui().unwrap().source_session.as_deref(),
                    Some("next")
                );
            });
        },
    );
}
