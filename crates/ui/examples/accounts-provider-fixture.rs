//! Actual AccountsPage with synthetic provider replies and an isolated profile.
//! Run: accounts-provider-fixture <fixture-provider-states.json> <output-directory>.
//! No engine, credentials, browser navigation, sign-in, or model requests.
#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    use gpui::{
        AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds,
        WindowOptions, div, point, prelude::*, px, size,
    };
    use harness_ui::{
        appearance, composer, icons, settings, state, theme, theme_library, typography,
    };
    use std::{
        path::PathBuf,
        sync::{Arc, Mutex},
        time::Duration,
    };

    struct Frame(Entity<settings::accounts::AccountsPage>);
    impl Render for Frame {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let theme = theme::Theme::of(cx);
            div()
                .size_full()
                .bg(theme.bg)
                .text_color(theme.text)
                .child(self.0.clone())
        }
    }
    let mut args = std::env::args().skip(1);
    let input = PathBuf::from(args.next().expect("fixture-provider-states.json"));
    let output = PathBuf::from(args.next().expect("output directory"));
    let cases: Vec<serde_json::Value> = serde_json::from_slice(&std::fs::read(&input)?)?;
    anyhow::ensure!(cases.len() == 3, "expected the three provider states");
    for case in &cases {
        anyhow::ensure!(
            case["graffLogins"]
                .as_array()
                .is_some_and(|rows| rows.len() == 6),
            "expected six synthetic provider replies"
        );
    }
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
        composer::init(cx, preferences.composer_send_behavior);
        theme_library::init(data.path().to_path_buf(), cx);
        appearance::init(appearance::AppearanceMode::Light, preferences.theme_selection, preferences.accent, preferences.surface, cx);
        cx.spawn(async move |cx| {
            let _keep_data = data;
            let mut active: Option<gpui::AnyWindowHandle> = None;
            let run: anyhow::Result<()> = async {
                let mut captures = Vec::new();
                for (tone, look, mode) in [("light", theme::Appearance::Light, appearance::AppearanceMode::Light), ("dark", theme::Appearance::Dark, appearance::AppearanceMode::Dark)] {
                    cx.update(|cx| {
                        appearance::set_theme(look, format!("warm-harp-{tone}"), cx);
                        appearance::set_mode(mode, cx);
                    });
                    for (width, height) in [(1440., 900.), (980., 700.)] {
                        for case in &cases {
                            let name = case["name"].as_str().ok_or_else(||anyhow::anyhow!("missing synthetic state name"))?;
                            let window = cx.update(|cx| cx.open_window(WindowOptions {
                                focus:false, titlebar:None, window_background:theme::Theme::of(cx).window_background_appearance(),
                                window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(24.),px(48.)),size(px(width),px(height))))), ..Default::default()
                            },|window,cx| {
                                window.set_rem_size(px(preferences.ui_font_size.pixels()));
                                let state = cx.new(|_| state::AppState::new());
                                let page = cx.new(|cx|settings::accounts::AccountsPage::new(state,cx));
                                cx.new(|_|Frame(page))
                            }))?;
                            let native: gpui::AnyWindowHandle = window.into();
                            active = Some(native);
                            window.update(cx,|view,_,cx|view.0.update(cx,|page,cx|page.fixture_provider_snapshot(case,cx)))??;
                            for section in if name == "signed-out" { vec!["top", "providers"] } else { vec!["providers"] } {
                                window.update(cx,|view,_,cx|view.0.update(cx,|page,cx|page.fixture_provider_scroll(if section == "providers" { 420. } else { 0. },cx)))?;
                                cx.background_executor().timer(Duration::from_millis(350)).await;
                                let filename = format!("accounts-{tone}-{width}-{name}-{section}.png");
                                let path = output.join(&filename);
                                native.update(cx,|_,window,cx|->anyhow::Result<()> {
                                    window.draw(cx).clear();
                                    window.render_to_image()?.save(path)?;
                                    Ok(())
                                })??;
                                captures.push(filename);
                            }
                            native.update(cx,|_,window,_|window.remove_window())?;
                            active = None;
                        }
                    }
                }
                std::fs::write(output.join("result.json"),serde_json::to_vec_pretty(&serde_json::json!({"synthetic":true,"engine_requests":0,"auth_actions":0,"renderer":"production AccountsPage","source":input.file_name().and_then(|n|n.to_str()),"captures":captures}))?)?;
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
