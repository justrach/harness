# Whale session blank-on-revisit regression

Base: `c24e0e26` (main, v0.2.76). Verified on Linux with synthetic local data;
`work-laptop` was not reachable from this environment, so this is not a claim
that its particular session or installed application was tested.

Two independently reproducible defects were found:

- `AppState::select_chat` discarded the transcript on every navigation. Even
  with a warm local engine, revisiting required a new full RPC reset before
  anything could render.
- `publish_messages_if_watched` checked the receiver count and cleared the
  mirror outside the lock used by `watch_messages`. A worker that observed
  zero receivers could mark dirty, let attach rebuild and clear dirty, then
  overwrite that freshly published transcript with an empty snapshot. A quiet
  document could remain empty until the next change.

The UI now moves recently viewed transcripts into a cache (12 inactive chats,
64 MiB estimated content budget). Navigation restores the destination in the
same state update, without waiting for RPC; fresh resets still replace it,
including authoritative empty resets. Restored content is classified as
historical so it does not replay entrance animations. Deleted chats and
account/runtime replacement clear cached data. Watches still end on navigation.
The engine serializes receiver checks, clearing, attach, and materialization
under the same mutex.

## Before/after proof

The new regression tests were retained while the affected production methods
were temporarily restored from the base commit (`select_chat`, `watch_messages`,
and the publication methods). Both failed:

```text
whale_transcript_revisit_is_synchronous_and_fresh_reset_wins ... FAILED
assertion `left == right` failed: revisit must render before any RPC frame
  left: 0
 right: 2000

transcript_attach_and_unwatched_clear_share_a_critical_section ... FAILED
unwatched clear escaped attach's critical section
```

With the fixes restored, both pass. The UI test switches away and back ten
times with 2,000 messages / 4,096,000 text bytes and no engine connection.
It checks synchronous availability, preservation of the original allocation,
historical classification, replacement by fresh data, and an empty reset.
The existing tool-group revisit view test additionally checks that rendered
rows exist before a new watch frame arrives, while preserving its historical
and live animation assertions.

Additional tests cover count/byte eviction, unloaded sessions, chat deletion,
account replacement, and a persisted 2,000-message snapshot opened with no edge
configured. One debug run measured 36.47 ms for offline cold open and 35.06 ms
for rebuilding the cleared mirror; these are observations, not timing gates or
laptop performance claims.

## Reproduce

```sh
cargo test -p zeron-engine --lib -- --nocapture
cargo test -p zeron-ui --lib --no-default-features -- --test-threads=1
```

Results: 196 engine tests and 1,075 UI tests passed. The focused transcript view
suite also passed all 107 tests. Changed Rust files pass rustfmt; `git diff
--check` passes.

A cache miss (first visit, process restart, or budget eviction) still reads the
local engine snapshot. The cache is a bounded presentation optimization, not a
replacement for durable local storage or authoritative synchronization.
