use super::*;
use std::{cell::RefCell, rc::Rc};

#[gpui::test]
fn an_open_menu_rechecks_ownership_when_its_chat_is_revoked(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for removed in [false, true] {
        for label in ["Open in Harness", "Open in external browser"] {
            with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
                promote(&shell, cx);
                navigate(&shell, "next", cx);
                let original = links(&peer, cx);
                let seen = Rc::new(RefCell::new(Vec::new()));
                let capture = seen.clone();
                peer.update(cx, |transcript, _| {
                    transcript.set_workspace_link_handler(LinkUi {
                        source_session: None,
                        handler: Rc::new(move |activation, window, cx| {
                            let result = (original.handler)(activation, window, cx);
                            capture.borrow_mut().push(result.clone());
                            LinkOutcome::Rejected
                        }),
                    })
                });
                draw(cx);
                open_menu(&peer, "next", cx);
                let action = cx.debug_bounds(label).unwrap();
                // A registry snapshot can revoke the owner before its observers run.
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
                    })
                });
                cx.simulate_click(action.center(), Default::default());
                draw(cx);
                assert_eq!(seen.borrow().as_slice(), &[LinkOutcome::Rejected]);
                shell.read_with(cx, |shell, _| assert!(shell.browsers.is_empty()));
            });
        }
    }
}

#[gpui::test]
fn unregistered_and_mid_transition_sources_cannot_open_child_tabs(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for pending_selection in [false, true] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            shell.update(cx, |shell, cx| {
                shell.on_state_changed(&shell.state.clone(), cx);
                if pending_selection {
                    shell
                        .state
                        .update(cx, |state, _| state.selected_chat = Some("peer".into()));
                }
                shell.on_transcript_event(
                    peer,
                    &TranscriptEvent::OpenSubagent {
                        chat_id: if pending_selection {
                            "peer"
                        } else {
                            "peer--sub--closed"
                        }
                        .into(),
                        doc_id: "peer--sub--closed--sub--new".into(),
                        title: "Queued child".into(),
                        frozen: true,
                    },
                    cx,
                );
                assert!(shell.subagent_tabs.is_empty());
                assert!(shell.browsers.is_empty());
                assert_eq!(shell.active_chat, "current");
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some(if pending_selection { "peer" } else { "current" })
                );
            });
        });
    }
}

#[gpui::test]
fn nested_children_preserve_registered_parent_lineage_and_harness(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for child_doc in ["peer--sub--child", "legacy-child"] {
        with_panes(cx, vec![reply("Peer response")], |shell, peer, _, cx| {
            promote(&shell, cx);
            shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, cx| {
                    state
                        .chats
                        .iter_mut()
                        .find(|chat| chat.id == "peer")
                        .unwrap()
                        .config = Some(harness_proto::ChatConfig {
                        harness: harness_proto::HarnessId::Codex,
                        model: None,
                        reasoning: None,
                        model_options: Default::default(),
                        sandbox: harness_proto::SandboxLevel::WorkspaceWrite,
                        chat_mode: false,
                    });
                    cx.notify();
                })
            });
            peer.update(cx, |_, cx| {
                cx.emit(TranscriptEvent::OpenSubagent {
                    chat_id: "peer".into(),
                    doc_id: child_doc.into(),
                    title: "Child".into(),
                    frozen: false,
                })
            });
            draw(cx);
            let child = shell.read_with(cx, |shell, _| {
                assert_eq!(
                    shell.subagent_tabs[&shell.subagent_seq].harness,
                    Some(harness_proto::HarnessId::Codex)
                );
                shell.subagent_tabs[&shell.subagent_seq].transcript.clone()
            });
            // A later parent run can choose another harness; an existing child did not.
            shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, cx| {
                    state
                        .chats
                        .iter_mut()
                        .find(|chat| chat.id == "peer")
                        .unwrap()
                        .config
                        .as_mut()
                        .unwrap()
                        .harness = harness_proto::HarnessId::Graff;
                    cx.notify();
                })
            });
            child.update(cx, |_, cx| {
                cx.emit(TranscriptEvent::OpenSubagent {
                    chat_id: child_doc.into(),
                    doc_id: "peer--sub--nested".into(),
                    title: "Nested".into(),
                    frozen: false,
                })
            });
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.subagent_tabs.len(),
                    2,
                    "registered legacy document IDs must resolve their owner"
                );
                let nested = &shell.subagent_tabs[&shell.subagent_seq];
                assert_eq!(nested.harness, Some(harness_proto::HarnessId::Codex));
                assert_eq!(
                    nested
                        .transcript
                        .read(cx)
                        .link_ui()
                        .unwrap()
                        .source_session
                        .as_deref(),
                    Some("peer")
                );
                assert_eq!(shell.right_tabs["peer"].len(), 2);
            });
        });
    }
}
