//! `graff-observe`: runs, one run, a live run, or totals. [`Command`] and
//! [`run`] are public so a host CLI can mount them as a subcommand.

use std::collections::HashSet;
use std::io::{self, Write};
use std::path::PathBuf;
use std::thread::sleep;
use std::time::{Duration, Instant};

use clap::{Args, Parser, Subcommand};
use serde::Serialize;

use crate::discover::{self, TraceFile};
use crate::follow::Follower;
use crate::process::{ProcSample, sample_process};
use crate::render;
use crate::stats::StatsBuilder;
use crate::summary::{self, Observer, RunSummary};

#[derive(Debug, Parser)]
#[command(
    name = "graff-observe",
    version,
    about = "Observe graff runs from their trace files (.graff/traces). Read-only and local."
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// List runs, newest first.
    Runs(ListArgs),
    /// Report one run: requests, tokens, cost, tools, Jev, children, retries.
    Show(ShowArgs),
    /// Follow a run as graff writes it, with the graff process's memory and CPU.
    Watch(WatchArgs),
    /// Totals across runs: models, effort, tools, Jev, delegation.
    Stats(ListArgs),
    /// Export runs as OpenTelemetry traces (OTLP/HTTP JSON, GenAI semantic
    /// conventions), once or live with --follow.
    Otel(crate::cli_otel::OtelArgs),
    /// Where tool-output tokens go in a session, and what compacting them
    /// would save, from graff's session transcripts.
    Xray(crate::cli_xray::XrayArgs),
}

#[derive(Debug, Args)]
pub struct ListArgs {
    /// Projects, folders of projects, `.graff/traces` folders or trace files.
    /// Default: the current folder.
    pub paths: Vec<PathBuf>,
    /// Only runs written since this long ago (`90m`, `24h`, `7d`) or this date (`2026-09-23`, UTC).
    #[arg(long)]
    pub since: Option<String>,
    /// At most this many runs, newest first (`runs` defaults to 20, `stats` to all).
    #[arg(long)]
    pub limit: Option<usize>,
    /// Include runs that never made a request (processes that only started up).
    #[arg(long)]
    pub all: bool,
    /// JSON instead of text.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Args)]
pub struct ShowArgs {
    /// A run id or its prefix, or a trace file. Default: the newest run.
    pub run: Option<String>,
    /// Where to look. Default: the current folder.
    #[arg(long = "in", value_name = "PATH")]
    pub roots: Vec<PathBuf>,
    /// JSON instead of text.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Args)]
pub struct WatchArgs {
    /// A run id or its prefix, or a trace file. Default: the newest run, then
    /// each new run that starts while watching.
    pub run: Option<String>,
    /// Where to look. Default: the current folder.
    #[arg(long = "in", value_name = "PATH")]
    pub roots: Vec<PathBuf>,
    /// Print the run's earlier events too, not just a digest of them.
    #[arg(long)]
    pub replay: bool,
    /// Also print transport and startup lines.
    #[arg(long)]
    pub all: bool,
    /// Seconds between process samples; 0 turns sampling off.
    #[arg(long, default_value_t = 5)]
    pub sample_secs: u64,
}

pub fn main() -> anyhow::Result<()> {
    run(Cli::parse().command)
}

pub fn run(command: Command) -> anyhow::Result<()> {
    match command {
        Command::Runs(args) => runs(args),
        Command::Show(args) => show(args),
        Command::Watch(args) => watch(args),
        Command::Stats(args) => stats(args),
        Command::Otel(args) => crate::cli_otel::run(args),
        Command::Xray(args) => crate::cli_xray::run(args),
    }
}

fn roots(paths: &[PathBuf]) -> Vec<PathBuf> {
    if paths.is_empty() {
        vec![PathBuf::from(".")]
    } else {
        paths.to_vec()
    }
}

/// Runs under `args.paths`, newest first, each read in full.
fn load(args: &ListArgs, default_limit: usize) -> anyhow::Result<Vec<(TraceFile, Observer)>> {
    let since = args
        .since
        .as_deref()
        .map(discover::parse_since)
        .transpose()?;
    let files = discover::written_since(discover::discover(&roots(&args.paths))?, since);
    let limit = args.limit.unwrap_or(default_limit);
    let mut runs = Vec::new();
    for file in files {
        if runs.len() >= limit {
            break;
        }
        // A file removed since discovery is skipped, not an error.
        let Ok(observer) = summary::observe_file(&file.path) else {
            continue;
        };
        if args.all || !observer.is_empty() {
            runs.push((file, observer));
        }
    }
    Ok(runs)
}

#[derive(Serialize)]
struct Row<'a> {
    file: &'a TraceFile,
    summary: &'a RunSummary,
}

fn runs(args: ListArgs) -> anyhow::Result<()> {
    let rows: Vec<(TraceFile, RunSummary)> = load(&args, 20)?
        .into_iter()
        .map(|(file, observer)| (file, observer.summary()))
        .collect();
    let mut out = io::stdout().lock();
    if args.json {
        let rows: Vec<Row> = rows
            .iter()
            .map(|(file, summary)| Row { file, summary })
            .collect();
        serde_json::to_writer_pretty(&mut out, &rows)?;
        writeln!(out)?;
    } else if rows.is_empty() {
        writeln!(out, "no graff runs found")?;
    } else {
        render::runs_table(&mut out, &rows)?;
    }
    Ok(())
}

fn show(args: ShowArgs) -> anyhow::Result<()> {
    let file = discover::resolve(&roots(&args.roots), args.run.as_deref())?;
    let summary = summary::summarize(&file.path)?;
    let mut out = io::stdout().lock();
    if args.json {
        serde_json::to_writer_pretty(
            &mut out,
            &Row {
                file: &file,
                summary: &summary,
            },
        )?;
        writeln!(out)?;
    } else {
        render::run_report(&mut out, &file, &summary)?;
    }
    Ok(())
}

fn stats(args: ListArgs) -> anyhow::Result<()> {
    let mut builder = StatsBuilder::new();
    for (_, observer) in load(&args, usize::MAX)? {
        builder.add(&observer);
    }
    let stats = builder.finish();
    let mut out = io::stdout().lock();
    if args.json {
        serde_json::to_writer_pretty(&mut out, &stats)?;
        writeln!(out)?;
    } else if stats.runs == 0 {
        writeln!(out, "no graff runs found")?;
    } else {
        render::stats_report(&mut out, &stats)?;
    }
    Ok(())
}

fn watch(args: WatchArgs) -> anyhow::Result<()> {
    let roots = roots(&args.roots);
    let pinned = args.run.is_some();
    let mut known: HashSet<PathBuf> = if pinned {
        HashSet::new()
    } else {
        discover::discover(&roots)?
            .into_iter()
            .map(|f| f.path)
            .collect()
    };
    let mut file = discover::resolve(&roots, args.run.as_deref())?;
    let mut out = io::stdout().lock();
    let mut follower = Follower::open(&file.path, true)?;
    let mut observer = catch_up(&mut out, &file, &mut follower, args.replay)?;
    let mut procs = ProcessLog::default();
    let mut last_sample: Option<Instant> = None;
    let mut last_scan = Instant::now();
    loop {
        for line in follower.poll()? {
            if let Some(text) = observer
                .push_line(&line)
                .and_then(|e| render::event_line(&e, args.all))
            {
                writeln!(out, "{text}")?;
            }
        }
        let due =
            last_sample.is_none_or(|at| at.elapsed() >= Duration::from_secs(args.sample_secs));
        if args.sample_secs > 0 && due {
            last_sample = Some(Instant::now());
            if let Some(text) = observer
                .pid()
                .and_then(sample_process)
                .and_then(|s| procs.line(s))
            {
                writeln!(out, "{text}")?;
            }
        }
        if !pinned && last_scan.elapsed() >= Duration::from_secs(2) {
            last_scan = Instant::now();
            let newer = discover::discover(&roots)?
                .into_iter()
                .find(|f| !known.contains(&f.path));
            if let Some(newer) = newer {
                known.insert(newer.path.clone());
                writeln!(
                    out,
                    "── finished watching: {}",
                    render::brief(&observer.summary())
                )?;
                file = newer;
                follower = Follower::open(&file.path, true)?;
                observer = catch_up(&mut out, &file, &mut follower, args.replay)?;
                procs = ProcessLog::default();
                last_sample = None;
            }
        }
        out.flush()?;
        sleep(Duration::from_millis(250));
    }
}

/// Prints a process sample when memory, CPU or the process count moved, and
/// otherwise once a minute, so an idle session stays quiet.
#[derive(Default)]
struct ProcessLog {
    peak_kb: u64,
    printed: Option<(Instant, ProcSample)>,
}

impl ProcessLog {
    fn line(&mut self, sample: ProcSample) -> Option<String> {
        self.peak_kb = self.peak_kb.max(sample.tree_rss_kb);
        let moved = self.printed.as_ref().is_none_or(|(at, last)| {
            at.elapsed() >= Duration::from_secs(60)
                || sample.tree_rss_kb.abs_diff(last.tree_rss_kb) * 20 > last.tree_rss_kb
                || sample.cpu_ms >= last.cpu_ms + 1000
                || sample.tree_procs != last.tree_procs
        });
        if !moved {
            return None;
        }
        let text = render::process_line(&sample, self.peak_kb);
        self.printed = Some((Instant::now(), sample));
        Some(text)
    }
}

/// Reads the run so far. Prints each event with `replay`, else one digest line.
fn catch_up(
    out: &mut dyn Write,
    file: &TraceFile,
    follower: &mut Follower,
    replay: bool,
) -> anyhow::Result<Observer> {
    let mut observer = Observer::new();
    writeln!(
        out,
        "── watching {} ({})",
        file.run_id,
        follower.path().display()
    )?;
    for line in follower.poll()? {
        let event = observer.push_line(&line);
        if replay && let Some(text) = event.and_then(|e| render::event_line(&e, false)) {
            writeln!(out, "{text}")?;
        }
    }
    if !replay {
        writeln!(out, "── so far: {}", render::brief(&observer.summary()))?;
    }
    Ok(observer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_lines_print_only_when_something_moved() {
        let mut log = ProcessLog::default();
        let base = ProcSample {
            pid: 1,
            command: "graff".into(),
            rss_kb: 1000,
            tree_rss_kb: 2000,
            tree_procs: 2,
            cpu_ms: 500,
            ..Default::default()
        };
        assert!(log.line(base.clone()).is_some());
        assert!(log.line(base.clone()).is_none());
        let small = ProcSample {
            tree_rss_kb: 2050,
            ..base.clone()
        };
        assert!(log.line(small).is_none());
        let grew = ProcSample {
            tree_rss_kb: 2200,
            ..base.clone()
        };
        assert!(log.line(grew.clone()).is_some());
        let busy = ProcSample {
            cpu_ms: 2000,
            ..grew.clone()
        };
        assert!(log.line(busy.clone()).is_some());
        let spawned = ProcSample {
            tree_procs: 3,
            ..busy
        };
        let text = log.line(spawned).unwrap();
        assert!(
            text.contains("in 3 processes") && text.contains("peak 2 MB"),
            "{text}"
        );
    }
}
