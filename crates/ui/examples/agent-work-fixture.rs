//! The agent work components from synthetic data: no engine, no agent calls.
//! Every card is derived from a made-up transcript through
//! `agent_work::work`, the same path the composer footer uses.
//! `HARNESS_FIXTURE_AGENT_WORK=sheet|footer|before` picks the view:
//! - `sheet`: the timeline (working and waiting on a question), the parts
//!   (step dots, tags, legend, tool chips) and the agents card;
//! - `footer`: the composer footer chip beside the context ring, with the
//!   card its hover opens;
//! - `before`: the same footer without the chip.
//!
//! cargo run -p harness-ui --example agent-work-fixture
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, size,
};
use harness_ui::agent_work::{self, Palette, StepState};
use harness_ui::*;
use serde_json::{Value, json};

fn entry(id: &str, role: &str, at: i64, status: &str, parts: Value) -> Value {
    json!({"id": id, "role": role, "createdAt": at, "deviceId": "preview",
           "status": status, "parts": parts})
}

fn todo(id: &str, done: usize) -> Value {
    let items = [
        "Collect fee data",
        "Compare validators",
        "Draft the report",
        "Check every number",
    ];
    json!({"id": id, "kind": "tool", "resolved": true, "call": {"kind": "todo",
        "items": items.iter().enumerate()
            .map(|(i, t)| json!({"text": t, "done": i < done})).collect::<Vec<_>>()}})
}

fn tool(id: &str, call: Value, resolved: bool) -> Value {
    json!({"id": id, "kind": "tool", "resolved": resolved, "call": call})
}

fn spawn(id: &str, name: &str, status: &str, tail: Option<&str>) -> Value {
    let mut part = tool(id, json!({"kind": "unknown", "name": name}), true);
    part["subagentStatus"] = json!(status);
    if let Some(tail) = tail {
        part["subagentTail"] = json!(tail);
    }
    part
}

/// A made-up turn: two steps done 12s and 18s apart, the third writing, and
/// three subagents. `waiting` ends it on a question for the user.
fn transcript(waiting: bool) -> Vec<Value> {
    let mut last = vec![todo("t3", 2)];
    if !waiting {
        last.push(spawn(
            "s1",
            "Agent: Refactor fee module",
            "running",
            Some("Editing 4 files"),
        ));
        last.push(spawn(
            "s2",
            "Agent: Audit token flows",
            "running",
            Some("Reading contracts"),
        ));
        last.push(spawn("s3", "Agent: Summarize PRs", "done", None));
        last.push(tool(
            "g",
            json!({"kind": "mcp", "server": "GitHub", "tool": "list_pull_requests"}),
            true,
        ));
        last.push(tool(
            "x",
            json!({"kind": "exec", "command": "make test"}),
            true,
        ));
    }
    last.push(tool(
        "f",
        json!({"kind": "webFetch", "url": "https://example.invalid/fees"}),
        true,
    ));
    last.push(tool(
        "w",
        json!({"kind": "writeFile", "path": "report/fee-overview.md"}),
        true,
    ));
    last.push(tool(
        "e",
        json!({"kind": "editFile", "path": "report/validators.md"}),
        waiting,
    ));
    if waiting {
        last.push(json!({"id": "q", "kind": "input", "requestId": "r", "resolved": false,
            "questions": [{"id": "q1", "header": "Send to team",
                           "question": "Send the report to the team?", "options": ["Send", "Not yet"]}]}));
    }
    vec![
        entry(
            "u",
            "user",
            0,
            "complete",
            json!([{"id": "u-t", "kind": "text", "text": "Write the fee report"}]),
        ),
        entry("a1", "assistant", 1_000, "complete", json!([todo("t1", 0)])),
        entry(
            "a2",
            "assistant",
            13_000,
            "complete",
            json!([todo("t2", 1)]),
        ),
        entry("a3", "assistant", 31_000, "streaming", Value::Array(last)),
    ]
}

fn parse(rows: Vec<Value>) -> Vec<harness_doc::SessionMessageEntry> {
    serde_json::from_value(Value::Array(rows)).unwrap()
}

struct Preview {
    mode: String,
    state: Entity<state::AppState>,
    card: gpui::AnyView,
}

fn caption(text: &'static str) -> gpui::Div {
    div()
        .text_size(px(11.0))
        .text_color(gpui::rgb(0xA1A1AA))
        .child(text)
}

impl Render for Preview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx).clone();
        let p = Palette::new(&theme);
        let view = cx.entity_id();
        let phase = agent_work::spin_phase(view, cx);
        let root = div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .bg(gpui::rgb(0x3F3E43))
            .text_color(p.text);
        if self.mode == "sheet" {
            let working = agent_work::work(&parse(transcript(false)));
            let waiting = agent_work::work(&parse(transcript(true)));
            let parts = agent_work::card(&p)
                .w(px(450.0))
                .gap(px(16.0))
                .child(agent_work::step_dots(
                    &[
                        StepState::Done,
                        StepState::Done,
                        StepState::Active,
                        StepState::Pending,
                        StepState::AsksFirst,
                    ],
                    20.0,
                    22.0,
                    &p,
                    phase,
                ))
                .child(
                    div()
                        .flex()
                        .gap(px(8.0))
                        .child(agent_work::tag("Trigger", p.red_text, p.red_bg))
                        .child(agent_work::tag("Agent", p.blue_text, p.blue_bg))
                        .child(agent_work::asks_first_tag(&p)),
                )
                .child(agent_work::legend(&p, phase))
                .child(agent_work::tool_chips(&working.tools, &p));
            return root.child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(14.0))
                    .child(
                        div()
                            .flex()
                            .gap(px(24.0))
                            .items_start()
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(6.0))
                                    .child(caption("Working"))
                                    .child(agent_work::card(&p).child(agent_work::timeline(
                                        &working.steps,
                                        &p,
                                        phase,
                                    ))),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(6.0))
                                    .child(caption("Waiting on a question"))
                                    .child(agent_work::card(&p).child(agent_work::timeline(
                                        &waiting.steps,
                                        &p,
                                        phase,
                                    ))),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .gap(px(24.0))
                            .items_start()
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(6.0))
                                    .child(caption("Parts"))
                                    .child(parts),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(6.0))
                                    .child(caption("Subagents"))
                                    .child(
                                        agent_work::card(&p)
                                            .child(agent_work::agents(&working, &p, phase)),
                                    ),
                            ),
                    )
                    .child(caption("Example data")),
            );
        }
        // The footer as the composer lays it out: chip, then the context ring.
        let usage = self.state.read(cx).context_usage;
        let chip = (self.mode == "footer")
            .then(|| agent_work::footer_chip(self.state.clone(), &theme, view, cx))
            .flatten();
        let footer = div()
            .w(px(420.0))
            .h(px(36.0))
            .px(px(10.0))
            .rounded(px(12.0))
            .bg(theme.surface)
            .border(px(1.0))
            .border_color(theme.border)
            .flex()
            .items_center()
            .child(div().flex_1())
            .children(chip.map(|c| div().flex_none().pr(px(4.0)).child(c)))
            .child(context_usage::render(usage, self.state.clone(), &theme));
        root.child(
            div()
                .flex()
                .flex_col()
                .items_end()
                .gap(px(8.0))
                .when(self.mode == "footer", |col| col.child(self.card.clone()))
                .child(footer),
        )
    }
}

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    let _guard = runtime.enter();
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".into()))
        .init();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    let mode = std::env::var("HARNESS_FIXTURE_AGENT_WORK").unwrap_or_else(|_| "sheet".into());
    let appearance = match std::env::var("HARNESS_FIXTURE_APPEARANCE").as_deref() {
        Ok("light") => appearance::AppearanceMode::Light,
        _ => appearance::AppearanceMode::Dark,
    };
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.clone(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                settings.ui_font_family.clone(),
                settings.ui_font_size,
                settings.terminal_font_family.clone(),
                settings.terminal_font_size,
                settings.code_font_family.clone(),
                settings.code_font_size,
                fonts,
                cx,
            );
            theme_library::init(data.clone(), cx);
            appearance::init(
                appearance,
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            let state = cx.new(|_| state::AppState::new());
            state.update(cx, |state, cx| {
                state
                    .receive_transcript_frame(
                        harness_doc::TranscriptFrame::Reset {
                            reset: serde_json::from_value(Value::Array(transcript(false))).unwrap(),
                        },
                        cx,
                    )
                    .unwrap();
                state.context_usage = Some(harness_proto::ContextUsage {
                    tokens: Some(112_000),
                    window: Some(200_000),
                    // graff's savings meta, so the ring's card shows "Nk saved".
                    savings: Some(harness_proto::ContextSavings {
                        handle_bytes: 96_000,
                        compacted_tokens: 0,
                        cache_read_tokens: 0,
                    }),
                });
                cx.notify();
            });
            // The same card the footer chip opens on hover.
            let card = agent_work::hover_card(state.clone(), cx);
            let (w, h) = if mode == "sheet" {
                (900., 760.)
            } else {
                (560., 640.)
            };
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(w), px(h)),
                    ))),
                    ..Default::default()
                },
                |_, cx| cx.new(|_| Preview { mode, state, card }),
            )
            .unwrap();
            cx.activate(true);
        });
    Ok(())
}
