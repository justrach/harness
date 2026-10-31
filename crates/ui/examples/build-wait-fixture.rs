//! Isolated production transcript captures; synthetic data, no engine/network.
//! scripts/heavy-build.sh cargo run --profile app-dev -p harness-ui --features appshots-fixture --example build-wait-fixture -- OUT_DIR [narrow] [split] [reduced]
//! `waiting-00..37` span two 1.9s pulses for a GIF; before/after are stills.
use gpui::{
    AppContext, AsyncApp, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use harness_ui::{
    appearance, icons, settings, state::AppState, theme::Theme, transcript::Transcript,
};
use std::{path::PathBuf, time::Duration};

struct Host(Vec<Entity<Transcript>>);
impl Render for Host {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .bg(Theme::of(cx).bg)
            .flex()
            .flex_row()
            .children(
                self.0
                    .iter()
                    .map(|pane| div().flex_1().min_w_0().h_full().child(pane.clone())),
            )
    }
}
fn entries() -> Vec<harness_doc::SessionMessageEntry> {
    serde_json::from_value(serde_json::json!([
        {"id": "prompt", "role": "user", "createdAt": 1, "deviceId": "synthetic", "parts": [{"id": "question", "kind": "text", "text": "Check the sample parser."}]},
        {"id": "reply", "role": "assistant", "createdAt": 2, "deviceId": "synthetic", "status": "streaming", "parts": [
            {"id": "intro", "kind": "text", "text": "I’ll check the parser and its tests."},
            {"id": "read", "kind": "tool", "resolved": true, "call": {"kind": "readFile", "path": "src/parser.rs"}},
            {"id": "check", "kind": "tool", "resolved": false, "call": {"kind": "exec", "command": "check sample"}}
        ]}
    ])).unwrap()
}
async fn pause(cx: &mut AsyncApp, millis: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(millis))
        .await;
}
fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    output: &std::path::Path,
    name: &str,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        window
            .render_to_image()?
            .save(output.join(format!("{name}.png")))?;
        Ok(())
    })?
}
fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let args: Vec<_> = std::env::args().skip(2).collect();
    let narrow = args.iter().any(|s| s == "narrow");
    let split = args.iter().any(|s| s == "split");
    let reduced = args.iter().any(|s| s == "reduced");
    let light = args.iter().any(|s| s == "light");
    let suffix = format!(
        "{}{}{}{}",
        if narrow { "narrow" } else { "wide" },
        if split { "-split" } else { "" },
        if reduced { "-reduced" } else { "" },
        if light { "-light" } else { "" }
    );
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = std::sync::Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_base::init(cx);
        let options = settings::UiSettings::default();
        settings::init(options.clone(), data.path(), cx);
        let fonts = harness_ui::typography::register_fonts(cx);
        harness_ui::typography::init(options.ui_font_family.clone(), options.ui_font_size, options.terminal_font_family.clone(), options.terminal_font_size, options.code_font_family.clone(), options.code_font_size, fonts, cx);
        harness_ui::theme_library::init(data.path().to_path_buf(), cx);
        appearance::init(if light { appearance::AppearanceMode::Light } else { appearance::AppearanceMode::Dark }, options.theme_selection, options.accent, options.surface, cx);
        harness_ui::motion::set_reduced_motion(cx, reduced);
        let now = chrono::Utc::now();
        let state = cx.new(|cx| {
            let mut state = AppState::new();
            state.selected_chat = Some("sample".into());
            state.receive_transcript_frame(harness_doc::TranscriptFrame::Reset { reset: entries() }, cx);
            if split {
                state.set_subagent_snapshot("peer".into(), entries());
                state.watch_peer_chat("peer".into(), cx);
            }
            for id in ["sample", "peer"] {
                state.sessions.push(harness_proto::Session {
                    chat_id: id.into(), device_id: "synthetic".into(),
                    status: harness_proto::SessionStatus::Working,
                    started_at: Some(now - chrono::Duration::minutes(5)), updated_at: now,
                    last_completed_turn: None, last_completed_peer_only: false,
                });
            }
            // Chat identity distinguishes a live split chat from a subagent doc.
            if split {
                state.chats = serde_json::from_value(serde_json::json!([{
                    "id": "peer", "title": "Sample review", "deviceId": "synthetic", "archived": false, "createdAt": now, "spaceId": null
                }])).unwrap();
            }
            state
        });
        let window: gpui::AnyWindowHandle = cx.open_window(WindowOptions {
            window_background: Theme::of(cx).window_background_appearance(),
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(gpui::point(px(20.), px(40.)), size(px(if narrow { 360. } else if split { 1100. } else { 900. }), px(680.))))),
            ..Default::default()
        }, |_, cx| cx.new(|cx| {
            let mut panes = vec![cx.new(|cx| Transcript::new(state.clone(), cx))];
            if split { panes.push(cx.new(|cx| Transcript::for_doc(state.clone(), "peer".into(), true, cx))); }
            Host(panes)
        })).unwrap().into();
        cx.activate(true);
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                pause(cx, 900).await;
                capture(window, cx, &output, &format!("before-{suffix}"))?;
                state.update(cx, |state, cx| state.fixture_tool_progress("sample", vec![harness_proto::build_wait_item(now.timestamp() - 240)], cx));
                pause(cx, 200).await;
                for frame in 0..38 {
                    capture(window, cx, &output, &format!("waiting-{frame:02}-{suffix}"))?;
                    if frame == 9 { capture(window, cx, &output, &format!("after-{suffix}"))?; }
                    pause(cx, 100).await;
                }
                state.update(cx, |state, cx| {
                    state.fixture_tool_progress("sample", vec![], cx);
                    if split { state.fixture_tool_progress("peer", vec![harness_proto::build_wait_item(now.timestamp() - 240)], cx); }
                });
                pause(cx, 300).await;
                capture(window, cx, &output, &format!("resumed-{suffix}"))?;
                Ok(())
            }.await;
            *result.lock().unwrap() = run.err();
            let _ = window.update(cx, |_, window, _| window.remove_window());
            let _ = cx.update(|cx| cx.quit());
        }).detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
