# Native Nano source-control demo

Run from this checkout on macOS:

```sh
python3 scripts/run-nano-demo.py
```

That command builds the real engine and Nano, creates a **fresh synthetic session**,
then opens a separate **Harness Nano Demo.app**. It never opens or stops the installed
Harness app. Requirements: Python 3.9+, Node 22+ with built-in `WebSocket`, Apple's
command-line tools, and the Rust/Zig toolchains used by this checkout. No Python or
npm packages, account, provider key, GitHub login, or project configuration are needed.
Compilation is offline too, so the checkout's ordinary Rust/Zig dependencies must
already be available in the installed dependency caches (as after a normal build).

Both builds run sequentially through `scripts/heavy-build.sh`: engine `app-dev`,
Nano `ReleaseSafe` (matching the normal desktop build's safety checks). Compiler outputs and Zig caches go in this session's `build/`;
the build reads the normal Cargo dependency cache and copies cached Zig package
sources into the session. Cargo uses `--offline`, and both compiler trees run
under a network-denying sandbox. Missing dependencies fail locally rather than
fetching anything. Build failures leave local `build/0.log` / `build/1.log`, not a
half-open preview.

## Already built / hidden validation

To use this checkout's existing `target/debug/harness` (or
`$CARGO_TARGET_DIR/debug/harness`) and `apps/nano/zig-out/bin/harness-nano`:

```sh
python3 scripts/run-nano-demo.py --no-build
```

For a different **checkout-local** engine build:

```sh
python3 scripts/run-nano-demo.py --no-build --engine target/app-dev/harness
```

`--nano PATH` can likewise select a checkout-local Nano executable, with
`--no-build`. Use binaries from the same revision/version; an old engine can render
an honest version-mismatch notice. The launcher does not conceal it or attach to
an existing daemon. Build both binaries before reviewing final visuals.

**No windows are shown when `--snapshot` is supplied:**

```sh
python3 scripts/run-nano-demo.py --no-build --snapshot git-history.png
python3 scripts/test_run_nano_demo.py
```

A snapshot name is **relative to the fresh session's `snapshots/` directory**;
absolute paths and `..` are refused. For example, the command prints:

```text
Demo session: <checkout>/.graff/nano-demo/<timestamp>/
PASS: real engine history (50 + 6), three completed mock turns, hidden native PNG, unchanged Git state.
Snapshot: <checkout>/.graff/nano-demo/<timestamp>/snapshots/git-history.png
```

Hidden validation starts the real isolated engine, creates the project/chat over
local WebSocket RPC, waits for all three mock turns, checks both Git history pages,
renders the actual native client to PNG, verifies HEAD/index/tracked diffs/status
are unchanged, and stops its engine. It is a functional smoke test, **not a claim
of 120-fps scrolling**. Scroll performance needs separate profiling.

## What to try

The app starts with **Synthetic Studio**, **Synthetic demo · Git history + scrolling**,
and the native **Git history** panel already open (`HARNESS_NANO_PANELS=git-history`).

- Browse 56 fictional commits on `demo/native-history`, four ahead of local `main`.
  Try **Next** / **Previous**; the native list pages at 50 entries.
- Click **Changes** to inspect a staged palette edit, an unstaged README edit and
  an untracked next-steps document in the disposable repository.
- Scroll the longer conversation next to history. Three completed turns use the
  existing mock agent, with four script repetitions plus its code/table options.
  Text and tool cards are **scripted fixtures**: command-looking tool cards do
  **not** run those commands. Additional messages still go to the mock agent.
- Add **Session pull requests** from the panel picker to see the native empty
  state. **There is no remote or `gh` authentication. This is not live GitHub
  integration.** No synthetic PR is presented as real, and no PR fixture/backend
  hook is injected. Merge and GitHub writes are not demonstrated.

The underlying client/engine are unchanged; this launcher adds no plugin runtime,
UI source changes or integration API. Native history reads real Git objects,
not a screenshot or mock history response.

## Isolation and stopping

Every launch creates a new owner-only timestamp directory under
`.graff/nano-demo/`. Runtime HOME, XDG directories, temporary files, app data,
repository, logs, local IPC port and bundle all belong to that directory. The
runtime environment is constructed from scratch, not copied from your shell.
LaunchServices goes through an `env -i` wrapper too. Credentials, personal config,
login-shell startup, auto-updates and the normal engine's IPC are not inherited.
Only generated demo logs are read/written; no personal logs are imported.

Both engine and Nano run under a macOS `sandbox-exec` profile which permits only
loopback network traffic and execution of the exact demo binaries and Git. It
blocks external network connections, `gh`, shells, terminal actions and real
agent executables. The demo has no remote, Git filters or hooks. This is a
convenience demo isolation layer, not a general-purpose hostile-code sandbox:
it does not attempt to remove every file picker or native client control.
Do not import personal projects/accounts into it.

The separate bundle ID is `com.codegraff.harness.nano-demo`; the launcher opens it
only when explicitly invoked **without** `--snapshot`. Session metadata is in
`session.json`. Stop the directory printed by the launch command:

```sh
python3 scripts/run-nano-demo.py --stop .graff/nano-demo/<timestamp>
# Or select the most recent session with metadata:
python3 scripts/run-nano-demo.py --stop latest
```

Stopping verifies each recorded PID, process start time and exact owned executable
command. A reused PID or different command is **not signalled**. It never uses
`pkill`, global daemon shutdown, process-name matching, or a port as ownership.
Closing the demo window alone need not stop its headless engine; use `--stop`.
Snapshot mode stops and reaps its engine automatically, including on failure.

Rerun the launcher to reopen a **fresh** demo; do not open an old stored `.app`
after stopping its engine. Prior demo edits are not copied to the next launch.
Old directories are retained for your inspection; the launcher never deletes
an earlier demo or the user's application data.

## Verification coverage

`test_run_nano_demo.py` checks synthetic Git history/changes, environment isolation,
path confinement, bundle wrapper sanitization, serialized/local build commands,
shell denial by the real macOS sandbox, Node bootstrap syntax, and conservative
process/session ownership. It does not compile, open windows or contact a service.
The `--snapshot` command is the end-to-end check against already-built binaries.
