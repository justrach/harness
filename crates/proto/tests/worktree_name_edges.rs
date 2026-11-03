use harness_proto::graff_worktree::{GraffWorktree, launch_root, name_for_task, valid_name};
use std::collections::HashSet;
use std::process::Command;

fn assert_git_branch(branch: &str) {
    let output = Command::new("git")
        .args(["check-ref-format", "--branch", branch])
        .output()
        .expect("git must be available to check generated worktree branches");
    assert!(
        output.status.success(),
        "generated branch {branch:?} is not a Git ref: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn assert_graff_round_trip(name: &str) -> String {
    assert!(valid_name(name), "invalid Graff name: {name:?}");
    assert!(name.len() <= 64, "Graff name exceeds its byte limit");
    let mut branch = None;
    // Root punctuation/Unicode must not be confused with the ASCII-only tree
    // name, including when a resumed run starts below the checkout itself.
    for root in ["/synthetic/repo with spaces", "/synthetic/工作树"] {
        let path = GraffWorktree::path_in(&format!("{root}///"), name);
        for suffix in ["", "/", "/src/lib.rs"] {
            let cwd = format!("{path}{suffix}");
            let parsed = GraffWorktree::from_path(&cwd)
                .unwrap_or_else(|| panic!("generated name did not round-trip: {cwd:?}"));
            assert_eq!(parsed.name, name);
            assert_eq!(parsed.root, root);
            assert_eq!(parsed.path, path);
            assert_eq!(launch_root(&cwd), root);
            let parsed_branch = parsed.branch();
            if let Some(expected) = &branch {
                assert_eq!(&parsed_branch, expected);
            } else {
                branch = Some(parsed_branch);
            }
        }
    }
    branch.unwrap()
}

#[test]
fn emitted_names_round_trip_and_are_git_branches_for_adversarial_task_matrix() {
    let mut tasks = Vec::new();
    // Every ASCII control, not only whitespace: embedded NUL/DEL and line
    // separators exercise different task_slug paths, but none may leak to a
    // filesystem component or the resulting branch.
    for byte in (0_u8..=31).chain(std::iter::once(127)) {
        tasks.push(format!("Repair{}checkout", char::from(byte)));
    }
    for separator in [
        "é", "e\u{301}", "修正", "💥", "\u{200b}", "\u{202e}", "\u{2028}", "\u{a0}",
    ] {
        tasks.push(format!("Repair{separator}checkout"));
        tasks.push(separator.repeat(64));
    }
    for punctuation in [
        "..", "@{", ".lock", "/", "\\", ":", "?", "*", "[", "~", "^", "`'\"",
    ] {
        tasks.push(format!("Repair{punctuation}checkout{punctuation}"));
    }
    // The slug's 48-byte bound and the emitter's smaller budget must compose
    // even if truncation lands on a separator, quote, or multibyte character.
    for length in [46, 47, 48, 49, 4096] {
        for tail in ["-remaining", "\"remaining", "💥remaining"] {
            tasks.push(format!("{}{tail}", "x".repeat(length)));
        }
    }
    let ids = ["", "synthetic\0id\n尾", "!?CASE-sensitive/id"];
    let mut checked_branches = HashSet::new();
    for task in tasks {
        for id in ids {
            let name = name_for_task(id, &task);
            assert_eq!(name_for_task(id, &task), name, "non-deterministic name");
            let branch = assert_graff_round_trip(&name);
            // Sanitization intentionally aliases some inputs. Ask Git once
            // per distinct output rather than spawning redundant subprocesses.
            if checked_branches.insert(branch.clone()) {
                assert_git_branch(&branch);
            }
        }
    }
}

#[test]
fn full_id_tails_remain_distinct_after_task_and_path_truncation() {
    // A shared prefix much longer than either naming budget catches accidental
    // truncation of IDs before hashing. Suffixes also distinguish raw bytes
    // that would disappear under punctuation/case/Unicode normalization.
    let prefix = "shared-SYNTHETIC-\0-尾/".repeat(256);
    let tails = [
        "", "a", "A", "-", "_", ".", "!", "\0", "\n", "\u{7f}", "é", "e\u{301}", "尾", "末",
    ];
    let task = format!("{}-with discarded task context", "x".repeat(47));
    let mut names = HashSet::new();
    for tail in tails {
        let name = name_for_task(&format!("{prefix}{tail}"), &task);
        assert!(
            names.insert(name.clone()),
            "distinct full-ID tails collided: {tail:?}"
        );
        assert_git_branch(&assert_graff_round_trip(&name));
    }
    assert_eq!(names.len(), tails.len());
}
