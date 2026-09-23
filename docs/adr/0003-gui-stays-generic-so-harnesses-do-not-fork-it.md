# ADR 0003: Keep the GUI generic so a harness does not fork it

- Status: Accepted
- Date: 2026-09-23

## Context

People like this desktop GUI and want to put their own coding-agent harness under it. A harness here is the program that actually runs the agent (`claude`, `codex`, `graff`, a personal ACP binary). The GUI is the shell: composer, transcript, settings, files, and updates.

Forking the shell once per harness would freeze each fork. Theme work, GPUI fixes, and the updater would have to be copied by hand, and a harness author would own a GUI they did not come here to maintain. The shell also vendors GPUI (Apache-2.0, recorded in `THIRD_PARTY_NOTICES.md`) so it can move without pulling a GPL crate graph. That vendored tree only stays honest if one product updates it, not a pile of renamed forks.

The installed base still launches a binary named `zeron`, reads `ZERON_*`, and updates through the existing installer layout. Renaming those in the same breath as the display name would strand the update path that is supposed to keep the GUI current.

## Decision

The GUI is the shared product. A person's harness is not a fork of it.

- The shell discovers an agent on the device (PATH, plus a documented `*_EXECUTABLE` override) and drives it. Settings → Agents says so, and names the override when the CLI is missing, so a custom build does not require reading the adapter source.
- A new harness joins by adding an adapter (`HarnessId`, an ACP spec or a native driver, a blurb, and an install one-liner only when that command has been verified). It does not copy the shell, the theme system, or the updater.
- Display name, bundle id (`harness.codegraff.app`), and conversation links (`harness://`) are Harness. The `zeron` binary name, `ZERON_*` variables, and installer roots stay until a migration can read both the old and new locations. That split is what lets the GUI update without breaking a running install.
- Third-party editor foundations stay vendored and license-tagged in `THIRD_PARTY_NOTICES.md`. They are not rebranded as if they were this product's source.

## How it stays up to date

1. **GUI.** Ship updates through the existing updater (`Harness.app` on macOS; the headless tarball on Linux). The updater still accepts a tarball that contains the old `Zeron.app` name so an install from before the rename can move forward once.
2. **Someone else's harness.** That CLI updates on its own schedule. The GUI does not pin it. The next probe of PATH (or the `*_EXECUTABLE` override) picks up the new binary. A harness author does not wait on a GUI release to ship their agent, and a GUI release does not require them to rebase a fork.
3. **Vendored GPUI.** Bump `vendor/zui` and `vendor/gpui-component` on purpose. Re-check that every vendored crate is still Apache-2.0 (no `github-download` feature, no `util` dependency on the GPL `path` crate). Keep `license = "Apache-2.0"` on each crate and refresh the row in `THIRD_PARTY_NOTICES.md` if the source revision changes.
4. **What not to combine with a GUI refresh.** Do not rename the `zeron` binary, `zeron.service`, or `~/.zeron` installer root in the same release. Those names are the update channel. Change them only with a reader that accepts the old path and a note in the installer.

## Consequences

- A harness author gets a working composer without maintaining GPUI, themes, or an updater.
- Built-in agents and a custom binary share one settings page and one launch probe.
- The shell cannot grow a per-harness special case without an adapter change in this repo. That is intentional: the special case belongs next to the other adapters, not in a fork.
- Existing installs keep updating because the binary and installer paths did not move.
- Saved theme ids `zeron-dark` / `zeron-light` still resolve. New worktree branches use `harness/`; branches already named `zeron/` are still treated as ours so old checkouts are not orphaned.
