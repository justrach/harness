//! Before/after captures for animated tool-call rows and the Tool Access Map.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example tool-motion-fixture -- <dir> [light|dark|all]`
use std::{path::PathBuf, time::Duration};

use gpui::{
    AppContext, AsyncApp, Bounds, Context, IntoElement, Render, SharedString, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use harness_proto::ToolCall;
use harness_ui::tool_access::{self, MapState};
use harness_ui::tool_call_rows::{self, CallGroup, CallRow, RowResult};
use harness_ui::transcript::{ToolItem, ToolItemKind};
use harness_ui::*;

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
    window.update(cx, |_, w, cx| {
        w.draw(cx).clear();
        match w.render_to_image() {
            Ok(image) => {
                image.save(directory.join(format!("{name}.png")))?;
                Ok(())
            }
            Err(error) => {
                let message = format!("{error:#}");
                if message.contains("not implemented") {
                    eprintln!("skip capture on this platform: {name} ({message})");
                    Ok(())
                } else {
                    Err(error.into())
                }
            }
        }
    })?
}

fn tool(id: &str, call: ToolCall, resolved: bool, is_error: bool) -> ToolItem {
    ToolItem {
        part_id: id.into(),
        call,
        is_error,
        resolved,
        detail: None,
        invocation: None,
        output_ref: None,
        output_bytes: None,
        diff_ref: None,
        subagent_ref: None,
        subagent_status: None,
        subagent_tail: None,
        view: None,
        kind: ToolItemKind::Call,
    }
}

fn sample_tools() -> Vec<ToolItem> {
    vec![
        tool(
            "1",
            ToolCall::Search {
                pattern: "session expiry".into(),
                path: Some("src".into()),
            },
            true,
            false,
        ),
        tool(
            "2",
            ToolCall::ReadFile {
                path: "src/auth/session.ts".into(),
            },
            true,
            false,
        ),
        tool(
            "3",
            ToolCall::EditFile {
                path: "src/auth/session.ts".into(),
                old_string: Some("ttl = 60".into()),
                new_string: Some("ttl = 300".into()),
            },
            true,
            false,
        ),
        tool(
            "4",
            ToolCall::Exec {
                command: "pnpm test -- session".into(),
            },
            true,
            true,
        ),
        tool(
            "5",
            ToolCall::Exec {
                command: "pnpm test -- cookies".into(),
            },
            true,
            false,
        ),
    ]
}

fn after_group() -> CallGroup {
    let mut group = tool_call_rows::from_tools(&sample_tools(), Some(4200));
    // Force settled summaries that match the reference clip.
    if let Some(row) = group.rows.get_mut(0) {
        row.result = RowResult::Summary("12 matches".into());
    }
    if let Some(row) = group.rows.get_mut(1) {
        row.result = RowResult::Summary("3 files".into());
    }
    if let Some(row) = group.rows.get_mut(2) {
        row.result = RowResult::Summary("+10 −4".into());
    }
    if let Some(row) = group.rows.get_mut(3) {
        row.result = RowResult::Failed {
            label: "1 failed".into(),
        };
        row.is_error = true;
    }
    if let Some(row) = group.rows.get_mut(4) {
        row.result = RowResult::Passed {
            label: "48 passed".into(),
        };
    }
    group.failed = 1;
    group.live = false;
    group.file_diffs = vec![
        harness_doc::ToolDiffStat {
            path: "session.ts".into(),
            additions: 10,
            deletions: 4,
        },
        harness_doc::ToolDiffStat {
            path: "cookies.ts".into(),
            additions: 2,
            deletions: 1,
        },
    ];
    group
}

fn before_rows() -> Vec<CallRow> {
    // Stand-in for the previous one-line chips: verb + path, no scramble,
    // no result pills, no dither.
    after_group()
        .rows
        .into_iter()
        .map(|mut row| {
            row.result = RowResult::Summary("".into());
            row
        })
        .collect()
}

fn access_map() -> MapState {
    tool_access::from_chat(
        "graff",
        "codegraff/auto",
        "Fix session expiry",
        false,
        &sample_tools(),
    )
}

struct Shot {
    kind: SharedString,
}

impl Render for Shot {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx).clone();
        let reduce = cx.reduce_motion();
        let phase = 0.35_f32;
        let kind = self.kind.as_ref();
        let body = match kind {
            "before-rows" => {
                let rows = before_rows();
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .h(px(28.0))
                            .flex()
                            .items_center()
                            .text_size(px(12.0))
                            .text_color(theme.text_muted)
                            .child(format!("{} tool calls", rows.len())),
                    )
                    .children(rows.into_iter().map(|row| {
                        div()
                            .h(px(28.0))
                            .px(px(8.0))
                            .rounded(px(6.0))
                            .flex()
                            .items_center()
                            .gap(px(8.0))
                            .bg(theme.ink(0.04))
                            .child(
                                icons::icon(row.icon)
                                    .size(px(12.0))
                                    .text_color(theme.text_muted),
                            )
                            .child(
                                div()
                                    .text_size(px(12.0))
                                    .text_color(theme.text)
                                    .child(format!("{}  {}", row.verb, row.detail)),
                            )
                    }))
                    .into_any_element()
            }
            "after-rows" => {
                let group = after_group();
                tool_call_rows::group(&group, true, &theme, phase, reduce)
            }
            "after-expanded-rows" => {
                // Expanded toolbar: same animated rows, with one disclosure open
                // so INPUT/OUTPUT sits under the prettier header (not the old chip).
                let group = after_group();
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .child(tool_call_rows::header(&group, true, &theme, phase, reduce))
                    .children(group.rows.iter().enumerate().map(|(ix, r)| {
                        let open = ix == 2;
                        let row = tool_call_rows::row(r, &theme, phase, reduce, Some(open));
                        if open {
                            div()
                                .flex()
                                .flex_col()
                                .child(row)
                                .child(
                                    div()
                                        .mt(px(2.0))
                                        .ml(px(8.0))
                                        .px(px(10.0))
                                        .py(px(8.0))
                                        .rounded(px(8.0))
                                        .bg(theme.ink(0.04))
                                        .child(
                                            div()
                                                .text_size(px(11.0))
                                                .text_color(theme.text_muted)
                                                .child("INPUT"),
                                        )
                                        .child(
                                            div()
                                                .mt(px(4.0))
                                                .font_family(theme.font_mono.clone())
                                                .text_size(px(11.0))
                                                .text_color(theme.text)
                                                .child(r.detail.clone()),
                                        )
                                        .child(
                                            div()
                                                .mt(px(8.0))
                                                .text_size(px(11.0))
                                                .text_color(theme.text_muted)
                                                .child("OUTPUT"),
                                        )
                                        .child(
                                            div()
                                                .mt(px(4.0))
                                                .text_size(px(11.0))
                                                .text_color(theme.success)
                                                .child("+48 −12"),
                                        ),
                                )
                                .into_any_element()
                        } else {
                            row
                        }
                    }))
                    .into_any_element()
            }
            "access-map" => {
                let state = access_map();
                tool_access::body(&state, &theme, phase, reduce)
            }
            "access-detail" => {
                let mut state = access_map();
                state.selected_tool = Some("search".into());
                tool_access::body(&state, &theme, phase, reduce)
            }
            _ => div().child("unknown").into_any_element(),
        };

        let title: SharedString = match kind {
            "before-rows" => "Before — tool call chips",
            "after-rows" => "After — animated tool call rows",
            "after-expanded-rows" => "After — expanded tool toolbar",
            "access-map" => "After — Tool Access Map",
            "access-detail" => "After — Tool Access detail",
            other => other,
        }
        .into();

        div()
            .size_full()
            .bg(theme.bg)
            .text_color(theme.text)
                        .p(px(24.0))
            .flex()
            .flex_col()
            .gap(px(12.0))
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(typography::WEIGHT_STRONG)
                    .child(title),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .rounded(px(12.0))
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.surface)
                    .p(px(16.0))
                    .child(body),
            )
    }
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let tone = std::env::args().nth(2).unwrap_or_else(|| "all".into());
    std::fs::create_dir_all(&output)?;
    let tones: Vec<(&str, appearance::AppearanceMode)> = match tone.as_str() {
        "light" => vec![("light", appearance::AppearanceMode::Light)],
        "dark" => vec![("dark", appearance::AppearanceMode::Dark)],
        _ => vec![
            ("light", appearance::AppearanceMode::Light),
            ("dark", appearance::AppearanceMode::Dark),
        ],
    };
    let kinds = ["before-rows", "after-rows", "after-expanded-rows", "access-map", "access-detail"];
    let failure = std::sync::Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
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
            // First tone; switched per capture below.
            appearance::init(
                tones[0].1,
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.), px(40.)),
                            size(px(920.), px(720.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| {
                        cx.new(|_| Shot {
                            kind: "before-rows".into(),
                        })
                    },
                )
                .unwrap();
            cx.activate(true);
            let tones = tones;
            let kinds = kinds;
            let output = output;
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    pause(cx, 400).await;
                    for (suffix, mode) in tones {
                        cx.update(|cx| {
                            appearance::set_mode(mode, cx);
                        });
                        pause(cx, 200).await;
                        for kind in kinds {
                            window.update(cx, |shot, _, cx| {
                                shot.kind = kind.into();
                                cx.notify();
                            })?;
                            pause(cx, 250).await;
                            capture(
                                window.into(),
                                cx,
                                &output,
                                &format!("tool-motion-{kind}-{suffix}"),
                            )?;
                        }
                    }
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err().map(|e| format!("{e:#}"));
                let _ = window.update(cx, |_, w, _| w.remove_window());
                pause(cx, 100).await;
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!("{error}");
    }
    Ok(())
}
