//! Synthetic Queue/Steer transcript evidence rendered by the production shell.
//! Uses an isolated EngineCore over local IPC and never sends an agent command.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example queue-steer-fixture -- before 900 <dir>`
//! Modes: `before`, `after-queued`, `after-pending`, `after-confirmed`, `settings`.
//! Widths: `900`, `360`.
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

const CHAT: &str = "queue-steer-fixture";
const QUEUE_ID: &str = "retry-path-follow-up";
const PROMPT: &str = "Check the retry path before continuing.";

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

#[cfg(not(windows))]
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

fn port() -> anyhow::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port())
}

fn base_transcript(device: &str) -> harness_doc::TranscriptFrame {
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {
                "id": "retry-user",
                "role": "user",
                "createdAt": 1788900000000_i64,
                "deviceId": device,
                "parts": [{"id": "retry-user-text", "kind": "text", "text": "Please inspect the retry path in the synthetic project."}]
            },
            {
                "id": "retry-assistant",
                "role": "assistant",
                "createdAt": 1788900001000_i64,
                "deviceId": device,
                "status": "complete",
                "parts": [
                    {"id": "retry-assistant-text", "kind": "text", "text": "I found the retry handler. Checking its edge case now."},
                    {
                        "id": "retry-tool",
                        "kind": "tool",
                        "resolved": true,
                        "output": "Retry state is preserved after a transient failure.",
                        "call": {"kind": "exec", "command": "git diff -- retry-handler.rs"}
                    }
                ]
            }
        ]))
        .unwrap(),
    }
}

fn confirmed_transcript(device: &str) -> harness_doc::TranscriptFrame {
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {
                "id": "retry-user",
                "role": "user",
                "createdAt": 1788900000000_i64,
                "deviceId": device,
                "parts": [{"id": "retry-user-text", "kind": "text", "text": "Please inspect the retry path in the synthetic project."}]
            },
            {
                "id": "retry-assistant",
                "role": "assistant",
                "createdAt": 1788900001000_i64,
                "deviceId": device,
                "status": "complete",
                "parts": [
                    {"id": "retry-assistant-text", "kind": "text", "text": "I found the retry handler. Checking its edge case now."},
                    {
                        "id": "retry-tool",
                        "kind": "tool",
                        "resolved": true,
                        "output": "Retry state is preserved after a transient failure.",
                        "call": {"kind": "exec", "command": "git diff -- retry-handler.rs"}
                    }
                ]
            },
            {
                "id": QUEUE_ID,
                "role": "user",
                "createdAt": 1788900002000_i64,
                "deviceId": device,
                "parts": [{"id": "steer-user-text", "kind": "text", "text": PROMPT}]
            },
            {
                "id": "steer-continuation",
                "role": "assistant",
                "createdAt": 1788900003000_i64,
                "deviceId": device,
                "status": "streaming",
                "continuationOf": "retry-assistant",
                "parts": [{"id": "steer-continuation-text", "kind": "text", "text": "I’ll verify the retry transition and check that the fallback keeps the original request."}]
            }
        ]))
        .unwrap(),
    }
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let mut args = std::env::args().skip(1);
    let mode = args
        .next()
        .expect("mode: before, after-queued, after-pending, after-confirmed or settings");
    anyhow::ensure!(
        matches!(
            mode.as_str(),
            "before" | "after-queued" | "after-pending" | "after-confirmed" | "settings"
        ),
        "mode must be before, after-queued, after-pending, after-confirmed or settings"
    );
    let width: f32 = args.next().expect("window width: 900 or 360").parse()?;
    anyhow::ensure!(width == 900.0 || width == 360.0, "width must be 900 or 360");
    let output = PathBuf::from(args.next().expect("output directory"));
    std::fs::create_dir_all(&output)?;

    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let registry = harness_engine::HarnessRegistry::new();
    registry.register(Arc::new(harness_adapters::mock::MockHarness {
        script: Vec::new(),
    }));
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(registry),
            harness_proto::HarnessId::Mock,
            None,
        )
    })?;
    core.workspace.create_chat(
        CHAT,
        None,
        Some(&core.device_id),
        Some(serde_json::from_value(serde_json::json!({
            "harness": "mock",
            "model": "mock-1",
            "reasoning": "medium",
            "modelOptions": {},
            "sandbox": "workspace-write"
        }))?),
        None,
    )?;
    core.workspace.rename_chat(CHAT, "Retry path review")?;

    let ipc_port = port()?;
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
    let chats = core.workspace.read_chats()?;
    let device = core.device_id.clone();
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();

    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let mut settings = settings::UiSettings::default();
            settings.sidebar_collapsed = true;
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
                state.fixture_attachment_engine(engine);
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                state.no_project = true;
                state.local_device_id = Some(device.clone());
                state.devices = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": device,
                        "name": "This device",
                        "platform": std::env::consts::OS,
                        "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
                state.chats = chats;
                state.selected_chat = Some(CHAT.into());
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
                            size(px(width), px(740.)),
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
                    if mode == "settings" {
                        // Help opens the production Shortcuts settings section, which contains
                        // the Queue/Steer preference. This exercises the public composer route.
                        pause(cx, 1400).await;
                        window.update(cx, |shell, _, cx| shell.fixture_help(cx))?;
                        pause(cx, 1000).await;
                        #[cfg(windows)]
                        {
                            std::fs::write(
                                output.join("ready.json"),
                                serde_json::to_vec_pretty(&serde_json::json!({
                                    "status": "ready",
                                    "mode": mode,
                                    "state": "settings",
                                    "width": width,
                                    "processId": std::process::id()
                                }))?,
                            )?;
                            pause(cx, 40_000).await;
                        }
                        #[cfg(not(windows))]
                        capture(window.into(), cx, &output, &format!("queue-steer-{mode}-{width}"))?;
                        return Ok(());
                    }
                    // Let the selected chat watch settle before replacing its UI-only queue.
                    pause(cx, 1400).await;
                    state.update(cx, |state, cx| {
                        state.receive_transcript_frame(base_transcript(&device), cx).unwrap();
                        cx.notify();
                    });
                    pause(cx, 900).await;
                    window.update(cx, |shell, _, cx| shell.fixture_appshots_transcript_start(cx))?;
                    let composer = window.update(cx, |shell, _, _| shell.fixture_appshots_composer())?;
                    composer.update(cx, |composer, cx| composer.fixture_set_draft(PROMPT, cx));
                    pause(cx, 250).await;
                    state.update(cx, |state, cx| {
                        let mut row = harness_doc::QueuedMessage::new(QUEUE_ID, PROMPT, &device);
                        row.hold_for_turn_end = true;
                        row.issued_at = 1788900002000;
                        state.queue = vec![row];
                        let now = chrono::Utc::now();
                        state.sessions = vec![harness_proto::Session {
                            last_completed_turn: None,
                            last_completed_peer_only: false,
                            chat_id: CHAT.into(),
                            device_id: device.clone(),
                            status: harness_proto::SessionStatus::Working,
                            started_at: Some(now - chrono::Duration::seconds(10)),
                            updated_at: now,
                        }];
                        cx.notify();
                    });
                    composer.update(cx, |composer, cx| composer.fixture_set_draft("", cx));
                    pause(cx, 900).await;

                    if matches!(mode.as_str(), "after-pending" | "after-confirmed") {
                        let echo: harness_doc::SessionMessageEntry = serde_json::from_value(
                            serde_json::json!({
                                "id": QUEUE_ID,
                                "role": "user",
                                "createdAt": 1788900002000_i64,
                                "deviceId": device,
                                "parts": [{"id": "steer-user-text", "kind": "text", "text": PROMPT}]
                            }),
                        )?;
                        state.update(cx, |state, cx| {
                            state.push_echo(CHAT, echo);
                            state.begin_pending_send(CHAT, QUEUE_ID, chrono::Utc::now());
                            cx.notify();
                        });
                    }
                    if mode == "after-confirmed" {
                        state.update(cx, |state, cx| {
                            state
                                .receive_transcript_frame(confirmed_transcript(&device), cx)
                                .unwrap();
                            state.end_pending_send(CHAT, QUEUE_ID);
                            cx.notify();
                        });
                    }
                    state.update(cx, |state, cx| {
                        state.devices = vec![
                            serde_json::from_value(serde_json::json!({
                                "id": device,
                                "name": "This device",
                                "platform": std::env::consts::OS,
                                "lastSeenAt": null
                            }))
                            .unwrap(),
                        ];
                        cx.notify();
                    });
                    pause(cx, 1500).await;
                    #[cfg(windows)]
                    let state_name = match mode.as_str() {
                        "before" => "queued",
                        "after-queued" => "queued",
                        "after-pending" => "pending",
                        _ => "confirmed",
                    };
                    #[cfg(windows)]
                    {
                        std::fs::write(
                            output.join("ready.json"),
                            serde_json::to_vec_pretty(&serde_json::json!({
                                "status": "ready",
                                "mode": mode,
                                "state": state_name,
                                "width": width,
                                "processId": std::process::id()
                            }))?,
                        )?;
                        // Parent captures the native HWND with the PID-checked client.
                        pause(cx, 40_000).await;
                    }
                    #[cfg(not(windows))]
                    {
                        capture(
                            window.into(),
                            cx,
                            &output,
                            &format!("queue-steer-{mode}-{width}"),
                        )?;
                        std::fs::write(
                            output.join("result.txt"),
                            "Synthetic production Shell, Composer and Transcript capture. EngineCore and IPC are temporary and local; no agent command or provider request was sent. Narrow width is desktop layout evidence, not mobile validation.\n",
                        )?;
                    }
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    eprintln!("Queue/Steer fixture failed: {error:#}");
                    *result.lock().unwrap() = Some(format!("{error:#}"));
                }
                let _ = window.update(cx, |_, window, _| window.remove_window());
                pause(cx, 100).await;
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
