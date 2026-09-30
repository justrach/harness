//! ChatGPT plan QA captured offscreen from the production shell, against a real
//! embedded engine: the card hidden in a stable build, signed out, the wait
//! dialog, on the plan with the one-time welcome, plan usage off, and a build
//! that keeps it off.
//!
//!   cargo run -p harness-ui --example chatgpt-plan-fixture --features appshots-fixture -- OUT_DIR [dark]
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

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
    window.update(cx, |_, window, cx| {
        window.draw(cx).clear();
        window
            .render_to_image()?
            .save(directory.join(format!("{name}.png")))?;
        Ok(())
    })?
}

fn port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn set_plan_switch(value: &str) {
    // SAFETY: the fixture flips it between captures, on one thread of intent.
    unsafe { std::env::set_var("HARNESS_CHATGPT_PLAN", value) };
}

fn sign_in(store: &std::path::Path, plan_usage: bool) {
    std::fs::create_dir_all(store).unwrap();
    let scopes = if plan_usage {
        serde_json::json!(["openid", "email", "chatgpt.tokens.use.direct"])
    } else {
        serde_json::json!(["openid", "email"])
    };
    std::fs::write(
        store.join("credentials.json"),
        serde_json::json!({
            "email": "me@example.com", "access_token": "a", "refresh_token": "r",
            "subject": "s", "client_id": "oaiapp_fixture", "scopes": scopes,
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        store.join("registration.json"),
        serde_json::json!({
            "client_id": "oaiapp_fixture", "subject": "s", "email": "me@example.com",
        })
        .to_string(),
    )
    .unwrap();
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let dark = std::env::args().nth(2).as_deref() == Some("dark");
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let store = temp.path().join("chatgpt");
    // SAFETY: before anything else reads it.
    unsafe {
        std::env::set_var("HARNESS_CHATGPT_HOME", &store);
        std::env::set_var("HARNESS_NO_BROWSER", "1");
    }
    set_plan_switch("0");
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::ClaudeCode,
            None,
        )
    })?;
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
                if dark {
                    appearance::AppearanceMode::Dark
                } else {
                    appearance::AppearanceMode::Light
                },
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
                state.fixture_attachment_engine(handle);
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                state.local_device_id = Some(device.clone());
                state.devices = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": device, "name": "MacBook Pro",
                        "platform": std::env::consts::OS, "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
                state.auto_selected = true;
                state.chats_synced = true;
                state.spaces_synced = true;
                state
            });
            // Tall enough that the whole Accounts page is in one capture.
            let window = cx
                .open_window(
                    WindowOptions {
                        window_background: theme::Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.), px(40.)),
                            size(px(1100.), px(1500.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
                )
                .unwrap();
            state.update(cx, |_, cx| cx.notify());
            cx.activate(true);
            let suffix = if dark { "dark" } else { "light" };
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    let shot = |name: &str| format!("{name}-{suffix}");
                    pause(cx, 1500).await;
                    window.update(cx, |shell, _, cx| shell.fixture_chatgpt_settings(cx))?;
                    pause(cx, 3500).await;
                    // A stable build with nobody signed in: no card at all.
                    capture(window.into(), cx, &output, &shot("01-stable-hidden"))?;

                    // A beta build, signed out: the offer.
                    set_plan_switch("1");
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(|page, cx| page.fixture_chatgpt_reload(cx), cx)
                    })?;
                    pause(cx, 1500).await;
                    capture(window.into(), cx, &output, &shot("02-signed-out"))?;

                    // Tap "Continue with ChatGPT": the wait dialog.
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(|page, cx| page.fixture_chatgpt_start(cx), cx)
                    })?;
                    pause(cx, 4000).await;
                    capture(window.into(), cx, &output, &shot("03-waiting"))?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(|page, cx| page.fixture_chatgpt_cancel(cx), cx)
                    })?;
                    pause(cx, 800).await;

                    // Signed in with plan usage: on the plan, then the one-time welcome.
                    sign_in(&store, true);
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(|page, cx| page.fixture_chatgpt_reload(cx), cx)
                    })?;
                    pause(cx, 1500).await;
                    capture(window.into(), cx, &output, &shot("04-on-plan"))?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(
                            |page, cx| page.fixture_chatgpt_notice("welcome", cx),
                            cx,
                        )
                    })?;
                    pause(cx, 800).await;
                    capture(window.into(), cx, &output, &shot("05-welcome"))?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(
                            |page, cx| page.fixture_chatgpt_notice("none", cx),
                            cx,
                        )
                    })?;

                    // Signed in, but plan usage was not allowed.
                    sign_in(&store, false);
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(|page, cx| page.fixture_chatgpt_reload(cx), cx)
                    })?;
                    pause(cx, 1500).await;
                    capture(window.into(), cx, &output, &shot("06-plan-off"))?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(
                            |page, cx| page.fixture_chatgpt_notice("plan-off", cx),
                            cx,
                        )
                    })?;
                    pause(cx, 800).await;
                    capture(window.into(), cx, &output, &shot("07-plan-off-notice"))?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(
                            |page, cx| page.fixture_chatgpt_notice("none", cx),
                            cx,
                        )
                    })?;

                    // Signed in with plan usage, in a build that keeps it off.
                    sign_in(&store, true);
                    set_plan_switch("0");
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_chatgpt_page(|page, cx| page.fixture_chatgpt_reload(cx), cx)
                    })?;
                    pause(cx, 1500).await;
                    capture(window.into(), cx, &output, &shot("08-off-in-this-build"))?;
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    eprintln!("chatgpt plan fixture failed: {error:#}");
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
