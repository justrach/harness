//! Product walkthrough rendered offscreen by the production shell, one frame
//! at a time, for the website demo: choose an agent, build something from a
//! starter, split the window and hand a follow-up to Claude Code, then
//! research and plan a launch. Writes numbered PNGs, `frames.ffconcat` (each
//! frame's hold time) and `chapters.json` (where each chapter starts).
//!
//!   cargo run -p harness-ui --example starter-demo-fixture --features appshots-fixture -- OUT_DIR [light|dark]
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_proto::HarnessId;
use harness_ui::*;
use serde_json::{Value, json};
use std::{path::PathBuf, sync::Arc, time::Duration};

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

/// Captured frames and how long each one holds in the finished video.
struct Reel {
    directory: PathBuf,
    frames: Vec<(String, f32)>,
    /// Where each chapter starts, in seconds.
    chapters: Vec<(&'static str, f32)>,
}

impl Reel {
    fn capture(
        &mut self,
        window: gpui::AnyWindowHandle,
        cx: &mut AsyncApp,
        hold: f32,
    ) -> anyhow::Result<()> {
        let name = format!("{:03}.png", self.frames.len());
        let path = self.directory.join(&name);
        window.update(cx, |_, window, cx| {
            window.draw(cx).clear();
            window.render_to_image()?.save(path)?;
            anyhow::Ok(())
        })??;
        self.frames.push((name, hold));
        Ok(())
    }

    fn chapter(&mut self, id: &'static str) {
        let start = self
            .frames
            .iter()
            .fold(0.0, |total, (_, hold)| total + hold);
        self.chapters.push((id, start));
    }

    fn finish(&self) -> anyhow::Result<()> {
        let mut concat = String::from("ffconcat version 1.0\n");
        for (name, hold) in &self.frames {
            concat.push_str(&format!("file '{name}'\nduration {hold}\n"));
        }
        if let Some((name, _)) = self.frames.last() {
            concat.push_str(&format!("file '{name}'\n"));
        }
        std::fs::write(self.directory.join("frames.ffconcat"), concat)?;
        let chapters: Vec<Value> = self
            .chapters
            .iter()
            .map(|(id, start)| json!({"id": id, "start": (f64::from(*start) * 100.0).round() / 100.0}))
            .collect();
        std::fs::write(
            self.directory.join("chapters.json"),
            serde_json::to_string_pretty(&chapters)?,
        )?;
        Ok(())
    }
}

fn port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// One chat the walkthrough sends: what gets typed and how the agent answers.
struct Scene {
    /// Starter applied first (its prompt precedes `idea`), if any.
    starter: Option<&'static str>,
    harness: &'static str,
    model: &'static str,
    chat: &'static str,
    title: &'static str,
    idea: &'static str,
    /// Assistant parts, revealed one at a time.
    steps: Vec<Value>,
}

impl Scene {
    fn prompt(&self) -> String {
        let starter = self
            .starter
            .and_then(shell::Shell::fixture_starter_prompt)
            .unwrap_or_default();
        format!("{starter}{}", self.idea)
    }

    fn entries(&self, device: &str, shown: usize, created: i64) -> Value {
        let done = shown == self.steps.len();
        json!([
            {
                "id": format!("{}-user", self.chat),
                "role": "user",
                "parts": [text("text", &self.prompt())],
                "createdAt": created,
                "deviceId": device
            },
            {
                "id": format!("{}-assistant", self.chat),
                "role": "assistant",
                "parts": self.steps[..shown],
                "createdAt": created + 1_000,
                "deviceId": device,
                "status": if done { "complete" } else { "streaming" }
            }
        ])
    }
}

fn text(id: &str, body: &str) -> Value {
    json!({"id": id, "kind": "text", "text": body})
}

fn tool(id: &str, call: Value, output: Option<&str>) -> Value {
    let mut part = json!({"id": id, "kind": "tool", "call": call, "resolved": true});
    if let Some(output) = output {
        part["output"] = json!(output);
    }
    part
}

const APP: &str = "/Users/demo/Projects/habit-tracker";

fn build() -> Scene {
    Scene {
        starter: Some("build"),
        harness: "graff",
        model: "grok-4.7",
        chat: "demo-build",
        title: "Habit tracker for my phone",
        idea: "a habit tracker I can use on my phone",
        steps: vec![
            text(
                "plan",
                "I'll make a small web app in ~/Projects/habit-tracker that you can add to \
                 your home screen. Habits stay on the phone, so it works offline.",
            ),
            tool(
                "scaffold",
                json!({"kind": "exec", "command": "mkdir -p ~/Projects/habit-tracker && cd ~/Projects/habit-tracker && npm create vite@latest . -- --template react-ts"}),
                Some("Scaffolding project in ~/Projects/habit-tracker...\n\nDone."),
            ),
            tool(
                "app",
                json!({"kind": "writeFile", "path": format!("{APP}/src/App.tsx")}),
                None,
            ),
            tool(
                "store",
                json!({"kind": "writeFile", "path": format!("{APP}/src/habits.ts")}),
                None,
            ),
            tool(
                "manifest",
                json!({"kind": "writeFile", "path": format!("{APP}/public/manifest.json")}),
                None,
            ),
            tool(
                "run",
                json!({"kind": "exec", "command": "npm install && npm run dev -- --host"}),
                Some(
                    "VITE ready\n\n  Local:   http://localhost:5173/\n  Network: http://192.168.1.20:5173/",
                ),
            ),
            text(
                "done",
                "Your habit tracker is running.\n\n\
                 - **On your phone:** open http://192.168.1.20:5173 on the same Wi-Fi.\n\
                 - **Add to Home Screen** and it opens like an app, offline too.\n\
                 - Tap a habit to check it off; streaks count themselves.\n\n\
                 Want a daily reminder next?",
            ),
        ],
    }
}

fn reminder() -> Scene {
    Scene {
        starter: None,
        harness: "claude-code",
        model: "claude-opus-5-5",
        chat: "demo-reminder",
        title: "Daily reminder at 8pm",
        idea: "Add a daily 8pm reminder to ~/Projects/habit-tracker",
        steps: vec![
            text(
                "plan",
                "I'll add a reminder that fires at 8pm through the phone's notifications, with a \
                 switch in Settings.",
            ),
            tool(
                "read",
                json!({"kind": "readFile", "path": format!("{APP}/src/habits.ts")}),
                None,
            ),
            tool(
                "schedule",
                json!({"kind": "writeFile", "path": format!("{APP}/src/reminders.ts")}),
                None,
            ),
            tool(
                "toggle",
                json!({"kind": "editFile", "path": format!("{APP}/src/App.tsx")}),
                None,
            ),
            tool(
                "check",
                json!({"kind": "exec", "command": "npm run build"}),
                Some("vite build\n✓ built in 1.2s"),
            ),
            text(
                "done",
                "Done. Turn on **Daily reminder** in Settings and your phone will nudge you at \
                 8pm. You can change the time there too.",
            ),
        ],
    }
}

fn research() -> Scene {
    Scene {
        starter: Some("research"),
        harness: "graff",
        model: "grok-4.7",
        chat: "demo-research",
        title: "How small teams price AI products",
        idea: "how small teams price AI products",
        steps: vec![
            tool(
                "search-1",
                json!({"kind": "webSearch", "query": "AI product pricing models usage-based vs per seat"}),
                None,
            ),
            tool(
                "search-2",
                json!({"kind": "webSearch", "query": "AI startup pricing page examples credits"}),
                None,
            ),
            tool(
                "fetch",
                json!({"kind": "webFetch", "url": "https://en.wikipedia.org/wiki/Pricing_strategies"}),
                None,
            ),
            text(
                "done",
                "## Pricing AI products\n\n\
                 **Key takeaways**\n\
                 1. Most teams mix a flat plan with usage on top, so heavy users pay for what they burn.\n\
                 2. Credits make usage legible: people buy a bundle instead of reading token math.\n\
                 3. A free tier with a hard cap drives trials without open-ended cost.\n\n\
                 Source: [Pricing strategies](https://en.wikipedia.org/wiki/Pricing_strategies)",
            ),
        ],
    }
}

fn launch() -> Scene {
    Scene {
        starter: Some("launch"),
        harness: "graff",
        model: "grok-4.7",
        chat: "demo-launch",
        title: "Launch plan for Streakless",
        idea: "Streakless, a habit tracker for people who hate habit trackers",
        steps: vec![
            tool(
                "market",
                json!({"kind": "webSearch", "query": "habit tracker apps reviews what people dislike"}),
                None,
            ),
            tool(
                "positioning",
                json!({"kind": "writeFile", "path": "/Users/demo/Streakless/launch/positioning.md"}),
                None,
            ),
            tool(
                "copy",
                json!({"kind": "writeFile", "path": "/Users/demo/Streakless/launch/landing-page.md"}),
                None,
            ),
            text(
                "done",
                "## Streakless launch plan\n\n\
                 **Positioning:** the habit tracker that never guilt-trips you. No streaks to break, \
                 just a quiet record of the days you showed up.\n\n\
                 **Go to market:** start where people complain about streak anxiety, then a \
                 launch-day post with a one-tap demo.\n\n\
                 **Headline:** *Keep the habit. Lose the pressure.*",
            ),
        ],
    }
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let mode = match std::env::args().nth(2).as_deref() {
        Some("dark") => appearance::AppearanceMode::Dark,
        _ => appearance::AppearanceMode::Light,
    };
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            HarnessId::Graff,
            None,
        )
    })?;
    let (build, reminder, research, launch) = (build(), reminder(), research(), launch());
    for scene in [&build, &reminder, &research, &launch] {
        core.workspace.create_chat(
            scene.chat,
            None,
            Some(&core.device_id),
            Some(serde_json::from_value(json!({
                "harness": scene.harness,
                "model": scene.model,
                "reasoning": "high",
                "modelOptions": {},
                "sandbox": "workspace-write"
            }))?),
            None,
        )?;
        core.workspace.rename_chat(scene.chat, scene.title)?;
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
        default_harness: HarnessId::Graff,
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
                mode,
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
            // First run: no projects and no chats yet. Each chat joins the
            // sidebar when it is sent.
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.fixture_attachment_engine(handle);
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                state.no_project = true;
                state.local_device_id = Some(device.clone());
                state.devices = vec![
                    serde_json::from_value(json!({
                        "id": device,
                        "name": "MacBook Pro",
                        "platform": std::env::consts::OS,
                        "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
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
                let mut reel = Reel {
                    directory: output.clone(),
                    frames: Vec::new(),
                    chapters: Vec::new(),
                };
                let run: anyhow::Result<()> = async {
                    let any: gpui::AnyWindowHandle = window.into();
                    let mut created = 1_788_900_000_000_i64;

                    // Type `scene`'s idea into the composer, a few letters a frame.
                    macro_rules! type_idea {
                        ($scene:expr) => {{
                            let starter = $scene
                                .starter
                                .and_then(shell::Shell::fixture_starter_prompt)
                                .unwrap_or_default();
                            let letters: Vec<char> = $scene.idea.chars().collect();
                            let mut typed = 0;
                            while typed < letters.len() {
                                typed = (typed + 4).min(letters.len());
                                let draft = format!(
                                    "{starter}{}",
                                    letters[..typed].iter().collect::<String>()
                                );
                                window.update(cx, |shell, _, cx| {
                                    shell.fixture_composer_text(&draft, cx)
                                })?;
                                pause(cx, 50).await;
                                reel.capture(any, cx, 0.05)?;
                            }
                            reel.capture(any, cx, 0.4)?;
                        }};
                    }
                    // Send `scene`: its chat joins the sidebar and opens, then the
                    // agent's parts arrive one at a time. `peer` keeps an unfocused
                    // split pane showing its finished chat.
                    macro_rules! send {
                        ($scene:expr, $peer:expr) => {{
                            let scene: &Scene = $scene;
                            let peer: Option<&Scene> = $peer;
                            let meta = chats.iter().find(|chat| chat.id == scene.chat).cloned();
                            state.update(cx, |state, cx| {
                                state.chats.extend(meta);
                                state.select_chat(Some(scene.chat.into()), cx);
                            });
                            pause(cx, 900).await;
                            created += 120_000;
                            for shown in 0..=scene.steps.len() {
                                let entries = scene.entries(&device, shown, created);
                                state.update(cx, |state, cx| {
                                    if let Some(peer) = peer {
                                        state.set_subagent_snapshot(
                                            peer.chat.into(),
                                            serde_json::from_value(peer.entries(
                                                &device,
                                                peer.steps.len(),
                                                1_788_900_120_000,
                                            ))
                                            .unwrap(),
                                        );
                                    }
                                    state
                                        .receive_transcript_frame(
                                            harness_doc::TranscriptFrame::Reset {
                                                reset: serde_json::from_value(entries).unwrap(),
                                            },
                                            cx,
                                        )
                                        .unwrap();
                                    cx.notify();
                                });
                                pause(cx, 350).await;
                                let hold = match shown {
                                    0 => 0.45,
                                    _ if shown == scene.steps.len() => 2.4,
                                    _ => 0.5,
                                };
                                reel.capture(any, cx, hold)?;
                            }
                        }};
                    }

                    pause(cx, 1500).await;

                    // 1. graff is the default agent; its menu lists frontier models.
                    reel.chapter("agents");
                    reel.capture(any, cx, 0.9)?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_model_menu(true, window, cx)
                    })?;
                    pause(cx, 1500).await;
                    reel.capture(any, cx, 2.2)?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_model_menu(false, window, cx)
                    })?;
                    pause(cx, 500).await;

                    // 2. Build from zero with a starter.
                    reel.chapter("build");
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_onboarding_starter("build", cx)
                    })?;
                    pause(cx, 700).await;
                    reel.capture(any, cx, 0.6)?;
                    type_idea!(build);
                    send!(&build, None);

                    // 3. ⌘D: a second pane, where Claude Code takes the follow-up.
                    reel.chapter("split");
                    // The unfocused pane reads its chat from a doc watch, which
                    // this fixture's engine has no rows for: pin the finished build.
                    macro_rules! pin_build {
                        () => {{
                            state.update(cx, |state, cx| {
                                state.set_subagent_snapshot(
                                    build.chat.into(),
                                    serde_json::from_value(build.entries(
                                        &device,
                                        build.steps.len(),
                                        1_788_900_120_000,
                                    ))
                                    .unwrap(),
                                );
                                cx.notify();
                            });
                            pause(cx, 400).await;
                        }};
                    }
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_onboarding_split(true, window, cx)
                    })?;
                    pause(cx, 900).await;
                    window.update(cx, |shell, _, cx| shell.fixture_composer_text("", cx))?;
                    pin_build!();
                    reel.capture(any, cx, 1.0)?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_model_menu(true, window, cx)
                    })?;
                    pause(cx, 900).await;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_pick_agent(HarnessId::ClaudeCode, Some(reminder.model), cx)
                    })?;
                    pause(cx, 1100).await;
                    pin_build!();
                    reel.capture(any, cx, 1.8)?;
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_model_menu(false, window, cx)
                    })?;
                    pause(cx, 500).await;
                    pin_build!();
                    type_idea!(reminder);
                    send!(&reminder, Some(&build));
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_onboarding_split(false, window, cx)
                    })?;
                    pause(cx, 600).await;

                    // 4 and 5. Not only code: research, then a launch plan.
                    for (chapter, scene) in [("research", &research), ("launch", &launch)] {
                        reel.chapter(chapter);
                        state.update(cx, |state, cx| state.select_chat(None, cx));
                        pause(cx, 500).await;
                        window.update(cx, |shell, _, cx| {
                            shell.fixture_pick_agent(HarnessId::Graff, Some(scene.model), cx);
                            shell.fixture_onboarding_starter(scene.starter.unwrap_or_default(), cx);
                        })?;
                        pause(cx, 700).await;
                        reel.capture(any, cx, 0.5)?;
                        type_idea!(scene);
                        send!(scene, None);
                    }
                    reel.finish()?;
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    eprintln!("starter demo fixture failed: {error:#}");
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
