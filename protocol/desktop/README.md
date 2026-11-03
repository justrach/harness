# Desktop parity vectors

The files here pin what the Harness desktop shell (Rust) and harness-nano (Zig, `apps/nano`) must agree on, as data.
Each side runs its own test against the same files, read from the repository at test time, so neither can drift
without a test failing.

| File | What it pins | Rust runner | Zig runner |
| --- | --- | --- | --- |
| `rules.json` | session times ("now", "5m", "3d"), tool chips and their detail, tool group summaries ("Ran 2 commands · 1 failed"), a session row's status, the sidebar's order | `crates/proto/tests/desktop_vectors.rs` | `apps/nano/src/parity.zig` |
| `transcript.json` | how `WatchDocMessages` frames apply (reset, upsert after an anchor, append with its length, remove, count), and which ones must be refused | `crates/doc/tests/desktop_transcript_vectors.rs` | `apps/nano/src/parity.zig` |
| `theme.json` | the Codegraff Dark and Light roles (surfaces, text, accent and its glyph tones, status, borders, hover, diff, terminal colours) | `crates/theme/tests/desktop_theme_vectors.rs` | `apps/nano/src/parity.zig` |
| `requests.json` | every request harness-nano sends the engine, as exact JSON | `crates/engine/tests/desktop_requests.rs` | `apps/nano/src/parity.zig` |

Run them:

```sh
cargo test -p harness-proto --test desktop_vectors
cargo test -p harness-doc --test desktop_transcript_vectors
cargo test -p harness-theme --test desktop_theme_vectors
cargo test -p harness-engine --test desktop_requests
cd apps/nano && zig build test
```

CI runs the Rust half in `ui-tests.yml` (the "Desktop parity vectors" step).

## The expected values

For `rules.json`, `transcript.json` and `theme.json` the expected values describe the desktop: the Rust runners check
them against harness-proto, harness-doc and harness-theme, and the Zig runner checks the port gets the same answers.

`requests.json` goes the other way. `zig build vectors` writes it from the functions harness-nano builds its requests
with (`apps/nano/src/requests.zig`, listed in `parity_requests.zig`). The Zig runner checks the builders still produce
exactly that JSON. The Rust runner sends each request, in order, to a real engine with the mock agent, and fails on
`bad params` or `unknown method`; any other answer (a queued row that isn't there, a terminal that doesn't exist)
means the engine understood the request. `$DEVICE` and `$DIR` stand for the engine's device id and the project's
folder.

## Changing a rule

Change the vector, then every runner it breaks, in the same pull request. When a request changes on purpose, run
`zig build vectors` in `apps/nano`, then the Rust runner, which tells you whether the engine still reads it.
