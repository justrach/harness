//! Capture image annotation step by step: the staged image's preview with
//! its Annotate button, annotate mode, a box with its note, several boxes and
//! colors, the text tool, and the annotated copy staged in the composer.
//! Synthetic data only: no engine, temporary settings.
//!
//! `HARNESS_FIXTURE_APPEARANCE=light|dark` picks the appearance.
//! cargo run -p harness-ui --example annotate-fixture --features appshots-fixture -- IMAGE OUT_DIR
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, size,
};
use harness_ui::*;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

/// The composer at the bottom of a window-sized app background.
struct Frame {
    composer: Entity<composer::Composer>,
}

impl Render for Frame {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .bg(theme::Theme::of(cx).bg)
            .flex()
            .flex_col()
            .justify_end()
            .p(px(16.0))
            .child(self.composer.clone())
    }
}

fn main() -> anyhow::Result<()> {
    let image = PathBuf::from(std::env::args().nth(1).expect("image to annotate"));
    let output = PathBuf::from(std::env::args().nth(2).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let dark = std::env::var("HARNESS_FIXTURE_APPEARANCE").as_deref() == Ok("dark");
    let suffix = if dark { "dark" } else { "light" };
    let mode = if dark {
        appearance::AppearanceMode::Dark
    } else {
        appearance::AppearanceMode::Light
    };
    // The composer's dev knob stages the image and opens its preview.
    // SAFETY: set before any thread reads the environment.
    unsafe {
        std::env::set_var("HARNESS_ATTACH", &image);
        std::env::set_var("HARNESS_ATTACH_PREVIEW", "1");
    }
    let data = tempfile::tempdir()?;
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.path(), cx);
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
            theme_library::init(data.path().to_path_buf(), cx);
            appearance::init(
                mode,
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
            app_menus::init(cx);
            composer::init(cx, settings.composer_send_behavior);
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.no_project = true;
                state
            });
            let (width, height) = (1280.0, 820.0);
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(0.), px(0.)),
                            size(px(width), px(height)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| {
                        let composer = cx.new(|cx| composer::Composer::new(state.clone(), cx));
                        cx.new(|_| Frame { composer })
                    },
                )
                .unwrap();
            let composer = window
                .update(cx, |frame, _, _| frame.composer.clone())
                .unwrap();
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    let settle = Duration::from_millis(700);
                    let capture_window: gpui::AnyWindowHandle = window.into();
                    let capture = |name: &str, cx: &mut gpui::AsyncApp| -> anyhow::Result<()> {
                        let path = output.join(format!("{name}-{suffix}.png"));
                        let rendered = capture_window.update(cx, |_, window, cx| {
                            window.draw(cx).clear();
                            window.render_to_image().map(|image| image.save(&path))
                        })?;
                        if !matches!(rendered, Ok(Ok(()))) {
                            // No offscreen readback on this platform (X11):
                            // `HARNESS_FIXTURE_GRAB` names a script that grabs
                            // this process's window to the given path.
                            let grab = std::env::var("HARNESS_FIXTURE_GRAB").map_err(|_| {
                                anyhow::anyhow!("no readback; set HARNESS_FIXTURE_GRAB")
                            })?;
                            let status = std::process::Command::new(grab)
                                .arg(&path)
                                .arg(std::process::id().to_string())
                                .status()?;
                            anyhow::ensure!(status.success(), "ffmpeg could not grab {name}");
                        }
                        println!("{}", path.display());
                        Ok(())
                    };
                    composer.update(cx, |composer, cx| {
                        composer.set_available_width(width - 32.0, cx);
                        composer.set_available_height(height, cx);
                        composer.fixture_set_draft("Polish the billing page", cx);
                    });
                    cx.background_executor().timer(settle).await;
                    capture("01-preview-annotate-button", cx)?;

                    capture_window.update(cx, |_, window, cx| {
                        composer.update(cx, |composer, cx| {
                            composer.fixture_open_annotate(window, cx)
                        })
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("02-annotate-mode", cx)?;

                    let editor = composer
                        .read_with(cx, |composer, _| composer.fixture_annotate_editor())
                        .ok_or_else(|| anyhow::anyhow!("annotate mode did not open"))?;
                    // Box 1 around the "Change plan" button, with its note
                    // still open.
                    capture_window.update(cx, |_, window, cx| {
                        editor.update(cx, |e, cx| {
                            e.drag_rect((968.0, 204.0), (1144.0, 264.0), window, cx);
                            e.type_note("Make this the primary button", cx);
                        })
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("03-box-with-note", cx)?;

                    // Box 2 (blue) around the usage meter, box 3 (green)
                    // around Save, which keeps its note open.
                    capture_window.update(cx, |_, window, cx| {
                        editor.update(cx, |e, cx| {
                            e.commit_note(window, cx);
                            e.pick_color(annotate::MarkColor::Blue, cx);
                            e.drag_rect((304.0, 280.0), (712.0, 340.0), window, cx);
                            e.type_note("Show the percentage next to the bar", cx);
                            e.commit_note(window, cx);
                            e.pick_color(annotate::MarkColor::Green, cx);
                            e.drag_rect((988.0, 660.0), (1172.0, 724.0), window, cx);
                            e.type_note("Disabled state is too faint", cx);
                        })
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("04-several-boxes", cx)?;

                    // The text tool: a yellow label by the invoices header.
                    capture_window.update(cx, |_, window, cx| {
                        editor.update(cx, |e, cx| {
                            e.commit_note(window, cx);
                            e.set_tool(annotate::Tool::Text, cx);
                            e.pick_color(annotate::MarkColor::Yellow, cx);
                            e.place_text((440.0, 410.0), window, cx);
                            e.type_note("Add a download link here", cx);
                        })
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("05-text-tool-typing", cx)?;
                    capture_window.update(cx, |_, window, cx| {
                        editor.update(cx, |e, cx| e.commit_note(window, cx))
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("06-text-placed", cx)?;

                    // Through the window, not the composer: Done stages
                    // into the composer, which must not be mid-update.
                    capture_window.update(cx, |_, window, cx| {
                        editor.update(cx, |e, cx| e.press_done(window, cx))
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("07-staged-in-composer", cx)?;
                    let staged = composer.read_with(cx, |composer, _| composer.fixture_staged());
                    for (name, bytes, notes) in &staged {
                        println!("staged {name} ({} bytes)", bytes.len());
                        if let Some(notes) = notes {
                            std::fs::write(
                                output.join(format!("prompt-notes-{suffix}.txt")),
                                notes,
                            )?;
                            std::fs::write(output.join(format!("flattened-{suffix}.png")), bytes)?;
                            println!("{notes}");
                        }
                    }
                    composer.update(cx, |composer, cx| composer.fixture_preview_first_staged(cx));
                    cx.background_executor().timer(settle).await;
                    capture("08-annotated-preview", cx)?;
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    *result.lock().unwrap() = Some(format!("{error:#}"));
                }
                let _ = window.update(cx, |_, window, _| window.remove_window());
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
