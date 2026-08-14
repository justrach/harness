//! Diff comments: notes pinned to an exact line of the changes pane, staged in
//! the composer and folded into the next prompt.
//!
//! The transport is deliberately the same shape as `attachments.rs`: the
//! comments ride the user message as PLAIN TEXT (see [`with_comments`]). There
//! is no second data model — nothing to persist, nothing to sync, and the
//! agent reads `path:line` in the prompt exactly as a human would. The
//! composer projects the staged set to one chip while it is being composed;
//! once sent, the message is ordinary text and the transcript renders it as
//! such, the same way file mentions carry their own Markdown.

use std::collections::HashMap;

/// Which column of the diff a comment's line number came from. A comment on a
/// deleted line can only ever cite the pre-change file, so the side has to
/// travel with the number — `path:42` alone would send the agent to the wrong
/// line whenever a hunk shifts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CommentSide {
    Old,
    New,
}

/// One staged comment. `id` is client-minted and only ever used to remove the
/// row again — it never leaves the process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffComment {
    pub id: String,
    /// Display path of the file, as the patch header spells it.
    pub path: String,
    pub side: CommentSide,
    pub line: u32,
    pub body: String,
}

impl DiffComment {
    pub fn new(
        path: impl Into<String>,
        side: CommentSide,
        line: u32,
        body: impl Into<String>,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            path: path.into(),
            side,
            line,
            body: body.into(),
        }
    }

    /// The anchor a rendered diff row matches itself against.
    pub fn anchor(&self) -> (CommentSide, u32) {
        (self.side, self.line)
    }

    /// `file.rs:42` — how the comment cites its line to the agent, and what
    /// the card shows in its header.
    pub fn location(&self) -> String {
        format!("{}:{}", self.path, self.line)
    }
}

/// Body used when the user stages comments and sends with an empty prompt —
/// mirrors `attachments::ATTACHMENT_ONLY_TEXT`.
pub const COMMENT_ONLY_TEXT: &str = "Address the review comments below.";

/// How comments ride the prompt: a trailing block of `path:line` bullets.
///
/// Multi-line bodies are indented under their bullet so the block stays
/// unambiguous when the agent re-reads it, and `L`/`R` marks which side of the
/// diff the number indexes (`R` = the post-change file, the common case).
pub fn with_comments(text: &str, comments: &[DiffComment]) -> String {
    if comments.is_empty() {
        return text.to_string();
    }
    let bullets: Vec<String> = comments
        .iter()
        .map(|comment| {
            let side = match comment.side {
                CommentSide::Old => "L",
                CommentSide::New => "R",
            };
            // Continuation lines are indented to the bullet's text column; an
            // unindented second line would read as a new comment.
            let body = comment.body.trim().replace('\n', "\n  ");
            format!("- {}:{} ({side}): {body}", comment.path, comment.line)
        })
        .collect();
    let body = if text.is_empty() {
        COMMENT_ONLY_TEXT
    } else {
        text
    };
    format!(
        "{body}\n\nComments on the diff (each cites the file and line it belongs to; L = line number in the original file, R = in the changed file):\n{}",
        bullets.join("\n")
    )
}

/// Composer chip label — "1 comment" / "4 comments".
pub fn chip_label(count: usize) -> String {
    if count == 1 {
        "1 comment".to_string()
    } else {
        format!("{count} comments")
    }
}

/// Group a chat's staged comments by file path for rendering — the changes
/// pane walks one file at a time and needs its comments in line order.
pub fn by_path(comments: &[DiffComment]) -> HashMap<&str, Vec<&DiffComment>> {
    let mut map: HashMap<&str, Vec<&DiffComment>> = HashMap::new();
    for comment in comments {
        map.entry(comment.path.as_str()).or_default().push(comment);
    }
    map
}

pub const CARD_PAD_V: f32 = 20.0;
pub const CARD_HEADER_HEIGHT: f32 = 22.0;
pub const CARD_LINE_HEIGHT: f32 = 18.0;
pub const CARD_GAP: f32 = 6.0;
/// Characters a card body fits per line at the pane's usual width. Only used
/// to guess soft wraps — see [`card_height`].
const CARD_WRAP_COLUMNS: usize = 64;
/// Ceiling on rendered body lines. A pasted essay clips inside its own card
/// rather than pushing the whole file body out of its fold height.
const CARD_MAX_LINES: usize = 8;

/// Rendered height of a comment card.
///
/// Analytic, because the changes pane sizes file bodies by arithmetic to drive
/// the fold tween (`changes::body_height`) — a measured card would desync it,
/// and the fold clips to the analytic number. That means soft wraps have to be
/// *guessed* here (the pure function has no width): each hard line is charged
/// one row per [`CARD_WRAP_COLUMNS`] characters, and the total is capped.
pub fn card_body_lines(body: &str) -> usize {
    body.lines()
        .map(|line| line.chars().count().div_ceil(CARD_WRAP_COLUMNS).max(1))
        .sum::<usize>()
        .clamp(1, CARD_MAX_LINES)
}

pub fn card_height(body: &str) -> f32 {
    CARD_PAD_V + CARD_HEADER_HEIGHT + card_body_lines(body) as f32 * CARD_LINE_HEIGHT + CARD_GAP
}

/// The draft card is a fixed two-row affair (input + actions) — its height is
/// constant so an open draft never fights the fold tween.
pub const DRAFT_CARD_HEIGHT: f32 = 116.0;

#[cfg(test)]
mod tests {
    use super::*;

    fn comment(path: &str, side: CommentSide, line: u32, body: &str) -> DiffComment {
        DiffComment::new(path, side, line, body)
    }

    #[test]
    fn empty_set_leaves_the_prompt_untouched() {
        assert_eq!(with_comments("ship it", &[]), "ship it");
    }

    #[test]
    fn comments_append_as_located_bullets() {
        let staged = vec![
            comment("src/main.rs", CommentSide::New, 42, "early-return here"),
            comment("src/lib.rs", CommentSide::Old, 7, "why was this dropped?"),
        ];
        let out = with_comments("look at these", &staged);
        assert!(out.starts_with("look at these\n\n"));
        assert!(out.contains("- src/main.rs:42 (R): early-return here"));
        assert!(out.contains("- src/lib.rs:7 (L): why was this dropped?"));
    }

    #[test]
    fn comment_only_send_gets_a_body() {
        let staged = vec![comment("a.rs", CommentSide::New, 1, "fix")];
        assert!(with_comments("", &staged).starts_with(COMMENT_ONLY_TEXT));
    }

    #[test]
    fn multiline_bodies_indent_under_their_bullet() {
        let staged = vec![comment("a.rs", CommentSide::New, 3, "first\nsecond")];
        assert!(with_comments("x", &staged).contains("- a.rs:3 (R): first\n  second"));
    }

    #[test]
    fn chip_label_pluralizes() {
        assert_eq!(chip_label(1), "1 comment");
        assert_eq!(chip_label(2), "2 comments");
        assert_eq!(chip_label(0), "0 comments");
    }

    #[test]
    fn grouping_keeps_per_file_order() {
        let staged = vec![
            comment("a.rs", CommentSide::New, 9, "x"),
            comment("b.rs", CommentSide::New, 1, "y"),
            comment("a.rs", CommentSide::New, 2, "z"),
        ];
        let grouped = by_path(&staged);
        assert_eq!(grouped["a.rs"].len(), 2);
        assert_eq!(grouped["a.rs"][0].line, 9);
        assert_eq!(grouped["a.rs"][1].line, 2);
        assert_eq!(grouped["b.rs"].len(), 1);
    }

    #[test]
    fn card_height_grows_with_body_lines() {
        assert!(card_height("two\nlines") > card_height("one"));
        // An empty body still reserves one line — the card is never zero-tall.
        assert_eq!(card_height(""), card_height("one"));
    }

    #[test]
    fn long_lines_are_charged_for_their_soft_wraps() {
        assert_eq!(card_body_lines("short"), 1);
        assert_eq!(card_body_lines(&"x".repeat(CARD_WRAP_COLUMNS)), 1);
        assert_eq!(card_body_lines(&"x".repeat(CARD_WRAP_COLUMNS + 1)), 2);
        // Capped, so a pasted essay can't blow out the fold height.
        assert_eq!(card_body_lines(&"line\n".repeat(200)), CARD_MAX_LINES);
    }
}
