use super::*;
use harness_rpc::{ClientFrame, ServerFrame};
use tokio::sync::mpsc::{Receiver, Sender};

fn pending() -> Vec<SessionMessageEntry> {
    serde_json::from_value(serde_json::json!([{
        "id": "assistant", "role": "assistant", "createdAt": 0,
        "deviceId": "host", "status": "streaming", "parts": [{
            "id": "input", "kind": "input", "requestId": "retry-request",
            "resolved": false, "questions": [{
                "id": "choice", "header": "Choice", "question": "Which approach?",
                "options": ["Yes", "No"], "multiSelect": true
            }]
        }]
    }]))
    .unwrap()
}

fn fixture(cx: &mut gpui::TestAppContext) -> (tempfile::TempDir, gpui::WindowHandle<Composer>) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
    });
    let handle = cx.add_window(|_, cx| {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |s, _| {
            s.selected_chat = Some("question-chat".into());
            s.transcript = pending();
            s.queue = vec![
                serde_json::from_value(serde_json::json!({
                    "id": "row", "text": "queued text", "issuedBy": "host", "issuedAt": 0
                }))
                .unwrap(),
            ];
        });
        let mut composer = Composer::new(state, cx);
        composer.set_available_width(200.0, cx);
        composer.set_available_height(600.0, cx);
        composer.on_state_changed(cx);
        composer.wizard.as_mut().unwrap().select(1);
        composer
            .input
            .update(cx, |i, cx| i.set_text("My answer", cx));
        composer
    });
    (dir, handle)
}

fn engine(
    handle: gpui::WindowHandle<Composer>,
    cx: &mut gpui::TestAppContext,
) -> (Receiver<String>, Sender<String>) {
    let (out, requests) = tokio::sync::mpsc::channel(64);
    let (replies, inbound) = tokio::sync::mpsc::channel(64);
    handle
        .update(cx, |c, _, cx| {
            c.state.update(cx, |s, _| {
                s.set_test_engine(crate::state::EngineHandle::from_test_client(
                    harness_rpc::RpcClient::new(out, inbound),
                ));
            })
        })
        .unwrap();
    (requests, replies)
}

fn request(requests: &mut Receiver<String>, method: &str) -> ClientFrame {
    while let Ok(frame) = requests.try_recv() {
        let frame: ClientFrame = serde_json::from_str(&frame).unwrap();
        if frame.method.as_deref() == Some(method) {
            return frame;
        }
    }
    panic!("missing RPC {method}");
}

fn reply(
    runtime: &tokio::runtime::Runtime,
    replies: &Sender<String>,
    frame: ServerFrame,
    cx: &mut gpui::TestAppContext,
) {
    replies
        .try_send(serde_json::to_string(&frame).unwrap())
        .unwrap();
    runtime.block_on(async { tokio::task::yield_now().await });
    cx.run_until_parked();
}

fn assert_retry(handle: gpui::WindowHandle<Composer>, cx: &mut gpui::TestAppContext) {
    handle
        .read_with(cx, |c, cx| {
            assert!(c.wizard_active());
            assert!(c.wizard_expanded);
            assert!(c.wizard.as_ref().unwrap().is_picked(1));
            assert_eq!(c.input.read(cx).text(), "My answer");
            assert!(!c.answered_requests.contains("retry-request"));
        })
        .unwrap();
    cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
        .unwrap();
    let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
    assert!(visual.debug_bounds("question-popover").is_some());
    assert!(visual.debug_bounds("wizard-submit").is_some());
}

#[gpui::test]
fn cached_question_and_queue_entrances_settle(cx: &mut gpui::TestAppContext) {
    struct ActivePane {
        composer: Entity<Composer>,
        cached: bool,
    }
    impl Render for ActivePane {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            let content = if self.cached {
                self.composer
                    .clone()
                    .cached_measured(gpui::StyleRefinement::default().w(px(800.0)))
                    .into_any_element()
            } else {
                self.composer.clone().into_any_element()
            };
            div().size_full().child(content)
        }
    }
    for question in [true, false] {
        for cached in [false, true] {
            let (_dir, original) = fixture(cx);
            cx.update(|cx| crate::motion::set_reduced_motion(cx, false));
            let composer = original
                .update(cx, |composer, _, cx| {
                    if !question {
                        composer.wizard = None;
                        composer
                            .state
                            .update(cx, |state, _| state.transcript.clear());
                        composer.on_state_changed(cx);
                        composer
                            .input
                            .update(cx, |input, cx| input.set_text("", cx));
                    }
                    composer.set_available_width(800.0, cx);
                    composer.set_available_height(900.0, cx);
                    cx.entity()
                })
                .unwrap();
            let pane = cx.add_window(|_, _| ActivePane {
                composer: composer.clone(),
                cached,
            });
            cx.update_window(original.into(), |_, window, _| window.remove_window())
                .unwrap();
            cx.update_window(pane.into(), |_, window, _| {
                window.resize(size(px(900.0), px(900.0)));
            })
            .unwrap();
            crate::motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| *samples = Some(Vec::new()));
            let target: gpui::ElementId = if question {
                "composer-wizard"
            } else {
                "composer-queue"
            }
            .into();
            let mut observed = 0;
            let mut settled_observed = 0;
            for frame in 0..90 {
                // The entrance uses scheduler::Instant's wall clock, not the
                // executor's virtual timer clock in this test environment.
                std::thread::sleep(Duration::from_millis(16));
                if frame % 10 == 0 {
                    composer.update(cx, |_, cx| cx.notify());
                }
                pane.update(cx, |_, _, cx| cx.notify()).unwrap();
                cx.update_window(pane.into(), |_, window, cx| {
                    window.simulate_next_frame(cx);
                    window.draw(cx).clear();
                })
                .unwrap();
                crate::motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| {
                    for (id, alpha) in samples.as_mut().unwrap().drain(..) {
                        if id == target {
                            observed += 1;
                            if frame >= 20 {
                                settled_observed += 1;
                                assert!(
                                    alpha >= 0.999,
                                    "{target:?} entrance restarted: cached={cached}, frame={frame}, opacity={alpha}"
                                );
                            }
                        }
                    }
                });
            }
            crate::motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| *samples = None);
            assert!(
                observed > 0 && settled_observed >= 7,
                "{target:?} did not render on the seven post-settle composer notifications"
            );
            cx.update_window(pane.into(), |_, window, _| window.remove_window())
                .unwrap();
        }
    }
}

#[gpui::test]
fn question_returns_after_queue_edit_without_another_state_notification(
    cx: &mut gpui::TestAppContext,
) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    for existing in [false, true] {
        for commit in [false, true] {
            let (_dir, handle) = fixture(cx);
            let (mut requests, replies) = engine(handle, cx);
            handle
                .update(cx, |c, _, cx| {
                    if !existing {
                        c.state.update(cx, |s, _| s.transcript.clear());
                        c.on_state_changed(cx);
                        c.wizard = None;
                        c.input.update(cx, |i, cx| i.set_text("ordinary draft", cx));
                    }
                    c.editing_queued = Some("row".into());
                    c.queue_edit_lease_id = Some("lease".into());
                    c.queue_edit_chat_id = Some("question-chat".into());
                    c.queue_edit_host_device_id = Some("host".into());
                    c.queue_edit_draft =
                        Some((c.input.read(cx).text().to_string(), vec![], vec![]));
                    c.prepare_queue_edit_input(cx);
                    c.input
                        .update(cx, |i, cx| i.set_text("edited queue row", cx));
                    if !existing {
                        c.state.update(cx, |s, _| s.transcript = pending());
                        c.on_state_changed(cx);
                        assert!(c.wizard.is_none(), "never steal the queue editor");
                    }
                })
                .unwrap();
            cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
                .unwrap();
            handle
                .update(cx, |c, _, cx| {
                    if commit {
                        assert!(c.commit_queue_edit(cx));
                    } else {
                        assert!(c.cancel_queue_edit(cx));
                    }
                })
                .unwrap();
            cx.run_until_parked();
            let frame = request(&mut requests, methods::FINISH_QUEUED_MESSAGE_EDIT);
            assert_eq!(
                frame.params["action"],
                if commit { "commit" } else { "cancel" }
            );
            reply(
                &runtime,
                &replies,
                ServerFrame {
                    id: frame.id,
                    ok: Some(
                        serde_json::json!({"outcome": if commit { "committed" } else { "cancelled" }}),
                    ),
                    ..Default::default()
                },
                cx,
            );
            handle
                .read_with(cx, |c, cx| {
                    assert!(c.editing_queued.is_none());
                    assert!(c.wizard_active());
                    assert!(c.wizard_expanded);
                    if existing {
                        assert!(c.wizard.as_ref().unwrap().is_picked(1));
                        assert_eq!(c.input.read(cx).text(), "My answer");
                    } else {
                        assert_eq!(
                            c.drafts.get("question-chat").map(String::as_str),
                            Some("ordinary draft")
                        );
                    }
                })
                .unwrap();
            cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
                .unwrap();
            let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
            assert!(visual.debug_bounds("question-popover").is_some());
            assert!(visual.debug_bounds("wizard-submit").is_some());
            handle
                .update(cx, |_, window, _| window.remove_window())
                .unwrap();
        }
    }
}

#[gpui::test]
fn question_answer_without_engine_keeps_panel_picks_text_and_files(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = fixture(cx);
    handle
        .update(cx, |c, _, cx| {
            let file = attachments::stage_png_bytes("answer.png".into(), vec![1, 2, 3]);
            c.attachments.insert(c.current_key.clone(), vec![file]);
            let answers = c.wizard.as_ref().unwrap().answers();
            c.wizard_finish(answers, cx);
            assert_eq!(c.staged().len(), 1);
            assert!(c.failure.is_some());
        })
        .unwrap();
    assert_retry(handle, cx);
}

#[gpui::test]
fn question_queue_edit_preserves_explicit_collapse(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = fixture(cx);
    handle
        .update(cx, |c, _, cx| {
            c.wizard_expanded = false;
            c.queue_edit_draft = Some(("My answer".into(), vec![], vec![]));
            c.editing_queued = Some("row".into());
            c.prepare_queue_edit_input(cx);
            c.input.update(cx, |i, cx| i.set_text("queued text", cx));
        })
        .unwrap();
    cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
        .unwrap();
    handle
        .update(cx, |c, _, cx| c.clear_queue_edit(cx))
        .unwrap();
    cx.run_until_parked();
    handle
        .read_with(cx, |c, cx| {
            assert!(c.wizard_active());
            assert!(!c.wizard_expanded);
            assert_eq!(c.input.read(cx).text(), "My answer");
        })
        .unwrap();
}

#[gpui::test]
fn question_timeout_never_revives_a_resolved_or_superseded_request(cx: &mut gpui::TestAppContext) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    for superseded in [false, true] {
        let (_dir, handle) = fixture(cx);
        let (mut requests, replies) = engine(handle, cx);
        handle
            .update(cx, |c, _, cx| {
                let answers = c.wizard.as_ref().unwrap().answers();
                c.wizard_finish(answers, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let frame = request(&mut requests, methods::QUEUE_COMMAND);
        reply(
            &runtime,
            &replies,
            ServerFrame {
                id: frame.id,
                ok: Some(serde_json::json!({})),
                ..Default::default()
            },
            cx,
        );
        handle
            .update(cx, |c, _, cx| {
                c.state.update(cx, |s, cx| {
                    if superseded {
                        s.transcript = serde_json::from_value(serde_json::json!([{
                            "id": "newer", "role": "assistant", "createdAt": 1,
                            "deviceId": "host", "status": "complete", "parts": [{
                                "id": "text", "kind": "text", "text": "Moved on"
                            }]
                        }]))
                        .unwrap();
                    } else if let MessagePart::Input { resolved, .. } =
                        &mut s.transcript[0].parts[0]
                    {
                        *resolved = true;
                    }
                    cx.notify();
                });
            })
            .unwrap();
        cx.executor().advance_clock(Duration::from_secs(3));
        cx.run_until_parked();
        handle
            .update(cx, |c, _, cx| {
                c.reveal_pending_question(cx);
                assert!(c.wizard.is_none());
            })
            .unwrap();
        handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    }
}

#[gpui::test]
fn question_failed_answers_restore_without_state_notifications(cx: &mut gpui::TestAppContext) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    for failure in ["rpc", "upload", "unresolved", "timeout"] {
        for navigate in [false, true] {
            let (_dir, handle) = fixture(cx);
            let (mut requests, replies) = engine(handle, cx);
            handle
                .update(cx, |c, _, cx| {
                    if matches!(failure, "upload" | "rpc") {
                        let file = attachments::stage_png_bytes("answer.png".into(), vec![1, 2, 3]);
                        c.attachments.insert(c.current_key.clone(), vec![file]);
                    }
                    let answers = c.wizard.as_ref().unwrap().answers();
                    c.wizard_finish(answers, cx);
                    assert!(c.wizard.is_none());
                })
                .unwrap();
            cx.run_until_parked();
            if navigate {
                handle
                    .update(cx, |c, _, cx| {
                        c.state.update(cx, |s, _| {
                            s.selected_chat = Some("other".into());
                            s.transcript.clear();
                        });
                        c.on_state_changed(cx);
                        c.input.update(cx, |i, cx| i.set_text("Other draft", cx));
                    })
                    .unwrap();
            }
            if matches!(failure, "upload" | "rpc") {
                // Exercise attachment retention on both upload and command failure.
                let chunk = request(&mut requests, methods::UPLOAD_CHUNK);
                reply(
                    &runtime,
                    &replies,
                    ServerFrame {
                        id: chunk.id,
                        ok: Some(serde_json::json!({})),
                        ..Default::default()
                    },
                    cx,
                );
                let finish = request(&mut requests, methods::UPLOAD_COMMIT);
                reply(
                    &runtime,
                    &replies,
                    ServerFrame {
                        id: finish.id,
                        ok: (failure == "rpc")
                            .then(|| serde_json::json!({"path": "uploaded/answer.png"})),
                        err: (failure == "upload").then(|| "upload rejected".into()),
                        ..Default::default()
                    },
                    cx,
                );
            }
            if failure != "upload" {
                let frame = request(&mut requests, methods::QUEUE_COMMAND);
                if failure != "timeout" {
                    reply(
                        &runtime,
                        &replies,
                        ServerFrame {
                            id: frame.id,
                            ok: (failure == "unresolved").then(|| serde_json::json!({})),
                            err: (failure == "rpc").then(|| "answer rejected".into()),
                            ..Default::default()
                        },
                        cx,
                    );
                }
                if matches!(failure, "unresolved" | "timeout") {
                    cx.executor()
                        .advance_clock(Duration::from_secs(if failure == "timeout" {
                            31
                        } else {
                            3
                        }));
                    cx.run_until_parked();
                }
            }
            if navigate {
                handle
                    .update(cx, |c, _, cx| {
                        assert!(c.wizard.is_none());
                        assert_eq!(c.input.read(cx).text(), "Other draft");
                        c.state.update(cx, |s, _| {
                            s.selected_chat = Some("question-chat".into());
                            s.transcript = pending();
                        });
                        c.on_state_changed(cx);
                    })
                    .unwrap();
            }
            assert_retry(handle, cx);
            if matches!(failure, "upload" | "rpc") {
                handle
                    .read_with(cx, |c, _| assert_eq!(c.staged().len(), 1))
                    .unwrap();
            }
            handle
                .update(cx, |_, window, _| window.remove_window())
                .unwrap();
        }
    }
}
