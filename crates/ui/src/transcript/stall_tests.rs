//! What one streamed token costs in a very long live turn (#342, with the
//! turn shapes of #341), measured through the watch's own path: background
//! preparation, then apply, sync and draw on the UI thread.
//!
//! A diagnostic report, not an assertion (timings vary by machine and build).
//! In a debug build it showed the UI-thread cost per token flat as one live
//! thought grows to 1 MB, and growing linearly with the number of thought and
//! tool steps in the live turn (its auto-opened group draws every step on
//! every frame), while background preparation grows with both.

use super::*;

fn assistant(id: &str, status: MessageStatus, parts: Vec<MessagePart>) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role: MessageRole::Assistant,
        parts,
        created_at: 0,
        device_id: "dev".into(),
        status: Some(status),
        continuation_of: None,
        duration_ms: None,
    }
}

fn exec(id: String) -> MessagePart {
    MessagePart::Tool {
        id,
        call: ToolCall::Exec {
            command: "cargo check".into(),
        },
        is_error: false,
        resolved: true,
        output: Some("Finished".into()),
        diff: None,
        output_ref: None,
        output_bytes: None,
        diff_ref: None,
        diff_stats: None,
        subagent_ref: None,
        subagent_status: None,
        subagent_tail: None,
        view: None,
    }
}

/// One live reply of `steps` thought + tool pairs, as a self-continued turn
/// re-joins its segments into one streaming entry. Each thought is ~2 KB.
fn live_turn(steps: usize, tail_bytes: usize) -> SessionMessageEntry {
    let thought = "Considering the next change to the parser and its tests. ".repeat(36);
    let mut parts = Vec::new();
    for step in 0..steps {
        parts.push(MessagePart::Reasoning {
            id: format!("r{step}"),
            text: thought.clone(),
        });
        parts.push(exec(format!("t{step}")));
    }
    parts.push(MessagePart::Reasoning {
        id: "tail".into(),
        text: tail_text(tail_bytes),
    });
    assistant("live", MessageStatus::Streaming, parts)
}

/// `bytes` of reasoning that ends with "Thinking", in short paragraphs.
fn tail_text(bytes: usize) -> String {
    let paragraph = "The fragment streams in a few words at a time, then pauses.\n\n";
    let mut text = paragraph.repeat(bytes / paragraph.len());
    text.push_str("Thinking");
    text
}

struct Host(Entity<Transcript>);
impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.0.clone())
    }
}

/// Mean per-token cost in microseconds, split by where it runs.
#[derive(Debug)]
pub(super) struct TokenCost {
    /// `TranscriptPreparation::prepare` (the watch runs it off the UI thread).
    pub prepare_us: f64,
    /// Applying the frame and syncing rows (UI thread).
    pub apply_us: f64,
    /// Drawing the next frame (UI thread).
    pub draw_us: f64,
}

/// Stream `deltas` reasoning tokens into a live turn of `steps` steps through
/// the watch's path: prepare, apply with the prepared rows, sync, draw.
pub(super) fn per_token_cost(
    cx: &mut gpui::TestAppContext,
    steps: usize,
    tail_bytes: usize,
    deltas: usize,
) -> TokenCost {
    per_token_cost_with_history(cx, 0, steps, tail_bytes, deltas).1
}

/// A settled earlier turn: the prompt, then a reply with a thought, two tool
/// calls and a few paragraphs of text.
fn settled_turn(turn: usize) -> [SessionMessageEntry; 2] {
    let prompt = SessionMessageEntry {
        role: MessageRole::User,
        status: None,
        ..assistant(
            &format!("p{turn}"),
            MessageStatus::Complete,
            vec![MessagePart::Text {
                id: format!("p{turn}-text"),
                text: "Run the suite and fix whatever fails.".into(),
            }],
        )
    };
    let reply = assistant(
        &format!("a{turn}"),
        MessageStatus::Complete,
        vec![
            MessagePart::Reasoning {
                id: format!("a{turn}-r"),
                text: "Considering the next change to the parser and its tests. ".repeat(8),
            },
            exec(format!("a{turn}-t0")),
            exec(format!("a{turn}-t1")),
            MessagePart::Text {
                id: format!("a{turn}-text"),
                text: "The parser now accepts trailing commas.\n\n".repeat(6),
            },
        ],
    );
    [prompt, reply]
}

/// [`per_token_cost`] behind `history` settled turns; also returns what the
/// opening reset cost on the UI thread (apply + first draw).
pub(super) fn per_token_cost_with_history(
    cx: &mut gpui::TestAppContext,
    history: usize,
    steps: usize,
    tail_bytes: usize,
    deltas: usize,
) -> (Duration, TokenCost) {
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::expanded(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    let window = cx.add_window(|_, cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx))));
    let draw = |cx: &mut gpui::TestAppContext| {
        cx.update_window(window.into(), |_, window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        })
        .unwrap();
    };
    let mut worker = TranscriptPreparation::default();
    let mut deliver = |update: harness_doc::TranscriptUpdate, cx: &mut gpui::TestAppContext| {
        let started = Instant::now();
        let prepared = worker.prepare(&update).unwrap();
        let prepare = started.elapsed();
        let started = Instant::now();
        state.update(cx, |state, cx| {
            state
                .receive_opening_transcript_update(update, false, cx)
                .unwrap();
            state.prepared_transcripts.insert("chat".into(), prepared);
        });
        cx.run_until_parked();
        let apply = started.elapsed();
        let started = Instant::now();
        draw(cx);
        (prepare, apply, started.elapsed())
    };
    state.update(cx, |state, cx| state.select_chat(Some("chat".into()), cx));
    let prompt = SessionMessageEntry {
        role: MessageRole::User,
        status: None,
        ..assistant(
            "p",
            MessageStatus::Complete,
            vec![MessagePart::Text {
                id: "text".into(),
                text: "Keep going until the suite passes.".into(),
            }],
        )
    };
    let mut entries: Vec<SessionMessageEntry> = (0..history).flat_map(settled_turn).collect();
    entries.extend([prompt, live_turn(steps, tail_bytes)]);
    let count = entries.len();
    let (_, reset_apply, reset_draw) = deliver(
        harness_doc::TranscriptUpdate {
            frame: harness_doc::TranscriptFrame::reset(&entries),
            context_usage: None,
            replay_baseline: None,
        },
        cx,
    );
    let mut len = tail_text(tail_bytes).len();
    let mut total = [Duration::ZERO; 3];
    for _ in 0..deltas {
        let text = " about it".to_string();
        len += text.len();
        let (prepare, apply, draw) = deliver(
            harness_doc::TranscriptUpdate {
                frame: harness_doc::TranscriptFrame::Delta {
                    upsert: Vec::new(),
                    append: vec![harness_doc::TextAppend {
                        entry: "live".into(),
                        part: "tail".into(),
                        text,
                        len,
                    }],
                    remove: Vec::new(),
                    count,
                },
                context_usage: None,
                replay_baseline: None,
            },
            cx,
        );
        total[0] += prepare;
        total[1] += apply;
        total[2] += draw;
    }
    let mean = |d: Duration| d.as_secs_f64() * 1e6 / deltas as f64;
    (
        reset_apply + reset_draw,
        TokenCost {
            prepare_us: mean(total[0]),
            apply_us: mean(total[1]),
            draw_us: mean(total[2]),
        },
    )
}

/// Prints the per-token cost as the live turn grows. Run with
/// `cargo test -p harness-ui --lib stall_tests -- --ignored --nocapture`.
#[gpui::test]
#[ignore = "timing report, not an assertion"]
fn report_per_token_cost_by_live_turn_size(cx: &mut gpui::TestAppContext) {
    let only: Option<usize> = std::env::var("STALL_STEPS")
        .ok()
        .and_then(|v| v.parse().ok());
    let deltas = std::env::var("STALL_DELTAS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(10);
    if let Some(history) = std::env::var("STALL_HISTORY")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        let (reset, cost) = per_token_cost_with_history(cx, history, 5, 0, deltas);
        eprintln!("{history:>5} settled turns + live turn of 5 steps: opening {reset:?}; {cost:?}");
        return;
    }
    let sizes = only.map_or(vec![25, 100, 400, 1600], |steps| vec![steps]);
    for steps in sizes {
        let cost = per_token_cost(cx, steps, 0, deltas);
        eprintln!("live turn of {steps:>5} steps: {cost:?}");
    }
    if only.is_none() {
        for history in [100, 400, 1600, 3200] {
            let (reset, cost) = per_token_cost_with_history(cx, history, 5, 0, deltas);
            eprintln!(
                "{history:>5} settled turns + live turn of 5 steps: opening {reset:?}; {cost:?}"
            );
        }
        for kb in [16, 64, 256, 1024] {
            let cost = per_token_cost(cx, 20, kb * 1024, deltas);
            eprintln!("20 steps, live thought of {kb:>5} KB: {cost:?}");
        }
    }
}
