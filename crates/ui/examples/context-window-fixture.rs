//! The composer's context window card from a simulated session: synthetic
//! turns and meters, no engine, no agent or provider calls. The session
//! fills, compacts at 80% twice, and the card shows the second compaction
//! with the session's trajectory under it. It loops through full,
//! compacting and compacted.
//!
//! `HARNESS_FIXTURE_CONTEXT=full|compacting|compacted` holds one stage.
//! `HARNESS_FIXTURE_KIND=opaque|summary` picks how the agent compacts
//! (default opaque, the way Codex does). `HARNESS_FIXTURE_EXPORT=<path>`
//! writes both kinds' simulated trajectories as JSON and exits.
//! cargo run -p harness-ui --example context-window-fixture
use std::collections::HashMap;
use std::time::Duration;

use gpui::{
    AppContext, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, size,
};
use harness_doc::SessionMessageEntry;
use harness_proto::{CompactionKind, CompactionMeta, ContextSavings, ContextUsage};
use harness_ui::context_trajectory::Trajectory;
use harness_ui::*;

const WINDOW: u64 = 200_000;
/// System prompt and tool schemas: what the transcript never holds.
const SYSTEM: u64 = 14_000;
/// graff's default compaction point.
const COMPACT_AT: u64 = WINDOW * 80 / 100;

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

/// One moment of the simulated session.
#[derive(Clone)]
struct Snapshot {
    rows: Vec<serde_json::Value>,
    usage: ContextUsage,
    trajectory: Trajectory,
}

/// A deterministic synthetic session for `kind`, with the trajectory it
/// leaves and the card's three stages around its second compaction.
fn simulate(kind: CompactionKind) -> (Trajectory, HashMap<&'static str, Snapshot>) {
    let mut seed: u64 = 0x5eed;
    let mut next = |range: u64| {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) % range
    };
    let mut rows: Vec<serde_json::Value> = Vec::new();
    let mut trajectory = Trajectory::default();
    let mut stages = HashMap::new();
    let mut since = 0u64; // transcript bytes since the last compaction
    let mut history = 0u64; // tokens of the item standing in for older chat
    let mut done = 0;
    let mut after_second = 0;
    // graff's savings meta, synthetic like the rest: tokens freed by the
    // compactions so far, and tool output graff parked in files (a quarter
    // of what the tools printed).
    let mut freed = 0u64;
    let mut parked_bytes = 0u64;
    let observe = |rows: &[serde_json::Value], tokens: u64, t: &mut Trajectory| {
        let entries: Vec<SessionMessageEntry> =
            serde_json::from_value(rows.to_vec().into()).unwrap();
        let usage = ContextUsage {
            tokens: Some(tokens),
            window: Some(WINDOW),
            ..Default::default()
        };
        t.observe(Some(usage), &entries);
        usage
    };
    let snap = |rows: &[serde_json::Value],
                usage: ContextUsage,
                t: &Trajectory,
                freed: u64,
                parked_bytes: u64| Snapshot {
        rows: rows.to_vec(),
        usage: ContextUsage {
            savings: Some(ContextSavings {
                handle_bytes: parked_bytes,
                compacted_tokens: freed,
                cache_read_tokens: 0,
            }),
            ..usage
        },
        trajectory: t.clone(),
    };
    for turn in 0..60 {
        let ask = 800 + next(1_600) as usize;
        let reply = 3_000 + next(5_000) as usize;
        rows.push(text(&format!("ask-{turn}"), "user", ask));
        rows.push(text(&format!("reply-{turn}"), "assistant", reply));
        since += (ask + reply) as u64;
        for call in 0..(2 + next(3)) {
            let bytes = 6_000 + next(34_000);
            let call_json = match (turn + call) % 5 {
                0 => serde_json::json!({"kind": "readFile", "path": "src/pricing.rs"}),
                1 => serde_json::json!({"kind": "exec", "command": "cargo test"}),
                2 => serde_json::json!({"kind": "search", "pattern": "fee"}),
                3 => serde_json::json!({"kind": "webFetch", "url": "https://example.invalid/docs"}),
                _ => serde_json::json!({"kind": "unknown", "name": "Update plan"}),
            };
            rows.push(tool(&format!("tool-{turn}-{call}"), call_json, bytes, true));
            since += bytes;
            parked_bytes += bytes / 4;
        }
        let tokens = SYSTEM + history + since.div_ceil(4);
        let usage = observe(&rows, tokens, &mut trajectory);
        if done == 2 {
            after_second += 1;
            if after_second == 1 {
                stages.insert(
                    "compacted",
                    snap(&rows, usage, &trajectory, freed, parked_bytes),
                );
            }
            if after_second == 4 {
                break;
            }
        }
        if tokens < COMPACT_AT {
            continue;
        }
        if done == 1 {
            stages.insert("full", snap(&rows, usage, &trajectory, freed, parked_bytes));
        }
        let id = format!("compact-{done}");
        let mut meta = CompactionMeta::new(kind);
        meta.tokens_before = Some(tokens);
        meta.trigger = Some("auto".into());
        rows.push(tool(
            &id,
            serde_json::json!({"kind": "unknown", "name": "Compact context", "input": meta}),
            0,
            false,
        ));
        if done == 1 {
            observe(&rows, tokens, &mut trajectory);
            stages.insert(
                "compacting",
                snap(&rows, usage, &trajectory, freed, parked_bytes),
            );
        }
        // Synthetic sizes: the item keeps about 6% of what it replaces.
        let item = (history + since.div_ceil(4)) * 6 / 100;
        meta.tokens_after = Some(SYSTEM + item);
        // Codex reports no size for its encrypted item; summaries are text.
        meta.item_tokens = (kind == CompactionKind::Summary).then_some(item);
        rows.pop();
        rows.push(tool(
            &id,
            serde_json::json!({"kind": "unknown", "name": "Compact context", "input": meta}),
            0,
            true,
        ));
        freed += tokens.saturating_sub(SYSTEM + item);
        history = item;
        since = 0;
        observe(&rows, SYSTEM + item, &mut trajectory);
        done += 1;
    }
    (trajectory, stages)
}

fn apply(state: &Entity<state::AppState>, snapshot: &Snapshot, cx: &mut gpui::App) {
    let snapshot = snapshot.clone();
    state.update(cx, |state, cx| {
        state.selected_chat = Some("fixture".into());
        state
            .receive_transcript_frame(
                harness_doc::TranscriptFrame::Reset {
                    reset: serde_json::from_value(snapshot.rows.into()).unwrap(),
                },
                cx,
            )
            .unwrap();
        state.context_usage = Some(snapshot.usage);
        state
            .context_trajectories
            .insert("fixture".into(), snapshot.trajectory);
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
    if let Ok(path) = std::env::var("HARNESS_FIXTURE_EXPORT") {
        let export = serde_json::json!({
            "label": "SIMULATED FIXTURE: synthetic session, no agent or provider calls",
            "window": WINDOW,
            "system": SYSTEM,
            "compactAt": COMPACT_AT,
            "opaque": simulate(CompactionKind::Opaque).0.to_json(),
            "summary": simulate(CompactionKind::Summary).0.to_json(),
        });
        std::fs::write(path, serde_json::to_vec_pretty(&export)?)?;
        return Ok(());
    }
    let held = std::env::var("HARNESS_FIXTURE_CONTEXT").ok();
    let kind = match std::env::var("HARNESS_FIXTURE_KIND").as_deref() {
        Ok("summary") => CompactionKind::Summary,
        _ => CompactionKind::Opaque,
    };
    let (_, stages) = simulate(kind);
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
            apply(&state, &stages[held.as_deref().unwrap_or("full")], cx);
            // The same card the composer's usage ring opens on hover.
            let card = context_window::usage_card(state.clone(), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(560.), px(520.)),
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
                            cx.update(|cx| apply(&state, &stages[name], cx));
                        }
                    }
                })
                .detach();
            }
        });
    Ok(())
}
