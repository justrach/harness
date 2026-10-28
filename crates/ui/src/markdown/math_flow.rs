//! Inline equation flow. Only paragraphs containing math use this path;
//! ordinary Markdown retains the shaped, cached text renderer.
use gpui::{AnyElement, IntoElement, ParentElement, SharedString, Styled, div, prelude::*, px};

use super::{
    math_layout,
    parser::{InlineRun, TableAlign},
    render::{self, RenderOptions},
};
use crate::theme::Theme;

struct Fragment {
    runs: Vec<InlineRun>,
    equation: Option<math_layout::Equation>,
    display: bool,
    copy: Option<String>,
}

/// Split at word boundaries without losing whitespace or surrounding Markdown
/// styling. Adjacent equation/punctuation fragments stay in the same word.
#[cfg(test)]
fn fragments(runs: &[InlineRun], size: f32, theme: &Theme) -> Vec<Vec<Fragment>> {
    fragments_styled(runs, size, theme, false)
}

fn breakable_space(c: char) -> bool {
    c.is_whitespace() && !matches!(c, '\u{00a0}' | '\u{202f}' | '\u{2007}')
}

fn fragments_styled(
    runs: &[InlineRun],
    size: f32,
    theme: &Theme,
    bold_default: bool,
) -> Vec<Vec<Fragment>> {
    // Find breaks across styles, rather than treating every styled run as a
    // separate string. A letter stands in for each atomic equation, keeping
    // surrounding Latin prose and punctuation attached as before.
    let logical: String = runs
        .iter()
        .map(|run| {
            if run.style.math.is_some() {
                "M"
            } else {
                &run.text
            }
        })
        .collect();
    let mut breaks = unicode_linebreak::linebreaks(&logical)
        .map(|(offset, _)| offset)
        .peekable();
    let mut offset = 0;
    let mut words = Vec::new();
    let mut word = Vec::new();
    for run in runs {
        if let Some(math) = &run.style.math {
            if math.display && !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
            let delimiter = if math.display { "$$" } else { "$" };
            let source = format!("{delimiter}{}{delimiter}", math.source);
            let styled_source = if bold_default || run.style.bold {
                format!(r"\boldsymbol{{{}}}", math.source)
            } else {
                math.source.clone()
            };
            let equation = math_layout::render(&styled_source, math.display, size, theme.text).ok();
            let mut style = run.style.clone();
            style.math = None;
            word.push(Fragment {
                runs: vec![InlineRun {
                    text: source.clone(),
                    style,
                }],
                equation,
                display: math.display,
                copy: Some(if math.display {
                    format!("\n{source}\n")
                } else {
                    source
                }),
            });
            offset += 1;
            let boundary = breaks.peek() == Some(&offset);
            if boundary {
                breaks.next();
            }
            if math.display || boundary {
                words.push(std::mem::take(&mut word));
            }
            continue;
        }
        let end = offset + run.text.len();
        let mut start = offset;
        // Keep semantic tokens intact for link/reference/code presentation;
        // these may contain punctuation that normally permits Unicode breaks.
        let semantic = run.style.link.is_some() || run.style.code || run.style.content_reference;
        let mut pieces = Vec::new();
        while breaks.peek().is_some_and(|boundary| *boundary <= end) {
            let boundary = breaks.next().unwrap();
            let local = boundary - offset;
            if !semantic || local == run.text.len() || run.text[..local].ends_with(breakable_space)
            {
                pieces.push((&run.text[start - offset..local], true));
                start = boundary;
            }
        }
        if start < end {
            pieces.push((&run.text[start - offset..], false));
        }
        offset = end;
        for (text, boundary) in pieces {
            if text.is_empty() {
                continue;
            }
            // Display math already supplies block separation; the parser's
            // adjacent soft-break spaces must not become empty flow rows.
            if word.is_empty()
                && text.chars().all(breakable_space)
                && words
                    .last()
                    .is_some_and(|w: &Vec<Fragment>| w.iter().any(|f| f.display))
            {
                continue;
            }
            let prose = InlineRun {
                text: text.to_owned(),
                style: run.style.clone(),
            };
            // Shape a joined word/grapheme as one text element, while retaining
            // all runs for styling, links, and source-preserving selection.
            if let Some(last) = word.last_mut().filter(|last| last.copy.is_none()) {
                last.runs.push(prose);
            } else {
                word.push(Fragment {
                    runs: vec![prose],
                    equation: None,
                    display: false,
                    copy: None,
                });
            }
            if boundary {
                words.push(std::mem::take(&mut word));
            }
        }
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

fn flatten_prose(runs: &[InlineRun], theme: &Theme, bold: bool) -> render::FlatText {
    use unicode_segmentation::UnicodeSegmentation;

    let mut flat = render::flatten_runs(runs, theme, bold);
    // Platform shapers deliberately break ligatures between styled runs. A
    // style boundary inside a grapheme must therefore move to its end: the
    // leading codepoint owns the cluster's paint style. Source/link/code byte
    // ranges stay unchanged, and styles resume at the next complete grapheme.
    let mut boundaries = flat
        .text
        .grapheme_indices(true)
        .map(|(index, _)| index)
        .peekable();
    let mut source_end = 0;
    let mut shaped_end = 0;
    for run in &mut flat.runs {
        source_end += run.len;
        while boundaries.peek().is_some_and(|index| *index < source_end) {
            boundaries.next();
        }
        let end = boundaries.peek().copied().unwrap_or(flat.text.len());
        run.len = end - shaped_end;
        shaped_end = end;
    }
    flat.runs.retain(|run| run.len > 0);
    flat
}

fn flow_row(align: TableAlign) -> gpui::Div {
    let row = div().flex().flex_wrap().min_w_0().w_full();
    match align {
        TableAlign::Left => row,
        TableAlign::Center => row.justify_center(),
        TableAlign::Right => row.justify_end(),
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn render_aligned(
    runs: &[InlineRun],
    size: f32,
    line_height: f32,
    bold: bool,
    ix: usize,
    opts: &RenderOptions,
    theme: &Theme,
    window: &gpui::Window,
    align: TableAlign,
) -> AnyElement {
    let scale = f32::from(window.rem_size()) / 16.0;
    let size_px = size * scale;
    let line_height_px = line_height * scale;
    let words = fragments_styled(runs, size_px, theme, bold);
    // A shared baseline across a wrapped flow gives fractions/scripts their
    // actual ascent and depth, rather than centering an image in a text row.
    let metrics = render::flatten_runs(
        &[InlineRun {
            text: "M".into(),
            style: Default::default(),
        }],
        theme,
        bold,
    );
    let shaped = window
        .text_system()
        .shape_line(metrics.text, px(size_px), &metrics.runs, None);
    let text_ascent =
        f32::from(shaped.ascent + (px(line_height_px) - shaped.ascent - shaped.descent) / 2.0);
    let text_depth = line_height_px - text_ascent;
    let ascent = words
        .iter()
        .flatten()
        .filter(|f| !f.display)
        .filter_map(|f| f.equation.as_ref())
        .map(|e| e.ascent)
        .fold(text_ascent, f32::max);
    let depth = words
        .iter()
        .flatten()
        .filter(|f| !f.display)
        .filter_map(|f| f.equation.as_ref())
        .map(|e| e.depth)
        .fold(text_depth, f32::max);
    let group = format!("{}:{ix}", opts.row_key);
    let mut next = 0usize;
    let mut column = div().flex().flex_col().min_w_0();
    let mut row = flow_row(align);
    let mut has_row = false;
    for word in words {
        let display = word.iter().any(|f| f.display);
        let hard_break = word
            .iter()
            .any(|f| f.runs.iter().any(|run| run.text.ends_with('\n')));
        if display && has_row {
            column = column.child(row);
            row = flow_row(align);
            has_row = false;
        }
        let mut element = div().flex().flex_none();
        if !display {
            element = element.h(px(ascent + depth));
        }
        for fragment in word {
            let key: std::sync::Arc<str> =
                super::selection::inline_fragment_key(&group, next).into();
            let fragment_ix = ix.wrapping_mul(4099).wrapping_add(next + 3000);
            next += 1;
            if let Some(equation) = fragment.equation {
                let source: SharedString = fragment.copy.unwrap().into();
                let mut image = div()
                    .id(SharedString::from(key.to_string()))
                    .relative()
                    .flex_none()
                    .w(px(equation.width))
                    .h(px(equation.height))
                    .child(render::equation_selection(
                        key.clone(),
                        source.clone(),
                        theme.selection,
                    ))
                    .child(
                        gpui::img(equation.image)
                            .w(px(equation.width))
                            .h(px(equation.height)),
                    )
                    .when(cfg!(test), |image| {
                        image.debug_selector(|| "math-flow-equation".into())
                    })
                    .role(gpui::Role::Image)
                    .aria_label(source.clone());
                if fragment.runs[0].style.strikethrough {
                    let stroke_y = equation.ascent - size_px * 0.25;
                    let color = theme.text_muted;
                    #[cfg(test)]
                    let decoration_key = key.clone();
                    image = image.child(
                        gpui::canvas(
                            |_, _, _| (),
                            move |bounds, _, window, _| {
                                let rect = gpui::Bounds::new(
                                    bounds.origin + gpui::point(px(1.), px(stroke_y)),
                                    gpui::size((bounds.size.width - px(2.)).max(px(0.)), px(1.)),
                                );
                                window.paint_quad(gpui::fill(rect, color));
                                #[cfg(test)]
                                PAINTED_DECORATIONS.with(|rects| {
                                    rects.borrow_mut().insert(decoration_key.clone(), rect);
                                });
                            },
                        )
                        .absolute()
                        .top_0()
                        .left_0()
                        .size_full(),
                    );
                }
                if !display {
                    image = image.mt(px(ascent - equation.ascent));
                }
                let child = if let Some(url) = fragment.runs[0]
                    .style
                    .link
                    .as_deref()
                    .filter(|url| *url != super::mend::PENDING_LINK_URL)
                {
                    super::link_interaction::LinkRanges {
                        id: SharedString::from(format!("{group}-math-link-{next}")),
                        child: image.into_any_element(),
                        layout: None,
                        selection_key: Some(key),
                        links: vec![(0..source.len(), render::LinkTarget::new(&source, url))],
                        ui: opts.link.clone(),
                    }
                    .into_any_element()
                } else {
                    image.into_any_element()
                };
                element = element.child(child);
            } else {
                // Malformed or unsupported commands stay visibly literal; a
                // failed typeset must never masquerade as a successful layout.
                let mut flat = flatten_prose(&fragment.runs, theme, bold);
                if flat.text.contains('\n') {
                    let original = flat.text.clone();
                    flat.text = original.replace('\n', " ").into();
                    flat.original = Some(super::link_presentation::OriginalText {
                        text: original,
                        offsets: Default::default(),
                    });
                }
                let content = render::flat_text_presented_element_with_key(
                    &flat,
                    fragment_ix,
                    opts,
                    theme,
                    Some(key),
                );
                element = element.child(
                    div()
                        .flex_none()
                        .mt(px(if display { 0.0 } else { ascent - text_ascent }))
                        .text_size(crate::typography::ui_rems(size))
                        .line_height(crate::typography::ui_rems(line_height))
                        .child(content),
                );
            }
        }
        if display {
            column = column.child(
                div()
                    .id(SharedString::from(format!("{group}-equation-{next}")))
                    .w_full()
                    .flex()
                    .my(px(6.0))
                    .overflow_x_scroll()
                    .child(element),
            );
        } else {
            // An inline formula is indivisible, but must not force the pane
            // wider. Clamp each word's viewport and allow long tokens/equations
            // to scroll within it; normal words retain their natural width.
            row = row.child(
                div()
                    .id(SharedString::from(format!("{group}-word-{next}")))
                    // A flex viewport keeps the nonshrinking word at its
                    // intrinsic width, so scroll extent includes all its ink.
                    .flex()
                    .flex_none()
                    .min_w_0()
                    .max_w_full()
                    .overflow_x_scroll()
                    .child(element),
            );
            has_row = true;
            if hard_break {
                column = column.child(row);
                row = flow_row(align);
                has_row = false;
            }
        }
    }
    if has_row {
        column = column.child(row);
    }
    column.into_any_element()
}

#[cfg(test)]
thread_local! {
    static PAINTED_DECORATIONS: std::cell::RefCell<std::collections::HashMap<std::sync::Arc<str>, gpui::Bounds<gpui::Pixels>>> = std::cell::RefCell::new(std::collections::HashMap::new());
}

#[cfg(test)]
#[path = "math_flow_tests.rs"]
mod regression_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown::parser::{Block, parse_full};

    #[test]
    fn math_flow_keeps_punctuation_and_source_for_copy() {
        let tree = parse_full(r"Before $\frac{1}{n}$, after.");
        let Block::Paragraph { runs } = &tree.blocks[0].block else {
            panic!()
        };
        let words = fragments(runs, 14., &Theme::dark());
        let copied: String = words
            .iter()
            .flatten()
            .map(|f| {
                f.copy
                    .clone()
                    .unwrap_or_else(|| f.runs.iter().map(|r| r.text.as_str()).collect())
            })
            .collect();
        assert_eq!(copied, r"Before $\frac{1}{n}$, after.");
        assert!(
            words
                .iter()
                .any(|w| w.len() == 2 && w[0].equation.is_some() && w[1].runs[0].text == ", ")
        );
    }
}
