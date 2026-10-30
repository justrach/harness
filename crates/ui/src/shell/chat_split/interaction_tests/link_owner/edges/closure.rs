use super::*;

fn spawn(
    source: &Entity<Transcript>,
    source_id: &str,
    doc: &str,
    frozen: bool,
    cx: &mut gpui::VisualTestContext,
) {
    source.update(cx, |_, cx| {
        cx.emit(TranscriptEvent::OpenSubagent {
            chat_id: source_id.into(),
            doc_id: doc.into(),
            title: "Child".into(),
            frozen,
        })
    });
    draw(cx);
}

fn close(shell: &Entity<Shell>, id: u64, cx: &mut gpui::VisualTestContext) {
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.close_right_surface(RightSurface::Subagent(id), window, cx)
        });
    });
    draw(cx);
}

#[gpui::test]
fn closed_child_links_stay_revoked_when_the_same_document_reopens(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for frozen in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            promote(&shell, cx);
            spawn(&peer, "peer", "child", frozen, cx);
            let (id, child) = shell.read_with(cx, |shell, _| {
                (
                    shell.subagent_seq,
                    shell.subagent_tabs[&shell.subagent_seq].transcript.clone(),
                )
            });
            // A menu holds this callback independently of the tab entity.
            let retained = links(&child, cx);
            close(&shell, id, cx);
            for reopen in [false, true] {
                if reopen {
                    spawn(&peer, "peer", "child", frozen, cx);
                }
                cx.update(|window, cx| {
                    for action in [LinkAction::Primary, LinkAction::Internal, LinkAction::External] {
                        assert_eq!(
                            (retained.handler)(&activation(&retained, action), window, cx),
                            LinkOutcome::Rejected,
                            "closed callback revived: frozen={frozen}, reopened={reopen}, action={action:?}"
                        );
                    }
                });
                shell.read_with(cx, |shell, _| assert!(shell.browsers.is_empty()));
            }
            let replacement = shell.read_with(cx, |shell, _| {
                shell.subagent_tabs[&shell.subagent_seq].transcript.clone()
            });
            assert_ne!(replacement, child);
            let live = links(&replacement, cx);
            cx.update(|window, cx| {
                assert_eq!(
                    (live.handler)(&activation(&live, LinkAction::Internal), window, cx),
                    LinkOutcome::Internal
                );
            });
        });
    }
}

#[gpui::test]
fn removed_owners_release_child_surfaces_but_partial_snapshots_keep_them(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for frozen in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            promote(&shell, cx);
            spawn(&peer, "peer", "child", frozen, cx);
            navigate(&shell, "next", cx);
            shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats_synced = false;
                    state.chats.retain(|chat| chat.id != "peer");
                    state.set_subagent_snapshot("child".into(), vec![reply("Frozen child")]);
                });
                shell.on_state_changed(&shell.state.clone(), cx);
                assert_eq!(
                    shell.subagent_tabs.len(),
                    1,
                    "partial list is not deletion proof"
                );
                shell.state.update(cx, |state, _| state.chats_synced = true);
                shell.on_state_changed(&shell.state.clone(), cx);
                assert!(
                    shell.subagent_tabs.is_empty(),
                    "removed owner leaked child registrations"
                );
                assert!(shell.state.read(cx).sub_transcript("child").is_empty());
                assert!(
                    !shell
                        .right_tabs
                        .values()
                        .flatten()
                        .any(|tab| matches!(tab, RightSurface::Subagent(_)))
                );
            });
            draw(cx);
            let root = shell.read_with(cx, |shell, _| shell.transcript.clone());
            spawn(&root, "next", "child", frozen, cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.subagent_tabs.len(),
                    1,
                    "orphan blocked document reuse"
                );
                assert_eq!(
                    shell.subagent_tabs[&shell.subagent_seq]
                        .transcript
                        .read(cx)
                        .link_ui()
                        .unwrap()
                        .source_session
                        .as_deref(),
                    Some("next")
                );
            });
        });
    }
}

#[gpui::test]
fn nested_links_and_spawns_survive_closing_their_parent_tab(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for frozen in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            promote(&shell, cx);
            spawn(&peer, "peer", "child", frozen, cx);
            let (id, child) = shell.read_with(cx, |shell, _| {
                (
                    shell.subagent_seq,
                    shell.subagent_tabs[&shell.subagent_seq].transcript.clone(),
                )
            });
            spawn(&child, "child", "nested", frozen, cx);
            let nested = shell.read_with(cx, |shell, _| {
                shell.subagent_tabs[&shell.subagent_seq].transcript.clone()
            });
            close(&shell, id, cx);
            let live = links(&nested, cx);
            cx.update(|window, cx| {
                assert_eq!(
                    (live.handler)(&activation(&live, LinkAction::Internal), window, cx),
                    LinkOutcome::Internal
                );
            });
            spawn(&nested, "nested", "grandchild", frozen, cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.subagent_tabs.len(), 2);
                assert_eq!(shell.active_chat, "peer");
                assert_eq!(
                    shell.subagent_tabs[&shell.subagent_seq]
                        .transcript
                        .read(cx)
                        .link_ui()
                        .unwrap()
                        .source_session
                        .as_deref(),
                    Some("peer")
                );
            });
            // Retaining a closed entity must not preserve its spawn capability.
            spawn(&child, "child", "closed-child-spawn", frozen, cx);
            shell.read_with(cx, |shell, _| assert_eq!(shell.subagent_tabs.len(), 2));
        });
    }
}
