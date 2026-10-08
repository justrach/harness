# Harness

## Verification gates

Narrow gates for ACP adapter work (the work tree is often dirty — never run
`cargo fmt` repo-wide; format-check only the files you touched and disable
child-module traversal):

```bash
cargo test -p harness-adapters --test acp devin_        # Devin ACP integration tests
cargo test -p harness-adapters --lib acp::devin_models  # pure resolver/catalog tests
rustfmt --edition 2024 --config skip_children=true --check <touched .rs files>
```

`crates/harness/src/acp/mod.rs` has existing formatting differences. Leave
unrelated formatting unchanged and distinguish those differences from new ones.

Adding a composer slash command (a `WorkspaceCommand` variant) changes the row
counts asserted in `workspace_commands_preserve_native_commands_and_avoid_collisions`
(`crates/ui/src/composer.rs`): with a chat, and without one if the command is
offered in drafts. Update them in the same change and run
`cargo test -p harness-ui --lib workspace_commands`.

## Commits and pull requests

No agent or tool attribution anywhere: no `Co-Authored-By` trailers for an
agent or bot, no "Generated with …" lines, and no session links, in commit
messages, PR titles or bodies, or review comments. Commits carry only the
user's git identity. This applies to every agent working here (Devin, Codex,
Claude Code, graff and any other); turn off the tool's own attribution setting
if it adds one. Before pushing, check:

```bash
git log origin/main..HEAD --format=%B | grep -iE "co-authored-by|generated with" && echo "remove the attribution first"
```

If a pushed commit already has a trailer, reword it and force-push the branch
before it is merged. Once it's on `main`, removing it means rewriting `main`.

## Issue format: every report states its versions

This repository is public. Every issue, whether a person or an agent files
it, opens with this header. A report without versions can't be told apart
from a bug that a newer release already fixed.

```markdown
**Harness:** 0.2.109 (latest: 0.2.109)
**graff:** 0.0.302.25, the engine Harness runs
**App:** desktop | iOS 0.2.109 | Android 0.2.109
**Platform:** macOS arm64 | Windows x64 | Linux x64 | iOS 27 | Android 16 | ...

## Symptom
What went wrong, in generic terms, with the app's own error text verbatim.

## Repro
The smallest sequence of steps that shows it.

## Root cause
In code terms (`crate::module::function`), naming the tag or commit the
line numbers come from. Leave this section out if the cause isn't known.

## Fix
The expected behavior, or the proposed change.
```

- **Harness:** About Harness on macOS, or Settings → Devices. From a shell on
  macOS, run
  `plutil -extract CFBundleShortVersionString raw /Applications/Harness.app/Contents/Info.plist`.
  For the latest release, run `gh release view --repo justrach/harness --json tagName`.
- **graff:** Harness runs its managed copy, not the `graff` on `PATH`:
  `~/.harness/bin/graff --version` (macOS and Linux).
- **Engine bugs go to `justrach/codegraff`.** That covers tools, compaction,
  sessions, and model replies, and its issues use the same header.
- **If either version is older than the latest release**, check whether the
  release notes or a closed issue already cover the bug. Reproduce it on the
  latest release before filing, or say plainly in the header that it wasn't
  rechecked.
- **Search before filing.** Search open and closed issues by the error text.
  Comment on an existing issue only when you have a new repro or diagnostic.
- **What the header must not contain:** account details, private repository
  names, local paths, session ids, or transcript excerpts.

## Heavy builds

One compile at a time; watch `ps -o rss=` on long builds and stop anything
growing past ~40 GB. Never use Zig's self-hosted backend for large builds
(system-level rule, applies to zigrepper/codedb work in this tree).

## Imported conversations continue in graff

A conversation brought in from another agent (Claude Code, Codex, or any other)
continues in a graff session, on graff's configured provider (for example
Codegraff). The source agent's transcript is read-only input. Never re-launch or
`--resume` the source agent to continue it, and never spend that agent's
subscription or credits. "Import & resume" and "Continue in graff" both mean a
new graff session seeded with the imported conversation (#168).
