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
    /// Element key (`{row_key}:{element ix}`, or [`inline_fragment_key`]).
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
    /// Byte offset of the anchor within its element.
    anchor_ix: usize,
    /// The immediate word/paragraph selected by a multi-click. A paragraph
    /// may span several inline fragments; moving inside must preserve it all.
    initial_spans: Option<Vec<Span>>,
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

/// Reserved suffix separating an inline fragment's paragraph key and index.
const INLINE_FRAGMENT_SUFFIX: &str = "\u{1f}inline-fragment:";

/// Make a unique selection key for one fragment of a logical paragraph.
///
/// Use the same document-unique `group` for every prose and equation fragment
/// in that paragraph, and a distinct `index` for each fragment. Consecutive
/// selected fragments in the same group copy without an inserted newline;
/// paragraph boundaries and ordinary element keys retain their newlines.
/// `group` is opaque and may itself contain the reserved suffix.
pub fn inline_fragment_key(group: &str, index: usize) -> String {
    format!("{group}{INLINE_FRAGMENT_SUFFIX}{index}")
}

fn inline_fragment_group(key: &str) -> Option<&str> {
    let (group, index) = key.rsplit_once(INLINE_FRAGMENT_SUFFIX)?;
    // Only recognize complete keys made by the API, not lookalike suffixes.
    let parsed = index.parse::<usize>().ok()?;
    (index == parsed.to_string()).then_some(group)
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
        anchor_ix: ix,
        initial_spans: None,
        dragging: true,
        forward: None,
        spans: Vec::new(),
    });
}

/// Begin with an immediate span (double/triple click inside one element).
pub fn begin_with_span(key: &str, text: &str, range: Range<usize>) {
    begin_with_spans(
        key,
        vec![Span {
            key: key.to_string(),
            range,
            text: text.to_string(),
        }],
    );
}

fn begin_with_spans(key: &str, spans: Vec<Span>) {
    // At a styled word boundary the selected word may end in the preceding
    // fragment; the clicked fragment still owns the mouse listeners.
    let anchor_ix = spans
        .iter()
        .find(|span| span.key == key)
        .map_or(0, |span| span.range.start);
    *state().lock().unwrap() = Some(MdSelection {
        anchor_key: key.to_string(),
        anchor_ix,
        initial_spans: Some(spans.clone()),
        dragging: true,
        forward: None,
        spans,
    });
}

/// Triple-click selects the logical paragraph, not just the painted fragment.
/// `elements` must already be restricted to the same selection owner/scope.
/// Ordinary elements (including code lines) retain their single-element rule.
pub fn begin_paragraph(key: &str, elements: &[(&str, &str)]) -> bool {
    let Some((start, end)) = paragraph_bounds(key, elements) else {
        return false;
    };
    begin_with_spans(
        key,
        resolve_spans(elements, (start, 0), (end, elements[end].1.len())),
    );
    true
}

/// Double-click a prose word across adjacent styled fragments. Equation
/// delimiters in the copy source act as word boundaries; equations themselves
/// use atomic selection instead of this function.
pub fn begin_word(key: &str, ix: usize, elements: &[(&str, &str)]) -> bool {
    let Some((start, end)) = paragraph_bounds(key, elements) else {
        return false;
    };
    let mut joined = String::new();
    let mut offset = 0;
    for (candidate, text) in &elements[start..=end] {
        if *candidate == key {
            offset = joined.len() + ix.min(text.len());
        }
        joined.push_str(text);
    }
    let range = word_range(&joined, offset);
    let mut offset = 0;
    let mut spans = Vec::new();
    for (candidate, text) in &elements[start..=end] {
        let from = range.start.saturating_sub(offset).min(text.len());
        let to = range.end.saturating_sub(offset).min(text.len());
        if from < to || *candidate == key && range.is_empty() {
            spans.push(Span {
                key: (*candidate).to_owned(),
                range: from..to,
                text: (*text).to_owned(),
            });
        }
        offset += text.len();
    }
    begin_with_spans(key, spans);
    true
}

fn paragraph_bounds(key: &str, elements: &[(&str, &str)]) -> Option<(usize, usize)> {
    let index = elements
        .iter()
        .position(|(candidate, _)| *candidate == key)?;
    let group = inline_fragment_group(key);
    let (mut start, mut end) = (index, index);
    if group.is_some() {
        while start > 0 && inline_fragment_group(elements[start - 1].0) == group {
            start -= 1;
        }
        while end + 1 < elements.len() && inline_fragment_group(elements[end + 1].0) == group {
            end += 1;
        }
    }
    Some((start, end))
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
    let initial = selection
        .initial_spans
        .as_ref()
        .and_then(|spans| resolve_initial_drag(spans, elements, head));
    let spans = if let Some((spans, forward)) = initial {
        selection.forward = Some(forward);
        spans
    } else if let Some(anchor_ei) = elements
        .iter()
        .position(|(key, _)| *key == selection.anchor_key)
    {
        let anchor = (anchor_ei, selection.anchor_ix);
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

/// Extend from the opposite edge of the original multi-click selection, or
/// keep the whole initial selection while the pointer is inside it. Resolve
/// against frozen spans so partially virtualized paragraphs retain their text.
fn resolve_initial_drag(
    initial: &[Span],
    elements: &[(&str, &str)],
    head: (usize, usize),
) -> Option<(Vec<Span>, bool)> {
    let (head_key, _) = elements.get(head.0)?;
    let forward = if let Some(span) = initial.iter().find(|span| span.key == *head_key) {
        if span.range.contains(&head.1) || head.1 == span.range.end {
            return Some((initial.to_vec(), true));
        }
        head.1 > span.range.end
    } else {
        let pivot = elements
            .iter()
            .position(|(key, _)| initial.iter().any(|span| span.key == *key))?;
        head.0 > pivot
    };
    Some((
        extend_virtualized_drag(initial, elements, head, forward)?,
        forward,
    ))
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

/// Invalidate a surface's snapshotted source, including an in-flight drag.
/// Unlike an outside click, a buffer replacement must not retain old text.
pub(crate) fn cancel_surface(prefix: &str) -> bool {
    let mut guard = state().lock().unwrap();
    if guard
        .as_ref()
        .is_some_and(|selection| selection.anchor_key.starts_with(prefix))
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
    let mut joined = String::new();
    let mut previous_group = None;
    for (index, span) in spans.iter().enumerate() {
        let group = inline_fragment_group(&span.key);
        if index > 0 && (group.is_none() || group != previous_group) {
            joined.push('\n');
        }
        joined.push_str(&span.text[span.range.clone()]);
        previous_group = group;
    }
    joined
}

/// Word range around `ix` for double-click selection: an alphanumeric/`_`
/// run, or the single non-space char under the cursor, or empty at spaces.
pub fn word_range(text: &str, ix: usize) -> Range<usize> {
    let mut ix = ix.min(text.len());
    // Snap into a char boundary (mouse indices should already be on one;
    // defensive against mid-char byte offsets).
    while ix > 0 && !text.is_char_boundary(ix) {
        ix -= 1;
    }
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    let before = text[..ix].chars().next_back();
    let at = text[ix..].chars().next();
    // Off a word boundary entirely: select the single char (or nothing).
    if !at.is_some_and(is_word) && !before.is_some_and(is_word) {
        return match at {
            Some(c) if !c.is_whitespace() => ix..ix + c.len_utf8(),
            _ => ix..ix,
        };
    }
    let start = text[..ix]
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_word(*c))
        .last()
        .map(|(i, _)| i)
        .unwrap_or(ix);
    let end = text[ix..]
        .char_indices()
        .take_while(|(_, c)| is_word(*c))
        .last()
        .map(|(i, c)| ix + i + c.len_utf8())
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
    fn inline_prose_math_and_prose_copy_as_one_paragraph() {
        let keys = [
            inline_fragment_key("row:p1", 0),
            inline_fragment_key("row:p1", 1),
            inline_fragment_key("row:p1", 2),
        ];
        let elements = [
            (keys[0].as_str(), "The ratio is "),
            (keys[1].as_str(), r"$\frac{a}{b}$"),
            (keys[2].as_str(), " today."),
        ];
        let spans = resolve_spans(&elements, (0, 0), (2, elements[2].1.len()));
        assert_eq!(join_spans(&spans), r"The ratio is $\frac{a}{b}$ today.");
    }

    #[test]
    fn inline_fragments_keep_newlines_between_paragraphs_and_normal_elements() {
        let keys = [
            inline_fragment_key("row:p1", 0),
            inline_fragment_key("row:p1", 1),
            inline_fragment_key("row:p2", 0),
            inline_fragment_key("row:p2", 1),
        ];
        let elements = [
            (keys[0].as_str(), "First "),
            (keys[1].as_str(), "$x$."),
            (keys[2].as_str(), "Next "),
            (keys[3].as_str(), "$y$."),
            ("row:p3", "Ordinary paragraph."),
        ];
        let spans = resolve_spans(&elements, (0, 0), (4, elements[4].1.len()));
        assert_eq!(
            join_spans(&spans),
            "First $x$.\nNext $y$.\nOrdinary paragraph."
        );
    }

    #[test]
    fn inline_fragments_preserve_unicode_partial_ranges_in_both_directions() {
        let keys = [
            inline_fragment_key("row:unicode", 0),
            inline_fragment_key("row:unicode", 1),
            inline_fragment_key("row:unicode", 2),
        ];
        let elements = [
            (keys[0].as_str(), "前置 café "),
            (keys[1].as_str(), "$α²$"),
            (keys[2].as_str(), " naïve 終了"),
        ];
        let start = (0, "前置 ".len());
        let end = (2, " naïve".len());
        let spans = resolve_spans(&elements, start, end);
        assert_eq!(join_spans(&spans), "café $α²$ naïve");
        assert_eq!(resolve_spans(&elements, end, start), spans);
    }

    #[test]
    fn inline_fragment_keys_are_unambiguous_and_reject_malformed_suffixes() {
        let group = format!("row{INLINE_FRAGMENT_SUFFIX}3");
        assert_eq!(
            inline_fragment_group(&inline_fragment_key(&group, usize::MAX)),
            Some(group.as_str())
        );
        assert_ne!(inline_fragment_key("row", 1), inline_fragment_key("row", 2));
        for suffix in ["", "-1", "+1", "01", "1:extra", "184467440737095516160"] {
            let key = format!("row{INLINE_FRAGMENT_SUFFIX}{suffix}");
            assert_eq!(inline_fragment_group(&key), None);
            let elements = [(key.as_str(), "first"), (key.as_str(), "second")];
            let spans = resolve_spans(&elements, (0, 0), (1, 6));
            assert_eq!(join_spans(&spans), "first\nsecond");
        }
    }

    #[test]
    fn ordinary_code_lines_keep_newlines_and_unicode_partial_ranges() {
        let elements = [
            ("code:0", "let café = 1;"),
            ("code:1", ""),
            ("code:2", "print(café);"),
        ];
        let spans = resolve_spans(&elements, (0, 4), (2, "print(café)".len()));
        assert_eq!(join_spans(&spans), "café = 1;\n\nprint(café)");
    }

    #[test]
    fn invalidating_surface_cancels_only_its_active_or_settled_selection() {
        let _state = test_state_lock();
        for dragging in [true, false] {
            for key in [
                "md-preview-1|row:0".to_owned(),
                inline_fragment_key("md-preview-1|row:1", 0),
            ] {
                begin(&key, 0);
                update_spans(vec![Span {
                    key: key.clone(),
                    range: 0..5,
                    text: "$x_i$".into(),
                }]);
                if !dragging {
                    end_active_drag();
                } else {
                    assert!(
                        !clear_if_owner(&key),
                        "ordinary outside-click clearing must still preserve an active drag"
                    );
                }
                assert!(!cancel_surface("md-preview-10|"));
                assert_eq!(is_dragging(), dragging);
                assert_eq!(selected_text().as_deref(), Some("$x_i$"));
                assert!(cancel_surface("md-preview-1|"));
                assert!(!is_dragging());
                assert!(selected_text().is_none());
                assert!(!cancel_surface("md-preview-1|"));
            }
        }
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
    fn paragraph_multi_click_extends_reverses_and_preserves_virtualized_fragments() {
        let _state = test_state_lock();
        let keys = [
            inline_fragment_key("row:p", 0),
            inline_fragment_key("row:p", 1),
            inline_fragment_key("row:p", 2),
        ];
        let elements = [
            ("previous", "Previous"),
            (keys[0].as_str(), "Before "),
            (keys[1].as_str(), "$x$"),
            (keys[2].as_str(), " after."),
            ("next", "Next"),
        ];
        assert!(begin_paragraph(&keys[1], &elements));
        assert_eq!(selected_text().as_deref(), Some("Before $x$ after."));
        for head in [(1, 0), (2, 1), (3, 7)] {
            assert!(!update_drag(&elements, head));
        }
        assert!(update_drag(&elements, (4, 4)));
        assert_eq!(selected_text().as_deref(), Some("Before $x$ after.\nNext"));
        assert!(update_drag(&elements, (0, 0)));
        assert_eq!(
            selected_text().as_deref(),
            Some("Previous\nBefore $x$ after.")
        );
        assert!(update_drag(&elements, (2, 1)));
        assert_eq!(selected_text().as_deref(), Some("Before $x$ after."));
        // Only the end of the original paragraph remains painted. Entering it
        // keeps the full initial selection, including the off-screen prefix.
        let shifted = [elements[3], elements[4], ("last", "Last")];
        assert!(!update_drag(&shifted, (0, 2)));
        assert!(update_drag(&shifted, (2, 4)));
        assert_eq!(
            selected_text().as_deref(),
            Some("Before $x$ after.\nNext\nLast")
        );
        assert_eq!(
            end_drag(&keys[1]).as_deref(),
            Some("Before $x$ after.\nNext\nLast")
        );
        assert!(clear_if_owner(&keys[1]));
    }

    #[test]
    fn paragraph_multi_click_keeps_ordinary_elements_and_group_boundaries_separate() {
        let _state = test_state_lock();
        let first = inline_fragment_key("first", 0);
        let second = inline_fragment_key("second", 0);
        let elements = [
            (first.as_str(), "$x$"),
            (second.as_str(), "$y$"),
            ("code", "line"),
        ];
        for (key, expected) in elements {
            assert!(begin_paragraph(key, &elements));
            assert_eq!(end_drag(key).as_deref(), Some(expected));
            assert!(clear_if_owner(key));
        }
        assert!(!begin_paragraph("missing", &elements));
        assert_eq!(selected_text(), None);
    }

    #[test]
    fn word_multi_click_crosses_styles_but_not_equations_or_paragraphs() {
        let _state = test_state_lock();
        let keys: Vec<_> = (0..6)
            .map(|index| inline_fragment_key("p", index))
            .collect();
        let other = inline_fragment_key("next", 0);
        let elements = [
            (keys[0].as_str(), "na"),
            (keys[1].as_str(), "ïve "),
            (keys[2].as_str(), "$x$"),
            (keys[3].as_str(), "co"),
            (keys[4].as_str(), "ordi"),
            (keys[5].as_str(), "nate"),
            (other.as_str(), "next"),
        ];
        for (index, expected) in [
            (0, "naïve"),
            (1, "naïve"),
            (3, "coordinate"),
            (4, "coordinate"),
            (5, "coordinate"),
            (6, "next"),
        ] {
            let key = elements[index].0;
            assert!(begin_word(key, 1, &elements));
            assert_eq!(selected_text().as_deref(), Some(expected));
            assert!(!update_drag(&elements, (index, 1)));
            assert_eq!(end_drag(key).as_deref(), Some(expected));
            assert!(clear_if_owner(key));
        }
    }

    #[test]
    fn word_multi_click_boundary_keeps_clicked_fragment_ownership() {
        let _state = test_state_lock();
        let keys = [inline_fragment_key("p", 0), inline_fragment_key("p", 1)];
        let elements = [(keys[0].as_str(), "word"), (keys[1].as_str(), " ")];
        assert!(begin_word(&keys[1], 0, &elements));
        assert_eq!(drag_anchor(&keys[1]), Some(0));
        assert_eq!(selected_text().as_deref(), Some("word"));
        assert!(!update_drag(&elements, (1, 0)));
        assert_eq!(end_drag(&keys[1]).as_deref(), Some("word"));
        assert!(clear_if_owner(&keys[1]));
        assert!(begin_word(&keys[1], 1, &elements));
        assert_eq!(end_drag(&keys[1]), None);
        assert!(!begin_word("missing", 0, &elements));
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
