//! Safe resolution of agent-authored Markdown links into workspace files.

use std::path::{Component, Path};

const FILE_MENTION_SCHEME: &str = "harness-file:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkspaceFileLink {
    pub path: String,
    pub line: Option<u32>,
    pub column: Option<u32>,
}

/// Resolve a literal path, such as a tool's file argument or a bare filename
/// in prose. `%` is an ordinary filename character here.
pub(crate) fn resolve_workspace_file_link(
    target: &str,
    workspace_root: &str,
) -> Option<WorkspaceFileLink> {
    resolve(target, workspace_root, false)
}

/// Resolve a Markdown link destination. Destinations are URIs, so `%20` in
/// `[guide](Week%201/Guide.md)` means a space. Escapes are decoded once,
/// after the `#L` and `:line:column` locations are split off and before the
/// path is checked, so an encoded `..`, `/`, `\` or NUL is still refused. An
/// invalid escape (`100%.md`) is kept as written.
pub(crate) fn resolve_markdown_file_link(
    destination: &str,
    workspace_root: &str,
) -> Option<WorkspaceFileLink> {
    resolve(destination, workspace_root, true)
}

fn resolve(target: &str, workspace_root: &str, uri: bool) -> Option<WorkspaceFileLink> {
    let target = target.trim();
    if target.is_empty() || target.contains(['?', '\0']) {
        return None;
    }

    let decoded;
    let is_file_mention = target.starts_with(FILE_MENTION_SCHEME);
    let mut target = if let Some(encoded) = target.strip_prefix(FILE_MENTION_SCHEME) {
        decoded = percent_decode_path(encoded)?;
        if percent_encode_path(&decoded) != encoded || decoded.ends_with('/') {
            return None;
        }
        if decoded.starts_with('/') || decoded.as_bytes().get(1) == Some(&b':') {
            let path =
                crate::markdown::content_reference::workspace_path(&decoded, workspace_root)?;
            return Some(WorkspaceFileLink {
                path,
                line: None,
                column: None,
            });
        }
        decoded.as_str()
    } else if let Some(path) = target.strip_prefix("file://") {
        path
    } else if target.contains("://") || target.starts_with("mailto:") {
        return None;
    } else {
        target
    };

    let (without_fragment, fragment_line) = if is_file_mention {
        (target, None)
    } else {
        split_line_fragment(target)
    };
    target = without_fragment;
    let (target, suffix_line, column) = if is_file_mention {
        (target, None, None)
    } else {
        split_line_suffix(target)
    };
    let uri_decoded;
    let target = if uri && !is_file_mention && target.contains('%') {
        uri_decoded = percent_decode_path(target).unwrap_or_else(|| target.to_owned());
        uri_decoded.as_str()
    } else {
        target
    };
    if target.contains(['\\', '\n', '\r', '\0'])
        || target
            .split('/')
            .enumerate()
            .any(|(index, part)| (part.is_empty() && index != 0) || matches!(part, "." | ".."))
    {
        return None;
    }
    if target.contains(':') {
        return None;
    }
    let line = fragment_line.or(suffix_line);

    let root = Path::new(workspace_root);
    // A remote engine may supply POSIX paths to a Windows viewport. A leading
    // slash has a root on Windows, but is_absolute() also requires a drive;
    // classify the link by its root instead of the viewer's absolute-path rules.
    let relative = if Path::new(target).has_root() {
        Path::new(target).strip_prefix(root).ok()?
    } else {
        Path::new(target)
    };
    let path = safe_relative_path(relative)?;
    Some(WorkspaceFileLink { path, line, column })
}

fn safe_relative_path(path: &Path) -> Option<String> {
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_str()?),
            Component::CurDir
            | Component::ParentDir
            | Component::RootDir
            | Component::Prefix(_) => return None,
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

fn split_line_fragment(target: &str) -> (&str, Option<u32>) {
    let Some((path, fragment)) = target.rsplit_once('#') else {
        return (target, None);
    };
    let line = fragment
        .strip_prefix('L')
        .and_then(|line| line.parse::<u32>().ok())
        .filter(|line| *line > 0);
    if line.is_some() {
        (path, line)
    } else {
        (target, None)
    }
}

fn split_line_suffix(target: &str) -> (&str, Option<u32>, Option<u32>) {
    let mut pieces = target.rsplitn(3, ':');
    let last = pieces.next().unwrap_or_default();
    let Some(before_last) = pieces.next() else {
        return (target, None, None);
    };
    let Some(last_number) = positive_number(last) else {
        return (target, None, None);
    };
    if let Some(path) = pieces.next()
        && let Some(line) = positive_number(before_last)
    {
        return (path, Some(line), Some(last_number));
    }
    let path_len = target.len() - last.len() - 1;
    (&target[..path_len], Some(last_number), None)
}

fn positive_number(value: &str) -> Option<u32> {
    value.parse::<u32>().ok().filter(|number| *number > 0)
}

fn percent_decode_path(encoded: &str) -> Option<String> {
    let raw = encoded.as_bytes();
    let mut bytes = Vec::with_capacity(raw.len());
    let mut at = 0;
    while at < raw.len() {
        if raw[at] == b'%' {
            let hex = std::str::from_utf8(raw.get(at + 1..at + 3)?).ok()?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
            at += 3;
        } else {
            bytes.push(raw[at]);
            at += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn percent_encode_path(path: &str) -> String {
    let mut out = String::new();
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push_str(&format!("{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_relative_absolute_and_location_links() {
        let root = "/work/comet";
        assert_eq!(
            resolve_workspace_file_link("crates/ui/src/lib.rs", root),
            Some(WorkspaceFileLink {
                path: "crates/ui/src/lib.rs".into(),
                line: None,
                column: None,
            })
        );
        assert_eq!(
            resolve_workspace_file_link("/work/comet/crates/ui/src/lib.rs:42:7", root),
            Some(WorkspaceFileLink {
                path: "crates/ui/src/lib.rs".into(),
                line: Some(42),
                column: Some(7),
            })
        );
        assert_eq!(
            resolve_workspace_file_link("file:///work/comet/README.md#L12", root),
            Some(WorkspaceFileLink {
                path: "README.md".into(),
                line: Some(12),
                column: None,
            })
        );
    }

    #[test]
    fn resolves_canonical_file_mentions() {
        assert_eq!(
            resolve_workspace_file_link("harness-file:src/a%20file.rs", "/work/comet"),
            Some(WorkspaceFileLink {
                path: "src/a file.rs".into(),
                line: None,
                column: None,
            })
        );
        assert!(resolve_workspace_file_link("harness-file:src/%61.rs", "/work/comet").is_none());
        assert!(resolve_workspace_file_link("harness-file:src/", "/work/comet").is_none());
    }

    #[test]
    fn citations_preserve_literal_punctuation_and_windows_host_paths() {
        let destination =
            crate::markdown::content_reference::file_destination("/work/a%20#L4.html");
        let link = resolve_workspace_file_link(&destination, "/work").unwrap();
        assert_eq!(link.path, "a%20#L4.html");
        assert_eq!(link.line, None);
        let destination =
            crate::markdown::content_reference::file_destination(r"C:\work\空 格.html");
        assert_eq!(
            resolve_workspace_file_link(&destination, r"C:\work")
                .unwrap()
                .path,
            "空 格.html"
        );
    }

    #[test]
    fn markdown_destinations_decode_escapes_once() {
        let root = "/work/comet";
        let open = |target| resolve_markdown_file_link(target, root);
        assert_eq!(
            open("Demo%20Folder/Week%201/Example%20Guide.md"),
            Some(WorkspaceFileLink {
                path: "Demo Folder/Week 1/Example Guide.md".into(),
                line: None,
                column: None,
            })
        );
        assert_eq!(
            open("file:///work/comet/Demo%20Folder/Guide.md#L3"),
            Some(WorkspaceFileLink {
                path: "Demo Folder/Guide.md".into(),
                line: Some(3),
                column: None,
            })
        );
        assert_eq!(
            open("Week%201/Guide.md:4:2"),
            Some(WorkspaceFileLink {
                path: "Week 1/Guide.md".into(),
                line: Some(4),
                column: Some(2),
            })
        );
        assert_eq!(open("%E7%A9%BA.md").unwrap().path, "空.md");
        assert_eq!(open("Week 1/Guide.md").unwrap().path, "Week 1/Guide.md");
        // Decoded once: `%2520` names a file containing a literal `%20`.
        assert_eq!(open("a%2520b.md").unwrap().path, "a%20b.md");
        assert_eq!(open("100%.md").unwrap().path, "100%.md");
        // `%23` is part of the name, not a location fragment.
        assert_eq!(open("a%23L4.md").unwrap().path, "a#L4.md");
        assert_eq!(
            open("harness-file:src/a%20file.rs").unwrap().path,
            "src/a file.rs"
        );
    }

    #[test]
    fn markdown_destinations_refuse_encoded_escapes() {
        let root = "/work/comet";
        for target in [
            "%2E%2E/secret.rs",
            "src/%2E%2E/%2E%2E/secret.rs",
            "src%2F%2F/lib.rs",
            "src%5Clib.rs",
            "src/lib%00.rs",
            "%2Ftmp/file.rs",
            "a%3Ab.rs",
        ] {
            assert!(
                resolve_markdown_file_link(target, root).is_none(),
                "accepted {target}"
            );
        }
    }

    #[test]
    fn literal_paths_keep_percent_signs() {
        assert_eq!(
            resolve_workspace_file_link("a%20b.md", "/work/comet")
                .unwrap()
                .path,
            "a%20b.md"
        );
    }

    #[test]
    fn rejects_external_and_unsafe_targets() {
        let root = "/work/comet";
        for target in [
            "https://example.com/file.rs",
            "mailto:dev@example.com",
            "/work/comet-other/src/lib.rs",
            "/tmp/file.rs",
            "../secret.rs",
            "src/../../secret.rs",
            "src/./lib.rs",
            "src//lib.rs",
        ] {
            assert!(
                resolve_workspace_file_link(target, root).is_none(),
                "accepted {target}"
            );
        }
    }
}
