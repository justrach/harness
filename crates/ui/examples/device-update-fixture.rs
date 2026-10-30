//! Synthetic Devices-page evidence; no engine, credentials or real devices.
//! `cargo run -p harness-ui --features appshots-fixture --example device-update-fixture -- OUT`
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::{appearance, composer, icons, settings, state, theme, theme_library, typography};
use harness_update::{HostUpdateMode, HostUpdatePhase, HostUpdateStatus, UpdateStatus};
use std::{path::PathBuf, sync::Arc, time::Duration};

fn status(phase: HostUpdatePhase) -> UpdateStatus {
    UpdateStatus {
        current_version: "0.2.132".into(),
        latest_version: Some("0.2.142".into()),
        update_available: true,
        checked_at: Some(chrono::Utc::now().timestamp_millis()),
        error: None,
        host: Some(HostUpdateStatus {
            mode: HostUpdateMode::Managed,
            automatic: true,
            phase,
        }),
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let config = settings::UiSettings::default();
            settings::init(config.clone(), temp.path().to_path_buf(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                config.ui_font_family.clone(),
                config.ui_font_size,
                config.terminal_font_family.clone(),
                config.terminal_font_size,
                config.code_font_family.clone(),
                config.code_font_size,
                fonts,
                cx,
            );
            theme_library::init(temp.path().to_path_buf(), cx);
            appearance::init(
                appearance::AppearanceMode::Dark,
                config.theme_selection,
                config.accent,
                config.surface,
                cx,
            );
            composer::init(cx, config.composer_send_behavior);
            let now = chrono::Utc::now();
            let state =
                cx.new(|_| {
                    let mut state = state::AppState::new();
                    state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                    state.local_device_id = Some("fixture-desktop".into());
                    state.update = Some(UpdateStatus {
                        current_version: "0.2.142".into(),
                        update_available: false,
                        ..status(HostUpdatePhase::Idle)
                    });
                    state.devices =
                        vec![
                serde_json::from_value(serde_json::json!({
                    "id": "fixture-desktop", "name": "Desktop", "platform": "macos",
                    "version": "0.2.142", "lastSeenAt": now,
                })).unwrap(),
                serde_json::from_value(serde_json::json!({
                    "id": "fixture-server", "name": "Build server", "platform": "linux",
                    "version": "0.2.132", "lastSeenAt": now,
                })).unwrap(),
                serde_json::from_value(serde_json::json!({
                    "id": "fixture-offline", "name": "Office PC", "platform": "windows",
                    "version": "0.2.118", "lastSeenAt": now - chrono::TimeDelta::hours(2),
                })).unwrap(),
            ];
                    state
                });
            let window = cx
                .open_window(
                    WindowOptions {
                        window_background: theme::Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(40.), px(40.)),
                            size(px(900.), px(700.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| settings::devices::DevicesPage::new(state, cx)),
                )
                .unwrap();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    for (name, snapshot) in [
                        ("before", None),
                        ("available", Some(status(HostUpdatePhase::Idle))),
                        ("waiting", Some(status(HostUpdatePhase::WaitingForIdle))),
                    ] {
                        window.update(cx, |page, _, cx| {
                            page.fixture_remote_update("fixture-server", snapshot, cx)
                        })?;
                        cx.background_executor()
                            .timer(Duration::from_millis(500))
                            .await;
                        // Drawing must not hold the root view's mutable borrow.
                        let capture: gpui::AnyWindowHandle = window.into();
                        capture.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            window
                                .render_to_image()?
                                .save(output.join(format!("device-update-{name}.png")))?;
                            Ok(())
                        })??;
                    }
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    *result.lock().unwrap() = Some(error.to_string());
                }
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
