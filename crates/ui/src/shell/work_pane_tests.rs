use super::*;
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_proto::ToolCall;

fn entry(id: &str, role: MessageRole, parts: Vec<MessagePart>) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts,
        created_at: 0,
        device_id: "local".into(),
        status: Some(MessageStatus::Streaming),
        continuation_of: None,
        duration_ms: None,
    }
}

/// A Ready shell whose selected chat is working, its latest turn running `cargo test`.
fn running_turn(
    cx: &mut gpui::TestAppContext,
) -> (
    tempfile::TempDir,
    Entity<Shell>,
    &mut gpui::VisualTestContext,
) {
    let dir = tempfile::tempdir().unwrap();
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
        settings::init(settings::UiSettings::expanded(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
    });
    let data_dir = dir.path().to_path_buf();
    let (shell, cx) = cx.add_window_view(|_, cx| {
        let state = cx.new(|_| AppState::new());
        let now = Utc::now();
        state.update(cx, |state, cx| {
            state.workspace_scope = Some(WorkspaceScope::Local);
            state.local_device_id = Some("local".into());
            state.chats_synced = true;
            // The composer (and the turn's work cue beside it) draws once the chat has a home.
            state.no_project = true;
            state.chats = vec![
                serde_json::from_value(serde_json::json!({
                    "id": "current", "deviceId": "local", "title": "Session",
                    "archived": false, "createdAt": now,
                }))
                .unwrap(),
            ];
            state.sessions = vec![harness_proto::Session {
                last_completed_turn: None,
                last_completed_peer_only: false,
                chat_id: "current".into(),
                device_id: "local".into(),
                status: harness_proto::SessionStatus::Working,
                started_at: Some(now),
                updated_at: now,
            }];
            state.select_chat(Some("current".into()), cx);
            state.transcript = vec![
                entry(
                    "prompt",
                    MessageRole::User,
                    vec![MessagePart::Text {
                        id: "t".into(),
                        text: "Run the tests".into(),
                    }],
                ),
                entry(
                    "reply",
                    MessageRole::Assistant,
                    vec![MessagePart::Tool {
                        id: "call".into(),
                        call: ToolCall::Exec {
                            command: "cargo test".into(),
                        },
                        is_error: false,
                        resolved: false,
                        output: None,
                        diff: None,
                        view: None,
                        output_ref: None,
                        output_bytes: None,
                        diff_ref: None,
                        diff_stats: None,
                        subagent_ref: None,
                        subagent_status: None,
                        subagent_tail: None,
                    }],
                ),
            ];
            state.transcript_replayed = true;
            state.transcript_revision += 1;
        });
        let mut shell = Shell::new(
            state,
            EngineBootConfig {
                data_dir,
                ipc_port: 0,
                edge_url: "http://127.0.0.1:1".into(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: harness_proto::HarnessId::Mock,
            },
            cx,
        );
        shell.debug_gate = Some(GatePhase::Ready);
        shell.splash = SplashPhase::Gone;
        shell.active_chat = "current".into();
        shell
    });
    cx.simulate_resize(gpui::size(px(1200.0), px(800.0)));
    for _ in 0..3 {
        cx.update(|window, cx| window.draw(cx).clear());
        cx.run_until_parked();
    }
    let (working, running) = shell.read_with(cx, |shell, cx| {
        let state = shell.state.read(cx);
        (
            state.indicator_for("current", Utc::now()) == harness_proto::view::Indicator::Working,
            crate::turn_work::running_command(&state.transcript).is_some(),
        )
    });
    assert!(
        working && running,
        "the fixture is a turn running a command"
    );
    (dir, shell, cx)
}

/// A turn running a command leaves the work pane as the person left it: the
/// changes card opens it in one click. Opening it by
/// itself filled a third of the window with "No uncommitted changes" for as
/// long as an agent worked, and came back whenever another pane was focused.
#[gpui::test]
fn a_running_command_does_not_open_the_work_pane(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = running_turn(cx);
    assert!(
        shell.read_with(cx, |shell, cx| !shell.right_pane_open(cx)),
        "a running command opened the work pane"
    );
}

/// No floating "Running ... Stop" bar over the composer: the transcript already
/// shows the command and the composer has Stop. In a split pane the bar ran past
/// both edges of its column.
#[gpui::test]
fn a_running_command_draws_no_bar_over_the_composer(cx: &mut gpui::TestAppContext) {
    let (_dir, _shell, cx) = running_turn(cx);
    assert!(
        cx.debug_bounds("turn-running-pill").is_none(),
        "the running-command bar showed over the composer"
    );
}
