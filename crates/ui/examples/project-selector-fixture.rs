//! Native project selector review fixture, with isolated synthetic data.
//! Pass --output=<path>, --sidebar-width=224|320, and optionally --light.
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, point, px, size};
use harness_ui::*;
use std::time::Duration;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let light = args.iter().any(|arg| arg == "--light");
    let sidebar_width = args
        .iter()
        .find_map(|arg| arg.strip_prefix("--sidebar-width=")?.parse::<f32>().ok())
        .unwrap_or(256.0)
        .clamp(settings::SIDEBAR_MIN, settings::SIDEBAR_MAX);
    let output = args
        .iter()
        .find_map(|arg| arg.strip_prefix("--output=").map(std::path::PathBuf::from));
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let _guard = runtime.enter();
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().to_path_buf();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let mut settings = settings::UiSettings::default();
        settings.sidebar_width = sidebar_width;
        settings.space_filter = Some("a".into());
        settings.theme_selection.light = "warm-harp-light".into();
        settings.theme_selection.dark = "warm-harp-dark".into();
        settings::init(settings.clone(), data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(settings.ui_font_family.clone(), settings.ui_font_size,
            settings.terminal_font_family.clone(), settings.terminal_font_size,
            settings.code_font_family.clone(), settings.code_font_size, fonts, cx);
        theme_library::init(data.clone(), cx);
        appearance::init(if light { appearance::AppearanceMode::Light } else { appearance::AppearanceMode::Dark }, settings.theme_selection,
            settings.accent, settings.surface, cx);
        history::init(settings.git_history_columns, settings.git_history_column_widths,
            settings.git_history_column_order, settings.git_history_author_display, cx);
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut s = state::AppState::new();
            s.connection = harness_proto::view::ConnectionStatus::Ready;
            s.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
            s.local_device_id = Some("local".into());
            s.devices = serde_json::from_value(serde_json::json!([
                {"id":"local","name":"Studio Mac","platform":"macos","lastSeenAt":null},
                {"id":"remote","name":"Build server","platform":"linux","lastSeenAt":null},
                {"id":"long","name":"Design team's very long workstation name","platform":"linux","lastSeenAt":null}
            ])).unwrap();
            s.auto_selected = true;
            s.chats_synced = true;
            s.spaces_synced = true;
            s.spaces = serde_json::from_value(serde_json::json!([
                {"id":"a","deviceId":"local","path":"/projects/anara","createdAt":"2026-09-15T00:00:00Z"},
                {"id":"b","deviceId":"remote","path":"/projects/anara","createdAt":"2026-09-15T00:00:00Z"},
                {"id":"c","deviceId":"long","path":"/projects/design-system-with-a-long-project-name","createdAt":"2026-09-15T00:00:00Z"},
                {"id":"d","deviceId":"unknown","path":"/projects/fieldnotes","createdAt":"2026-09-15T00:00:00Z"}
            ])).unwrap();
            s
        });
        let boot = EngineBootConfig { data_dir: data, ipc_port: 0, edge_url: String::new(),
            edge_token: None, org_id: None, codegraff_client_id: None,
            default_harness: HarnessId::ClaudeCode };
        let window = cx.open_window(WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(0.), px(0.)), size(px(1000.), px(680.))))),
            ..Default::default()
        }, |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx))).unwrap();
        state.update(cx, |_, cx| cx.notify());
        cx.activate(true);
        if let Some(output) = output {
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_millis(400)).await;
                window.update(cx, |shell, window, cx| {
                    shell.fixture_project_selector(sidebar_width, window, cx);
                }).unwrap();
                cx.background_executor().timer(Duration::from_millis(400)).await;
                let capture_window: gpui::AnyWindowHandle = window.into();
                capture_window.update(cx, |_, window, cx| {
                    window.draw(cx).clear();
                    window.render_to_image().unwrap().save(output).unwrap();
                }).unwrap();
                cx.update(|cx| cx.quit());
            }).detach();
        }
    });
}
