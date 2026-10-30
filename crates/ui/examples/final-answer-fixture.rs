//! Native transcript completion captures using synthetic data and no engine.
//! `cargo run --profile app-dev -p harness-ui --features appshots-fixture --example final-answer-fixture -- <dir> [narrow] [compact]`
use gpui::{
    AppContext, AsyncApp, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use harness_ui::{
    appearance, icons, settings, state::AppState, theme::Theme, transcript::Transcript,
};
use std::{path::PathBuf, time::Duration};

struct Host(Entity<Transcript>);
impl Render for Host {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().size_full().bg(Theme::of(cx).bg).child(self.0.clone())
    }
}

fn frame(complete: bool) -> harness_doc::TranscriptFrame {
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {
                "id": "user", "role": "user", "createdAt": 1, "deviceId": "fixture",
                "parts": [{"id": "prompt", "kind": "text", "text": "Review the parser change."}]
            },
            {
                "id": "assistant", "role": "assistant", "createdAt": 2,
                "deviceId": "fixture", "status": if complete { "complete" } else { "streaming" },
                "durationMs": if complete { Some(94_000) } else { None },
                "parts": [
                    {"id": "progress", "kind": "text", "text": "I’ll check the parser and its regression tests."},
                    {"id": "read", "kind": "tool", "resolved": true,
                     "call": {"kind": "readFile", "path": "src/parser.rs"}},
                    {"id": "check", "kind": "tool", "resolved": true,
                     "call": {"kind": "exec", "command": "cargo test parser"}},
                    {"id": "answer", "kind": "text", "text": "The parser change is ready.\n\nAll 24 tests pass, including the empty-input regression. No blocking findings."}
                ]
            }
        ]))
        .unwrap(),
    }
}

async fn pause(cx: &mut AsyncApp) {
    cx.background_executor()
        .timer(Duration::from_millis(900))
        .await;
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let args: Vec<_> = std::env::args().skip(2).collect();
    let narrow = args.iter().any(|arg| arg == "narrow");
    let compact = args.iter().any(|arg| arg == "compact");
    let suffix = format!(
        "{}{}",
        if narrow { "narrow" } else { "wide" },
        if compact { "-compact" } else { "" }
    );
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = std::sync::Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_base::init(cx);
            let mut options = settings::UiSettings::default();
            options.transcript_compact_mode = compact;
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
                appearance::AppearanceMode::Dark,
                options.theme_selection,
                options.accent,
                options.surface,
                cx,
            );
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.selected_chat = Some("fixture".into());
                state
            });
            let window: gpui::AnyWindowHandle = cx
                .open_window(
                    WindowOptions {
                        window_background: Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.), px(40.)),
                            size(px(if narrow { 360. } else { 900. }), px(680.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx)))),
                )
                .unwrap()
                .into();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    for complete in [false, true] {
                        state.update(cx, |state, cx| {
                            state.receive_transcript_frame(frame(complete), cx)
                        })?;
                        pause(cx).await;
                        let stage = if complete { "complete" } else { "working" };
                        window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            window
                                .render_to_image()?
                                .save(output.join(format!("{stage}-{suffix}.png")))?;
                            Ok(())
                        })??;
                    }
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
