//! Context occupancy is read from the replicated chat snapshot, never local CLI state.
use crate::theme::Theme;
use gpui::{
    Context, IntoElement, PathBuilder, Render, SharedString, Window, canvas, div, point,
    prelude::*, px,
};
use harness_proto::ContextUsage;

pub fn render(
    usage: Option<ContextUsage>,
    state: gpui::Entity<crate::state::AppState>,
    theme: &Theme,
) -> gpui::Stateful<gpui::Div> {
    let fraction = usage.and_then(ContextUsage::fraction);
    let color = match fraction {
        Some(f) if f >= 0.9 => theme.danger,
        Some(f) if f >= 0.75 => theme.warning,
        Some(_) => theme.text_muted,
        None => theme.text_faint,
    };
    let track = theme.text_faint.opacity(0.25);
    let ring = canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let center = bounds.center();
            let mut arc = |fraction: f32, color| {
                if fraction <= 0.0 {
                    return;
                }
                let steps = (64.0 * fraction).ceil().max(2.0) as usize;
                let mut path = PathBuilder::stroke(px(1.8));
                for i in 0..=steps {
                    let angle = -std::f32::consts::FRAC_PI_2
                        + std::f32::consts::TAU * fraction * i as f32 / steps as f32;
                    let p = point(
                        center.x + px(6.0 * angle.cos()),
                        center.y + px(6.0 * angle.sin()),
                    );
                    if i == 0 {
                        path.move_to(p);
                    } else {
                        path.line_to(p);
                    }
                }
                if let Ok(path) = path.build() {
                    window.paint_path(path, color);
                }
            };
            arc(1.0, track);
            arc(fraction.unwrap_or(0.0).clamp(0.0, 1.0) as f32, color);
        },
    )
    .size(px(16.0));
    let percent = fraction
        .map(|f| format!("{:.0}%", f * 100.0))
        .unwrap_or_else(|| "—".into());
    div()
        .id("context-usage")
        .debug_selector(|| "context-usage".into())
        .flex_none()
        .flex()
        .items_center()
        .gap(px(5.0))
        .h(px(24.0))
        .px(px(6.0))
        .rounded(px(6.0))
        .text_size(px(11.0))
        .text_color(color)
        .hover(|s| s.bg(crate::theme::ink(0.05)))
        .child(ring)
        .child(SharedString::from(percent))
        .tooltip(move |_, cx| {
            cx.new(|cx| UsageCard {
                _subscription: cx.observe(&state, |_, _, cx| cx.notify()),
                state: state.clone(),
            })
            .into()
        })
}

struct UsageCard {
    state: gpui::Entity<crate::state::AppState>,
    _subscription: gpui::Subscription,
}

fn with_separators(count: u64) -> String {
    let digits = count.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    grouped
}

/// Below this, a saving isn't worth a label: one handle or a cache hit on
/// the first turn.
const SAVED_LABEL_MIN: u64 = 1_000;

/// "12k saved": the tokens the agent kept out of its context (graff). Cache
/// reads are not counted: those tokens were in the context, only cheaper.
fn saved_label(usage: Option<ContextUsage>) -> Option<String> {
    let kept = usage?.savings?.kept_out_tokens();
    (kept >= SAVED_LABEL_MIN).then(|| format!("{} saved", compact_count(kept)))
}

/// 1.2k, 34k, 1.5M.
fn compact_count(n: u64) -> String {
    match n {
        0..1_000 => n.to_string(),
        1_000..10_000 => format!("{:.1}k", n as f64 / 1_000.0),
        10_000..1_000_000 => format!("{}k", n / 1_000),
        _ => format!("{:.1}M", n as f64 / 1_000_000.0),
    }
}

/// The card's breakdown of [`ContextSavings`], one measured source per line.
fn savings_details(usage: Option<ContextUsage>) -> Option<String> {
    let s = usage?.savings?;
    let mut lines = Vec::new();
    if s.handle_bytes > 0 {
        lines.push(format!(
            "~{} tokens of tool output kept in files",
            with_separators(s.handle_tokens())
        ));
    }
    if s.compacted_tokens > 0 {
        lines.push(format!(
            "~{} tokens freed by compaction",
            with_separators(s.compacted_tokens)
        ));
    }
    if s.cache_read_tokens > 0 {
        lines.push(format!(
            "{} input tokens read from the provider's cache",
            with_separators(s.cache_read_tokens)
        ));
    }
    (!lines.is_empty()).then(|| lines.join("\n"))
}

/// whether the indicator has anything to measure against: harnesses that
/// never report a window (antigravity) get no indicator at all, rather than a
/// permanently empty ring.
pub fn has_window(usage: Option<ContextUsage>) -> bool {
    usage
        .and_then(|usage| usage.window)
        .is_some_and(|window| window > 0)
}

fn details(usage: Option<ContextUsage>) -> String {
    match usage.unwrap_or_default() {
        ContextUsage {
            tokens: Some(tokens),
            window: Some(window),
            ..
        } if window > 0 => {
            format!(
                "{} / {} tokens\n{} tokens remaining",
                with_separators(tokens),
                with_separators(window),
                with_separators(window.saturating_sub(tokens))
            )
        }
        ContextUsage {
            tokens: Some(tokens),
            ..
        } => format!(
            "{} tokens used\nContext limit not reported",
            with_separators(tokens)
        ),
        ContextUsage {
            window: Some(window),
            ..
        } if window > 0 => format!(
            "{} token capacity\nWaiting for context usage",
            with_separators(window)
        ),
        _ => "Context usage not reported by this harness yet".into(),
    }
}

impl Render for UsageCard {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = &Theme::of(cx).for_popup();
        let card = crate::popover::popover_card(theme)
            .p(px(12.0))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .child(
                div()
                    .text_size(px(12.0))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child("Context window"),
            )
            .child(
                // the lines break only at their own newlines: a tooltip sizes
                // from the unwrapped text, so soft wrapping clipped the last line
                div()
                    .text_size(px(12.0))
                    .line_height(px(19.0))
                    .whitespace_nowrap()
                    .text_color(theme.text_muted)
                    .child(SharedString::from(details(
                        self.state.read(cx).context_usage,
                    ))),
            )
            .children(saved_label(self.state.read(cx).context_usage).map(|label| {
                div()
                    .text_size(px(12.0))
                    .text_color(theme.text_muted)
                    .child(SharedString::from(label))
            }))
            .children(savings_details(self.state.read(cx).context_usage).map(|lines| {
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .pt(px(4.0))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .text_color(theme.text)
                            .child("Kept out of context by graff"),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .line_height(px(19.0))
                            .whitespace_nowrap()
                            .text_color(theme.text_muted)
                            .child(SharedString::from(lines)),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .whitespace_nowrap()
                            .text_color(theme.text_faint)
                            .child("Measured by graff in this session; tool output counted at 4 bytes a token."),
                    )
            }));
        crate::frost::frosted(crate::popover::CARD_RADIUS, crate::frost::MENU_BLUR, card)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn indicator_needs_a_reported_window() {
        assert!(!has_window(None));
        assert!(!has_window(Some(ContextUsage {
            tokens: Some(1_200),
            window: None,
            ..Default::default()
        })));
        assert!(!has_window(Some(ContextUsage {
            tokens: Some(1_200),
            window: Some(0),
            ..Default::default()
        })));
        assert!(has_window(Some(ContextUsage {
            tokens: None,
            window: Some(200_000),
            ..Default::default()
        })));
    }

    #[test]
    fn missing_usage_is_distinct_from_zero_and_overflow() {
        assert!(details(None).contains("not reported"));
        assert!(
            details(Some(ContextUsage {
                tokens: Some(0),
                window: Some(200),
                ..Default::default()
            }))
            .contains("200 tokens remaining")
        );
        assert!(
            details(Some(ContextUsage {
                tokens: Some(250),
                window: Some(200),
                ..Default::default()
            }))
            .contains("0 tokens remaining")
        );
        assert!(
            details(Some(ContextUsage {
                tokens: Some(10),
                window: Some(0),
                ..Default::default()
            }))
            .contains("limit not reported")
        );
    }

    #[test]
    fn savings_show_what_graff_kept_out_and_never_count_the_cache() {
        let usage = |savings| {
            Some(ContextUsage {
                tokens: Some(40_000),
                window: Some(200_000),
                savings: Some(savings),
            })
        };
        let saved = usage(harness_proto::ContextSavings {
            handle_bytes: 96_000,
            compacted_tokens: 78_000,
            cache_read_tokens: 500_000,
        });
        assert_eq!(saved_label(saved).as_deref(), Some("102k saved"));
        assert_eq!(
            savings_details(saved).unwrap(),
            "~24,000 tokens of tool output kept in files\n\
             ~78,000 tokens freed by compaction\n\
             500,000 input tokens read from the provider's cache"
        );
        // Cache reads alone aren't a saving; the card still says what they were.
        let cached = usage(harness_proto::ContextSavings {
            cache_read_tokens: 9_000,
            ..Default::default()
        });
        assert_eq!(saved_label(cached), None);
        assert!(
            savings_details(cached)
                .unwrap()
                .contains("9,000 input tokens")
        );
        // Other harnesses report no savings at all.
        assert_eq!(saved_label(Some(ContextUsage::default())), None);
        assert_eq!(savings_details(None), None);
        assert_eq!(compact_count(1_250), "1.2k");
        assert_eq!(compact_count(1_500_000), "1.5M");
    }

    #[test]
    fn token_counts_are_grouped_by_thousands() {
        assert_eq!(with_separators(0), "0");
        assert_eq!(with_separators(999), "999");
        assert_eq!(with_separators(5417), "5,417");
        assert_eq!(with_separators(1_048_576), "1,048,576");
        assert_eq!(
            details(Some(ContextUsage {
                tokens: Some(5417),
                window: Some(1_048_576),
                ..Default::default()
            })),
            "5,417 / 1,048,576 tokens\n1,043,159 tokens remaining"
        );
    }
}
