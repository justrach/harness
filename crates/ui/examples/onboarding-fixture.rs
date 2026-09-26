//! Onboarding QA captures rendered offscreen by the production shell: the
//! first-run screen, a starter prompt, the new-session canvas, a ⌘D split,
//! the Screen Recording notice and the Agents settings row.
//!
//!   cargo run -p harness-ui --example onboarding-fixture --features appshots-fixture -- OUT_DIR
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
    window.update(cx, |_, window, cx| {
        window.draw(cx).clear();
        window
            .render_to_image()?
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
    core.workspace.create_chat(
        "onboarding-chat",
        None,
        Some(&core.device_id),
        Some(serde_json::from_value(serde_json::json!({
            "harness": "claude-code",
            "model": "claude-opus-5-5",
            "reasoning": null,
            "modelOptions": {},
            "sandbox": "workspace-write"
        }))?),
        None,
    )?;
    core.workspace
        .rename_chat("onboarding-chat", "Check the landing page layout")?;
    // Three more chats for the ⌘K pane-search scene.
    for (id, title) in [
        ("pane-review", "Code Review And Improvements"),
        ("pane-audit", "Codegraff Login Security Audit"),
        ("pane-xiaomi", "Xiaomi Project Status Check"),
    ] {
        core.workspace.create_chat(
            id,
            None,
            Some(&core.device_id),
            Some(serde_json::from_value(serde_json::json!({
                "harness": "claude-code",
                "model": "claude-opus-5-5",
                "reasoning": null,
                "modelOptions": {},
                "sandbox": "workspace-write"
            }))?),
            None,
        )?;
        core.workspace.rename_chat(id, title)?;
    }
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
            theme_library::init(data.clone(), cx);
            appearance::init(
                appearance::AppearanceMode::Light,
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
            let space: harness_proto::Space = serde_json::from_value(serde_json::json!({
                "id": "space-codedb",
                "deviceId": device,
                "path": "/Users/demo/codedb",
                "gitDetected": false,
                "createdAt": "2026-09-01T00:00:00Z"
            }))
            .unwrap();
            // First run: no projects, nothing picked, nothing selected.
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.fixture_attachment_engine(handle);
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                state.local_device_id = Some(device.clone());
                state.devices = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": device,
                        "name": "MacBook Pro",
                        "platform": std::env::consts::OS,
                        "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
                state.chats = chats;
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
                    pause(cx, 1500).await;
                    capture(window.into(), cx, &output, "01-first-run")?;

                    // A project exists and is picked: the everyday new-session canvas.
                    state.update(cx, |state, cx| {
                        state.spaces = vec![space.clone()];
                        state.selected_space = Some(space.id.clone());
                        state.no_project = false;
                        cx.notify();
                    });
                    pause(cx, 1200).await;
                    capture(window.into(), cx, &output, "02-new-session")?;

                    window.update(cx, |shell, window, cx| {
                        shell.fixture_onboarding_split(true, window, cx)
                    })?;
                    pause(cx, 1200).await;
                    capture(window.into(), cx, &output, "03-split")?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_onboarding_split(false, window, cx)
                    })?;
                    pause(cx, 800).await;

                    window.update(cx, |shell, _, cx| {
                        shell.fixture_onboarding_starter("launch", cx)
                    })?;
                    pause(cx, 1000).await;
                    capture(window.into(), cx, &output, "04-starter-launch")?;

                    state.update(cx, |state, cx| {
                        state.select_chat(Some("onboarding-chat".into()), cx)
                    });
                    pause(cx, 1000).await;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_screen_access_notice("onboarding-chat", false, cx)
                    })?;
                    pause(cx, 800).await;
                    capture(window.into(), cx, &output, "05-screen-notice")?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_screen_access_notice("onboarding-chat", true, cx)
                    })?;
                    pause(cx, 600).await;
                    capture(window.into(), cx, &output, "06-screen-notice-requested")?;

                    // ⌘K across open panes: three chats side by side, search one.
                    for id in ["pane-review", "pane-audit", "pane-xiaomi"] {
                        state.update(cx, |state, cx| state.select_chat(Some(id.into()), cx));
                        pause(cx, 300).await;
                        if id != "pane-xiaomi" {
                            window.update(cx, |shell, window, cx| {
                                shell.fixture_onboarding_split(true, window, cx)
                            })?;
                            pause(cx, 300).await;
                        }
                    }
                    pause(cx, 800).await;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_command_palette(Some("audit"), window, cx)
                    })?;
                    pause(cx, 800).await;
                    capture(window.into(), cx, &output, "08-pane-search")?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_command_palette(None, window, cx)
                    })?;
                    pause(cx, 1000).await;
                    capture(window.into(), cx, &output, "09-pane-jumped")?;
                    // The third ⌘D didn't fit (panes under 380px), so it opened a
                    // tab: the sidebar shows both tabs.
                    capture(window.into(), cx, &output, "10-tabs")?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_chat_tab(None, window, cx)
                    })?;
                    pause(cx, 800).await;
                    capture(window.into(), cx, &output, "11-new-tab")?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_chat_tab(Some(0), window, cx)
                    })?;
                    pause(cx, 800).await;
                    capture(window.into(), cx, &output, "12-back-to-split-tab")?;

                    window.update(cx, |shell, _, cx| shell.fixture_readme_agents_settings(cx))?;
                    pause(cx, 3000).await;
                    capture(window.into(), cx, &output, "07-settings-agents")?;
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    eprintln!("onboarding fixture failed: {error:#}");
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
