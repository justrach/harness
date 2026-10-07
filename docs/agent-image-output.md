# Agent image output (`show_image`)

Agents running inside a Harness chat can publish an existing raster image from
their workspace inline into the conversation, where it renders with the same
attachment cache and lightbox as generated images.

## Tool contract (MCP)

`show_image` is listed only when the MCP server is running inside a chat (an
injected origin). The destination is always that origin chat - there is no
chat or device selector, and unknown arguments are rejected.

| Field | Type | Notes |
| --- | --- | --- |
| `path` | string, required, 1-4096 chars | Relative to the active workspace, or absolute inside it. |
| `caption` | string, optional, at most 200 chars | Short preview label. |

Success returns `{ "attached": true, "id", "name", "mimeType" }` - never the
original path, bytes, or base64. Failures surface as a normal tool error
(`isError`). Invalid files or inactive runs do not publish an image.

## Scope and limits

- The file must live inside the **current run's working directory** - the
  same jail, pinned-directory traversal, signature sniffing, and 24 MiB cap
  as the generated-image importer. Relative paths resolve under the run cwd;
  traversal outside the workspace, symlink escapes, and non-regular files are
  rejected. PNG, JPEG, WebP, and GIF signatures are accepted; the UI also
  validates decoding within its image limits. The extension alone is not
  sufficient. No URLs, no SVG, no data URIs.
- A copy is attached. The managed file persists in the profile's uploads
  store, so the image still renders after the source is deleted and after
  restart.
- A run must be **actively working**. Idle/parked, interrupted, finished, or
  absent runs reject the call; nothing is queued.
- The call does not capture the screen, generate an image, send a message, or
  start another turn.

## Ordering and acknowledgement

`show_image` travels the run's normal sequential pipeline (RPC `ShowImage`
to a bounded mailbox inside the run task). The tool call resolves only after the
file is imported, journaled, and synced into the chat document -
`attached: true` means **accepted into the host's journal and doc**, not
"already rendered": a connected UI may materialize it a moment later. A failed
journal append or doc write reports an error rather than success. These storage
steps are not one transaction: a storage error can leave a managed copy or
partially published record, so an error does not guarantee rollback.

Each call mints a fresh request id server-side; the client's single reconnect
retry re-sends identical params and dedupes to one image - no duplicates.

## Status

Implemented and test-verified; ships with the MCP tool catalog, not separately toggleable.
