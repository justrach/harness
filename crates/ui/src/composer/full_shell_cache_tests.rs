//! Regression coverage through the production Shell's measured composer cache.
//! Unlike a standalone Composer fixture, this retains the transcript, dock,
//! sidebar and nested cached descendants while animation frames are replayed.
use super::*;
use crate::shell::{FocusComposer, Shell};
use crate::state::{ConnectionStatus, EngineBootConfig};
use harness_doc::TranscriptFrame;
use harness_proto::WorkspaceScope;

#[derive(Clone, Copy, Debug)]
enum Panel {
    Question,
    Queue,
}

impl Panel {
    fn animation_id(self) -> gpui::ElementId {
        match self {
            Self::Question => "composer-wizard",
            Self::Queue => "composer-queue",
        }
        .into()
    }

    fn selector(self) -> &'static str {
        match self {
            Self::Question => "question-panel",
            Self::Queue => "queue-waiting-row",
        }
    }
}

/// Disable the thread-local observer even if an assertion unwinds the test.
struct FadeObserver;

impl FadeObserver {
    fn start() -> Self {
        motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| {
            assert!(samples.is_none(), "another fade observer is already active");
            *samples = Some(Vec::new());
        });
        Self
    }
}

impl Drop for FadeObserver {
    fn drop(&mut self) {
        motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| *samples = None);
    }
}

fn transcript(panel: Panel) -> Vec<SessionMessageEntry> {
    match panel {
        Panel::Question => serde_json::from_value(serde_json::json!([{
            "id": "assistant", "role": "assistant", "createdAt": 0,
            "deviceId": "local", "status": "streaming", "parts": [{
                "id": "input", "kind": "input", "requestId": "shell-question",
                "resolved": false, "questions": [{
                    "id": "choice", "header": "Approach", "question": "Which approach?",
                    "options": ["Small change", "Full rewrite"], "multiSelect": true
                }]
            }]
        }]))
        .unwrap(),
        // Deliberately no input part: queue regressions must reproduce without
        // a pending question anywhere in the selected chat.
        Panel::Queue => serde_json::from_value(serde_json::json!([{
            "id": "assistant", "role": "assistant", "createdAt": 0,
            "deviceId": "local", "status": "streaming", "parts": [{
                "id": "text", "kind": "text", "text": "Preparing the synthetic change."
            }]
        }]))
        .unwrap(),
    }
}

fn open_shell<'a>(
    cx: &'a mut gpui::TestAppContext,
    data_dir: &std::path::Path,
    panel: Panel,
    reduced_motion: bool,
) -> (
    Entity<Shell>,
    Entity<AppState>,
    &'a mut gpui::VisualTestContext,
) {
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        crate::settings::init(crate::settings::UiSettings::default(), data_dir, cx);
        motion::set_reduced_motion(cx, reduced_motion);
    });
    let state = cx.update(|cx| {
        cx.new(|_| {
            let mut state = AppState::new();
            // Start Ready so Shell's real splash/gate path mounts the chat;
            // no private Shell fields or environment overrides are needed.
            state.connection = ConnectionStatus::Ready;
            state.workspace_scope = Some(WorkspaceScope::Local);
            state.local_device_id = Some("local".into());
            state.chats_synced = true;
            state.spaces_synced = true;
            // Mount the established-chat route on the very first Shell frame,
            // rather than measuring a new-chat-to-thread dock transition.
            state.selected_chat = Some("chat".into());
            state.auto_selected = true;
            state.spaces = vec![
                serde_json::from_value(serde_json::json!({
                    "id": "project", "deviceId": "local", "path": data_dir,
                    "createdAt": "2026-09-20T00:00:00Z"
                }))
                .unwrap(),
            ];
            state.chats = vec![
                serde_json::from_value(serde_json::json!({
                    "id": "chat", "title": "Synthetic cache regression", "deviceId": "local",
                    "spaceId": "project", "archived": false,
                    "createdAt": "2026-09-20T00:00:00Z"
                }))
                .unwrap(),
            ];
            state
        })
    });
    let (shell, cx) = cx.add_window_view(|_, cx| {
        Shell::new(
            state.clone(),
            EngineBootConfig {
                data_dir: data_dir.to_path_buf(),
                ipc_port: 0,
                edge_url: "http://127.0.0.1:1".into(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: HarnessId::Mock,
            },
            cx,
        )
    });
    state.update(cx, |state, cx| {
        state.select_chat(Some("chat".into()), cx);
        state
            .receive_transcript_frame(TranscriptFrame::reset(&transcript(panel)), cx)
            .unwrap();
        state.apply_sessions(vec![harness_proto::Session {
            last_completed_turn: None,
            last_completed_peer_only: false,
            chat_id: "chat".into(),
            device_id: "local".into(),
            status: harness_proto::SessionStatus::Working,
            started_at: Some(chrono::Utc::now()),
            updated_at: chrono::Utc::now(),
        }]);
        if matches!(panel, Panel::Queue) {
            state.queue = vec![
                serde_json::from_value(serde_json::json!({
                    "id": "waiting", "text": "Follow up after the current change.",
                    "issuedBy": "local", "issuedAt": 0
                }))
                .unwrap(),
            ];
        }
        cx.notify();
    });
    cx.simulate_resize(size(px(1200.0), px(900.0)));
    cx.run_until_parked();
    (shell, state, cx)
}

fn assert_shell_entrance_settles(
    cx: &mut gpui::TestAppContext,
    panel: Panel,
    reduced_motion: bool,
) {
    let dir = tempfile::tempdir().unwrap();
    let _observer = FadeObserver::start();
    let (_shell, state, cx) = open_shell(cx, dir.path(), panel, reduced_motion);
    let target = panel.animation_id();
    let mut observed = 0;
    let mut settled_observed = 0;
    let mut after_typing_observed = 0;
    let mut panel_bounds: Option<gpui::Bounds<gpui::Pixels>> = None;
    for frame in 0..80 {
        // AnimationElement uses the scheduler's wall-clock Instant, not the
        // executor's virtual timer clock. Twenty 16ms frames exceed fade-quick's
        // 150ms duration with ample margin, even on a fast test executor.
        std::thread::sleep(Duration::from_millis(16));
        cx.executor().advance_clock(Duration::from_millis(16));
        cx.run_until_parked();

        // Real focus, typing and hover changes invalidate the actual cached
        // descendants. No window.refresh(), cache bypass or hand-built root.
        if frame == 30 {
            cx.dispatch_action(FocusComposer);
        }
        if frame >= 30 && frame % 10 == 0 {
            cx.simulate_input("x");
        }
        if frame >= 25 && frame % 5 == 0 {
            // Debug selectors aren't replayed by GPUI's cache. Use the last
            // actual render's geometry, just as retained hitboxes do.
            let bounds = panel_bounds.expect("the panel must have rendered before hover");
            let position = if frame % 10 == 0 {
                bounds.center()
            } else {
                point(px(600.0), px(100.0))
            };
            cx.simulate_mouse_move(position, None, Default::default());
        }
        cx.update(|window, cx| {
            window.simulate_next_frame(cx);
            window.draw(cx).clear();
        });
        if let Some(bounds) = cx.debug_bounds(panel.selector()) {
            panel_bounds = Some(bounds);
        }
        if frame == 0 {
            assert!(
                panel_bounds.is_some(),
                "the expected panel must render before the settling window starts"
            );
        }
        motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| {
            for (id, alpha) in samples.as_mut().unwrap().drain(..) {
                if id != target {
                    continue;
                }
                observed += 1;
                if frame >= 20 {
                    settled_observed += 1;
                    assert!(
                        alpha >= 0.999,
                        "{panel:?} entrance restarted in production Shell: \
                         reduced_motion={reduced_motion}, frame={frame}, opacity={alpha}"
                    );
                }
                if frame >= 30 {
                    after_typing_observed += 1;
                }
                if reduced_motion {
                    assert_eq!(alpha, 1.0, "reduced motion must skip the entrance");
                }
            }
        });
    }
    assert!(observed > 0, "{target:?} never rendered");
    assert!(
        settled_observed > 0,
        "{target:?} was not sampled after settling"
    );
    assert!(
        after_typing_observed >= 5,
        "{target:?} was not sampled after real focus/typing updates"
    );
    if matches!(panel, Panel::Queue) {
        assert!(cx.debug_bounds("question-panel").is_none());
        assert!(cx.debug_bounds("question-expand").is_none());
        state.read_with(cx, |state, _| {
            assert!(state.transcript.iter().all(|entry| {
                entry
                    .parts
                    .iter()
                    .all(|part| !matches!(part, MessagePart::Input { .. }))
            }));
            assert_eq!(state.queue.len(), 1, "the queue must remain visible");
        });
    }
    cx.update(|window, _| window.remove_window());
}

fn animation_frame(cx: &mut gpui::VisualTestContext) -> Vec<(gpui::ElementId, f32)> {
    std::thread::sleep(Duration::from_millis(16));
    cx.executor().advance_clock(Duration::from_millis(16));
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.simulate_next_frame(cx);
        window.draw(cx).clear();
    });
    motion::FADE_TEST_SAMPLES.with_borrow_mut(|samples| {
        std::mem::take(samples.as_mut().expect("fade observer must be active"))
    })
}

fn assert_settled(samples: &[(gpui::ElementId, f32)], panel: Panel) -> usize {
    let target = panel.animation_id();
    let mut observed = 0;
    for (id, alpha) in samples {
        if *id == target {
            observed += 1;
            assert!(*alpha >= 0.999, "{panel:?} entrance restarted: {alpha}");
        }
    }
    observed
}

#[gpui::test]
fn full_shell_question_and_queue_stay_opaque_during_streaming_and_queue_mutations(
    cx: &mut gpui::TestAppContext,
) {
    let dir = tempfile::tempdir().unwrap();
    let _observer = FadeObserver::start();
    let (_shell, state, cx) = open_shell(cx, dir.path(), Panel::Question, false);
    let mut entries = transcript(Panel::Question);
    entries[0].parts.push(MessagePart::Text {
        id: "live-text".into(),
        text: String::new(),
    });
    state.update(cx, |state, cx| {
        state
            .receive_transcript_frame(TranscriptFrame::reset(&entries), cx)
            .unwrap();
        state.queue = vec![harness_doc::QueuedMessage::new(
            "waiting",
            "Synthetic follow-up",
            "local",
        )];
        cx.notify();
    });
    let mut text_len = 0;
    let mut observed = [0, 0];
    for frame in 0..60 {
        if frame >= 21 && frame % 3 == 0 {
            state.update(cx, |state, cx| {
                let text = format!(" Chunk {frame}.");
                text_len += text.len();
                state
                    .receive_transcript_frame(
                        TranscriptFrame::Delta {
                            upsert: Vec::new(),
                            append: vec![harness_doc::TextAppend {
                                entry: "assistant".into(),
                                part: "live-text".into(),
                                text,
                                len: text_len,
                            }],
                            remove: Vec::new(),
                            count: 1,
                        },
                        cx,
                    )
                    .unwrap();
                // Keep the tray mounted while adding, reordering, removing
                // and editing its rows; neither entrance should restart.
                if state.queue.len() == 1 {
                    state.queue.push(harness_doc::QueuedMessage::new(
                        "second",
                        "Another synthetic follow-up",
                        "local",
                    ));
                    state.queue.swap(0, 1);
                } else {
                    state.queue.remove(0);
                }
                state.queue[0].text = format!("Updated synthetic follow-up {frame}");
                cx.notify();
            });
        }
        let samples = animation_frame(cx);
        if frame >= 20 {
            observed[0] += assert_settled(&samples, Panel::Question);
            observed[1] += assert_settled(&samples, Panel::Queue);
        }
    }
    assert!(observed.iter().all(|count| *count >= 10), "{observed:?}");
    state.read_with(cx, |state, _| {
        assert_eq!(state.transcript.len(), 1);
        assert!(state.transcript[0].parts.iter().any(|part| {
            matches!(part, MessagePart::Text { text, .. } if text.len() == text_len)
        }));
        assert!(!state.queue.is_empty());
    });
    cx.update(|window, _| window.remove_window());
}

#[gpui::test]
fn full_shell_queue_remount_restarts_only_its_own_entrance(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let _observer = FadeObserver::start();
    let (_shell, state, cx) = open_shell(cx, dir.path(), Panel::Question, false);
    for _ in 0..25 {
        animation_frame(cx);
    }
    for mounted in [true, false, true, false] {
        state.update(cx, |state, cx| {
            state.queue = if mounted {
                vec![harness_doc::QueuedMessage::new(
                    "same-row",
                    "Synthetic remounted follow-up",
                    "local",
                )]
            } else {
                Vec::new()
            };
            cx.notify();
        });
        let samples = animation_frame(cx);
        assert!(assert_settled(&samples, Panel::Question) > 0);
        let queue_samples: Vec<_> = samples
            .iter()
            .filter(|(id, _)| *id == Panel::Queue.animation_id())
            .collect();
        if mounted {
            assert!(
                queue_samples.iter().any(|(_, alpha)| *alpha < 0.999),
                "a genuinely new tray must still animate, including with the same row ID"
            );
        } else {
            assert!(
                queue_samples.is_empty(),
                "an empty queue must unmount the tray"
            );
        }
        let mut settled_queue = 0;
        for frame in 0..25 {
            let samples = animation_frame(cx);
            assert_settled(&samples, Panel::Question);
            if frame >= 15 {
                settled_queue += assert_settled(&samples, Panel::Queue);
            }
        }
        if mounted {
            // A real state update ensures this check isn't satisfied merely
            // by the tray remaining cached after its initial entrance.
            state.update(cx, |_, cx| cx.notify());
            settled_queue += assert_settled(&animation_frame(cx), Panel::Queue);
            assert!(settled_queue > 0);
        }
    }
    cx.update(|window, _| window.remove_window());
}

#[gpui::test]
fn full_shell_settled_panels_survive_resize_and_motion_preference_changes(
    cx: &mut gpui::TestAppContext,
) {
    let dir = tempfile::tempdir().unwrap();
    let _observer = FadeObserver::start();
    let (_shell, state, cx) = open_shell(cx, dir.path(), Panel::Question, false);
    state.update(cx, |state, cx| {
        state.queue = vec![harness_doc::QueuedMessage::new(
            "waiting",
            "Synthetic resize follow-up",
            "local",
        )];
        cx.notify();
    });
    for _ in 0..25 {
        animation_frame(cx);
    }
    // Stay in the inline route: geometry and preferences invalidate the
    // cache, but neither panel's identity changes or needs a new entrance.
    for (width, height, reduced_motion) in [
        (1400., 1000., false),
        (1100., 850., true),
        (1250., 950., false),
        (1200., 900., true),
        (1400., 1000., false),
    ] {
        cx.simulate_resize(size(px(width), px(height)));
        cx.update(|_, cx| motion::set_reduced_motion(cx, reduced_motion));
        state.update(cx, |_, cx| cx.notify());
        let samples = animation_frame(cx);
        assert!(assert_settled(&samples, Panel::Question) > 0);
        assert!(assert_settled(&samples, Panel::Queue) > 0);
        if reduced_motion {
            for (_, alpha) in samples {
                assert_eq!(alpha, 1.0);
            }
        }
    }
    cx.update(|window, _| window.remove_window());
}

#[gpui::test]
fn full_shell_cached_question_entrance_does_not_restart(cx: &mut gpui::TestAppContext) {
    assert_shell_entrance_settles(cx, Panel::Question, false);
}

#[gpui::test]
fn full_shell_cached_queue_without_question_entrance_does_not_restart(
    cx: &mut gpui::TestAppContext,
) {
    assert_shell_entrance_settles(cx, Panel::Queue, false);
}

#[gpui::test]
fn full_shell_cached_question_reduced_motion_stays_opaque(cx: &mut gpui::TestAppContext) {
    assert_shell_entrance_settles(cx, Panel::Question, true);
}

#[gpui::test]
fn full_shell_cached_queue_without_question_reduced_motion_stays_opaque(
    cx: &mut gpui::TestAppContext,
) {
    assert_shell_entrance_settles(cx, Panel::Queue, true);
}
