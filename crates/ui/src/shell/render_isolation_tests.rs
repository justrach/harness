//! The transcript and the composer are cached views: typing redraws the
//! composer without rebuilding transcript rows, a streamed chunk redraws the
//! transcript without rebuilding the composer, and the changes each of them
//! must show (chat switch, theme, the composer growing) still redraw them.
use super::*;
use crate::transcript::render_total;
use harness_doc::{
    MessagePart, MessageRole, MessageStatus, SessionMessageEntry, TextAppend, TranscriptFrame,
    TranscriptUpsert,
};

fn entry(
    id: &str,
    role: MessageRole,
    text: String,
    status: Option<MessageStatus>,
) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: format!("{id}-text"),
            text,
        }],
        created_at: 1_790_000_000_000,
        device_id: "local".into(),
        status,
        continuation_of: None,
        duration_ms: None,
    }
}

/// Twelve made-up turns, each a prompt and a reply with a list and code.
fn conversation() -> Vec<SessionMessageEntry> {
    (0..12)
        .flat_map(|turn| {
            [
                entry(
                    &format!("user-{turn}"),
                    MessageRole::User,
                    format!("Step {turn}: tidy the parser"),
                    None,
                ),
                entry(
                    &format!("reply-{turn}"),
                    MessageRole::Assistant,
                    format!(
                        "Step {turn} keeps one buffer per input.\n\n- Buffers are reused\n- \
                         Errors carry offsets\n\n```rust\nfn parse_{turn}() {{}}\n```"
                    ),
                    Some(MessageStatus::Complete),
                ),
            ]
        })
        .collect()
}

fn session(chat: &str, status: harness_proto::SessionStatus) -> harness_proto::Session {
    harness_proto::Session {
        last_completed_turn: None,
        last_completed_peer_only: false,
        chat_id: chat.into(),
        device_id: "local".into(),
        status,
        started_at: Some(Utc::now()),
        updated_at: Utc::now(),
    }
}

struct Counts {
    transcripts: usize,
    rows: usize,
    composers: usize,
}

fn counts() -> (u64, u64, u64) {
    (
        render_total("transcript"),
        render_total("transcript-row"),
        render_total("composer"),
    )
}

fn since(before: (u64, u64, u64)) -> Counts {
    let now = counts();
    Counts {
        transcripts: (now.0 - before.0) as usize,
        rows: (now.1 - before.1) as usize,
        composers: (now.2 - before.2) as usize,
    }
}

/// A shell on a selected chat with a conversation on screen and the
/// composer focused (after one caret move: the first key press switches the
/// window to keyboard focus styling, which redraws everything once).
fn open_chat(
    cx: &mut gpui::TestAppContext,
    data_dir: std::path::PathBuf,
) -> (Entity<Shell>, &mut gpui::VisualTestContext) {
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
        settings::init(settings::UiSettings::expanded(), &data_dir, cx);
        // Route and dock tweens run on the wall clock, not the test clock: a
        // slow machine could still be animating (redrawing everything) when
        // the measurement starts.
        motion::set_reduced_motion(cx, true);
    });
    let (shell, cx) = cx.add_window_view(|_, cx| {
        let state = cx.new(|_| AppState::new());
        Shell::new(
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
        )
    });
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, cx| {
            state.workspace_scope = Some(WorkspaceScope::Local);
            state.local_device_id = Some("local".into());
            state.chats_synced = true;
            state.spaces_synced = true;
            state.spaces = vec![
                serde_json::from_value(serde_json::json!({
                    "id": "project", "deviceId": "local", "path": "/tmp/render-isolation",
                    "createdAt": "2026-09-20T00:00:00Z"
                }))
                .unwrap(),
            ];
            state.chats = ["chat-1", "chat-2"]
                .map(|id| {
                    serde_json::from_value(serde_json::json!({
                        "id": id, "title": format!("Parser {id}"), "deviceId": "local",
                        "spaceId": "project", "archived": false,
                        "createdAt": "2026-09-20T00:00:00Z"
                    }))
                    .unwrap()
                })
                .to_vec();
            state.select_chat(Some("chat-1".into()), cx);
            state
                .receive_transcript_frame(TranscriptFrame::reset(&conversation()), cx)
                .unwrap();
            state.apply_sessions(vec![session("chat-1", harness_proto::SessionStatus::Idle)]);
        });
        shell.debug_gate = Some(GatePhase::Ready);
        shell.splash = SplashPhase::Gone;
        cx.notify();
    });
    cx.simulate_resize(gpui::size(px(1200.0), px(800.0)));
    for _ in 0..3 {
        cx.executor().advance_clock(Duration::from_secs(2));
        cx.run_until_parked();
    }
    cx.update(|window, cx| {
        let focus = shell.read(cx).composer.focus_handle(cx);
        window.focus(&focus, cx);
    });
    cx.simulate_keystrokes("right");
    cx.run_until_parked();
    (shell, cx)
}

#[gpui::test]
fn typing_redraws_the_composer_and_not_the_transcript(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (_shell, cx) = open_chat(cx, dir.path().to_path_buf());
    let before = counts();
    for ch in "hello world".chars() {
        cx.simulate_input(&ch.to_string());
        cx.run_until_parked();
    }
    let rendered = since(before);
    assert!(
        rendered.composers >= 11,
        "each keystroke redraws the composer ({} renders)",
        rendered.composers
    );
    assert_eq!(
        (rendered.transcripts, rendered.rows),
        (0, 0),
        "typing rebuilt the transcript (views, rows)"
    );
}

#[gpui::test]
fn a_streamed_chunk_redraws_the_transcript_and_not_the_composer(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = open_chat(cx, dir.path().to_path_buf());
    let state = shell.read_with(cx, |shell, _| shell.state.clone());
    let mut entries = conversation();
    let last = entries.last_mut().unwrap();
    last.status = Some(MessageStatus::Streaming);
    let mut live = last.clone();
    let after = entries[entries.len() - 2].id.clone();
    let count = entries.len();
    state.update(cx, |state, cx| {
        state
            .receive_transcript_frame(
                TranscriptFrame::Delta {
                    upsert: vec![TranscriptUpsert {
                        after: Some(after),
                        entry: live.clone(),
                    }],
                    append: Vec::new(),
                    remove: Vec::new(),
                    count,
                },
                cx,
            )
            .unwrap();
        state.apply_sessions(vec![session(
            "chat-1",
            harness_proto::SessionStatus::Working,
        )]);
    });
    cx.run_until_parked();

    let before = counts();
    for chunk in 0..5 {
        let text = format!(" Chunk {chunk} of the reply.");
        let MessagePart::Text { text: body, .. } = &mut live.parts[0] else {
            unreachable!()
        };
        body.push_str(&text);
        let frame = TranscriptFrame::Delta {
            upsert: Vec::new(),
            append: vec![TextAppend {
                entry: live.id.clone(),
                part: format!("{}-text", live.id),
                text,
                len: body.len(),
            }],
            remove: Vec::new(),
            count,
        };
        state.update(cx, |state, cx| {
            state.receive_transcript_frame(frame, cx).unwrap()
        });
        cx.run_until_parked();
    }
    let rendered = since(before);
    assert!(
        rendered.transcripts >= 5 && rendered.rows > 0,
        "each chunk redraws the transcript ({} renders, {} rows)",
        rendered.transcripts,
        rendered.rows
    );
    assert_eq!(
        rendered.composers, 0,
        "a streamed chunk rebuilt the composer"
    );
}

#[gpui::test]
fn switching_chats_and_theme_still_redraw_both_views(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = open_chat(cx, dir.path().to_path_buf());
    let state = shell.read_with(cx, |shell, _| shell.state.clone());

    let before = counts();
    state.update(cx, |state, cx| state.select_chat(Some("chat-2".into()), cx));
    cx.run_until_parked();
    let switched = since(before);
    assert!(switched.transcripts > 0, "the transcript kept the old chat");
    assert!(
        switched.composers > 0,
        "the composer kept the old chat's draft"
    );

    let before = counts();
    cx.update(|_, cx| {
        let mut theme = Theme::of(cx).clone();
        theme.text = gpui::red();
        cx.set_global(theme);
        cx.refresh_windows();
    });
    cx.run_until_parked();
    let themed = since(before);
    assert!(
        themed.transcripts > 0 && themed.composers > 0,
        "a theme change was not drawn"
    );
}

/// The composer grows a line at a time; the cached transcript under it must
/// still redraw for the taller chrome it scrolls under.
#[gpui::test]
fn a_growing_composer_redraws_the_transcript_under_it(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = open_chat(cx, dir.path().to_path_buf());
    let height = |cx: &mut gpui::VisualTestContext| {
        shell.read_with(cx, |shell, cx| {
            shell
                .composer
                .read(cx)
                .surface_bounds()
                .get()
                .map(|bounds| f32::from(bounds.size.height))
                .unwrap_or_default()
        })
    };
    let start = height(cx);
    let before = counts();
    for line in ["one", "two", "three", "four"] {
        cx.simulate_keystrokes("shift-enter");
        cx.simulate_input(line);
        cx.run_until_parked();
    }
    for _ in 0..3 {
        cx.executor().advance_clock(Duration::from_millis(500));
        cx.run_until_parked();
    }
    assert!(
        height(cx) > start + 20.0,
        "the composer did not grow: {start} → {}",
        height(cx)
    );
    assert!(
        since(before).transcripts > 0,
        "the transcript kept the clearance of the shorter composer"
    );
}
