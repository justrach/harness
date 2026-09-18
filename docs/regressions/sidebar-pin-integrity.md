# Sidebar pin integrity

## Storage and scope

Synced profiles store the complete ordered pin list in the existing per-user/org registry preference row. Local profiles retain profile-keyed device preferences. Session rows and the activity ordering of unpinned sessions are never rewritten by a pin operation. The maximum is 200 pins, including pins hidden by filters or archiving.

Concurrent cross-device edits intentionally remain last-writer-wins on that complete list. Local serialization and acknowledgement revisions prevent same-client response races; they do not merge simultaneous edits from different desktops or iOS. Fractional indexing alone would not define conflict semantics for concurrent pin/unpin operations. Collaborative ordering is a separate protocol change, not a guarantee of this implementation.

## Authoritative cleanup and migration

Desktop UI chat and preference watches are independent. Receiving a chat frame, including an initial cached/empty frame, is never evidence that a remote pin was deleted. The engine reconciles pins under the registry lock, using chat rows and preferences from the same snapshot, only after an authoritative registry state has arrived. Archived chat rows remain eligible pins.

Legacy migration is conditional on the preferences row still being absent under that same lock. An existing empty row is an intentional unpin-all and is never replaced by local legacy pins. Migration filters and bounds the source in the engine and acknowledges only after persisting the registry snapshot. The desktop keeps its source until acknowledgement; a failed attempt retains it for the next engine attachment/application restart.

## Interaction and persistence

Menu and drop paths share validation of profile identity, preference readiness, ID validity and capacity before changing anything. Cached initialized preferences remain editable offline while the local engine is available. Unknown preferences are not editable. Rejected drops retain the existing animated return behavior, and successful drops do not replay the automatic activity-sort animation.

During dragging, previews only affect layout. Each accepted drop queues one full-list mutation. The latest queued list is an optimistic overlay, separate from the watch state; unrelated sidebar mutations cannot cancel its task. Writes are serialized per engine attachment. Failure removes the relevant optimistic entry and reveals the latest confirmed state once no newer operation remains, rather than restoring a stale pre-drag backup. Replies from an old profile, attachment or completed queue are ignored.

Engine acknowledgements and preference watches carry the same monotonically increasing attachment-local revision. Older watch frames cannot overwrite a newer acknowledgement, and older acknowledgements cannot overwrite newer remote state. These revisions are not stored in the shared registry and are not ordering keys for sessions.

A confirmation timeout is not proof that a write was rejected. It discards queued, unsent edits with a notice instead of submitting them behind an operation with uncertain execution order. The interface falls back to the latest confirmed state and continues accepting authoritative watch updates, including a later confirmation of the timed-out operation. Further edits wait until the original request resolves or the engine attachment is replaced, so even a fresh drop cannot overtake that uncertain write.

## Regression commands

```sh
cargo test --locked -p zeron-doc --lib sidebar_
cargo test --locked -p zeron-engine --lib sidebar_preferences
cargo test --locked -p zeron-ui --lib pinned_session_tests -- --test-threads=1
```

Coverage includes reversed stream arrival, absent versus explicitly empty preferences, archived/deleted IDs, unsynced menu/drop parity, full-capacity drops in local and remote profiles, offline readiness, invalid lists, operation/profile/attachment boundaries, ordered pending writes, rejection recovery and stale watch/ack delivery. Existing native drag tests cover empty Pinned targets, cross-section gaps, return animation, successful-drop animation suppression and unchanged normal activity ordering.
