//! What one keystroke and one streamed chunk re-render in the main window.
//!
//! Opens the shell offscreen (native CoreText shaping, headless Metal) on a
//! long synthetic conversation, then
//! - types 20 characters into the composer, and
//! - streams 20 chunks into the last reply,
//!
//! drawing a frame after each, and prints how many transcript views, rows
//! and composers each phase rebuilt and the time per input.
//!
//! ```sh
//! cargo build --profile app-dev -p harness-ui --features resource-profile \
//!   --example render-isolation-profile
//! HARNESS_FRAME_STATS=1 target/app-dev/examples/render-isolation-profile
//! ```
//!
//! `HARNESS_FRAME_STATS=1` turns on the render counters.
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use std::{
    cell::RefCell,
    rc::Rc,
    time::{Duration, Instant},
};

use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry, TranscriptFrame};
use harness_ui::*;

#[cfg(target_os = "macos")]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

const TURNS: usize = 40;
const STEPS: usize = 20;

#[cfg(not(target_os = "macos"))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("This profiler requires macOS")
}

fn entry(
    id: String,
    role: MessageRole,
    text: String,
    status: Option<MessageStatus>,
) -> SessionMessageEntry {
    SessionMessageEntry {
        parts: vec![MessagePart::Text {
            id: format!("{id}-text"),
            text,
        }],
        id,
        role,
        created_at: 1_790_000_000_000,
        device_id: "local".into(),
        status,
        continuation_of: None,
        duration_ms: None,
    }
}

/// A made-up conversation: short prompts, replies with prose, a list and a
/// code fence, so rows exercise paragraphs, lists and highlighted code.
fn conversation() -> Vec<SessionMessageEntry> {
    let mut entries = Vec::new();
    for turn in 0..TURNS {
        entries.push(entry(
            format!("user-{turn}"),
            MessageRole::User,
            format!("Step {turn}: tidy the parser module and explain what changed."),
            None,
        ));
        let reply = format!(
            "## Step {turn}\n\nThe parser now keeps one buffer per input instead of \
             reallocating on every token, and errors carry the byte offset where they \
             started. Nothing else about its output changes.\n\n- Buffers are reused \
             across calls\n- Error spans point at the first bad byte\n- The fast path \
             skips validation for ASCII\n\n```rust\nfn parse_{turn}(input: &str) -> \
             Result<Vec<Token>, Error> {{\n    let mut tokens = Vec::with_capacity(input.len() / 4);\n    \
             for (offset, ch) in input.char_indices() {{\n        tokens.push(Token::new(offset, ch)?);\n    \
             }}\n    Ok(tokens)\n}}\n```\n\nRun the tests again after pulling; the fixtures \
             were regenerated."
        );
        entries.push(entry(
            format!("reply-{turn}"),
            MessageRole::Assistant,
            reply,
            Some(MessageStatus::Complete),
        ));
    }
    entries
}

struct Phase {
    name: &'static str,
    ms: Vec<f64>,
    transcripts: u64,
    rows: u64,
    composers: u64,
}

impl Phase {
    fn print(&self) {
        let mut sorted = self.ms.clone();
        sorted.sort_by(f64::total_cmp);
        let mean = sorted.iter().sum::<f64>() / sorted.len() as f64;
        let p50 = sorted[sorted.len() / 2];
        let p95 = sorted[(sorted.len() * 95 / 100).min(sorted.len() - 1)];
        println!(
            "{:<10} inputs={} transcript_renders={} rows_rendered={} composer_renders={} \
             ms_per_input mean={mean:.2} p50={p50:.2} p95={p95:.2}",
            self.name,
            self.ms.len(),
            self.transcripts,
            self.rows,
            self.composers,
        );
    }
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    anyhow::ensure!(
        std::env::var("HARNESS_FRAME_STATS").is_ok_and(|v| !v.is_empty() && v != "0"),
        "Set HARNESS_FRAME_STATS=1: it turns on the render counters"
    );
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
            composer::init(cx, harness_ui::settings::ComposerSendBehavior::default());
            terminal::panel::init(cx);
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
                state.selected_chat = Some("profile".into());
                state.selected_space = Some("project".into());
                state.auto_selected = true;
                state.chats_synced = true;
                state.spaces_synced = true;
                state.spaces = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "project", "deviceId": "local", "path": "/tmp/render-isolation",
                        "createdAt": "2026-09-05T00:00:00Z"
                    }))
                    .unwrap(),
                ];
                state.chats = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "profile", "deviceId": "local", "spaceId": "project",
                        "title": "Parser cleanup", "archived": false,
                        "createdAt": "2026-09-05T00:00:00Z",
                        "config": {"harness": "mock", "model": "fable-5", "reasoning": null,
                                   "sandbox": "workspace-write"}
                    }))
                    .unwrap(),
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
                            size(px(1320.), px(880.)),
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
                .update(cx, |_, window, cx| {
                    window.simulate_next_frame(cx);
                })
                .unwrap()
        });
        dispatcher.run_until_idle();
        app.update(|cx| {
            window
                .update(cx, |_, window, _| window.present_if_needed())
                .unwrap()
        });
    };
    let settle = |app: &gpui::ApplicationHandle, for_: Duration| {
        let start = Instant::now();
        while start.elapsed() < for_ {
            frame(app);
            std::thread::sleep(Duration::from_millis(8));
        }
    };

    let session = |status| harness_proto::Session {
        last_completed_turn: None,
        last_completed_peer_only: false,
        chat_id: "profile".into(),
        device_id: "local".into(),
        status,
        started_at: Some(chrono::Utc::now()),
        updated_at: chrono::Utc::now(),
    };
    let mut entries = conversation();
    app.update(|cx| {
        state.update(cx, |state, cx| {
            state
                .receive_transcript_frame(TranscriptFrame::reset(&entries), cx)
                .unwrap();
            state.apply_sessions(vec![session(harness_proto::SessionStatus::Idle)]);
            cx.notify();
        })
    });
    settle(&app, Duration::from_secs(3));

    // Focus the composer the way a person does (the Jump to the message box
    // command).
    app.update(|cx| {
        cx.update_window(window.into(), |_, window, cx| {
            window.dispatch_action(Box::new(shell::FocusComposer), cx)
        })
        .unwrap()
    });
    // The first key press switches the window to keyboard focus styling and
    // redraws everything once; take that with a caret move, not a measured
    // keystroke.
    app.update(|cx| {
        cx.update_window(window.into(), |_, window, cx| {
            window.dispatch_keystroke(gpui::Keystroke::parse("right").unwrap(), cx);
        })
        .unwrap()
    });
    settle(&app, Duration::from_secs(1));

    let counts = || {
        (
            transcript::render_total("transcript"),
            transcript::render_total("transcript-row"),
            transcript::render_total("composer"),
        )
    };
    let mut run = |name: &'static str, step: &mut dyn FnMut(usize, &gpui::ApplicationHandle)| {
        let before = counts();
        let mut ms = Vec::new();
        for i in 0..STEPS {
            let start = Instant::now();
            step(i, &app);
            frame(&app);
            ms.push(start.elapsed().as_secs_f64() * 1000.0);
            // Keep inputs at a typing pace; this also lets the caret and
            // fades run their own frames between inputs, uncounted in `ms`.
            std::thread::sleep(Duration::from_millis(30));
            frame(&app);
        }
        let after = counts();
        Phase {
            name,
            ms,
            transcripts: after.0 - before.0,
            rows: after.1 - before.1,
            composers: after.2 - before.2,
        }
    };
    let mut type_keys = |app: &gpui::ApplicationHandle, i: usize| {
        let key = ["h", "e", "l", "l", "o", "space"][i % 6];
        app.update(|cx| {
            cx.update_window(window.into(), |_, window, cx| {
                window.dispatch_keystroke(gpui::Keystroke::parse(key).unwrap(), cx);
            })
            .unwrap()
        });
    };

    let typing = run("typing", &mut |i, app| type_keys(app, i));

    // The last reply goes live: the agent is working and text streams in.
    let last = entries.last_mut().unwrap();
    last.status = Some(MessageStatus::Streaming);
    let last = last.clone();
    let after = entries[entries.len() - 2].id.clone();
    app.update(|cx| {
        state.update(cx, |state, cx| {
            state
                .receive_transcript_frame(
                    TranscriptFrame::Delta {
                        upsert: vec![harness_doc::TranscriptUpsert {
                            after: Some(after),
                            entry: last.clone(),
                        }],
                        append: Vec::new(),
                        remove: Vec::new(),
                        count: entries.len(),
                    },
                    cx,
                )
                .unwrap();
            state.apply_sessions(vec![session(harness_proto::SessionStatus::Working)]);
            cx.notify();
        })
    });
    settle(&app, Duration::from_secs(1));

    let part = match &last.parts[0] {
        MessagePart::Text { id, text } => (id.clone(), text.len()),
        _ => unreachable!(),
    };
    let mut len = part.1;
    let streaming = run("streaming", &mut |i, app| {
        let text = format!(" More detail on item {i}, streamed in.");
        len += text.len();
        let frame = TranscriptFrame::Delta {
            upsert: Vec::new(),
            append: vec![harness_doc::TextAppend {
                entry: last.id.clone(),
                part: part.0.clone(),
                text,
                len,
            }],
            remove: Vec::new(),
            count: entries.len(),
        };
        app.update(|cx| {
            state.update(cx, |state, cx| {
                state.receive_transcript_frame(frame, cx).unwrap();
            })
        });
    });
    // Typing the next message while the reply is still live.
    let typing_live = run("typing-live", &mut |i, app| type_keys(app, i));

    typing.print();
    streaming.print();
    typing_live.print();

    // HARNESS_VERIFY_CACHE=1: a frame that reused the cached transcript and
    // composer must match one drawn from scratch, after each change below.
    if std::env::var_os("HARNESS_VERIFY_CACHE").is_some() {
        let mut done = last.clone();
        done.status = Some(MessageStatus::Complete);
        if let MessagePart::Text { text, .. } = &mut done.parts[0] {
            text.push_str(&" More detail, streamed in.".repeat(1));
        }
        let keys = |app: &gpui::ApplicationHandle, keys: &[&str]| {
            for key in keys {
                app.update(|cx| {
                    cx.update_window(window.into(), |_, window, cx| {
                        window.dispatch_keystroke(gpui::Keystroke::parse(key).unwrap(), cx);
                    })
                    .unwrap()
                });
                frame(app);
            }
        };
        let hover = |app: &gpui::ApplicationHandle, x: f32, y: f32| {
            app.update(|cx| {
                cx.update_window(window.into(), |_, window, cx| {
                    window.dispatch_event(
                        gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                            position: gpui::point(px(x), px(y)),
                            ..Default::default()
                        }),
                        cx,
                    );
                })
                .unwrap()
            });
        };
        let scenarios: [(&str, &dyn Fn(&gpui::ApplicationHandle)); 7] = [
            ("reply-finished", &|app| {
                app.update(|cx| {
                    state.update(cx, |state, cx| {
                        let after = entries[entries.len() - 2].id.clone();
                        state
                            .receive_transcript_frame(
                                TranscriptFrame::Delta {
                                    upsert: vec![harness_doc::TranscriptUpsert {
                                        after: Some(after),
                                        entry: done.clone(),
                                    }],
                                    append: Vec::new(),
                                    remove: Vec::new(),
                                    count: entries.len(),
                                },
                                cx,
                            )
                            .unwrap();
                        state.apply_sessions(vec![session(harness_proto::SessionStatus::Idle)]);
                        cx.notify();
                    })
                })
            }),
            ("composer-grew", &|app| {
                keys(
                    app,
                    &["shift-enter", "a", "shift-enter", "b", "shift-enter", "c"],
                )
            }),
            ("composer-shrank", &|app| keys(app, &["cmd-a", "backspace"])),
            ("typed-again", &|app| keys(app, &["o", "k"])),
            ("hover-attach", &|app| hover(app, 443.0, 815.0)),
            ("hover-transcript", &|app| hover(app, 1138.0, 372.0)),
            ("hover-none", &|app| hover(app, 700.0, 500.0)),
        ];
        for (name, scenario) in scenarios {
            scenario(&app);
            settle(&app, Duration::from_millis(700));
            let cached = app.update(|cx| {
                window
                    .update(cx, |_, window, _| window.render_to_image().unwrap())
                    .unwrap()
            });
            app.update(|cx| window.update(cx, |_, window, _| window.refresh()).unwrap());
            frame(&app);
            let fresh = app.update(|cx| {
                window
                    .update(cx, |_, window, _| window.render_to_image().unwrap())
                    .unwrap()
            });
            let differing = cached
                .enumerate_pixels()
                .filter(|(x, y, pixel)| *pixel != fresh.get_pixel(*x, *y))
                .map(|(x, y, _)| (x, y))
                .fold(None, |bounds: Option<(u32, u32, u32, u32)>, (x, y)| {
                    Some(bounds.map_or((x, y, x, y), |(a, b, c, d)| {
                        (a.min(x), b.min(y), c.max(x), d.max(y))
                    }))
                });
            if let Some(dir) = std::env::var_os("HARNESS_VERIFY_DIR") {
                let dir = std::path::PathBuf::from(dir);
                cached.save(dir.join(format!("{name}-cached.png")))?;
                fresh.save(dir.join(format!("{name}-fresh.png")))?;
            }
            match differing {
                None => println!("cache pixels match: {name}"),
                Some(bounds) => println!("CACHE DIFFERS: {name} in {bounds:?} (device px)"),
            }
        }
    }
    // Optional: the final frame, to check the typed and streamed text landed.
    if let Some(path) = std::env::var_os("HARNESS_PROFILE_SHOT") {
        settle(&app, Duration::from_millis(500));
        app.update(|cx| {
            window
                .update(cx, |_, window, _| {
                    window.render_to_image().unwrap().save(&path)
                })
                .unwrap()
        })?;
    }
    drop(state);
    app.update(|cx| cx.quit());
    drop(app);
    Ok(())
}
