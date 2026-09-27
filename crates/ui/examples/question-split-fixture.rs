//! Stress captures of agent questions in the production shell, with isolated synthetic data.
//! cargo run -p harness-ui --example question-split-fixture --features appshots-fixture -- OUT_DIR
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor().timer(Duration::from_millis(ms)).await;
}

fn question_frame() -> harness_doc::TranscriptFrame {
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([{
            "id": "stress-assistant", "role": "assistant",
            "parts": [{
                "id": "stress-input", "kind": "input", "requestId": "stress-question",
                "questions": [
                    {
                        "id": "approach", "header": "Agent question",
                        "question": "Which approach should we use to keep the agent question readable when the session pane becomes narrow?",
                        "options": ["Wrap the question and its options to fit the session pane.", "Keep the existing behavior and review another approach."],
                        "multiSelect": false
                    },
                    {
                        "id": "confirm", "header": "Confirmation",
                        "question": "Would you like to continue?",
                        "options": ["Yes", "No"], "multiSelect": false
                    }
                ], "resolved": false
            }],
            "createdAt": 0, "deviceId": "preview", "status": "streaming"
        }])).unwrap(),
    }
}

fn capture(
    handle: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    directory: &std::path::Path,
    name: &str,
) -> anyhow::Result<()> {
    handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        window.render_to_image()?.save(directory.join(format!("{name}.png")))?;
        Ok(())
    })?
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
            harness_proto::HarnessId::Mock,
            None,
        )
    })?;
    for index in 1..=8 {
        let id = format!("stress-{index}");
        core.workspace.create_chat(&id, None, Some(&core.device_id), None, None)?;
        core.workspace.rename_chat(&id, &format!("Session {index}"))?;
    }
    let ipc_port = std::net::TcpListener::bind("127.0.0.1:0")?.local_addr()?.port();
    let _ipc = runtime.block_on(harness_engine::serve_ipc(ipc_port, core.rpc_service()))?;
    let data = temp.path().join("ui");
    std::fs::create_dir(&data)?;
    let boot = EngineBootConfig {
        data_dir: data.clone(), ipc_port, edge_url: String::new(),
        edge_token: None, org_id: None, codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::Mock,
    };
    let engine = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
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
            settings.ui_font_family.clone(), settings.ui_font_size,
            settings.terminal_font_family.clone(), settings.terminal_font_size,
            settings.code_font_family.clone(), settings.code_font_size, fonts, cx,
        );
        theme_library::init(data.clone(), cx);
        appearance::init(
            appearance::AppearanceMode::Dark, settings.theme_selection,
            settings.accent, settings.surface, cx,
        );
        history::init(Default::default(), Default::default(), Default::default(), Default::default(), cx);
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.fixture_attachment_engine(engine);
            state.connection = harness_proto::view::ConnectionStatus::Ready;
            state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
            state.no_project = true;
            state.local_device_id = Some(device.clone());
            state.devices = vec![serde_json::from_value(serde_json::json!({
                "id": device, "name": "Preview device", "platform": std::env::consts::OS,
                "lastSeenAt": null
            })).unwrap()];
            state.chats = chats;
            state.selected_chat = Some("stress-1".into());
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state
        });
        let window = cx.open_window(
            WindowOptions {
                window_background: theme::Theme::of(cx).window_background_appearance(),
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(20.), px(40.)), size(px(1440.), px(900.)),
                ))),
                ..Default::default()
            },
            |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
        ).unwrap();
        state.update(cx, |_, cx| cx.notify());
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                pause(cx, 1200).await;
                for count in 1..=8 {
                    if count > 1 {
                        window.update(cx, |shell, window, cx| {
                            shell.fixture_onboarding_split(true, window, cx);
                        })?;
                        state.update(cx, |state, cx| state.select_chat(Some(format!("stress-{count}")), cx));
                    }
                    pause(cx, 500).await;
                    state.update(cx, |state, cx| state.receive_transcript_frame(question_frame(), cx))?;
                    pause(cx, 500).await;
                    if [1, 2, 4, 8].contains(&count) {
                        capture(window.into(), cx, &output, &format!("shell-{count}-panes-1440"))?;
                    }
                }
                // Eight equal panes under tighter desktop viewports.
                for width in [1200, 1000, 800] {
                    let handle: gpui::AnyWindowHandle = window.into();
                    handle.update(cx, |_, window, _| window.resize(size(px(width as f32), px(900.))))?;
                    pause(cx, 700).await;
                    capture(window.into(), cx, &output, &format!("shell-8-panes-{width}"))?;
                }
                // Tabs are not splits: eight tabs still give the active session the full column.
                window.update(cx, |shell, window, cx| {
                    window.resize(size(px(1440.), px(900.)));
                    for _ in 0..7 {
                        shell.fixture_onboarding_split(false, window, cx);
                    }
                })?;
                for index in 2..=8 {
                    window.update(cx, |shell, window, cx| shell.fixture_chat_tab(None, window, cx))?;
                    state.update(cx, |state, cx| state.select_chat(Some(format!("stress-{index}")), cx));
                    pause(cx, 120).await;
                }
                pause(cx, 600).await;
                state.update(cx, |state, cx| state.receive_transcript_frame(question_frame(), cx))?;
                pause(cx, 600).await;
                capture(window.into(), cx, &output, "shell-8-tabs-1440")?;
                Ok(())
            }.await;
            if let Err(error) = run {
                *result.lock().unwrap() = Some(format!("{error:#}"));
            }
            let _ = window.update(cx, |_, window, _| window.remove_window());
            cx.update(|cx| cx.quit());
        }).detach();
    });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
