//! Follow-up delivery policy for the live-run composer.

use crate::settings::FollowUpBehavior;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum FollowUpAction {
    Queue,
    Steer,
    StopAndSend,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum MainAction {
    Send,
    Stop,
    FollowUp(FollowUpAction),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SteerUnavailable {
    NoLiveRun,
    NoText,
    Attachments,
    QueueActions,
    StepBoundary,
}

pub(super) fn steer_unavailable(
    live: bool,
    has_text: bool,
    has_attachments: bool,
    queue_actions_supported: bool,
    supports_step_boundary: bool,
) -> Option<SteerUnavailable> {
    if !live {
        Some(SteerUnavailable::NoLiveRun)
    } else if !has_text {
        Some(SteerUnavailable::NoText)
    } else if has_attachments {
        Some(SteerUnavailable::Attachments)
    } else if !queue_actions_supported {
        Some(SteerUnavailable::QueueActions)
    } else if !supports_step_boundary {
        Some(SteerUnavailable::StepBoundary)
    } else {
        None
    }
}

pub(super) fn steer_reason(reason: SteerUnavailable) -> &'static str {
    match reason {
        SteerUnavailable::NoLiveRun => "Steer is available while a run is active",
        SteerUnavailable::NoText => "Steer needs text in the composer",
        SteerUnavailable::Attachments => {
            "Steer only supports text; remove attachments or screenshots"
        }
        SteerUnavailable::QueueActions => {
            "Update Harness on this device and the chat host to use this action"
        }
        SteerUnavailable::StepBoundary => "This agent does not support steering during a turn",
    }
}

pub(super) fn main_action(
    live: bool,
    has_content: bool,
    behavior: FollowUpBehavior,
    steer_unavailable: Option<SteerUnavailable>,
) -> MainAction {
    if !live {
        MainAction::Send
    } else if !has_content {
        MainAction::Stop
    } else {
        match behavior {
            FollowUpBehavior::Queue => MainAction::FollowUp(FollowUpAction::Queue),
            FollowUpBehavior::Steer if steer_unavailable.is_none() => {
                MainAction::FollowUp(FollowUpAction::Steer)
            }
            FollowUpBehavior::Steer => MainAction::FollowUp(FollowUpAction::Queue),
        }
    }
}

pub(super) fn opposite_follow_up(behavior: FollowUpBehavior) -> FollowUpBehavior {
    match behavior {
        FollowUpBehavior::Queue => FollowUpBehavior::Steer,
        FollowUpBehavior::Steer => FollowUpBehavior::Queue,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::composer::{Composer, ComposerEvent, SendButtonMode};
    use crate::state::AppState;
    use gpui::AppContext as _;
    use harness_rpc::{ClientFrame, ServerFrame, methods};
    use std::cell::RefCell;
    use std::rc::Rc;

    fn receive_request(
        cx: &mut gpui::TestAppContext,
        runtime: &tokio::runtime::Runtime,
        requests: &mut tokio::sync::mpsc::Receiver<String>,
        stage: &str,
    ) -> ClientFrame {
        cx.run_until_parked();
        runtime.block_on(async { tokio::task::yield_now().await });
        cx.run_until_parked();
        let frame = requests.try_recv().unwrap_or_else(|error| {
            panic!("expected {stage} RPC request after executor pump: {error}")
        });
        serde_json::from_str(&frame).expect("client frame")
    }

    fn reply(
        replies: &tokio::sync::mpsc::Sender<String>,
        request: &ClientFrame,
        value: serde_json::Value,
    ) {
        replies
            .try_send(
                serde_json::to_string(&ServerFrame {
                    id: request.id,
                    ok: Some(value),
                    ..Default::default()
                })
                .unwrap(),
            )
            .unwrap();
    }

    fn steer_test_chat() -> harness_proto::Chat {
        serde_json::from_value(serde_json::json!({
            "id": "steer-chat",
            "deviceId": "local",
            "archived": false,
            "cwd": "/repo",
            "createdAt": chrono::Utc::now(),
            "config": { "harness": "codex", "sandbox": "workspace-write" }
        }))
        .unwrap()
    }
    fn run_steer_send(
        cx: &mut gpui::TestAppContext,
        runtime: &tokio::runtime::Runtime,
        promotion_succeeds: bool,
        behavior: FollowUpBehavior,
        shortcut: bool,
    ) {
        let (out, mut requests) = tokio::sync::mpsc::channel::<String>(32);
        let (replies, inbound) = tokio::sync::mpsc::channel::<String>(32);
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, _| {
            state.set_test_engine(
                crate::state::EngineHandle::from_test_client_with_capabilities(
                    harness_rpc::RpcClient::new(out, inbound),
                    vec![
                        harness_proto::capabilities::MESSAGE_QUEUE_V1.into(),
                        harness_proto::capabilities::MESSAGE_QUEUE_ACTIONS_V1.into(),
                    ],
                ),
            );
            state.chats = vec![steer_test_chat()];
            state.local_device_id = Some("local".into());
            state.selected_chat = Some("steer-chat".into());
            state.begin_pending_send("steer-chat", "running-turn", chrono::Utc::now());
        });
        let composer = cx.new(|cx| Composer::new(state.clone(), cx));
        cx.run_until_parked();
        while let Ok(raw) = requests.try_recv() {
            let request: ClientFrame = serde_json::from_str(&raw).unwrap();
            if request.method.as_deref() == Some(methods::LIST_HARNESSES) {
                reply(
                    &replies,
                    &request,
                    serde_json::json!([{
                        "id": "codex",
                        "name": "Codex",
                        "supportsSteering": true,
                        "steeringMode": "step-boundary",
                        "reasoningLevels": [],
                        "installed": true,
                        "canInstall": false,
                        "enabled": true
                    }]),
                );
            } else {
                reply(&replies, &request, serde_json::json!([]));
            }
        }
        cx.run_until_parked();
        composer.update(cx, |composer, cx| {
            composer.pickers.update(cx, |pickers, cx| {
                pickers.seed_step_boundary_steering_for_test(cx)
            });
            composer
                .input
                .update(cx, |input, cx| input.set_text("Keep the current turn", cx));
        });
        let events = Rc::new(RefCell::new(Vec::new()));
        let captured = events.clone();
        let _subscription = cx.update(|cx| {
            cx.subscribe(&composer, move |_, event: &ComposerEvent, _| {
                match event {
                    ComposerEvent::Sent { message_id, .. } => {
                        captured.borrow_mut().push(("sent", message_id.clone()));
                    }
                    ComposerEvent::Queued { message_id, .. } => {
                        captured.borrow_mut().push(("queued", message_id.clone()));
                    }
                    _ => {}
                }
            })
        });
        cx.update(|cx| {
            crate::settings::update(crate::settings::SavePolicy::Immediate, cx, |settings| {
                settings.follow_up_behavior = behavior;
            });
        });
        composer.update(cx, |composer, cx| {
            assert_eq!(composer.button_mode(cx), SendButtonMode::Queue);
            let main_action = composer.follow_up_main_action(cx);
            if shortcut {
                assert_eq!(main_action, MainAction::FollowUp(FollowUpAction::Queue));
                composer.on_follow_up_shortcut(cx);
            } else {
                assert_eq!(main_action, MainAction::FollowUp(FollowUpAction::Steer));
                composer.on_submit(cx);
            }
        });

        let queued = receive_request(cx, &runtime, &mut requests, "queue message");
        assert_eq!(queued.method.as_deref(), Some(methods::QUEUE_MESSAGE));
        assert_eq!(queued.params["holdForTurnEnd"], true);
        // The shortcut always steers, independently of the saved button policy.
        let is_steer = behavior == FollowUpBehavior::Steer || shortcut;
        let provisional_id = if is_steer {
            let provisional_id = state.read_with(cx, |state, _| {
                let echo = state.pending_echoes().first();
                assert!(echo.is_some(), "Steer should echo before QueueMessage is acknowledged");
                echo.unwrap().id.clone()
            });
            assert_eq!(
                state.read_with(cx, |state, _| state.pending_echoes()[0].parts[0].clone()),
                harness_doc::MessagePart::Text {
                    id: "t0".into(),
                    text: "Keep the current turn".into(),
                }
            );
            assert_eq!(&*events.borrow(), &[("sent", provisional_id.clone())]);
            Some(provisional_id)
        } else {
            assert!(state.read_with(cx, |state, _| state.pending_echoes().is_empty()));
            None
        };
        reply(
            &replies,
            &queued,
            serde_json::json!({ "id": "stable-row-id" }),
        );
        let promoted = receive_request(cx, &runtime, &mut requests, "follow-up action");
        if is_steer {
            assert_eq!(
                state.read_with(cx, |state, _| state.pending_echoes()[0].id.clone()),
                "stable-row-id".to_string(),
                "queue ack should rekey the pending echo before Steer RPC"
            );
        }
        assert!(!state.read_with(cx, |state, _| state.message_is_in_transcript(
            "steer-chat",
            "missing-id"
        )));
        assert_eq!(
            promoted.method.as_deref(),
            Some(methods::STEER_QUEUED_MESSAGE_NOW)
        );
        assert_eq!(promoted.params["chatId"], "steer-chat");
        assert_eq!(promoted.params["targetDeviceId"], "local");
        assert_eq!(promoted.params["id"], "stable-row-id");
        reply(
            &replies,
            &promoted,
            serde_json::json!({ "sent": promotion_succeeds }),
        );

        let watch = receive_request(cx, &runtime, &mut requests, "queue refresh");
        assert_eq!(watch.method.as_deref(), Some(methods::WATCH_QUEUE));
        let items = if promotion_succeeds {
            Vec::new()
        } else {
            vec![serde_json::json!({
                "id": "stable-row-id",
                "text": "Keep the current turn",
                "holdForTurnEnd": true,
                "issuedBy": "local",
                "issuedAt": 1
            })]
        };
        replies
            .try_send(
                serde_json::to_string(&ServerFrame {
                    id: watch.id,
                    item: Some(serde_json::json!({ "items": items })),
                    ..Default::default()
                })
                .unwrap(),
            )
            .unwrap();
        runtime.block_on(async { tokio::task::yield_now().await });
        cx.run_until_parked();
        composer.read_with(cx, |composer, cx| {
            assert!(!composer.is_sending());
            assert!(composer.input.read(cx).text().is_empty());
            if promotion_succeeds {
                assert!(composer.failure.is_none());
                assert!(state.read(cx).queue.is_empty());
            } else {
                assert_eq!(
                    composer.failure.as_deref(),
                    Some("Message queued, but the follow-up action was not accepted. Check the queue or transcript.")
                );
                assert_eq!(state.read(cx).queue.len(), 1);
                assert_eq!(state.read(cx).queue[0].id, "stable-row-id");
            }
        });
        if is_steer {
            state.read_with(cx, |state, _| {
                if promotion_succeeds {
                    assert_eq!(state.pending_echoes()[0].id, "stable-row-id");
                } else {
                    assert!(state.pending_echoes().is_empty());
                }
            });
        }
        if let Some(provisional_id) = provisional_id {
            let expected = if promotion_succeeds {
                vec![("sent", provisional_id), ("sent", "stable-row-id".into())]
            } else {
                vec![
                    ("sent", provisional_id),
                    ("sent", "stable-row-id".into()),
                    ("queued", "stable-row-id".into()),
                ]
            };
            assert_eq!(&*events.borrow(), &expected);
        } else {
            assert_eq!(&*events.borrow(), &[("queued", "stable-row-id".into())]);
        }
        cx.update(|cx| {
            assert_eq!(
                crate::settings::with_current(cx, |settings| settings.follow_up_behavior),
                behavior,
                "one-shot shortcut must not change the saved preference"
            );
        });
    }

    #[test]
    fn saved_policy_and_effective_main_action_match_steer_capability() {
        assert_eq!(
            main_action(true, true, FollowUpBehavior::Queue, None),
            MainAction::FollowUp(FollowUpAction::Queue)
        );
        assert_eq!(
            main_action(true, true, FollowUpBehavior::Steer, None),
            MainAction::FollowUp(FollowUpAction::Steer)
        );
        assert_eq!(
            main_action(
                true,
                true,
                FollowUpBehavior::Steer,
                Some(SteerUnavailable::StepBoundary),
            ),
            MainAction::FollowUp(FollowUpAction::Queue)
        );
    }

    #[test]
    fn steering_fails_closed_for_attachments_and_unknown_capabilities() {
        assert_eq!(
            steer_unavailable(true, true, true, true, true),
            Some(SteerUnavailable::Attachments)
        );
        assert_eq!(
            steer_unavailable(true, true, false, false, true),
            Some(SteerUnavailable::QueueActions)
        );
        assert_eq!(
            steer_unavailable(true, true, false, true, false),
            Some(SteerUnavailable::StepBoundary)
        );
        assert_eq!(steer_unavailable(true, true, false, true, true), None);
    }

    #[test]
    fn idle_empty_and_shortcut_policy_are_explicit() {
        assert_eq!(
            main_action(false, true, FollowUpBehavior::Steer, None),
            MainAction::Send
        );
        assert_eq!(
            main_action(true, false, FollowUpBehavior::Queue, None),
            MainAction::Stop
        );
        assert_eq!(
            opposite_follow_up(FollowUpBehavior::Queue),
            FollowUpBehavior::Steer
        );
        assert_eq!(
            opposite_follow_up(FollowUpBehavior::Steer),
            FollowUpBehavior::Queue
        );
    }

    #[gpui::test]
    fn steer_enqueue_promotes_the_durable_row_and_failed_promotion_keeps_it(
        cx: &mut gpui::TestAppContext,
    ) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let directory = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            crate::settings::init(crate::settings::UiSettings::default(), directory.path(), cx);
            crate::settings::update(crate::settings::SavePolicy::Immediate, cx, |settings| {
                settings.follow_up_behavior = FollowUpBehavior::Steer;
            });
        });
        run_steer_send(cx, &runtime, true, FollowUpBehavior::Steer, false);
        run_steer_send(cx, &runtime, false, FollowUpBehavior::Steer, false);
        run_steer_send(cx, &runtime, true, FollowUpBehavior::Queue, true);
    }

    #[gpui::test]
    fn follow_up_shortcut_does_nothing_when_composer_is_empty(cx: &mut gpui::TestAppContext) {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, _| {
            state.selected_chat = Some("running-chat".into());
            state.begin_pending_send("running-chat", "running-turn", chrono::Utc::now());
        });
        let composer = cx.new(|cx| Composer::new(state, cx));
        composer.update(cx, |composer, cx| {
            assert_eq!(composer.button_mode(cx), SendButtonMode::Stop);
            composer.on_follow_up_shortcut(cx);
            assert!(!composer.is_sending());
            assert!(composer.failure.is_none());
        });
    }

    #[gpui::test]
    fn unavailable_one_shot_steer_preserves_queue_draft_and_sends_nothing(
        cx: &mut gpui::TestAppContext,
    ) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let directory = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            crate::settings::init(crate::settings::UiSettings::default(), directory.path(), cx);
            crate::settings::update(crate::settings::SavePolicy::Immediate, cx, |settings| {
                settings.follow_up_behavior = FollowUpBehavior::Queue;
                settings.composer_send_behavior = crate::settings::ComposerSendBehavior::Enter;
            });
        });
        let (out, mut requests) = tokio::sync::mpsc::channel::<String>(32);
        let (replies, inbound) = tokio::sync::mpsc::channel::<String>(32);
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, _| {
            state.set_test_engine(
                crate::state::EngineHandle::from_test_client_with_capabilities(
                    harness_rpc::RpcClient::new(out, inbound),
                    vec![
                        harness_proto::capabilities::MESSAGE_QUEUE_V1.into(),
                        harness_proto::capabilities::MESSAGE_QUEUE_ACTIONS_V1.into(),
                    ],
                ),
            );
            state.chats = vec![steer_test_chat()];
            state.local_device_id = Some("local".into());
            state.selected_chat = Some("steer-chat".into());
            state.begin_pending_send("steer-chat", "running-turn", chrono::Utc::now());
        });
        let composer = cx.new(|cx| Composer::new(state.clone(), cx));
        cx.run_until_parked();
        while let Ok(raw) = requests.try_recv() {
            let request: ClientFrame = serde_json::from_str(&raw).unwrap();
            reply(&replies, &request, serde_json::json!([]));
        }
        runtime.block_on(async { tokio::task::yield_now().await });
        cx.run_until_parked();

        composer.update(cx, |composer, cx| {
            composer.pickers.update(cx, |pickers, _| {
                pickers.select_for_test(harness_proto::HarnessId::Codex, "Codex", "test-model");
            });
        });
        composer.update(cx, |composer, cx| {
            composer
                .input
                .update(cx, |input, cx| input.set_text("Keep this draft", cx));
            assert_eq!(composer.button_mode(cx), SendButtonMode::Queue);
            composer.on_modified_submit(cx);
            assert_eq!(
                composer.failure.as_deref(),
                Some("This agent does not support steering during a turn")
            );
            assert_eq!(composer.input.read(cx).text(), "Keep this draft");
            assert!(!composer.is_sending());
        });

        runtime.block_on(async { tokio::task::yield_now().await });
        cx.run_until_parked();
        let mut sent_methods = Vec::new();
        while let Ok(raw) = requests.try_recv() {
            let request: ClientFrame = serde_json::from_str(&raw).unwrap();
            sent_methods.push(request.method.unwrap_or_default());
        }
        assert!(!sent_methods.iter().any(|method| {
            matches!(
                method.as_str(),
                methods::QUEUE_MESSAGE | methods::STEER_QUEUED_MESSAGE_NOW
            )
        }));
        cx.update(|cx| {
            assert_eq!(
                crate::settings::with_current(cx, |settings| settings.follow_up_behavior),
                FollowUpBehavior::Queue
            );
        });
    }

    #[gpui::test]
    fn follow_up_shortcut_does_not_replace_an_in_flight_send(cx: &mut gpui::TestAppContext) {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, _| {
            state.selected_chat = Some("running-chat".into());
            state.begin_pending_send("running-chat", "running-turn", chrono::Utc::now());
        });
        let composer = cx.new(|cx| Composer::new(state, cx));
        composer.update(cx, |composer, cx| {
            composer
                .input
                .update(cx, |input, cx| input.set_text("Keep this draft", cx));
            composer.sending = true;

            assert_eq!(composer.button_mode(cx), SendButtonMode::Queue);
            composer.on_follow_up_shortcut(cx);

            assert!(composer.is_sending());
            assert_eq!(composer.input.read(cx).text(), "Keep this draft");
            assert!(composer.failure.is_none());
        });
    }
}
