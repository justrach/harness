//! Offline model picker fixture. The temporary state has no engine or accounts.
//! cargo run -p harness-ui --example model-picker-fixture --features model-picker-preview,appshots-fixture
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled, Window,
    WindowBounds, WindowOptions, div, px, size,
};
use harness_ui::*;
use std::time::Duration;

struct Fixture {
    picker: Entity<pickers::Pickers>,
}
impl Render for Fixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = theme::Theme::of(cx);
        div()
            .size_full()
            .bg(t.bg)
            .text_color(t.text)
            .font_family("Geist")
            .p(px(32.0))
            .flex()
            .flex_col()
            .justify_end()
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(t.text_muted)
                    .mb(px(12.0))
                    .child("Synthetic workspace · No agent calls"),
            )
            .child(self.picker.clone())
    }
}
fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let has = |arg: &str| args.iter().any(|a| a == arg);
    let legacy = has("--legacy");
    let dark = has("--dark");
    let large = has("--large");
    let narrow = has("--narrow");
    let selected = args
        .iter()
        .find_map(|a| a.strip_prefix("--model=").map(str::to_owned));
    let hovered = args
        .iter()
        .find_map(|a| a.strip_prefix("--hover=").map(str::to_owned));
    let recording = args
        .iter()
        .find_map(|a| a.strip_prefix("--record=").map(std::path::PathBuf::from));
    let output = args
        .iter()
        .find_map(|a| a.strip_prefix("--output=").map(std::path::PathBuf::from));
    let runtime = tokio::runtime::Runtime::new()?;
    let _guard = runtime.enter();
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
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
            theme_library::init(data, cx);
            appearance::init(
                if dark {
                    appearance::AppearanceMode::Dark
                } else {
                    appearance::AppearanceMode::Light
                },
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            composer::init(cx, settings.composer_send_behavior);
            let state = cx.new(|_| state::AppState::new());
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(80.0), px(70.0)),
                            size(px(if narrow { 540.0 } else { 860.0 }), px(680.0)),
                        ))),
                        titlebar: Some(gpui::TitlebarOptions {
                            title: Some("Model picker preview — synthetic data".into()),
                            ..Default::default()
                        }),
                        ..Default::default()
                    },
                    |_, cx| {
                        cx.new(|cx| {
                            let picker = cx.new(|cx| {
                                pickers::Pickers::model_picker_fixture(state, legacy, large, cx)
                            });
                            if let Some(id) = selected {
                                picker
                                    .update(cx, |picker, cx| picker.fixture_preview_model(&id, cx));
                            }
                            Fixture { picker }
                        })
                    },
                )
                .unwrap();
            cx.activate(true);
            let picker = window.read_with(cx, |f, _| f.picker.clone()).unwrap();
            if output.is_some() || recording.is_some() || hovered.is_some() {
                cx.spawn(async move |cx| {
                    cx.background_executor()
                        .timer(Duration::from_millis(500))
                        .await;
                    let handle: gpui::AnyWindowHandle = window.into();
                    let exit_after_capture = output.is_some() || recording.is_some();
                    if let Some(id) = hovered.as_ref() {
                        handle
                            .update(cx, |_, window, cx| {
                                let position = picker
                                    .read(cx)
                                    .fixture_model_position(&id, cx)
                                    .expect("visible fixture model");
                                window.dispatch_event(
                                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                        position,
                                        ..Default::default()
                                    }),
                                    cx,
                                );
                            })
                            .unwrap();
                    } else {
                        handle
                            .update(cx, |_, window, cx| {
                                window.dispatch_event(
                                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                        position: gpui::point(px(0.0), px(0.0)),
                                        ..Default::default()
                                    }),
                                    cx,
                                );
                            })
                            .unwrap();
                    }
                    cx.background_executor()
                        .timer(Duration::from_millis(500))
                        .await;
                    if let Some(directory) = recording {
                        std::fs::create_dir_all(&directory).unwrap();
                        for frame in 0..60 {
                            handle
                                .update(cx, |_, window, cx| {
                                    let percent = match frame {
                                        10 => None,
                                        11..=35 => Some(0.85 - (frame - 11) as f32 / 24.0 * 0.43),
                                        _ => Some(0.42),
                                    };
                                    let position = picker
                                        .read(cx)
                                        .fixture_slider_position(percent, cx)
                                        .expect("reasoning slider");
                                    if frame == 10 {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                                position,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                    } else if (11..=35).contains(&frame) {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position,
                                                pressed_button: Some(gpui::MouseButton::Left),
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                    } else if frame == 36 {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                position,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                    }
                                    window.draw(cx).clear();
                                    window
                                        .render_to_image()
                                        .unwrap()
                                        .save(directory.join(format!("{frame:03}.png")))
                                        .unwrap();
                                })
                                .unwrap();
                            cx.background_executor()
                                .timer(Duration::from_millis(25))
                                .await;
                        }
                    }
                    if let Some(output) = output {
                        if let Some(id) = &hovered {
                            cx.update(|cx| {
                                picker.update(cx, |p, cx| p.fixture_show_model_details(id, cx))
                            });
                            cx.background_executor()
                                .timer(Duration::from_millis(200))
                                .await;
                        }
                        handle
                            .update(cx, |_, window, cx| {
                                window.draw(cx).clear();
                                window.render_to_image().unwrap().save(&output).unwrap();
                                println!("Saved {}", output.display());
                            })
                            .unwrap();
                    }
                    if exit_after_capture {
                        cx.update(|cx| cx.quit());
                    }
                })
                .detach();
            }
        });
    Ok(())
}
