//! A graff chat that Harness restarted under (a quit or an update) while the
//! agent waited on a question, with isolated data:
//! - `restart-before`: the transcript the crash path left: an interruption
//!   error card, then the same question asked again by the re-sent run;
//! - `restart-after-question`: the one question, still answerable, with a calm
//!   note that answering it picks the run back up;
//! - `restart-after-resume`: a run cut short mid-turn, picked back up on its own
//!   after an update.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example restart-resume-fixture -- <dir> [light]`
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry, TranscriptFrame};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

const CHAT: &str = "restart-resume-fixture";

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

fn entry(
    id: &str,
    role: MessageRole,
    at: i64,
    status: MessageStatus,
    parts: Vec<MessagePart>,
) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts,
        created_at: at,
        device_id: "fixture".into(),
        status: Some(status),
        continuation_of: None,
        duration_ms: None,
    }
}

fn text(id: &str, text: &str) -> MessagePart {
    MessagePart::Text {
        id: id.into(),
        text: text.into(),
    }
}

fn thought(id: &str, text: &str) -> MessagePart {
    MessagePart::Reasoning {
        id: id.into(),
        text: text.into(),
    }
}

fn question(request_id: &str, resolved: bool) -> MessagePart {
    MessagePart::Input {
        id: request_id.into(),
        request_id: request_id.into(),
        questions: vec![harness_proto::UserInputQuestion {
            id: "q1".into(),
            header: "Target branch".into(),
            question: "Which branch should the retry fix go on?".into(),
            options: vec!["main".into(), "release".into()],
            multi_select: false,
            prefill: None,
            multiline: false,
        }],
        resolved,
    }
}

fn note(id: &str, message: &str) -> MessagePart {
    MessagePart::Error {
        id: id.into(),
        message: message.into(),
        reauth: None,
    }
}

fn user(at: i64) -> SessionMessageEntry {
    entry(
        "user-1",
        MessageRole::User,
        at,
        MessageStatus::Complete,
        vec![text("t0", "Add a retry to the upload step and open a PR.")],
    )
}

fn asked(status: MessageStatus, extra: Vec<MessagePart>) -> SessionMessageEntry {
    let mut parts = vec![
        thought(
            "r0",
            "The retry belongs in the upload client. I should check where it ships.",
        ),
        text("t1", "I found the upload step. Before I change it:"),
        question("req-1", false),
    ];
    parts.extend(extra);
    entry("assistant-1", MessageRole::Assistant, 1, status, parts)
}

/// What the crash path left: the interruption error, then the re-sent run
/// asking the same question again.
fn before() -> TranscriptFrame {
    TranscriptFrame::Reset {
        reset: vec![
            user(0),
            asked(
                MessageStatus::Aborted,
                vec![note("e9", "Run interrupted by engine restart — resuming")],
            ),
            entry(
                "assistant-2",
                MessageRole::Assistant,
                2,
                MessageStatus::Streaming,
                vec![
                    thought(
                        "r0",
                        "Picking the task back up. I should confirm the branch first.",
                    ),
                    question("req-2", false),
                ],
            ),
        ],
    }
}

/// The one question, still answerable, and a calm note beside it.
fn after_question() -> TranscriptFrame {
    TranscriptFrame::Reset {
        reset: vec![
            user(0),
            asked(
                MessageStatus::Aborted,
                vec![note("e9", harness_doc::restart_note::AWAITING_ANSWER)],
            ),
        ],
    }
}

/// A turn cut short by an update, picked back up on its own.
fn after_resume() -> TranscriptFrame {
    TranscriptFrame::Reset {
        reset: vec![
            user(0),
            entry(
                "assistant-1",
                MessageRole::Assistant,
                1,
                MessageStatus::Aborted,
                vec![
                    text("t1", "Adding the retry to the upload client now."),
                    note(
                        "e9",
                        &harness_doc::restart_note::resuming(Some(env!("CARGO_PKG_VERSION"))),
                    ),
                ],
            ),
            entry(
                "assistant-2",
                MessageRole::Assistant,
                2,
                MessageStatus::Complete,
                vec![text(
                    "t1",
                    "The retry is in place, with a test for a dropped upload. Opening the PR.",
                )],
            ),
        ],
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
        // A graff (Codegraff) chat, as reported.
        chat.config = Some(harness_proto::ChatConfig {
            harness: harness_proto::HarnessId::Graff,
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
                    for (name, frame) in [
                        ("restart-before", before()),
                        ("restart-after-question", after_question()),
                        ("restart-after-resume", after_resume()),
                    ] {
                        state.update(cx, |state, cx| state.receive_transcript_frame(frame, cx))?;
                        pause(cx, 900).await;
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
