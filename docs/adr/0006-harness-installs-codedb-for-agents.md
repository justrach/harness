# ADR 0006: Harness installs codedb for its agents

- Status: Proposed
- Date: 2026-10-09

## Context

Agents running under Harness are often told to use codedb for code search and navigation, by project instructions or by the user's own. On a computer that never had codedb installed, a graff session reported that "codedb is not on `PATH`" and fell back to slower tools. That computer was a second desktop reached through the device relay. Cloud sandboxes and other `harness headless` hosts have the same gap.

Harness already keeps graff for its agents, in two layers (`crates/harness/src/graff_bundle.rs`):

- **Bundled:** `Harness.app/Contents/Resources/bin/graff`, fixed per app build.
- **Managed:** `~/.harness/bin/graff`. It is seeded from the bundle and replaced from codegraff's GitHub releases. Each archive is checked against the release's `SHA256SUMS`, and the binary must run `--version` before it is renamed into place.

The managed-graff updater runs only in the desktop app. It starts from `install_path_shims_and_auto_update_graff`, and only when the app bundle ships a graff.

codedb publishes one raw binary per platform on its GitHub releases, about 8 MB each: `codedb-darwin-arm64`, `codedb-darwin-x86_64`, `codedb-linux-arm64`, `codedb-linux-x86_64` and `codedb-windows-x86_64.exe`. Each release also has a `checksums.sha256` file in `<sha256>  <file>` form. Releases were frequent in late September (v0.2.5857 to v0.2.5860 in two days).

Agents find tools through the `PATH` that `compose_path` builds for every agent process. It is, in order: the agent's own executable directory, Harness's `PATH`, then the login shell's `PATH`, with duplicates removed (the first occurrence wins). A graff session therefore puts `~/.harness/bin` first.

## Options

**A. Leave codedb to the user.** Document it and let each computer install it. Nothing to maintain, but sandboxes and remote hosts keep failing until someone notices.

**B. Bundle codedb in the app.** Ship it in `Contents/Resources/bin` like graff. It works offline from first launch, but it covers only the desktop app (headless hosts have no bundle), grows every download, and pins codedb to Harness's release cadence.

**C. Install a managed codedb at runtime.** Download codedb's latest release into a Harness-owned directory, verify it, and keep it current. This covers the app and headless hosts alike and adds nothing to the download. Until the first check completes (30 seconds after start, with the network up), codedb is missing.

**D. B and C together**, as graff does. Offline first launch on the desktop, at the cost of B's size and release coupling.

## Decision

Option D, the same two layers as graff (`crates/harness/src/codedb_bundle.rs`):

- **Bundled by default:** `scripts/package-macos.sh` puts `codedb-darwin-<arch>` from codedb's latest release (checked against `checksums.sha256`) in `Contents/Resources/bin/codedb`, and signs it with Harness's Developer ID when it doesn't carry one. `CODEDB_BINARY` overrides the download, like `GRAFF_BINARY`. At start, `seed_managed` copies it into place when the managed copy is missing or older, with no network needed.
- **Location:** `~/.harness/tools/bin/codedb` (`codedb.exe` on Windows). It is not `~/.harness/bin`: a graff session puts that directory first on `PATH`, so a codedb there would shadow the user's own.
- **Install and update:** `ensure_managed` reads `/releases/latest` and installs only when codedb is missing or older (dotted numeric compare). It downloads the platform asset and `checksums.sha256` from the same release, requires the SHA-256 to match, writes the file beside the target, requires `--version` to run, then renames it into place. A failure at any step leaves the installed copy untouched. Unsupported platforms are skipped.
- **When:** the desktop app (on its own thread) and `harness headless` (on the engine's runtime) run `keep_current`. It seeds from the bundle at once, waits 30 seconds, then checks the releases every 6 hours. `HARNESS_CODEDB_AUTO_INSTALL=0` turns it off.
- **Discovery:** `compose_path` appends `~/.harness/tools/bin` after every other directory. A codedb the user installed is found first, and Harness's copy fills the gap.

## Consequences

- The macOS app has codedb from its first launch, offline included. Hosts without the bundle (`harness headless` on Linux, cloud sandboxes) get it about 30 seconds after start, once the network is up.
- The macOS download grows by codedb's binary, about 8 MB.
- The trust model matches the managed graff's: GitHub's TLS plus a checksum file from the same release. This catches corrupted or truncated downloads but not a compromised release. Signing both tools' releases would be a separate decision.
- Each Harness host makes one unauthenticated GitHub API call every 6 hours for codedb. With graff's checks (hourly, plus at most one every 10 minutes when graff sessions start), a host stays under 10 calls an hour, well inside GitHub's anonymous limit of 60.
- A user who installs codedb themselves keeps control: theirs comes first on `PATH`, and the opt-out stops Harness from downloading at all.
- There is no Settings row or notice for codedb yet. Its install and update show up only in the log (`codedb installed from its GitHub release`). If users need to see or pin the version, add a row next to graff's in Settings → Agents.
- The Linux tarballs and the Windows zip don't bundle codedb yet. They don't bundle graff either. Add both to `package-linux.sh` and `package-windows.ps1` together if offline first launch matters there.
- Tests: unit tests cover version parsing, checksum lookup and refusing a binary that won't run. An ignored network test installs the real latest release into a throwaway `HOME`: `HOME=$(mktemp -d) cargo test -p harness-adapters --lib codedb_bundle -- --ignored`.
