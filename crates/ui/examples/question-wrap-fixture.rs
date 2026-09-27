//! Capture the production question composer with synthetic content at several widths.
//! cargo run -p harness-ui --example question-wrap-fixture --features appshots-fixture -- OUT_DIR
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::{Arc, Mutex}, time::Duration};

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_base::init(cx);
        let settings = settings::UiSettings::default();
        settings::init(settings.clone(), data.path(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(
            settings.ui_font_family.clone(), settings.ui_font_size,
            settings.terminal_font_family.clone(), settings.terminal_font_size,
            settings.code_font_family.clone(), settings.code_font_size, fonts, cx,
        );
        cx.set_global(theme::Theme::dark());
        history::init(Default::default(), Default::default(), Default::default(), Default::default(), cx);
        app_menus::init(cx);
        composer::init(cx, settings.composer_send_behavior);
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.selected_chat = Some("question-preview".into());
            state.no_project = true;
            state
        });
        let window = cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(30.), px(40.)), size(px(768.), px(900.)),
                ))),
                ..Default::default()
            },
            |_, cx| cx.new(|cx| composer::Composer::new(state.clone(), cx)),
        ).unwrap();
        state.update(cx, |state, cx| {
            state.receive_transcript_frame(
                harness_doc::TranscriptFrame::Reset {
                    reset: serde_json::from_value(serde_json::json!([{
                        "id": "preview-assistant",
                        "role": "assistant",
                        "parts": [{
                            "id": "preview-input",
                            "kind": "input",
                            "requestId": "preview-question",
                            "questions": [
                                {
                                    "id": "approach", "header": "Agent question",
                                    "question": "Which approach should we use to keep the agent question readable when the session pane becomes narrow?",
                                    "options": ["Wrap the question and its options to fit the session pane.", "Keep the existing behavior and review another approach."],
                                    "multiSelect": false
                                },
                                {
                                    "id": "confirm", "header": "Confirmation",
                                    "question": "Would you like to continue?",
                                    "options": ["Yes", "No"], "multiSelect": false
                                }
                            ],
                            "resolved": false
                        }],
                        "createdAt": 0, "deviceId": "preview", "status": "streaming"
                    }])).unwrap(),
                }, cx,
            ).unwrap();
            cx.notify();
        });
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                for (width, height) in [(768, 900), (320, 900), (320, 300), (220, 600), (160, 600), (128, 600), (100, 600), (80, 600), (64, 600)] {
                    // A tiny split pane still lives in a desktop-sized window.
                    let window_width = if width < 300 { 1000 } else { width };
                    window.update(cx, |composer, window, cx| {
                        window.resize(size(px(window_width as f32), px(height as f32)));
                        composer.set_available_width(width as f32, cx);
                        composer.set_available_height(height as f32, cx);
                        cx.notify();
                    })?;
                    cx.background_executor().timer(Duration::from_millis(500)).await;
                    let capture_window: gpui::AnyWindowHandle = window.into();
                    capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                        window.draw(cx).clear();
                        window.render_to_image()?.save(output.join(format!("question-{width}-{height}.png")))?;
                        Ok(())
                    })??;
                    if width < 300 {
                        capture_window.update(cx, |_, window, cx| {
                            let position = gpui::point(px(width as f32 / 2.0), px(14.0));
                            window.dispatch_event(gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                button: gpui::MouseButton::Left, position, click_count: 1,
                                ..Default::default()
                            }), cx);
                            window.dispatch_event(gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                button: gpui::MouseButton::Left, position, click_count: 1,
                                ..Default::default()
                            }), cx);
                        })?;
                        cx.background_executor().timer(Duration::from_millis(300)).await;
                        capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            window.render_to_image()?.save(output.join(format!("question-{width}-expanded.png")))?;
                            // Escape closes without discarding the pending answer.
                            window.dispatch_event(gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                                keystroke: gpui::Keystroke::parse("escape")?,
                                is_held: false,
                                prefer_character_input: false,
                            }), cx);
                            Ok(())
                        })??;
                    }
                }
                Ok(())
            }.await;
            if let Err(error) = run {
                *result.lock().unwrap() = Some(format!("{error:#}"));
            }
            let _ = window.update(cx, |_, window, _| window.remove_window());
            cx.update(|cx| cx.quit());
        }).detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
