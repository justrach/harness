# harness-observe

A read-only observer for graff runs, outside the graff binary.

graff writes one JSONL trace per process to `<project>/.graff/traces/<run-id>.jsonl`, whether it runs in its TUI, with `-p`, or over ACP inside Harness. This crate reads those files and reports what each run did. It never writes to them and sends nothing anywhere.

## Command line

```bash
cargo run -p harness-observe --release -- runs ~ --since 7d    # one line per run, newest first
cargo run -p harness-observe --release -- show                 # the newest run in this folder, in detail
cargo run -p harness-observe --release -- show 47e0 --in ~/app # a run by id prefix
cargo run -p harness-observe --release -- watch                # follow the newest run live
cargo run -p harness-observe --release -- stats ~ --since 2026-09-23
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
