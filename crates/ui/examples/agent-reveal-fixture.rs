//! Clicking an agent in the composer's agents card, from synthetic data and
//! no engine: a chat whose first turn spawned two agents that still run,
//! under a footer with the agents chip and the context ring. The pointer is
//! driven with synthetic events and each stage is saved as a PNG:
//! - `before-card.png`, `before-row.png`: the card with display-only rows
//!   (no reveal handler), opened and then pointed at a row;
//! - `after-hover.png`: the same card with clickable rows, one hovered;
//! - `after-revealed.png`: after the click, the transcript at the agent's
//!   chip with its ring.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example agent-reveal-fixture -- <dir> <light|dark> <width>`
//! Run each appearance/width in a fresh process; all content is synthetic.
use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gpui::{
    AppContext, AsyncApp, Bounds, Context, Entity, IntoElement, Modifiers, MouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, Pixels, PlatformInput, Point, Render, Window,
    WindowBounds, WindowOptions, canvas, div, point, prelude::*, px, size,
};
use harness_ui::{
    agent_work, appearance, context_usage, icons, settings, state::AppState, theme::Theme,
    transcript::Transcript,
};
use serde_json::{Value, json};

const HEIGHT: f32 = 820.0;
const FOOTER: f32 = 44.0;

struct Host {
    transcript: Entity<Transcript>,
    state: Entity<AppState>,
    /// Off for the "before" stage: the card's rows are display-only.
    clickable: bool,
    chip: Rc<Cell<Bounds<Pixels>>>,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let transcript = self.transcript.clone();
        let reveal = self.clickable.then(|| {
            Rc::new(move |id: &str, _: &mut Window, cx: &mut gpui::App| {
                transcript.update(cx, |t, cx| t.reveal_agent(id, cx));
            }) as agent_work::RevealAgent
        });
        let chip = agent_work::footer_chip(self.state.clone(), &theme, cx.entity_id(), reveal, cx);
        let probe = self.chip.clone();
        let usage = self.state.read(cx).context_usage;
        div()
            .size_full()
            .relative()
            .bg(theme.bg)
            .text_color(theme.text)
            .child(self.transcript.clone())
            .child(
                div()
                    .absolute()
                    .left(px(24.0))
                    .right(px(24.0))
                    .bottom(px(14.0))
                    .h(px(FOOTER))
                    .px(px(10.0))
                    .rounded(px(14.0))
                    .bg(theme.surface)
                    .border(px(1.0))
                    .border_color(theme.border)
                    .flex()
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.0))
                            .text_color(theme.text_muted)
                            .child("Ask for follow-up changes"),
                    )
                    .children(chip.map(|chip| {
                        div()
                            .relative()
                            .flex_none()
                            .h(px(24.0))
                            .pr(px(4.0))
                            .child(chip)
                            .child(
                                canvas(move |bounds, _, _| probe.set(bounds), |_, _, _, _| {})
                                    .absolute()
                                    .inset_0(),
                            )
                    }))
                    .child(context_usage::render(usage, self.state.clone(), &theme)),
            )
    }
}

fn spawn(id: &str, title: &str, tail: &str) -> Value {
    json!({"id": id, "kind": "tool", "resolved": true,
           "call": {"kind": "unknown", "name": format!("Agent: {title}")},
           "subagentStatus": "running", "subagentRef": format!("doc-{id}"),
           "subagentTail": tail})
}

fn chat() -> Value {
    let mut entries = vec![
        json!({"id": "u1", "role": "user", "createdAt": 1, "deviceId": "fixture",
               "parts": [{"id": "p", "kind": "text",
                          "text": "Compare the two text renderers and audit the token flows."}]}),
        json!({"id": "a1", "role": "assistant", "createdAt": 2, "deviceId": "fixture",
               "status": "complete", "parts": [
            {"id": "t1", "kind": "text", "text": "I'll split this in two and keep going on the fee model meanwhile."},
            spawn("s1", "Compare the two text renderers", "Measuring glyph cache hits"),
            spawn("s2", "Audit the token flows", "Tracing the refresh path"),
            {"id": "t2", "kind": "text", "text": "Both agents are running; I'll report back when they finish."},
        ]}),
    ];
    for turn in 0..3 {
        entries.push(json!({"id": format!("u{}", turn + 2), "role": "user",
            "createdAt": 3 + turn * 2, "deviceId": "fixture",
            "parts": [{"id": "p", "kind": "text", "text": "Meanwhile, walk me through the fee model."}]}));
        let body: String = (0..6)
            .map(|p| format!("Step {p} of the fee model: each validator's share follows its stake, and the protocol keeps a fixed slice for the treasury before rewards are paid out.\n\n"))
            .collect();
        entries.push(json!({"id": format!("r{turn}"), "role": "assistant",
            "createdAt": 4 + turn * 2, "deviceId": "fixture", "status": "complete",
            "parts": [{"id": "b", "kind": "text", "text": body}]}));
    }
    Value::Array(entries)
}

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

fn pointer(window: gpui::AnyWindowHandle, cx: &mut AsyncApp, input: PlatformInput) {
    let _ = window.update(cx, |_, window, cx| {
        window.dispatch_event(input, cx);
    });
}

fn move_to(window: gpui::AnyWindowHandle, cx: &mut AsyncApp, at: Point<Pixels>) {
    pointer(
        window,
        cx,
        PlatformInput::MouseMove(MouseMoveEvent {
            position: at,
            pressed_button: None,
            modifiers: Modifiers::none(),
        }),
    );
}

fn click(window: gpui::AnyWindowHandle, cx: &mut AsyncApp, at: Point<Pixels>) {
    pointer(
        window,
        cx,
        PlatformInput::MouseDown(MouseDownEvent {
            position: at,
            button: MouseButton::Left,
            modifiers: Modifiers::none(),
            click_count: 1,
            first_mouse: false,
        }),
    );
    pointer(
        window,
        cx,
        PlatformInput::MouseUp(MouseUpEvent {
            position: at,
            button: MouseButton::Left,
            modifiers: Modifiers::none(),
            click_count: 1,
        }),
    );
}

fn save(window: gpui::AnyWindowHandle, cx: &mut AsyncApp, path: PathBuf) -> anyhow::Result<()> {
    window.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.refresh();
        window.draw(cx).clear();
        window.render_to_image()?.save(path)?;
        Ok(())
    })?
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let tone = std::env::args().nth(2).unwrap_or_else(|| "light".into());
    anyhow::ensure!(
        matches!(tone.as_str(), "light" | "dark"),
        "appearance must be light or dark"
    );
    let width = std::env::args()
        .nth(3)
        .map(|v| v.parse::<f32>())
        .transpose()?
        .unwrap_or(960.0);
    anyhow::ensure!(width >= 384.0, "fixture width must be at least 384 px");
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let _runtime = runtime.enter();
    let failure = std::sync::Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let mut options = settings::UiSettings::default();
            options.theme_selection.light = "warm-harp-light".into();
            options.theme_selection.dark = "warm-harp-dark".into();
            settings::init(options.clone(), data.path(), cx);
            let fonts = harness_ui::typography::register_fonts(cx);
            harness_ui::typography::init(
                options.ui_font_family.clone(),
                options.ui_font_size,
                options.terminal_font_family.clone(),
                options.terminal_font_size,
                options.code_font_family.clone(),
                options.code_font_size,
                fonts,
                cx,
            );
            harness_ui::theme_library::init(data.path().to_path_buf(), cx);
            appearance::init(
                if tone == "light" {
                    appearance::AppearanceMode::Light
                } else {
                    appearance::AppearanceMode::Dark
                },
                options.theme_selection,
                options.accent,
                options.surface,
                cx,
            );
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.selected_chat = Some("fixture".into());
                state.context_usage = Some(harness_proto::ContextUsage {
                    tokens: Some(74_000),
                    window: Some(200_000),
                    savings: None,
                });
                state
            });
            let chip = Rc::new(Cell::new(Bounds::default()));
            let host = cx
                .open_window(
                    WindowOptions {
                        window_background: Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            point(px(20.), px(40.)),
                            size(px(width), px(HEIGHT)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| {
                        let transcript = cx.new(|cx| {
                            let mut t = Transcript::new(state.clone(), cx);
                            t.set_bottom_clearance(FOOTER + 28.0, cx);
                            t
                        });
                        cx.new(|_| Host {
                            transcript,
                            state: state.clone(),
                            clickable: false,
                            chip: chip.clone(),
                        })
                    },
                )
                .unwrap();
            let window: gpui::AnyWindowHandle = host.into();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    state.update(cx, |state, cx| {
                        state.receive_transcript_frame(
                            harness_doc::TranscriptFrame::Reset {
                                reset: serde_json::from_value(chat()).unwrap(),
                            },
                            cx,
                        )
                    })?;
                    pause(cx, 900).await;
                    let at = chip.get().center();
                    // The card opens above-left of the pointer: its bottom
                    // edge 1 px above it, its right edge 1 px left of it.
                    // The second agent's row is the card's last row.
                    let row = point(at.x - px(160.0), at.y - px(36.0));
                    for clickable in [false, true] {
                        let _ = host.update(cx, |host, _, cx| {
                            host.clickable = clickable;
                            cx.notify();
                        });
                        move_to(window, cx, point(px(width / 2.0), px(200.0)));
                        pause(cx, 700).await;
                        move_to(window, cx, at);
                        pause(cx, 800).await;
                        if !clickable {
                            save(window, cx, output.join("before-card.png"))?;
                        }
                        for step in 1..=6 {
                            let t = step as f32 / 6.0;
                            move_to(
                                window,
                                cx,
                                point(at.x + (row.x - at.x) * t, at.y + (row.y - at.y) * t),
                            );
                            pause(cx, 30).await;
                        }
                        pause(cx, 300).await;
                        let stage = if clickable {
                            "after-hover"
                        } else {
                            "before-row"
                        };
                        save(window, cx, output.join(format!("{stage}.png")))?;
                    }
                    click(window, cx, row);
                    // The glide (500 ms), then the ring at full strength.
                    pause(cx, 650).await;
                    save(window, cx, output.join("after-revealed.png"))?;
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err();
                let _ = window.update(cx, |_, window, _| window.remove_window());
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
