//! Observation layer for graff runs, outside the graff binary.
//!
//! graff writes one JSONL trace per process to
//! `<project>/.graff/traces/<run-id>.jsonl`: model requests, token usage, tool
//! calls, turn outcomes, sub-agents and retries. This crate reads those files
//! (it never writes them, and sends nothing unless asked to export
//! OpenTelemetry) and turns them into summaries for a person or a Harness
//! surface:
//!
//! - [`discover`] finds runs under project folders; [`find_by_pid`] and
//!   [`find_by_acp_session`] map a live graff process or ACP session to its run.
//! - [`Observer`] folds trace lines into a [`RunSummary`], for a finished run
//!   or one still being written; [`summarize`] reads a whole file.
//! - [`Follower`] tails a trace graff is still writing.
//! - [`sample_process`] reads the memory and CPU of a live graff process tree.
//! - [`StatsBuilder`] totals many runs.
//! - [`otel::Converter`] turns a run into OpenTelemetry spans (GenAI semantic
//!   conventions) and [`otlp`] sends them to any OTLP/HTTP backend.
//! - [`xray::XrayBuilder`] sizes every tool output in a session transcript and
//!   flags what bloats the context.
//!
//! The `graff-observe` binary ([`cli`]) puts all of it on the command line.

pub mod cli;
mod cli_otel;
mod cli_xray;
mod delegation;
mod discover;
mod event;
mod follow;
pub mod otel;
pub mod otlp;
mod process;
pub mod render;
mod stats;
mod summary;
pub mod transcript;
pub mod xray;

pub use cli_otel::OtelArgs;
pub use cli_xray::XrayArgs;
pub use delegation::{ChildRun, Delegation};
pub use discover::{
    TraceFile, discover, discover_transcripts, find_by_acp_session, find_by_pid, parse_since,
    resolve, written_since,
};
pub use event::{Event, EventKind, Stamp, SubagentRun, TurnOutcome, Usage, parse_line};
pub use follow::Follower;
pub use process::{ProcSample, sample_process};
pub use stats::{Count, DelegationStats, JevStats, ModelStats, Stats, StatsBuilder};
pub use summary::{
    Jev, Observer, Percentiles, Reliability, Requests, RunSummary, SCHEMA_VERSION, Tokens,
    ToolStat, Tools, jev_eligible, summarize,
};
