use super::*;
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_proto::{Session, SessionStatus, UserInputQuestion};

fn admit_overview_session(
    shell: &mut Shell,
    id: &str,
    project: &str,
    chats: &[&str],
    cx: &mut Context<Shell>,
) {
    shell.ensure_workspace_sessions(cx);
    shell.chat_tabs.push(chat_tabs::ChatTab {
        id: id.into(),
        title: Some(id.into()),
        project: Some(project.into()),
        selected: chats.first().map(|id| (*id).into()),
        ..Default::default()
    });
    let mut layout = workspace_panels::WorkspaceLayout::default();
    layout.panels[0].tabs = chats
        .iter()
        .map(|id| workspace_panels::PanelTab::Chat((*id).into()))
        .collect();
    shell.workspace_panels.layouts.insert(id.into(), layout);
}

#[gpui::test]
fn overview_session_inventory_and_tasks_follow_actual_panel_tabs(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            let id = shell.chat_tabs[shell.chat_tab].id.clone();
            let mut layout = workspace_panels::WorkspaceLayout::default();
            layout.panels[0].tabs = vec![
                workspace_panels::PanelTab::Chat("current".into()),
                workspace_panels::PanelTab::Chat("peer".into()),
                workspace_panels::PanelTab::Terminal(77),
            ];
            layout.panels.push(workspace_panels::WorkspacePanel {
                id: 1,
                tabs: vec![workspace_panels::PanelTab::Draft(88)],
                active: 0,
                share: 1.0,
            });
            shell.workspace_panels.layouts.insert(id.clone(), layout);
            shell.state.update(cx, |state, _| {
                let mut unrelated = state.chats[0].clone();
                unrelated.id = "another-chat-in-the-project".into();
                state.chats.push(unrelated);
            });
            let sessions = shell.overview_sessions(cx);
            let session = sessions.iter().find(|session| session.id == id).unwrap();
            assert_eq!(session.panel_count, 2);
            assert_eq!(session.tab_count, 4);
            assert_eq!(session.threads.len(), 2);
            assert!(
                session
                    .threads
                    .iter()
                    .all(|thread| { thread.id == "current" || thread.id == "peer" })
            );
        })
        .unwrap();
}

fn working_session(chat: &str) -> Session {
    Session {
            last_completed_peer_only: false,
        last_completed_turn: None,
        chat_id: chat.into(),
        device_id: "local".into(),
        status: SessionStatus::Working,
        started_at: Some(Utc::now()),
        updated_at: Utc::now(),
    }
}

fn assistant(parts: Vec<MessagePart>, status: MessageStatus) -> SessionMessageEntry {
    SessionMessageEntry {
        id: "overview-assistant".into(),
        role: MessageRole::Assistant,
        parts,
        created_at: Utc::now().timestamp_millis(),
        device_id: "local".into(),
        status: Some(status),
        continuation_of: None,
        duration_ms: None,
    }
}

fn completed_plan() -> SessionMessageEntry {
    assistant(
        vec![
            serde_json::from_value(serde_json::json!({
                "kind": "tool", "id": "plan", "resolved": true,
                "call": { "kind": "todo", "items": [
                    { "text": "Prepare the change", "done": true },
                    { "text": "Verify the result", "done": true }
                ] }
            }))
            .unwrap(),
            MessagePart::Text {
                id: "result".into(),
                text: "The change is ready to review.".into(),
            },
        ],
        MessageStatus::Complete,
    )
}

#[gpui::test]
fn overview_keeps_an_admitted_workspace_session_when_work_finishes(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            admit_overview_session(shell, "background-session", "b", &["target"], cx);
            shell.state.update(cx, |state, _| {
                state.sessions = vec![working_session("target")];
            });
            shell.open_session_overview(window, cx);
            let _ = shell.render_session_overview(window, cx);
            let before: Vec<_> = shell
                .overview_sessions(cx)
                .into_iter()
                .map(|session| session.id)
                .collect();
            assert!(before.contains(&"background-session".into()));

            shell.state.update(cx, |state, _| {
                state.sessions.clear();
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "target")
                    .unwrap()
                    .last_message_at = Some(Utc::now());
            });
            let _ = shell.render_session_overview(window, cx);
            let after: Vec<_> = shell
                .overview_sessions(cx)
                .into_iter()
                .map(|session| session.id)
                .collect();
            assert_eq!(
                after, before,
                "finishing work must not remove or reorder its card"
            );
        })
        .unwrap();
}

#[gpui::test]
fn overview_keeps_a_dead_runs_question_answerable(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            admit_overview_session(shell, "background-session", "b", &["target"], cx);
            shell.state.update(cx, |state, _| {
                state.set_subagent_snapshot(
                    "target".into(),
                    vec![assistant(
                        vec![MessagePart::Input {
                            id: "input".into(),
                            request_id: "pending-after-disconnect".into(),
                            questions: vec![UserInputQuestion {
                                id: "format".into(),
                                header: "Date format".into(),
                                question: "Which date format should be used?".into(),
                                options: vec!["Original".into(), "ISO".into()],
                                multi_select: false,
                                prefill: None,
                                multiline: false,
                            }],
                            resolved: false,
                        }],
                        MessageStatus::Aborted,
                    )],
                );
                let target = state.chats.iter().find(|chat| chat.id == "target").unwrap();
                assert_eq!(
                    state.display_status_for(target, Utc::now()),
                    harness_proto::ChatIndicator::Idle
                );
            });
            shell.open_session_overview(window, cx);
            let _ = shell.render_session_overview(window, cx);
            let sessions = shell.overview_sessions(cx);
            let target = sessions
                .iter()
                .flat_map(|session| &session.threads)
                .find(|thread| thread.id == "target")
                .unwrap();
            assert_eq!(
                target.indicator,
                harness_proto::ChatIndicator::AwaitingInput
            );
            assert!(target.activity.pending_question);
            assert_eq!(target.activity.update, "Which date format should be used?");
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
        })
        .unwrap();
}

#[gpui::test]
fn overview_follows_secondary_work_in_the_same_workspace_session(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            admit_overview_session(shell, "background-session", "b", &["target", "parked"], cx);
            shell.state.update(cx, |state, _| {
                state.sessions = vec![working_session("target"), working_session("parked")];
            });
            shell.open_session_overview(window, cx);
            let _ = shell.render_session_overview(window, cx);
            let watched = shell.overview_live_chats(cx);
            assert!(watched.contains(&"target".into()));
            assert!(
                watched.contains(&"parked".into()),
                "secondary active tasks need their own live updates"
            );
            assert!(shell.peer_chat_views.contains_key("target"));
            assert!(shell.peer_chat_views.contains_key("parked"));
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
        })
        .unwrap();
}

#[gpui::test]
fn overview_retains_final_details_until_the_dashboard_closes(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            admit_overview_session(shell, "background-session", "b", &["target"], cx);
            shell.state.update(cx, |state, _| {
                state.sessions = vec![working_session("target")];
            });
            shell.open_session_overview(window, cx);
            let _ = shell.render_session_overview(window, cx);
            assert!(shell.peer_chat_views.contains_key("target"));

            shell.state.update(cx, |state, _| {
                state.sessions.clear();
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "target")
                    .unwrap()
                    .last_message_at = Some(Utc::now());
                state.set_peer_chat_snapshot("target".into(), vec![completed_plan()]);
            });
            let _ = shell.render_session_overview(window, cx);
            assert!(shell.peer_chat_views.contains_key("target"));
            let sessions = shell.overview_sessions(cx);
            let target = sessions
                .iter()
                .flat_map(|session| &session.threads)
                .find(|thread| thread.id == "target")
                .unwrap();
            assert_eq!(target.activity.completed_steps, 2);
            assert_eq!(target.activity.total_steps, 2);
            assert_eq!(target.activity.update, "The change is ready to review.");

            shell.close_session_overview(window, cx);
            assert!(!shell.peer_chat_views.contains_key("target"));
            assert!(
                shell
                    .state
                    .read(cx)
                    .overview_transcript("target")
                    .is_empty()
            );
        })
        .unwrap();
}

#[gpui::test]
fn overview_question_survives_empty_replay_until_explicit_resolution(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    let shell = window.entity(cx).unwrap();
    let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
    // Native panel elements retain the input entity until their draw arena is
    // cleared. Build them inside a draw scope so test teardown releases it.
    visual.draw(
        gpui::point(px(0.), px(0.)),
        gpui::size(px(800.), px(600.)),
        |window, cx| {
            shell.update(cx, |shell, cx| {
                shell.boot_restored = true;
                let mut entry = assistant(
                    vec![MessagePart::Input {
                        id: "input".into(),
                        request_id: "question-during-reconnect".into(),
                        questions: vec![UserInputQuestion {
                            id: "format".into(),
                            header: "Date format".into(),
                            question: "Which date format should be used?".into(),
                            options: vec!["Original".into(), "ISO".into()],
                            multi_select: false,
                            prefill: None,
                            multiline: false,
                        }],
                        resolved: false,
                    }],
                    MessageStatus::Aborted,
                );
                shell.state.update(cx, |state, cx| {
                    state.select_chat(Some("target".into()), cx);
                    state.apply_transcript(vec![entry.clone()]);
                    state.select_chat(Some("current".into()), cx);
                });
                shell.open_session_overview(window, cx);
                shell.open_overview_question("target".into(), window, cx);
                assert!(shell.overview_question_overlay(window, cx).is_some());
                assert_eq!(
                    shell.composer.read(cx).overview_question_request_id(),
                    Some("question-during-reconnect")
                );

                shell.state.update(cx, |state, _| {
                    state.apply_transcript(Vec::new());
                    assert!(state.transcript_replayed);
                });
                assert!(shell.overview_question_overlay(window, cx).is_some());
                assert_eq!(
                    shell
                        .session_overview_runtime
                        .question
                        .as_ref()
                        .and_then(|question| question.request.as_deref()),
                    Some("question-during-reconnect")
                );
                assert_eq!(
                    shell.composer.read(cx).overview_question_request_id(),
                    Some("question-during-reconnect")
                );

                if let MessagePart::Input { resolved, .. } = &mut entry.parts[0] {
                    *resolved = true;
                }
                shell.state.update(cx, |state, _| {
                    state.apply_transcript(vec![entry]);
                });
                assert!(shell.overview_question_overlay(window, cx).is_none());
                assert!(shell.session_overview_runtime.question.is_none());
                assert!(shell.session_overview);
            });
            gpui::div()
        },
    );
}

/// Six sessions as people get them, through the real render: one waiting on a
/// question, one working, one never used.
fn sections_window(
    cx: &mut gpui::TestAppContext,
) -> (
    tempfile::TempDir,
    gpui::WindowHandle<Shell>,
    gpui::VisualTestContext,
) {
    let (dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.debug_gate = Some(GatePhase::Ready);
            shell.splash = SplashPhase::Gone;
            shell.boot_restored = true;
            shell.reduced_motion = true;
            admit_overview_session(shell, "old", "a", &[], cx);
            admit_overview_session(shell, "busy", "a", &["peer"], cx);
            admit_overview_session(shell, "waiting", "b", &["target"], cx);
            shell.state.update(cx, |state, _| {
                state.sessions.push(working_session("peer"));
                state.set_subagent_snapshot(
                    "target".into(),
                    vec![assistant(
                        vec![MessagePart::Input {
                            id: "input".into(),
                            request_id: "question".into(),
                            questions: vec![UserInputQuestion {
                                id: "format".into(),
                                header: "Date format".into(),
                                question: "Which date format should be used?".into(),
                                options: vec!["Original".into(), "ISO".into()],
                                multi_select: false,
                                prefill: None,
                                multiline: false,
                            }],
                            resolved: false,
                        }],
                        MessageStatus::Streaming,
                    )],
                );
            });
            shell.open_session_overview(window, cx);
            cx.notify();
        })
        .unwrap();
    let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(gpui::size(px(1200.0), px(900.0)));
    redraw_overview(&mut visual);
    (dir, window, visual)
}

fn redraw_overview(visual: &mut gpui::VisualTestContext) {
    visual.run_until_parked();
    visual.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
}

#[gpui::test]
fn the_screen_opens_on_what_needs_you_and_old_sessions_are_rows(cx: &mut gpui::TestAppContext) {
    let (_dir, _window, mut visual) = sections_window(cx);
    let waiting = visual.debug_bounds("overview-session-waiting").unwrap();
    let working = visual.debug_bounds("overview-session-busy").unwrap();
    let old = visual.debug_bounds("overview-row-old").unwrap();
    assert!(
        waiting.bottom() <= working.top(),
        "working sits under its own heading, below what needs you"
    );
    assert!(working.bottom() <= old.top());
    assert!(
        old.size.height < px(40.0),
        "an unused session is one line, not a card"
    );
    assert!(
        working.size.height < px(240.0),
        "a card is as tall as what it says, was {:?}",
        working.size.height
    );
}

#[gpui::test]
fn the_answer_button_stays_here_and_a_card_opens_its_chat(cx: &mut gpui::TestAppContext) {
    let _selection = crate::markdown::selection::test_state_lock();
    let (_dir, window, mut visual) = sections_window(cx);
    let answer = visual
        .debug_bounds("overview-answer-waiting")
        .unwrap()
        .center();
    visual.simulate_click(answer, Default::default());
    redraw_overview(&mut visual);
    window
        .update(cx, |shell, window, cx| {
            assert!(shell.session_overview, "the card's click didn't also fire");
            assert_eq!(
                shell
                    .session_overview_runtime
                    .question
                    .as_ref()
                    .map(|question| question.chat.as_str()),
                Some("target")
            );
            shell.close_overview_question(window, cx);
        })
        .unwrap();
    redraw_overview(&mut visual);

    let card = visual
        .debug_bounds("overview-session-busy")
        .unwrap()
        .center();
    visual.simulate_click(card, Default::default());
    redraw_overview(&mut visual);
    window
        .update(cx, |shell, _, cx| {
            assert!(!shell.session_overview);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        })
        .unwrap();
}
