//! Native, synthetic single-image annotation review over a visible conversation.
//! Run: annotation-review-fixture <output-directory>. No engine or model calls.
//! Captures four stages at two Mac window sizes in both Warm Harp themes.

#[cfg(target_os = "macos")]
mod native {
    use gpui::{
        AnyWindowHandle, AppContext, AsyncApp, Bounds, Context, Entity, IntoElement, Render,
        Window, WindowBounds, WindowOptions, div, point, prelude::*, px, size,
    };
    use harness_ui::{
        annotate, app_menus, appearance, composer, history, icons, settings, state, theme,
        theme_library, typography,
    };
    use std::{
        path::{Path, PathBuf},
        sync::{Arc, Mutex},
        time::Duration,
    };

    const DRAFT: &str = "Keep the existing layout. I am adding a note to the attached screen.";
    const NOTE: &str = "Make this action easier to find";

    /// Deliberately busy synthetic chat behind the real composer and overlays.
    /// These messages are mock content; preview and annotation are production UI.
    struct Frame {
        composer: Entity<composer::Composer>,
    }

    impl Render for Frame {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let t = theme::Theme::of(cx);
            let response = [
                "The first screen introduces the workspace. The next section explains how the project is organized and where to continue.",
                "Keep the main action visible below the preview. The title and supporting text should remain easy to scan at a narrow width.",
                "Use the annotation tools to point out the exact detail. Add a short note beside the action, then choose Done to keep an annotated copy.",
                "The original attachment and this draft stay available while the image is being reviewed. Nothing in this synthetic conversation is sent.",
            ];
            div()
                .size_full()
                .bg(t.bg)
                .text_color(t.text)
                .text_size(px(15.0))
                .flex()
                .flex_col()
                .child(
                    div()
                        .h(px(52.0))
                        .flex_shrink_0()
                        .px(px(20.0))
                        .flex()
                        .items_center()
                        .justify_between()
                        .border_b_1()
                        .border_color(t.border)
                        .child("Onboarding review")
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(t.text_muted)
                                .child("Synthetic fixture"),
                        ),
                )
                .child(
                    div()
                        .flex_1()
                        .min_h(px(0.0))
                        .overflow_hidden()
                        .px(px(24.0))
                        .py(px(24.0))
                        .flex()
                        .flex_col()
                        .gap(px(20.0))
                        .child(
                            div()
                                .w_full()
                                .p(px(16.0))
                                .rounded(px(12.0))
                                .bg(t.surface_raised)
                                .border_1()
                                .border_color(t.border)
                                .child("Review this onboarding screen. I want to mark the action near the bottom before we make changes."),
                        )
                        .child(div().text_color(t.text_muted).child("Harness"))
                        .children(response.into_iter().map(|text| {
                            div().w_full().line_height(px(23.0)).child(text)
                        }))
                        .child(
                            div()
                                .w_full()
                                .p(px(16.0))
                                .rounded(px(12.0))
                                .bg(t.surface_raised)
                                .border_1()
                                .border_color(t.border)
                                .child("Please preserve the current draft while I annotate the image."),
                        ),
                )
                .child(
                    div()
                        .flex_shrink_0()
                        .px(px(16.0))
                        .pb(px(16.0))
                        .child(self.composer.clone()),
                )
        }
    }

    /// Literal geometric test board, not generated model output or user data.
    fn portrait(path: &Path) -> anyhow::Result<()> {
        let mut image = image::RgbImage::from_pixel(720, 1600, image::Rgb([241, 238, 227]));
        let mut rect = |x: u32, y: u32, w: u32, h: u32, color: [u8; 3]| {
            for py in y..(y + h).min(1600) {
                for px in x..(x + w).min(720) {
                    image.put_pixel(px, py, image::Rgb(color));
                }
            }
        };
        rect(0, 0, 720, 104, [45, 72, 64]);
        rect(36, 36, 42, 32, [237, 218, 156]);
        rect(102, 44, 206, 14, [249, 248, 241]);
        rect(48, 154, 400, 24, [45, 72, 64]);
        rect(48, 198, 526, 12, [144, 149, 135]);
        rect(48, 226, 434, 12, [144, 149, 135]);
        rect(48, 286, 624, 346, [201, 218, 206]);
        rect(88, 334, 246, 250, [104, 143, 125]);
        rect(364, 334, 268, 112, [241, 220, 169]);
        rect(364, 476, 268, 108, [218, 161, 137]);
        for (row, color) in [[203, 216, 206], [225, 199, 157], [202, 207, 222]]
            .into_iter()
            .enumerate()
        {
            let y = 688 + row as u32 * 204;
            rect(48, y, 624, 170, [255, 254, 247]);
            rect(72, y + 30, 76, 76, color);
            rect(174, y + 36, 264, 15, [64, 80, 70]);
            rect(174, y + 72, 434, 10, [157, 164, 149]);
            rect(174, y + 98, 364, 10, [157, 164, 149]);
            rect(174, y + 128, 172, 9, [180, 183, 169]);
        }
        rect(48, 1340, 624, 92, [45, 72, 64]);
        rect(230, 1378, 260, 14, [255, 254, 247]);
        rect(172, 1480, 376, 10, [144, 149, 135]);
        rect(236, 1510, 248, 10, [144, 149, 135]);
        image.save(path)?;
        Ok(())
    }

    fn capture(
        window: AnyWindowHandle,
        output: &Path,
        name: &str,
        width: f32,
        height: f32,
        cx: &mut AsyncApp,
    ) -> anyhow::Result<serde_json::Value> {
        let filename = format!("{name}.png");
        let path = output.join(&filename);
        let pixels = window.update(cx, |_, window, cx| -> anyhow::Result<_> {
            let viewport = window.viewport_size();
            anyhow::ensure!(
                f32::from(viewport.width) == width && f32::from(viewport.height) == height,
                "unexpected viewport: {viewport:?}; requested {width}×{height}"
            );
            // An untyped handle avoids holding a mutable root-view borrow
            // while draw re-enters its Render implementation.
            window.draw(cx).clear();
            let image = window.render_to_image()?;
            let pixels = image.dimensions();
            image.save(&path)?;
            Ok(pixels)
        })??;
        println!("{}", path.display());
        Ok(serde_json::json!({
            "file": filename,
            "logical_size": [width, height],
            "pixel_size": [pixels.0, pixels.1],
        }))
    }

    fn rect(bounds: Bounds<gpui::Pixels>) -> [f32; 4] {
        [
            bounds.origin.x.into(),
            bounds.origin.y.into(),
            bounds.size.width.into(),
            bounds.size.height.into(),
        ]
    }

    fn visible_bounds(window: &Window, selector: &str) -> anyhow::Result<Bounds<gpui::Pixels>> {
        let bounds = window
            .debug_bounds(selector)
            .ok_or_else(|| anyhow::anyhow!("missing rendered selector: {selector}"))?;
        let [x, y, width, height] = rect(bounds);
        let viewport = window.viewport_size();
        anyhow::ensure!(
            width > 0.0
                && height > 0.0
                && x >= -1.0
                && y >= -1.0
                && x + width <= f32::from(viewport.width) + 1.0
                && y + height <= f32::from(viewport.height) + 1.0,
            "{selector} is outside the viewport: {bounds:?} in {viewport:?}"
        );
        Ok(bounds)
    }

    fn verify_editor(
        native: AnyWindowHandle,
        preview_frame: Bounds<gpui::Pixels>,
        stage: &str,
        note_open: bool,
        cx: &mut AsyncApp,
    ) -> anyhow::Result<serde_json::Value> {
        native.update(cx, |_, window, _| -> anyhow::Result<_> {
            let frame = visible_bounds(window, "annotate-frame")?;
            anyhow::ensure!(
                rect(frame)
                    .into_iter()
                    .zip(rect(preview_frame))
                    .all(|(actual, expected)| (actual - expected).abs() <= 1.0),
                "image frame moved when entering {stage}: preview {preview_frame:?}, editor {frame:?}"
            );
            let tools = visible_bounds(window, "annotate-tools")?;
            let actions = visible_bounds(window, "annotate-actions")?;
            let filename = visible_bounds(window, "annotate-filename")?;
            let note = if note_open {
                Some(rect(visible_bounds(window, "annotate-note")?))
            } else {
                None
            };
            Ok(serde_json::json!({
                "stage": stage, "image_frame_unchanged": true,
                "controls_within_viewport": true, "frame": rect(frame),
                "tools": rect(tools), "actions": rect(actions),
                "filename": rect(filename), "note": note,
            }))
        })?
    }

    pub fn run() -> anyhow::Result<()> {
        let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
        std::fs::create_dir_all(&output)?;
        let data = tempfile::tempdir()?;
        let image_path = data.path().join("synthetic-onboarding-portrait.png");
        portrait(&image_path)?;
        let original = std::fs::read(&image_path)?;
        std::fs::copy(&image_path, output.join("synthetic-source-720x1600.png"))?;
        // SAFETY: set before starting GPUI or its worker threads. Each fresh
        // composer stages the same synthetic source and opens its single viewer.
        unsafe {
            std::env::set_var("HARNESS_ATTACH", &image_path);
            std::env::set_var("HARNESS_ATTACH_PREVIEW", "1");
        }
        let error = Arc::new(Mutex::new(None));
        let failure = error.clone();
        gpui_platform::application()
            .with_assets(icons::Assets)
            .run(move |cx| {
                gpui_tokio::init(cx);
                gpui_base::init(cx);
                let mut preferences = settings::UiSettings::default();
                preferences.ui_font_family = typography::UiFontFamily::System;
                settings::init(preferences.clone(), data.path(), cx);
                let fonts = typography::register_fonts(cx);
                typography::init(
                    preferences.ui_font_family.clone(),
                    preferences.ui_font_size,
                    preferences.terminal_font_family.clone(),
                    preferences.terminal_font_size,
                    preferences.code_font_family.clone(),
                    preferences.code_font_size,
                    fonts,
                    cx,
                );
                theme_library::init(data.path().to_path_buf(), cx);
                appearance::init(
                    appearance::AppearanceMode::Light,
                    preferences.theme_selection,
                    preferences.accent,
                    preferences.surface,
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
                composer::init(cx, preferences.composer_send_behavior);
                cx.spawn(async move |cx| {
                    let _keep_data = data;
                    let mut active: Option<AnyWindowHandle> = None;
                    let run: anyhow::Result<()> = async {
                        let settle = Duration::from_millis(700);
                        let mut captures = Vec::new();
                        let mut assertions = Vec::new();
                        for (tone, look, mode) in [
                            ("light", theme::Appearance::Light, appearance::AppearanceMode::Light),
                            ("dark", theme::Appearance::Dark, appearance::AppearanceMode::Dark),
                        ] {
                            cx.update(|cx| {
                                appearance::set_theme(look, format!("warm-harp-{tone}"), cx);
                                appearance::set_mode(mode, cx);
                            });
                            for (size_name, width, height) in [
                                ("normal", 1200.0, 800.0),
                                ("narrow", 420.0, 700.0),
                            ] {
                                let window = cx.update(|cx| cx.open_window(WindowOptions {
                                    focus: false,
                                    titlebar: None,
                                    window_background: theme::Theme::of(cx).window_background_appearance(),
                                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                                        point(px(24.0), px(48.0)), size(px(width), px(height)),
                                    ))),
                                    ..Default::default()
                                }, |window, cx| {
                                    window.set_rem_size(px(preferences.ui_font_size.pixels()));
                                    let state = cx.new(|_| {
                                        let mut state = state::AppState::new();
                                        state.no_project = true;
                                        state
                                    });
                                    let composer = cx.new(|cx| composer::Composer::new(state, cx));
                                    composer.update(cx, |composer, cx| {
                                        composer.set_available_width(width - 32.0, cx);
                                        composer.set_available_height(height, cx);
                                        composer.fixture_set_draft(DRAFT, cx);
                                    });
                                    cx.new(|_| Frame { composer })
                                }))?;
                                let native: AnyWindowHandle = window.into();
                                active = Some(native);
                                let composer = window.update(cx, |frame, _, _| frame.composer.clone())?;
                                cx.background_executor().timer(settle).await;
                                let prefix = format!("annotation-{tone}-{size_name}");
                                captures.push(capture(native, &output, &format!("{prefix}-preview"), width, height, cx)?);

                                let (preview_frame, annotate_bounds) = native.update(cx, |_, window, cx| -> anyhow::Result<_> {
                                    let button = visible_bounds(window, "attachment-lightbox-annotate")?;
                                    let frame = visible_bounds(window, "attachment-lightbox-frame")?;
                                    let center = button.center();
                                    anyhow::ensure!((f32::from(center.x) - width / 2.0).abs() <= 1.0,
                                        "Annotate is not centered: {button:?} in width {width}");
                                    // Exercise the real Mac click handler and
                                    // event propagation through the lightbox.
                                    window.dispatch_event(gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                        position: center, ..Default::default()
                                    }), cx);
                                    window.dispatch_event(gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                        position: center, button: gpui::MouseButton::Left,
                                        click_count: 1, ..Default::default()
                                    }), cx);
                                    window.dispatch_event(gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                        position: center, button: gpui::MouseButton::Left,
                                        click_count: 1, ..Default::default()
                                    }), cx);
                                    Ok((frame, button))
                                })??;
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-editor"), width, height, cx)?);
                                let editor = composer.read_with(cx, |composer, _| composer.fixture_annotate_editor())
                                    .ok_or_else(|| anyhow::anyhow!("real Annotate click did not open the annotation editor"))?;
                                let mut geometry = vec![verify_editor(native, preview_frame, "editor", false, cx)?];

                                native.update(cx, |_, window, cx| editor.update(cx, |editor, cx| {
                                    editor.set_tool(annotate::Tool::Text, cx);
                                    editor.pick_color(annotate::MarkColor::Yellow, cx);
                                    editor.place_text((360.0, 1320.0), window, cx);
                                }))?;
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-text-empty"), width, height, cx)?);
                                geometry.push(verify_editor(native, preview_frame, "text-empty", true, cx)?);
                                editor.update(cx, |editor, cx| editor.type_note(NOTE, cx));
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-text-filled"), width, height, cx)?);
                                geometry.push(verify_editor(native, preview_frame, "text-filled", true, cx)?);

                                // Done calls back into Composer: it must not be
                                // borrowed while the editor stages the new PNG.
                                native.update(cx, |_, window, cx| editor.update(cx, |editor, cx| {
                                    editor.commit_note(window, cx);
                                    editor.press_done(window, cx);
                                }))?;
                                cx.background_executor().timer(settle).await;
                                let staged = composer.read_with(cx, |composer, _| composer.fixture_staged());
                                let annotated: Vec<_> = staged.iter().filter(|(_, _, notes)| notes.is_some()).collect();
                                anyhow::ensure!(annotated.len() == 1, "Done must stage one annotated PNG");
                                let (name, bytes, notes) = annotated[0];
                                anyhow::ensure!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"), "annotated copy is not PNG");
                                anyhow::ensure!(bytes != &original, "annotation did not change image bytes");
                                let decoded = image::load_from_memory(bytes)?;
                                anyhow::ensure!(decoded.width() == 720 && decoded.height() == 1600, "portrait dimensions changed");
                                anyhow::ensure!(notes.as_deref().is_some_and(|notes| notes.contains(NOTE)), "annotation text missing from prompt notes");
                                let draft = composer.read_with(cx, |composer, cx| composer.fixture_input_text(cx).0);
                                anyhow::ensure!(draft == DRAFT, "Done changed the existing composer draft");
                                std::fs::write(output.join(format!("{prefix}-annotated.png")), bytes)?;
                                assertions.push(serde_json::json!({
                                    "theme": format!("warm-harp-{tone}"), "window": size_name,
                                    "annotated_name": name, "annotated_png_staged": true,
                                    "encoded_bytes_changed": true, "portrait_dimensions_preserved": true,
                                    "note_preserved": true, "draft_preserved": true,
                                    "native_annotate_click_opened_editor": true,
                                    "annotate_centered": true, "annotate_within_viewport": true,
                                    "annotate_bounds": rect(annotate_bounds),
                                    "preview_frame": rect(preview_frame), "geometry": geometry,
                                }));
                                native.update(cx, |_, window, _| window.remove_window())?;
                                active = None;
                            }
                        }
                        anyhow::ensure!(captures.len() == 16, "incomplete annotation capture matrix");
                        std::fs::write(output.join("result.json"), serde_json::to_vec_pretty(&serde_json::json!({
                            "synthetic": true, "platform": "macOS", "engine_requests": 0,
                            "source": "literal geometric portrait test board", "source_size": [720, 1600],
                            "background": "synthetic native conversation and real Composer with a retained draft",
                            "production_components": ["Composer", "PreviewImage", "AnnotateEditor"],
                            "stages": ["preview", "editor", "text-empty", "text-filled"],
                            "assertions": assertions, "captures": captures,
                        }))?)?;
                        Ok(())
                    }.await;
                    if let Err(err) = run {
                        *failure.lock().unwrap() = Some(format!("{err:#}"));
                    }
                    if let Some(window) = active {
                        let _ = window.update(cx, |_, window, _| window.remove_window());
                    }
                    cx.update(|cx| cx.quit());
                }).detach();
            });
        if let Some(error) = error.lock().unwrap().take() {
            anyhow::bail!(error);
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    native::run()
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This annotation review fixture is macOS-only.");
}
