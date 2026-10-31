//! Text selection for rendered markdown (round 18).
//!
//! gpui has no built-in selection for plain text elements. Zed's markdown
//! selects continuously because its whole document is ONE element over one
//! text model; harness renders a TREE of text elements inside a virtualized
//! list, so this module rebuilds that continuity: every frame the renderer
//! registers each painted text element in paint order (= document order),
//! and a drag anchored in one element resolves against that registry into
//! per-element SPANS — partial in the anchor/head elements, whole for every
//! element between. The wash paints per element from its span; copy joins
//! the spans in order.
//!
//! This module is the pure state half (gpui-free, unit-tested); the
//! registry, geometry and mouse listeners live in `render.rs`.

use std::ops::Range;
use std::sync::{Mutex, OnceLock};

/// One element's slice of the selection, in document order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    /// Element key (`{row_key}:{element ix}`).
    pub key: String,
    /// Selected byte range of the element's flat text.
    pub range: Range<usize>,
    /// The element's full flat text (copy source, snapshotted at drag time
    /// so copy still works after the element scrolls out of the registry).
    pub text: String,
}

#[derive(Clone, Default)]
struct MdSelection {
    /// Element that owns the drag (where the mouse went down).
    anchor_key: String,
    /// Stable surface identity, retained when virtualization unmounts the anchor.
    anchor_owner: Option<u64>,
    /// Byte offset of the anchor within its element.
    anchor_ix: usize,
    /// The immediate word/paragraph selected by a multi-click. Moving inside
    /// it (including a stationary pointer refresh) must not erase that span.
    initial_span: Option<Range<usize>>,
    dragging: bool,
    /// Document direction established while the anchor is still painted.
    /// Once virtualization moves it out of the registry, this tells us which
    /// side of the accumulated spans to preserve while extending the head.
    forward: Option<bool>,
    /// Resolved spans, document order. Empty while a click hasn't moved.
    spans: Vec<Span>,
}

fn state() -> &'static Mutex<Option<MdSelection>> {
    static STATE: OnceLock<Mutex<Option<MdSelection>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(None))
}

/// Selection state is process-global; tests that exercise its lifecycle must
/// not race each other.
#[cfg(test)]
pub(crate) fn test_state_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Resolve the spans for a selection between `a` and `b`, each an
/// `(element index, byte offset)` into `elements` (document-ordered
/// `(key, text)` pairs). Handles either direction; empty slices are skipped.
pub fn resolve_spans(elements: &[(&str, &str)], a: (usize, usize), b: (usize, usize)) -> Vec<Span> {
    let (start, end) = if (a.0, a.1) <= (b.0, b.1) {
        (a, b)
    } else {
        (b, a)
    };
    let mut spans = Vec::new();
    for (ei, (key, text)) in elements.iter().enumerate().take(end.0 + 1).skip(start.0) {
        let from = if ei == start.0 { start.1 } else { 0 };
        let to = if ei == end.0 { end.1 } else { text.len() };
        let (from, to) = (from.min(text.len()), to.min(text.len()));
        // Keep empty elements strictly between the endpoints. Rendered code
        // fences register one element per source line, so a blank line must
        // contribute its newline when a selection crosses it.
        if from < to || (ei > start.0 && ei < end.0) {
            spans.push(Span {
                key: (*key).to_string(),
                range: from..to,
                text: (*text).to_string(),
            });
        }
    }
    spans
}

/// Begin a drag anchored at `(key, ix)`; claims the global selection.
pub fn begin(key: &str, ix: usize) {
    *state().lock().unwrap() = Some(MdSelection {
        anchor_key: key.to_string(),
        anchor_owner: None,
        anchor_ix: ix,
        initial_span: None,
        dragging: true,
        forward: None,
        spans: Vec::new(),
    });
}

/// Begin with an immediate span (double/triple click inside one element).
pub fn begin_with_span(key: &str, text: &str, range: Range<usize>) {
    *state().lock().unwrap() = Some(MdSelection {
        anchor_key: key.to_string(),
        anchor_owner: None,
        anchor_ix: range.start,
        initial_span: Some(range.clone()),
        dragging: true,
        forward: None,
        spans: vec![Span {
            key: key.to_string(),
            range,
            text: text.to_string(),
        }],
    });
}

/// The live drag's anchor, if `key` owns it: `(anchor byte offset)`.
pub fn drag_anchor(key: &str) -> Option<usize> {
    let guard = state().lock().unwrap();
    let sel = guard.as_ref()?;
    (sel.dragging && sel.anchor_key == key).then_some(sel.anchor_ix)
}

pub(crate) fn anchor_key() -> Option<String> {
    state()
        .lock()
        .unwrap()
        .as_ref()
        .map(|s| s.anchor_key.clone())
}

/// Remember the surface that claimed this gesture independently of painted rows.
pub(crate) fn set_anchor_owner(key: &str, owner: u64) {
    if let Some(selection) = state()
        .lock()
        .unwrap()
        .as_mut()
        .filter(|selection| selection.dragging && selection.anchor_key == key)
    {
        selection.anchor_owner = Some(owner);
    }
}

pub(crate) fn anchor_owner() -> Option<u64> {
    state()
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|selection| selection.anchor_owner)
}

/// Whether a markdown selection drag is currently in flight.
pub fn is_dragging() -> bool {
    state()
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|selection| selection.dragging)
}

/// Resolve a drag head against this frame's visible elements.
///
/// While the anchor is visible this is a normal replacement, which lets the
/// user contract or reverse the selection. Once a virtualized list scrolls the
/// anchor away, merge through an overlapping selected element instead. The
/// overlap preserves text that is no longer painted while allowing newly
/// visible elements at the drag edge to join the selection.
pub fn update_drag(elements: &[(&str, &str)], head: (usize, usize)) -> bool {
    let mut guard = state().lock().unwrap();
    let Some(selection) = guard.as_mut().filter(|selection| selection.dragging) else {
        return false;
    };
    let spans = if let Some(anchor_ei) = elements
        .iter()
        .position(|(key, _)| *key == selection.anchor_key)
    {
        let (anchor, head) = if let Some(range) = &selection.initial_span {
            let start = (anchor_ei, range.start);
            let end = (anchor_ei, range.end);
            if head < start {
                (end, head)
            } else if head > end {
                (start, head)
            } else {
                (start, end)
            }
        } else {
            ((anchor_ei, selection.anchor_ix), head)
        };
        selection.forward = Some(anchor <= head);
        resolve_spans(elements, anchor, head)
    } else {
        let Some(forward) = selection.forward else {
            return false;
        };
        let Some(spans) = extend_virtualized_drag(&selection.spans, elements, head, forward) else {
            return false;
        };
        spans
    };
    if selection.spans == spans {
        return false;
    }
    selection.spans = spans;
    true
}

fn extend_virtualized_drag(
    existing: &[Span],
    elements: &[(&str, &str)],
    head: (usize, usize),
    forward: bool,
) -> Option<Vec<Span>> {
    if forward {
        let (element_ix, span_ix) =
            elements
                .iter()
                .enumerate()
                .find_map(|(element_ix, (key, _))| {
                    existing
                        .iter()
                        .position(|span| span.key == *key)
                        .map(|span_ix| (element_ix, span_ix))
                })?;
        let start = existing[span_ix].range.start;
        let mut merged = existing[..span_ix].to_vec();
        merged.extend(resolve_spans(elements, (element_ix, start), head));
        Some(merged)
    } else {
        let (element_ix, span_ix) =
            elements
                .iter()
                .enumerate()
                .rev()
                .find_map(|(element_ix, (key, _))| {
                    existing
                        .iter()
                        .position(|span| span.key == *key)
                        .map(|span_ix| (element_ix, span_ix))
                })?;
        let end = existing[span_ix].range.end;
        let mut merged = resolve_spans(elements, head, (element_ix, end));
        merged.extend_from_slice(&existing[span_ix + 1..]);
        Some(merged)
    }
}

/// Replace the resolved spans (drag update). Returns true if they changed.
pub fn update_spans(spans: Vec<Span>) -> bool {
    let mut guard = state().lock().unwrap();
    let Some(sel) = guard.as_mut() else {
        return false;
    };
    if sel.spans == spans {
        return false;
    }
    sel.spans = spans;
    true
}

/// End the drag for `key`'s claim; returns the joined text if non-empty.
pub fn end_drag(key: &str) -> Option<String> {
    let mut guard = state().lock().unwrap();
    let sel = guard.as_mut()?;
    if sel.anchor_key != key || !sel.dragging {
        return None;
    }
    sel.dragging = false;
    if sel.spans.iter().all(|s| s.range.is_empty()) {
        *guard = None;
        return None;
    }
    Some(join_spans(&sel.spans))
}

/// End whichever drag is active, even when virtualization has removed the
/// anchor element (and therefore its frame-scoped mouse-up listener).
pub fn end_active_drag() -> Option<String> {
    let mut guard = state().lock().unwrap();
    let sel = guard.as_mut()?;
    if !sel.dragging {
        return None;
    }
    sel.dragging = false;
    if sel.spans.iter().all(|span| span.range.is_empty()) {
        *guard = None;
        return None;
    }
    Some(join_spans(&sel.spans))
}

/// Clear if `key` owns a settled selection (a mouse-down landed outside the
/// owner; the element the down landed IN claims right after). True if cleared.
pub fn clear_if_owner(key: &str) -> bool {
    let mut guard = state().lock().unwrap();
    if guard
        .as_ref()
        .is_some_and(|s| s.anchor_key == key && !s.dragging)
    {
        *guard = None;
        return true;
    }
    false
}

/// The wash range for `key` this frame (empty ⇒ nothing to paint).
pub fn wash_range(key: &str) -> Option<Range<usize>> {
    let guard = state().lock().unwrap();
    let sel = guard.as_ref()?;
    sel.spans
        .iter()
        .find(|s| s.key == key && !s.range.is_empty())
        .map(|s| s.range.clone())
}

/// The full selected text (Cmd+C), spans joined in document order.
pub fn selected_text() -> Option<String> {
    let guard = state().lock().unwrap();
    let sel = guard.as_ref()?;
    if sel.spans.iter().all(|s| s.range.is_empty()) {
        return None;
    }
    Some(join_spans(&sel.spans))
}

fn join_spans(spans: &[Span]) -> String {
    spans
        .iter()
        .map(|s| &s.text[s.range.clone()])
        .collect::<Vec<_>>()
        .join("\n")
}

/// Word range around `ix` for double-click selection: an alphanumeric/`_`
/// run, or one non-space grapheme, or empty at spaces. Never split combining
/// marks or multi-codepoint emoji from the character they belong to.
pub fn word_range(text: &str, ix: usize) -> Range<usize> {
    use unicode_segmentation::UnicodeSegmentation;

    let ix = ix.min(text.len());
    // Mouse indices and defensive mid-byte offsets both snap to the start of
    // the containing grapheme, not merely to a UTF-8 character boundary.
    let ix = if ix < text.len() {
        text.grapheme_indices(true)
            .take_while(|(start, _)| *start <= ix)
            .last()
            .map_or(0, |(start, _)| start)
    } else {
        ix
    };
    let is_word = |grapheme: &str| {
        grapheme
            .chars()
            .next()
            .is_some_and(|c| c.is_alphanumeric() || c == '_')
    };
    let before = text[..ix].graphemes(true).next_back();
    let at = text[ix..].graphemes(true).next();
    if !at.is_some_and(is_word) && !before.is_some_and(is_word) {
        return match at {
            Some(grapheme) if !grapheme.chars().all(char::is_whitespace) => ix..ix + grapheme.len(),
            _ => ix..ix,
        };
    }
    let start = text[..ix]
        .grapheme_indices(true)
        .rev()
        .take_while(|(_, grapheme)| is_word(grapheme))
        .last()
        .map(|(i, _)| i)
        .unwrap_or(ix);
    let end = text[ix..]
        .grapheme_indices(true)
        .take_while(|(_, grapheme)| is_word(grapheme))
        .last()
        .map(|(i, grapheme)| ix + i + grapheme.len())
        .unwrap_or(ix);
    start..end
}

#[cfg(test)]
mod tests {
    use super::*;

    fn elems<'a>() -> Vec<(&'a str, &'a str)> {
        vec![
            ("p1", "first paragraph"),
            ("p2", "second"),
            ("p3", "third one"),
        ]
    }

    #[test]
    fn selection_owner_is_bound_to_the_active_anchor_and_resets_for_new_gestures() {
        let _state = test_state_lock();
        begin("p1", 0);
        assert_eq!(anchor_owner(), None);
        set_anchor_owner("p1", 7);
        set_anchor_owner("other", 9);
        assert_eq!(anchor_owner(), Some(7));
        update_drag(&elems(), (1, 6));
        end_active_drag();
        set_anchor_owner("p1", 9);
        assert_eq!(anchor_owner(), Some(7));
        begin_with_span("p2", "second", 0..6);
        assert_eq!(anchor_owner(), None);
        set_anchor_owner("p2", 0); // Non-transcript surfaces also have an owner.
        assert_eq!(anchor_owner(), Some(0));
        assert!(!clear_if_owner("p2")); // A live gesture is not a settled selection.
        end_active_drag();
        assert!(clear_if_owner("p2"));
        assert_eq!(anchor_owner(), None);
        begin("p3", 0);
        assert_eq!(anchor_owner(), None);
        end_active_drag();
    }

    #[test]
    fn spans_within_one_element() {
        let spans = resolve_spans(&elems(), (0, 6), (0, 15));
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].key, "p1");
        assert_eq!(&spans[0].text[spans[0].range.clone()], "paragraph");
        // Reversed direction normalizes.
        assert_eq!(resolve_spans(&elems(), (0, 15), (0, 6)), spans);
    }

    #[test]
    fn spans_across_elements_cover_middles_whole() {
        let spans = resolve_spans(&elems(), (0, 6), (2, 5));
        assert_eq!(spans.len(), 3);
        assert_eq!(&spans[0].text[spans[0].range.clone()], "paragraph");
        assert_eq!(&spans[1].text[spans[1].range.clone()], "second");
        assert_eq!(&spans[2].text[spans[2].range.clone()], "third");
        // Reversed drag (bottom-up) resolves identically.
        assert_eq!(resolve_spans(&elems(), (2, 5), (0, 6)), spans);
    }

    #[test]
    fn spans_across_empty_elements_preserve_blank_lines() {
        let elements = [("line-1", "first"), ("line-2", ""), ("line-3", "third")];
        let spans = resolve_spans(&elements, (0, 0), (2, 5));
        assert_eq!(spans.len(), 3);
        assert_eq!(join_spans(&spans), "first\n\nthird");
    }

    #[test]
    fn drag_lifecycle_and_copy_joins() {
        let _state = test_state_lock();
        begin("p1", 6);
        assert_eq!(drag_anchor("p1"), Some(6));
        assert_eq!(drag_anchor("p2"), None);
        let spans = resolve_spans(&elems(), (0, 6), (1, 6));
        assert!(update_spans(spans.clone()));
        assert!(!update_spans(spans)); // unchanged ⇒ no repaint
        assert_eq!(wash_range("p1"), Some(6..15));
        assert_eq!(wash_range("p2"), Some(0..6));
        assert_eq!(wash_range("p3"), None);
        assert_eq!(end_drag("p1").as_deref(), Some("paragraph\nsecond"));
        assert_eq!(selected_text().as_deref(), Some("paragraph\nsecond"));
        // Settled: a down elsewhere clears via the owner's listener.
        assert!(!clear_if_owner("p2"));
        assert!(clear_if_owner("p1"));
        assert_eq!(selected_text(), None);
    }

    #[test]
    fn drag_survives_forward_virtualization() {
        let _state = test_state_lock();
        begin("p1", 6);
        assert!(update_drag(&elems(), (2, 5)));
        let shifted = [("p2", "second"), ("p3", "third one"), ("p4", "fourth")];
        assert!(update_drag(&shifted, (2, 4)));
        assert_eq!(
            selected_text().as_deref(),
            Some("paragraph\nsecond\nthird one\nfour")
        );
        assert_eq!(
            end_active_drag().as_deref(),
            Some("paragraph\nsecond\nthird one\nfour")
        );
        assert_eq!(drag_anchor("p1"), None);
    }

    #[test]
    fn drag_survives_backward_virtualization() {
        let _state = test_state_lock();
        begin("p5", 4);
        let first = [("p3", "third"), ("p4", "fourth"), ("p5", "fifth")];
        assert!(update_drag(&first, (0, 2)));
        let shifted = [("p2", "second"), ("p3", "third"), ("p4", "fourth")];
        assert!(update_drag(&shifted, (0, 3)));
        assert_eq!(selected_text().as_deref(), Some("ond\nthird\nfourth\nfift"));
        assert_eq!(end_drag("p5").as_deref(), Some("ond\nthird\nfourth\nfift"));
    }

    #[test]
    fn empty_click_clears_on_release() {
        let _state = test_state_lock();
        begin("p1", 3);
        assert_eq!(end_drag("p1"), None);
        assert_eq!(selected_text(), None);
    }

    #[test]
    fn double_click_span() {
        let _state = test_state_lock();
        begin_with_span("p1", "hello world", 6..11);
        assert_eq!(wash_range("p1"), Some(6..11));
        assert_eq!(end_drag("p1").as_deref(), Some("world"));
    }

    #[test]
    fn multi_click_span_survives_stationary_and_inside_span_drag_updates() {
        let _state = test_state_lock();
        let elements = [("p1", "hello world")];
        for range in [6..11, 0..11] {
            begin_with_span("p1", "hello world", range.clone());
            for ix in range.start..=range.end {
                assert!(!update_drag(&elements, (0, ix)));
                assert_eq!(wash_range("p1"), Some(range.clone()));
            }
            assert_eq!(end_drag("p1"), Some("hello world"[range].to_string()));
        }
    }

    #[test]
    fn multi_click_drag_extends_from_the_opposite_edge_and_can_reverse() {
        let _state = test_state_lock();
        begin_with_span("p2", "second", 0..6);
        assert!(update_drag(&elems(), (2, 5)));
        assert_eq!(selected_text().as_deref(), Some("second\nthird"));
        assert!(update_drag(&elems(), (0, 6)));
        assert_eq!(selected_text().as_deref(), Some("paragraph\nsecond"));
        assert!(update_drag(&elems(), (1, 3)));
        assert_eq!(end_drag("p2").as_deref(), Some("second"));
    }

    #[test]
    fn ordinary_drag_can_still_contract_to_an_empty_selection() {
        let _state = test_state_lock();
        begin("p1", 6);
        assert!(update_drag(&elems(), (0, 15)));
        assert_eq!(selected_text().as_deref(), Some("paragraph"));
        assert!(update_drag(&elems(), (0, 6)));
        assert_eq!(end_drag("p1"), None);
    }

    #[test]
    fn word_ranges_preserve_grapheme_boundaries_for_mixed_text_and_arbitrary_offsets() {
        use unicode_segmentation::UnicodeSegmentation;

        let pieces = ["", "a", "_", " ", "é", "e\u{301}", "👩‍💻", "👍🏽", "."];
        for left in pieces {
            for middle in pieces {
                for right in pieces {
                    let text = format!("{left}{middle}{right}");
                    let boundaries = text
                        .grapheme_indices(true)
                        .map(|(ix, _)| ix)
                        .chain(std::iter::once(text.len()))
                        .collect::<Vec<_>>();
                    for ix in (0..=text.len() + 3).chain(std::iter::once(usize::MAX)) {
                        let range = word_range(&text, ix);
                        assert!(
                            range.start <= range.end && range.end <= text.len(),
                            "{text:?}: {ix} -> {range:?}"
                        );
                        assert!(
                            text.get(range.clone()).is_some(),
                            "range must be UTF-8 safe"
                        );
                        assert!(
                            boundaries.contains(&range.start) && boundaries.contains(&range.end),
                            "selection split a grapheme in {text:?}: {ix} -> {range:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn word_ranges_keep_decomposed_letters_and_marks_together() {
        for word in ["cafe\u{301}", "nai\u{308}ve", "foo_e\u{301}_bar"] {
            let text = format!("[{word}]");
            for ix in 1..1 + word.len() {
                assert_eq!(
                    &text[word_range(&text, ix)],
                    word,
                    "word={word:?}, byte={ix}"
                );
            }
        }
    }

    #[test]
    fn word_ranges_select_complete_emoji_graphemes() {
        for emoji in ["👩‍💻", "👍🏽", "🇸🇬", "✈️"] {
            let text = format!(" {emoji} ");
            for ix in 1..1 + emoji.len() {
                assert_eq!(
                    &text[word_range(&text, ix)],
                    emoji,
                    "emoji={emoji:?}, byte={ix}"
                );
            }
        }
    }

    #[test]
    fn word_ranges() {
        let t = "let foo_bar = 12;";
        assert_eq!(word_range(t, 5), 4..11); // inside foo_bar
        assert_eq!(word_range(t, 4), 4..11); // at word start
        assert_eq!(word_range(t, 11), 4..11); // at word end
        assert_eq!(word_range(t, 15), 14..16); // inside 12
        assert_eq!(&t[word_range(t, 12)], "="); // lone symbol
        assert_eq!(word_range(t, 3), 0..3); // boundary after "let"
        // Unicode-safe (mid-char byte offsets snap down).
        let u = "héllo wörld";
        assert_eq!(&u[word_range(u, 2)], "héllo");
    }
}
