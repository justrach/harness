//! The diff pane with and without whitespace changes, from a synthetic patch.
//! cargo run --profile app-dev -p harness-ui --features appshots-fixture \
//!   --example diff-whitespace-fixture -- OUTPUT_DIR
//! Set `GPUI_DISPLAY_LINK=cvdisplaylink`: a `CAMetalDisplayLink` window can't capture.
use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, size,
};
use harness_ui::{changes::Changes, settings, state::AppState, theme::Theme, typography};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

/// `greeting.rs` is reindented with one real edit; `theme.rs` is only reindented.
fn patch() -> String {
    let body = [
        "pub fn greeting(name: &str) -> String {",
        "let trimmed = name.trim();",
        "if trimmed.is_empty() {",
        "return \"Hello there\".to_string();",
        "}",
        "format!(\"Hello, {trimmed}\")",
        "}",
    ];
    let mut patch = String::from(
        "diff --git a/src/greeting.rs b/src/greeting.rs\n--- a/src/greeting.rs\n+++ b/src/greeting.rs\n@@ -1,7 +1,7 @@\n",
    );
    for line in body {
        patch.push_str(&format!("-{line}\n"));
    }
    for line in body {
        let line = line.replace("Hello, {trimmed}", "Hi, {trimmed}");
        patch.push_str(&format!("+    {line}\n"));
    }
    patch.push_str(
        "diff --git a/src/theme.rs b/src/theme.rs\n--- a/src/theme.rs\n+++ b/src/theme.rs\n@@ -1,2 +1,2 @@\n-const ACCENT: u32 = 1;\n-const MUTED: u32 = 2;\n+    const ACCENT: u32 = 1;\n+    const MUTED: u32 = 2;\n",
    );
    patch
}

struct Fixture(Entity<Changes>);
impl Render for Fixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let controls = self
            .0
            .update(cx, |changes, cx| changes.render_header_controls(cx));
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.text)
            .child(div().flex_none().h(px(40.0)).px(px(12.0)).child(controls))
            .child(div().flex_1().min_h_0().child(self.0.clone()))
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(harness_ui::icons::Assets)
        .run(move |cx| {
            gpui_base::init(cx);
            let config = settings::UiSettings::default();
            settings::init(config.clone(), data.path(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                config.ui_font_family,
                config.ui_font_size,
                config.terminal_font_family,
                config.terminal_font_size,
                config.code_font_family,
                config.code_font_size,
                fonts,
                cx,
            );
            cx.set_global(Theme::light());
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.chats = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "chat", "deviceId": "fixture", "cwd": "/fixture/app",
                        "archived": false, "createdAt": "2026-10-01T00:00:00Z",
                    }))
                    .unwrap(),
                ];
                state.selected_chat = Some("chat".into());
                state.local_device_id = Some("fixture".into());
                state
            });
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.0), px(40.0)),
                            size(px(760.0), px(560.0)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| Fixture(cx.new(|cx| Changes::new(state, cx)))),
                )
                .unwrap();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let surface: gpui::AnyWindowHandle = window.into();
                let changes = window.update(cx, |fixture, _, _| fixture.0.clone())?;
                let run: anyhow::Result<()> = async {
                    changes.update(cx, |changes, cx| {
                        changes.fixture_working_tree_diff(
                            serde_json::from_value(serde_json::json!({
                                "checkoutId": "fixture", "deviceId": "fixture",
                                "cwd": "/fixture/app", "patch": patch(), "files": [],
                                "additions": 9, "deletions": 9, "truncated": false,
                                "checksum": "fixture-v1", "updatedAt": "2026-10-01T00:00:00Z",
                            }))
                            .unwrap(),
                            cx,
                        )
                    });
                    for (name, ignore) in [("whitespace-shown", false), ("whitespace-hidden", true)]
                    {
                        changes.update(cx, |changes, cx| {
                            changes.fixture_ignore_whitespace(ignore, cx)
                        });
                        cx.background_executor()
                            .timer(Duration::from_millis(600))
                            .await;
                        surface.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.refresh();
                            window.draw(cx).clear();
                            window
                                .render_to_image()?
                                .save(output.join(format!("{name}.png")))?;
                            Ok(())
                        })??;
                    }
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err();
                let _ = surface.update(cx, |_, window, _| window.remove_window());
                cx.update(|cx| cx.quit());
                anyhow::Ok(())
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
