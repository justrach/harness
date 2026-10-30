use super::*;

#[gpui::test]
fn stale_and_hidden_parent_events_cannot_open_subagent_surfaces(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for hidden in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            shell.update(cx, |shell, cx| {
                shell.on_state_changed(&shell.state.clone(), cx);
                if hidden {
                    shell.chat_split.as_mut().unwrap().zoomed = true;
                } else {
                    shell.chat_split.as_mut().unwrap().panes[0] = Some("replacement".into());
                    shell.sync_chat_panes(cx);
                }
            });
            draw(cx);
            peer.update(cx, |_, cx| {
                cx.emit(TranscriptEvent::OpenSubagent {
                    chat_id: "peer".into(),
                    doc_id: "peer--sub--stale".into(),
                    title: "Stale child".into(),
                    frozen: true,
                });
            });
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert!(shell.subagent_tabs.is_empty());
                assert!(shell.browsers.is_empty());
                assert_eq!(shell.active_chat, "current");
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
            });
        });
    }
}

#[gpui::test]
fn opening_a_peer_child_parks_the_canvas_draft_and_reuses_its_tab(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        shell.update(cx, |shell, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
        });
        draw(cx);
        let composer = shell.read_with(cx, |shell, _| shell.composer.clone());
        composer.update(cx, |composer, cx| {
            composer.prefill("Keep this unsent draft".into(), cx)
        });
        for round in 0..2 {
            peer.update(cx, |_, cx| {
                cx.emit(TranscriptEvent::OpenSubagent {
                    chat_id: "peer".into(),
                    doc_id: "peer--sub--child".into(),
                    title: "Child".into(),
                    frozen: true,
                });
            });
            draw(cx);
            shell.read_with(cx, |shell, _| {
                assert_eq!(shell.active_chat, "peer");
                assert_eq!(shell.subagent_tabs.len(), 1);
                assert_eq!(shell.right_tabs["peer"].len(), 1);
            });
            shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(1, cx)));
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert!(shell.active_chat.is_empty());
                assert_eq!(
                    shell.composer.read(cx).input.read(cx).text(),
                    "Keep this unsent draft",
                    "draft lost on round {round}"
                );
            });
        }
    });
}
