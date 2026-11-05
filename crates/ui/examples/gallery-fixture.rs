//! Native gallery comparison using synthetic cached images and isolated data.
//! Run: gallery-fixture <output-directory>. No engine or model requests are sent.
#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, point, px, size};
    use harness_ui::transcript::gallery_fixture::GalleryReview;
    use harness_ui::{appearance, icons, settings, theme, theme_library, typography};
    use std::{
        path::PathBuf,
        sync::{Arc, Mutex},
        time::Duration,
    };

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
        typography::init(preferences.ui_font_family.clone(), preferences.ui_font_size,
            preferences.terminal_font_family.clone(), preferences.terminal_font_size,
            preferences.code_font_family.clone(), preferences.code_font_size, fonts, cx);
        theme_library::init(data.path().to_path_buf(), cx);
        appearance::init(appearance::AppearanceMode::Light, preferences.theme_selection, preferences.accent, preferences.surface, cx);
        cx.spawn(async move |cx| {
            let _keep_data = data;
            let mut active: Option<gpui::AnyWindowHandle> = None;
            let run: anyhow::Result<()> = async {
                let mut captures = Vec::new();
                for (tone, look, mode) in [
                    ("light", theme::Appearance::Light, appearance::AppearanceMode::Light),
                    ("dark", theme::Appearance::Dark, appearance::AppearanceMode::Dark),
                ] {
                    cx.update(|cx| {
                        appearance::set_theme(look, format!("warm-harp-{tone}"), cx);
                        appearance::set_mode(mode, cx);
                    });
                    let window = cx.update(|cx| cx.open_window(WindowOptions {
                        focus: false,
                        window_background: theme::Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(24.0), px(48.0)), size(px(1200.0), px(760.0))))),
                        titlebar: None,
                        ..Default::default()
                    }, |window, cx| {
                        window.set_rem_size(px(preferences.ui_font_size.pixels()));
                        cx.new(GalleryReview::new)
                    }))?;
                    let native_window: gpui::AnyWindowHandle = window.into();
                    active = Some(native_window);
                    for (phase, width, height) in [
                        ("comparison", 1200., 760.), ("gallery", 620., 640.),
                        ("selected", 620., 640.), ("boundary", 620., 1040.),
                        ("single", 620., 640.), ("loading", 620., 640.), ("unavailable", 620., 640.),
                        ("recovered", 620., 640.), ("gallery-narrow", 420., 640.),
                        ("save-partial", 620., 640.),
                        ("lightbox", 1200., 760.),
                    ] {
                        native_window.update(cx, |_, window, _| window.resize(size(px(width), px(height))))?;
                        window.update(cx, |view, window, cx| view.set_phase(phase, window, cx))?;
                        // Two bounded thumbnail jobs run at a time. Let their
                        // notifications repaint all four synthetic previews.
                        cx.background_executor().timer(Duration::from_millis(900)).await;
                        let name = format!("gallery-{tone}-{phase}.png");
                        let path = output.join(&name);
                        // Drawing re-enters the root view's Render implementation.
                        // An untyped handle avoids holding its mutable entity borrow.
                        native_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            window.render_to_image()?.save(path)?;
                            Ok(())
                        })??;
                        captures.push(name);
                    }
                    native_window.update(cx, |_, window, _| window.remove_window())?;
                    active = None;
                }
                std::fs::write(output.join("result.json"), serde_json::to_vec_pretty(&serde_json::json!({
                    "synthetic":true,"engine_requests":0,"boundary_groups_asserted":true,"captures":captures
                }))?)?;
                Ok(())
            }.await;
            if let Err(err) = run { *failure.lock().unwrap() = Some(format!("{err:#}")); }
            if let Some(window) = active { let _ = window.update(cx, |_, window, _| window.remove_window()); }
            cx.update(|cx| cx.quit());
        }).detach();
    });
    if let Some(error) = error.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This reconciliation fixture is macOS-only.");
}
