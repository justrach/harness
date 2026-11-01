//! Write: the composer's draft on a full page. This is the page's styler, a
//! pure function from the draft to the stretches drawn as headings, lists,
//! bold, code and so on. Nothing is hidden: markdown syntax stays in the text
//! and is only drawn faint. The rules mirror the iOS page
//! (`apps/ios/Harness/Composer/WriteSheet.swift`, `WriteMarkdown.spans`).

use std::ops::Range;

/// How one stretch of the draft is drawn on the Write page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteStyle {
    /// A `#`, `##` or `###` line (deeper levels draw as 3).
    Heading(u8),
    /// A `- `, `* ` or `1. ` line. `indent` is the byte length of everything
    /// up to the item's text, which wrapped rows hang under.
    ListItem {
        indent: usize,
    },
    Quote,
    /// A line inside a ``` fence.
    CodeBlock,
    Bold,
    Italic,
    Code,
    /// Markdown syntax itself (`#`, `**`, `` ` ``, `- `, `> `): drawn faint,
    /// never hidden.
    Marker,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteSpan {
    /// Byte range into the draft.
    pub range: Range<usize>,
    pub style: WriteStyle,
}

/// Above this the page draws the draft plain, like the composer's own
/// markdown faces.
const MAX_STYLED_BYTES: usize = 128 * 1024;

/// The styled stretches of `text`: line styles first, then inline styles,
/// then markers, which is the order they are drawn in (a later span's colour
/// wins).
pub fn spans(text: &str) -> Vec<WriteSpan> {
    if text.len() > MAX_STYLED_BYTES {
        return Vec::new();
    }
    let mut lines = Vec::new();
    let mut inline = Vec::new();
    let mut markers = Vec::new();
    let mut in_fence = false;
    let mut start = 0;
    for raw in text.split('\n') {
        let line_start = start;
        start += raw.len() + 1;
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let line_range = line_start..line_start + line.len();
        if is_fence(line) {
            in_fence = !in_fence;
            markers.push(span(line_range, WriteStyle::Marker));
            continue;
        }
        if in_fence {
            if !line.is_empty() {
                lines.push(span(line_range, WriteStyle::CodeBlock));
            }
            continue;
        }
        let mut rest = 0;
        if let Some((hashes, end)) = heading_prefix(line) {
            lines.push(span(
                line_range.clone(),
                WriteStyle::Heading(hashes.min(3) as u8),
            ));
            markers.push(span(line_start..line_start + end, WriteStyle::Marker));
            rest = end;
        } else if let Some(end) = quote_prefix(line) {
            lines.push(span(line_range.clone(), WriteStyle::Quote));
            markers.push(span(line_start..line_start + end, WriteStyle::Marker));
            rest = end;
        } else if let Some((bullet, end)) = list_prefix(line) {
            lines.push(span(
                line_range.clone(),
                WriteStyle::ListItem { indent: end },
            ));
            markers.push(span(
                line_start + bullet.start..line_start + bullet.end,
                WriteStyle::Marker,
            ));
            rest = end;
        }
        style_inline(line, rest, line_start, &mut inline, &mut markers);
    }
    lines.extend(inline);
    lines.extend(markers);
    lines
}

/// Words a reader would count: runs between spaces holding a letter or a
/// digit, so bare markers (`#`, `-`, `**`) don't add to it.
pub fn word_count(text: &str) -> usize {
    text.split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .count()
}

pub fn word_count_label(count: usize) -> String {
    if count == 1 {
        "1 word".into()
    } else {
        format!("{count} words")
    }
}

fn span(range: Range<usize>, style: WriteStyle) -> WriteSpan {
    WriteSpan { range, style }
}

/// Up to three spaces or tabs, as CommonMark allows before block syntax.
fn small_indent(line: &str) -> usize {
    line.bytes()
        .take(3)
        .take_while(|byte| matches!(byte, b' ' | b'\t'))
        .count()
}

/// `^[ \t]{0,3}(```|~~~)`, the rest of the line being the info string.
fn is_fence(line: &str) -> bool {
    let rest = &line[small_indent(line)..];
    rest.starts_with("```") || rest.starts_with("~~~")
}

/// `^(#{1,6})[ \t]+`: the number of hashes and the end of the marker.
fn heading_prefix(line: &str) -> Option<(usize, usize)> {
    let hashes = line.bytes().take_while(|byte| *byte == b'#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let spaces = line[hashes..]
        .bytes()
        .take_while(|byte| matches!(byte, b' ' | b'\t'))
        .count();
    (spaces > 0).then_some((hashes, hashes + spaces))
}

/// `^[ \t]{0,3}>[ \t]?`: the end of the marker.
fn quote_prefix(line: &str) -> Option<usize> {
    let indent = small_indent(line);
    if line.as_bytes().get(indent) != Some(&b'>') {
        return None;
    }
    let end = indent + 1;
    Some(end + usize::from(matches!(line.as_bytes().get(end), Some(b' ' | b'\t'))))
}

/// `^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+`: the bullet's range and the end of
/// the whole marker.
fn list_prefix(line: &str) -> Option<(Range<usize>, usize)> {
    let bytes = line.as_bytes();
    let indent = bytes
        .iter()
        .take_while(|byte| matches!(byte, b' ' | b'\t'))
        .count();
    let bullet_end = match bytes.get(indent)? {
        b'-' | b'*' | b'+' => indent + 1,
        _ => {
            let digits = bytes[indent..]
                .iter()
                .take_while(|byte| byte.is_ascii_digit())
                .count();
            if !(1..=9).contains(&digits)
                || !matches!(bytes.get(indent + digits), Some(b'.' | b')'))
            {
                return None;
            }
            indent + digits + 1
        }
    };
    let spaces = bytes[bullet_end..]
        .iter()
        .take_while(|byte| matches!(byte, b' ' | b'\t'))
        .count();
    (spaces > 0).then_some((indent..bullet_end, bullet_end + spaces))
}

/// Code, then bold, then italic: a later kind never claims text an earlier
/// one took, so nothing inside backticks is bold.
fn style_inline(
    line: &str,
    from: usize,
    offset: usize,
    styles: &mut Vec<WriteSpan>,
    markers: &mut Vec<WriteSpan>,
) {
    let rest = &line[from..];
    if rest.is_empty() {
        return;
    }
    let mut taken: Vec<Range<usize>> = Vec::new();
    let finders: [(fn(&str) -> Vec<Range<usize>>, WriteStyle, usize); 3] = [
        (code_matches, WriteStyle::Code, 1),
        (bold_matches, WriteStyle::Bold, 2),
        (italic_matches, WriteStyle::Italic, 1),
    ];
    for (find, style, width) in finders {
        for found in find(rest) {
            if taken
                .iter()
                .any(|t| t.start < found.end && found.start < t.end)
            {
                continue;
            }
            taken.push(found.clone());
            let at = offset + from;
            styles.push(span(
                at + found.start + width..at + found.end - width,
                style,
            ));
            markers.push(span(
                at + found.start..at + found.start + width,
                WriteStyle::Marker,
            ));
            markers.push(span(
                at + found.end - width..at + found.end,
                WriteStyle::Marker,
            ));
        }
    }
}

/// `` `[^`]+` ``, leftmost first and non-overlapping.
fn code_matches(text: &str) -> Vec<Range<usize>> {
    let bytes = text.as_bytes();
    let mut found = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'`'
            && let Some(close) = bytes[at + 1..].iter().position(|byte| *byte == b'`')
            && close > 0
        {
            let end = at + 1 + close + 1;
            found.push(at..end);
            at = end;
        } else {
            at += 1;
        }
    }
    found
}

/// `\*\*(?=\S)(.+?)(?<=\S)\*\*`.
fn bold_matches(text: &str) -> Vec<Range<usize>> {
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(open) = text[at..].find("**").map(|i| at + i) {
        let content = open + 2;
        let close = text[content..]
            .chars()
            .next()
            .filter(|c| !c.is_whitespace())
            .and_then(|_| {
                (content + 1..=text.len().saturating_sub(2)).find(|&close| {
                    text.is_char_boundary(close)
                        && text[close..].starts_with("**")
                        && text[..close]
                            .chars()
                            .next_back()
                            .is_some_and(|c| !c.is_whitespace())
                })
            });
        match close {
            Some(close) => {
                found.push(open..close + 2);
                at = close + 2;
            }
            None => at = open + 1,
        }
    }
    found
}

/// `(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])`, where the edges of
/// `text` count as neither.
fn italic_matches(text: &str) -> Vec<Range<usize>> {
    let word = |c: char| c.is_alphanumeric() || c == '_';
    let before = |at: usize| text[..at].chars().next_back();
    let after = |at: usize| text[at + 1..].chars().next();
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(open) = text[at..].find('*').map(|i| at + i) {
        let opens = !before(open).is_some_and(|c| c == '*' || word(c))
            && after(open).is_some_and(|c| !c.is_whitespace() && c != '*');
        let close = opens
            .then(|| {
                (open + 2..text.len()).find(|&close| {
                    text.as_bytes()[close] == b'*'
                        && before(close).is_some_and(|c| !c.is_whitespace() && c != '*')
                        && !after(close).is_some_and(|c| c == '*' || word(c))
                })
            })
            .flatten();
        match close {
            Some(close) => {
                found.push(open..close + 1);
                at = close + 1;
            }
            None => at = open + 1,
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The text of every span with `style`, in order.
    fn styled<'a>(source: &'a str, style: WriteStyle) -> Vec<&'a str> {
        spans(source)
            .into_iter()
            .filter(|span| span.style == style)
            .map(|span| &source[span.range])
            .collect()
    }

    fn markers(source: &str) -> Vec<&str> {
        styled(source, WriteStyle::Marker)
    }

    #[test]
    fn headings_style_the_whole_line_and_fade_the_hashes() {
        let source = "# Renderer notes\nbody\n## Keep it short\n### Third\n#### Deeper";
        assert_eq!(styled(source, WriteStyle::Heading(1)), ["# Renderer notes"]);
        assert_eq!(styled(source, WriteStyle::Heading(2)), ["## Keep it short"]);
        assert_eq!(
            styled(source, WriteStyle::Heading(3)),
            ["### Third", "#### Deeper"]
        );
        assert_eq!(markers(source), ["# ", "## ", "### ", "#### "]);
    }

    #[test]
    fn a_hash_without_a_space_is_not_a_heading() {
        assert!(spans("#hashtag and #1").is_empty());
        assert!(spans("####### seven").is_empty());
    }

    #[test]
    fn bold_italic_and_code_keep_their_markers_faint() {
        let source = "Cap it at `30s`, **never** re-encode, *maybe* later";
        assert_eq!(styled(source, WriteStyle::Code), ["30s"]);
        assert_eq!(styled(source, WriteStyle::Bold), ["never"]);
        assert_eq!(styled(source, WriteStyle::Italic), ["maybe"]);
        assert_eq!(markers(source), ["`", "`", "**", "**", "*", "*"]);
    }

    #[test]
    fn nothing_inside_code_is_bold() {
        let source = "run `a **b** c` now";
        assert_eq!(styled(source, WriteStyle::Code), ["a **b** c"]);
        assert!(styled(source, WriteStyle::Bold).is_empty());
    }

    #[test]
    fn list_lines_hang_under_their_text() {
        let source = "- first\n* second\n12. third\n  - nested\n-not a list";
        let items: Vec<(&str, usize)> = spans(source)
            .into_iter()
            .filter_map(|span| match span.style {
                WriteStyle::ListItem { indent } => Some((&source[span.range], indent)),
                _ => None,
            })
            .collect();
        assert_eq!(
            items,
            [
                ("- first", 2),
                ("* second", 2),
                ("12. third", 4),
                ("  - nested", 4)
            ]
        );
        // Only the bullet is faint, and a `* ` bullet is not an italic opener.
        assert_eq!(markers(source), ["-", "*", "12.", "-"]);
        assert!(styled(source, WriteStyle::Italic).is_empty());
    }

    #[test]
    fn quotes_and_fenced_code() {
        let source = "> quoted **line**\n```\nlet x = 1\n```\nafter";
        assert_eq!(styled(source, WriteStyle::Quote), ["> quoted **line**"]);
        assert_eq!(styled(source, WriteStyle::Bold), ["line"]);
        assert_eq!(styled(source, WriteStyle::CodeBlock), ["let x = 1"]);
        assert_eq!(markers(source), ["> ", "**", "**", "```", "```"]);
    }

    #[test]
    fn ranges_are_byte_offsets_into_the_draft() {
        let source = "👋 **hi** and é *ça*";
        assert_eq!(styled(source, WriteStyle::Bold), ["hi"]);
        assert_eq!(styled(source, WriteStyle::Italic), ["ça"]);
    }

    #[test]
    fn crlf_lines_style_without_the_carriage_return() {
        let source = "# Title\r\nbody";
        assert_eq!(styled(source, WriteStyle::Heading(1)), ["# Title"]);
    }

    #[test]
    fn unclosed_markers_stay_plain() {
        for source in ["**open", "a * b * c", "`tick", "** spaced **"] {
            assert!(spans(source).is_empty(), "{source:?}");
        }
    }

    #[test]
    fn words_count_what_a_reader_would_count() {
        assert_eq!(word_count(""), 0);
        assert_eq!(word_count("# Title\n\n- one **two**\n- `3`"), 4);
        assert_eq!(word_count_label(1), "1 word");
        assert_eq!(word_count_label(214), "214 words");
    }
}
