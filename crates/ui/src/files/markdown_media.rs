//! Collect workspace images and diagrams referenced by Markdown.
use crate::markdown::parser::{Block, BlockTree, InlineRun};

pub(super) fn image_sources(tree: &BlockTree) -> Vec<String> {
    let mut out = Vec::new();
    for top in &tree.blocks {
        collect_images(&top.block, &mut out);
    }
    out
}

/// Image sources in one block, in order, without duplicates.
pub(crate) fn block_image_sources(block: &Block) -> Vec<String> {
    let mut out = Vec::new();
    collect_images(block, &mut out);
    out
}

fn collect_images(b: &Block, out: &mut Vec<String>) {
    fn runs(runs: &[InlineRun], out: &mut Vec<String>) {
        for run in runs {
            if let Some(image) = &run.style.image {
                if !out.contains(&image.source) {
                    out.push(image.source.clone());
                }
            }
        }
    }
    match b {
        Block::Paragraph { runs: r } | Block::Heading { runs: r, .. } => runs(r, out),
        Block::BlockQuote { children } => children.iter().for_each(|b| collect_images(b, out)),
        Block::List { items, .. } => items.iter().flatten().for_each(|b| collect_images(b, out)),
        Block::Table { header, rows, .. } => header
            .iter()
            .chain(rows.iter().flatten())
            .for_each(|r| runs(r, out)),
        _ => {}
    }
}

pub(super) fn diagram_sources(tree: &BlockTree) -> Vec<String> {
    let mut out = Vec::new();
    for top in &tree.blocks {
        collect_diagrams(&top.block, &mut out);
    }
    out
}

/// Mermaid fence sources in one block, in order, without duplicates.
pub(crate) fn block_diagram_sources(block: &Block) -> Vec<String> {
    let mut out = Vec::new();
    collect_diagrams(block, &mut out);
    out
}

fn collect_diagrams(block: &Block, out: &mut Vec<String>) {
    match block {
        Block::CodeBlock { language, code }
            if language
                .as_deref()
                .is_some_and(|l| l.eq_ignore_ascii_case("mermaid")) =>
        {
            if !out.contains(code) {
                out.push(code.clone());
            }
        }
        Block::BlockQuote { children } => children.iter().for_each(|b| collect_diagrams(b, out)),
        Block::List { items, .. } => items
            .iter()
            .flatten()
            .for_each(|b| collect_diagrams(b, out)),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn image_collection_preserves_nested_and_repeated_media() {
        let tree = crate::markdown::parser::parse_full(
            "before ![a](a.png) after\n\n> ![b](b.svg)\n\n- ![a](a.png)",
        );
        assert_eq!(image_sources(&tree), ["a.png", "b.svg"]);
    }

    #[test]
    fn diagram_collection_finds_nested_mermaid_fences_once() {
        let tree = crate::markdown::parser::parse_full(
            "```mermaid\ngraph TD; A-->B\n```\n\n> ```Mermaid\n> graph LR; C-->D\n> ```\n\n- ```mermaid\n  graph TD; A-->B\n  ```\n\n```rust\nfn main() {}\n```",
        );
        assert_eq!(
            diagram_sources(&tree),
            ["graph TD; A-->B", "graph LR; C-->D"]
        );
        assert_eq!(
            block_diagram_sources(&tree.blocks[1].block),
            ["graph LR; C-->D"]
        );
        assert!(block_diagram_sources(&tree.blocks[3].block).is_empty());
    }
}
