use super::*;
use navigation_tests::fixture;

#[gpui::test]
fn reopen_closed_middle_pane_restores_uneven_sizes(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, false, None);
    press(cx, window, "mod-d");
    press(cx, window, "mod-d");
    let original = window
        .update(cx, |shell, window, cx| {
            shell.chat_split.as_mut().unwrap().shares = vec![0.2, 0.3, 0.5];
            shell.focus_chat_pane(1, window, cx);
            shell.park_chat_tab(cx)
        })
        .unwrap();
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-shift-t");
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(shell.park_chat_tab(cx), original)
        })
        .unwrap();
}

#[gpui::test]
fn reopen_closed_parent_tab_then_its_pane_in_reverse_order(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, false, None);
    press(cx, window, "mod-d");
    let original = window
        .update(cx, |shell, _, cx| shell.park_chat_tab(cx))
        .unwrap();
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-t");
    window
        .update(cx, |shell, window, cx| shell.switch_chat_tab(0, window, cx))
        .unwrap();
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-shift-t");
    press(cx, window, "mod-shift-t");
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(shell.chat_tab, 0);
            assert_eq!(shell.park_chat_tab(cx), original);
            assert!(shell.closed_chat_tabs.is_empty());
        })
        .unwrap();
}

#[gpui::test]
fn reopen_closed_pane_with_changed_axis_keeps_history_and_surviving_panes(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = fixture(cx, false, None);
    press(cx, window, "mod-d");
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-shift-d");
    let current = window
        .update(cx, |shell, _, cx| shell.park_chat_tab(cx))
        .unwrap();
    press(cx, window, "mod-shift-t");
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(shell.park_chat_tab(cx), current);
            assert_eq!(shell.closed_chat_tabs.len(), 1);
            assert!(
                shell
                    .sidebar_notice
                    .as_ref()
                    .unwrap()
                    .contains("split direction")
            );
        })
        .unwrap();
}

pub(in crate::shell) fn mutations(
    requests: &mut tokio::sync::mpsc::Receiver<String>,
) -> Vec<serde_json::Value> {
    let mut result = Vec::new();
    while let Ok(request) = requests.try_recv() {
        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
        if request["method"] == methods::MUTATE {
            result.push(request);
        }
    }
    result
}

pub(in crate::shell) fn reply(
    runtime: &tokio::runtime::Runtime,
    replies: &tokio::sync::mpsc::Sender<String>,
    request: &serde_json::Value,
) {
    runtime.block_on(async {
        replies
            .send(serde_json::json!({"id": request["id"], "ok": {}}).to_string())
            .await
            .unwrap();
        while replies.capacity() < replies.max_capacity() {
            tokio::task::yield_now().await;
        }
    });
}

#[gpui::test]
fn reopen_closed_pane_and_tab_archive_shortcut_matrix(cx: &mut gpui::TestAppContext) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    for scope in ["pane", "tab", "last session"] {
        for preference in [false, true] {
            for cmd_w in [false, true] {
                // Choose the opposite of the saved preference; ⌘⌥W never archives.
                let archive = cmd_w && !preference;
                for completed in [false, true] {
                    let (_dir, window) = fixture(cx, false, None);
                    cx.update(|cx| settings::set_archive_sessions_on_close(preference, cx));
                    if scope != "last session" {
                        press(cx, window, if scope == "pane" { "mod-d" } else { "mod-t" });
                        window
                            .update(cx, |shell, _, cx| {
                                shell.open_chat("peer".into(), cx);
                                shell.chat_split_on_state_changed(cx);
                            })
                            .unwrap();
                    }
                    let (out, mut requests) = tokio::sync::mpsc::channel(128);
                    let (replies, inbound) = tokio::sync::mpsc::channel(128);
                    let engine = crate::state::EngineHandle::from_test_client(
                        harness_rpc::RpcClient::new(out, inbound),
                    );
                    let original = window
                        .update(cx, |shell, _, cx| {
                            shell
                                .state
                                .update(cx, |state, _| state.set_test_engine(engine));
                            shell.park_chat_tab(cx)
                        })
                        .unwrap();
                    press(cx, window, if cmd_w { "mod-w" } else { "mod-alt-w" });
                    if cmd_w {
                        window
                            .update(cx, |shell, window, cx| {
                                assert!(shell.archive_choice_prompt);
                                assert!(shell.choose_close_archiving(archive, window, cx));
                                assert_eq!(settings::archive_sessions_on_close(cx), preference);
                            })
                            .unwrap();
                        cx.run_until_parked();
                    }
                    let closing = mutations(&mut requests);
                    assert_eq!(
                        closing.len(),
                        usize::from(archive),
                        "{scope}: close cmd_w={cmd_w}, preference={preference}"
                    );
                    if archive {
                        assert_eq!(
                            closing[0]["params"]["chatId"],
                            original.selected.as_deref().unwrap()
                        );
                        assert_eq!(closing[0]["params"]["archived"], true);
                        if completed {
                            reply(&runtime, &replies, &closing[0]);
                            cx.run_until_parked();
                            window
                                .update(cx, |shell, _, cx| {
                                    shell.state.update(cx, |state, cx| {
                                        state.chats_synced = true;
                                        state
                                            .chats
                                            .iter_mut()
                                            .find(|chat| {
                                                Some(&chat.id) == original.selected.as_ref()
                                            })
                                            .unwrap()
                                            .archived = true;
                                        cx.notify();
                                    });
                                })
                                .unwrap();
                            cx.run_until_parked();
                        }
                    }
                    press(cx, window, "mod-shift-t");
                    if archive {
                        if !completed {
                            assert!(
                                mutations(&mut requests).is_empty(),
                                "undo waits for its archive"
                            );
                            reply(&runtime, &replies, &closing[0]);
                            cx.run_until_parked();
                        }
                        let undo = mutations(&mut requests);
                        assert_eq!(
                            undo.len(),
                            1,
                            "{scope}: unarchive exactly the closed session"
                        );
                        assert_eq!(
                            undo[0]["params"]["chatId"],
                            original.selected.as_deref().unwrap()
                        );
                        assert_eq!(undo[0]["params"]["archived"], false);
                        reply(&runtime, &replies, &undo[0]);
                        cx.run_until_parked();
                    } else {
                        assert!(
                            mutations(&mut requests).is_empty(),
                            "plain reopen must not mutate archive state"
                        );
                    }
                    window.update(cx, |shell, window, cx| {
                        assert_eq!(shell.park_chat_tab(cx), original,
                            "{scope}: cmd_w={cmd_w}, preference={preference}, completed={completed}");
                        assert!(shell.chat_tab_unarchiving.is_empty());
                        assert!(shell.state.read(cx).chats.iter().all(|chat| !chat.archived));
                        window.remove_window();
                    }).unwrap();
                }
            }
        }
    }
}

#[gpui::test]
fn reopen_closed_panes_preserves_new_edits_in_surviving_canvas(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, false, None);
    press(cx, window, "mod-d");
    let draft = |text: &str| {
        Some(CanvasDraft {
            input: Some(crate::pickers::CanvasInput {
                text: text.into(),
                ..Default::default()
            }),
            ..Default::default()
        })
    };
    window
        .update(cx, |shell, _, cx| {
            shell.adopt_canvas_draft(draft("first pane"), cx)
        })
        .unwrap();
    press(cx, window, "mod-d");
    window
        .update(cx, |shell, _, cx| {
            shell.adopt_canvas_draft(draft("second pane"), cx)
        })
        .unwrap();
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-shift-t");
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "first pane"
            );
            shell.adopt_canvas_draft(draft("edited surviving pane"), cx);
        })
        .unwrap();
    press(cx, window, "mod-shift-t");
    window
        .update(cx, |shell, window, cx| {
            let split = shell.chat_split.as_ref().unwrap();
            assert_eq!(split.panes.len(), 3);
            assert_eq!(split.focus, 2);
            assert_eq!(split.shares, vec![1.0 / 3.0; 3]);
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "second pane"
            );
            shell.focus_chat_pane(1, window, cx);
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "edited surviving pane"
            );
        })
        .unwrap();
}

#[gpui::test]
fn reopen_closed_pane_finds_its_tab_after_switching_and_reordering(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, false, None);
    press(cx, window, "mod-d");
    let original = window
        .update(cx, |shell, _, cx| shell.park_chat_tab(cx))
        .unwrap();
    press(cx, window, "mod-alt-w");
    press(cx, window, "mod-t");
    press(cx, window, "mod-t");
    window
        .update(cx, |shell, _, cx| shell.move_chat_tab(0, 2, cx))
        .unwrap();
    press(cx, window, "mod-shift-t");
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(
                shell.chat_tabs.len(),
                3,
                "must not duplicate the parent tab"
            );
            assert_eq!(shell.chat_tab, 2);
            assert_eq!(shell.park_chat_tab(cx), original);
        })
        .unwrap();
}

pub(in crate::shell) fn press(
    cx: &mut gpui::TestAppContext,
    window: gpui::WindowHandle<Shell>,
    combo: &str,
) {
    let combo = match combo {
        "mod-shift-t" => crate::settings::ShortcutId::ReopenClosedTab.default_combo(),
        "mod-alt-w" => crate::settings::ShortcutId::CloseTabWithoutArchiving.default_combo(),
        "mod-t" => crate::settings::ShortcutId::NewSession.default_combo(),
        "mod-w" if !cfg!(target_os = "macos") => "ctrl-shift-w",
        "mod-d" if !cfg!(target_os = "macos") => "ctrl-shift-o",
        "mod-shift-d" if !cfg!(target_os = "macos") => "ctrl-shift-e",
        combo => combo,
    };
    let keystroke = gpui::Keystroke::parse(&platform_combo(combo)).unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        window.activate_window();
        window.draw(cx).clear();
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
    })
    .unwrap();
    cx.run_until_parked();
}

#[gpui::test]
fn reopen_closed_pane_after_cmd_d_and_both_close_shortcuts(cx: &mut gpui::TestAppContext) {
    for split_key in ["mod-d", "mod-shift-d"] {
        for close_key in ["mod-w", "mod-alt-w"] {
            for focus in [0, 1] {
                let (_dir, window) = fixture(cx, false, None);
                // A saved preference does not bypass the per-close choice.
                cx.update(|cx| settings::set_archive_sessions_on_close(false, cx));
                press(cx, window, split_key);
                let original = window
                    .update(cx, |shell, window, cx| {
                        shell.open_chat("peer".into(), cx);
                        shell.chat_split_on_state_changed(cx);
                        shell.focus_chat_pane(focus, window, cx);
                        shell.park_chat_tab(cx)
                    })
                    .unwrap();
                press(cx, window, close_key);
                if close_key == "mod-w" {
                    window
                        .update(cx, |shell, window, cx| {
                            assert!(shell.choose_close_archiving(false, window, cx));
                        })
                        .unwrap();
                }
                window
                    .update(cx, |shell, _, _| {
                        assert!(shell.chat_split.is_none(), "two panes collapse to one");
                    })
                    .unwrap();
                press(cx, window, "mod-shift-t");
                window
                    .update(cx, |shell, window, cx| {
                        assert_eq!(
                            shell.park_chat_tab(cx),
                            original,
                            "{split_key}, {close_key}, pane {focus}: restore in the same pane"
                        );
                        assert!(shell.chat_tabs.is_empty(), "reopen a pane, not a new tab");
                        window.remove_window();
                    })
                    .unwrap();
            }
        }
    }
}
