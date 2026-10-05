//! `graff-observe xray`: where a session's tool-output tokens go, read from
//! the session transcript graff already keeps.

use std::io::{self, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use clap::Args;
use serde::Serialize;

use crate::discover::{self, TraceFile};
use crate::render::{clip, percent, tokens};
use crate::summary;
use crate::transcript;
use crate::xray::{Xray, XrayBuilder};

#[derive(Debug, Args)]
pub struct XrayArgs {
    /// A session name or prefix, a `.transcript.jsonl` file, or a trace run id
    /// (its ACP session is read). Default: the newest session.
    pub session: Option<String>,
    /// Where to look. Default: the current folder.
    #[arg(long = "in", value_name = "PATH")]
    pub roots: Vec<PathBuf>,
    /// Total every session written since this long ago (`24h`, `7d`) or this date.
    #[arg(long, conflicts_with = "session")]
    pub since: Option<String>,
    /// Examples shown per finding.
    #[arg(long, default_value_t = 3)]
    pub top: usize,
    /// JSON instead of text.
    #[arg(long)]
    pub json: bool,
}

/// Measured model input from the graff runs that served the session.
#[derive(Debug, Serialize)]
struct Measured {
    runs: Vec<String>,
    input_tokens: u64,
    cache_read_tokens: u64,
    requests: u64,
    /// Some run also served other ACP sessions, so the numbers mix sessions.
    shared: bool,
}

#[derive(Serialize)]
struct Report<'a> {
    sessions: &'a [TraceFile],
    measured: Option<&'a Measured>,
    xray: &'a Xray,
}

pub(crate) fn run(args: XrayArgs) -> anyhow::Result<()> {
    let roots = if args.roots.is_empty() {
        vec![PathBuf::from(".")]
    } else {
        args.roots.clone()
    };
    let sessions = match &args.since {
        Some(since) => {
            let since = discover::parse_since(since)?;
            discover::written_since(discover::discover_transcripts(&roots)?, Some(since))
        }
        None => vec![pick(&roots, args.session.as_deref())?],
    };
    let many = sessions.len() > 1;
    let mut builder = XrayBuilder::new(args.top);
    for file in &sessions {
        // A transcript removed since discovery is skipped.
        if let Ok(t) = transcript::read(&file.path) {
            builder.add(&label(file, many), &t);
        }
    }
    let xray = builder.finish();
    let measured = match sessions.as_slice() {
        [one] => measure(&roots, one),
        _ => None,
    };
    let mut out = io::stdout().lock();
    if args.json {
        let report = Report {
            sessions: &sessions,
            measured: measured.as_ref(),
            xray: &xray,
        };
        serde_json::to_writer_pretty(&mut out, &report)?;
        writeln!(out)?;
    } else if xray.calls == 0 {
        writeln!(out, "no tool outputs in {} session(s)", sessions.len())?;
    } else {
        report(&mut out, &sessions, measured.as_ref(), &xray)?;
    }
    Ok(())
}

/// A session by file, name or prefix; else the ACP session a trace run served
/// last; else, with no argument, the newest session.
fn pick(roots: &[PathBuf], arg: Option<&str>) -> anyhow::Result<TraceFile> {
    if let Some(path) = arg.map(Path::new).filter(|p| p.is_file()) {
        return Ok(TraceFile::open(path)?);
    }
    let sessions = discover::discover_transcripts(roots)?;
    let Some(arg) = arg else {
        return sessions
            .into_iter()
            .next()
            .context("no graff session transcripts here (looked for .graff/sessions)");
    };
    let matches: Vec<&TraceFile> = sessions
        .iter()
        .filter(|s| s.run_id.starts_with(arg))
        .collect();
    match matches.as_slice() {
        [one] => return Ok((*one).clone()),
        [] => {}
        many => bail!(
            "`{arg}` matches {} sessions; give more of the name",
            many.len()
        ),
    }
    let run = discover::resolve(roots, Some(arg))
        .with_context(|| format!("no session or run matching `{arg}`"))?;
    let served = summary::summarize(&run.path)?.acp_sessions;
    let last = served.last().with_context(|| {
        format!(
            "run {} served no ACP session; give the session's transcript instead \
             (only ACP sessions are named after their id)",
            run.run_id
        )
    })?;
    sessions
        .into_iter()
        .find(|s| &s.run_id == last)
        .with_context(|| format!("no transcript for session {last}"))
}

/// The graff runs that served an ACP session record the model's real input.
/// A session outlives a graff process, so it may span several runs.
fn measure(roots: &[PathBuf], session: &TraceFile) -> Option<Measured> {
    // The session's own project first: its traces sit next to its transcripts.
    let project = session
        .path
        .parent()?
        .parent()?
        .parent()
        .map(Path::to_path_buf);
    let mut runs = project
        .map(|p| discover::find_all_by_acp_session(&[p], &session.run_id))
        .unwrap_or_default();
    if runs.is_empty() {
        runs = discover::find_all_by_acp_session(roots, &session.run_id);
    }
    let mut measured = Measured {
        runs: Vec::new(),
        input_tokens: 0,
        cache_read_tokens: 0,
        requests: 0,
        shared: false,
    };
    for run in runs {
        let Ok(s) = summary::summarize(&run.path) else {
            continue;
        };
        measured.input_tokens += s.tokens.input;
        measured.cache_read_tokens += s.tokens.cache_read;
        measured.requests += s.requests.root + s.requests.children + s.requests.helpers;
        measured.shared |= s.acp_sessions.len() > 1;
        measured.runs.push(s.run_id);
    }
    (!measured.runs.is_empty()).then_some(measured)
}

/// How a session is named in findings: its id alone, or with several
/// sessions its project and the end of its id.
fn label(file: &TraceFile, many: bool) -> String {
    match (many, file.project()) {
        (true, Some(project)) => {
            let chars: Vec<char> = file.run_id.chars().collect();
            let tail: String = chars[chars.len().saturating_sub(5)..].iter().collect();
            format!("{project}/…{tail}")
        }
        _ => file.run_id.clone(),
    }
}

fn report(
    w: &mut dyn Write,
    sessions: &[TraceFile],
    measured: Option<&Measured>,
    x: &Xray,
) -> io::Result<()> {
    let what = match sessions {
        [one] => match one.project() {
            Some(project) => format!("{} ({project})", one.run_id),
            None => one.run_id.clone(),
        },
        many => format!("{} sessions", many.len()),
    };
    writeln!(
        w,
        "x-ray     {what} · {} tool outputs · {} model requests",
        x.calls, x.requests
    )?;
    let mut line = format!(
        "tool outputs {} (est. characters/4) · call arguments {}",
        tokens(x.output_tokens),
        tokens(x.argument_tokens)
    );
    if x.handles > 0 {
        line += &format!(" · {} already handles (preview + file)", x.handles);
    }
    writeln!(w, "tokens    {line}")?;
    writeln!(
        w,
        "carried   up to {} re-sent with later requests (upper bound: a compaction drops outputs sooner)",
        tokens(x.carried_tokens)
    )?;
    if let Some(m) = measured {
        let hit = (m.input_tokens > 0).then(|| m.cache_read_tokens as f64 / m.input_tokens as f64);
        let runs = match m.runs.as_slice() {
            [one] => format!("run {}", clip(one, 12)),
            many => format!("{} runs", many.len()),
        };
        let shared = if m.shared {
            ", other sessions mixed in"
        } else {
            ""
        };
        writeln!(
            w,
            "measured  model input {} over {} requests, {} cached ({runs}{shared})",
            tokens(m.input_tokens),
            m.requests,
            percent(hit),
        )?;
        // Re-sent tool output against everything the model was sent.
        let share = (m.input_tokens > 0)
            .then(|| (x.carried_tokens as f64 / m.input_tokens as f64).min(1.0));
        writeln!(
            w,
            "          tool outputs are up to {} of that input",
            percent(share)
        )?;
    }
    for (i, b) in x.by_tool.iter().take(8).enumerate() {
        let share = (x.output_tokens > 0).then(|| b.tokens as f64 / x.output_tokens as f64);
        writeln!(
            w,
            "{:<9} {:<24} {:>5} calls {:>7} {:>4}  largest {:>6}",
            if i == 0 { "by tool" } else { "" },
            clip(&b.tool, 24),
            b.calls,
            tokens(b.tokens),
            percent(share),
            tokens(b.largest_tokens)
        )?;
    }
    if x.findings.is_empty() {
        return writeln!(w, "findings  none");
    }
    let share = (x.output_tokens > 0).then(|| x.savings_tokens as f64 / x.output_tokens as f64);
    writeln!(
        w,
        "savings   ≈ {} tokens ({} of tool output) if these outputs were compacted",
        tokens(x.savings_tokens),
        percent(share)
    )?;
    for k in &x.findings {
        let label = k.kind.map_or("?", |kind| kind.label());
        writeln!(
            w,
            "  {:<17} {:>4} × {:>7}",
            label,
            k.count,
            tokens(k.savings_tokens)
        )?;
        for e in &k.examples {
            let at = if sessions.len() > 1 {
                format!("{} ", clip(&e.session, 24))
            } else {
                String::new()
            };
            writeln!(w, "      {at}{} #{}: {}", e.tool, e.call, e.detail)?;
        }
    }
    Ok(())
}
