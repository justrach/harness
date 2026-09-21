# Antigravity stabilization status

Work stopped at the requested disk threshold: root free space reached 9.7 GB
while engine tests were linking. Only this task's build processes were stopped;
other builds and shared cache contents were left alone. Free space recovered to
19 GB after stopping. These commits are work in progress, not fully validated.

Commits: `52af2728` (harness), `3f8f159b` (engine and UI).

1. Implemented plain enablement in `3f8f159b`. Toggle calls only SetHarnessEnabled.
   Full UI interaction coverage remains outstanding.
2. Existing dimming/install hint retained. Explicit sign-in visibility covered by
   `explicit_sign_in_requires_installed_antigravity` (added, not run).
3. Implemented CLI/override/completed-install detection in `52af2728`.
   `antigravity_cli_path_controls_detection_and_enablement` and its subprocess
   test added in `3f8f159b`, not run. Dedicated completed-install and login-shell
   detection tests remain outstanding.
4. Implemented detection-based enablement in `3f8f159b`. Legacy optedIn is ignored;
   disabled remains authoritative. Test:
   `antigravity_detection_ignores_legacy_opt_in_and_preserves_opt_out` (not run).
5. Removed disable/logout coupling in `3f8f159b`. Test:
   `antigravity_disable_does_not_launch_the_server` (not run). Registry last-agent
   guard remains in place.
6. Implemented explicit Sign in and removed Enabling phase in `3f8f159b`.
   Remote-device browser restriction remains in start_sign_in. Logout restored in
   `52af2728`; its assertion passed in the initial suite and the test was later
   renamed `antigravity_commands_include_logout`. UI phase/visibility tests have
   not run; end-to-end action sequencing coverage remains outstanding.
7. Existing lazy installation/background discovery retained. `52af2728` converts
   Antigravity spawn/install failures into an Errored Done. Existing downloader
   includes URL/reason. A dedicated download-failure event test is still needed.
8. Implemented Settings → Agents → Sign in guidance in `52af2728`.
   Existing new-session test passed. Added
   `antigravity_load_and_prompt_auth_expiry_point_to_sign_in` (not run).
   No authenticate calls added to runs or probes.
9. Removed obsolete registry and logout comments and updated sign-in action docs.
   Existing Settings module docs already describe detection-based enablement.
   README/docs search found no old Antigravity enablement instructions.
10. A: Not done. No cold/warm measurement, so discovery budget remains 10 seconds;
    handshake remains 120 seconds. Probe now resolves/installs through the harness
    and records initialize and session/new elapsed times, but was not executed.
11. B: Implemented Unix BROWSER suppression in `52af2728` for run/discovery spawns
    and the probe. Fixture now checks the run's BROWSER value (not rerun).
    Real server/browser behavior is not verified. Minimal overlap with #452.
12. C: Existing generic cancellation fixture passed. Added
    `antigravity_wedge_emits_one_interrupted_done` with default 2s/3s graces and a
    6s outer bound (not run). No process-signalling code changed.
13. D: Existing stop_outcome completes end_turn regardless of output. Chose to keep
    silent completion without an invented assistant message. Added
    `antigravity_empty_reply_completes_once` (not run).
14. E: Implemented auth-required load-error propagation in `52af2728`, preventing
    fresh-session fallback. Covered by the new load/prompt fixture test (not run).
15. F: Existing model rejection, grouping, and newer Flash catalog tests passed.
    Added `antigravity_unknown_saved_model_fails_clearly` (not run).
16. G: Already wired: spawn_agent captures StderrTail; handshake crash/timeout paths
    append it and session teardown uses it. Code inspection only for this spec;
    dedicated Antigravity stderr failure tests remain outstanding.
17. H: Verified live with the requested gh registry API query: version remains
    1.1.1. No version or digest changes.

Validation commands (all cargo commands used the shared CARGO_TARGET_DIR and
TMPDIR=/home/ubuntu/codex-runs/agy-scratch):

- cargo test -p zeron-harness: passed on the initial edit snapshot, 39 ACP
  integration tests and 180 unit tests plus the other harness suites. This does
  not validate later fixture additions or the later spawn-failure change.
- cargo test -p zeron-engine: stopped during compilation/linking at disk threshold.
  Existing unused-variable warning at tests/restart_resume.rs:459.
- cargo test -p zeron-ui --lib settings::: queued, stopped before compilation.
- cargo test -p zeron-ui --lib pickers::: not run.
- cargo clippy -p zeron-harness -p zeron-engine -p zeron-ui --all-targets: not run.
- git diff --check: passed before commits.
- cargo run -p zeron-harness --example antigravity_acp_probe: queued behind the
  engine build, stopped before execution. No real download or server handshake.

Live verification was limited to the registry version query. No cold/warm
numbers are available. Google sign-in cannot be completed without an account.
No test flakes were observed in the completed harness run.

Follow-ups: finish the listed test gaps, run all required commands against the
final commits, measure the real server and set a justified per-spec discovery
budget. Check immediate server exit racing an authentication-error response too.
#452 overlaps browser suppression and the still-outstanding discovery budget;
echoed system-message stripping was untouched. #475's temporary-directory cleanup
was not implemented. Pi and generic process-signalling code were not changed.
No push, PR, or merge was performed.
