//! Offscreen, synthetic reproduction of question and queue entrance flicker.
//! cargo run -p harness-ui --features resource-profile --example composer-cache-flicker -- OUT
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Styled, Window, WindowBounds,
    WindowOptions, div, px, size,
};
use harness_ui::*;
use std::{cell::RefCell, path::PathBuf, rc::Rc, time::Duration};

struct Pane {
    composer: Entity<composer::Composer>,
    cached: bool,
}

impl Render for Pane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        use gpui::ParentElement;
        let content = if self.cached {
            self.composer
                .clone()
                .cached_measured(gpui::StyleRefinement::default().w(px(760.)))
                .into_any_element()
        } else {
            self.composer.clone().into_any_element()
        };
        div()
            .size_full()
            .bg(theme::Theme::of(cx).bg)
            .p(px(20.))
            .child(content)
    }
}

#[cfg(not(target_os = "macos"))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("This fixture requires macOS")
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let native = gpui_platform::current_platform(true);
    let platform = gpui::bench_platform(
        Some(Box::new(gpui_platform::current_headless_renderer)),
        native.text_system(),
    );
    let executor = platform.background_executor();
    let handles = Rc::new(RefCell::new(Vec::new()));
    let captured = handles.clone();
    let app = gpui::Application::with_platform(platform)
        .with_assets(icons::Assets)
        .run_embedded(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.path(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                settings.ui_font_family.clone(), settings.ui_font_size,
                settings.terminal_font_family.clone(), settings.terminal_font_size,
                settings.code_font_family.clone(), settings.code_font_size, fonts, cx,
            );
            cx.set_global(theme::Theme::light());
            motion::set_reduced_motion(cx, false);
            history::init(Default::default(), Default::default(), Default::default(), Default::default(), cx);
            composer::init(cx, settings.composer_send_behavior);
            for question in [true, false] {
                for cached in [false, true] {
                    let state = cx.new(|_| {
                        let mut state = state::AppState::new();
                        state.selected_chat = Some("synthetic-chat".into());
                        state.no_project = true;
                        state.queue = if question { vec![] } else {
                            vec![harness_doc::QueuedMessage::new("synthetic-row", "Review the synthetic parser changes", "synthetic-host")]
                        };
                        if question {
                            state.transcript = serde_json::from_value(serde_json::json!([{
                                "id": "synthetic-assistant", "role": "assistant", "createdAt": 0,
                                "deviceId": "synthetic-host", "status": "streaming", "parts": [{
                                    "id": "synthetic-input", "kind": "input", "requestId": "synthetic-request",
                                    "resolved": false, "questions": [{
                                        "id": "choice", "header": "Agent question",
                                        "question": "Which synthetic example should we review?",
                                        "options": ["Parser changes", "Formatting changes"], "multiSelect": false
                                    }]
                                }]
                            }])).unwrap();
                        }
                        state
                    });
                    let window = cx.open_window(
                        WindowOptions {
                            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                                gpui::point(px(0.), px(0.)), size(px(800.), px(460.)),
                            ))),
                            ..Default::default()
                        },
                        |_, cx| cx.new(|cx| {
                            let composer = cx.new(|cx| composer::Composer::new(state.clone(), cx));
                            composer.update(cx, |composer, cx| {
                                composer.set_available_width(760., cx);
                                composer.set_available_height(460., cx);
                            });
                            state.update(cx, |_, cx| cx.notify());
                            Pane { composer, cached }
                        }),
                    ).unwrap();
                    captured.borrow_mut().push((question, cached, window));
                }
            }
        });
    let windows = handles.borrow_mut().drain(..).collect::<Vec<_>>();
    let dispatcher = executor.dispatcher().as_bench().unwrap();
    for frame in 0..60 {
        std::thread::sleep(Duration::from_millis(16));
        app.update(|cx| {
            for (_, _, window) in &windows {
                window
                    .update(cx, |pane, window, cx| {
                        if frame % 10 == 0 {
                            pane.composer.update(cx, |_, cx| cx.notify());
                        }
                        cx.notify();
                        window.simulate_next_frame(cx);
                    })
                    .unwrap();
            }
        });
        dispatcher.run_until_idle();
        app.update(|cx| {
            for (_, _, window) in &windows {
                window
                    .update(cx, |_, window, _| window.present_if_needed())
                    .unwrap();
            }
        });
    }
    app.update(|cx| {
        for (question, cached, window) in windows {
            let kind = if question { "question" } else { "queue" };
            let mode = if cached { "cached" } else { "uncached" };
            cx.update_window(window.into(), |_, window, _| {
                window
                    .render_to_image()
                    .unwrap()
                    .save(output.join(format!("{kind}-{mode}.png")))
                    .unwrap();
            })
            .unwrap();
        }
    });
    Ok(())
}
