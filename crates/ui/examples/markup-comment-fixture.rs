//! Native Markup/Comment interaction and persistence review over a synthetic conversation.
//! Run: markup-comment-fixture <output-directory>. No engine or model calls.
//! Captures preview, color, resting/active width rails, comment and editable reopening at two Mac sizes in both Warm Harp themes.

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
    const REVISED_NOTE: &str = "Make this primary action easier to find";
    const UNSAVED_NOTE: &str = "Temporary comment that must be discarded";

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
                "Use Markup to draw on the image or Comment to explain a detail. Keep comment words outside the picture, then choose Done.",
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

    fn click_point(window: &mut Window, at: gpui::Point<gpui::Pixels>, cx: &mut gpui::App) {
        window.dispatch_event(
            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                position: at,
                ..Default::default()
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position: at,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position: at,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    }

    fn click(native: AnyWindowHandle, selector: &str, cx: &mut AsyncApp) -> anyhow::Result<()> {
        click_fraction(native, selector, (0.5, 0.5), cx)
    }

    fn click_fraction(
        native: AnyWindowHandle,
        selector: &str,
        fraction: (f32, f32),
        cx: &mut AsyncApp,
    ) -> anyhow::Result<()> {
        native.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            let bounds = visible_bounds(window, selector)?;
            let at = point(
                bounds.origin.x + bounds.size.width * fraction.0,
                bounds.origin.y + bounds.size.height * fraction.1,
            );
            click_point(window, at, cx);
            Ok(())
        })??;
        Ok(())
    }

    fn blur_width_rail(
        native: AnyWindowHandle,
        tool_selector: &str,
        cx: &mut AsyncApp,
    ) -> anyhow::Result<()> {
        click(native, tool_selector, cx)?;
        native.update(cx, |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: point(window.viewport_size().width - px(8.0), px(8.0)),
                    ..Default::default()
                }),
                cx,
            );
        })?;
        Ok(())
    }

    fn hover_width_rail(native: AnyWindowHandle, cx: &mut AsyncApp) -> anyhow::Result<()> {
        native.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            let bounds = visible_bounds(window, "annotate-width-slider")?;
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: bounds.center(),
                    ..Default::default()
                }),
                cx,
            );
            Ok(())
        })??;
        Ok(())
    }

    fn click_width_endpoint(
        native: AnyWindowHandle,
        maximum: bool,
        cx: &mut AsyncApp,
    ) -> anyhow::Result<()> {
        native.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            let bounds = visible_bounds(window, "annotate-width-slider")?;
            let y = if maximum {
                bounds.top() + px(16.0)
            } else {
                bounds.bottom() - px(16.0)
            };
            click_point(window, point(bounds.center().x, y), cx);
            Ok(())
        })??;
        Ok(())
    }

    fn width_rail_geometry(
        native: AnyWindowHandle,
        cx: &mut AsyncApp,
    ) -> anyhow::Result<serde_json::Value> {
        native.update(cx, |_, window, cx| -> anyhow::Result<_> {
            window.draw(cx).clear();
            let rail = visible_bounds(window, "annotate-width-rail")?;
            let slider = visible_bounds(window, "annotate-width-slider")?;
            let track = visible_bounds(window, "annotate-width-track")?;
            let thumb = visible_bounds(window, "annotate-width-thumb")?;
            let frame = visible_bounds(window, "annotate-frame")?;
            let image = visible_bounds(window, "annotate-image")?;
            let footer = visible_bounds(window, "annotate-filename")?;
            let gutter = if f32::from(window.viewport_size().width) < 560.0 {
                16.0
            } else {
                24.0
            };
            anyhow::ensure!(
                (f32::from(rail.left()) - gutter).abs() <= 1.0
                    && (f32::from(rail.center().y - frame.center().y)).abs() <= 1.0,
                "persistent width rail is not at the left gutter and centered on the image frame"
            );
            anyhow::ensure!(
                rail.right() <= image.left()
                    && rail.bottom() <= footer.top()
                    && frame.bottom() <= footer.top(),
                "width rail or image frame overlaps the portrait image/footer"
            );
            anyhow::ensure!(
                window.debug_bounds("annotate-width-trigger").is_none()
                    && window.debug_bounds("annotate-width-popover").is_none(),
                "old width popup controls are still rendered"
            );
            Ok(serde_json::json!({
                "rail": rect(rail), "slider": rect(slider), "track": rect(track),
                "thumb": rect(thumb), "frame": rect(frame), "footer": rect(footer),
                "track_width": f32::from(track.size.width),
                "thumb_width": f32::from(thumb.size.width),
                "left_gutter_and_frame_centered": true,
                "clear_of_portrait_and_footer": true,
            }))
        })?
    }

    fn width_rail_absent(native: AnyWindowHandle, cx: &mut AsyncApp) -> anyhow::Result<()> {
        native.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            for selector in [
                "annotate-width-rail",
                "annotate-width-slider",
                "annotate-width-thumb",
                "annotate-width-track",
            ] {
                anyhow::ensure!(
                    window.debug_bounds(selector).is_none(),
                    "{selector} is visible outside a width-bearing markup tool"
                );
            }
            Ok(())
        })??;
        Ok(())
    }

    fn key(native: AnyWindowHandle, key: &str, cx: &mut AsyncApp) -> anyhow::Result<()> {
        let keystroke = gpui::Keystroke::parse(key)?;
        native.update(cx, |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                    keystroke,
                    is_held: false,
                    prefer_character_input: false,
                }),
                cx,
            );
        })?;
        Ok(())
    }

    fn stroke(
        native: AnyWindowHandle,
        points: &[(f32, f32)],
        cx: &mut AsyncApp,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(points.len() >= 2, "a fixture stroke needs two points");
        native.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            let bounds = visible_bounds(window, "annotate-image")?;
            let at = |fraction: (f32, f32)| {
                point(
                    bounds.origin.x + bounds.size.width * fraction.0,
                    bounds.origin.y + bounds.size.height * fraction.1,
                )
            };
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                    position: at(points[0]),
                    button: gpui::MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
            for position in points.iter().skip(1) {
                window.dispatch_event(
                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                        position: at(*position),
                        pressed_button: Some(gpui::MouseButton::Left),
                        ..Default::default()
                    }),
                    cx,
                );
            }
            window.dispatch_event(
                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                    position: at(*points.last().unwrap()),
                    button: gpui::MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
            Ok(())
        })??;
        Ok(())
    }

    fn editor(
        composer: &Entity<composer::Composer>,
        cx: &AsyncApp,
    ) -> anyhow::Result<Entity<annotate::editor::AnnotateEditor>> {
        composer
            .read_with(cx, |composer, _| composer.fixture_annotate_editor())
            .ok_or_else(|| anyhow::anyhow!("native entry action did not open the editor"))
    }

    fn document(
        composer: &Entity<composer::Composer>,
        cx: &AsyncApp,
    ) -> anyhow::Result<annotate::Annotations> {
        Ok(editor(composer, cx)?.read_with(cx, |editor, _| editor.fixture_document()))
    }

    fn staged_state(composer: &Entity<composer::Composer>, cx: &AsyncApp) -> serde_json::Value {
        composer.read_with(cx, |composer, _| composer.fixture_annotation_state())
    }

    fn assert_same_attachment(
        before: &serde_json::Value,
        after: &serde_json::Value,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            after["staged_count"] == 1,
            "editing duplicated or lost the attachment: {after}"
        );
        anyhow::ensure!(
            before["id"].is_string() && before["id"] == after["id"],
            "attachment identity changed"
        );
        anyhow::ensure!(
            before["original_sha256"].is_string()
                && before["original_sha256"] == after["original_sha256"],
            "original image bytes changed"
        );
        Ok(())
    }

    fn geometry(
        native: AnyWindowHandle,
        selectors: &[&str],
        cx: &mut AsyncApp,
    ) -> anyhow::Result<serde_json::Value> {
        native.update(cx, |_, window, _| -> anyhow::Result<_> {
            let mut result = serde_json::Map::new();
            for selector in selectors {
                result.insert(
                    (*selector).to_owned(),
                    serde_json::json!(rect(visible_bounds(window, selector)?)),
                );
            }
            Ok(serde_json::Value::Object(result))
        })?
    }

    fn comment_pin_clear_of_popup(
        native: AnyWindowHandle,
        comment: u64,
        cx: &mut AsyncApp,
    ) -> anyhow::Result<()> {
        native.update(cx, |_, window, _| -> anyhow::Result<()> {
            let pin = visible_bounds(window, &format!("annotate-comment-{comment}"))?;
            let popup = visible_bounds(window, "annotate-note")?;
            let [px, py, pw, ph] = rect(pin);
            let [nx, ny, nw, nh] = rect(popup);
            anyhow::ensure!(
                px + pw <= nx || nx + nw <= px || py + ph <= ny || ny + nh <= py,
                "active comment pin overlaps its note popup: pin={pin:?}, popup={popup:?}"
            );
            Ok(())
        })??;
        Ok(())
    }

    fn comment_words_are_not_pixels(
        original: &[u8],
        saved: &annotate::Annotations,
        comment: u64,
    ) -> anyhow::Result<()> {
        let mut changed = saved.clone();
        anyhow::ensure!(
            changed.commit_text(comment, REVISED_NOTE),
            "comment edit was not applied"
        );
        let before = annotate::flatten(original, saved, 1.0).map_err(anyhow::Error::msg)?;
        let after = annotate::flatten(original, &changed, 1.0).map_err(anyhow::Error::msg)?;
        anyhow::ensure!(
            before == after,
            "changing comment words changed exported image pixels"
        );
        Ok(())
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
                                let prefix = format!("markup-comment-{tone}-{size_name}");
                                let initial_state = staged_state(&composer, cx);
                                let mut geometry_checks = Vec::new();
                                captures.push(capture(native, &output, &format!("{prefix}-preview"), width, height, cx)?);
                                native.update(cx, |_, window, _| -> anyhow::Result<()> {
                                    let group = visible_bounds(window, "attachment-lightbox-actions")?;
                                    let markup = visible_bounds(window, "attachment-lightbox-markup")?;
                                    let comment = visible_bounds(window, "attachment-lightbox-comment")?;
                                    anyhow::ensure!((f32::from(group.center().x) - width / 2.0).abs() <= 1.0,
                                        "Markup/Comment action group is not centered");
                                    anyhow::ensure!(markup.center().x < comment.center().x,
                                        "Markup and Comment action order changed");
                                    Ok(())
                                })??;
                                geometry_checks.push(geometry(native, &["attachment-lightbox-actions", "attachment-lightbox-markup", "attachment-lightbox-comment", "attachment-lightbox-frame"], cx)?);

                                // All entry, tool, slider, canvas, history and
                                // completion actions use real native pointer events.
                                click(native, "attachment-lightbox-markup", cx)?;
                                cx.background_executor().timer(settle).await;
                                click(native, "annotate-tool-pen", cx)?;
                                stroke(native, &[(0.18,0.25),(0.26,0.22),(0.35,0.24),(0.44,0.30),(0.55,0.28),(0.69,0.24),(0.81,0.27)], cx)?;
                                let first = document(&composer, cx)?;
                                anyhow::ensure!(first.items().len() == 1 && matches!(&first.items()[0].shape, annotate::Shape::Stroke { points, .. } if points.len() > 2), "pointer drag did not create a freehand stroke");
                                click(native, "annotate-color-trigger", cx)?;
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-color"), width, height, cx)?);
                                geometry_checks.push(geometry(native, &["annotate-color-popover", "annotate-color-red", "annotate-color-blue", "annotate-color-green", "annotate-color-yellow"], cx)?);
                                click(native, "annotate-color-blue", cx)?;
                                stroke(native, &[(0.20,0.14),(0.35,0.16),(0.50,0.14)], cx)?;
                                let blue = document(&composer, cx)?;
                                anyhow::ensure!(blue.items().len() == 2 && blue.items()[1].color == annotate::MarkColor::Blue, "native Blue swatch click did not change the drawn stroke");
                                click(native, "annotate-undo", cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == first.items(), "Undo did not remove the temporary Blue stroke");
                                click(native, "annotate-color-trigger", cx)?;
                                click(native, "annotate-color-red", cx)?;
                                click(native, "annotate-tool-text", cx)?;
                                width_rail_absent(native, cx)?;
                                click(native, "annotate-tool-rect", cx)?;
                                geometry_checks.push(width_rail_geometry(native, cx)?);
                                click(native, "annotate-tool-pen", cx)?;
                                let initial_image_width = match &first.items()[0].shape {
                                    annotate::Shape::Stroke { width, .. } => *width,
                                    _ => anyhow::bail!("initial mark was not a stroke"),
                                };
                                let mut endpoint_widths = Vec::new();
                                for (maximum, expected) in [(true, 20.0), (false, 1.0)] {
                                    click_width_endpoint(native, maximum, cx)?;
                                    blur_width_rail(native, "annotate-tool-pen", cx)?;
                                    stroke(native, &[(0.20,0.14),(0.35,0.16),(0.50,0.14)], cx)?;
                                    let endpoint = document(&composer, cx)?;
                                    anyhow::ensure!(endpoint.items().len() == 2, "endpoint probe did not create a stroke");
                                    let image_width = match &endpoint.items()[1].shape {
                                        annotate::Shape::Stroke { width, .. } => *width,
                                        _ => anyhow::bail!("endpoint probe was not a stroke"),
                                    };
                                    let screen_width = image_width * 4.0 / initial_image_width;
                                    anyhow::ensure!((screen_width - expected).abs() < 0.01,
                                        "slider endpoint produced {screen_width} px instead of {expected} px");
                                    endpoint_widths.push(serde_json::json!({
                                        "endpoint": if maximum { "top" } else { "bottom" },
                                        "expected_screen_width": expected,
                                        "drawn_screen_width": screen_width,
                                    }));
                                    click(native, "annotate-undo", cx)?;
                                    anyhow::ensure!(document(&composer, cx)?.items() == first.items(), "Undo did not remove the endpoint probe stroke");
                                }
                                click_fraction(native, "annotate-width-slider", (0.75,0.5), cx)?;
                                // Middle of the inset 1–20 slider rounds to
                                // 11 px. Two Up presses and Down make 12 px.
                                key(native, "up", cx)?;
                                key(native, "up", cx)?;
                                key(native, "down", cx)?;
                                key(native, "escape", cx)?;
                                let _still_open = editor(&composer, cx)?;
                                geometry_checks.push(width_rail_geometry(native, cx)?);
                                blur_width_rail(native, "annotate-tool-pen", cx)?;
                                stroke(native, &[(0.20,0.42),(0.28,0.46),(0.39,0.48),(0.51,0.44),(0.64,0.46),(0.78,0.42)], cx)?;
                                let two_strokes = document(&composer, cx)?;
                                anyhow::ensure!(two_strokes.items().len() == 2, "second pen stroke was not created");
                                let widths: Vec<_> = two_strokes.items().iter().filter_map(|mark| match &mark.shape {
                                    annotate::Shape::Stroke { width, .. } => Some(*width), _ => None,
                                }).collect();
                                anyhow::ensure!(widths.len() == 2 && widths[1] > widths[0], "native width slider did not change stroke width");
                                anyhow::ensure!((widths[1] / widths[0] - 3.0).abs() < 0.01, "width arrow keys did not adjust the selected brush to 12 px");
                                anyhow::ensure!(two_strokes.items()[1].color == annotate::MarkColor::Red, "Red swatch reset did not restore the pen color");
                                blur_width_rail(native, "annotate-tool-pen", cx)?;
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-pen-width-rest"), width, height, cx)?);
                                let resting_rail = width_rail_geometry(native, cx)?;
                                geometry_checks.push(resting_rail.clone());
                                hover_width_rail(native, cx)?;
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-pen-width"), width, height, cx)?);
                                let hovered_rail = width_rail_geometry(native, cx)?;
                                anyhow::ensure!((resting_rail["track_width"].as_f64().unwrap() - 2.0).abs() < 0.25,
                                    "width rail did not settle to a thin 2px track");
                                anyhow::ensure!((hovered_rail["track_width"].as_f64().unwrap() - 20.0).abs() < 0.5,
                                    "hover did not expand the track to its 20px taper");
                                anyhow::ensure!(hovered_rail["thumb_width"].as_f64().unwrap() > resting_rail["thumb_width"].as_f64().unwrap() + 0.5,
                                    "hover did not expand the width thumb");
                                geometry_checks.push(hovered_rail.clone());
                                blur_width_rail(native, "annotate-tool-pen", cx)?;

                                click(native, "annotate-tool-eraser", cx)?;
                                hover_width_rail(native, cx)?;
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-eraser-width"), width, height, cx)?);
                                geometry_checks.push(width_rail_geometry(native, cx)?);
                                blur_width_rail(native, "annotate-tool-eraser", cx)?;
                                stroke(native, &[(0.50,0.27),(0.55,0.28),(0.60,0.27)], cx)?;
                                let erased = document(&composer, cx)?;
                                anyhow::ensure!(erased.items().len() == 1, "eraser did not remove the intersected stroke");
                                click(native, "annotate-undo", cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == two_strokes.items(), "Undo did not restore the erased stroke");
                                click(native, "annotate-redo", cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == erased.items(), "Redo did not repeat erasure");
                                click(native, "annotate-undo", cx)?;
                                click(native, "annotate-done", cx)?;
                                cx.background_executor().timer(settle).await;
                                let pen_state = staged_state(&composer, cx);
                                assert_same_attachment(&initial_state, &pen_state)?;

                                composer.update(cx, |composer, cx| composer.fixture_preview_first_staged(cx));
                                cx.background_executor().timer(settle).await;
                                click(native, "attachment-lightbox-comment", cx)?;
                                cx.background_executor().timer(settle).await;
                                width_rail_absent(native, cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == two_strokes.items(), "Comment reopened flattened pixels instead of editable strokes");
                                click_fraction(native, "annotate-image", (0.25,0.65), cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items().len() == two_strokes.items().len() + 1, "blank comment pin was not created");
                                click(native, "annotate-undo", cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == two_strokes.items(), "Undo of a blank new comment removed an earlier stroke");
                                click_fraction(native, "annotate-image", (0.55,0.81), cx)?;
                                let comment_editor = editor(&composer, cx)?;
                                comment_editor.update(cx, |editor, cx| editor.type_note(NOTE, cx));
                                cx.background_executor().timer(settle).await;
                                captures.push(capture(native, &output, &format!("{prefix}-comment"), width, height, cx)?);
                                geometry_checks.push(geometry(native, &["annotate-image", "annotate-note", "annotate-tools", "annotate-actions"], cx)?);
                                let comment_draft = document(&composer, cx)?;
                                let pin = comment_draft.items().iter().find(|mark| matches!(mark.shape, annotate::Shape::Comment { .. }))
                                    .ok_or_else(|| anyhow::anyhow!("Comment canvas click did not create a pin"))?;
                                geometry_checks.push(geometry(native, &[&format!("annotate-comment-{}", pin.id)], cx)?);
                                comment_pin_clear_of_popup(native, pin.id, cx)?;
                                click(native, "annotate-done", cx)?;
                                cx.background_executor().timer(settle).await;
                                let saved_document = comment_editor.read_with(cx, |editor, _| editor.fixture_document());
                                anyhow::ensure!(saved_document.items().len() == 3, "saved document lost or duplicated marks");
                                anyhow::ensure!(saved_document.items().iter().any(|mark| matches!(mark.shape, annotate::Shape::Comment { .. }) && mark.text == NOTE), "comment body was not committed");
                                comment_words_are_not_pixels(&original, &saved_document, pin.id)?;
                                let saved_state = staged_state(&composer, cx);
                                assert_same_attachment(&initial_state, &saved_state)?;
                                let staged = composer.read_with(cx, |composer, _| composer.fixture_staged());
                                anyhow::ensure!(staged.len() == 1, "Done must replace the same single attachment");
                                let (_, bytes, notes) = &staged[0];
                                anyhow::ensure!(bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes != &original, "Done did not produce an annotated PNG");
                                let decoded = image::load_from_memory(bytes)?;
                                anyhow::ensure!(decoded.width() == 720 && decoded.height() == 1600, "saved image dimensions changed");
                                anyhow::ensure!(notes.as_deref().is_some_and(|notes| notes.contains(NOTE)), "comment body missing from prompt notes");
                                std::fs::write(output.join(format!("{prefix}-saved.png")), bytes)?;

                                composer.update(cx, |composer, cx| composer.fixture_preview_first_staged(cx));
                                cx.background_executor().timer(settle).await;
                                click(native, "attachment-lightbox-markup", cx)?;
                                cx.background_executor().timer(settle).await;
                                anyhow::ensure!(document(&composer, cx)?.items() == saved_document.items(), "saved marks did not reopen as editable objects");
                                captures.push(capture(native, &output, &format!("{prefix}-reopened"), width, height, cx)?);
                                geometry_checks.push(geometry(native, &["annotate-image", "annotate-tools", "annotate-actions"], cx)?);
                                // A live edit of an existing pin is an Undo
                                // operation of its own, even after reopening.
                                click(native, &format!("annotate-comment-{}", pin.id), cx)?;
                                editor(&composer, cx)?.update(cx, |editor, cx| editor.type_note(REVISED_NOTE, cx));
                                click(native, "annotate-undo", cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == saved_document.items(), "Undo of pending comment words changed an unrelated mark");
                                click(native, "annotate-redo", cx)?;
                                let redone = document(&composer, cx)?;
                                let mut expected_redo = saved_document.clone();
                                expected_redo.commit_text(pin.id, REVISED_NOTE);
                                anyhow::ensure!(redone.items() == expected_redo.items(), "Redo did not recover the pending comment words");
                                click(native, "annotate-undo", cx)?;
                                anyhow::ensure!(document(&composer, cx)?.items() == saved_document.items(), "comment history did not restore the saved document");
                                click(native, "annotate-done", cx)?;
                                cx.background_executor().timer(settle).await;
                                let unchanged_save = staged_state(&composer, cx);
                                anyhow::ensure!(unchanged_save == saved_state, "Done without edits changed the saved attachment or doubled markup");

                                composer.update(cx, |composer, cx| composer.fixture_preview_first_staged(cx));
                                cx.background_executor().timer(settle).await;
                                click(native, "attachment-lightbox-comment", cx)?;
                                cx.background_executor().timer(settle).await;
                                click_fraction(native, "annotate-image", (0.25,0.65), cx)?;
                                editor(&composer, cx)?.update(cx, |editor, cx| editor.type_note(UNSAVED_NOTE, cx));
                                click(native, "annotate-cancel", cx)?;
                                cx.background_executor().timer(settle).await;
                                anyhow::ensure!(staged_state(&composer, cx) == saved_state, "Cancel changed saved annotation data");
                                let draft = composer.read_with(cx, |composer, cx| composer.fixture_input_text(cx).0);
                                anyhow::ensure!(draft == DRAFT, "Done or Cancel changed the existing composer draft");
                                assertions.push(serde_json::json!({
                                    "theme": format!("warm-harp-{tone}"), "window": size_name,
                                    "native_markup_and_comment_entry": true, "centered_preview_actions": true,
                                    "freehand_pointer_strokes": true, "native_width_slider_changed_stroke": true,
                                    "native_color_swatch_selection": true, "width_keyboard_arrows": true,
                                    "pen_width_pointer_endpoints": endpoint_widths,
                                    "persistent_left_rail_layout": true,
                                    "rail_hidden_for_text_and_comment": true,
                                    "escape_keeps_editor_and_rail": true,
                                    "width_rail_hover_expansion": {"rest": resting_rail, "hover": hovered_rail},
                                    "eraser_width_rail_within_viewport": true,
                                    "eraser_undo_redo": true, "pending_comment_undo_redo": true,
                                    "blank_comment_undo_preserves_prior_strokes": true,
                                    "active_comment_pin_clear_of_popup": true,
                                    "comment_words_do_not_change_exported_pixels": true,
                                    "same_attachment_identity": true, "original_image_preserved": true,
                                    "saved_marks_reopen_editable": true, "idempotent_done_no_doubled_marks": true,
                                    "cancel_preserves_saved_annotations": true, "draft_preserved": true,
                                    "saved_document": saved_document, "saved_attachment": saved_state,
                                    "geometry": geometry_checks,
                                }));
                                native.update(cx, |_, window, _| window.remove_window())?;
                                active = None;
                            }
                        }
                        anyhow::ensure!(captures.len() == 28, "incomplete Markup/Comment capture matrix");
                        std::fs::write(output.join("result.json"), serde_json::to_vec_pretty(&serde_json::json!({
                            "synthetic": true, "platform": "macOS", "engine_requests": 0,
                            "source": "literal geometric portrait test board", "source_size": [720, 1600],
                            "background": "synthetic native conversation and real Composer with a retained draft",
                            "production_components": ["Composer", "PreviewImage", "AnnotateEditor"],
                            "stages": ["preview", "color", "pen-width-rest", "pen-width", "eraser-width", "comment", "reopened"],
                            "text_entry": "production editor text-input helper after real native comment-pin click",
                            "draft_restoration": "not exercised here; native fixture checks current draft through Done and Cancel",
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
    eprintln!("This Markup/Comment review fixture is macOS-only.");
}
