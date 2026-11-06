//! Native disclosure and tool-summary interaction using synthetic cached images.
//! Run: viewed-image-fixture <output-directory>. No engine or model requests.
#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    use gpui::{
        AnyWindowHandle, AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, point, px, size,
    };
    use harness_ui::transcript::ViewedImageReview;
    use harness_ui::{appearance, icons, settings, theme, theme_library, typography};
    use std::{
        path::PathBuf,
        sync::{Arc, Mutex},
        time::Duration,
    };

    fn click(handle: AnyWindowHandle, selector: &str, cx: &mut AsyncApp) -> anyhow::Result<()> {
        handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            let bounds = window
                .debug_bounds(selector)
                .ok_or_else(|| anyhow::anyhow!("missing {selector}"))?;
            let view = window.viewport_size();
            anyhow::ensure!(
                bounds.left() >= px(0.)
                    && bounds.top() >= px(0.)
                    && bounds.right() <= view.width
                    && bounds.bottom() <= view.height,
                "{selector} outside viewport: {bounds:?}"
            );
            let position = bounds.center();
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
            window.dispatch_event(
                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                    position,
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
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let error = Arc::new(Mutex::new(None));
    let failure = error.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let mut preferences = settings::UiSettings::default();
        preferences.ui_font_family = typography::UiFontFamily::System;
        settings::init(preferences.clone(), data.path(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(preferences.ui_font_family.clone(), preferences.ui_font_size, preferences.terminal_font_family.clone(), preferences.terminal_font_size, preferences.code_font_family.clone(), preferences.code_font_size, fonts, cx);
        theme_library::init(data.path().to_path_buf(), cx);
        appearance::init(appearance::AppearanceMode::Light, preferences.theme_selection, preferences.accent, preferences.surface, cx);
        cx.spawn(async move |cx| {
            let _keep_data = data;
            let mut active: Option<AnyWindowHandle> = None;
            let run: anyhow::Result<()> = async {
                let mut captures = Vec::new();
                for (tone, look, mode) in [("light", theme::Appearance::Light, appearance::AppearanceMode::Light), ("dark", theme::Appearance::Dark, appearance::AppearanceMode::Dark)] {
                    cx.update(|cx| {
                        appearance::set_theme(look, format!("warm-harp-{tone}"), cx);
                        appearance::set_mode(mode, cx);
                    });
                    for (width_name, width) in [("normal", 900.), ("narrow", 420.)] {
                        let window = cx.update(|cx| cx.open_window(WindowOptions {
                            focus:false, titlebar:None, window_background:theme::Theme::of(cx).window_background_appearance(),
                            window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(24.),px(48.)),size(px(width),px(900.))))), ..Default::default()
                        }, |window,cx| { window.set_rem_size(px(preferences.ui_font_size.pixels())); cx.new(ViewedImageReview::new) }))?;
                        let native: AnyWindowHandle = window.into();
                        active = Some(native);
                        for phase in ["closed", "expanded", "preview", "tools-closed", "tools-expanded", "results", "unavailable"] {
                            match phase {
                                "expanded" => click(native, "transcript-viewed-image-toggle", cx)?,
                                "preview" => click(native, "transcript-viewed-image-thumbnail", cx)?,
                                "tools-closed" => window.update(cx, |view, _, cx| view.set_phase("tools", cx))?,
                                "tools-expanded" => click(native, "transcript-tool-group-header", cx)?,
                                "results" | "unavailable" => window.update(cx, |view, _, cx| view.set_phase(phase, cx))?,
                                _ => {}
                            }
                            cx.background_executor().timer(Duration::from_millis(800)).await;
                            native.update(cx, |_,window,cx|window.draw(cx).clear())?;
                            window.update(cx, |view, _, cx| match phase {
                                "closed" => view.assert_disclosure(false,cx),
                                "expanded" => view.assert_disclosure(true,cx),
                                "preview" => view.assert_preview(true,cx),
                                "tools-closed" => view.assert_tools(false,cx),
                                "tools-expanded" => view.assert_tools(true,cx),
                                _ => {}
                            })?;
                            let name = format!("viewed-{tone}-{width_name}-{phase}.png");
                            let path = output.join(&name);
                            native.update(cx,|_,window,cx|->anyhow::Result<()> { window.draw(cx).clear(); window.render_to_image()?.save(path)?; Ok(()) })??;
                            captures.push(name);
                            if phase == "preview" {
                                native.update(cx, |_,window,cx| {
                                    window.dispatch_event(gpui::PlatformInput::KeyDown(gpui::KeyDownEvent { keystroke:gpui::Keystroke::parse("escape").unwrap(), is_held:false, prefer_character_input:false }),cx);
                                })?;
                                cx.background_executor().timer(Duration::from_millis(60)).await;
                                window.update(cx,|view,_,cx|view.assert_preview(false,cx))?;
                            }
                        }
                        native.update(cx,|_,window,_|window.remove_window())?;
                        active = None;
                    }
                }
                std::fs::write(output.join("result.json"),serde_json::to_vec_pretty(&serde_json::json!({"synthetic":true,"engine_requests":0,"pointer_disclosure_and_viewer":true,"escape_closes_preview":true,"annotation_hook_preserved":true,"live_tools_default_closed":true,"explicit_tool_expansion":true,"captures":captures}))?)?;
                Ok(())
            }.await;
            if let Err(error) = run { *failure.lock().unwrap() = Some(format!("{error:#}")); }
            if let Some(window) = active { let _ = window.update(cx,|_,window,_|window.remove_window()); }
            cx.update(|cx|cx.quit());
        }).detach();
    });
    if let Some(error) = error.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This fixture is macOS-only.");
}
