use super::*;

#[gpui::test]
fn promoted_links_cannot_navigate_after_their_owner_is_archived_or_removed(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for removed in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            promote(&shell, cx);
            navigate(&shell, "next", cx);
            let link = links(&peer, cx);
            cx.update(|window, cx| {
                shell.update(cx, |shell, cx| {
                    shell.state.update(cx, |state, _| {
                        state.chats_synced = true;
                        if removed {
                            state.chats.retain(|chat| chat.id != "next");
                        } else {
                            state
                                .chats
                                .iter_mut()
                                .find(|chat| chat.id == "next")
                                .unwrap()
                                .archived = true;
                        }
                    });
                    for action in [
                        LinkAction::Primary,
                        LinkAction::Internal,
                        LinkAction::External,
                    ] {
                        assert_eq!(
                            shell.activate_session_link(&activation(&link, action), window, cx),
                            LinkOutcome::Rejected
                        );
                    }
                    assert!(shell.browsers.is_empty());
                });
            });
        });
    }
}

#[gpui::test]
fn inactive_parent_spawn_links_use_the_parent_even_from_a_canvas(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for frozen in [false, true] {
        for canvas in [false, true] {
            with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
                shell.update(cx, |shell, cx| {
                    shell.on_state_changed(&shell.state.clone(), cx)
                });
                draw(cx);
                if canvas {
                    shell.update(cx, |shell, cx| {
                        shell
                            .state
                            .update(cx, |state, cx| state.select_chat(None, cx));
                    });
                    draw(cx);
                }
                peer.update(cx, |_, cx| {
                    cx.emit(TranscriptEvent::OpenSubagent {
                        chat_id: "peer".into(),
                        doc_id: "peer--sub--child".into(),
                        title: "Child".into(),
                        frozen,
                    });
                });
                draw(cx);
                let child = shell.read_with(cx, |shell, cx| {
                    assert_eq!(
                        shell.active_chat, "peer",
                        "the emitting parent must own the surface"
                    );
                    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                    let id = shell.subagent_seq;
                    assert!(shell.right_tabs["peer"].contains(&RightSurface::Subagent(id)));
                    shell.subagent_tabs[&id].transcript.clone()
                });
                let link = links(&child, cx);
                assert_eq!(link.source_session.as_deref(), Some("peer"));
                cx.update(|window, cx| {
                    assert_eq!(
                        (link.handler)(&activation(&link, LinkAction::Internal), window, cx),
                        LinkOutcome::Internal
                    );
                });
                // Nested spawn events carry a subagent document ID, not the root chat ID.
                child.update(cx, |_, cx| {
                    cx.emit(TranscriptEvent::OpenSubagent {
                        chat_id: "peer--sub--child".into(),
                        doc_id: "peer--sub--child--sub--nested".into(),
                        title: "Nested".into(),
                        frozen,
                    });
                });
                draw(cx);
                let nested = shell.read_with(cx, |shell, _| {
                    shell.subagent_tabs[&shell.subagent_seq].transcript.clone()
                });
                assert_eq!(links(&nested, cx).source_session.as_deref(), Some("peer"));
                navigate(&shell, "next", cx);
                let parent_link = links(&child, cx);
                assert_eq!(parent_link.source_session.as_deref(), Some("peer"));
                cx.update(|window, cx| {
                    assert_eq!(
                        (parent_link.handler)(
                            &activation(&parent_link, LinkAction::Internal),
                            window,
                            cx
                        ),
                        LinkOutcome::Rejected
                    );
                });
            });
        }
    }
}
