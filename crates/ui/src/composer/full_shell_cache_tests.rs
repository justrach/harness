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
