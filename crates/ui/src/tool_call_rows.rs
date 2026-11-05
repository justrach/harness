//! Animated one-line tool-call rows for the chat transcript.
//!
//! What a row in a tool group adds to the task tree: an active row sits in a
//! gray pill with a scramble on the middle of its path and a ticking timer; a
//! finished row settles the path and shows a short result (`12 matches`,
//! `+8 −3`, `48 passed`); a failed or passed run paints a dither wash from the
//! right into a status pill. Aggregate file diffs land under the list once the
//! turn settles. The transcript draws these inside its own tree rows
//! ([`status_trail`], [`status_wash`]), so every row in a group has one layout.
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
pub const STATUS_RADIUS: f32 = 5.0;

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
/// Width of the pass/fail wash at a row's right end. The row keeps its text
/// out of this space, so the dither never runs under a long command.
pub const WASH_WIDTH: f32 = 112.0;
/// The aggregate file-diff line under a group's rows.
pub const DIFF_SUMMARY_HEIGHT: f32 = 22.0;
/// More files than this and the line gives their total instead of naming them.
const DIFF_SUMMARY_MAX_NAMED: usize = 3;

const SCRAMBLE_TICK: MotionSpec = MotionSpec::new(80, CubicBezier::new(0.0, 0.0, 1.0, 1.0));

/// How a row presents its trailing result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowResult {
    /// Still running: elapsed seconds, when this view saw the tool start.
    /// A tool replayed from history has no honest start time, so no timer.
    Running { elapsed_ms: Option<u64> },
    /// Finished with nothing worth saying. The row has simply stopped moving;
    /// a "done" on every line is noise.
    Settled,
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
        let row = call_row(tool, elapsed_ms);
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

fn call_row(tool: &ToolItem, elapsed_ms: Option<u64>) -> CallRow {
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

pub fn row_result(tool: &ToolItem, elapsed_ms: Option<u64>) -> RowResult {
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
            ToolDetail::Output {
                lines,
                truncated_by,
            } => {
                // Only a command's output is a test report. A file or a search
                // that merely contains "3 failed" did not fail anything.
                if matches!(tool.call, ToolCall::Exec { .. })
                    && let Some(parsed) = parse_test_outcome(lines, tool.is_error)
                {
                    return parsed;
                }
                if let Some(summary) = search_summary(tool, lines, *truncated_by) {
                    return RowResult::Summary(summary);
                }
            }
            _ => {}
        }
    }
    if tool.is_error {
        return RowResult::Failed {
            label: SharedString::from("failed"),
        };
    }
    RowResult::Settled
}

/// A pass or fail the output reports, when it agrees with how the command
/// exited. A successful `cat` of a log saying "2 failed" isn't a failure, and a
/// failed command that printed "48 passed" isn't a pass.
fn parse_test_outcome(lines: &[SharedString], is_error: bool) -> Option<RowResult> {
    let text = lines
        .iter()
        .map(|l| l.as_ref())
        .collect::<Vec<_>>()
        .join("\n");
    let lower = text.to_ascii_lowercase();
    if let Some(n) = capture_count(&lower, "failed")
        && n > 0
    {
        return is_error.then(|| RowResult::Failed {
            label: SharedString::from(format!("{n} failed")),
        });
    }
    if is_error {
        return None;
    }
    capture_count(&lower, "passed").map(|n| RowResult::Passed {
        label: SharedString::from(format!("{n} passed")),
    })
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

/// A count, only when the output can really be counted. Large outputs reach the
/// doc as their first line and a `…`, and "No matches found" is one line too;
/// counting either would print "1 match".
fn search_summary(
    tool: &ToolItem,
    lines: &[SharedString],
    truncated_by: usize,
) -> Option<SharedString> {
    let rows = || lines.iter().filter(|line| !line.trim().is_empty());
    if rows().any(|line| line.ends_with('…')) {
        return None;
    }
    let n = rows().count() + truncated_by;
    if n == 0 {
        return None;
    }
    let (one, many) = match tool.call {
        ToolCall::Search { .. } if rows().all(|line| is_match_line(line)) => ("match", "matches"),
        ToolCall::Glob { .. } if rows().all(|line| !line.contains(' ')) => ("file", "files"),
        _ => return None,
    };
    Some(SharedString::from(format!(
        "{n} {}",
        if n == 1 { one } else { many }
    )))
}

/// `path:line` or `path:line:text`, what a search prints per match.
fn is_match_line(line: &str) -> bool {
    line.split(':')
        .nth(1)
        .is_some_and(|number| !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()))
}

// ---------------------------------------------------------------------------
// Scramble
// ---------------------------------------------------------------------------

/// Letter-weight glyphs: block characters read as dark bars against the rows
/// around them, where these read as the path itself churning.
const SCRAMBLE_GLYPHS: &[char] = &[
    'a', 'c', 'e', 'k', 'm', 'n', 'o', 'r', 's', 'u', 'v', 'x', 'z', '·', '-', '_', '=', '+',
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

const DITHER_CELL: f32 = 2.0;
const DITHER_ALPHA: f32 = 0.3;
/// The soft tint under the dots, so they dissolve into something.
const WASH_TINT_ALPHA: f32 = 0.12;
const DITHER_MAX_DENSITY: f32 = 0.6;
const BAYER_4: [[u8; 4]; 4] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

/// Whether one dither cell is painted. Ordered rather than random, so the fade
/// reads as a pattern instead of static. It builds toward the right and thins
/// toward the top and bottom, so the wash has no hard edge against the page.
fn wash_cell_on(col: u32, row: u32, cols: u32, rows: u32) -> bool {
    let across = (col as f32 + 0.5) / cols.max(1) as f32;
    let edge = row.min(rows.saturating_sub(row + 1)) as f32;
    let taper = (edge / (rows as f32 * 0.25).max(1.0)).min(1.0);
    let density = across * across * DITHER_MAX_DENSITY * taper;
    let threshold = (BAYER_4[(row % 4) as usize][(col % 4) as usize] as f32 + 0.5) / 16.0;
    threshold < density
}

/// Right-origin dither wash into `color`.
fn dither_wash(color: Hsla) -> AnyElement {
    let dots = canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let cols = (f32::from(bounds.size.width) / DITHER_CELL).ceil() as u32;
            let rows = (f32::from(bounds.size.height) / DITHER_CELL).ceil() as u32;
            let mut path = PathBuilder::fill();
            for row in 0..rows {
                for col in 0..cols {
                    if !wash_cell_on(col, row, cols, rows) {
                        continue;
                    }
                    let origin = point(
                        bounds.origin.x + px(col as f32 * DITHER_CELL),
                        bounds.origin.y + px(row as f32 * DITHER_CELL),
                    );
                    path.move_to(origin);
                    path.line_to(point(origin.x + px(DITHER_CELL), origin.y));
                    path.line_to(point(
                        origin.x + px(DITHER_CELL),
                        origin.y + px(DITHER_CELL),
                    ));
                    path.line_to(point(origin.x, origin.y + px(DITHER_CELL)));
                    path.close();
                }
            }
            if let Ok(built) = path.build() {
                window.paint_path(built, color.opacity(DITHER_ALPHA));
            }
        },
    )
    .absolute()
    .inset_0();
    div()
        .absolute()
        .top_0()
        .bottom_0()
        .right_0()
        .w(px(WASH_WIDTH))
        .rounded(px(PILL_RADIUS))
        .bg(gpui::linear_gradient(
            90.0,
            gpui::linear_color_stop(color.opacity(0.0), 0.0),
            gpui::linear_color_stop(color.opacity(WASH_TINT_ALPHA), 1.0),
        ))
        .child(dots)
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

/// The dither wash behind a settled pass or fail, if the row has one.
pub fn status_wash(result: &RowResult, theme: &Theme) -> Option<AnyElement> {
    match result {
        RowResult::Failed { .. } => Some(dither_wash(theme.danger)),
        RowResult::Passed { .. } => Some(dither_wash(theme.success)),
        _ => None,
    }
}

/// The right-hand end of a row: timer, summary, diff counts or status pill.
pub fn status_trail(result: &RowResult, theme: &Theme) -> Option<AnyElement> {
    match result {
        RowResult::Running { elapsed_ms } => elapsed_ms.map(|ms| timer_label(ms, theme)),
        RowResult::Settled => None,
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
        RowResult::Failed { label } => Some(status_pill(
            label.clone(),
            theme.danger,
            fg_on(theme.danger),
        )),
        RowResult::Passed { label } => Some(status_pill(
            label.clone(),
            theme.success,
            fg_on(theme.success),
        )),
    }
}

/// One compact animated row, for fixtures. `disclosure` is `Some(open)` when the
/// row expands, which ends it in a chevron.
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
    let wash = status_wash(&row.result, theme);
    let trail = status_trail(&row.result, theme);

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
        .when(active, |el| el.bg(theme.ink(0.06)))
        .when(!active, |el| el.opacity(if row.is_error { 0.95 } else { 0.72 }))
        .children(wash)
        .child(
            icons::icon(row.icon)
                .size(px(12.0))
                .flex_none()
                .text_color(if row.is_error {
                    theme.danger
                } else {
                    theme.text_muted
                })
                .mt(px(CAP_CENTER_NUDGE)),
        )
        .child(
            div()
                .flex_none()
                .text_size(px(TEXT_BODY))
                .font_weight(WEIGHT_REGULAR)
                .text_color(if row.is_error {
                    theme.danger
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
                    icons::ALT_ARROW_DOWN
                } else {
                    icons::ALT_ARROW_RIGHT
                })
                .size(px(12.0))
                .flex_none()
                .text_color(theme.text_muted),
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
        .h(px(18.0))
        .px(px(6.0))
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

/// `+8 −3`. A side with nothing to report isn't shown, so `+10 −0` reads `+10`.
fn diff_trail(additions: u64, deletions: u64, theme: &Theme) -> AnyElement {
    div()
        .flex_none()
        .flex()
        .gap(px(6.0))
        .text_size(px(TEXT_CAPTION))
        .tabular_nums()
        .when(additions > 0, |trail| {
            trail.child(
                div()
                    .text_color(theme.success)
                    .child(SharedString::from(format!("+{additions}"))),
            )
        })
        .when(deletions > 0, |trail| {
            trail.child(
                div()
                    .text_color(theme.danger)
                    .child(SharedString::from(format!("−{deletions}"))),
            )
        })
        .into_any_element()
}

/// One entry of the line under a group's rows: the files named, or their total.
fn diff_summary_entries(stats: &[ToolDiffStat]) -> Vec<(String, u64, u64)> {
    if stats.len() <= DIFF_SUMMARY_MAX_NAMED {
        return stats
            .iter()
            .map(|stat| {
                let name = stat
                    .path
                    .rsplit(['/', '\\'])
                    .find(|part| !part.is_empty())
                    .unwrap_or(stat.path.as_str());
                (name.to_owned(), stat.additions, stat.deletions)
            })
            .collect();
    }
    let (additions, deletions) = stats.iter().fold((0u64, 0u64), |(a, d), stat| {
        (
            a.saturating_add(stat.additions),
            d.saturating_add(stat.deletions),
        )
    });
    vec![(format!("{} files", stats.len()), additions, deletions)]
}

/// Aggregate file diffs under the rows (`session.ts +10 −4`). One clipped line:
/// the group folds on an analytic height, so this can't wrap to an unknown one.
pub fn file_diff_summary(stats: &[ToolDiffStat], theme: &Theme) -> AnyElement {
    div()
        .w_full()
        .min_w_0()
        .h(px(DIFF_SUMMARY_HEIGHT))
        .overflow_hidden()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(12.0))
        .text_size(px(TEXT_CAPTION))
        .children(
            diff_summary_entries(stats)
                .into_iter()
                .map(|(name, additions, deletions)| {
                    div()
                        .min_w_0()
                        .flex()
                        .gap(px(6.0))
                        .items_center()
                        .child(
                            div()
                                .min_w_0()
                                .truncate()
                                .font_family(theme.font_mono.clone())
                                .text_color(theme.text_muted)
                                .child(SharedString::from(name)),
                        )
                        .child(diff_trail(additions, deletions, theme))
                }),
        )
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
            col.children(
                group
                    .rows
                    .iter()
                    .map(|r| row(r, theme, phase, reduce_motion, None)),
            )
            .when(!group.file_diffs.is_empty() && !group.live, |col| {
                col.child(file_diff_summary(&group.file_diffs, theme))
            })
        })
        .into_any_element()
}

/// Pulse phase for scramble / spinner. Callers that already hold a phase
/// (agent work) can pass it through; fixtures use this helper.
pub fn pulse_phase(view: EntityId, cx: &mut App) -> f32 {
    motion::pulse_delta_slow(&SCRAMBLE_TICK, view, cx)
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
    fn scramble_uses_no_block_glyphs() {
        for phase in [0.0, 0.2, 0.5, 0.9] {
            let s = scramble_middle("zig build bench --filter parser", phase);
            assert!(!s.contains(['░', '▒', '▓', '▪', '▫']), "{s}");
        }
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

    fn exec_tool(lines: &[&str], is_error: bool) -> ToolItem {
        ToolItem {
            part_id: "t".into(),
            call: ToolCall::Exec {
                command: "pnpm test".into(),
            },
            is_error,
            resolved: true,
            detail: Some(std::sync::Arc::new(ToolDetail::Output {
                lines: lines.iter().map(|l| SharedString::from(*l)).collect(),
                truncated_by: 0,
            })),
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

    #[test]
    fn a_plain_failure_does_not_claim_a_count() {
        assert_eq!(
            row_result(&exec_tool(&["permission denied"], true), None),
            RowResult::Failed {
                label: "failed".into()
            }
        );
        assert_eq!(
            row_result(&exec_tool(&["tests: 2 failed"], true), None),
            RowResult::Failed {
                label: "2 failed".into()
            }
        );
    }

    #[test]
    fn only_a_command_output_counts_as_a_test_report() {
        let mut read = exec_tool(&["last night: 3 failed"], false);
        read.call = ToolCall::ReadFile {
            path: "notes.md".into(),
        };
        assert_eq!(row_result(&read, None), RowResult::Settled);
    }

    #[test]
    fn a_command_with_nothing_to_report_says_nothing() {
        let row = row_result(&exec_tool(&["Build finished"], false), None);
        assert_eq!(row, RowResult::Settled);
        assert!(status_trail(&row, &Theme::dark()).is_none());
    }

    #[test]
    fn the_pill_agrees_with_how_the_command_exited() {
        assert_eq!(
            row_result(&exec_tool(&["2 failed, 46 passed"], false), None),
            RowResult::Settled,
            "a successful cat of a test log isn't a failure, or a pass"
        );
        assert_eq!(
            row_result(&exec_tool(&["48 passed"], true), None),
            RowResult::Failed {
                label: "failed".into()
            },
            "a command that failed isn't green"
        );
    }

    fn search_tool(lines: &[&str]) -> ToolItem {
        let mut tool = exec_tool(lines, false);
        tool.call = ToolCall::Search {
            pattern: "needle".into(),
            path: None,
        };
        tool
    }

    #[test]
    fn a_search_counts_only_output_it_can_really_count() {
        assert_eq!(
            row_result(&search_tool(&["a.rs:1:x", "b.rs:20:y"]), None),
            RowResult::Summary("2 matches".into())
        );
        assert_eq!(
            row_result(&search_tool(&["a.rs:1"]), None),
            RowResult::Summary("1 match".into())
        );
        for lines in [["No matches found"], ["a.rs:1:the first of many…"]] {
            assert_eq!(row_result(&search_tool(&lines), None), RowResult::Settled);
        }
    }

    #[test]
    fn the_wash_builds_to_the_right_and_has_no_hard_edge() {
        let (cols, rows) = (80, 15);
        let lit = |col_range: std::ops::Range<u32>, row_range: std::ops::Range<u32>| {
            col_range
                .flat_map(|col| row_range.clone().map(move |row| (col, row)))
                .filter(|(col, row)| wash_cell_on(*col, *row, cols, rows))
                .count()
        };
        assert_eq!(lit(0..16, 0..rows), 0, "the left end fades to nothing");
        assert!(lit(60..80, 0..rows) > lit(40..60, 0..rows));
        assert_eq!(lit(0..cols, 0..1), 0, "the top row is clear");
        assert_eq!(lit(0..cols, rows - 1..rows), 0, "the bottom row is clear");
    }

    #[test]
    fn many_changed_files_are_totalled_rather_than_listed() {
        let stat = |path: &str, additions, deletions| ToolDiffStat {
            path: path.into(),
            additions,
            deletions,
        };
        let three = [
            stat("src/a.rs", 1, 2),
            stat("b.rs", 3, 0),
            stat("c.rs", 0, 4),
        ];
        assert_eq!(
            diff_summary_entries(&three)[0],
            ("a.rs".to_owned(), 1, 2),
            "up to three are named"
        );
        let four = [
            stat("src/a.rs", 1, 2),
            stat("b.rs", 3, 0),
            stat("c.rs", 0, 4),
            stat("d.rs", 5, 5),
        ];
        assert_eq!(
            diff_summary_entries(&four),
            vec![("4 files".to_owned(), 9, 11)]
        );
    }

    #[test]
    fn parse_passed_and_failed_counts() {
        let lines = vec![SharedString::from("48 passed, 0 failed")];
        assert_eq!(
            parse_test_outcome(&lines, false),
            Some(RowResult::Passed {
                label: "48 passed".into()
            })
        );
        let lines = vec![SharedString::from("tests: 1 failed")];
        assert_eq!(
            parse_test_outcome(&lines, true),
            Some(RowResult::Failed {
                label: "1 failed".into()
            })
        );
    }
}
