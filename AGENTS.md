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
