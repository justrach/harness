//! `graff-observe otel`: export runs as OpenTelemetry traces, once or live.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, bail};
use clap::Args;

use crate::discover::{self, TraceFile};
use crate::follow::Follower;
use crate::otel::{Converter, Span};
use crate::otlp::{self, Sink};
use crate::process::sample_process;

/// Spans per request, well under collectors' request-size limits.
const BATCH: usize = 500;
/// Spans kept for a retry while the backend is unreachable.
const UNSENT_CAP: usize = 20_000;

#[derive(Debug, Args)]
pub struct OtelArgs {
    /// A run id or its prefix, or a trace file. Default: the newest run.
    pub run: Option<String>,
    /// Where to look. Default: the current folder.
    #[arg(long = "in", value_name = "PATH")]
    pub roots: Vec<PathBuf>,
    /// Export every run written since this long ago (`24h`, `7d`) or this date, instead of one run.
    #[arg(long, conflicts_with_all = ["run", "follow"])]
    pub since: Option<String>,
    /// OTLP/HTTP endpoint such as `http://localhost:4318` (`/v1/traces` is added).
    /// Default: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT.
    #[arg(long)]
    pub endpoint: Option<String>,
    /// A request header `key=value`; repeat for more. OTEL_EXPORTER_OTLP_HEADERS is read too.
    #[arg(long = "header", value_name = "KEY=VALUE")]
    pub headers: Vec<String>,
    /// Write OTLP JSON lines to this file (`-` for stdout) instead of sending them.
    #[arg(long, value_name = "FILE", conflicts_with = "endpoint")]
    pub out: Option<PathBuf>,
    /// Keep exporting as graff writes, including runs that start later. Ctrl-C stops.
    #[arg(long)]
    pub follow: bool,
}

pub(crate) fn run(args: OtelArgs) -> anyhow::Result<()> {
    let mut sink = sink(&args)?;
    let roots = if args.roots.is_empty() {
        vec![PathBuf::from(".")]
    } else {
        args.roots.clone()
    };
    if args.follow {
        return follow(&roots, args.run.as_deref(), &mut sink);
    }
    let files = match &args.since {
        Some(since) => discover::written_since(
            discover::discover(&roots)?,
            Some(discover::parse_since(since)?),
        ),
        None => vec![discover::resolve(&roots, args.run.as_deref())?],
    };
    let (mut runs, mut spans_sent) = (0, 0);
    for file in &files {
        let Ok(mut converter) = convert_file(file) else {
            continue;
        };
        if converter.is_empty() {
            continue;
        }
        let mut spans = converter.take();
        spans.extend(converter.finish());
        let start = otlp::run_start_unix_ms(modified(&file.path), converter.last_t());
        spans_sent += send(&mut sink, &converter, &spans, start)?;
        runs += 1;
    }
    eprintln!(
        "exported {spans_sent} spans from {runs} run(s) to {}",
        sink.target()
    );
    Ok(())
}

fn sink(args: &OtelArgs) -> anyhow::Result<Sink> {
    if let Some(out) = &args.out {
        let writer: Box<dyn Write> = if out.as_os_str() == "-" {
            Box::new(io::stdout())
        } else {
            Box::new(File::create(out).with_context(|| out.display().to_string())?)
        };
        return Ok(Sink::lines(writer));
    }
    let env = |name: &str| std::env::var(name).ok();
    let Some(url) = otlp::traces_endpoint(args.endpoint.as_deref(), &env) else {
        bail!(
            "give --endpoint (for example http://localhost:4318) or --out, or set OTEL_EXPORTER_OTLP_ENDPOINT"
        );
    };
    for name in [
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL",
        "OTEL_EXPORTER_OTLP_PROTOCOL",
    ] {
        if let Some(protocol) = env(name).filter(|p| !p.is_empty() && p != "http/json") {
            eprintln!("note: {name} is {protocol}; graff-observe sends OTLP/HTTP with JSON bodies");
            break;
        }
    }
    Sink::http(&url, otlp::export_headers(&args.headers, &env)?)
}

fn convert_file(file: &TraceFile) -> io::Result<Converter> {
    let mut converter = Converter::new(file);
    let mut reader = BufReader::new(File::open(&file.path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        converter.push_line(&String::from_utf8_lossy(&line));
    }
    Ok(converter)
}

fn modified(path: &Path) -> SystemTime {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .unwrap_or_else(|_| SystemTime::now())
}

fn send(
    sink: &mut Sink,
    converter: &Converter,
    spans: &[Span],
    run_start: u64,
) -> anyhow::Result<usize> {
    let resource = converter.resource();
    for chunk in spans.chunks(BATCH) {
        let rejected = sink.send(&otlp::export_request(&resource, chunk, run_start))?;
        if rejected > 0 {
            eprintln!("note: {} rejected {rejected} span(s)", sink.target());
        }
    }
    Ok(spans.len())
}

/// A run being exported as graff writes it.
struct Live {
    file: TraceFile,
    follower: Follower,
    converter: Converter,
    run_start: Option<u64>,
    /// Spans whose send failed, retried on the next pump.
    unsent: Vec<Span>,
    finished: bool,
}

impl Live {
    fn open(file: TraceFile) -> anyhow::Result<Self> {
        Ok(Live {
            follower: Follower::open(&file.path, true)?,
            converter: Converter::new(&file),
            file,
            run_start: None,
            unsent: Vec::new(),
            finished: false,
        })
    }

    /// Reads new lines and sends the spans they finished.
    fn pump(&mut self, sink: &mut Sink) -> anyhow::Result<usize> {
        for line in self.follower.poll()? {
            self.converter.push_line(&line);
        }
        let spans = self.converter.take();
        self.export(sink, spans)
    }

    /// The run ended (its process exited or a newer run started): send what was still open.
    fn finish(&mut self, sink: &mut Sink) -> anyhow::Result<usize> {
        let sent = self.pump(sink)?;
        self.finished = true;
        let spans = self.converter.finish();
        Ok(sent + self.export(sink, spans)?)
    }

    fn export(&mut self, sink: &mut Sink, spans: Vec<Span>) -> anyhow::Result<usize> {
        self.unsent.extend(spans);
        if self.unsent.is_empty() {
            return Ok(0);
        }
        // The run's wall clock is anchored once, at its first export.
        if self.run_start.is_none() {
            let start = otlp::run_start_unix_ms(modified(&self.file.path), self.converter.last_t());
            self.run_start = Some(start);
        }
        let start = self.run_start.unwrap_or(0);
        match send(sink, &self.converter, &self.unsent, start) {
            Ok(sent) => {
                self.unsent.clear();
                Ok(sent)
            }
            Err(err) => {
                let excess = self.unsent.len().saturating_sub(UNSENT_CAP);
                self.unsent.drain(..excess);
                Err(err)
            }
        }
    }
}

fn follow(roots: &[PathBuf], run: Option<&str>, sink: &mut Sink) -> anyhow::Result<()> {
    let pinned = run.is_some();
    let mut known: HashSet<PathBuf> = if pinned {
        HashSet::new()
    } else {
        discover::discover(roots)?
            .into_iter()
            .map(|f| f.path)
            .collect()
    };
    let mut live = Live::open(discover::resolve(roots, run)?)?;
    eprintln!(
        "── exporting run {} to {} (Ctrl-C stops)",
        live.file.run_id,
        sink.target()
    );
    let mut last_check = Instant::now();
    let mut last_error: Option<Instant> = None;
    loop {
        let mut report = |result: anyhow::Result<usize>, what: &str| match result {
            Ok(0) => {}
            Ok(sent) => eprintln!("   {what}: {sent} spans"),
            Err(err) if last_error.is_none_or(|at| at.elapsed() >= Duration::from_secs(30)) => {
                last_error = Some(Instant::now());
                eprintln!("   export failed, will retry: {err:#}");
            }
            Err(_) => {}
        };
        report(live.pump(sink), &format!("run {}", live.file.run_id));
        if last_check.elapsed() >= Duration::from_secs(2) {
            last_check = Instant::now();
            // `ps` is how a run's end is seen; without it a run ends when a newer one starts.
            let exited = cfg!(unix)
                && live
                    .converter
                    .pid()
                    .is_some_and(|pid| sample_process(pid).is_none());
            if exited && !live.finished {
                report(
                    live.finish(sink),
                    &format!("run {} ended", live.file.run_id),
                );
            }
            let newer = if pinned {
                None
            } else {
                discover::discover(roots)?
                    .into_iter()
                    .find(|f| !known.contains(&f.path))
            };
            if let Some(newer) = newer {
                known.insert(newer.path.clone());
                if !live.finished {
                    report(
                        live.finish(sink),
                        &format!("run {} ended", live.file.run_id),
                    );
                }
                live = Live::open(newer)?;
                eprintln!("── exporting run {}", live.file.run_id);
            }
        }
        sleep(Duration::from_millis(500));
    }
}
