//! Captures the chat column split into two panes, offscreen, to show how the
//! pane that takes your typing is marked.
//!
//! Opens the shell offscreen (native CoreText shaping, headless Metal) with two
//! made-up chats side by side and saves the frame as a PNG. No window is shown.
//!
//! ```sh
//! cargo run --profile app-dev -p harness-ui --features resource-profile,appshots-fixture \
//!   --example focus-cue-capture -- OUT.png
//! ```

use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use std::{
    cell::RefCell,
    rc::Rc,
    time::{Duration, Instant},
};

use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry, TranscriptFrame};
use harness_proto::HarnessId;
use harness_ui::*;

#[cfg(not(target_os = "macos"))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("This capture requires macOS")
}

fn entry(id: &str, role: MessageRole, text: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        parts: vec![MessagePart::Text {
            id: format!("{id}-text"),
            text: text.into(),
        }],
        id: id.into(),
        role,
        created_at: 1_790_000_000_000,
        device_id: "local".into(),
        status: (role == MessageRole::Assistant).then_some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: None,
    }
}

fn conversation(topic: &str) -> Vec<SessionMessageEntry> {
    vec![
        entry(
            "u1",
            MessageRole::User,
            &format!("How is the {topic} going?"),
        ),
        entry(
            "a1",
            MessageRole::Assistant,
            &format!(
                "The {topic} is on track. Two of the three steps are done, and the \
                 tests for the last one are running now.\n\n- Step one: merged\n- Step \
                 two: merged\n- Step three: in review"
            ),
        ),
        entry("u2", MessageRole::User, "Great, tell me when it lands."),
    ]
}

fn chat(id: &str, title: &str) -> harness_proto::Chat {
    serde_json::from_value(serde_json::json!({
        "id": id, "deviceId": "local", "spaceId": "project",
        "title": title, "archived": false,
        "createdAt": "2026-09-05T00:00:00Z",
        "config": {"harness": "mock", "model": "fable-5", "reasoning": null,
                   "sandbox": "workspace-write"}
    }))
    .unwrap()
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    let out = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("usage: focus-cue-capture OUT.png"))?;
    let data = tempfile::tempdir()?;
    let data_dir = data.path().to_path_buf();
    let native = gpui_platform::current_platform(true);
    let platform = gpui::bench_platform(
        Some(Box::new(gpui_platform::current_headless_renderer)),
        native.text_system(),
    );
    let executor = platform.background_executor();
    let handles = Rc::new(RefCell::new(None));
    let captured = handles.clone();
    let app = gpui::Application::with_platform(platform)
        .with_assets(icons::Assets)
        .run_embedded(move |cx| {
            gpui_tokio::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data_dir.clone(), cx);
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
            theme_library::init(data_dir.clone(), cx);
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
            composer::init(cx, harness_ui::settings::ComposerSendBehavior::default());
            terminal::panel::init(cx);
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
                state.selected_chat = Some("left".into());
                state.selected_space = Some("project".into());
                state.auto_selected = true;
                state.chats_synced = true;
                state.spaces_synced = true;
                state.spaces = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "project", "deviceId": "local", "path": "/tmp/focus-cue",
                        "createdAt": "2026-09-05T00:00:00Z"
                    }))
                    .unwrap(),
                ];
                state.chats = vec![
                    chat("left", "Parser cleanup"),
                    chat("right", "Release notes"),
                ];
                state
            });
            let boot = EngineBootConfig {
                data_dir: data_dir.clone(),
                ipc_port: 0,
                edge_url: String::new(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: HarnessId::Mock,
            };
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(0.), px(0.)),
                            size(px(1320.), px(560.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
                )
                .unwrap();
            *captured.borrow_mut() = Some((state, window));
        });
    let (state, window) = handles.borrow_mut().take().unwrap();
    let dispatcher = executor.dispatcher().as_bench().unwrap();
    let frame = |app: &gpui::ApplicationHandle| {
        app.update(|cx| {
            window
                .update(cx, |_, window, cx| window.simulate_next_frame(cx))
                .unwrap()
        });
        dispatcher.run_until_idle();
    };
    let settle = |app: &gpui::ApplicationHandle, for_: Duration| {
        let start = Instant::now();
        while start.elapsed() < for_ {
            frame(app);
            std::thread::sleep(Duration::from_millis(8));
        }
    };
    let load = |app: &gpui::ApplicationHandle, topic: &str| {
        let entries = conversation(topic);
        app.update(|cx| {
            state.update(cx, |state, cx| {
                state
                    .receive_transcript_frame(TranscriptFrame::reset(&entries), cx)
                    .unwrap();
                cx.notify();
            })
        });
    };

    load(&app, "parser cleanup");
    settle(&app, Duration::from_secs(2));
    // Split: the new pane on the right takes the focus and opens the second chat.
    app.update(|cx| {
        window
            .update(cx, |shell, window, cx| {
                shell.fixture_onboarding_split(true, window, cx)
            })
            .unwrap();
        state.update(cx, |state, cx| state.select_chat(Some("right".into()), cx));
    });
    settle(&app, Duration::from_millis(500));
    load(&app, "release");
    settle(&app, Duration::from_secs(2));
    app.update(|cx| {
        window
            .update(cx, |_, window, _| window.render_to_image())
            .unwrap()
    })?
    .save(&out)?;
    eprintln!("saved {out}");
    Ok(())
}
