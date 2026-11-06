//! Matched upstream/local menu comparisons with isolated synthetic data.
//! Identical Codegraff palettes, System font, cases, dimensions and seed data on both trees.
//! HARNESS_FIXTURE_CAPTURE optionally receives the fixture PID and renderer image path.
//! cargo run -p harness-ui --example pr-menu-review-fixture --features appshots-fixture -- <output>
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, point, px, size};
use harness_ui::*;
use std::{path::Path, path::PathBuf, sync::Arc, time::Duration};

const SELECTED_CHAT: &str = "launch-0";
const PROJECTS: [(&str, &str, [&str; 3]); 3] = [
    (
        "launch",
        "Launch",
        [
            "Refine the launch page",
            "Compare pricing plans",
            "Polish the signup flow",
        ],
    ),
    (
        "mobile",
        "Mobile app",
        [
            "Simplify onboarding",
            "Review offline states",
            "Improve navigation",
        ],
    ),
    (
        "backend",
        "Backend",
        [
            "Add request caching",
            "Review API responses",
            "Update service docs",
        ],
    ),
];

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    output: &Path,
    name: &str,
) -> anyhow::Result<()> {
    let path = output.join(format!("{name}.png"));
    window.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        window.render_to_image()?.save(&path)?;
        Ok(())
    })??;
    if let Some(helper) = std::env::var_os("HARNESS_FIXTURE_CAPTURE") {
        let status = std::process::Command::new(helper)
            .arg(std::process::id().to_string())
            .arg(&path)
            .status()?;
        anyhow::ensure!(status.success(), "native capture helper failed");
    }
    Ok(())
}

fn port() -> anyhow::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port())
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or_else(|| anyhow::anyhow!("usage: menu-review-fixture <output-directory>"))?,
    );
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::Graff,
            None,
        )
    })?;
    let config: harness_proto::ChatConfig = serde_json::from_value(serde_json::json!({
        "harness": "graff", "model": "gpt-6-sol", "reasoning": "high",
        "modelOptions": {}, "sandbox": "workspace-write"
    }))?;
    for (project, label, titles) in PROJECTS {
        // These paths are invented display data, not a user's checkout.
        let path = format!("/projects/{project}");
        core.workspace
            .create_space(project, &core.device_id, &path, Some(label.into()), false)?;
        for (index, title) in titles.into_iter().enumerate() {
            let id = format!("{project}-{index}");
            core.workspace.create_chat(
                &id,
                Some(project),
                Some(&core.device_id),
                Some(config.clone()),
                Some(path.clone()),
            )?;
            core.workspace.rename_chat(&id, title)?;
        }
    }
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
        default_harness: harness_proto::HarnessId::Graff,
    };
    let engine = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let mut chats = core.workspace.read_chats()?;
    let spaces = core.workspace.read_spaces()?;
    let device = core.device_id.clone();
    let now = chrono::Utc::now();
    let mut sessions = Vec::new();
    for (project_index, (project, _, titles)) in PROJECTS.into_iter().enumerate() {
        for index in 0..titles.len() {
            let id = format!("{project}-{index}");
            let chat = chats
                .iter_mut()
                .find(|chat| chat.id == id)
                .expect("seeded chat");
            let minutes = (project_index * 12 + index * 4 + 1) as i64;
            let timestamp = now - chrono::Duration::minutes(minutes);
            chat.created_at = timestamp;
            chat.last_prompt_at = Some(timestamp);
            chat.last_message_at = Some(timestamp);
            chat.last_seen_at = (index != 2).then_some(now);
            chat.branch = Some(format!(
                "feature/{}",
                titles[index].to_lowercase().replace(' ', "-")
            ));
            if index == 1 {
                sessions.push(
                    serde_json::from_value(serde_json::json!({
                        "chatId": id,
                        "deviceId": device.clone(),
                        "status": if project_index == 1 {
                            harness_proto::SessionStatus::Working
                        } else {
                            harness_proto::SessionStatus::AwaitingInput
                        },
                        "startedAt": timestamp,
                        "updatedAt": now,
                        "lastCompletedTurn": null
                    }))
                    .expect("synthetic session"),
                );
            }
        }
    }
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let mut settings = settings::UiSettings::default();
            settings.sidebar_organization = settings::SidebarOrganization::ByProject;
            settings.sidebar_width = 272.;
            settings.sidebar_show_branch = false;
            settings.sidebar_show_project_label = false;
            settings.ui_font_family = typography::UiFontFamily::System;
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
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.fixture_attachment_engine(engine);
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                state.local_device_id = Some(device.clone());
                state.devices = vec![harness_proto::Device {
                    id: device.clone(),
                    name: "This device".into(),
                    platform: std::env::consts::OS.into(),
                    last_seen_at: None,
                    created_at: None,
                    version: None,
                    cursor_sdk_version: None,
                    capabilities: Vec::new(),
                }];
                state.spaces = spaces;
                state.chats = chats;
                state.sessions = sessions;
                state.selected_chat = Some(SELECTED_CHAT.into());
                state.selected_space = Some("launch".into());
                state.auto_selected = true;
                state.chats_synced = true;
                state.spaces_synced = true;
                state
            });
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    for (tone, mode) in [
                        ("light", appearance::AppearanceMode::Light),
                        ("dark", appearance::AppearanceMode::Dark),
                    ] {
                        cx.update(|cx| {
                            appearance::set_theme(theme::Appearance::Light, "codegraff-light", cx);
                            appearance::set_theme(theme::Appearance::Dark, "codegraff-dark", cx);
                            appearance::set_mode(mode, cx);
                        });
                        for &(case, label) in &[
                            ("theme-light", "Light theme selector"),
                            ("theme-dark", "Dark theme selector"),
                            ("titles-harness", "Session title agent"),
                            ("titles-model", "Session title model"),
                        ] {
                            let window: gpui::AnyWindowHandle = cx
                                .update(|cx| {
                                    cx.open_window(
                                        WindowOptions {
                                            window_bounds: Some(WindowBounds::Windowed(
                                                Bounds::new(
                                                    point(px(30.), px(40.)),
                                                    size(px(900.), px(680.)),
                                                ),
                                            )),
                                            titlebar: None,
                                            ..Default::default()
                                        },
                                        |window, cx| {
                                            window.set_rem_size(px(16.));
                                            cx.new(|cx| {
                                                menu_review::MenuReview::new(
                                                    case,
                                                    label,
                                                    state.clone(),
                                                    boot.clone(),
                                                    cx,
                                                )
                                            })
                                        },
                                    )
                                })?
                                .into();
                            window.update(cx, |_, window, cx| window.draw(cx).clear())?;
                            if case == "link-context" {
                                window.update(cx, |_, window, cx| {
                                    window.dispatch_event(
                                        gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                            button: gpui::MouseButton::Right,
                                            position: point(px(90.), px(120.)),
                                            click_count: 1,
                                            ..Default::default()
                                        }),
                                        cx,
                                    );
                                })?;
                            }
                            pause(cx, 300).await;
                            window.update(cx, |_, window, cx| {
                                window.refresh();
                                window.draw(cx).clear();
                            })?;
                            pause(cx, 200).await;
                            capture(window, cx, &output, &format!("{case}-{tone}"))?;
                            window.update(cx, |_, window, _| window.remove_window())?;
                        }
                    }
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err();
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
