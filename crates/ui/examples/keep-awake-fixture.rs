//! Synthetic screenshots of the production keep-awake settings row.
//! No engine is started; toggling the fixture cannot acquire a power assertion.
//! Usage: keep-awake-fixture <output-directory> [light|dark]
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, point, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

async fn pause(cx: &mut AsyncApp) {
    cx.background_executor()
        .timer(Duration::from_millis(250))
        .await;
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).ok_or_else(|| {
        anyhow::anyhow!("usage: keep-awake-fixture <output-directory> [light|dark]")
    })?);
    let dark = std::env::args().nth(2).as_deref() == Some("dark");
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let data = temp.path().join("ui");
    std::fs::create_dir(&data)?;
    let boot = EngineBootConfig {
        data_dir: data.clone(),
        ipc_port: 0,
        edge_url: String::new(),
        edge_token: None,
        org_id: None,
        codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::Graff,
    };
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
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
            appearance::set_theme(theme::Appearance::Light, "warm-harp-light", cx);
            appearance::set_theme(theme::Appearance::Dark, "warm-harp-dark", cx);
            let state = cx.new(|_| state::AppState::new());
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    for &(case, label) in menu_review::CASES
                        .iter()
                        .filter(|(case, _)| case.starts_with("keep-awake-"))
                    {
                        let window: gpui::AnyWindowHandle = cx
                            .update(|cx| {
                                cx.open_window(
                                    WindowOptions {
                                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                                            point(px(30.), px(40.)),
                                            size(px(900.), px(420.)),
                                        ))),
                                        titlebar: None,
                                        ..Default::default()
                                    },
                                    |window, cx| {
                                        window.set_rem_size(px(16.));
                                        cx.new(|cx| {
                                            menu_review::MenuReview::new(
                                                case,
                                                label,
                                                state.clone(),
                                                boot.clone(),
                                                cx,
                                            )
                                        })
                                    },
                                )
                            })?
                            .into();
                        pause(cx).await;
                        window.update(cx, |_, window, cx| {
                            window.refresh();
                            window.draw(cx).clear();
                        })?;
                        pause(cx).await;
                        window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            let tone = if dark { "dark" } else { "light" };
                            window
                                .render_to_image()?
                                .save(output.join(format!("{case}-{tone}.png")))?;
                            Ok(())
                        })??;
                        window.update(cx, |_, window, _| window.remove_window())?;
                    }
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err();
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
