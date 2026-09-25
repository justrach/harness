//! Image attachments as ACP `image` prompt blocks.
//!
//! Composer uploads ride the prompt text as an `Attached images (local files
//! — open them to view):` trailer of `- <path>` lines (the ui crate's
//! `with_attachments`; that text is what persists). An agent that advertises
//! `promptCapabilities.image` gets every prompt — the run's first and each
//! follow-up — the way a chat client sends one: the text without the trailer,
//! then the images as `image` blocks whose `uri` is the file.
//!
//! Only files the engine resolved to this device's uploads (`RunRequest::
//! attachments`, `SteerMessage::attachments`) are ever read; the trailer only
//! selects among them. A path merely written in synced or pasted text is
//! never read. A file must also sniff as an image by its bytes. If any
//! trailer ref can't be inlined, the trailer stays so the model can still
//! open it. Agents without the capability get the text unchanged.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// Case-insensitive start of the trailer header (after a blank line).
const MARKER: &str = "\n\nattached images (local files";

/// The trailer's byte span (from the blank line before its header through
/// its last `- <path>` line) and its refs.
struct Trailer {
    start: usize,
    end: usize,
    paths: Vec<String>,
}

fn trailer(text: &str) -> Option<Trailer> {
    let lower = text.to_ascii_lowercase();
    let mut from = 0;
    while let Some(rel) = lower[from..].find(MARKER) {
        let start = from + rel;
        let header_start = start + 2;
        let header_end = text[header_start..]
            .find('\n')
            .map_or(text.len(), |p| header_start + p);
        if text[header_start..header_end].trim_end().ends_with("):") {
            // `end` sits on the newline after the last ref line (or at the
            // end of the text), so anything after the trailer survives.
            let mut end = header_end;
            let mut paths = Vec::new();
            while end < text.len() {
                let line_start = end + 1;
                let line_end = text[line_start..]
                    .find('\n')
                    .map_or(text.len(), |p| line_start + p);
                let Some(path) = text[line_start..line_end].trim_start().strip_prefix("- ") else {
                    break;
                };
                let path = path.trim();
                if !path.is_empty() {
                    paths.push(path.to_string());
                }
                end = line_end;
            }
            return Some(Trailer { start, end, paths });
        }
        from = header_start;
    }
    None
}

/// `file://` URI for an absolute local path (RFC 8089), percent-encoding
/// everything outside the unreserved set and `/`.
fn file_uri(path: &str) -> String {
    let mut uri = String::from("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            uri.push(b as char);
        } else {
            uri.push_str(&format!("%{b:02X}"));
        }
    }
    uri
}

/// Media type from the file's bytes alone: an extension proves nothing.
fn sniff(bytes: &[u8]) -> Option<&'static str> {
    match bytes {
        [0x89, b'P', b'N', b'G', ..] => Some("image/png"),
        [0xFF, 0xD8, 0xFF, ..] => Some("image/jpeg"),
        [b'G', b'I', b'F', b'8', ..] => Some("image/gif"),
        [
            b'R',
            b'I',
            b'F',
            b'F',
            _,
            _,
            _,
            _,
            b'W',
            b'E',
            b'B',
            b'P',
            ..,
        ] => Some("image/webp"),
        _ => None,
    }
}

/// Canonical form for comparing paths (`/var` vs `/private/var`); a path
/// that can't be canonicalized (missing) can't be authorized either.
async fn canonical(path: &str) -> Option<PathBuf> {
    tokio::fs::canonicalize(path).await.ok()
}

/// One file as an `image` block, or `None` (unreadable, over the inline cap,
/// or not an image by its bytes) — its path ref still rides the text.
async fn image_block(path: &Path, uri_path: &str) -> Option<Value> {
    use base64::Engine as _;
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(err) => {
            tracing::warn!(target: "harness_adapters::acp", path = %path.display(), error = %err, "attachment unreadable; path ref only");
            return None;
        }
    };
    if bytes.len() as u64 > crate::claude::MAX_INLINE_IMAGE_BYTES {
        return None;
    }
    let mime = sniff(&bytes)?;
    Some(json!({
        "type": "image",
        "mimeType": mime,
        "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
        "uri": file_uri(uri_path),
    }))
}

/// `session/prompt` content: the text block, then one `image` block per
/// attachment when `images` (the agent's `promptCapabilities.image`).
/// Candidates are the text trailer's refs plus `extra` (the run request's
/// uploads); only those in `allowed` (engine-resolved uploads) are read.
pub(super) async fn prompt_blocks(
    text: String,
    extra: &[String],
    allowed: &[String],
    images: bool,
) -> Vec<Value> {
    if !images {
        return vec![json!({ "type": "text", "text": text })];
    }
    let mut authorized: HashSet<PathBuf> = HashSet::new();
    for path in allowed {
        if let Some(real) = canonical(path).await {
            authorized.insert(real);
        }
    }
    let found = trailer(&text);
    let trailer_refs: &[String] = found.as_ref().map_or(&[], |t| &t.paths);
    let mut sent: Vec<PathBuf> = Vec::new();
    let mut blocks = Vec::new();
    let mut all_trailer_inlined = true;
    for (index, path) in trailer_refs.iter().chain(extra).enumerate() {
        let from_trailer = index < trailer_refs.len();
        let real = canonical(path)
            .await
            .filter(|real| authorized.contains(real));
        let Some(real) = real else {
            all_trailer_inlined &= !from_trailer;
            continue;
        };
        if sent.contains(&real) {
            continue;
        }
        match image_block(&real, path).await {
            Some(block) => {
                blocks.push(block);
                sent.push(real);
            }
            None => all_trailer_inlined &= !from_trailer,
        }
    }
    let text = match found {
        Some(t) if !t.paths.is_empty() && all_trailer_inlined => {
            format!("{}{}", &text[..t.start], &text[t.end..])
        }
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
        assert_eq!(
            format!("{}{}", &text[..t.start], &text[t.end..]),
            "hi\n\nnot a ref"
        );
        assert!(trailer("hi\n\nAttached images are nice").is_none());
        assert!(trailer("no trailer").is_none());
    }

    #[test]
    fn file_uris_are_percent_encoded() {
        assert_eq!(file_uri("/tmp/a b#1.png"), "file:///tmp/a%20b%231.png");
    }

    #[tokio::test]
    async fn refs_become_image_blocks_and_the_trailer_leaves_the_text() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("shot.png");
        std::fs::write(&image, PNG).unwrap();
        let path = image.to_str().unwrap();

        let blocks = prompt_blocks(
            with_refs("what is this?", &[path]),
            &[path.into()],
            &[path.into()],
            true,
        )
        .await;
        assert_eq!(
            blocks.len(),
            2,
            "trailer ref and request attachment dedupe: {blocks:?}"
        );
        assert_eq!(
            blocks[0]["text"], "what is this?",
            "just the message, like a chat client"
        );
        assert_eq!(blocks[1]["type"], "image");
        assert_eq!(blocks[1]["uri"], file_uri(path));
    }

    #[tokio::test]
    async fn text_paths_the_engine_did_not_resolve_are_never_read() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join("secret.png");
        std::fs::write(&secret, PNG).unwrap();
        let path = secret.to_str().unwrap();
        let text = with_refs("hi", &[path]);

        let blocks = prompt_blocks(text.clone(), &[], &[], true).await;
        assert_eq!(
            blocks.len(),
            1,
            "unauthorized trailer path not inlined: {blocks:?}"
        );
        assert_eq!(blocks[0]["text"], text.as_str(), "trailer kept");
    }

    #[tokio::test]
    async fn a_non_image_named_png_is_not_sent() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("keys.png");
        std::fs::write(&fake, b"-----BEGIN PRIVATE KEY-----").unwrap();
        let path = fake.to_str().unwrap();

        let blocks = prompt_blocks(with_refs("hi", &[path]), &[], &[path.into()], true).await;
        assert_eq!(
            blocks.len(),
            1,
            "extension alone is not an image: {blocks:?}"
        );
    }

    #[tokio::test]
    async fn aliased_paths_dedupe_after_canonicalizing() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("shot.png");
        std::fs::write(&image, PNG).unwrap();
        let path = image.to_str().unwrap();
        let alias = dir.path().join(".").join("shot.png");
        let alias = alias.to_str().unwrap();

        let blocks =
            prompt_blocks(with_refs("hi", &[path, alias]), &[], &[path.into()], true).await;
        assert_eq!(blocks.len(), 2, "one image for two spellings: {blocks:?}");
        assert_eq!(blocks[0]["text"], "hi");
    }

    #[tokio::test]
    async fn missing_file_keeps_the_trailer() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("shot.png");
        std::fs::write(&image, PNG).unwrap();
        let path = image.to_str().unwrap();
        let missing = "/nonexistent/missing.png";
        let text = with_refs("hi", &[path, missing]);

        let blocks = prompt_blocks(text.clone(), &[], &[path.into(), missing.into()], true).await;
        assert_eq!(blocks.len(), 2, "readable image still inlined");
        assert_eq!(
            blocks[0]["text"],
            text.as_str(),
            "model must still open the missing one"
        );
    }

    #[tokio::test]
    async fn agents_without_the_capability_get_text_only() {
        let blocks =
            prompt_blocks(with_refs("hi", &["/x.png"]), &[], &["/x.png".into()], false).await;
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0]["text"], with_refs("hi", &["/x.png"]).as_str());
    }
}
