//! browse Connected apps evidence with isolated, synthetic data: Settings ›
//! Accounts before the browse card, and the card in each state (browse not
//! running, ready to connect, showing a pairing code, connected).
//!
//! Nothing here reaches the person's own setup: the engine runs on a fresh
//! data directory with its own IPC port, `HOME` is a temporary directory, no
//! browse is found (`HARNESS_BROWSE_CONNECT` names a file that doesn't
//! exist), and `security` on `PATH` is a stub, so no Keychain is read.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example browse-link-fixture -- <dir> [light]`
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::settings::browse_link::BrowseLinkStatus;
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

const CHAT: &str = "browse-link-fixture";

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

/// The card's state for one stage; `None` is the page without the card.
fn stage(name: &str) -> Option<BrowseLinkStatus> {
    let scopes = || vec!["read".to_owned(), "act-own-pages".to_owned()];
    match name {
        "before" => None,
        "unavailable" => Some(BrowseLinkStatus::default()),
        "ready" => Some(BrowseLinkStatus {
            browse_running: true,
            ..Default::default()
        }),
        "pairing" => Some(BrowseLinkStatus {
            browse_running: true,
            pairing_code: Some("482913".into()),
            ..Default::default()
        }),
        "connected" => Some(BrowseLinkStatus {
            browse_running: true,
            paired: true,
            scopes: scopes(),
            ..Default::default()
        }),
        "revoked" => Some(BrowseLinkStatus {
            browse_running: true,
            error: Some(
                "browse no longer knows Harness (revoked, or unused for 30 days). Connect again."
                    .into(),
            ),
            ..Default::default()
        }),
        other => panic!("unknown stage {other}"),
    }
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let light = std::env::args().nth(2).as_deref() == Some("light");
    let suffix = if light { "light" } else { "dark" };
    let stages: Vec<String> = std::env::var("BROWSE_LINK_STAGES")
        .unwrap_or_else(|_| "before,unavailable,ready,pairing,connected,revoked".into())
        .split(',')
        .map(str::to_owned)
        .collect();
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let home = temp.path().join("home");
    let bin = temp.path().join("bin");
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&bin)?;
    {
        use std::os::unix::fs::PermissionsExt as _;
        let stub = bin.join("security");
        // "The specified item could not be found in the keychain."
        std::fs::write(&stub, "#!/bin/sh\nexit 44\n")?;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755))?;
    }
    let ipc_port = std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port();
    // SAFETY: set before any thread is started.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("PATH", format!("{}:/usr/bin:/bin", bin.display()));
        std::env::set_var(
            "HARNESS_BROWSE_CONNECT",
            temp.path().join("no-browse/connect.json"),
        );
        std::env::set_var("HARNESS_IPC_PORT", ipc_port.to_string());
        std::env::set_var("HARNESS_DATA_DIR", temp.path().join("engine"));
    }
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
    core.workspace
        .rename_chat(CHAT, "Compare three laptop stands")?;
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
                            size(px(1100.), px(720.)),
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
                    for name in &stages {
                        let status = stage(name);
                        window.update(cx, |shell, _, cx| shell.fixture_browse_link(status, cx))?;
                        pause(cx, 900).await;
                        capture(
                            window.into(),
                            cx,
                            &output,
                            &format!("browse-link-{name}-{suffix}"),
                        )?;
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
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
