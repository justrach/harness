# Cursor authentication-error follow-up

Investigated against main `10c9d3e2` using the supplied redacted JSONL export.
No user prompt, tool argument, output, credential, or original transcript is
checked into this repository.

## What the export establishes

The export has 13,915 events. At sequence 6177, after extensive reasoning and
tool activity, Cursor returns:

> Authentication error If you are logged in, try logging out and back in.

The following run resumes the same agent and completes at sequence 12085.
Several further turns also complete. The abandoned-run recovery is therefore
working in this incident, but it did not prevent the authentication failure.

At sequence 13915 a separate run using Grok exits with code 1. Its only retained
diagnostic is the SDK's minified `index.js:1` location. This does not identify
the exception. The earlier authentication failure used `claude-fable-5-1`.

There are no timestamps, request IDs, SDK error codes, or underlying engine
logs in the export. It cannot establish a root cause, credential expiry,
which service rejected authentication, whether a login occurred between runs,
or whether the two failures share a cause. Do not describe this as a proven
credential-cache bug or claim the upgrade below fixes the provider error.

## Changes and rationale

- Update the pinned Cursor SDK from 1.0.28 to 1.0.31, the current npm version
  at investigation time. Public run/store APIs remain compatible in testing.
- Preserve allowlisted SDK error codes and request IDs from send/wait errors
  and failed run results. These were previously discarded. Do not serialize
  causes, headers, credentials, or SDK configuration objects.
- Catch SDK background promise rejections and uncaught exceptions at the
  process boundary. Send the actual error through the existing fatal protocol,
  then shut down with a two-second hard deadline. Never continue using the
  faulted process. This avoids Node's minified source dump obscuring the error.
- Add the exact reported error, an unhandled rejection, and an uncaught
  exception to production-shim regression coverage. Each must retain useful
  diagnostics, omit a secret planted in the cause object, and permit a fresh
  process to resume the same history. The prompt ledger must show only the
  failed request and the explicitly requested continuation, with no replay.
- Allow the opt-in live probe to choose its model with
  `ZERON_CURSOR_TEST_MODEL`.

## Validation and limits

See [results.json](results.json) for measured results. Cursor CLI update reported
already current at `2026.09.15-d2fe57e`; the actual harness uses the SDK separately.

The live `claude-fable-5-1` attempt was rejected with **Model Blocked**, asking
for administrator enablement. Its provider request ID was preserved by the new
error path. This is an account access restriction, not a passing auth reproduction.
Grok live turns and Composer fault recovery are tested separately.

The original mid-turn authentication rejection has **not** been reproduced or
shown eliminated. Additional engine diagnostics/request IDs from an affected
run are needed. Automatically resending a tool-using prompt would risk duplicate
side effects and is intentionally not introduced. Existing recovery preserves
saved checkpoints; it cannot manufacture provider state that was never saved.

Reproduce without credentials:

```sh
cargo test -p zeron-harness
```

Opt-in live checks (use provider quota and disposable workspaces):

```sh
cargo run -p zeron-harness --example cursor_stability_probe -- models 1000
ZERON_CURSOR_STATE_DIR=$(mktemp -d) cargo run -p zeron-harness --example cursor_stability_probe -- sessions 6
ZERON_CURSOR_STATE_DIR=$(mktemp -d) ZERON_CURSOR_TEST_MODEL=grok-4.6 cargo run -p zeron-harness --example cursor_stability_probe -- parked 6
```
