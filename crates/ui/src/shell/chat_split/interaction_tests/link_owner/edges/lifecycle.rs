use super::*;

#[gpui::test]
fn repeated_promotions_and_navigation_keep_links_in_their_own_chat(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, _, _, cx| {
        for round in 0..4 {
            let pane = round % 2;
            let incoming = shell.read_with(cx, |shell, _| {
                let id = shell.chat_split.as_ref().unwrap().panes[pane]
                    .as_ref()
                    .unwrap();
                shell.peer_chat_views[id].transcript.clone()
            });
            shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(pane, cx)));
            draw(cx);
            let chat = format!("round-{round}");
            navigate(&shell, &chat, cx);
            shell.read_with(cx, |shell, _| assert_eq!(shell.transcript, incoming));
            click_current_link(&shell, &chat, cx);
        }
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.browsers.len(), 4);
            for round in 0..4 {
                assert_eq!(shell.right_tabs[&format!("round-{round}")].len(), 1);
            }
        });
    });
}

#[gpui::test]
fn closing_a_promoted_pane_leaves_single_pane_links_live(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        promote(&shell, cx);
        navigate(&shell, "next", cx);
        let old = links(&peer, cx);
        cx.update(|window, cx| {
            shell.update(cx, |shell, cx| {
                assert!(shell.close_focused_chat_pane_without_archiving(window, cx));
            });
        });
        draw(cx);
        shell.read_with(cx, |shell, _| {
            assert!(shell.chat_split.is_none());
            assert_eq!(shell.active_chat, "current");
        });
        navigate(&shell, "current", cx);
        let point = text_point(&peer, "current-link-reply#text.0:0");
        let pane = cx.debug_bounds("peer-column").unwrap();
        assert!(
            pane.contains(&point),
            "link point {point:?} is outside the surviving pane {pane:?}"
        );
        open_menu(&peer, "current", cx);
        cx.simulate_keystrokes("escape");
        draw(cx);
        click_current_link(&shell, "current", cx);
        cx.update(|window, cx| {
            assert_eq!(
                (old.handler)(&activation(&old, LinkAction::Internal), window, cx),
                LinkOutcome::Rejected
            );
        });
    });
}

#[gpui::test]
fn canvas_exit_rejects_retained_links_and_new_chat_links_recover(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        promote(&shell, cx);
        navigate(&shell, "next", cx);
        let old = links(&peer, cx);
        shell.update(cx, |shell, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
        });
        draw(cx);
        let before = shell.read_with(cx, |shell, cx| {
            assert!(shell.active_chat.is_empty());
            assert!(shell.state.read(cx).selected_chat.is_none());
            shell.browsers.len()
        });
        cx.update(|window, cx| {
            for action in [
                LinkAction::Primary,
                LinkAction::Internal,
                LinkAction::External,
            ] {
                assert_eq!(
                    (old.handler)(&activation(&old, action), window, cx),
                    LinkOutcome::Rejected
                );
            }
        });
        shell.read_with(cx, |shell, _| assert_eq!(shell.browsers.len(), before));
        navigate(&shell, "after-canvas", cx);
        click_current_link(&shell, "after-canvas", cx);
    });
}

#[gpui::test]
fn replacing_a_peer_revokes_its_old_callback(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        let old = links(&peer, cx);
        shell.update(cx, |shell, cx| {
            shell.chat_split.as_mut().unwrap().panes[0] = Some("replacement".into());
            shell.sync_chat_panes(cx);
        });
        draw(cx);
        shell.read_with(cx, |shell, cx| {
            assert!(!shell.peer_chat_views.contains_key("peer"));
            assert_eq!(
                shell.peer_chat_views["replacement"]
                    .transcript
                    .read(cx)
                    .link_ui()
                    .unwrap()
                    .source_session
                    .as_deref(),
                Some("replacement")
            );
        });
        cx.update(|window, cx| {
            for action in [
                LinkAction::Primary,
                LinkAction::Internal,
                LinkAction::External,
            ] {
                assert_eq!(
                    (old.handler)(&activation(&old, action), window, cx),
                    LinkOutcome::Rejected
                );
            }
        });
        shell.read_with(cx, |shell, _| assert!(shell.browsers.is_empty()));
    });
}
