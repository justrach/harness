//! Turn work captures rendered offscreen by the production shell: the
//! "N files changed" card, the running-command pill with the work pane it
//! opens, and the Changes review footer. The chat runs in a throwaway git
//! repo with uncommitted edits so the working-tree diff is real.
//!
//!   cargo run -p harness-ui --example turn-work-fixture --features appshots-fixture -- OUT_DIR
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, process::Command, sync::Arc, time::Duration};

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

fn click(window: gpui::AnyWindowHandle, cx: &mut AsyncApp, x: f32, y: f32) -> anyhow::Result<()> {
    window.update(cx, |_, w, cx| {
        w.draw(cx).clear();
        let position = gpui::point(px(x), px(y));
        w.dispatch_event(
            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                position,
                pressed_button: None,
                modifiers: Default::default(),
            }),
            cx,
        );
        w.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position,
                modifiers: Default::default(),
                click_count: 1,
                first_mouse: false,
            }),
            cx,
        );
        w.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                button: gpui::MouseButton::Left,
                position,
                modifiers: Default::default(),
                click_count: 1,
            }),
            cx,
        );
    })?;
    Ok(())
}

fn port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}


/// One prompt, then the agent's work: three edits and `cargo test`, still
/// running unless `done`.
fn frame(turn: &str, done: bool) -> harness_doc::TranscriptFrame {
    let edit = |id: &str, path: &str, additions: u64, deletions: u64| {
        serde_json::json!({
            "id": id, "kind": "tool", "resolved": true,
            "call": {"kind": "editFile", "path": path},
            "diffStats": [{"path": path, "additions": additions, "deletions": deletions}]
        })
    };
    let mut parts = vec![
        serde_json::json!({"id": "plan", "kind": "text", "text": "I'll fix the lexer, guard empty input, and add a regression test."}),
        edit("e1", "src/lexer.rs", 1, 1),
        edit("e2", "src/parser.rs", 4, 1),
        edit("e3", "src/empty_input.rs", 4, 0),
        serde_json::json!({"id": "test", "kind": "tool", "resolved": done,
            "call": {"kind": "exec", "command": "cargo test -p parser"}}),
    ];
    if done {
        parts.push(serde_json::json!({"id": "answer", "kind": "text",
            "text": "Empty input now parses to 0. All 25 tests pass."}));
    }
    harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {"id": turn, "role": "user", "createdAt": 1, "deviceId": "fixture",
             "parts": [{"id": "prompt", "kind": "text", "text": "Empty input crashes the parser. Fix it and add a test."}]},
            {"id": format!("{turn}-reply"), "role": "assistant", "createdAt": 2, "deviceId": "fixture",
             "status": if done { "complete" } else { "streaming" },
             "parts": parts}
        ]))
        .unwrap(),
    }
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
    let repo = temp.path().join("parser");
    std::fs::create_dir_all(repo.join("src"))?;
    let git = |args: &[&str]| -> anyhow::Result<()> {
        let status = Command::new("git").args(args).current_dir(&repo).status()?;
        anyhow::ensure!(status.success(), "git {args:?} failed");
        Ok(())
    };
    git(&["init", "-q"])?;
    git(&["config", "user.email", "fixture@example.com"])?;
    git(&["config", "user.name", "Fixture"])?;
    std::fs::write(repo.join("src/lexer.rs"), "pub fn lex(input: &str) -> Vec<&str> {\n    input.split(' ').collect()\n}\n")?;
    std::fs::write(repo.join("src/parser.rs"), "pub fn parse(input: &str) -> usize {\n    input.len()\n}\n")?;
    git(&["add", "."])?;
    git(&["commit", "-q", "-m", "init"])?;
    std::fs::write(repo.join("src/lexer.rs"), "pub fn lex(input: &str) -> Vec<&str> {\n    input.split_whitespace().collect()\n}\n")?;
    std::fs::write(repo.join("src/parser.rs"), "pub fn parse(input: &str) -> usize {\n    if input.is_empty() {\n        return 0;\n    }\n    crate::lexer::lex(input).len()\n}\n")?;
    std::fs::write(repo.join("src/empty_input.rs"), "#[test]\nfn empty_input_parses_to_zero() {\n    assert_eq!(crate::parser::parse(\"\"), 0);\n}\n")?;
    // Canonical (macOS temp dirs sit behind /var -> /private/var), so the
    // chat's cwd matches the checkout the engine's diff watch reports.
    let repo_path = std::fs::canonicalize(&repo)?.to_string_lossy().to_string();
    core.workspace.create_chat(
        "work-chat",
        None,
        Some(&core.device_id),
        Some(serde_json::from_value(serde_json::json!({
            "harness": "claude-code",
            "model": "claude-opus-5-5",
            "reasoning": null,
            "modelOptions": {},
            "sandbox": "workspace-write"
        }))?),
        Some(repo_path.clone()),
    )?;
    core.workspace.rename_chat("work-chat", "Fix the empty input parser bug")?;
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
            "path": repo_path,
            "gitDetected": true,
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
            state.devices = vec![serde_json::from_value(serde_json::json!({
                "id": device,
                "name": "MacBook Pro",
                "platform": std::env::consts::OS,
                "lastSeenAt": null
            }))
            .unwrap()];
            state.chats = chats;
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state.spaces = vec![space.clone()];
            state.selected_space = Some(space.id.clone());
            state.no_project = false;
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
                    // Never take key focus: keystrokes on the Mac must not
                    // land in the capture window.
                    focus: false,
                    ..Default::default()
                },
                |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
            )
            .unwrap();
        state.update(cx, |_, cx| cx.notify());
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                state.update(cx, |state, cx| state.select_chat(Some("work-chat".into()), cx));
                pause(cx, 1500).await;

                // A finished turn that edited three files: the card.
                state.update(cx, |state, cx| state.receive_transcript_frame(frame("u1", true), cx))?;
                pause(cx, 1200).await;
                capture(window.into(), cx, &output, "01-changes-card")?;

                // The next turn runs the tests: the pill (and, after this
                // change, the work pane opens by itself).
                state.update(cx, |state, cx| {
                    state.begin_pending_send("work-chat", "fixture-send", chrono::Utc::now());
                    state.receive_transcript_frame(frame("u2", false), cx)
                })?;
                pause(cx, 1800).await;
                capture(window.into(), cx, &output, "02-running-pill")?;

                // The turn ends with edits: the pane stays on the review.
                state.update(cx, |state, cx| {
                    state.end_pending_send("work-chat", "fixture-send");
                    state.receive_transcript_frame(frame("u2", true), cx)
                })?;
                pause(cx, 1500).await;
                let open = window.update(cx, |shell, _, cx| shell.fixture_right_pane_open(cx))?;
                if !open {
                    // Click the card's Review, as a user would.
                    click(window.into(), cx, 726., 643.)?;
                }
                // The working-tree diff comes from the engine's git watch.
                pause(cx, 6000).await;
                capture(window.into(), cx, &output, "03-review-footer")?;
                Ok(())
            }
            .await;
            if let Err(error) = run {
                eprintln!("turn work fixture failed: {error:#}");
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
