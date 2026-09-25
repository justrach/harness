//! Graff-owned git worktrees. `graff -w <name>` creates (or reuses)
//! `<root>/.graff/worktrees/<name>` on branch `worktree-<name>`, runs the
//! checkout's `.graff/workspace.toml` setup there, and lands it back with
//! `graff worktree merge <name>` from `<root>`. Named trees are never reaped
//! between runs, so a chat can keep one across turns.

const MARKER: &str = "/.graff/worktrees/";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraffWorktree {
    /// The main checkout the tree belongs to (where `graff worktree` runs).
    pub root: String,
    /// The `-w` name; also what `graff worktree merge|archive|remove` take.
    pub name: String,
    /// Absolute path of the worktree checkout.
    pub path: String,
}

impl GraffWorktree {
    /// The Graff worktree `path` is (or is inside), if any.
    pub fn from_path(path: &str) -> Option<Self> {
        let at = path.find(MARKER)?;
        let root = &path[..at];
        let name = path[at + MARKER.len()..].split('/').next()?;
        if root.is_empty() || !valid_name(name) {
            return None;
        }
        Some(Self {
            root: root.to_owned(),
            name: name.to_owned(),
            path: Self::path_in(root, name),
        })
    }

    /// Where `graff -w <name>` launched from `root` puts its tree.
    pub fn path_in(root: &str, name: &str) -> String {
        format!("{}{MARKER}{name}", root.trim_end_matches('/'))
    }

    pub fn branch(&self) -> String {
        format!("worktree-{}", self.name)
    }
}

/// Graff's `-w` name rule: 1–64 of `[A-Za-z0-9._-]`.
pub fn valid_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The stable per-chat tree name Harness asks Graff for.
pub fn name_for_chat(chat_id: &str) -> String {
    let short: String = chat_id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(12)
        .collect::<String>()
        .to_ascii_lowercase();
    if short.is_empty() {
        "harness-chat".into()
    } else {
        format!("harness-{short}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_graff_worktree_paths() {
        let tree = GraffWorktree::from_path("/repo/.graff/worktrees/harness-ab12").unwrap();
        assert_eq!(tree.root, "/repo");
        assert_eq!(tree.name, "harness-ab12");
        assert_eq!(tree.path, "/repo/.graff/worktrees/harness-ab12");
        assert_eq!(tree.branch(), "worktree-harness-ab12");
        let inside = GraffWorktree::from_path("/repo/.graff/worktrees/x/src/lib.rs").unwrap();
        assert_eq!(inside.path, "/repo/.graff/worktrees/x");
        assert_eq!(GraffWorktree::path_in("/repo/", "x"), "/repo/.graff/worktrees/x");
        for other in ["/repo", "/repo/.graff/worktrees/", "/.graff/worktrees/x", "/r/.graff/worktrees/bad name"] {
            assert_eq!(GraffWorktree::from_path(other), None, "{other}");
        }
    }

    #[test]
    fn chat_names_are_valid_graff_names() {
        let name = name_for_chat("0199A1B2-C3D4-7e5f-8a9b-0c1d2e3f4a5b");
        assert_eq!(name, "harness-0199a1b2c3d4");
        assert!(valid_name(&name));
        assert!(valid_name(&name_for_chat("---")));
        assert!(!valid_name(&"x".repeat(65)));
        assert!(!valid_name("a/b"));
    }
}
