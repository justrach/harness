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

/// Where `graff -w` must launch for a run whose cwd is `cwd`: the main
/// checkout. A follow-up can carry the chat's re-homed cwd, the tree itself,
/// and `-w` from inside it asks Graff for a nested tree on a branch that is
/// already checked out, which fails with a name collision.
pub fn launch_root(cwd: &str) -> &str {
    match cwd.find(MARKER) {
        Some(at) if GraffWorktree::from_path(cwd).is_some() => &cwd[..at],
        _ => cwd,
    }
}

/// Graff's `-w` name rule: 1–64 of `[A-Za-z0-9._-]`.
pub fn valid_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Legacy name, retained for compatibility with existing checkouts.
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

/// A new tree is named for the task, with a stable digest of the full chat id
/// to distinguish independent conversations doing the same work. Existing trees
/// keep their name.
pub fn name_for_task(chat_id: &str, task: &str) -> String {
    // FNV-1a has an explicitly stable algorithm, unlike DefaultHasher. Hash all
    // bytes: UUIDv7 ids share prefixes, and filtering punctuation/case loses ids.
    let digest = chat_id
        .as_bytes()
        .iter()
        .fold(0xcbf29ce484222325_u64, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
        });
    let slug = crate::worktree_name::task_slug(task);
    // Reserve one separator and 16 hex digits within Graff's 64-byte limit.
    let slug = slug[..slug.len().min(47)].trim_end_matches('-');
    format!("{slug}-{digest:016x}")
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
    fn worktree_runs_launch_from_the_main_checkout() {
        assert_eq!(launch_root("/repo"), "/repo");
        assert_eq!(launch_root("/repo/.graff/worktrees/harness-ab12"), "/repo");
        assert_eq!(
            launch_root("/repo/.graff/worktrees/harness-ab12/src"),
            "/repo"
        );
        assert_eq!(
            launch_root("/repo/.graff/worktrees/bad name"),
            "/repo/.graff/worktrees/bad name"
        );
    }

    #[test]
    fn new_chat_names_describe_the_task_without_product_branding() {
        let name = name_for_task("chat-graff-tree", "Fix login redirect after sign-in");
        assert_eq!(name, "fix-login-redirect-after-sign-in-1a7188e911beeb31");
        assert!(valid_name(&name));
        assert!(valid_name(&name_for_task("---", "***")));
        assert!(valid_name(&name_for_task("chat", &"x".repeat(100))));
        assert_ne!(
            name_for_task("chat-one", "Fix login"),
            name_for_task("chat-two", "Fix login")
        );
    }

    #[test]
    fn task_name_digests_are_stable_across_processes() {
        // Published FNV-1a 64-bit vectors pin the algorithm, not Rust's hasher.
        assert_eq!(name_for_task("", "Fix login"), "fix-login-cbf29ce484222325");
        assert_eq!(
            name_for_task("a", "Fix login"),
            "fix-login-af63dc4c8601ec8c"
        );
        assert_eq!(
            name_for_task("foobar", "Fix login"),
            "fix-login-85944171f73967e8"
        );
    }

    #[test]
    fn task_names_distinguish_chat_ids_with_shared_uuidv7_prefixes() {
        let ids = [
            "019b1234-5678-7000-8000-000000000001",
            "019b1234-5678-7000-8000-000000000002",
            "019b1234-5678-7fff-bfff-ffffffffffff",
        ];
        let names: std::collections::HashSet<_> = ids
            .iter()
            .map(|id| name_for_task(id, "Fix login"))
            .collect();
        assert_eq!(names.len(), ids.len());
    }

    #[test]
    fn task_names_distinguish_punctuation_case_and_empty_chat_ids() {
        let ids = [
            "", "---", "...", "_", "chat-one", "chat_one", "chatone", "CHATONE", "é", "è",
        ];
        let names: std::collections::HashSet<_> = ids
            .iter()
            .map(|id| name_for_task(id, "Fix login"))
            .collect();
        assert_eq!(names.len(), ids.len());
        for name in names {
            assert!(valid_name(&name), "{name}");
            assert!(name.starts_with("fix-login-"), "{name}");
        }
    }

    #[test]
    fn task_names_fit_graff_limits_at_slug_boundaries() {
        for task in [
            "x".repeat(47),
            "x".repeat(48),
            "x".repeat(100),
            format!("{}-more", "x".repeat(46)),
            "CON".into(),
            "***".into(),
        ] {
            for id in ["", "---", "019b1234-5678-7000-8000-000000000001"] {
                let name = name_for_task(id, &task);
                assert!(valid_name(&name), "{name}");
                assert!(name.len() <= 64);
                assert!(!name.starts_with("harness-"));
                assert!(!name.contains("--"), "{name}");
                assert_eq!(name_for_task(id, &task), name);
            }
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
