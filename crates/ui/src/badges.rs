//! Message badges: the compact pills that stand in for structured context a
//! user message carries.
//!
//! The whole family shares one shape. Some feature stages context against the
//! composer, folds it into the outgoing prompt as PLAIN TEXT (there is no
//! second data model — see `comments.rs` and `attachments.rs`), and registers
//! a [`Extractor`] here. The composer shows the staged set as a pill while it
//! is being written; once sent, [`split`] lifts the same block back out of the
//! transcript's raw text so the message reads as one pill over the bubble
//! instead of a wall of machine-addressed bullets.
//!
//! Adding a second kind of pill means adding an extractor to [`EXTRACTORS`]
//! and a matching stager on the composer side. Nothing here knows what a diff
//! comment is.

use gpui::{ParentElement, SharedString, Styled, div, px};

use crate::theme::Theme;

/// One pill: an icon and a short label, both already resolved for display.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageBadge {
    /// An `icons::*` asset name.
    pub icon: &'static str,
    pub label: SharedString,
}

/// Lifts one feature's trailing block out of a sent message. Returns the text
/// with the block removed plus the pill that replaces it, or `None` when this
/// message carries nothing of that kind.
pub type Extractor = fn(&str) -> Option<(String, MessageBadge)>;

/// Every registered extractor, applied in order. Each one sees the text the
/// previous ones already stripped, so two features can ride the same prompt.
const EXTRACTORS: &[Extractor] = &[crate::comments::extract_badge];

/// Split every registered badge block back out of a sent user message.
///
/// Pure over the text, like `attachments::parse_user_message_images` — the
/// transcript's row version stays a valid cache key because nothing here
/// depends on state outside the string.
pub fn split(text: &str) -> (String, Vec<MessageBadge>) {
    let mut rest = text.to_string();
    let mut badges = Vec::new();
    for extract in EXTRACTORS {
        if let Some((stripped, badge)) = extract(&rest) {
            rest = stripped;
            badges.push(badge);
        }
    }
    (rest, badges)
}

/// Rendered height of a pill, and of the row that holds one. The composer
/// sizes its own strip arithmetically, so this has to be a constant.
pub const BADGE_HEIGHT: f32 = 24.0;

/// The pill itself — one element, so the composer's staged chip and the
/// transcript's sent chip can never drift apart.
pub fn render(badge: &MessageBadge, theme: &Theme) -> gpui::Div {
    div()
        .h(px(BADGE_HEIGHT))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.0))
        .px(px(8.0))
        .rounded(px(8.0))
        .bg(crate::theme::ink(0.06))
        .text_size(px(12.0))
        .font_weight(gpui::FontWeight::MEDIUM)
        .text_color(theme.text_muted)
        .child(
            crate::icons::icon(badge.icon)
                .size(px(12.0))
                .text_color(theme.text_muted.opacity(0.7)),
        )
        .child(badge.label.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::comments::{CommentSide, DiffComment, with_comments};

    #[test]
    fn a_plain_message_carries_no_badges() {
        let (text, badges) = split("just a prompt");
        assert_eq!(text, "just a prompt");
        assert!(badges.is_empty());
    }

    #[test]
    fn a_sent_comment_block_becomes_one_pill() {
        let staged = vec![
            DiffComment::new("a.rs", CommentSide::New, 3, "fix"),
            DiffComment::new("b.rs", CommentSide::Old, 9, "why"),
        ];
        let (text, badges) = split(&with_comments("do", &staged));
        assert_eq!(text, "do");
        assert_eq!(badges.len(), 1);
        assert_eq!(badges[0].label.as_ref(), "2 comments");
    }

    #[test]
    fn a_comment_only_send_keeps_its_stand_in_body() {
        let staged = vec![DiffComment::new("a.rs", CommentSide::New, 3, "fix")];
        let (text, badges) = split(&with_comments("", &staged));
        assert_eq!(text, crate::comments::COMMENT_ONLY_TEXT);
        assert_eq!(badges[0].label.as_ref(), "1 comment");
    }
}
