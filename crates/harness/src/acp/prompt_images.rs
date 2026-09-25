//! Image attachments as ACP `image` prompt blocks.
//!
//! Composer uploads ride the prompt text as an `Attached images (local files
//! — open them to view):` trailer of `- <path>` lines (the ui crate's
//! `with_attachments`; that text is what persists). For an agent that
//! advertises `promptCapabilities.image`, every prompt — the run's first and
//! each follow-up — also carries those files as `image` blocks, and the wire
//! trailer says they are already inline so the model doesn't spend tool calls
//! opening them. Agents without the capability get the text unchanged.

use std::path::Path;

use serde_json::{Value, json};

/// Case-insensitive start of the trailer header (after a blank line).
const MARKER: &str = "\n\nattached images (local files";
/// Wire header once every ref is inline. Keeps the `Attached images (local
/// files` prefix and `):` ending so trailer parsers still match it.
const INLINE_HEADER: &str =
    "Attached images (local files — already attached inline as images; no need to open them):";

/// The trailer's header line span and its `- <path>` refs.
struct Trailer {
    header_start: usize,
    header_end: usize,
    paths: Vec<String>,
}

fn trailer(text: &str) -> Option<Trailer> {
    let lower = text.to_ascii_lowercase();
    let mut from = 0;
    while let Some(rel) = lower[from..].find(MARKER) {
        let header_start = from + rel + 2;
        let header_end = text[header_start..]
            .find('\n')
            .map_or(text.len(), |p| header_start + p);
        if text[header_start..header_end].trim_end().ends_with("):") {
            let paths = text[header_end..]
                .lines()
                .skip_while(|line| line.trim().is_empty())
                .map_while(|line| line.trim_start().strip_prefix("- "))
                .map(|path| path.trim().to_string())
                .filter(|path| !path.is_empty())
                .collect();
            return Some(Trailer {
                header_start,
                header_end,
                paths,
            });
        }
        from = header_start;
    }
    None
}

/// One file as an `image` block, or `None` (unreadable, over the inline cap,
/// or not an inline-supported image) — its path ref still rides the text.
async fn image_block(path: &str) -> Option<Value> {
    use base64::Engine as _;
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(err) => {
            tracing::warn!(target: "harness_adapters::acp", %path, error = %err, "attachment unreadable; path ref only");
            return None;
        }
    };
    if bytes.len() as u64 > crate::claude::MAX_INLINE_IMAGE_BYTES {
        return None;
    }
    let mime = crate::claude::image_media_type(Path::new(path), &bytes)?;
    Some(json!({
        "type": "image",
        "mimeType": mime,
        "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
    }))
}

/// `session/prompt` content: the text block, then one `image` block per
/// attachment when `images` (the agent's `promptCapabilities.image`).
/// Attachments are the text trailer's refs plus `extra` (the run request's
/// staged uploads), deduplicated.
pub(super) async fn prompt_blocks(text: String, extra: &[String], images: bool) -> Vec<Value> {
    if !images {
        return vec![json!({ "type": "text", "text": text })];
    }
    let found = trailer(&text);
    let mut paths: Vec<&str> = Vec::new();
    for path in found
        .iter()
        .flat_map(|t| t.paths.iter())
        .chain(extra)
        .map(String::as_str)
    {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    let mut blocks = Vec::with_capacity(paths.len());
    for path in &paths {
        if let Some(block) = image_block(path).await {
            blocks.push(block);
        }
    }
    let text = match found {
        Some(t) if !t.paths.is_empty() && blocks.len() == paths.len() => format!(
            "{}{INLINE_HEADER}{}",
            &text[..t.header_start],
            &text[t.header_end..]
        ),
        _ => text,
    };
    let mut prompt = vec![json!({ "type": "text", "text": text })];
    prompt.extend(blocks);
    prompt
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

    fn with_refs(body: &str, paths: &[&str]) -> String {
        let refs: Vec<String> = paths.iter().map(|p| format!("- {p}")).collect();
        format!(
            "{body}\n\nAttached images (local files — open them to view):\n{}",
            refs.join("\n")
        )
    }

    #[test]
    fn trailer_reads_refs_and_stops_at_other_lines() {
        let text = format!("{}\n\nnot a ref", with_refs("hi", &["/a.png", "/b.png"]));
        let t = trailer(&text).unwrap();
        assert_eq!(t.paths, ["/a.png", "/b.png"]);
        assert!(text[t.header_start..t.header_end].starts_with("Attached images"));
        assert!(trailer("hi\n\nAttached images are nice").is_none());
        assert!(trailer("no trailer").is_none());
    }

    #[tokio::test]
    async fn follow_up_refs_become_image_blocks_and_the_header_says_inline() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("shot.png");
        std::fs::write(&image, PNG).unwrap();
        let path = image.to_str().unwrap();

        let blocks = prompt_blocks(with_refs("what is this?", &[path]), &[path.into()], true).await;
        assert_eq!(
            blocks.len(),
            2,
            "trailer ref and request attachment dedupe: {blocks:?}"
        );
        assert_eq!(blocks[1]["type"], "image");
        let text = blocks[0]["text"].as_str().unwrap();
        assert!(text.starts_with("what is this?\n\n"));
        assert!(text.contains(INLINE_HEADER), "{text}");
        assert!(!text.contains("open them to view"), "{text}");
        assert!(
            text.ends_with(&format!("- {path}")),
            "path ref kept: {text}"
        );
        let t = trailer(text).unwrap();
        assert_eq!(t.paths, [path], "rewritten header still parses");
    }

    #[tokio::test]
    async fn missing_file_keeps_the_open_them_header() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("shot.png");
        std::fs::write(&image, PNG).unwrap();
        let path = image.to_str().unwrap();
        let text = with_refs("hi", &[path, "/nonexistent/missing.png"]);

        let blocks = prompt_blocks(text.clone(), &[], true).await;
        assert_eq!(blocks.len(), 2, "readable image still inlined");
        assert_eq!(
            blocks[0]["text"],
            text.as_str(),
            "model must still open the missing one"
        );
    }

    #[tokio::test]
    async fn agents_without_the_capability_get_text_only() {
        let blocks = prompt_blocks(with_refs("hi", &["/x.png"]), &[], false).await;
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0]["text"], with_refs("hi", &["/x.png"]).as_str());
    }
}
