//! What a wait reports as a turn's replies (#1415): the assistant messages of
//! the turn being waited on, never a history folded through continuations,
//! each trimmed to its end.

use crate::transcript::{RenderOptions, RenderedMessage, render_entries};

/// A wait's replies never carry more than this much text per message, or this
/// many tool lines: the caller wants the turn's outcome, and the whole reply is
/// one `get_chat` away.
const REPLY_TEXT_CAP: usize = 16 * 1024;
const REPLY_TOOLS_CAP: usize = 40;
pub(crate) const REPLIES_TRUNCATED_NOTE: &str =
    "Long replies were trimmed to their end; get_chat returns the full transcript.";

/// The assistant replies of the turn a wait is about (#1415).
///
/// Only entries created at or after the turn's start are rendered, so a
/// continuation chain cannot fold earlier turns into "the newest reply". The
/// turn starts at the caller's send (`since_millis`, with a little clock
/// slack) or, for a bare wait, at the newest user message. When nothing landed
/// in that window, the newest assistant entry alone stands in. Each reply is
/// trimmed to its end; the bool says whether anything was trimmed.
pub(crate) fn turn_replies(
    entries: &[harness_doc::SessionMessageEntry],
    since_millis: i64,
) -> (Vec<RenderedMessage>, bool) {
    let start = if since_millis > 0 {
        since_millis.saturating_sub(2_000)
    } else {
        entries
            .iter()
            .rev()
            .find(|e| e.role == harness_doc::MessageRole::User)
            .map(|e| e.created_at)
            .unwrap_or(i64::MIN)
    };
    let window: Vec<_> = entries
        .iter()
        .filter(|e| e.created_at >= start)
        .cloned()
        .collect();
    let mut replies: Vec<RenderedMessage> = render_entries(&window, RenderOptions::default())
        .into_iter()
        .filter(|m| m.role == harness_doc::MessageRole::Assistant)
        .collect();
    if replies.is_empty()
        && let Some(last) = entries
            .iter()
            .rev()
            .find(|e| e.role == harness_doc::MessageRole::Assistant)
    {
        replies = render_entries(std::slice::from_ref(last), RenderOptions::default());
    }
    let mut truncated = false;
    for reply in &mut replies {
        truncated |= trim_reply(reply);
    }
    (replies, truncated)
}

/// Keep the end of a long reply (where a turn's outcome is): the last
/// `REPLY_TEXT_CAP` bytes of text and the last `REPLY_TOOLS_CAP` tool lines.
fn trim_reply(reply: &mut RenderedMessage) -> bool {
    let mut trimmed = false;
    if reply.text.len() > REPLY_TEXT_CAP {
        let mut cut = reply.text.len() - REPLY_TEXT_CAP;
        while !reply.text.is_char_boundary(cut) {
            cut += 1;
        }
        reply.text = format!("…{}", &reply.text[cut..]);
        trimmed = true;
    }
    if reply.tools.len() > REPLY_TOOLS_CAP {
        let drop = reply.tools.len() - REPLY_TOOLS_CAP;
        reply.tools.drain(..drop);
        reply
            .tools
            .insert(0, format!("… {drop} earlier tool calls"));
        trimmed = true;
    }
    trimmed
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn entry(
        id: &str,
        role: &str,
        at: i64,
        text: &str,
        parent: Option<&str>,
    ) -> harness_doc::SessionMessageEntry {
        serde_json::from_value(json!({
            "id": id, "role": role, "createdAt": at, "deviceId": "d",
            "parts": [{"kind": "text", "id": format!("{id}-p"), "text": text}],
            "continuationOf": parent,
        }))
        .unwrap()
    }

    fn texts(replies: &[RenderedMessage]) -> Vec<&str> {
        replies.iter().map(|r| r.text.as_str()).collect()
    }

    #[test]
    fn a_bare_wait_returns_the_current_turn_not_a_folded_history() {
        // A continuation chain that runs across turns used to fold every
        // earlier turn into the "newest" reply.
        let entries = vec![
            entry("u1", "user", 1_000, "first task", None),
            entry("a1", "assistant", 1_100, "old work", None),
            entry("u2", "user", 9_000, "second task", None),
            entry("a2", "assistant", 9_100, "new work", Some("a1")),
            entry("a3", "assistant", 9_200, "new work, continued", Some("a2")),
        ];
        let (replies, truncated) = turn_replies(&entries, 0);
        assert_eq!(texts(&replies), ["new work\n\nnew work, continued"]);
        assert!(!truncated);
    }

    #[test]
    fn a_send_and_wait_returns_what_landed_since_the_send() {
        let entries = vec![
            entry("a1", "assistant", 1_000, "before the send", None),
            entry("a2", "assistant", 20_500, "after the send", Some("a1")),
        ];
        let (replies, _) = turn_replies(&entries, 20_000);
        assert_eq!(texts(&replies), ["after the send"]);
        // Nothing new yet: the newest entry alone, not its folded chain.
        let (replies, _) = turn_replies(&entries, 30_000);
        assert_eq!(texts(&replies), ["after the send"]);
    }

    #[test]
    fn long_replies_keep_their_end_and_say_so() {
        let long = format!("{}THE END", "x".repeat(REPLY_TEXT_CAP * 2));
        let entries = vec![
            entry("u", "user", 1, "go", None),
            entry("a", "assistant", 2, &long, None),
        ];
        let (replies, truncated) = turn_replies(&entries, 0);
        assert!(truncated);
        assert!(replies[0].text.ends_with("THE END"));
        assert!(replies[0].text.len() <= REPLY_TEXT_CAP + 4);
        let mut many = replies[0].clone();
        many.tools = (0..REPLY_TOOLS_CAP + 10)
            .map(|i| format!("tool {i}"))
            .collect();
        assert!(trim_reply(&mut many));
        assert_eq!(many.tools.len(), REPLY_TOOLS_CAP + 1);
        assert_eq!(many.tools[0], "… 10 earlier tool calls");
        assert_eq!(
            many.tools.last().unwrap(),
            &format!("tool {}", REPLY_TOOLS_CAP + 9)
        );
    }
}
