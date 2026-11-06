//! An open tool group in the real transcript, from synthetic data with no engine.
//! `cargo run --profile app-dev -p harness-ui --features appshots-fixture --example tool-group-fixture -- <dir> [dark] [narrow] [done]`
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, size,
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

fn frame(done: bool) -> harness_doc::TranscriptFrame {
    let exec = |id: &str, command: &str, output: Option<&str>, is_error: bool| {
        let mut part = serde_json::json!({
            "id": id, "kind": "tool", "resolved": true, "isError": is_error,
            "call": {"kind": "exec", "command": command}
        });
        if let Some(output) = output {
            part["output"] = output.into();
        }
        part
    };
    let stats = |path: &str, additions: u64, deletions: u64| serde_json::json!([{"path": path, "additions": additions, "deletions": deletions}]);
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {
                "id": "user", "role": "user", "createdAt": 1, "deviceId": "fixture",
                "parts": [{"id": "prompt", "kind": "text", "text": "Fix the parser timeout."}]
            },
            {
                "id": "assistant", "role": "assistant", "createdAt": 2,
                "deviceId": "fixture", "status": if done { "complete" } else { "streaming" },
                "parts": [
                    {"id": "intro", "kind": "text", "text": "I'll fix the timeout and rerun the suite."},
                    {"id": "edit-a", "kind": "tool", "resolved": true,
                     "call": {"kind": "editFile", "path": "src/parser.zig"},
                     "diffStats": stats("src/parser.zig", 10, 4)},
                    {"id": "edit-b", "kind": "tool", "resolved": true,
                     "call": {"kind": "editFile", "path": "tools/run_suite.py"},
                     "diffStats": stats("tools/run_suite.py", 3, 1)},
                    {"id": "read", "kind": "tool", "resolved": true,
                     "call": {"kind": "readFile", "path": "src/lexer.zig"}},
                    exec("poll", "shell", None, false),
                    exec("build", "zig build -Doptimize=ReleaseFast", Some("Build finished"), false),
                    exec("denied", "shell", None, true),
                    exec("fail", "export GRAFF_NO_CODEDB_GUARD=1; cd tools/parity; zig build test --summary all --verbose --seed 12345 --test-filter parser --test-timeout-ms 90000", Some("2 failed, 46 passed"), true),
                    exec("pass", "zig build test", Some("48 passed, 0 failed"), false),
                    {"id": "search", "kind": "tool", "resolved": true,
                     "call": {"kind": "search", "pattern": "readTimeout", "path": "src"},
                     "output": "src/parser.zig:12\nsrc/lexer.zig:80\nsrc/io.zig:4"},
                    {"id": "live", "kind": "tool", "resolved": done,
                     "call": {"kind": "exec", "command": "zig build bench -- --filter parser"}},
                ]
            }
        ]))
        .unwrap(),
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let args: Vec<_> = std::env::args().skip(2).collect();
    let dark = args.iter().any(|arg| arg == "dark");
    let narrow = args.iter().any(|arg| arg == "narrow");
    let done = args.iter().any(|arg| arg == "done");
    let name = format!(
        "tool-group-{}{}{}.png",
        if dark { "dark" } else { "light" },
        if narrow { "-narrow" } else { "" },
        if done { "-done" } else { "" }
    );
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = std::sync::Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_base::init(cx);
            let options = settings::UiSettings::default();
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
                if dark {
                    appearance::AppearanceMode::Dark
                } else {
                    appearance::AppearanceMode::Light
                },
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
            let transcript = cx.new(|cx| Transcript::new(state.clone(), cx));
            let view = transcript.clone();
            let window: gpui::AnyWindowHandle = cx
                .open_window(
                    WindowOptions {
                        window_background: Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.), px(40.)),
                            size(px(if narrow { 420. } else { 900. }), px(640.)),
                        ))),
                        show: false,
                        focus: false,
                        ..Default::default()
                    },
                    |_, cx| cx.new(|_| Host(view)),
                )
                .unwrap()
                .into();
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    state.update(cx, |state, cx| {
                        state.receive_transcript_frame(frame(done), cx)
                    })?;
                    cx.background_executor()
                        .timer(Duration::from_millis(500))
                        .await;
                    transcript.update(cx, |transcript, cx| transcript.fixture_open_tool_groups(cx));
                    cx.background_executor()
                        .timer(Duration::from_millis(900))
                        .await;
                    window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                        window.refresh();
                        window.draw(cx).clear();
                        window.render_to_image()?.save(output.join(&name))?;
                        Ok(())
                    })??;
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
