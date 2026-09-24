//! Isolated, synthetic README captures rendered by the production desktop shell.
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor().timer(Duration::from_millis(ms)).await;
}

fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    directory: &std::path::Path,
    name: &str,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, cx| {
        window.draw(cx).clear();
        window.render_to_image()?.save(directory.join(format!("{name}.png")))?;
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
            harness_proto::HarnessId::Graff,
            None,
        )
    })?;
    core.workspace
        .create_chat(
            "readme-fixture",
            None,
            Some(&core.device_id),
            Some(serde_json::from_value(serde_json::json!({
                "harness": "graff",
                "model": "gpt-6-sol",
                "reasoning": null,
                "modelOptions": {},
                "sandbox": "workspace-write"
            }))?),
            None,
        )?;
    core.workspace
        .rename_chat("readme-fixture", "Build a release checklist")?;
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
        default_harness: harness_proto::HarnessId::Graff,
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
        theme_library::init(data.clone(), cx);
        appearance::init(
            appearance::AppearanceMode::Dark,
            settings.theme_selection,
            settings.accent,
            settings.surface,
            cx,
        );
        history::init(
            settings.git_history_columns,
            settings.git_history_column_widths,
            settings.git_history_column_order,
            settings.git_history_author_display,
            cx,
        );
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.fixture_attachment_engine(handle);
            state.connection = harness_proto::view::ConnectionStatus::Ready;
            state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
            state.no_project = true;
            state.local_device_id = Some(device.clone());
            state.devices = vec![serde_json::from_value(serde_json::json!({
                "id": device,
                "name": "This device",
                "platform": std::env::consts::OS,
                "lastSeenAt": null
            }))
            .unwrap()];
            state.chats = chats;
            state.selected_chat = Some("readme-fixture".into());
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state
        });
        let window = cx
            .open_window(
                WindowOptions {
                    window_background: theme::Theme::of(cx).window_background_appearance(),
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(20.), px(40.)),
                        size(px(1200.), px(760.)),
                    ))),
                    ..Default::default()
                },
                |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
            )
            .unwrap();
        state.update(cx, |_, cx| cx.notify());
        cx.activate(true);
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                pause(cx, 1000).await;
                state.update(cx, |state, cx| {
                    state
                        .receive_transcript_frame(
                            harness_doc::TranscriptFrame::Reset {
                                reset: serde_json::from_value(serde_json::json!([
                                    {
                                        "id": "user",
                                        "role": "user",
                                        "parts": [{"id": "text", "kind": "text", "text": "Help me prepare a release checklist for Harness."}],
                                        "createdAt": 1788900000000_i64,
                                        "deviceId": device
                                    },
                                    {
                                        "id": "assistant",
                                        "role": "assistant",
                                        "parts": [{"id": "text", "kind": "text", "text": "## Release checklist\n\n1. Review the changes and confirm the version.\n2. Build and sign the macOS app.\n3. Notarize the app and DMG, then check a fresh launch."}],
                                        "createdAt": 1788900001000_i64,
                                        "deviceId": device,
                                        "status": "complete"
                                    }
                                ]))
                                .unwrap(),
                            },
                            cx,
                        )
                        .unwrap();
                    cx.notify();
                });
                pause(cx, 600).await;
                capture(window.into(), cx, &output, "codegraff-chat-dark")?;
                window.update(cx, |shell, _, cx| shell.fixture_readme_agents_settings(cx))?;
                pause(cx, 5000).await;
                capture(window.into(), cx, &output, "codegraff-agents-dark")?;
                Ok(())
            }
            .await;
            if let Err(error) = run {
                eprintln!("README fixture failed: {error:#}");
                *result.lock().unwrap() = Some(format!("{error:#}"));
            }
            let _ = window.update(cx, |_, window, _| window.remove_window());
            pause(cx, 100).await;
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
