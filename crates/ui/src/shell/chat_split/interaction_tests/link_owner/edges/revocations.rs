use super::*;

#[gpui::test]
fn revoked_owners_cannot_open_or_reactivate_child_tabs(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for removed in [false, true] {
        for frozen in [false, true] {
            for nested in [false, true] {
                with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
                    promote(&shell, cx);
                    peer.update(cx, |_, cx| {
                        cx.emit(TranscriptEvent::OpenSubagent {
                            chat_id: "peer".into(),
                            doc_id: "registered-child".into(),
                            title: "Child".into(),
                            frozen: false,
                        })
                    });
                    draw(cx);
                    shell.update(cx, |shell, cx| {
                        let child = shell.subagent_tabs[&shell.subagent_seq].transcript.clone();
                        shell.state.update(cx, |state, _| {
                            state.chats_synced = true;
                            if removed {
                                state.chats.retain(|chat| chat.id != "peer");
                            } else {
                                state
                                    .chats
                                    .iter_mut()
                                    .find(|chat| chat.id == "peer")
                                    .unwrap()
                                    .archived = true;
                            }
                        });
                        // Revoke before observers reconcile the selected pane.
                        shell.set_surfaces_open(false, cx);
                        let before = (
                            shell.subagent_seq,
                            shell.right_tabs.clone(),
                            shell.panels.map.clone(),
                            shell.chat_split.clone(),
                        );
                        for doc in ["registered-child", "new-child"] {
                            shell.on_transcript_event(
                                if nested { child.clone() } else { peer.clone() },
                                &TranscriptEvent::OpenSubagent {
                                    chat_id: if nested { "registered-child" } else { "peer" }
                                        .into(),
                                    doc_id: doc.into(),
                                    title: "Queued child".into(),
                                    frozen,
                                },
                                cx,
                            );
                            assert_eq!(
                                (
                                    shell.subagent_seq,
                                    shell.right_tabs.clone(),
                                    shell.panels.map.clone(),
                                    shell.chat_split.clone()
                                ),
                                before
                            );
                            assert_eq!(shell.active_chat, "peer");
                            assert_eq!(shell.subagent_tabs.len(), 1);
                        }
                    });
                });
            }
        }
    }
}

#[gpui::test]
fn a_foreign_document_collision_is_rejected_without_selecting_an_invisible_tab(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for frozen in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            promote(&shell, cx);
            peer.update(cx, |_, cx| {
                cx.emit(TranscriptEvent::OpenSubagent {
                    chat_id: "peer".into(),
                    doc_id: "shared-doc".into(),
                    title: "Child".into(),
                    frozen,
                })
            });
            draw(cx);
            navigate(&shell, "next", cx);
            shell.update(cx, |shell, cx| {
                shell.set_surfaces_open(false, cx);
                let before = (
                    shell.subagent_seq,
                    shell.right_tabs.clone(),
                    shell.panels.map.clone(),
                );
                shell.on_transcript_event(
                    shell.transcript.clone(),
                    &TranscriptEvent::OpenSubagent {
                        chat_id: "next".into(),
                        doc_id: "shared-doc".into(),
                        title: "Conflicting child".into(),
                        frozen,
                    },
                    cx,
                );
                assert_eq!(
                    (
                        shell.subagent_seq,
                        shell.right_tabs.clone(),
                        shell.panels.map.clone()
                    ),
                    before
                );
                assert_eq!(shell.active_chat, "next");
                let original = &shell.subagent_tabs[&shell.subagent_seq];
                assert_eq!(
                    original
                        .transcript
                        .read(cx)
                        .link_ui()
                        .unwrap()
                        .source_session
                        .as_deref(),
                    Some("peer")
                );
            });
        });
    }
}

#[gpui::test]
fn emitting_entity_disambiguates_chat_and_child_document_ids(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for parent_visible in [false, true] {
        for nested_source in [false, true] {
            if nested_source && !parent_visible {
                continue;
            }
            with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
                promote(&shell, cx);
                peer.update(cx, |_, cx| {
                    cx.emit(TranscriptEvent::OpenSubagent {
                        chat_id: "peer".into(),
                        doc_id: "next".into(),
                        title: "Legacy child".into(),
                        frozen: false,
                    })
                });
                draw(cx);
                let child = shell.read_with(cx, |shell, _| {
                    shell.subagent_tabs[&shell.subagent_seq].transcript.clone()
                });
                if parent_visible {
                    shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(1, cx)));
                    draw(cx);
                }
                navigate(&shell, "next", cx);
                let root = shell.read_with(cx, |shell, _| shell.transcript.clone());
                let emitter = if nested_source { child } else { root };
                emitter.update(cx, |_, cx| {
                    cx.emit(TranscriptEvent::OpenSubagent {
                        chat_id: "next".into(),
                        doc_id: "new-nested".into(),
                        title: "Nested".into(),
                        frozen: false,
                    })
                });
                draw(cx);
                shell.read_with(cx, |shell, cx| {
                    let expected = if nested_source { "peer" } else { "next" };
                    assert_eq!(shell.active_chat, expected);
                    assert_eq!(shell.subagent_tabs.len(), 2);
                    let id = shell.subagent_seq;
                    assert_eq!(
                        shell.subagent_tabs[&id]
                            .transcript
                            .read(cx)
                            .link_ui()
                            .unwrap()
                            .source_session
                            .as_deref(),
                        Some(expected)
                    );
                    assert!(shell.right_tabs[expected].contains(&RightSurface::Subagent(id)));
                    assert_eq!(shell.resolved_right_active(cx), RightSurface::Subagent(id));
                });
            });
        }
    }
}

#[gpui::test]
fn a_replaced_transcript_cannot_relabel_its_spawn_as_the_active_chat(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
        shell.update(cx, |shell, cx| {
            shell.on_state_changed(&shell.state.clone(), cx);
            shell.chat_split.as_mut().unwrap().panes[0] = Some("replacement".into());
            shell.sync_chat_panes(cx);
            shell.on_transcript_event(
                peer,
                &TranscriptEvent::OpenSubagent {
                    chat_id: "current".into(),
                    doc_id: "stale-child".into(),
                    title: "Stale child".into(),
                    frozen: true,
                },
                cx,
            );
            assert!(shell.subagent_tabs.is_empty());
            assert_eq!(shell.active_chat, "current");
        });
    });
}
