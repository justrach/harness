//! The context window card behind the composer's usage ring: what fills the
//! selected chat's context, as a row of segments with a legend.
//!
//! The total and the window come from the agent's own context meter
//! ([`ContextUsage`]); nothing here replaces them. The split between chat,
//! files, commands and the rest is estimated from the selected chat's
//! transcript since its last compaction, at 4 bytes a token, and scaled down
//! when it would exceed the reported total. Whatever the transcript cannot
//! account for (system prompt, tool schemas, images) is "System & other".
//!
//! Compaction comes in two kinds ([`CompactionKind`]). A readable summary
//! becomes "Chat summary". An opaque provider item (OpenAI's encrypted
//! `compaction` item, which Codex passes back unread) becomes a locked
//! "Compacted context" block: only its size is shown, never contents. Its
//! size is the agent's own count when it reports one; otherwise it is
//! estimated as the context after the compaction minus the share the
//! transcript could not account for just before it.
//!
//! Motion: on open the segments cascade in and the counter rolls up. When the
//! agent compacts, the header reads "compacting", the chat block loses
//! segments from its right edge while the blocks after it slide left, its
//! legend entry crossfades to "Chat summary" (or "Compacted context") and
//! the status line fades up with what was freed; the header goes back to
//! "reading". Reduced motion snaps every transition to its end.
use std::time::{Duration, Instant};

use gpui::{
    Context, Div, Entity, Hsla, IntoElement, Render, SharedString, Subscription, Window, div,
    prelude::*, px,
};
use harness_doc::{MessagePart, MessageRole, SessionMessageEntry};
use harness_proto::{CompactionKind, ContextUsage, ToolCall};

pub use crate::context_usage::card as usage_card;
use crate::motion::{AnimationExt, CubicBezier};
use crate::state::AppState;
use crate::theme::Theme;

/// Segments across the full window. Each is 4 px wide with a 2 px gap.
pub const SEGMENTS: usize = 62;
const SEGMENT_W: f32 = 4.0;
const SEGMENT_H: f32 = 16.0;
const SEGMENT_GAP: f32 = 2.0;
/// The bar's width, which sets the card's content width.
pub const BAR_WIDTH: f32 = SEGMENTS as f32 * (SEGMENT_W + SEGMENT_GAP) - SEGMENT_GAP;
/// Space between legend columns.
const LEGEND_GAP: f32 = 12.0;
/// Tool output is counted the way graff counts it.
const BYTES_PER_TOKEN: u64 = 4;

/// `cubic-bezier(0.2, 0.8, 0.2, 1)`: fast out, long settle.
pub const EASE_SETTLE: CubicBezier = CubicBezier::new(0.2, 0.8, 0.2, 1.0);
const TRANSITION_MS: u64 = 720;
/// Each later block starts this much after the one before it.
const CASCADE_STAGGER_MS: u64 = 70;

/// What the oldest block of the context holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum History {
    /// The conversation itself: nothing compacted yet.
    #[default]
    Chat,
    /// A readable summary replaced the older chat.
    Summary,
    /// An opaque provider item replaced it; its contents are sealed.
    Sealed,
}

impl History {
    fn of(kind: Option<CompactionKind>) -> Self {
        match kind {
            Some(CompactionKind::Opaque) => History::Sealed,
            // Chips from before the record existed are ACP summaries.
            Some(CompactionKind::Summary) | None => History::Summary,
        }
    }
}

/// One kind of thing in the context, in the order the bar draws them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Slot {
    /// The conversation before any compaction, or what replaced it.
    History,
    /// Conversation since the last compaction.
    Recent,
    Files,
    Commands,
    Search,
    Tools,
    /// The reported total the transcript can't account for.
    System,
}

impl Slot {
    pub const ALL: [Slot; 7] = [
        Slot::History,
        Slot::Recent,
        Slot::Files,
        Slot::Commands,
        Slot::Search,
        Slot::Tools,
        Slot::System,
    ];

    pub fn label(self, history: History) -> &'static str {
        match self {
            Slot::History => match history {
                History::Chat => "Chat history",
                History::Summary => "Chat summary",
                History::Sealed => "Compacted context",
            },
            Slot::Recent => "Recent chat",
            Slot::Files => "Files",
            Slot::Commands => "Commands",
            Slot::Search => "Search & web",
            Slot::Tools => "Other tools",
            Slot::System => "System & other",
        }
    }

    fn color(self, history: History, theme: &Theme) -> Hsla {
        let hex = match self {
            Slot::History => match history {
                History::Chat => 0xFFB020,
                History::Summary => 0x4C8DF6,
                History::Sealed => 0x7D8BA3,
            },
            Slot::Recent => 0xF7C873,
            Slot::Files => 0x7C5CFF,
            Slot::Commands => 0x5BC0EB,
            Slot::Search => 0xF368E0,
            Slot::Tools => 0x9B59B6,
            Slot::System => return theme.text_faint,
        };
        gpui::rgb(hex).into()
    }
}

/// What the context holds right now.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Breakdown {
    /// Reported tokens in the context.
    pub tokens: u64,
    /// Reported window size.
    pub window: u64,
    /// What replaced the older chat, if anything has.
    pub history: History,
    /// A compaction is running now.
    pub compacting: bool,
    /// The kind of the running compaction, when it said.
    pub pending: History,
    /// Tokens freed by compaction, cumulative: graff's own count, or the
    /// before/after meters on each compaction chip.
    pub freed: u64,
    /// The sealed block's size is an estimate, not the agent's count.
    pub sealed_estimated: bool,
    /// Non-empty slots in [`Slot::ALL`] order; they sum to `tokens`.
    pub items: Vec<(Slot, u64)>,
}

fn tool_slot(call: &ToolCall) -> Slot {
    match call {
        ToolCall::ReadFile { .. }
        | ToolCall::WriteFile { .. }
        | ToolCall::EditFile { .. }
        | ToolCall::ApplyPatch { .. } => Slot::Files,
        ToolCall::Exec { .. } => Slot::Commands,
        ToolCall::Search { .. }
        | ToolCall::Glob { .. }
        | ToolCall::WebFetch { .. }
        | ToolCall::WebSearch { .. } => Slot::Search,
        _ => Slot::Tools,
    }
}

fn output_len(output: &Option<String>, output_bytes: Option<u64>) -> u64 {
    output_bytes.unwrap_or_else(|| output.as_ref().map_or(0, |o| o.len() as u64))
}

impl Breakdown {
    /// Something has replaced the older chat.
    pub fn compacted(&self) -> bool {
        self.history != History::Chat
    }
}

/// The split of the reported context across [`Slot`]s. `None` when the agent
/// reports no window to measure against.
///
/// One pass over the transcript. Each finished compaction is a boundary:
/// what came before it now lives in its summary or sealed item, so the
/// per-slot counts restart there.
pub fn breakdown(
    usage: Option<ContextUsage>,
    transcript: &[SessionMessageEntry],
) -> Option<Breakdown> {
    let usage = usage?;
    let window = usage.window.filter(|w| *w > 0)?;
    let tokens = usage.tokens.unwrap_or(0);

    let index = |slot: Slot| Slot::ALL.iter().position(|s| *s == slot).unwrap_or(0);
    let mut bytes = [0u64; Slot::ALL.len()];
    let mut history = History::Chat;
    // Tokens of the summary or sealed item standing in for older chat.
    let mut history_tokens = 0u64;
    let mut compacting = false;
    let mut pending = History::Summary;
    let mut chip_freed = 0u64;
    let mut sealed_estimated = false;
    for entry in transcript {
        for part in &entry.parts {
            match part {
                MessagePart::Tool {
                    call,
                    resolved,
                    output,
                    output_bytes,
                    ..
                } if call.is_compaction() => {
                    let meta = call.compaction();
                    if !resolved {
                        compacting = true;
                        pending = History::of(meta.as_ref().map(|m| m.kind));
                        continue;
                    }
                    compacting = false;
                    let transcript_before: u64 = bytes
                        .iter()
                        .map(|b| b.div_ceil(BYTES_PER_TOKEN))
                        .sum::<u64>()
                        + history_tokens;
                    let kind = History::of(meta.as_ref().map(|m| m.kind));
                    let reported = meta.as_ref().and_then(|m| m.item_tokens);
                    history_tokens = match (kind, reported) {
                        (_, Some(n)) => n,
                        (History::Sealed, None) => {
                            // After minus what the transcript could not
                            // account for before: the system share is the
                            // same on both sides of the compaction.
                            let sizes = meta
                                .as_ref()
                                .and_then(|m| Some((m.tokens_before?, m.tokens_after?)));
                            sealed_estimated = sizes.is_some();
                            sizes.map_or(0, |(before, after)| {
                                after.saturating_sub(before.saturating_sub(transcript_before))
                            })
                        }
                        _ => output_len(output, *output_bytes).div_ceil(BYTES_PER_TOKEN),
                    };
                    if kind != History::Sealed || reported.is_some() {
                        sealed_estimated = false;
                    }
                    chip_freed += meta.as_ref().and_then(|m| m.freed()).unwrap_or(0);
                    history = kind;
                    bytes = [0; Slot::ALL.len()];
                }
                MessagePart::Tool {
                    call,
                    output,
                    output_bytes,
                    ..
                } => bytes[index(tool_slot(call))] += output_len(output, *output_bytes),
                MessagePart::Text { text, .. }
                    if matches!(entry.role, MessageRole::User | MessageRole::Assistant) =>
                {
                    let slot = if history == History::Chat {
                        Slot::History
                    } else {
                        Slot::Recent
                    };
                    bytes[index(slot)] += text.len() as u64;
                }
                _ => {}
            }
        }
    }
    let mut estimated: Vec<u64> = bytes.iter().map(|b| b.div_ceil(BYTES_PER_TOKEN)).collect();
    if history != History::Chat {
        estimated[index(Slot::History)] += history_tokens;
    }
    let sum: u64 = estimated.iter().sum();
    if sum > tokens {
        // The meter is the truth: scale the estimate into it.
        for value in &mut estimated {
            *value = ((*value as u128 * tokens as u128) / sum.max(1) as u128) as u64;
        }
    }
    let accounted: u64 = estimated.iter().sum();
    estimated[index(Slot::System)] += tokens.saturating_sub(accounted);
    let items = Slot::ALL
        .iter()
        .zip(estimated)
        .filter(|(_, tokens)| *tokens > 0)
        .map(|(slot, tokens)| (*slot, tokens))
        .collect();
    let graff_freed = usage.savings.map_or(0, |s| s.compacted_tokens);
    Some(Breakdown {
        tokens,
        window,
        history,
        compacting,
        pending,
        freed: if graff_freed > 0 {
            graff_freed
        } else {
            chip_freed
        },
        sealed_estimated: sealed_estimated && history == History::Sealed,
        items,
    })
}

/// Segments each slot fills, in bar order. Any slot with tokens gets at least
/// one segment; the total never passes [`SEGMENTS`].
pub fn segment_counts(breakdown: &Breakdown) -> Vec<(Slot, f32)> {
    let window = breakdown.window.max(1) as f32;
    let mut left = SEGMENTS as f32;
    breakdown
        .items
        .iter()
        .map(|(slot, tokens)| {
            let wanted = (*tokens as f32 / window * SEGMENTS as f32).round().max(1.0);
            let count = wanted.min(left);
            left -= count;
            (*slot, count)
        })
        .collect()
}

/// 1.2k, 34k, 1.5M.
pub fn compact_count(n: u64) -> String {
    match n {
        0..1_000 => n.to_string(),
        1_000..10_000 => format!("{:.1}k", n as f64 / 1_000.0),
        10_000..1_000_000 => format!("{}k", n / 1_000),
        _ => format!("{:.1}M", n as f64 / 1_000_000.0),
    }
}

/// The status line under the legend.
pub fn status_line(from: &Breakdown, to: &Breakdown) -> String {
    let sealed = to.history == History::Sealed;
    if to.compacting {
        return match to.pending {
            History::Sealed => "Compacting older chat into a sealed item".into(),
            _ => "Summarizing older chat to free up space".into(),
        };
    }
    let freed_now = to.freed.saturating_sub(from.freed);
    if from.compacting && freed_now > 0 {
        return if sealed {
            format!("Sealed older chat, freed {}", compact_count(freed_now))
        } else {
            format!("Compacted older chat, freed {}", compact_count(freed_now))
        };
    }
    if to.compacted() && to.freed > 0 {
        return if sealed {
            format!(
                "Older chat sealed, {} freed so far",
                compact_count(to.freed)
            )
        } else {
            format!(
                "Older chat summarized, {} freed so far",
                compact_count(to.freed)
            )
        };
    }
    format!(
        "{} free of {}",
        compact_count(to.window.saturating_sub(to.tokens)),
        compact_count(to.window)
    )
}

/// One transition between two [`Breakdown`]s.
struct Transition {
    from: Breakdown,
    to: Breakdown,
    /// Segment counts drawn at the start (mid-flight values when a new
    /// breakdown interrupts a running transition).
    from_counts: Vec<(Slot, f32)>,
    from_tokens: f32,
    started: Instant,
    /// Stagger the blocks, the way they first fill in.
    cascade: bool,
}

/// The eased progress of `slot`'s part of a transition `elapsed` in.
pub fn slot_progress(elapsed: Duration, order: usize, cascade: bool, reduced: bool) -> f32 {
    if reduced {
        return 1.0;
    }
    let delay = if cascade {
        CASCADE_STAGGER_MS * order as u64
    } else {
        0
    };
    let raw = (elapsed.as_millis() as f32 - delay as f32) / TRANSITION_MS as f32;
    EASE_SETTLE.eval(raw.clamp(0.0, 1.0))
}

fn transition_len(cascade: bool) -> Duration {
    let stagger = if cascade {
        CASCADE_STAGGER_MS * Slot::ALL.len() as u64
    } else {
        0
    };
    Duration::from_millis(TRANSITION_MS + stagger)
}

fn lerp(from: f32, to: f32, t: f32) -> f32 {
    from + (to - from) * t
}

fn mix(from: Hsla, to: Hsla, t: f32) -> Hsla {
    let a = from.to_rgb();
    let b = to.to_rgb();
    gpui::Rgba {
        r: lerp(a.r, b.r, t),
        g: lerp(a.g, b.g, t),
        b: lerp(a.b, b.b, t),
        a: lerp(a.a, b.a, t),
    }
    .into()
}

fn count_of(counts: &[(Slot, f32)], slot: Slot) -> f32 {
    counts
        .iter()
        .find(|(s, _)| *s == slot)
        .map_or(0.0, |(_, c)| *c)
}

/// The card's live view. Lives as long as the tooltip is open.
pub struct ContextWindowCard {
    state: Entity<AppState>,
    /// The transcript revision and usage the cached breakdown was built from.
    built_from: Option<(u64, Option<ContextUsage>)>,
    current: Option<Breakdown>,
    transition: Option<Transition>,
    _subscription: Subscription,
}

impl ContextWindowCard {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        Self {
            _subscription: cx.observe(&state, |_, _, cx| cx.notify()),
            state,
            built_from: None,
            current: None,
            transition: None,
        }
    }

    /// Rebuild the breakdown only when the transcript or the meter changed:
    /// the card repaints every frame while it animates.
    fn refresh(&mut self, cx: &mut Context<Self>) {
        let state = self.state.read(cx);
        let key = (state.transcript_revision, state.context_usage);
        if self.built_from == Some(key) {
            return;
        }
        self.built_from = Some(key);
        let next = breakdown(state.context_usage, &state.transcript);
        if next == self.current {
            return;
        }
        let now = Instant::now();
        let reduced = crate::motion::reduced_motion(cx);
        let (from, from_counts, from_tokens, cascade) = match (&self.transition, &self.current) {
            (Some(running), _) => {
                let (counts, tokens) = self.sample(running, now, reduced);
                (running.to.clone(), counts, tokens, false)
            }
            (None, Some(current)) => (
                current.clone(),
                segment_counts(current),
                current.tokens as f32,
                false,
            ),
            // First paint: everything fills in from empty.
            (None, None) => (Breakdown::default(), Vec::new(), 0.0, true),
        };
        self.current = next.clone();
        self.transition = next.map(|to| Transition {
            from,
            to,
            from_counts,
            from_tokens,
            started: now,
            cascade,
        });
    }

    /// Segment counts and the counter value `now` into a transition.
    fn sample(
        &self,
        transition: &Transition,
        now: Instant,
        reduced: bool,
    ) -> (Vec<(Slot, f32)>, f32) {
        let elapsed = now.saturating_duration_since(transition.started);
        let to_counts = segment_counts(&transition.to);
        let counts = Slot::ALL
            .iter()
            .enumerate()
            .map(|(order, slot)| {
                let t = slot_progress(elapsed, order, transition.cascade, reduced);
                (
                    *slot,
                    lerp(
                        count_of(&transition.from_counts, *slot),
                        count_of(&to_counts, *slot),
                        t,
                    ),
                )
            })
            .filter(|(_, c)| *c > 0.001)
            .collect();
        let t = slot_progress(elapsed, 0, false, reduced);
        let tokens = lerp(transition.from_tokens, transition.to.tokens as f32, t);
        (counts, tokens)
    }
}

/// A fixed-height window that rolls each changed digit of `from` to `to`.
fn odometer(from: &str, to: &str, rising: bool, t: f32, color: Hsla) -> Div {
    let width = from.chars().count().max(to.chars().count());
    let pad = |s: &str| {
        let mut chars: Vec<Option<char>> = vec![None; width - s.chars().count()];
        chars.extend(s.chars().map(Some));
        chars
    };
    let (from_chars, to_chars) = (pad(from), pad(to));
    let line = 16.0;
    div()
        .flex()
        .h(px(line))
        .overflow_hidden()
        .text_color(color)
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .children(from_chars.into_iter().zip(to_chars).map(move |(a, b)| {
            let glyph = |c: Option<char>| {
                div()
                    .h(px(line))
                    .line_height(px(line))
                    .child(SharedString::from(c.map(String::from).unwrap_or_default()))
            };
            if a == b {
                return div().child(glyph(b));
            }
            // The new digit arrives from below when counting up, from above
            // when counting down.
            let (first, second, offset) = if rising {
                (a, b, -line * t)
            } else {
                (b, a, -line * (1.0 - t))
            };
            div().h(px(line)).overflow_hidden().child(
                div()
                    .relative()
                    .top(px(offset))
                    .flex()
                    .flex_col()
                    .child(glyph(first))
                    .child(glyph(second)),
            )
        }))
}

/// Opacity of a label crossfading at the midpoint of `t`.
fn crossfade(t: f32) -> f32 {
    (1.0 - 2.0 * t).abs()
}

/// A legend entry's marker: a dot for live content, a summary block with
/// three lines for a readable summary, a padlock for a sealed item. `t` is
/// the marker's opacity while it crossfades between shapes.
fn legend_marker(shape: History, color: Hsla, t: f32) -> Div {
    let slot = div()
        .flex_none()
        .size(px(10.0))
        .flex()
        .items_center()
        .justify_center()
        .opacity(t);
    match shape {
        History::Chat => slot.child(div().size(px(8.0)).rounded(px(4.0)).bg(color)),
        History::Summary => slot.child(
            div()
                .size(px(10.0))
                .rounded(px(2.0))
                .bg(color)
                .flex()
                .flex_col()
                .justify_center()
                .gap(px(1.0))
                .px(px(2.0))
                .children((0..3).map(|line| {
                    div()
                        .h(px(1.0))
                        .w(px(if line == 2 { 4.0 } else { 6.0 }))
                        .bg(gpui::white().opacity(0.9))
                })),
        ),
        History::Sealed => slot.child(
            div()
                .flex()
                .flex_col()
                .items_center()
                .child(
                    div()
                        .w(px(6.0))
                        .h(px(4.0))
                        .border_t(px(1.5))
                        .border_l(px(1.5))
                        .border_r(px(1.5))
                        .border_color(color)
                        .rounded_t(px(3.0)),
                )
                .child(div().w(px(9.0)).h(px(6.0)).rounded(px(1.5)).bg(color)),
        ),
    }
}

/// The session's context fill as a strip of columns, one per meter update
/// (the latest [`SEGMENTS`]). The first column after each compaction takes
/// the color of what replaced the older chat.
fn trajectory_strip(trajectory: &crate::context_trajectory::Trajectory, theme: &Theme) -> Div {
    const HEIGHT: f32 = 18.0;
    let fills = trajectory.fills();
    let skip = fills.len().saturating_sub(SEGMENTS);
    let points = trajectory.compaction_points();
    let columns = fills.iter().enumerate().skip(skip).map(|(index, fill)| {
        let point = points.iter().find(|(i, _)| *i == index).map(|(_, kind)| {
            let shape = if *kind == "opaque" {
                History::Sealed
            } else {
                History::Summary
            };
            Slot::History.color(shape, theme)
        });
        let column = div()
            .flex_none()
            .w(px(SEGMENT_W))
            .h(px(HEIGHT))
            .flex()
            .items_end()
            .rounded(px(1.0));
        // A compaction's column gets a full-height tint, so the drop it
        // caused reads even when the context after it is small.
        let column = match point {
            Some(color) => column.bg(color.opacity(0.3)),
            None => column,
        };
        column.child(
            div()
                .w_full()
                .h(px((fill * HEIGHT).max(1.0)))
                .rounded(px(1.0))
                .bg(point.unwrap_or(theme.text_faint.opacity(0.55))),
        )
    });
    let count = trajectory.compactions.len();
    let caption = match count {
        0 => "This session".to_owned(),
        1 => "This session, 1 compaction".to_owned(),
        n => format!("This session, {n} compactions"),
    };
    div()
        .flex()
        .flex_col()
        .gap(px(4.0))
        .child(
            div()
                .text_size(px(11.0))
                .text_color(theme.text_faint)
                .child(SharedString::from(caption)),
        )
        .child(
            div()
                .id("context-window-trajectory")
                .flex()
                .items_end()
                .h(px(HEIGHT))
                .gap(px(SEGMENT_GAP))
                .children(columns),
        )
}

impl Render for ContextWindowCard {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.refresh(cx);
        let theme = Theme::of(cx).for_popup();
        let reduced = crate::motion::reduced_motion(cx);
        let now = Instant::now();
        let card = div().flex().flex_col().gap(px(10.0)).w(px(BAR_WIDTH));
        let Some(transition) = &self.transition else {
            return card;
        };
        let elapsed = now.saturating_duration_since(transition.started);
        if !reduced && elapsed < transition_len(transition.cascade) {
            window.request_animation_frame();
        }
        let (counts, tokens) = self.sample(transition, now, reduced);
        let t = slot_progress(elapsed, 0, false, reduced);
        let (from, to) = (&transition.from, &transition.to);

        // Header: "Context <state>" and the rolling counter.
        let state_word = |b: &Breakdown| {
            if b.compacting {
                "compacting"
            } else {
                "reading"
            }
        };
        let (word, word_opacity) = if state_word(from) != state_word(to) && from.window > 0 {
            (
                if t < 0.5 {
                    state_word(from)
                } else {
                    state_word(to)
                },
                crossfade(t),
            )
        } else {
            (state_word(to), 1.0)
        };
        let shown = compact_count(tokens.round() as u64);
        let settled = compact_count(to.tokens);
        let previous = compact_count(transition.from_tokens.round() as u64);
        let counter = if reduced || t >= 1.0 {
            odometer(&settled, &settled, true, 1.0, theme.text)
        } else if transition.cascade {
            // Filling from empty: count up through the values.
            odometer(&shown, &shown, true, 1.0, theme.text)
        } else {
            odometer(
                &previous,
                &settled,
                to.tokens as f32 >= transition.from_tokens,
                t,
                theme.text,
            )
        };
        let header =
            div()
                .flex()
                .items_center()
                .justify_between()
                .text_size(px(13.0))
                .child(
                    div()
                        .flex()
                        .gap(px(4.0))
                        .child(
                            div()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .text_color(theme.text)
                                .child("Context"),
                        )
                        .child(
                            div()
                                .text_color(theme.text_muted)
                                .opacity(word_opacity)
                                .child(word),
                        ),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(3.0))
                        .child(counter)
                        .child(div().text_color(theme.text_faint).child(SharedString::from(
                            format!("of {}", compact_count(to.window)),
                        ))),
                );

        // The bar: each slot's whole segments, a fading partial one, then
        // the empty track.
        let history_t = if from.history != to.history { t } else { 1.0 };
        let history_color = mix(
            Slot::History.color(from.history, &theme),
            Slot::History.color(to.history, &theme),
            history_t,
        );
        let color_of = |slot: Slot| {
            if slot == Slot::History {
                history_color
            } else {
                slot.color(to.history, &theme)
            }
        };
        let mut segments: Vec<gpui::AnyElement> = Vec::with_capacity(SEGMENTS);
        let segment = |color: Hsla, opacity: f32| {
            div()
                .flex_none()
                .w(px(SEGMENT_W))
                .h(px(SEGMENT_H))
                .rounded(px(1.5))
                .bg(color)
                .opacity(opacity)
                .into_any_element()
        };
        for (slot, count) in &counts {
            let whole = count.floor() as usize;
            for _ in 0..whole {
                if segments.len() < SEGMENTS {
                    segments.push(segment(color_of(*slot), 1.0));
                }
            }
            let partial = count - whole as f32;
            if partial > 0.01 && segments.len() < SEGMENTS {
                segments.push(segment(color_of(*slot), partial));
            }
        }
        let track = theme.text_faint.opacity(0.22);
        while segments.len() < SEGMENTS {
            segments.push(segment(track, 1.0));
        }
        let bar = div()
            .id("context-window-bar")
            .flex()
            .gap(px(SEGMENT_GAP))
            .children(segments);

        // Legend: two columns; entries that arrive fade and rise in,
        // entries that leave fade out.
        let column = ((BAR_WIDTH - LEGEND_GAP) / 2.0).floor();
        let entries =
            Slot::ALL.iter().enumerate().filter_map(|(order, slot)| {
                let before = from.items.iter().find(|(s, _)| s == slot).map(|(_, n)| *n);
                let after = to.items.iter().find(|(s, _)| s == slot).map(|(_, n)| *n);
                if before.is_none() && after.is_none() {
                    return None;
                }
                let st = slot_progress(elapsed, order, transition.cascade, reduced);
                let (opacity, rise) = match (before, after) {
                    (None, Some(_)) => (st, 5.0 * (1.0 - st)),
                    (Some(_), None) => (1.0 - st, 0.0),
                    _ => (1.0, 0.0),
                };
                if opacity <= 0.0 && after.is_none() {
                    return None;
                }
                let value = lerp(before.unwrap_or(0) as f32, after.unwrap_or(0) as f32, st);
                let relabel = *slot == Slot::History && from.history != to.history;
                let (label, label_opacity) = if relabel {
                    (
                        slot.label(if st < 0.5 { from.history } else { to.history }),
                        crossfade(st),
                    )
                } else {
                    (slot.label(to.history), 1.0)
                };
                let marker = if *slot == Slot::History {
                    let (shape, t) = if relabel {
                        (
                            if st < 0.5 { from.history } else { to.history },
                            crossfade(st),
                        )
                    } else {
                        (to.history, 1.0)
                    };
                    legend_marker(shape, color_of(*slot), t)
                } else {
                    legend_marker(History::Chat, color_of(*slot), 1.0)
                };
                Some(
                    div()
                        .relative()
                        .top(px(rise))
                        .opacity(opacity)
                        .w(px(column))
                        .flex()
                        .items_center()
                        .gap(px(6.0))
                        .overflow_hidden()
                        .child(marker)
                        .child(
                            div()
                                .flex()
                                .gap(px(4.0))
                                .min_w_0()
                                .overflow_hidden()
                                .whitespace_nowrap()
                                .child(
                                    div()
                                        .text_color(theme.text)
                                        .opacity(label_opacity)
                                        .child(label),
                                )
                                .child(div().text_color(theme.text_faint).child(
                                    SharedString::from(compact_count(value.round() as u64)),
                                )),
                        ),
                )
            });
        let legend = div()
            .flex()
            .flex_wrap()
            .gap_x(px(LEGEND_GAP))
            .gap_y(px(8.0))
            .text_size(px(12.0))
            .children(entries);

        // Status line: fades up whenever its text changes.
        let status = status_line(from, to);
        let status_key = format!("context-window-status-in-{status}");
        let status_el = div()
            .id(SharedString::from(format!(
                "context-window-status-{status}"
            )))
            .text_size(px(12.0))
            .text_color(theme.text_faint)
            .child(SharedString::from(status));
        let status_el = if reduced {
            status_el.into_any_element()
        } else {
            status_el
                .with_animation(
                    SharedString::from(status_key),
                    crate::motion::MotionSpec::new(360, EASE_SETTLE).animation(),
                    |el, t| el.relative().opacity(t).top(px(5.0 * (1.0 - t))),
                )
                .into_any_element()
        };

        let trajectory = {
            let state = self.state.read(cx);
            state
                .selected_chat
                .as_ref()
                .and_then(|chat| state.context_trajectories.get(chat))
                .filter(|t| t.samples.len() >= 2)
                .map(|t| trajectory_strip(t, &theme))
        };

        card.child(header)
            .child(bar)
            .child(legend)
            .child(status_el)
            .children(trajectory)
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(theme.text_faint)
                    .whitespace_nowrap()
                    .child(if to.history == History::Sealed {
                        "Compacted context is sealed by the provider: size only."
                    } else {
                        "Split estimated from this chat; total reported by the agent."
                    }),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_proto::{CompactionMeta, ContextSavings};

    fn entry(role: MessageRole, parts: Vec<MessagePart>) -> SessionMessageEntry {
        SessionMessageEntry {
            id: "m".into(),
            role,
            parts,
            created_at: 0,
            device_id: "d".into(),
            status: None,
            continuation_of: None,
            duration_ms: None,
        }
    }

    fn text(n: usize) -> MessagePart {
        MessagePart::Text {
            id: "t".into(),
            text: "x".repeat(n),
        }
    }

    fn tool(call: ToolCall, bytes: u64, resolved: bool) -> MessagePart {
        serde_json::from_value(serde_json::json!({
            "kind": "tool", "id": "tool", "call": call,
            "resolved": resolved, "outputBytes": bytes,
        }))
        .unwrap()
    }

    fn compaction(bytes: u64, resolved: bool) -> MessagePart {
        tool(
            ToolCall::Unknown {
                name: harness_proto::COMPACTION_TOOL_NAME.into(),
                input: None,
            },
            bytes,
            resolved,
        )
    }

    fn sealed(before: u64, after: u64, item: Option<u64>, resolved: bool) -> MessagePart {
        let mut meta = CompactionMeta::new(CompactionKind::Opaque);
        meta.tokens_before = Some(before);
        meta.tokens_after = resolved.then_some(after);
        meta.item_tokens = item;
        tool(meta.call(), 0, resolved)
    }

    fn usage(tokens: u64, freed: u64) -> Option<ContextUsage> {
        Some(ContextUsage {
            tokens: Some(tokens),
            window: Some(200_000),
            savings: Some(ContextSavings {
                compacted_tokens: freed,
                ..Default::default()
            }),
        })
    }

    #[test]
    fn needs_a_reported_window() {
        assert_eq!(breakdown(None, &[]), None);
        let no_window = Some(ContextUsage {
            tokens: Some(10),
            window: Some(0),
            ..Default::default()
        });
        assert_eq!(breakdown(no_window, &[]), None);
    }

    #[test]
    fn splits_the_transcript_and_keeps_the_reported_total() {
        let transcript = vec![
            entry(MessageRole::User, vec![text(4_000)]),
            entry(
                MessageRole::Assistant,
                vec![
                    text(4_000),
                    tool(ToolCall::ReadFile { path: "a".into() }, 40_000, true),
                    tool(
                        ToolCall::Exec {
                            command: "ls".into(),
                        },
                        8_000,
                        true,
                    ),
                ],
            ),
        ];
        let b = breakdown(usage(30_000, 0), &transcript).unwrap();
        assert_eq!(
            b.items,
            vec![
                (Slot::History, 2_000),
                (Slot::Files, 10_000),
                (Slot::Commands, 2_000),
                (Slot::System, 16_000),
            ]
        );
        assert_eq!(b.items.iter().map(|(_, n)| n).sum::<u64>(), 30_000);
        assert!(!b.compacted() && !b.compacting);
    }

    #[test]
    fn an_estimate_over_the_meter_is_scaled_into_it() {
        let transcript = vec![entry(
            MessageRole::Assistant,
            vec![
                text(40_000),
                tool(ToolCall::ReadFile { path: "a".into() }, 40_000, true),
            ],
        )];
        let b = breakdown(usage(10_000, 0), &transcript).unwrap();
        assert_eq!(b.items, vec![(Slot::History, 5_000), (Slot::Files, 5_000)]);
    }

    #[test]
    fn compaction_replaces_older_chat_with_its_summary() {
        let mut transcript = vec![
            entry(MessageRole::User, vec![text(160_000)]),
            entry(
                MessageRole::Assistant,
                vec![tool(ToolCall::ReadFile { path: "a".into() }, 80_000, true)],
            ),
            entry(MessageRole::Assistant, vec![compaction(0, false)]),
        ];
        let running = breakdown(usage(90_000, 0), &transcript).unwrap();
        assert!(running.compacting && !running.compacted());
        assert_eq!(running.items[0], (Slot::History, 40_000));

        transcript[2] = entry(MessageRole::Assistant, vec![compaction(16_000, true)]);
        transcript.push(entry(MessageRole::User, vec![text(400)]));
        let done = breakdown(usage(20_000, 70_000), &transcript).unwrap();
        assert!(done.compacted() && !done.compacting);
        assert_eq!(
            done.items,
            vec![
                (Slot::History, 4_000),
                (Slot::Recent, 100),
                (Slot::System, 15_900)
            ]
        );
        assert_eq!(done.history, History::Summary);
        assert_eq!(Slot::History.label(done.history), "Chat summary");
        assert_eq!(
            status_line(&running, &done),
            "Compacted older chat, freed 70k"
        );
        assert_eq!(
            status_line(&done, &done),
            "Older chat summarized, 70k freed so far"
        );
        assert_eq!(
            status_line(&running, &running),
            "Summarizing older chat to free up space"
        );
    }

    #[test]
    fn an_opaque_compaction_is_a_sealed_block_sized_without_contents() {
        let mut transcript = vec![
            entry(MessageRole::User, vec![text(40_000)]),
            entry(
                MessageRole::Assistant,
                vec![tool(ToolCall::ReadFile { path: "a".into() }, 40_000, true)],
            ),
            entry(MessageRole::Assistant, vec![sealed(50_000, 0, None, false)]),
        ];
        let running = breakdown(usage(50_000, 0), &transcript).unwrap();
        assert!(running.compacting && running.pending == History::Sealed);
        assert_eq!(
            status_line(&running, &running),
            "Compacting older chat into a sealed item"
        );

        // 20k of the 50k came from the transcript, so 30k is system share;
        // 34k after the compaction leaves ~4k for the sealed item.
        transcript[2] = entry(
            MessageRole::Assistant,
            vec![sealed(50_000, 34_000, None, true)],
        );
        transcript.push(entry(MessageRole::User, vec![text(400)]));
        let done = breakdown(usage(34_100, 0), &transcript).unwrap();
        assert_eq!(done.history, History::Sealed);
        assert!(done.sealed_estimated && !done.compacting);
        assert_eq!(
            done.items,
            vec![
                (Slot::History, 4_000),
                (Slot::Recent, 100),
                (Slot::System, 30_000)
            ]
        );
        assert_eq!(Slot::History.label(done.history), "Compacted context");
        assert_eq!(done.freed, 16_000);
        assert_eq!(status_line(&running, &done), "Sealed older chat, freed 16k");
        assert_eq!(
            status_line(&done, &done),
            "Older chat sealed, 16k freed so far"
        );

        // A size the agent reports wins over the estimate.
        transcript[2] = entry(
            MessageRole::Assistant,
            vec![sealed(50_000, 34_000, Some(2_500), true)],
        );
        let reported = breakdown(usage(34_100, 0), &transcript).unwrap();
        assert!(!reported.sealed_estimated);
        assert_eq!(reported.items[0], (Slot::History, 2_500));
    }

    #[test]
    fn a_later_summary_replaces_an_earlier_sealed_block() {
        let transcript = vec![
            entry(MessageRole::User, vec![text(8_000)]),
            entry(
                MessageRole::Assistant,
                vec![sealed(10_000, 6_000, Some(1_000), true)],
            ),
            entry(MessageRole::User, vec![text(8_000)]),
            entry(MessageRole::Assistant, vec![compaction(2_000, true)]),
        ];
        let b = breakdown(usage(5_000, 0), &transcript).unwrap();
        assert_eq!(b.history, History::Summary);
        assert_eq!(b.items, vec![(Slot::History, 500), (Slot::System, 4_500)]);
        assert_eq!(b.freed, 4_000);
    }

    #[test]
    fn segments_never_overflow_and_small_slots_stay_visible() {
        let b = Breakdown {
            tokens: 200_000,
            window: 200_000,
            items: vec![(Slot::History, 199_900), (Slot::Files, 100)],
            ..Default::default()
        };
        let counts = segment_counts(&b);
        assert_eq!(counts.iter().map(|(_, c)| c).sum::<f32>(), SEGMENTS as f32);
        let small = Breakdown {
            tokens: 100,
            window: 200_000,
            items: vec![(Slot::Files, 100)],
            ..Default::default()
        };
        assert_eq!(segment_counts(&small), vec![(Slot::Files, 1.0)]);
    }

    #[test]
    fn motion_staggers_blocks_and_snaps_under_reduced_motion() {
        let at = Duration::from_millis(100);
        assert!(slot_progress(at, 0, true, false) > slot_progress(at, 3, true, false));
        assert_eq!(slot_progress(Duration::ZERO, 5, true, true), 1.0);
        assert_eq!(
            slot_progress(Duration::from_millis(5_000), 6, true, false),
            1.0
        );
        assert_eq!(crossfade(0.0), 1.0);
        assert_eq!(crossfade(0.5), 0.0);
        assert_eq!(crossfade(1.0), 1.0);
    }
}
