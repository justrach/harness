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
