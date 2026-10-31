//! Native selection repro using only synthetic messages, no engine or user data.
//! cargo run --profile app-dev -p harness-ui --features appshots-fixture \
//!   --example transcript-selection-fixture -- OUTPUT_DIR before|after
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, MouseButton, MouseDownEvent, MouseMoveEvent,
    MouseUpEvent, PlatformInput, Render, Window, WindowBounds, WindowOptions, div, prelude::*, px,
    size,
};
use harness_ui::{
    markdown, settings, state::AppState, theme::Theme, transcript::Transcript, typography,
};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

const REPLY: &str = "Selecting output must not select the prompt, even when the collapsed prompt has many hidden lines.";

struct Fixture(Entity<Transcript>);
impl Render for Fixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let selected = markdown::selection::selected_text().unwrap_or_else(|| "(none)".into());
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.text)
            .font_family(theme.font_sans.clone())
            .child(
                div()
                    .p(px(16.0))
                    .child("Double-click the reply word “collapsed”"),
            )
            .child(div().flex_1().min_h_0().child(self.0.clone()))
            .child(
                div()
                    .p(px(16.0))
                    .child(format!("Selected text: {selected}")),
            )
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let phase = std::env::args().nth(2).expect("before or after");
    anyhow::ensure!(phase == "before" || phase == "after");
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application().with_assets(harness_ui::icons::Assets).run(move |cx| {
        gpui_base::init(cx);
        let config = settings::UiSettings::default();
        settings::init(config.clone(), data.path(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(
            config.ui_font_family, config.ui_font_size,
            config.terminal_font_family, config.terminal_font_size,
            config.code_font_family, config.code_font_size, fonts, cx,
        );
        cx.set_global(Theme::light());
        let state = cx.new(|cx| {
            let mut state = AppState::new();
            state.selected_chat = Some("selection-fixture".into());
            state.transcript_replayed = true;
            let reset = serde_json::from_value(serde_json::json!([
                {
                    "id": "prompt", "role": "user", "createdAt": 0, "deviceId": "fixture",
                    "parts": [{"id": "text", "kind": "text", "text":
                        "Hidden prompt words with enough width to overlap the assistant reply below.\n".repeat(40)}]
                },
                {
                    "id": "reply", "role": "assistant", "createdAt": 0, "deviceId": "fixture",
                    "status": "complete", "parts": [{"id": "text", "kind": "text", "text": REPLY}]
                }
            ])).unwrap();
            state.receive_transcript_frame(harness_doc::TranscriptFrame::Reset { reset }, cx).unwrap();
            state
        });
        let window = cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(20.0), px(40.0)), size(px(900.0), px(620.0)),
                ))),
                ..Default::default()
            },
            |_, cx| cx.new(|cx| Fixture(cx.new(|cx| Transcript::new(state, cx)))),
        ).unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            let surface: gpui::AnyWindowHandle = window.into();
            let run: anyhow::Result<()> = async {
                for width in [900, 360] {
                    surface.update(cx, |_, window, _| {
                        window.resize(size(px(width as f32), px(620.0)));
                        window.refresh();
                    })?;
                    cx.background_executor().timer(Duration::from_millis(600)).await;
                    surface.update(cx, |_, window, cx| {
                        window.refresh();
                        window.draw(cx).clear();
                    })?;
                    let position = markdown::render::fixture_selection_position(REPLY, REPLY.find("collapsed").unwrap() + 3)
                        .ok_or_else(|| anyhow::anyhow!("synthetic reply was not painted"))?;
                    surface.update(cx, |_, window, cx| {
                        window.dispatch_event(PlatformInput::MouseDown(MouseDownEvent {
                            button: MouseButton::Left, position, click_count: 2, ..Default::default()
                        }), cx);
                        window.dispatch_event(PlatformInput::MouseMove(MouseMoveEvent {
                            position, pressed_button: Some(MouseButton::Left), ..Default::default()
                        }), cx);
                        window.dispatch_event(PlatformInput::MouseUp(MouseUpEvent {
                            button: MouseButton::Left, position, ..Default::default()
                        }), cx);
                        window.refresh();
                    })?;
                    cx.background_executor().timer(Duration::from_millis(100)).await;
                    let selected = markdown::selection::selected_text().unwrap_or_default();
                    if phase == "after" {
                        anyhow::ensure!(selected == "collapsed", "reply selection was {selected:?}");
                    } else {
                        anyhow::ensure!(selected != "collapsed", "baseline did not reproduce");
                    }
                    surface.update(cx, |_, window, cx| -> anyhow::Result<()> {
                        window.refresh();
                        window.draw(cx).clear();
                        window.render_to_image()?.save(output.join(format!("selection-{phase}-{width}.png")))?;
                        Ok(())
                    })??;
                }
                Ok(())
            }.await;
            *result.lock().unwrap() = run.err();
            let _ = surface.update(cx, |_, window, _| window.remove_window());
            cx.update(|cx| cx.quit());
        }).detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
