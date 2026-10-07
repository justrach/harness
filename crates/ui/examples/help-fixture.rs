//! `/help` evidence with isolated data: runs the workspace command and captures
//! Settings → Shortcuts, including the fixed (non-rebindable) shortcuts.
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    directory: &std::path::Path,
    name: &str,
) -> anyhow::Result<()> {
    window.update(cx, |_, w, cx| {
        w.draw(cx).clear();
        w.render_to_image()?
            .save(directory.join(format!("{name}.png")))?;
        Ok(())
    })?
}

fn port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::ClaudeCode,
            None,
        )
    })?;
    core.workspace
        .create_chat("help-fixture", None, Some(&core.device_id), None, None)?;
    core.workspace
        .rename_chat("help-fixture", "Keyboard shortcuts")?;
    let ipc_port = port();
    let _ipc = runtime.block_on(harness_engine::serve_ipc(ipc_port, core.rpc_service()))?;
    let data = temp.path().join("ui");
    std::fs::create_dir(&data)?;
    let boot = EngineBootConfig {
        data_dir: data.clone(),
        ipc_port,
        edge_url: String::new(),
        edge_token: None,
        org_id: None,
        codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::ClaudeCode,
    };
    let handle = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let chats = core.workspace.read_chats()?;
    let device = core.device_id.clone();
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let settings = settings::UiSettings::default();
        settings::init(settings.clone(), data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(settings.ui_font_family.clone(), settings.ui_font_size, settings.terminal_font_family.clone(), settings.terminal_font_size, settings.code_font_family.clone(), settings.code_font_size, fonts, cx);
        theme_library::init(data.clone(), cx);
        appearance::init(appearance::AppearanceMode::Dark, settings.theme_selection, settings.accent, settings.surface, cx);
        history::init(settings.git_history_columns, settings.git_history_column_widths, settings.git_history_column_order, settings.git_history_author_display, cx);
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut s = state::AppState::new();
            s.fixture_attachment_engine(handle);
            s.connection = harness_proto::view::ConnectionStatus::Ready;
            s.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
            s.local_device_id = Some(device.clone());
            s.devices = vec![serde_json::from_value(serde_json::json!({"id": device, "name": "This device", "platform": std::env::consts::OS, "lastSeenAt": null})).unwrap()];
            s.chats = chats;
            s.selected_chat = Some("help-fixture".into());
            s.auto_selected = true;
            s.chats_synced = true;
            s.spaces_synced = true;
            s
        });
        let window = cx
            .open_window(
                WindowOptions {
                    window_background: theme::Theme::of(cx).window_background_appearance(),
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(gpui::point(px(20.), px(40.)), size(px(1100.), px(900.))))),
                    ..Default::default()
                },
                |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
            )
            .unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                pause(cx, 1500).await;
                state.update(cx, |_, cx| cx.notify());
                // The real `/help` path: the workspace command, as the composer issues it.
                window.update(cx, |s, _, cx| s.fixture_help(cx))?;
                pause(cx, 900).await;
                capture(window.into(), cx, &output, "help-shortcuts-top")?;
                // Scroll to the end of the page, where the fixed shortcuts are.
                for step in 0..12 {
                    if step == 6 || step == 8 {
                        pause(cx, 400).await;
                        capture(window.into(), cx, &output, &format!("help-shortcuts-scroll-{step}"))?;
                    }
                    window.update(cx, |_, w, cx| {
                        w.dispatch_event(
                            gpui::PlatformInput::ScrollWheel(gpui::ScrollWheelEvent {
                                position: gpui::point(px(700.), px(500.)),
                                delta: gpui::ScrollDelta::Pixels(gpui::point(px(0.), px(-400.))),
                                ..Default::default()
                            }),
                            cx,
                        );
                    })?;
                    pause(cx, 60).await;
                }
                pause(cx, 500).await;
                capture(window.into(), cx, &output, "help-shortcuts-bottom")?;
                Ok(())
            }
            .await;
            *result.lock().unwrap() = run.err();
            let _ = window.update(cx, |_, w, _| w.remove_window());
            pause(cx, 100).await;
            let _ = cx.update(|cx| cx.quit());
        })
        .detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
