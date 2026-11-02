//! #23: chat text and icons reported doubled and blurred after scrolling to
//! the bottom. Two layout faults would look like that: one frame painting a
//! row twice (or rows that don't sit back to back), and a viewport that flips
//! between two positions frame after frame. `scrolling_to_the_bottom_settles`
//! covers plain replies; this covers the configurations it leaves out: the
//! rail, compact mode, a held own-turn runway, and replies with thoughts and
//! tool groups, at several widths and frame rates.

use super::*;
use crate::transcript_paint_check::{ViewportFlicker, ViewportSample, painted_rows_anomaly};

fn entry(
    id: &str,
    role: MessageRole,
    status: Option<MessageStatus>,
    parts: Vec<MessagePart>,
) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts,
        created_at: 0,
        device_id: "dev".into(),
        status,
        continuation_of: None,
        duration_ms: None,
    }
}

fn text(id: &str, text: &str) -> MessagePart {
    MessagePart::Text {
        id: id.into(),
        text: text.into(),
    }
}

fn exec(id: &str) -> MessagePart {
    MessagePart::Tool {
        id: id.into(),
        call: ToolCall::Exec {
            command: "cargo test".into(),
        },
        is_error: false,
        resolved: true,
        output: Some("ok".into()),
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

#[derive(Clone, Copy, Debug)]
struct Scenario {
    rail: bool,
    compact: bool,
    own_send: bool,
    tools: bool,
    width: Option<f32>,
    frame_ms: u64,
}

struct Host(Entity<Transcript>);
impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.0.clone())
    }
}

/// A long chat, then a turn of its own that streams and completes; scroll up,
/// back down to the bottom with fractional deltas and momentum against the
/// clamp, then rest. `Err` names the first frame that painted rows
/// inconsistently, alternated, or (without tool groups) moved at rest.
fn run(cx: &mut gpui::TestAppContext, s: Scenario) -> Result<(), String> {
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::expanded(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    let window = cx.add_window(|_, cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx))));
    let transcript = window.update(cx, |host, _, _| host.0.clone()).unwrap();
    if let Some(width) = s.width {
        window
            .update(cx, |_, window, _| window.resize(size(px(width), px(800.0))))
            .unwrap();
    }
    transcript.update(cx, |this, _| {
        this.rail_enabled = s.rail;
        this.compact_mode = s.compact;
    });
    let draw = |cx: &mut gpui::TestAppContext| {
        cx.update_window(window.into(), |_, window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        })
        .unwrap();
    };
    let feed = |entries: Vec<SessionMessageEntry>, cx: &mut gpui::TestAppContext| {
        state.update(cx, |state, _| {
            state.selected_chat = Some("chat".into());
            state.transcript_replayed = true;
            state.transcript = entries;
            state.transcript_revision += 1;
        });
        transcript.update(cx, |this, cx| this.sync(cx));
    };
    let frame_ms = s.frame_ms;
    let tick = |cx: &mut gpui::TestAppContext| {
        transcript.update(cx, |this, cx| {
            this.own_turn_last_tick = Some(Instant::now() - Duration::from_millis(frame_ms));
            this.spring_last_tick = Some(Instant::now() - Duration::from_millis(frame_ms));
            if this.own_turn.is_some() || this.deferred_own_send.is_some() || this.own_turn_kick {
                this.step_own_turn(cx);
            }
            if this.pinned {
                this.step_spring(cx);
            }
        });
        draw(cx);
    };
    let wheel = |delta: f32, cx: &mut gpui::TestAppContext| {
        cx.update_window(window.into(), |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::ScrollWheel(gpui::ScrollWheelEvent {
                    position: gpui::point(px(100.0), px(300.0)),
                    delta: gpui::ScrollDelta::Pixels(gpui::point(px(0.0), px(delta))),
                    ..Default::default()
                }),
                cx,
            );
        })
        .unwrap();
        cx.run_until_parked();
    };
    let flicker = RefCell::new(ViewportFlicker::default());
    let frame = |label: &str,
                 cx: &mut gpui::TestAppContext|
     -> Result<Vec<(usize, Bounds<Pixels>)>, String> {
        let (painted, rows) =
            transcript.read_with(cx, |this, _| (this.list.painted_items(), this.rows.len()));
        if painted.is_empty() {
            return Err(format!("{label}: nothing painted"));
        }
        if let Some(problem) = painted_rows_anomaly(&painted) {
            return Err(format!("{label}: {problem}"));
        }
        let sample = ViewportSample::new(rows, &painted).unwrap();
        flicker.borrow_mut().remember(&painted);
        if flicker.borrow_mut().record(sample) {
            return Err(format!(
                "{label}: viewport alternating: {}",
                flicker.borrow().difference()
            ));
        }
        Ok(painted)
    };
    let prompt = |id: &str| {
        entry(
            id,
            MessageRole::User,
            None,
            vec![text("text", "Please explain this.")],
        )
    };
    let body = (0..12)
        .map(|i| format!("Paragraph {i} of a long answer, with enough words to wrap.\n\n"))
        .collect::<String>();
    let reply = |id: &str, status: MessageStatus, body: &str| {
        let mut parts = Vec::new();
        if s.tools {
            parts.push(MessagePart::Reasoning {
                id: "think".into(),
                text: "Weighing the options.".into(),
            });
            parts.push(exec("t1"));
            parts.push(exec("t2"));
        }
        parts.push(text("text", body));
        entry(id, MessageRole::Assistant, Some(status), parts)
    };
    let mut history = Vec::new();
    for i in 0..20 {
        history.push(prompt(&format!("p{i}")));
        history.push(reply(&format!("r{i}"), MessageStatus::Complete, &body));
    }
    feed(history.clone(), cx);
    for _ in 0..10 {
        tick(cx);
    }

    // A turn of our own: the prompt, then a streamed reply that completes.
    history.push(prompt("p-live"));
    feed(history.clone(), cx);
    if s.own_send {
        transcript.update(cx, |this, cx| {
            this.on_own_send("chat".into(), "p-live".into(), cx)
        });
    }
    for _ in 0..6 {
        tick(cx);
    }
    for paragraphs in 1..20 {
        let live = (0..paragraphs)
            .map(|i| format!("Live paragraph {i} streams in with a few more words.\n\n"))
            .collect::<String>();
        let mut entries = history.clone();
        entries.push(reply("r-live", MessageStatus::Streaming, &live));
        feed(entries, cx);
        tick(cx);
        frame(&format!("streaming {paragraphs}"), cx)?;
    }
    let live = (0..19)
        .map(|i| format!("Live paragraph {i} streams in with a few more words.\n\n"))
        .collect::<String>();
    history.push(reply("r-live", MessageStatus::Complete, &live));
    feed(history.clone(), cx);
    for step in 0..20 {
        tick(cx);
        frame(&format!("settling {step}"), cx)?;
    }

    // Scroll up, then back down to the bottom with fractional deltas.
    for step in 0..8 {
        wheel(97.3, cx);
        draw(cx);
        frame(&format!("scrolling up {step}"), cx)?;
    }
    for step in 0..60 {
        wheel(-17.35, cx);
        wheel(-14.35, cx);
        tick(cx);
        frame(&format!("scrolling down {step}"), cx)?;
    }
    // Momentum keeps pushing at the clamp after the bottom is reached.
    for step in 0..20 {
        wheel(-3.3, cx);
        tick(cx);
        frame(&format!("momentum at the bottom {step}"), cx)?;
    }
    // At rest. Tool groups may still be finishing their own reveal and fold
    // tweens, which move rows legitimately; without them nothing may move.
    let rest = frame("at the bottom", cx)?;
    let (pinned, rows, viewport) = transcript.read_with(cx, |this, _| {
        (this.pinned, this.rows.len(), this.list.viewport_bounds())
    });
    if !pinned {
        return Err("the pin didn't re-engage at the bottom".into());
    }
    // The clamp lands the newest row flush with the viewport's bottom, not a
    // fraction of a pixel off it (a held runway ends below its reply).
    let (last, bounds) = *rest.last().unwrap();
    if !s.own_send
        && (last + 1 != rows || f32::from(bounds.bottom() - viewport.bottom()).abs() > 0.01)
    {
        return Err(format!(
            "at the bottom: row {last} of {rows} ends at {:.2}, viewport at {:.2}",
            f32::from(bounds.bottom()),
            f32::from(viewport.bottom())
        ));
    }
    for step in 0..30 {
        tick(cx);
        let now = frame(&format!("resting {step}"), cx)?;
        if !s.tools && now != rest {
            return Err(format!("resting {step}: moved at rest"));
        }
    }
    Ok(())
}

#[gpui::test]
fn scrolling_to_the_bottom_never_doubles_rows_or_alternates(cx: &mut gpui::TestAppContext) {
    let base = Scenario {
        rail: true,
        compact: false,
        own_send: false,
        tools: true,
        width: None,
        frame_ms: 17,
    };
    let scenarios = [
        base,
        Scenario {
            tools: false,
            ..base
        },
        Scenario {
            compact: true,
            ..base
        },
        Scenario {
            own_send: true,
            ..base
        },
        Scenario {
            own_send: true,
            compact: true,
            ..base
        },
        Scenario {
            width: Some(360.0),
            own_send: true,
            frame_ms: 50,
            ..base
        },
        Scenario {
            rail: false,
            frame_ms: 8,
            ..base
        },
    ];
    for scenario in scenarios {
        if let Err(problem) = run(cx, scenario) {
            panic!("{scenario:?}: {problem}");
        }
    }
}
