//! Chat-mode screenshots from isolated synthetic data: no engine calls, no
//! real workspace. `HARNESS_FIXTURE_CHAT_MODE` picks the stage: `code`, `chat`,
//! `menu`, `smart` or `unavailable` (see `Pickers::fixture_chat_mode`).
//! cargo run -p harness-ui --example chat-mode-fixture --features project-palette-fixture
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    let _guard = runtime.enter();
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    let stage = std::env::var("HARNESS_FIXTURE_CHAT_MODE").unwrap_or_else(|_| "chat".into());
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
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
            appearance::AppearanceMode::Dark, settings.theme_selection,
            settings.accent, settings.surface, cx,
        );
        history::init(
            settings.git_history_columns, settings.git_history_column_widths,
            settings.git_history_column_order, settings.git_history_author_display, cx,
        );
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut s = state::AppState::new();
            s.connection = harness_proto::view::ConnectionStatus::Ready;
            s.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
            s.local_device_id = Some("local".into());
            s.devices = serde_json::from_value(serde_json::json!([
                {"id":"local","name":"Studio Mac","platform":"macos","lastSeenAt":null}
            ]))
            .unwrap();
            s.spaces = vec![serde_json::from_value(serde_json::json!({
                "id":"project","deviceId":"local","path":"/tmp/fieldnotes","createdAt":"2026-09-08T00:00:00Z"
            }))
            .unwrap()];
            s.selected_chat = None;
            s.selected_space = Some("project".into());
            s.auto_selected = true;
            s.chats_synced = true;
            s.spaces_synced = true;
            s
        });
        let boot = EngineBootConfig {
            data_dir: data, ipc_port: 0, edge_url: String::new(), edge_token: None,
            org_id: None, codegraff_client_id: None, default_harness: HarnessId::Codex,
        };
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(40.), px(60.)),
                        size(px(900.), px(640.)),
                    ))),
                    titlebar: Some(gpui::TitlebarOptions {
                        title: Some("Chat mode fixture".into()),
                        appears_transparent: true,
                        traffic_light_position: Some(gpui::point(px(14.), px(14.))),
                    }),
                    app_owns_titlebar_drag: true,
                    ..Default::default()
                },
                |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
            )
            .unwrap();
        cx.spawn(async move |cx| {
            loop {
                cx.background_executor().timer(std::time::Duration::from_millis(150)).await;
                if window
                    .update(cx, |shell, window, cx| shell.fixture_chat_mode(&stage, window, cx))
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();
        state.update(cx, |_, cx| cx.notify());
        cx.activate(true);
    });
    Ok(())
}
