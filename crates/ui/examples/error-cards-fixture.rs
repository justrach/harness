//! Error cards with Log in, with isolated data: a run refused because the agent is signed out,
//! one that hit its usage limit, and a plain failure. Nothing here starts a real sign-in.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example error-cards-fixture -- <dir> [light]`
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

const CHAT: &str = "error-cards-fixture";

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

fn frame() -> harness_doc::TranscriptFrame {
    let user = |id: &str, at: i64, text: &str| {
        serde_json::json!({
            "id": id, "role": "user", "createdAt": at, "deviceId": "fixture",
            "parts": [{"id": "t0", "kind": "text", "text": text}]
        })
    };
    let error = |id: &str, at: i64, message: &str| {
        serde_json::json!({
            "id": id, "role": "assistant", "createdAt": at, "deviceId": "fixture",
            "status": "aborted",
            "parts": [{"id": "e1", "kind": "error", "message": message}]
        })
    };
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            user("user-1", 0, "Add a retry to the upload step."),
            error("assistant-1", 1, "Not logged in \u{b7} Please run /login"),
            user("user-2", 2, "Signed in, try again."),
            error(
                "assistant-2",
                3,
                "Claude usage limit reached \u{2014} try again after the limit resets.",
            ),
            user("user-3", 4, "And once more."),
            error(
                "assistant-3",
                5,
                "Claude Code exited with status 1: the upload test crashed",
            ),
        ]))
        .unwrap(),
    }
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let light = std::env::args().nth(2).as_deref() == Some("light");
    let suffix = if light { "light" } else { "dark" };
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
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, None)?;
    core.workspace.rename_chat(CHAT, "Upload retries")?;
    let ipc_port = std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port();
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
        default_harness: harness_proto::HarnessId::Mock,
    };
    let engine = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let mut chats = core.workspace.read_chats()?;
    for chat in &mut chats {
        // "Log in" routes by the chat's own agent.
        chat.config = Some(harness_proto::ChatConfig {
            harness: harness_proto::HarnessId::ClaudeCode,
            model: Some("fixture-model".into()),
            reasoning: None,
            model_options: Default::default(),
            sandbox: harness_proto::SandboxLevel::WorkspaceWrite,
            chat_mode: false,
        });
    }
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
                if light {
                    appearance::AppearanceMode::Light
                } else {
                    appearance::AppearanceMode::Dark
                },
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            composer::init(cx, settings.composer_send_behavior);
            terminal::panel::init(cx);
            app_menus::init(cx);
            let state = cx.new(|_| {
                let mut s = state::AppState::new();
                s.fixture_attachment_engine(engine);
                s.connection = harness_proto::view::ConnectionStatus::Ready;
                s.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                s.no_project = true;
                s.local_device_id = Some(device.clone());
                s.devices = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": device, "name": "Studio", "platform": std::env::consts::OS,
                        "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
                s.chats = chats;
                s.selected_chat = Some(CHAT.into());
                s.auto_selected = true;
                s.chats_synced = true;
                s.spaces_synced = true;
                s
            });
            let window = cx
                .open_window(
                    WindowOptions {
                        window_background: theme::Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.), px(40.)),
                            size(px(1100.), px(820.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
                )
                .unwrap();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    pause(cx, 1500).await;
                    state.update(cx, |state, cx| state.receive_transcript_frame(frame(), cx))?;
                    pause(cx, 900).await;
                    capture(window.into(), cx, &output, &format!("error-cards-{suffix}"))?;
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
