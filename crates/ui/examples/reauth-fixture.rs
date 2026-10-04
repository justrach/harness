//! In-chat ChatGPT reconnect evidence with isolated data. Renders the recovery card in each step
//! by setting the recovery state directly; nothing here starts a real sign-in.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example reauth-fixture -- <dir> [light]`
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_proto::{AgentLoginMode, AgentLoginStart, ReauthProvider};
use harness_ui::reauth_recovery::{ReauthKey, ReauthRow, RecoveryPhase};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

const CHAT: &str = "reauth-fixture";

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
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {
                "id": "user-1", "role": "user", "createdAt": 0, "deviceId": "fixture",
                "parts": [{"id": "t0", "kind": "text", "text": "Add a retry to the upload step."}]
            },
            {
                "id": "assistant-1", "role": "assistant", "createdAt": 1, "deviceId": "fixture",
                "status": "aborted",
                "parts": [
                    {"id": "t0", "kind": "text", "text": "I'll look at the upload step first."},
                    {"id": "e1", "kind": "error", "reauth": "chatgpt-new",
                     "message": "chatgpt-new api error [token_expired]: Provided authentication token is expired."}
                ]
            }
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
        // Resume needs the chat's own agent and model.
        chat.config = Some(harness_proto::ChatConfig {
            harness: harness_proto::HarnessId::Graff,
            model: Some("chatgpt-model".into()),
            reasoning: None,
            model_options: Default::default(),
            sandbox: harness_proto::SandboxLevel::WorkspaceWrite,
        });
    }
    let device = core.device_id.clone();
    let key = ReauthKey {
        host: device.clone(),
        provider: ReauthProvider::ChatgptNew,
    };
    let row = ReauthRow {
        chat_id: CHAT.into(),
        row_id: "assistant-1#e1".into(),
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
                    capture(
                        window.into(),
                        cx,
                        &output,
                        &format!("reauth-1-offer-{suffix}"),
                    )?;
                    let steps: Vec<(&str, Box<dyn Fn(&mut state::AppState)>)> = vec![
                        (
                            "reauth-2-starting",
                            Box::new({
                                let (key, row) = (key.clone(), row.clone());
                                move |s| {
                                    s.reauth.request(&key, row.clone());
                                }
                            }),
                        ),
                        (
                            "reauth-3-waiting-host-browser",
                            Box::new({
                                let key = key.clone();
                                move |s| {
                                    s.reauth.set(
                                        &key,
                                        RecoveryPhase::Waiting {
                                            start: AgentLoginStart {
                                                login_id: "fixture".into(),
                                                url: String::new(),
                                                mode: AgentLoginMode::HostBrowser,
                                                code: None,
                                            },
                                            message: None,
                                        },
                                    )
                                }
                            }),
                        ),
                        (
                            "reauth-4-waiting-device-code",
                            Box::new({
                                let key = key.clone();
                                move |s| {
                                    s.reauth.set(
                                        &key,
                                        RecoveryPhase::Waiting {
                                            start: AgentLoginStart {
                                                login_id: "fixture".into(),
                                                url: "https://auth.openai.com/codex/device".into(),
                                                mode: AgentLoginMode::DeviceCode,
                                                code: Some("ABCD-EFGH".into()),
                                            },
                                            message: None,
                                        },
                                    )
                                }
                            }),
                        ),
                        (
                            "reauth-5-failed",
                            Box::new({
                                let key = key.clone();
                                move |s| {
                                    s.reauth.set(
                                        &key,
                                        RecoveryPhase::Failed(
                                            "Sign-in failed. Try again on the chat's computer."
                                                .into(),
                                        ),
                                    )
                                }
                            }),
                        ),
                        (
                            "reauth-6-reconnected",
                            Box::new({
                                let (key, row) = (key.clone(), row.clone());
                                move |s| {
                                    s.reauth.request(&key, row.clone());
                                    s.reauth.set(&key, RecoveryPhase::Reconnected);
                                }
                            }),
                        ),
                    ];
                    for (name, apply) in steps {
                        state.update(cx, |s, cx| {
                            apply(s);
                            cx.notify();
                        });
                        pause(cx, 700).await;
                        capture(window.into(), cx, &output, &format!("{name}-{suffix}"))?;
                    }
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
