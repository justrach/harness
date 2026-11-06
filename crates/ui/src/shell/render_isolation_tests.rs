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
fn show_two_chats(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) {
    use super::workspace_panels::{PanelTab, WorkspacePanel};
    shell.update(cx, |shell, cx| {
        shell.boot_restored = true;
        shell.ensure_workspace_sessions(cx);
        let layout = shell.panel_layout_mut(cx);
        layout.panels = ["chat-1", "chat-2"]
            .into_iter()
            .enumerate()
            .map(|(id, chat)| WorkspacePanel {
                id: id as u64,
                tabs: vec![PanelTab::Chat(chat.into())],
                active: 0,
                share: 0.5,
            })
            .collect();
        layout.focused = 0;
        layout.next_id = 2;
        layout.last_selected = Some(Some("chat-1".into()));
        cx.notify();
    });
    cx.run_until_parked();
}

/// A second visible chat has its own transcript entity and a parked draft.
/// Typing in the active panel must not rebuild either transcript or consume
/// the other panel's draft; promotion must keep the peer entity and its state.
#[gpui::test]
fn cached_workspace_peers_stay_idle_while_typing_and_follow_panel_focus(
    cx: &mut gpui::TestAppContext,
) {
    use super::workspace_panels::PanelTab;
    use crate::transcript::entity_render_total;
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = open_chat(cx, dir.path().to_path_buf());
    show_two_chats(&shell, cx);
    let (main, peer) = shell.read_with(cx, |shell, _| {
        (
            shell.transcript.entity_id(),
            shell.workspace_panels.peers["chat-2"].0.entity_id(),
        )
    });
    assert!(
        entity_render_total(peer) > 0,
        "the inactive chat must actually be rendered"
    );
    cx.simulate_keystrokes("right");
    cx.run_until_parked();
    let before = (entity_render_total(main), entity_render_total(peer));
    cx.simulate_input("Draft for the first panel");
    cx.run_until_parked();
    assert_eq!(
        (entity_render_total(main), entity_render_total(peer)),
        before,
        "typing must reuse both visible transcripts"
    );
    shell.update_in(cx, |shell, window, cx| {
        shell.focus_workspace_tab(1, PanelTab::Chat("chat-2".into()), window, cx);
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.transcript.entity_id(),
            peer,
            "focus promotes the retained peer"
        );
        assert_eq!(
            shell.composer.read(cx).parked_chat_input("chat-1", cx).text,
            "Draft for the first panel"
        );
        assert_eq!(shell.composer.read(cx).input.read(cx).text(), "");
    });
    cx.simulate_input("Draft for the second panel");
    cx.run_until_parked();
    shell.update_in(cx, |shell, window, cx| {
        shell.focus_workspace_tab(0, PanelTab::Chat("chat-1".into()), window, cx);
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.transcript.entity_id(), main);
        assert_eq!(
            shell.composer.read(cx).input.read(cx).text(),
            "Draft for the first panel"
        );
        assert_eq!(
            shell.composer.read(cx).parked_chat_input("chat-2", cx).text,
            "Draft for the second panel"
        );
    });
}

/// These are actual picker/state transitions, not an unconditional cache flush:
/// target and model changes must invalidate the cached composer and retain its
/// unsent text while the corresponding selections are read back.
#[gpui::test]
fn cached_composer_tracks_device_project_and_model_without_losing_the_draft(
    cx: &mut gpui::TestAppContext,
) {
    use crate::transcript::entity_render_total;
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = open_chat(cx, dir.path().to_path_buf());
    let (state, composer) =
        shell.read_with(cx, |shell, _| (shell.state.clone(), shell.composer.clone()));
    state.update(cx, |state, cx| state.select_chat(None, cx));
    cx.run_until_parked();
    composer.update(cx, |composer, cx| {
        composer
            .input
            .update(cx, |input, cx| input.set_text("Keep this draft", cx))
    });
    cx.run_until_parked();

    let before = entity_render_total(composer.entity_id());
    state.update(cx, |state, cx| {
        state.select_device("other-computer".into(), cx)
    });
    cx.run_until_parked();
    assert!(
        entity_render_total(composer.entity_id()) > before,
        "device change left the composer cache stale"
    );
    state.read_with(cx, |state, _| {
        assert_eq!(state.selected_device.as_deref(), Some("other-computer"))
    });

    let before = entity_render_total(composer.entity_id());
    state.update(cx, |state, cx| {
        state.select_space(Some("project".into()), cx)
    });
    cx.run_until_parked();
    assert!(
        entity_render_total(composer.entity_id()) > before,
        "project change left the composer cache stale"
    );
    state.read_with(cx, |state, _| {
        assert_eq!(state.selected_space.as_deref(), Some("project"))
    });

    let before = entity_render_total(composer.entity_id());
    let pickers = composer.read_with(cx, |composer, _| composer.pickers().clone());
    pickers.update(cx, |pickers, cx| {
        pickers.adopt_canvas_draft(
            Some(crate::pickers::CanvasDraft {
                harness: Some(harness_proto::HarnessId::Mock),
                model: Some("cache-fixture-model".into()),
                ..Default::default()
            }),
            cx,
        );
    });
    cx.run_until_parked();
    assert!(
        entity_render_total(composer.entity_id()) > before,
        "model change left the composer cache stale"
    );
    pickers.read_with(cx, |pickers, cx| {
        assert_eq!(
            pickers.canvas_draft(cx).model.as_deref(),
            Some("cache-fixture-model")
        )
    });
    composer.read_with(cx, |composer, cx| {
        assert_eq!(composer.input.read(cx).text(), "Keep this draft")
    });
}

/// The real tab detach path creates a separate AppState and composer. A late
/// shared capability result/settings change must reach both caches without
/// moving either draft or making the windows share a composer.
#[gpui::test]
fn detached_window_composer_caches_receive_shared_invalidations(cx: &mut gpui::TestAppContext) {
    use super::workspace_panels::PanelTab;
    use crate::transcript::entity_render_total;
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = open_chat(cx, dir.path().to_path_buf());
    show_two_chats(&shell, cx);
    cx.simulate_input("Original window draft");
    cx.run_until_parked();
    let destination = shell.update_in(cx, |shell, window, cx| {
        shell
            .move_workspace_tab_to_new_window(1, PanelTab::Chat("chat-2".into()), None, window, cx)
            .unwrap()
    });
    let source_composer = shell.read_with(cx, |shell, _| shell.composer.clone());
    let detached_composer = cx.update(|_, cx| {
        destination
            .update(cx, |shell, _, cx| {
                shell.debug_gate = Some(GatePhase::Ready);
                shell.splash = SplashPhase::Gone;
                shell.composer.update(cx, |composer, cx| {
                    composer
                        .input
                        .update(cx, |input, cx| input.set_text("Detached window draft", cx))
                });
                cx.notify();
                shell.composer.clone()
            })
            .unwrap()
    });
    cx.run_until_parked();
    assert_ne!(source_composer.entity_id(), detached_composer.entity_id());
    assert!(entity_render_total(source_composer.entity_id()) > 0);
    assert!(entity_render_total(detached_composer.entity_id()) > 0);

    let before = (
        entity_render_total(source_composer.entity_id()),
        entity_render_total(detached_composer.entity_id()),
    );
    cx.update(|_, cx| cx.set_global(crate::composer::DictationAvailabilityChanged));
    cx.run_until_parked();
    assert!(
        entity_render_total(source_composer.entity_id()) > before.0,
        "original window missed the late capability result"
    );
    assert!(
        entity_render_total(detached_composer.entity_id()) > before.1,
        "detached window missed the late capability result"
    );

    let before = (
        entity_render_total(source_composer.entity_id()),
        entity_render_total(detached_composer.entity_id()),
    );
    cx.update(|_, cx| {
        settings::update(settings::SavePolicy::Immediate, cx, |next| {
            next.attach_sound_enabled = !next.attach_sound_enabled;
        });
    });
    cx.run_until_parked();
    assert!(entity_render_total(source_composer.entity_id()) > before.0);
    assert!(entity_render_total(detached_composer.entity_id()) > before.1);
    source_composer.read_with(cx, |composer, cx| {
        assert_eq!(composer.input.read(cx).text(), "Original window draft")
    });
    detached_composer.read_with(cx, |composer, cx| {
        assert_eq!(composer.input.read(cx).text(), "Detached window draft")
    });
}
