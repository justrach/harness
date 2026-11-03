# Shared message queue

Ported from `jg-personal-cut` at `fd3f97b`. The queue spans the session document,
host executor, RPC, desktop composer and iOS client.

## Storage and ownership

`SessionDoc.queue` is a Loro movable list, separate from the immutable command
ledger and host-authored transcript. Each row holds a stable ID, editable text,
committed attachment paths, author/timestamps, an optional hold-until-turn-end
policy and an optional delivery gate. Real move operations preserve row identity
and converge across devices without delete-and-insert duplicates.

Clients can enqueue and reorder through their local document. Only the chat host
may deliver, remove or grant an edit lease. Desktop routes these actions with
`targetDeviceId`; iOS uses the host's relay. `WatchQueue` sends whole-list snapshots.
Failed or unacknowledged mutations trigger a fresh authoritative projection.

## Delivery

The host drains after document changes and session status changes. A per-chat
mutex serializes drains, explicit delivery, removal and protected edits.

| State | Automatic delivery |
| --- | --- |
| Idle | Start the head as the next turn. |
| Working or awaiting input | Keep queued messages until the turn ends. Steering requires an explicit action. |
| Head has attachments | Wait for a new turn that can accept files. |
| Head has an editing or review gate | Block delivery; do not skip the head. |
| Queue paused after Cancel or snapshot recovery | Wait for a successful explicit prompt or queue delivery. |

Explicit steering never interrupts. **Stop and send** interrupts the active
turn before dispatching the selected row. Desktop exposes these as separate
actions; iOS currently exposes only **Send now** (interrupt). Steering requires
host-advertised step-boundary support and a text-only row without an edit or
review gate. Unknown capabilities leave steering unavailable.

Dispatch retains the queue ID as the user-message ID. Failed dispatch restores
the row. An acknowledged removal cannot subsequently be consumed by this host.
Shutdown freezes open queues before stopping runs, and handles opened with
recovered queued work start paused.

## Protected editing

`BeginQueuedMessageEdit` acquires a host-issued generation under the drain mutex
and persists its delivery gate before acknowledging. Leases last 60 seconds and
clients renew every 20 seconds. Expiry changes the gate to `ReviewRequired`; it
never silently releases the row. Timers check both generation and deadline, and
snapshot recovery rearms all outstanding leases.

Finish supports commit, cancel, discard and release-unchanged. Commit checks the
lease generation and original text hash. Text, optional replacement attachments
and gate removal commit atomically. Stale/conflicting finishes preserve the row
for review. Desktop edits restore the previous composer draft after finishing;
the edited row retains its place in the queue.

## Composer and compatibility

Desktop defaults to Queue. Settings → Shortcuts → Messages while the agent is
working chooses Queue or Steer independently of the Enter/Cmd/Ctrl+Enter submit
preference. The composer offers Queue, Steer and Stop and send for a single
message without changing that default. When steering is unavailable, the
effective action is Queue and the composer explains why. iOS holds active-turn
messages until turn end and has no Queue/Steer preference.

With Enter-to-send and text in the composer, Ctrl+Enter (Cmd+Enter on macOS)
uses the opposite follow-up behaviour for one message while a turn is active;
Ctrl+Alt+Enter (Cmd+Option+Enter on macOS) remains a backwards-compatible alias.
On an empty composer, Ctrl+Enter (Cmd+Enter on macOS) still activates the newest
queued message, while the alias does nothing. With modifier-to-send and text in
the composer, Ctrl+Alt+Enter (Cmd+Option+Enter on macOS) uses the opposite
follow-up behaviour; it does nothing on an empty composer. Shift+Enter still
inserts a newline. Escape dismisses the follow-up menu before the optional
stop-agent shortcut can run.

The normal queue drain never steers. Composer steering first enqueues a durable
row, then explicitly asks the host to steer that row. If the host cannot promote
an accepted row, it remains recoverable in the queue; the composer does not
restore a duplicate draft. If the original turn has ended, steering starts the
next turn with the same message ID.
Cmd/Ctrl+Enter on desktop submits content, saves an active edit, or activates
the most recently added queue row when the composer is empty. The empty-composer
shortcut also works after clicking Send or the transcript; focused controls and
overlays retain first refusal, and a draft outside the editor is never submitted.
Queue clicks, including Remove, restore composer focus immediately. After the
latest row is removed, the shortcut targets the newest remaining row; it waits
while removal is pending. Command+Return on iOS activates the queue head. A
blocked shortcut target is never skipped and an empty modified submit never
stops the agent.

Queue submissions stay in the queue and do not create transcript bubbles. Steer
appears immediately at the conversation tail as a pending user message. If a
tool result is still in flight, it can finish above the pending message before
the host accepts the steer. Steering a queued row removes it from the queue and
shows the same pending message. The host writes the user message before the
continued assistant response, so the pending bubble becomes the confirmed
message in place and the continuation follows it. Failed enqueue restores the
composer draft; failed promotion removes the pending bubble and leaves the row
recoverable in the queue. Desktop retains the active reply's scroll runway and
anchors queued messages only when their stable IDs appear in the transcript.
Attachment paths remain separate from editable text and are expanded at
dispatch; legacy expanded rows are recognized to avoid duplicate trailers.
Queue attachments use committed host uploads.

Support is negotiated through `EngineInfo` and device-registry capabilities:
`message-queue-v1`, `message-queue-actions-v1`, `message-queue-attachments-v1`,
`message-queue-clean-attachment-text-v1` and `message-queue-edit-lease-v1`.
Missing capabilities default to unsupported, regardless of matching version
numbers. Older hosts retain the existing command-send path.

## Validation

- Document tests cover round trips, concurrent moves/edits and delivery gates.
- Engine queue tests cover drain serialization, awaiting-input behavior,
  steering, attachments, Cancel/restart recovery, protected edits and removal.
- Device-routing tests race local and remote consumers over the same row.
- Desktop tests cover action selection, modifier submission, optimistic echo,
  settings compatibility and transcript anchoring.
- `apps/ios/HarnessTests/MessageQueueTests.swift` covers projection, policy,
  attachment text, action acknowledgements and keyboard submission. Run with
  the iOS Xcode test suite on macOS.

Failed automatic dispatch pauses the queue before restoring its head, so the restore cannot trigger another delivery attempt. Fix the host configuration or connection, then explicitly send a queued row or a new prompt to resume. New queued turns use the current chat configuration.
