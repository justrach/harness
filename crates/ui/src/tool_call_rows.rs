//! Animated one-line tool-call rows for the chat transcript.
//!
//! Compact rows under a "N tool calls" header (collapsed or expanded): an active row sits in a gray
//! pill with a scramble on the middle of its path and a ticking timer; a
//! finished row fades the pill away, settles the path, and shows a short
//! result (`12 matches`, `+8 −3`, `48 passed`); a failed or passed test run
//! paints a dither wash from the right into a status pill. Aggregate file
//! diffs land under the list once the turn settles.
//!
//! Everything shown comes from real [`ToolItem`] values (the same model the
//! transcript already builds from tool events). Fixtures feed synthetic
//! items for screenshots; production paths never invent tools.
//!
//! Motion: scramble and timers ride the shared pulse clock; dither fills and
//! pill fades use [`crate::motion::EASE_OUT_QUINT`]. Reduced motion snaps.
use gpui::{
    AnyElement, App, EntityId, Hsla, IntoElement, PathBuilder, SharedString, canvas, div, point,
    prelude::*, px,
};
use harness_doc::ToolDiffStat;
use harness_proto::ToolCall;

use crate::icons;
use crate::motion::{self, CubicBezier, MotionSpec};
use crate::theme::Theme;
use crate::transcript::{tool_icon_path, ToolDetail, ToolItem, ToolItemKind};
use crate::typography::{CAP_CENTER_NUDGE, TEXT_BODY, TEXT_CAPTION, TabularNums, WEIGHT_REGULAR, WEIGHT_STRONG};

/// One row tall, matching the activity-rail tool rows.
pub const ROW_HEIGHT: f32 = 28.0;
/// Active pill radius.
pub const PILL_RADIUS: f32 = 8.0;
/// Status pill (pass / fail) radius.
pub const STATUS_RADIUS: f32 = 6.0;

fn fg_on(bg: Hsla) -> Hsla {
    if crate::theme::contrast_ratio(gpui::white(), bg)
        >= crate::theme::contrast_ratio(gpui::black(), bg)
    {
        gpui::white()
    } else {
        gpui::black()
    }
}
/// Header chevron + title line.
pub const HEADER_HEIGHT: f32 = 24.0;

const SCRAMBLE_TICK: MotionSpec = MotionSpec::new(80, CubicBezier::new(0.0, 0.0, 1.0, 1.0));

/// How a row presents its trailing result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowResult {
    /// Still running: show elapsed seconds.
    Running { elapsed_ms: u64 },
    /// Settled success text (`12 matches`, `3 files`, `+8 −3`).
    Summary(SharedString),
    /// Diff counts on the right.
    Diff { additions: u64, deletions: u64 },
    /// Test / command failure: red dither + pill.
    Failed { label: SharedString },
    /// Test / command pass: green dither + pill.
    Passed { label: SharedString },
}

/// One animated tool row, derived from a [`ToolItem`].
#[derive(Debug, Clone, PartialEq)]
pub struct CallRow {
    pub id: SharedString,
    pub verb: SharedString,
    pub detail: SharedString,
    pub icon: &'static str,
    pub result: RowResult,
    pub is_error: bool,
    pub resolved: bool,
}

/// The list under a tool-group header, plus optional aggregate file diffs.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CallGroup {
    pub rows: Vec<CallRow>,
    pub failed: usize,
    pub live: bool,
    pub file_diffs: Vec<ToolDiffStat>,
}

impl CallGroup {
    pub fn header_label(&self) -> String {
        let n = self.rows.len();
        let tools = if n == 1 { "tool call" } else { "tool calls" };
        if self.failed > 0 {
            format!("{n} {tools}, {} failed", self.failed)
        } else {
            format!("{n} {tools}")
        }
    }
}

/// Build the animated group from the transcript's real tool items.
pub fn from_tools(tools: &[ToolItem], elapsed_ms: Option<u64>) -> CallGroup {
    let mut rows = Vec::new();
    let mut failed = 0usize;
    let mut live = false;
    let mut file_diffs: Vec<ToolDiffStat> = Vec::new();
    for tool in tools {
        if tool.kind != ToolItemKind::Call {
            continue;
        }
        if tool.call.is_subagent_spawn() {
            continue;
        }
        let row = call_row(tool, elapsed_ms.unwrap_or(0));
        if row.is_error {
            failed += 1;
        }
        if !row.resolved {
            live = true;
        }
        collect_diffs(tool, &mut file_diffs);
        rows.push(row);
    }
    CallGroup {
        rows,
        failed,
        live,
        file_diffs,
    }
}

fn collect_diffs(tool: &ToolItem, out: &mut Vec<ToolDiffStat>) {
    let Some(detail) = tool.detail.as_ref() else {
        return;
    };
    match detail.as_ref() {
        ToolDetail::Stats { stats } => {
            for stat in stats.iter() {
                merge_stat(out, stat.clone());
            }
        }
        ToolDetail::Diff { file, .. } => {
            merge_stat(
                out,
                ToolDiffStat {
                    path: file.path.clone(),
                    additions: file.additions as u64,
                    deletions: file.deletions as u64,
                },
            );
        }
        _ => {}
    }
}

fn merge_stat(out: &mut Vec<ToolDiffStat>, stat: ToolDiffStat) {
    if let Some(existing) = out.iter_mut().find(|s| s.path == stat.path) {
        existing.additions = existing.additions.saturating_add(stat.additions);
        existing.deletions = existing.deletions.saturating_add(stat.deletions);
    } else {
        out.push(stat);
    }
}

fn call_row(tool: &ToolItem, elapsed_ms: u64) -> CallRow {
    let (verb, detail) = harness_proto::view::tool_chip_content(&tool.call);
    let result = row_result(tool, elapsed_ms);
    CallRow {
        id: SharedString::from(tool.part_id.clone()),
        verb: SharedString::from(verb),
        detail: SharedString::from(detail),
        icon: tool_icon_path(&tool.call),
        result,
        is_error: tool.is_error,
        resolved: tool.resolved,
    }
}

fn row_result(tool: &ToolItem, elapsed_ms: u64) -> RowResult {
    if !tool.resolved {
        return RowResult::Running { elapsed_ms };
    }
    if let Some(detail) = tool.detail.as_ref() {
        match detail.as_ref() {
            ToolDetail::Stats { stats } if !stats.is_empty() => {
                if stats.len() == 1 {
                    return RowResult::Diff {
                        additions: stats[0].additions,
                        deletions: stats[0].deletions,
                    };
                }
                return RowResult::Summary(SharedString::from(format!("{} files", stats.len())));
            }
            ToolDetail::Diff { file, .. } => {
                return RowResult::Diff {
                    additions: file.additions as u64,
                    deletions: file.deletions as u64,
                };
            }
            ToolDetail::Output { lines, .. } => {
                if let Some(parsed) = parse_test_outcome(lines) {
                    return parsed;
                }
                if let Some(summary) = search_summary(tool, lines) {
                    return RowResult::Summary(summary);
                }
            }
            _ => {}
        }
    }
    if tool.is_error {
        return RowResult::Failed {
            label: SharedString::from("1 failed"),
        };
    }
    match &tool.call {
        ToolCall::Search { .. } | ToolCall::Glob { .. } => {
            RowResult::Summary(SharedString::from("matches"))
        }
        ToolCall::ReadFile { .. } => RowResult::Summary(SharedString::from("1 file")),
        ToolCall::EditFile { .. } | ToolCall::WriteFile { .. } | ToolCall::ApplyPatch { .. } => {
            RowResult::Summary(SharedString::from("edited"))
        }
        ToolCall::Exec { .. } => RowResult::Summary(SharedString::from("done")),
        _ => RowResult::Summary(SharedString::from("done")),
    }
}

fn parse_test_outcome(lines: &[SharedString]) -> Option<RowResult> {
    let text = lines
        .iter()
        .map(|l| l.as_ref())
        .collect::<Vec<_>>()
        .join("\n");
    let lower = text.to_ascii_lowercase();
    if let Some(n) = capture_count(&lower, "failed") {
        if n > 0 {
            return Some(RowResult::Failed {
                label: SharedString::from(format!("{n} failed")),
            });
        }
    }
    if let Some(n) = capture_count(&lower, "passed") {
        return Some(RowResult::Passed {
            label: SharedString::from(format!("{n} passed")),
        });
    }
    None
}

fn capture_count(text: &str, word: &str) -> Option<u64> {
    for token in text.split(|c: char| !c.is_ascii_alphanumeric()) {
        // patterns like "48 passed" / "failed: 1" already split; look nearby
        let _ = token;
    }
    // "48 passed" / "1 failed" / "tests: 1 failed"
    let needle = format!(" {word}");
    if let Some(ix) = text.find(&needle) {
        let before = &text[..ix];
        let num: String = before
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        if let Ok(n) = num.parse::<u64>() {
            return Some(n);
        }
    }
    let needle2 = format!("{word}:");
    if let Some(ix) = text.find(&needle2) {
        let after = text[ix + needle2.len()..]
            .trim_start()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        if let Ok(n) = after.parse::<u64>() {
            return Some(n);
        }
    }
    None
}

fn search_summary(tool: &ToolItem, lines: &[SharedString]) -> Option<SharedString> {
    if !matches!(tool.call, ToolCall::Search { .. } | ToolCall::Glob { .. }) {
        return None;
    }
    let n = lines
        .iter()
        .filter(|l| !l.trim().is_empty())
        .count()
        .max(1);
    Some(SharedString::from(format!(
        "{n} {}",
        if n == 1 { "match" } else { "matches" }
    )))
}

// ---------------------------------------------------------------------------
// Scramble
// ---------------------------------------------------------------------------

const SCRAMBLE_GLYPHS: &[char] = &[
    '░', '▒', '▓', '·', '•', '◦', '▪', '▫', '×', '+', '›', '‹',
];

/// Scramble the middle of `text` while a tool is active. Ends stay readable
/// so the file name / query still anchors the row.
pub fn scramble_middle(text: &str, phase: f32) -> String {
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    if n < 6 {
        return text.to_owned();
    }
    let keep_head = (n / 4).clamp(2, 8);
    let keep_tail = (n / 4).clamp(2, 10);
    if keep_head + keep_tail >= n {
        return text.to_owned();
    }
    let seed = ((phase * 97.0).floor() as usize).wrapping_mul(31).wrapping_add(n);
    let mut out = String::with_capacity(text.len());
    for (i, ch) in chars.into_iter().enumerate() {
        if i < keep_head || i >= n - keep_tail || ch == '/' || ch == '\\' || ch == ' ' {
            out.push(ch);
        } else {
            let g = SCRAMBLE_GLYPHS[(seed.wrapping_add(i * 17)) % SCRAMBLE_GLYPHS.len()];
            out.push(g);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Dither wash (pass / fail)
// ---------------------------------------------------------------------------

/// Right-origin dither wash into `color`. Density falls off toward the left.
fn dither_wash(color: Hsla, strength: f32) -> AnyElement {
    let strength = strength.clamp(0.0, 1.0);
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let w = f32::from(bounds.size.width).max(1.0);
            let h = f32::from(bounds.size.height).max(1.0);
            let cell = 2.0_f32;
            let cols = (w / cell).ceil() as i32;
            let rows = (h / cell).ceil() as i32;
            for row in 0..rows {
                for col in 0..cols {
                    let x = col as f32 * cell;
                    let y = row as f32 * cell;
                    // Right-heavy: density rises toward the right edge.
                    let t = (x / w).clamp(0.0, 1.0);
                    let density = (t * t * strength * 0.85).clamp(0.0, 1.0);
                    let hash = ((col.wrapping_mul(374761393))
                        .wrapping_add(row.wrapping_mul(668265263)))
                        as u32;
                    let bit = ((hash >> 16) ^ hash) & 0xff;
                    if (bit as f32 / 255.0) > density {
                        continue;
                    }
                    let mut path = PathBuilder::fill();
                    let origin = point(bounds.origin.x + px(x), bounds.origin.y + px(y));
                    path.move_to(origin);
                    path.line_to(point(origin.x + px(cell), origin.y));
                    path.line_to(point(origin.x + px(cell), origin.y + px(cell)));
                    path.line_to(point(origin.x, origin.y + px(cell)));
                    path.close();
                    if let Ok(built) = path.build() {
                        window.paint_path(built, color.opacity(0.55 + 0.35 * t));
                    }
                }
            }
        },
    )
    .absolute()
    .inset_0()
    .into_any_element()
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

/// Header: chevron + "N tool calls[, M failed]" with a spinner while live.
pub fn header(
    group: &CallGroup,
    open: bool,
    theme: &Theme,
    phase: f32,
    reduce_motion: bool,
) -> AnyElement {
    let label = group.header_label();
    div()
        .h(px(HEADER_HEIGHT))
        .w_full()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.0))
        .text_size(px(TEXT_CAPTION))
        .text_color(theme.text_muted)
        .child(
            icons::icon(if open {
                icons::ALT_ARROW_DOWN
            } else {
                icons::ALT_ARROW_RIGHT
            })
            .size(px(12.0))
            .text_color(theme.text_faint),
        )
        .when(group.live && !reduce_motion, |row| {
            row.child(crate::agent_work::spinner(
                12.0,
                1.5,
                theme.text_muted,
                theme.ink(0.08),
                phase,
            ))
        })
        .when(group.live && reduce_motion, |row| {
            row.child(
                div()
                    .size(px(12.0))
                    .rounded_full()
                    .border_1()
                    .border_color(theme.text_muted.opacity(0.5)),
            )
        })
        .when(!group.live && group.failed == 0, |row| {
            row.child(
                icons::icon(icons::CHECK)
                    .size(px(12.0))
                    .text_color(theme.success)
                    .mt(px(CAP_CENTER_NUDGE)),
            )
        })
        .child(SharedString::from(label))
        .into_any_element()
}

/// One compact animated row.
///
/// `disclosure` is `Some(open)` when the row can expand to show INPUT/OUTPUT
/// under it (chevron on the trailing edge); `None` for a plain one-line row.
pub fn row(
    row: &CallRow,
    theme: &Theme,
    phase: f32,
    reduce_motion: bool,
    disclosure: Option<bool>,
) -> AnyElement {
    let active = matches!(row.result, RowResult::Running { .. });
    let detail = if active && !reduce_motion {
        SharedString::from(scramble_middle(row.detail.as_ref(), phase))
    } else {
        row.detail.clone()
    };
    let (wash, status) = match &row.result {
        RowResult::Failed { label } => (
            Some((theme.danger, 1.0)),
            Some(status_pill(label.clone(), theme.danger, fg_on(theme.danger))),
        ),
        RowResult::Passed { label } => (
            Some((theme.success, 1.0)),
            Some(status_pill(label.clone(), theme.success, fg_on(theme.success))),
        ),
        _ => (None, None),
    };
    let trail = match &row.result {
        RowResult::Running { elapsed_ms } => Some(timer_label(*elapsed_ms, theme)),
        RowResult::Summary(text) => Some(
            div()
                .flex_none()
                .text_size(px(TEXT_CAPTION))
                .text_color(theme.text_muted)
                .child(text.clone())
                .into_any_element(),
        ),
        RowResult::Diff {
            additions,
            deletions,
        } => Some(diff_trail(*additions, *deletions, theme)),
        RowResult::Failed { .. } | RowResult::Passed { .. } => status,
    };

    let body = div()
        .relative()
        .h(px(ROW_HEIGHT))
        .w_full()
        .min_w_0()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(8.0))
        .px(px(8.0))
        .rounded(px(PILL_RADIUS))
        // Active row: clear gray pill highlight (Shawn-style).
        .when(active, |el| {
            el.bg(theme.ink(0.08))
                .border_1()
                .border_color(crate::theme::hairline(0.10))
        })
        .when(!active, |el| el.opacity(if row.is_error { 0.95 } else { 0.82 }))
        .when_some(wash, |el, (color, strength)| {
            el.child(dither_wash(color, strength))
        })
        .child(
            icons::icon(row.icon)
                .size(px(12.0))
                .flex_none()
                .text_color(if row.is_error {
                    theme.danger
                } else if active {
                    theme.text
                } else {
                    theme.text_muted
                })
                .mt(px(CAP_CENTER_NUDGE)),
        )
        .child(
            div()
                .flex_none()
                .text_size(px(TEXT_BODY))
                .font_weight(if active { WEIGHT_STRONG } else { WEIGHT_REGULAR })
                .text_color(if row.is_error {
                    theme.danger
                } else if active {
                    theme.text
                } else {
                    theme.text_muted
                })
                .child(row.verb.clone()),
        )
        .child(
            div()
                .min_w_0()
                .flex_1()
                .truncate()
                .font_family(theme.font_mono.clone())
                .text_size(px(TEXT_CAPTION))
                .text_color(if row.is_error {
                    theme.danger
                } else if active {
                    theme.text
                } else {
                    theme.text.opacity(0.85)
                })
                .child(detail),
        )
        .children(trail)
        .when_some(disclosure, |el, open| {
            el.child(
                icons::icon(if open {
                    icons::ALT_ARROW_UP
                } else {
                    icons::ALT_ARROW_DOWN
                })
                .size(px(10.0))
                .flex_none()
                .text_color(theme.text_muted)
                .mt(px(CAP_CENTER_NUDGE)),
            )
        });

    // Failed rows stay more opaque (already set); pass/fail icons replace verb icon when settled tests.
    match &row.result {
        RowResult::Failed { .. } => body
            .child(
                // Leading X is already reflected via danger tint; keep layout.
                div().size(px(0.0)),
            )
            .into_any_element(),
        _ => body.into_any_element(),
    }
}

fn status_pill(label: SharedString, bg: Hsla, fg: Hsla) -> AnyElement {
    div()
        .flex_none()
        .h(px(20.0))
        .px(px(8.0))
        .rounded(px(STATUS_RADIUS))
        .bg(bg)
        .text_color(fg)
        .text_size(px(TEXT_CAPTION))
        .font_weight(WEIGHT_STRONG)
        .flex()
        .items_center()
        .child(label)
        .into_any_element()
}

fn timer_label(elapsed_ms: u64, theme: &Theme) -> AnyElement {
    let secs = elapsed_ms as f32 / 1000.0;
    let text = if secs < 10.0 {
        format!("{secs:.1}s")
    } else {
        format!("{:.0}s", secs)
    };
    div()
        .flex_none()
        .text_size(px(TEXT_CAPTION))
        .text_color(theme.text_muted)
        .tabular_nums()
        .child(SharedString::from(text))
        .into_any_element()
}

fn diff_trail(additions: u64, deletions: u64, theme: &Theme) -> AnyElement {
    div()
        .flex_none()
        .flex()
        .gap(px(6.0))
        .text_size(px(TEXT_CAPTION))
        .tabular_nums()
        .child(
            div()
                .text_color(theme.success)
                .child(SharedString::from(format!("+{additions}"))),
        )
        .child(
            div()
                .text_color(theme.danger)
                .child(SharedString::from(format!("−{deletions}"))),
        )
        .into_any_element()
}

/// Aggregate file diffs under the rows (`session.ts +10 −4`).
pub fn file_diff_summary(stats: &[ToolDiffStat], theme: &Theme) -> AnyElement {
    div()
        .w_full()
        .min_w_0()
        .pt(px(4.0))
        .flex()
        .flex_row()
        .flex_wrap()
        .gap(px(10.0))
        .text_size(px(TEXT_CAPTION))
        .font_family(theme.font_mono.clone())
        .children(stats.iter().map(|stat| {
            let name = stat
                .path
                .rsplit(['/', '\\'])
                .find(|c| !c.is_empty())
                .unwrap_or(stat.path.as_str());
            div()
                .flex()
                .gap(px(6.0))
                .items_center()
                .child(
                    div()
                        .text_color(theme.text_muted)
                        .child(SharedString::from(name.to_owned())),
                )
                .child(
                    div()
                        .text_color(theme.success)
                        .tabular_nums()
                        .child(SharedString::from(format!("+{}", stat.additions))),
                )
                .child(
                    div()
                        .text_color(theme.danger)
                        .tabular_nums()
                        .child(SharedString::from(format!("−{}", stat.deletions))),
                )
        }))
        .into_any_element()
}

/// Full group: header + rows + optional file diffs.
pub fn group(
    group: &CallGroup,
    open: bool,
    theme: &Theme,
    phase: f32,
    reduce_motion: bool,
) -> AnyElement {
    div()
        .w_full()
        .min_w_0()
        .flex()
        .flex_col()
        .gap(px(2.0))
        .child(header(group, open, theme, phase, reduce_motion))
        .when(open, |col| {
            col.children(group.rows.iter().map(|r| row(r, theme, phase, reduce_motion, None)))
                .when(!group.file_diffs.is_empty() && !group.live, |col| {
                    col.child(file_diff_summary(&group.file_diffs, theme))
                })
        })
        .into_any_element()
}

/// Pulse phase for scramble / spinner. Callers that already hold a phase
/// (agent work) can pass it through; fixtures use this helper.
pub fn pulse_phase(view: EntityId, cx: &mut App) -> f32 {
    motion::pulse_delta(&SCRAMBLE_TICK, view, cx)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scramble_keeps_ends_and_separators() {
        let s = scramble_middle("src/auth/session.ts:42", 0.3);
        assert!(s.starts_with("src"));
        assert!(s.contains('/'));
        assert!(s.ends_with("42") || s.ends_with("s:42") || s.contains("42"));
        assert_ne!(s, "src/auth/session.ts:42");
    }

    #[test]
    fn header_mentions_failures() {
        let g = CallGroup {
            rows: vec![
                CallRow {
                    id: "a".into(),
                    verb: "Search".into(),
                    detail: "x".into(),
                    icon: icons::MAGNIFER,
                    result: RowResult::Summary("12 matches".into()),
                    is_error: false,
                    resolved: true,
                },
                CallRow {
                    id: "b".into(),
                    verb: "Run".into(),
                    detail: "pnpm test".into(),
                    icon: icons::TERMINAL,
                    result: RowResult::Failed {
                        label: "1 failed".into(),
                    },
                    is_error: true,
                    resolved: true,
                },
            ],
            failed: 1,
            live: false,
            file_diffs: vec![],
        };
        assert_eq!(g.header_label(), "2 tool calls, 1 failed");
    }

    #[test]
    fn parse_passed_and_failed_counts() {
        let lines = vec![SharedString::from("48 passed, 0 failed")];
        assert_eq!(
            parse_test_outcome(&lines),
            Some(RowResult::Passed {
                label: "48 passed".into()
            })
        );
        let lines = vec![SharedString::from("tests: 1 failed")];
        assert_eq!(
            parse_test_outcome(&lines),
            Some(RowResult::Failed {
                label: "1 failed".into()
            })
        );
    }
}
