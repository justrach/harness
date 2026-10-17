# ADR 0006: TUI resume keeps the agent's native session identity

- Status: Accepted

## Context

The terminal client's bridge held sessions only in connection memory, returned
an empty saved-session list, and did not supply a session name. Enabling the
client's existing `/resume` command alone would leave an empty picker and lose
conversation continuity after exit.

## Decision

Persist each TUI conversation in the terminal client's config home. Keep the
readable name, agent, model, working directory, native resume token, and visible
turns together. Derive the initial name from the first prompt, without making
an extra model request. Use atomic, owner-readable files and checkpoint the
native token as soon as the agent reports it.

The bridge implements the client's existing thread list, read and resume
protocol. The frontend uses that list for keyboard and mouse selection and
shows the name through its existing status-line support. Replayed transcript
items are presentation history, never a replacement prompt sent to the agent.
The next turn continues with the saved native token and working directory.

## Constraints

This is TUI-owned history, not the desktop workspace registry or Codex rollouts.
It does not import older desktop or REPL conversations. Agents remain responsible
for their own durable execution history; the bridge must not resume a token with
a different agent. A turn left in progress by an exited bridge is displayed as
interrupted, not as a still-running task.
