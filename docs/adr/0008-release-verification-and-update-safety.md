# ADR 0008: Release verification and desktop self-update safety gates

- Status: Accepted
- Date: 2026-11-10

## Context

Two consecutive desktop hotfix releases (`v0.2.175` and `v0.2.177`) had to be pulled immediately after publication due to launch-time failures that unit tests (`zig build test`) did not catch:

1. **`v0.2.175` (startup crash under `-Doptimize=ReleaseFast` multi-module split)**:
   - `apps/nano/build.zig` split `src/main.zig` into two separate Zig modules (`core` and root `exe`), each importing `std` and `nanoui`, and compiled the release binary with `-Doptimize=ReleaseFast`.
   - Under `zig test` (`Debug`, single module) every test passed, but the packaged `ReleaseFast` binary crashed 1.5 seconds after launch when the background `release.zig` `NSURLSession` callback invoked `std.log.info` across duplicated module instances with runtime safety checks stripped.

2. **`v0.2.177` (1-second open/close relaunch loop)**:
   - `apps/nano/build.zig` read `../../Cargo.toml` inside `workspaceVersion(b)` during Zig's cached `configure` phase (`b.addOptions()`) without registering `../../Cargo.toml` as a `WriteFiles` build input. As a result, `.zig-cache` kept `@import("build_info").version` frozen at `"0.2.175"` inside `harness-nano` even when `Cargo.toml` and `Contents/MacOS/harness` were `"0.2.177"`.
   - On launch, `harness-nano` (`0.2.175`) fetched `manifest.json` (`0.2.177`), concluded an update was available (`0.2.177 > 0.2.175`), and ran `/Applications/Harness.app/Contents/MacOS/harness update` in the background.
   - Because `Contents/MacOS/harness` was already `0.2.177`, `harness update` printed `"Harness 0.2.177 is up to date"` and exited `0` in ~100 ms.
   - `appUpdateWorker` (`apps/nano/src/view_updates.zig`) treated *any* exit code `0` as a newly staged update (`app_ready = true`), and `appUpdateDelivered` immediately invoked `restartIntoUpdate` (`std.process.exit(0)` + `/usr/bin/open /Applications/Harness.app`) because `restart_to_install_updates` defaulted to `true`. The app opened and closed every second in an infinite loop.

## Decision

Every desktop build and release must enforce four invariants in code and in packaging scripts:

1. **Single-root-module `ReleaseSafe` build (`apps/nano/build.zig`)**:
   - `harness-nano`, `harness-nano-snap`, and `harness-nano-profile` compile directly from a single root module (`src/main.zig`, `src/snap.zig`, `src/profile.zig`) so `std` and `nanoui` exist once in the binary.
   - Production desktop binaries compile with `-Doptimize=ReleaseSafe` (never `ReleaseFast`), keeping bounds, null, and unreachable traps active.

2. **Cache-tracked version embedding (`apps/nano/build.zig` & `scripts/package-macos.sh`)**:
   - `build_info` must never use a configure-only file read (`std.Io.Dir.cwd().readFileAlloc` into `b.addOptions()`), because Zig's build runner caches the configure graph when `build.zig` is unchanged.
   - Instead, `apps/nano/build.zig` copies `../../Cargo.toml` via `b.addWriteFiles().addCopyFile(b.path("../../Cargo.toml"), "Cargo.toml")` and parses `@embedFile("Cargo.toml")` at `comptime` in `build_info.zig`. Zig hashes `../../Cargo.toml` on every build invocation.
   - `scripts/package-macos.sh` verifies before signing that both `"$APP/Contents/MacOS/harness" --version` and `strings "$APP/Contents/MacOS/harness-nano"` contain the exact `$VERSION` from `Cargo.toml`. Any mismatch aborts packaging immediately.

3. **Self-updater state-machine guards (`apps/nano/src/view_updates.zig`)**:
   - `appUpdateWorker` only sets `app_ready = true` when `harness update` exits `0` **and** its stdout confirms a bundle swap (`"relaunch Harness to finish"`). When `harness update` prints `"is up to date"`, `app_ready` and `app_relaunch_when_ready` are cleared (`false`).
   - `appUpdateDelivered` only calls `restartIntoUpdate` (`std.process.exit(0)`) when `relaunch == true` (an explicit user click on `"Update to v…"` or `"Restart to update"`). Background release checks may stage the update and surface the `"Restart to update"` pill in the sidebar and `Settings › Devices`, but must never kill an active window automatically on startup.

4. **Mandatory 3-second live-bundle smoke gate (`scripts/package-macos.sh`)**:
   - Before notarizing or uploading a release, `scripts/package-macos.sh` launches the signed `$APP/Contents/MacOS/harness-nano` against an isolated temporary `HOME` and port (`HARNESS_IPC_PORT=49877`) for 3 seconds (long enough for window creation, Metal initialization, engine spawn, and the initial GitHub `manifest.json` release check to complete) and asserts `kill -0 $SMOKE_PID`.
   - If the process crashes or exits early within those 3 seconds, packaging fails before notarization or release publication.

## Consequences

- Stale `.zig-cache` version strings can no longer ship inside `harness-nano` or diverge from `Contents/MacOS/harness`.
- Background update checks never force-quit a live window on launch.
- Both the `v0.2.175` startup crash and the `v0.2.177` relaunch loop are caught automatically by `scripts/package-macos.sh` before any tag or release asset reaches GitHub.
