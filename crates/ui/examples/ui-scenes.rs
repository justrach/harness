//! Renders scenes of the main window headlessly: native CoreText text and an
//! offscreen Metal target, with no window on screen and no engine. A scene is
//! one JSON file of made-up workspace state in the engine's wire shapes
//! (spaces, chats, sessions, the open chat's transcript); each renders to a
//! PNG beside it. harness-nano renders the same files (`--scene`), so the two
//! apps can be compared, and the pairs kept as a dataset (apps/nano/parity).
//!
//! `cargo run -p harness-ui --features ui-scenes --example ui-scenes -- <scene.json>... --out <dir>`
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{
    cell::RefCell,
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Scene {
    name: String,
    #[serde(default)]
    appearance: Appearance,
    #[serde(default = "default_width")]
    width: f32,
    #[serde(default = "default_height")]
    height: f32,
    #[serde(default)]
    spaces: Vec<harness_proto::Space>,
    #[serde(default)]
    chats: Vec<harness_proto::Chat>,
    #[serde(default)]
    sessions: Vec<harness_proto::Session>,
    #[serde(default)]
    selected_chat: Option<String>,
    #[serde(default)]
    selected_space: Option<String>,
    #[serde(default)]
    transcript: Vec<harness_doc::SessionMessageEntry>,
    /// A run of interactions: after each, the frame is written as
    /// `<name>-<NN>.png` and the step's cost noted in `<name>.steps.json`.
    #[serde(default)]
    steps: Vec<Step>,
    /// Settings › Accounts' replies in place of the engine's
    /// (`settings::accounts::SCENE_ACCOUNTS`).
    #[serde(default)]
    accounts: Option<serde_json::Value>,
    /// Made-up engine replies, by method: the app gets an engine that
    /// answers each call with its entry (`{"$items": [...]}` streams them,
    /// then ends), and "isn't in this scene" for any other.
    #[serde(default)]
    replies: Option<serde_json::Map<String, serde_json::Value>>,
    /// More devices, after this one ("Studio").
    #[serde(default)]
    devices: Vec<serde_json::Value>,
    /// Synthetic device capability, never the renderer host's installed CLI.
    #[serde(default)]
    dictation_available: bool,
}

/// One interaction, in points from the window's top left. Keys as
/// `cmd+shift+n`; harness-nano reads the same steps.
#[derive(serde::Deserialize, serde::Serialize, Clone)]
#[serde(tag = "do", rename_all = "lowercase")]
enum Step {
    Click { x: f32, y: f32 },
    Hover { x: f32, y: f32 },
    Key { keys: String },
    Type { text: String },
    Scroll { x: f32, y: f32, dy: f32 },
    Wait { ms: u64 },
}

#[derive(serde::Deserialize, Default, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Appearance {
    #[default]
    Dark,
    Light,
}

fn default_width() -> f32 {
    1200.
}

fn default_height() -> f32 {
    780.
}

#[cfg(not(target_os = "macos"))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("ui-scenes renders with Metal: macOS only")
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter("warn")
        .with_writer(std::io::stderr)
        .init();
    let mut files = Vec::new();
    let mut out = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--out" {
            out = args.next().map(PathBuf::from);
        } else {
            files.push(PathBuf::from(arg));
        }
    }
    let out = out.ok_or_else(|| anyhow::anyhow!("Usage: ui-scenes <scene.json>... --out <dir>"))?;
    anyhow::ensure!(!files.is_empty(), "no scenes given");
    std::fs::create_dir_all(&out)?;
    let scenes = files
        .iter()
        .map(|f| {
            let scene: Scene = serde_json::from_slice(&std::fs::read(f)?)
                .map_err(|e| anyhow::anyhow!("{}: {e}", f.display()))?;
            Ok(scene)
        })
        .collect::<anyhow::Result<Vec<_>>>()?;

    let data = tempfile::tempdir()?;
    let data_dir = data.path().to_path_buf();
    let native = gpui_platform::current_platform(true);
    let platform = gpui::bench_platform(
        Some(Box::new(gpui_platform::current_headless_renderer)),
        native.text_system(),
    );
    let executor = platform.background_executor();
    let booted = Rc::new(RefCell::new(false));
    let ready = booted.clone();
    let settings_dir = data_dir.clone();
    let app = gpui::Application::with_platform(platform)
        .with_assets(icons::Assets)
        .run_embedded(move |cx| {
            gpui_tokio::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), settings_dir.clone(), cx);
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
            theme_library::init(settings_dir.clone(), cx);
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
            // The app-level actions (⌘W, ⌘= ⌘- ⌘0, ⌘M), as the app registers them.
            app_menus::register_actions(cx);
            *ready.borrow_mut() = true;
        });
    anyhow::ensure!(*booted.borrow(), "the app didn't start");
    let dispatcher = executor.dispatcher().as_bench().unwrap();

    for scene in scenes {
        composer::set_scene_dictation_available(scene.dictation_available);
        *settings::accounts::SCENE_ACCOUNTS.lock().unwrap() = scene.accounts.clone();
        app.update(|cx| {
            appearance::set_mode(
                match scene.appearance {
                    Appearance::Dark => appearance::AppearanceMode::Dark,
                    Appearance::Light => appearance::AppearanceMode::Light,
                },
                cx,
            )
        });
        let device = scene
            .chats
            .first()
            .map(|c| c.device_id.clone())
            .or_else(|| scene.spaces.first().map(|s| s.device_id.clone()))
            .unwrap_or_else(|| "local".into());
        let transcript = scene.transcript.clone();
        // Fresh as of this render: an old `updatedAt` reads as a stale run.
        let mut sessions = scene.sessions.clone();
        for s in &mut sessions {
            s.updated_at = chrono::Utc::now();
        }
        let state = app.update(|cx| {
            cx.new(|_| {
                let mut s = state::AppState::new();
                s.connection = harness_proto::view::ConnectionStatus::Ready;
                s.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
                s.local_device_id = Some(device.clone());
                s.devices = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": device, "name": "Studio", "platform": "macos", "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
                for d in &scene.devices {
                    if let Ok(d) = serde_json::from_value(d.clone()) {
                        s.devices.push(d);
                    }
                }
                s.spaces = scene.spaces.clone();
                s.chats = scene.chats.clone();
                s.selected_chat = scene.selected_chat.clone();
                s.selected_space = scene
                    .selected_space
                    .clone()
                    .or_else(|| scene.spaces.first().map(|s| s.id.clone()));
                s.auto_selected = true;
                s.chats_synced = true;
                s.spaces_synced = true;
                s
            })
        });
        if let Some(replies) = scene.replies.clone() {
            app.update(|cx| {
                let engine = scene_engine(gpui_tokio::Tokio::handle(cx), replies);
                state.update(cx, |s, _| s.set_test_engine(engine));
            });
        }
        let boot = EngineBootConfig {
            data_dir: data_dir.clone(),
            ipc_port: 0,
            edge_url: String::new(),
            edge_token: None,
            org_id: None,
            codegraff_client_id: None,
            default_harness: harness_proto::HarnessId::Graff,
        };
        let window = app.update(|cx| {
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(scene.width), px(scene.height)),
                    ))),
                    ..Default::default()
                },
                |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
            )
        })?;
        // The key window, as the app's would be: window-level actions (⌘W,
        // ⌘M) act on `cx.active_window()`.
        app.update(|cx| {
            window
                .update(cx, |_, window, _| window.activate_window())
                .ok()
        });
        app.update(|cx| {
            state.update(cx, |state, cx| {
                if scene.selected_chat.is_some() {
                    state
                        .receive_transcript_frame(
                            harness_doc::TranscriptFrame::Reset { reset: transcript },
                            cx,
                        )
                        .ok();
                }
                state.apply_sessions(sessions);
                cx.notify();
            })
        });
        // Frames until fonts, icons and layout settle (and entrance
        // animations end); the first frame's CPU time is the step's cost.
        let settle = |frames: usize| -> f64 {
            let mut first = 0.0;
            for i in 0..frames {
                let started = Instant::now();
                app.update(|cx| {
                    window
                        .update(cx, |_, window, cx| window.simulate_next_frame(cx))
                        .ok()
                });
                dispatcher.run_until_idle();
                if i == 0 {
                    first = started.elapsed().as_secs_f64() * 1000.0;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
            first
        };
        let save = |path: &std::path::Path| -> anyhow::Result<()> {
            app.update(|cx| {
                window.update(cx, |_, window, _| -> anyhow::Result<()> {
                    window.render_to_image()?.save(path)?;
                    Ok(())
                })
            })??;
            println!("{}", path.display());
            Ok(())
        };
        let opened = Instant::now();
        settle(40);
        // The real time each frame took to reach, so a renderer on a
        // simulated clock (harness-nano's) can draw the same moment.
        let initial_ms = opened.elapsed().as_secs_f64() * 1000.0;
        save(&out.join(format!("{}.png", scene.name)))?;
        let mut log = Vec::new();
        for (i, step) in scene.steps.iter().enumerate() {
            let started = Instant::now();
            // Through the untyped handle: the Shell isn't held while the
            // event reaches it.
            app.update(|cx| {
                cx.update_window(window.into(), |_, window, cx| perform(window, cx, step))
                    .ok()
            });
            let ms = if let Step::Wait { ms } = step {
                let frames = (*ms as usize / 15).max(1);
                settle(frames)
            } else {
                settle(20)
            };
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            let png = format!("{}-{:02}.png", scene.name, i + 1);
            save(&out.join(&png))?;
            log.push(serde_json::json!({
                "step": step,
                "frame": png,
                "frame_ms": ms,
                "elapsed_ms": elapsed_ms,
            }));
        }
        std::fs::write(
            out.join(format!("{}.steps.json", scene.name)),
            serde_json::to_vec_pretty(
                &serde_json::json!({ "initial_ms": initial_ms, "steps": log }),
            )?,
        )?;
        app.update(|cx| {
            window
                .update(cx, |_, window, _| window.remove_window())
                .ok()
        });
        dispatcher.run_until_idle();
    }
    Ok(())
}

/// Plays one step on the window, as the platform would deliver it.
fn perform(window: &mut gpui::Window, cx: &mut gpui::App, step: &Step) {
    use gpui::{
        Modifiers, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PlatformInput,
        ScrollDelta, ScrollWheelEvent, TouchPhase,
    };
    let at = |x: f32, y: f32| gpui::point(px(x), px(y));
    match step {
        Step::Hover { x, y } | Step::Click { x, y } => {
            window.dispatch_event(
                PlatformInput::MouseMove(MouseMoveEvent {
                    position: at(*x, *y),
                    pressed_button: None,
                    modifiers: Modifiers::default(),
                }),
                cx,
            );
            if let Step::Click { .. } = step {
                window.dispatch_event(
                    PlatformInput::MouseDown(MouseDownEvent {
                        button: MouseButton::Left,
                        position: at(*x, *y),
                        modifiers: Modifiers::default(),
                        click_count: 1,
                        first_mouse: false,
                    }),
                    cx,
                );
                window.dispatch_event(
                    PlatformInput::MouseUp(MouseUpEvent {
                        button: MouseButton::Left,
                        position: at(*x, *y),
                        modifiers: Modifiers::default(),
                        click_count: 1,
                    }),
                    cx,
                );
            }
        }
        Step::Key { keys } => {
            // `cmd+shift+n` as gpui writes it, `cmd-shift-n`.
            let combo = keys.replace('+', "-").replace("--", "-+");
            if let Ok(k) = gpui::Keystroke::parse(&combo) {
                window.dispatch_keystroke(k, cx);
            }
        }
        Step::Type { text } => {
            for ch in text.chars() {
                let key = if ch == ' ' {
                    "space".to_string()
                } else {
                    ch.to_string()
                };
                if let Ok(mut k) = gpui::Keystroke::parse(&key) {
                    k.key_char = Some(ch.to_string());
                    window.dispatch_keystroke(k, cx);
                }
            }
        }
        Step::Scroll { x, y, dy } => {
            window.dispatch_event(
                PlatformInput::ScrollWheel(ScrollWheelEvent {
                    position: at(*x, *y),
                    delta: ScrollDelta::Pixels(gpui::point(px(0.), px(*dy))),
                    modifiers: Modifiers::default(),
                    touch_phase: TouchPhase::Moved,
                }),
                cx,
            );
        }
        Step::Wait { .. } => {}
    }
}

/// An engine whose replies are the scene's (`Scene::replies`).
fn scene_engine(
    runtime: tokio::runtime::Handle,
    replies: serde_json::Map<String, serde_json::Value>,
) -> state::EngineHandle {
    let _guard = runtime.enter();
    let (out, mut requests) = tokio::sync::mpsc::channel::<String>(256);
    let (answers, inbound) = tokio::sync::mpsc::channel::<String>(256);
    let client = harness_rpc::RpcClient::new(out, inbound);
    runtime.spawn(async move {
        while let Some(payload) = requests.recv().await {
            for line in payload.lines() {
                let Ok(frame) = serde_json::from_str::<harness_rpc::ClientFrame>(line) else {
                    continue;
                };
                let Some(method) = frame.method else {
                    continue;
                };
                let id = frame.id;
                let mut frames = Vec::new();
                match replies.get(&method) {
                    Some(reply) if reply.get("$items").is_some() => {
                        for item in reply["$items"].as_array().cloned().unwrap_or_default() {
                            frames.push(harness_rpc::ServerFrame {
                                id,
                                item: Some(item),
                                ..Default::default()
                            });
                        }
                        frames.push(harness_rpc::ServerFrame {
                            id,
                            done: true,
                            ..Default::default()
                        });
                    }
                    Some(reply) => frames.push(harness_rpc::ServerFrame {
                        id,
                        ok: Some(reply.clone()),
                        ..Default::default()
                    }),
                    None => frames.push(harness_rpc::ServerFrame {
                        id,
                        err: Some(format!("{method} isn't in this scene")),
                        ..Default::default()
                    }),
                }
                for frame in frames {
                    if let Ok(text) = serde_json::to_string(&frame) {
                        let _ = answers.send(text).await;
                    }
                }
            }
        }
    });
    state::EngineHandle::from_test_client(client)
}
