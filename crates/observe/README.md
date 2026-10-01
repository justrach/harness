# harness-observe

A read-only observer for graff runs, outside the graff binary.

graff writes one JSONL trace per process to `<project>/.graff/traces/<run-id>.jsonl`, whether it runs in its TUI, with `-p`, or over ACP inside Harness. This crate reads those files and reports what each run did. It never writes to them. It sends nothing anywhere unless you run `otel` with an endpoint.

## Command line

```bash
cargo run -p harness-observe --release -- runs ~ --since 7d    # one line per run, newest first
cargo run -p harness-observe --release -- show                 # the newest run in this folder, in detail
cargo run -p harness-observe --release -- show 47e0 --in ~/app # a run by id prefix
cargo run -p harness-observe --release -- watch                # follow the newest run live
cargo run -p harness-observe --release -- stats ~ --since 2026-09-23
cargo run -p harness-observe --release -- otel --endpoint http://localhost:4318   # OpenTelemetry, below
```

The binary is `graff-observe`. Paths may be projects, folders of projects (searched four levels deep, skipping hidden folders except `.worktrees`), `.graff/traces` folders, or trace files. `--json` prints the same data as JSON. `runs` and `stats` skip runs that never made a request unless `--all` is given.

- **`show`** reports:
  - model and effort over time, turns and interruptions;
  - root, child and helper requests;
  - time to first token and request latency (p50/p90);
  - tokens and cache reuse, cost of finished turns;
  - tool calls and failures by tool;
  - Jev effort calls;
  - retries, stalls and compactions;
  - the ACP sessions the run served.
- **`watch`** first prints a digest of the run so far (or every event with `--replay`), then each new event as graff writes it. It also samples the graff process and everything it started: RSS, CPU time and the peak. When a new run starts in the watched folders, it moves to that run. `--all` adds transport and startup lines.
- **`stats`** totals runs:
  - per model: runs, turns, requests, cost, first-token and request latency;
  - effort at the end of each turn;
  - tool failure counts;
  - how many runs on routes that offer Jev actually called it;
  - how much time children took and how long parents waited for them.

## Sub-agents: was delegating worth it?

For a run with children, `show` splits the time:

| Column | Meaning |
| --- | --- |
| first spawn | when the parent started its first child |
| spawn spread | first to last spawn |
| critical path | first child start to last child finish |
| slowest | the longest single child |
| parallel | child time summed over the critical path (1.00x means the children never overlapped) |
| parent model | the parent's own model time |
| parent waited | the parent blocked in `agent_output` |
| tail | last child finish to the parent's last request |

Children come from graff's per-child `subagent` trace line (status, time, tools, effort). On traces written before that line, each child's span comes from its own model requests and its status is unknown.

## OpenTelemetry

`graff-observe otel` turns runs into OpenTelemetry traces and sends them to any OTLP/HTTP backend, such as an OpenTelemetry Collector or Jaeger. Spans are named and attributed after the OpenTelemetry GenAI semantic conventions.

```bash
graff-observe otel --endpoint http://localhost:4318               # the newest run in this folder
graff-observe otel 47e0 --in ~/app --endpoint http://localhost:4318
graff-observe otel --since 7d --in ~ --out runs.otlp.jsonl        # backfill into a file instead
graff-observe otel --follow --in ~/app                            # stream spans while graff runs
```

The endpoint and headers follow the standard OpenTelemetry environment variables:

- `OTEL_EXPORTER_OTLP_ENDPOINT` (`/v1/traces` is added);
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (used as is);
- `OTEL_EXPORTER_OTLP_HEADERS` and `OTEL_EXPORTER_OTLP_TRACES_HEADERS`;
- `--header key=value` adds more.

Requests are OTLP/HTTP with JSON bodies. `--out` writes one request per line, the format the collector's `otlpjsonfile` receiver reads.

| Span | Kind | One per | Main attributes |
| --- | --- | --- | --- |
| `invoke_agent graff` | internal | root turn (the trace root) | `gen_ai.request.reasoning.level` (effort when the turn ended), `gen_ai.conversation.id` (the ACP session, else graff's session), `graff.turn.cost_usd`, `graff.turn.success`, `graff.turn.model_calls`, `graff.turn.tool_errors` |
| `chat {model}` | client | model request | `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.reasoning.output_tokens`, `gen_ai.response.time_to_first_chunk`, `graff.agent`, `graff.context_tokens` |
| `execute_tool {name}` | internal | tool call, `jev_effort` included | `gen_ai.tool.name`, `error.type` on failure |
| `invoke_agent {label}` | internal | sub-agent; its requests and tool calls nest under it | `gen_ai.request.reasoning.level` (the child's effort), `graff.agent.tool_calls`, `error.type` when it failed |

- **Notes** (retries, stalls, compactions, interrupts) are events on the turn span.
- **Resource attributes:** `service.name=graff`, `service.version`, `service.instance.id` (the run id), `process.pid`, `graff.project`.
- **What leaves the machine:**
  - model and tool names, sub-agent labels;
  - token counts, timings, costs and effort levels;
  - error flags;
  - the details of notes graff writes from fixed text.
- **What doesn't:** prompts, tool arguments and results; graff's traces do not hold them. A note kind that may carry user text is sent by name only.
- **Timing:** traces record milliseconds since the run started, so a run's wall-clock start is the trace file's last write minus the run's latest event time.
- **A child's tool calls:** the trace line doesn't name the agent. The call nests under the child while exactly one child is running, and otherwise under the turn, with `graff.from_sub=true`.
- **Span ids** derive from the run id, so exporting a run twice produces the same ids.
- **`--follow`** sends each span as it finishes. A turn's root span goes when the turn ends. Anything still open goes when the graff process exits or a newer run starts. Spans that fail to send are retried on the next poll.

Library: `otel::Converter` turns trace lines into spans, `otlp::export_request` encodes them, and `otlp::Sink` sends or writes them.

## Tool-output x-ray

`graff-observe xray` shows where a session's tool-output tokens go and what compacting them would save. It needs no new capture: graff already keeps each session's transcript in `.graff/sessions/<session>.transcript.jsonl`, with every tool call's arguments and the exact output the model received. Both transcript shapes are read: Responses items and chat rows.

```bash
graff-observe xray                       # the newest session in this folder
graff-observe xray <session> --in ~/app  # a session name or its prefix
graff-observe xray --since 7d --in ~     # totals across every session
```

- **Sizes:** each output's estimated tokens, `ceil(characters / 4)`. This is a size, not billing data.
- **By tool:** calls, tokens, share of all tool output, and the largest single output.
- **Carried:** each output's tokens times the model requests made after it. It is an upper bound on re-sending, since a compaction drops outputs sooner.
- **Measured:** for an ACP session, the graff runs that served it supply the model's real input tokens and request count. The report then says what share of that input tool outputs can account for.

Findings, each with the tokens a compact form would save:

| Finding | What it flags | Estimated saving |
| --- | --- | --- |
| large output | an output of 2k+ tokens (graff already turns anything over 16 KiB into a preview plus a file) | for command logs: what keeping errors and warnings (±1 line) plus the first and last five lines would drop; otherwise none |
| repeated content | a line of 8+ characters appearing 3+ times in one output | every copy after the first |
| repeated keys | a JSON array whose 3+ objects share the same fields | the field names after the first object |
| repeated paths | a directory prefix of 12+ characters written 5+ times in one output | every copy after the first |
| repeated calls | a tool returning an output (100+ characters) it already returned | the whole repeat |

The total counts each output once, at its largest saving.

The outputs are the user's data. The report quotes short snippets of them, prints locally, and sends nothing anywhere.

## Library

```rust
let runs = harness_observe::discover(&[project.into()])?;      // newest first
let summary = harness_observe::summarize(&runs[0].path)?;      // RunSummary (serde::Serialize)
let run = harness_observe::find_by_acp_session(&roots, "session-…"); // ACP session → its run
let run = harness_observe::find_by_pid(&roots, pid);           // live graff process → its run

let mut observer = harness_observe::Observer::new();           // incremental, for live views
let mut follower = harness_observe::Follower::open(&path, true)?;
for line in follower.poll()? {
    observer.push_line(&line);
}
let sample = harness_observe::sample_process(pid);             // RSS and CPU of the process tree
```

`harness_observe::cli::{Command, run}` can be mounted as a subcommand of another clap CLI.

## What it reads

Every trace line carries `run_id`, `pid`, `session_id`, `t` (ms since the run started) and `ev`. The fields this crate uses:

| `ev` | Fields |
| --- | --- |
| `api` | `agent`, `model`, `ms`, `context_tokens`, `is_error` |
| `usage` | `agent`, `from_sub`, `provider`, `model`, `input_tokens`, `cache_read_tokens`, `cache_write_tokens`, `output_tokens`, `reasoning_tokens`, `prefix_bust` |
| `tool` | `name`, `ms`, `is_error`, `from_sub` |
| `first_token` | `agent`, `from_sub`, `ms` |
| `recipe` | `provider`, `model`, `effort`, `harness_version` |
| `recipe_outcome` | `provider`, `model`, `effort`, `success`, `latency_ms`, `model_calls`, `tool_calls`, `tool_errors`, `cost_microusd` |
| `startup_phase` | `startup_ms` |
| `subagent` | `detail`: `<id> <ok\|failed> label=<label> ms=<n> tools=<n> context=<n> cached=<n> effort=<effort>` |
| `compact_cut` | counted as a compaction |
| any other | `detail` (retries, stalls, interrupts, `acp_prompt` session ids) |

A line with drifted field types still counts by its event name, and a half-written last line is skipped until it is complete.

## Limits

- Cost comes from finished turns, so a turn in progress is not counted yet. Routes billed by subscription show `$0`.
- Jev: graff offers `jev_effort` only on some routes and only with a Codegraff login. The observer applies graff's route rule, but the login is not in the trace, so "offered" means the route qualifies.
- Root, helper and child agents are told apart by graff's agent labels: `main`, `repl` and `root` are the root, and graff's own side agents (titles, recaps, judges, side questions, reviews) are helpers.
- Process sampling uses `ps` and is unavailable on Windows. A sample needs the graff process to still be running.
- `watch` prints note details as graff wrote them. Read traces as the user's local data.
