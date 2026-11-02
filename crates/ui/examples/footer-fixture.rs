//! Interactive footer-overlap preview with synthetic Git sessions and no agent calls.
//! cargo run -p harness-ui --example footer-fixture --features appshots-fixture,project-palette-fixture
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::time::Duration;

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    let _guard = runtime.enter();
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    let output = std::env::current_dir()?.join(".graff");
    std::fs::create_dir_all(&output)?;
    let image = output.join(
        std::env::var("HARNESS_FOOTER_IMAGE").unwrap_or_else(|_| "footer-preview.png".into()),
    );
    let worktree = std::env::var_os("HARNESS_FOOTER_WORKTREE").is_some();
    let capture_only = std::env::var_os("HARNESS_FOOTER_CAPTURE_ONLY").is_some();
    let single_pane = std::env::var_os("HARNESS_FOOTER_SINGLE_PANE").is_some();
    let width = std::env::var("HARNESS_FOOTER_WIDTH")
        .ok()
        .and_then(|value| value.parse::<f32>().ok())
        .unwrap_or(1000.0);
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
                settings.ui_font_family.clone(), settings.ui_font_size,
                settings.terminal_font_family.clone(), settings.terminal_font_size,
                settings.code_font_family.clone(), settings.code_font_size, fonts, cx,
            );
            theme_library::init(data.clone(), cx);
            appearance::init(
                appearance::AppearanceMode::Light, settings.theme_selection,
                settings.accent, settings.surface, cx,
            );
            history::init(Default::default(), Default::default(), Default::default(), Default::default(), cx);
            composer::init(cx, settings.composer_send_behavior);
            terminal::panel::init(cx);
            app_menus::init(cx);
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
                state.local_device_id = Some("preview".into());
                state.devices = vec![serde_json::from_value(serde_json::json!({
                    "id": "preview", "name": "Footer preview", "platform": "macos", "lastSeenAt": null
                })).unwrap()];
                state.spaces = vec![serde_json::from_value(serde_json::json!({
                    "id": "project", "deviceId": "preview", "name": "Footer test project",
                    "path": "/preview/project", "gitDetected": true, "createdAt": "2026-09-01T00:00:00Z"
                })).unwrap()];
                for index in 1..=2 {
                    let branch = format!("feature/long-branch-name-for-footer-test-{index}");
                    let cwd = if worktree {
                        format!("/preview/project/.graff/worktrees/footer-{index}")
                    } else {
                        "/preview/project".into()
                    };
                    state.chats.push(serde_json::from_value(serde_json::json!({
                        "id": format!("footer-{index}"), "deviceId": "preview", "spaceId": "project",
                        "title": format!("Footer test {index}"), "archived": false,
                        "createdAt": "2026-09-01T00:00:00Z", "cwd": cwd, "branch": branch,
                        "config": {
                            "harness": if worktree { "graff" } else { "mock" },
                            "model": if worktree { "chatgpt-new/preview" } else { "mock" },
                            "sandbox": "workspace-write"
                        },
                        "sourceContext": {
                            "checkoutId": format!("checkout-{index}"), "repoRoot": "/preview/project",
                            "cwd": cwd, "branch": branch, "observedAt": "2026-09-01T00:00:00Z"
                        }
                    })).unwrap());
                    state.fixture_sidebar_change_request(harness_proto::CheckoutChangeRequestStatus {
                        checkout_id: format!("checkout-{index}"), device_id: "preview".into(),
                        cwd: "/preview/project".into(), branch: branch.clone(),
                        change_request: Some(harness_proto::ChangeRequestSummary {
                            provider: "github".into(), number: 31 + index, title: "Synthetic footer preview".into(),
                            url: "https://example.invalid/footer-preview".into(),
                            state: harness_proto::ChangeRequestState::Open,
                            base_ref: "main".into(), head_ref: branch,
                        }),
                        updated_at: chrono::Utc::now(),
                    });
                }
                state.selected_chat = Some("footer-1".into());
                state.selected_space = Some("project".into());
                state.auto_selected = true;
                state.chats_synced = true;
                state.spaces_synced = true;
                state
            });
            let boot = EngineBootConfig {
                data_dir: data, ipc_port: 0, edge_url: String::new(), edge_token: None,
                org_id: None, codegraff_client_id: None, default_harness: HarnessId::Mock,
            };
            let window = cx.open_window(WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(60.0), px(70.0)), size(px(width), px(720.0)),
                ))),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some("Harness Dev — Footer overlap preview".into()),
                    appears_transparent: true,
                    traffic_light_position: Some(gpui::point(px(14.0), px(14.0))),
                }),
                app_owns_titlebar_drag: true,
                ..Default::default()
            }, |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx))).unwrap();
            cx.activate(true);
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_millis(1200)).await;
                if !single_pane {
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_onboarding_split(true, window, cx);
                    }).unwrap();
                }
            state.update(cx, |state, cx| {
                state.select_chat(Some("footer-2".into()), cx);
                state.receive_transcript_frame(harness_doc::TranscriptFrame::Reset {
                    reset: serde_json::from_value(serde_json::json!([{
                        "id": "preview-message", "role": "assistant", "createdAt": 0,
                        "deviceId": "preview", "status": "complete", "parts": [{
                            "id": "preview-text", "kind": "text",
                            "text": "Footer overlap preview\n\nThe real composer footer below is populated with checkout, branch, PR, and usage controls. Drag the pane divider to the right to squeeze this pane, or resize the window. This preview uses synthetic data and sends no agent requests."
                        }]
                    }])).unwrap(),
                }, cx).unwrap();
                state.context_usage = Some(harness_proto::ContextUsage {
                    tokens: Some(100_000), window: Some(200_000), ..Default::default()
                });
                cx.notify();
            });
                cx.background_executor().timer(Duration::from_millis(1200)).await;
                let handle: gpui::AnyWindowHandle = window.into();
                let result = handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
                    window.draw(cx).clear();
                    window.render_to_image()?.save(&image)?;
                    println!("Footer preview ready; reference image saved.");
                    Ok(())
                });
                if let Err(error) = result.and_then(|result| result) {
                    eprintln!("Unable to save footer preview: {error}");
                }
                if capture_only {
                    cx.update(|cx| cx.quit());
                }
            }).detach();
        });
    Ok(())
}
