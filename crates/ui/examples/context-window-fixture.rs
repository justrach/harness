//! The composer's context window card from synthetic data: no engine, no
//! agent calls. It fills, compacts, then settles, and repeats.
//! `HARNESS_FIXTURE_CONTEXT=full|compacting|compacted` holds one stage instead.
//! cargo run -p harness-ui --example context-window-fixture
use std::time::Duration;

use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, size,
};
use harness_ui::*;

fn text(id: &str, role: &str, bytes: usize) -> serde_json::Value {
    serde_json::json!({
        "id": id, "role": role, "createdAt": 0, "deviceId": "preview", "status": "complete",
        "parts": [{"id": format!("{id}-text"), "kind": "text", "text": "x".repeat(bytes)}]
    })
}

fn tool(id: &str, call: serde_json::Value, bytes: u64, resolved: bool) -> serde_json::Value {
    serde_json::json!({
        "id": id, "role": "assistant", "createdAt": 0, "deviceId": "preview", "status": "complete",
        "parts": [{"id": format!("{id}-tool"), "kind": "tool", "call": call,
                   "resolved": resolved, "outputBytes": bytes}]
    })
}

/// The synthetic chat at each stage, with what its agent's meter reports.
fn stage(name: &str) -> (Vec<serde_json::Value>, u64, u64) {
    let mut rows = vec![
        text("ask", "user", 52_000),
        text("reply", "assistant", 112_000),
        tool(
            "read",
            serde_json::json!({"kind": "readFile", "path": "pricing.md"}),
            72_000,
            true,
        ),
        tool(
            "grep",
            serde_json::json!({"kind": "search", "pattern": "fee"}),
            40_000,
            true,
        ),
        tool(
            "run",
            serde_json::json!({"kind": "exec", "command": "make test"}),
            56_000,
            true,
        ),
        tool(
            "web",
            serde_json::json!({"kind": "webFetch", "url": "https://example.invalid/docs"}),
            32_000,
            true,
        ),
    ];
    let compaction = |resolved: bool, bytes: u64| {
        tool(
            "compact",
            serde_json::json!({"kind": "unknown", "name": "Compact context"}),
            bytes,
            resolved,
        )
    };
    match name {
        "compacting" => {
            rows.push(compaction(false, 0));
            (rows, 159_000, 0)
        }
        "compacted" => {
            rows.push(compaction(true, 16_000));
            rows.push(text("after", "user", 2_400));
            rows.push(tool(
                "read2",
                serde_json::json!({"kind": "readFile", "path": "validators.ts"}),
                36_000,
                true,
            ));
            (rows, 82_000, 77_000)
        }
        _ => (rows, 112_000, 0),
    }
}

fn apply(state: &Entity<state::AppState>, name: &str, cx: &mut gpui::App) {
    let (rows, tokens, freed) = stage(name);
    state.update(cx, |state, cx| {
        state
            .receive_transcript_frame(
                harness_doc::TranscriptFrame::Reset {
                    reset: serde_json::from_value(rows.into()).unwrap(),
                },
                cx,
            )
            .unwrap();
        state.context_usage = Some(harness_proto::ContextUsage {
            tokens: Some(tokens),
            window: Some(200_000),
            savings: Some(harness_proto::ContextSavings {
                compacted_tokens: freed,
                ..Default::default()
            }),
        });
        cx.notify();
    });
}

struct Preview {
    card: gpui::AnyView,
}

impl Render for Preview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx).clone();
        div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .bg(theme.bg)
            .child(self.card.clone())
    }
}

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    let _guard = runtime.enter();
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".into()))
        .init();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    let held = std::env::var("HARNESS_FIXTURE_CONTEXT").ok();
    let mode = match std::env::var("HARNESS_FIXTURE_APPEARANCE").as_deref() {
        Ok("dark") => appearance::AppearanceMode::Dark,
        _ => appearance::AppearanceMode::Light,
    };
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
            let state = cx.new(|_| state::AppState::new());
            apply(&state, held.as_deref().unwrap_or("full"), cx);
            // The same card the composer's usage ring opens on hover.
            let card = context_window::usage_card(state.clone(), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(560.), px(400.)),
                    ))),
                    ..Default::default()
                },
                |_, cx| cx.new(|_| Preview { card }),
            )
            .unwrap();
            cx.activate(true);
            if held.is_none() {
                cx.spawn(async move |cx| {
                    loop {
                        for (name, hold) in
                            [("compacting", 2_400), ("compacted", 3_600), ("full", 3_000)]
                        {
                            cx.background_executor()
                                .timer(Duration::from_millis(hold))
                                .await;
                            cx.update(|cx| apply(&state, name, cx));
                        }
                    }
                })
                .detach();
            }
        });
    Ok(())
}
