//! Task-derived names shared by host-created and agent-owned worktrees.
//! A worktree can be allocated before a chat title exists, so its first request
//! supplies the name. Only the first line is used; context appended below it is
//! not part of the task label.

pub fn task_slug(task: &str) -> String {
    let mut slug = String::new();
    let first_line = task
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("");
    for c in first_line.trim().chars() {
        if matches!(c, '\'' | '"' | '`') {
            continue;
        }
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
        if slug.len() >= 48 {
            break;
        }
    }
    let slug = slug.trim_end_matches('-');
    if slug.is_empty() {
        "changes".into()
    } else if matches!(slug, "con" | "prn" | "aux" | "nul")
        || matches!(
            slug.as_bytes(),
            [b'c', b'o', b'm', b'1'..=b'9'] | [b'l', b'p', b't', b'1'..=b'9']
        )
    {
        // These are device names on Windows even when used as folder names.
        format!("{slug}-task")
    } else {
        slug.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_names_avoid_windows_device_names() {
        for reserved in ["CON", "prn", "AuX", "NUL", "COM1", "com9", "LPT1", "lpt9"] {
            let expected = format!("{}-task", reserved.to_ascii_lowercase());
            assert_eq!(task_slug(reserved), expected, "{reserved}");
            assert_eq!(task_slug(&format!(" .{reserved}. ")), expected);
        }
        for ordinary in ["com0", "com10", "lpt0", "lpt10", "console", "auxiliary"] {
            assert_eq!(task_slug(ordinary), ordinary);
        }
    }

    #[test]
    fn task_names_use_only_the_first_nonblank_line() {
        for (task, expected) in [
            ("\t\r\n \nFix login\r\nPrivate context", "fix-login"),
            ("\u{2003}\u{a0}\n Fix login \nOther task", "fix-login"),
            ("***\nFix login", "changes"),
            ("\t\r\n \u{2003}", "changes"),
            ("\0Fix\tlogin\u{7f}flow\rnow", "fix-login-flow-now"),
            ("\u{200b}Fix\u{202e}login", "fix-login"),
            ("修正\nFix login", "changes"),
            ("", "changes"),
        ] {
            assert_eq!(task_slug(task), expected, "{task:?}");
        }
    }

    #[test]
    fn task_names_bound_ascii_length_without_trailing_separators() {
        for length in [46, 47, 48, 49, 100, 4096] {
            let input = "x".repeat(length);
            assert_eq!(task_slug(&input), "x".repeat(length.min(48)));
        }
        assert_eq!(
            task_slug(&format!("{} more", "x".repeat(47))),
            "x".repeat(47)
        );
        assert_eq!(
            task_slug(&format!("{}more", "x-".repeat(24))),
            format!("{}x", "x-".repeat(23))
        );
        for task in [
            "../@{feature}.lock",
            "---",
            "💥",
            "  a...b__c / d  ",
            "don't `join` \"words\"",
        ] {
            let slug = task_slug(task);
            assert!((1..=48).contains(&slug.len()));
            assert!(
                slug.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            );
            assert!(!slug.starts_with('-') && !slug.ends_with('-'));
            assert!(!slug.contains("--"));
        }
    }

    #[test]
    fn task_names_are_descriptive_and_valid_ref_components() {
        assert_eq!(task_slug("  Fix `Login` Flow!  "), "fix-login-flow");
        assert_eq!(task_slug("Cafe's Dark Mode"), "cafes-dark-mode");
        assert_eq!(
            task_slug("\nFix redirect\nAdditional context"),
            "fix-redirect"
        );
        assert_eq!(task_slug("../../Fix: login @{flow}"), "fix-login-flow");
        assert_eq!(task_slug("***"), "changes");
        assert_eq!(task_slug(&"x".repeat(100)).len(), 48);
    }
}
