//! Plain-text views of runs, events and process samples.

use std::io::{self, Write};
use std::time::SystemTime;

use crate::delegation::Delegation;
use crate::discover::TraceFile;
use crate::event::{Event, EventKind};
use crate::process::ProcSample;
use crate::stats::Stats;
use crate::summary::{Percentiles, RunSummary};

pub fn ms(v: u64) -> String {
    match v {
        0..1_000 => format!("{v}ms"),
        1_000..60_000 => format!("{:.1}s", v as f64 / 1000.0),
        60_000..3_600_000 => format!("{}m{:02}s", v / 60_000, v / 1000 % 60),
        _ => format!("{}h{:02}m", v / 3_600_000, v / 60_000 % 60),
    }
}

pub fn tokens(v: u64) -> String {
    match v {
        0..1_000 => v.to_string(),
        1_000..1_000_000 => format!("{:.1}k", v as f64 / 1e3),
        _ => format!("{:.2}M", v as f64 / 1e6),
    }
}

pub fn usd(v: f64) -> String {
    if v == 0.0 {
        "$0".into()
    } else if v < 0.0001 {
        "<$0.0001".into()
    } else if v < 0.01 {
        format!("${v:.4}")
    } else {
        format!("${v:.2}")
    }
}

pub fn percent(v: Option<f64>) -> String {
    v.map_or_else(|| "-".into(), |x| format!("{:.0}%", x * 100.0))
}

/// A byte count: `60 B`, `4.1 KB`, `1.2 MB`.
pub fn bytes(v: u64) -> String {
    match v {
        0..1_000 => format!("{v} B"),
        1_000..1_000_000 => format!("{:.1} KB", v as f64 / 1e3),
        _ => format!("{:.1} MB", v as f64 / 1e6),
    }
}

fn kb(v: u64) -> String {
    match v {
        0..1_024 => format!("{v} KB"),
        1_024..1_048_576 => format!("{:.0} MB", v as f64 / 1024.0),
        _ => format!("{:.1} GB", v as f64 / 1_048_576.0),
    }
}

pub fn age(modified: SystemTime) -> String {
    let secs = SystemTime::now()
        .duration_since(modified)
        .map_or(0, |d| d.as_secs());
    match secs {
        0..60 => "now".into(),
        60..3_600 => format!("{}m", secs / 60),
        3_600..86_400 => format!("{}h", secs / 3_600),
        _ => format!("{}d", secs / 86_400),
    }
}

pub(crate) fn clip(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        text.to_string()
    } else {
        text.chars()
            .take(width.saturating_sub(1))
            .collect::<String>()
            + "…"
    }
}

fn spread(p: &Percentiles) -> String {
    match (p.p50, p.p90) {
        (Some(p50), Some(p90)) => format!("p50 {} p90 {}", ms(p50), ms(p90)),
        _ => "-".into(),
    }
}

fn plural(n: u64, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// One line per run, newest first.
pub fn runs_table(w: &mut dyn Write, rows: &[(TraceFile, RunSummary)]) -> io::Result<()> {
    writeln!(
        w,
        "{:<5} {:<16} {:<8} {:<12} {:<18} {:<14} {:>5} {:>5} {:>4} {:>5} {:>4} {:>5} {:>8} {:>3} {:>7}",
        "AGE",
        "PROJECT",
        "RUN",
        "GRAFF",
        "MODEL",
        "EFFORT",
        "TURNS",
        "REQS",
        "KIDS",
        "TOOLS",
        "ERR",
        "CACHE",
        "COST",
        "JEV",
        "SPAN"
    )?;
    for (file, s) in rows {
        let requests = s.requests.root + s.requests.children + s.requests.helpers;
        let jev = if s.jev.eligible_model || s.jev.calls > 0 {
            s.jev.calls.to_string()
        } else {
            "-".into()
        };
        writeln!(
            w,
            "{:<5} {:<16} {:<8} {:<12} {:<18} {:<14} {:>5} {:>5} {:>4} {:>5} {:>4} {:>5} {:>8} {:>3} {:>7}",
            age(file.modified),
            clip(&file.project().unwrap_or_default(), 16),
            clip(&file.run_id, 8),
            clip(&s.version, 12),
            clip(&s.model, 18),
            clip(&s.efforts.join("→"), 14),
            s.turns,
            requests,
            s.delegation.children.len(),
            s.tools.calls,
            s.tools.errors,
            percent(s.cache_hit),
            usd(s.cost_usd),
            jev,
            ms(s.span_ms),
        )?;
    }
    Ok(())
}

/// A one-line digest, for `watch` and for headers.
pub fn brief(s: &RunSummary) -> String {
    let mut parts = vec![
        ms(s.span_ms),
        plural(s.turns, "turn", "turns"),
        plural(
            s.requests.root + s.requests.children + s.requests.helpers,
            "request",
            "requests",
        ),
        format!(
            "{} ({} failed)",
            plural(s.tools.calls, "tool", "tools"),
            s.tools.errors
        ),
        usd(s.cost_usd),
        format!("cache {}", percent(s.cache_hit)),
    ];
    if !s.delegation.children.is_empty() {
        parts.push(plural(
            s.delegation.children.len() as u64,
            "child",
            "children",
        ));
    }
    if s.jev.eligible_model || s.jev.calls > 0 {
        parts.push(format!("jev {}", s.jev.calls));
    }
    parts.join(" · ")
}

/// Everything known about one run.
pub fn run_report(w: &mut dyn Write, file: &TraceFile, s: &RunSummary) -> io::Result<()> {
    let pid = s.pid.map_or_else(|| "?".into(), |p| p.to_string());
    let version = if s.version.is_empty() {
        "?"
    } else {
        &s.version
    };
    writeln!(w, "run       {}  (pid {pid}, graff {version})", s.run_id)?;
    writeln!(w, "file      {}", file.path.display())?;
    let mut model = format!("{}/{}", s.provider, s.model);
    if s.models.len() > 1 {
        model += &format!("  (switched: {})", s.models.join(" → "));
    }
    writeln!(w, "model     {model}")?;
    if !s.efforts.is_empty() {
        writeln!(w, "effort    {}", s.efforts.join(" → "))?;
    }
    let mut span = format!(
        "{} · {} ({} ok",
        ms(s.span_ms),
        plural(s.turns, "turn", "turns"),
        s.turns_ok
    );
    if s.interrupts > 0 {
        span += &format!(", {} interrupted", s.interrupts);
    }
    span += ")";
    if let Some(startup) = s.startup_ms {
        span += &format!(" · startup {}", ms(startup));
    }
    writeln!(w, "span      {span}")?;
    let r = &s.requests;
    writeln!(
        w,
        "requests  {} root · {} children · {} helpers · {} failed",
        r.root, r.children, r.helpers, r.errors
    )?;
    writeln!(
        w,
        "latency   first token {} · request {}",
        spread(&s.ttft_ms),
        spread(&s.request_ms)
    )?;
    let t = &s.tokens;
    let mut line = format!(
        "in {} · cached {} ({}) · out {}",
        tokens(t.input),
        tokens(t.cache_read),
        percent(s.cache_hit),
        tokens(t.output)
    );
    if t.reasoning > 0 {
        line += &format!(" · reasoning {}", tokens(t.reasoning));
    }
    if t.cache_write > 0 {
        line += &format!(" · cache writes {}", tokens(t.cache_write));
    }
    if t.prefix_busts > 0 {
        line += &format!(
            " · {}",
            plural(t.prefix_busts, "prefix bust", "prefix busts")
        );
    }
    writeln!(w, "tokens    {line}")?;
    writeln!(w, "cost      {} (finished turns)", usd(s.cost_usd))?;
    writeln!(
        w,
        "tools     {} · {} failed · {} by children and helpers",
        plural(s.tools.calls, "call", "calls"),
        s.tools.errors,
        s.tools.from_children
    )?;
    let top: Vec<String> = s
        .tools
        .by_name
        .iter()
        .take(10)
        .map(|t| match t.errors {
            0 => format!("{} {} ({})", t.name, t.calls, bytes(t.bytes)),
            e => format!("{} {} ({}, {e} failed)", t.name, t.calls, bytes(t.bytes)),
        })
        .collect();
    if !top.is_empty() {
        writeln!(w, "          {}", top.join(" · "))?;
    }
    writeln!(w, "jev       {}", jev_line(s))?;
    delegation(w, &s.delegation)?;
    let rel = &s.reliability;
    let issues: Vec<String> = [
        (rel.retries, "retry", "retries"),
        (rel.stream_retries, "stream retry", "stream retries"),
        (rel.stall_reconnects, "stall reconnect", "stall reconnects"),
        (rel.stalls, "stall", "stalls"),
        (rel.ws_errors, "websocket error", "websocket errors"),
        (rel.context_trims, "context trim", "context trims"),
        (rel.compactions, "compaction", "compactions"),
        (rel.budget_stops, "budget stop", "budget stops"),
    ]
    .into_iter()
    .filter(|(n, ..)| *n > 0)
    .map(|(n, one, many)| plural(n, one, many))
    .collect();
    if !issues.is_empty() {
        writeln!(w, "issues    {}", issues.join(" · "))?;
    }
    if !s.acp_sessions.is_empty() {
        writeln!(w, "acp       {}", s.acp_sessions.join(", "))?;
    }
    if s.unreadable_lines > 0 {
        writeln!(
            w,
            "note      {} of {} lines unreadable",
            s.unreadable_lines, s.lines
        )?;
    }
    Ok(())
}

fn jev_line(s: &RunSummary) -> String {
    let j = &s.jev;
    match (j.eligible_model, j.calls) {
        (false, 0) => "not offered on this route".into(),
        (true, 0) => "offered on this route (with a Codegraff login) · never called".into(),
        (_, calls) => {
            let mut line = format!(
                "{} ({} by children) · {} failed · {}",
                plural(calls, "call", "calls"),
                j.child_calls,
                j.errors,
                ms(j.ms)
            );
            if s.efforts.len() > 1 {
                line += &format!(" · effort {}", s.efforts.join(" → "));
            }
            line
        }
    }
}

fn delegation(w: &mut dyn Write, d: &Delegation) -> io::Result<()> {
    if d.children.is_empty() {
        return writeln!(w, "children  none");
    }
    let mut line = plural(d.children.len() as u64, "child", "children");
    let opt = |label: &str, v: Option<u64>| {
        v.map(|v| format!(" · {label} {}", ms(v)))
            .unwrap_or_default()
    };
    line += &opt("first spawn at", d.first_spawn_at_ms);
    line += &opt("spawn spread", d.spawn_spread_ms);
    line += &opt("critical path", d.child_critical_ms);
    line += &opt("slowest", d.slowest_child_ms);
    if let Some(p) = d.parallelism {
        line += &format!(" · parallel {p:.2}x");
    }
    writeln!(w, "children  {line}")?;
    writeln!(
        w,
        "          parent model {} · parent waited {}{}",
        ms(d.parent_model_ms),
        ms(d.parent_wait_ms),
        opt("tail", d.tail_ms)
    )?;
    for c in &d.children {
        let status = match c.ok {
            Some(true) => "ok",
            Some(false) => "failed",
            None => "?",
        };
        let tools = c.tools.map_or_else(|| "-".into(), |t| t.to_string());
        writeln!(
            w,
            "          {status:<6} {:>7}  {:>3} tools  {:>3} req  {:<7} {}",
            ms(c.ms()),
            tools,
            c.requests,
            c.effort.as_deref().unwrap_or("-"),
            c.label
        )?;
    }
    Ok(())
}

/// One line per live event; `None` for events `watch` hides by default.
pub fn event_line(e: &Event, all: bool) -> Option<String> {
    let at = e
        .t_ms
        .map_or_else(|| "+?".into(), |t| format!("+{}", ms(t)));
    let body = match &e.kind {
        EventKind::Api {
            agent,
            model,
            ms: took,
            context_tokens,
            is_error,
        } => {
            let failed = if *is_error { "  failed" } else { "" };
            format!(
                "request  {}  {model}  {}  ctx {}{failed}",
                clip(agent, 24),
                ms(*took),
                tokens(*context_tokens)
            )
        }
        EventKind::Usage(u) => {
            let hit = (u.input > 0).then(|| u.cache_read as f64 / u.input as f64);
            let bust = if u.prefix_bust { "  prefix bust" } else { "" };
            format!(
                "usage    {}  in {} cached {} ({}) out {}{bust}",
                clip(&u.agent, 24),
                tokens(u.input),
                tokens(u.cache_read),
                percent(hit),
                tokens(u.output)
            )
        }
        EventKind::Tool {
            name,
            ms: took,
            is_error,
            from_sub,
            result_bytes,
        } => {
            let who = if *from_sub { "  (child)" } else { "" };
            let failed = if *is_error { "  failed" } else { "" };
            let label = if name == "jev_effort" {
                "jev     "
            } else {
                "tool    "
            };
            format!(
                "{label} {name}  {}  {}{failed}{who}",
                ms(*took),
                bytes(*result_bytes)
            )
        }
        EventKind::FirstToken {
            agent, ms: took, ..
        } => format!("first    {}  {}", clip(agent, 24), ms(*took)),
        EventKind::Recipe {
            provider,
            model,
            effort,
            ..
        } => format!("turn     {provider}/{model}  effort {effort}"),
        EventKind::Turn(o) => format!(
            "done     {}  effort {}  {}  {} requests  {} tools",
            if o.success { "ok" } else { "not ok" },
            o.effort,
            usd(o.cost_microusd as f64 / 1e6),
            o.model_calls,
            o.tool_calls
        ),
        EventKind::Subagent(run) => format!(
            "child    {}  {}  {} tools  effort {}  {}",
            if run.ok { "ok" } else { "failed" },
            ms(run.ms),
            run.tools,
            run.effort,
            run.label
        ),
        EventKind::Startup { .. } if !all => return None,
        EventKind::Startup { startup_ms } => format!("startup  {}", ms(*startup_ms)),
        EventKind::Note { kind, .. } if !all && kind == "ws" => return None,
        EventKind::Note { kind, detail } => format!("{:<8} {}", clip(kind, 8), clip(detail, 160)),
        EventKind::Other { kind } => kind.clone(),
    };
    Some(format!("{at:>8}  {body}"))
}

pub fn process_line(p: &ProcSample, peak_tree_kb: u64) -> String {
    format!(
        "{:>8}  process  {} pid {} · rss {} · with children {} in {} · peak {} · cpu {} ({:.1}%)",
        "",
        p.command,
        p.pid,
        kb(p.rss_kb),
        kb(p.tree_rss_kb),
        plural(u64::from(p.tree_procs), "process", "processes"),
        kb(peak_tree_kb),
        ms(p.cpu_ms),
        p.cpu_pct
    )
}

/// Totals across runs.
pub fn stats_report(w: &mut dyn Write, s: &Stats) -> io::Result<()> {
    writeln!(
        w,
        "runs      {} · {} · {} · {}",
        s.runs,
        plural(s.turns, "turn", "turns"),
        plural(s.requests, "request", "requests"),
        usd(s.cost_usd)
    )?;
    writeln!(
        w,
        "tokens    in {} · cached {} ({}) · out {}",
        tokens(s.tokens.input),
        tokens(s.tokens.cache_read),
        percent(s.cache_hit),
        tokens(s.tokens.output)
    )?;
    for (i, m) in s.models.iter().take(12).enumerate() {
        writeln!(
            w,
            "{:<9} {:<20} {:>4} runs {:>5} turns {:>6} req {:>9}  first token {}  request {}",
            if i == 0 { "models" } else { "" },
            clip(&m.model, 20),
            m.runs,
            m.turns,
            m.requests,
            usd(m.cost_usd),
            spread(&m.ttft_ms),
            spread(&m.request_ms)
        )?;
    }
    if !s.turn_efforts.is_empty() {
        let efforts: Vec<String> = s
            .turn_efforts
            .iter()
            .map(|c| format!("{} {}", c.name, c.n))
            .collect();
        writeln!(
            w,
            "effort    {}  (root effort at the end of each turn)",
            efforts.join(" · ")
        )?;
    }
    let j = &s.jev;
    writeln!(
        w,
        "jev       {} on routes that offer it ({}) · called in {} · {} ({} by children) · {} failed",
        plural(j.eligible_runs, "run", "runs"),
        plural(j.eligible_turns, "turn", "turns"),
        plural(j.runs_with_calls, "run", "runs"),
        plural(j.calls, "call", "calls"),
        j.child_calls,
        j.errors
    )?;
    let d = &s.delegation;
    writeln!(
        w,
        "children  {} delegated · {} ({} failed) · child time {} · critical paths {} · parent waited {}",
        plural(d.runs_with_children, "run", "runs"),
        plural(d.children, "child", "children"),
        d.failed_children,
        ms(d.child_ms),
        ms(d.child_critical_ms),
        ms(d.parent_wait_ms)
    )?;
    let top: Vec<String> = s
        .tools
        .iter()
        .take(12)
        .map(|t| match t.errors {
            0 => format!("{} {}", t.name, t.calls),
            e => format!("{} {} ({e} failed)", t.name, t.calls),
        })
        .collect();
    if !top.is_empty() {
        writeln!(w, "tools     {}", top.join(" · "))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summary::Observer;
    use crate::summary::tests::RUN;

    fn summary() -> RunSummary {
        let mut observer = Observer::new();
        for line in RUN.lines() {
            observer.push_line(line);
        }
        observer.summary()
    }

    #[test]
    fn units() {
        assert_eq!(
            (ms(850), ms(12_340), ms(192_000), ms(3_900_000)),
            (
                "850ms".into(),
                "12.3s".into(),
                "3m12s".into(),
                "1h05m".into()
            )
        );
        assert_eq!(
            (tokens(950), tokens(12_300), tokens(1_200_000)),
            ("950".into(), "12.3k".into(), "1.20M".into())
        );
        assert_eq!(
            (usd(0.0), usd(0.00001), usd(0.0031), usd(0.42)),
            (
                "$0".into(),
                "<$0.0001".into(),
                "$0.0031".into(),
                "$0.42".into()
            )
        );
        assert_eq!(clip("abcdef", 4), "abc…");
    }

    #[test]
    fn the_report_names_what_matters() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("r1.jsonl");
        std::fs::write(&path, RUN).unwrap();
        let file = TraceFile::open(&path).unwrap();
        let mut out = Vec::new();
        run_report(&mut out, &file, &summary()).unwrap();
        let text = String::from_utf8(out).unwrap();
        for needle in [
            "effort    medium → high",
            "2 turns (1 ok, 1 interrupted)",
            "3 root · 1 children · 1 helpers",
            "first token p50 1.5s",
            "cached 900 (30%)",
            "$0.04",
            "2 calls (1 by children)",
            "critical path 12.0s",
            "failed   12.0s",
            "Fix lexer",
            "1 retry",
            "1 of 27 lines unreadable",
        ] {
            assert!(text.contains(needle), "missing {needle:?} in\n{text}");
        }
        let mut table = Vec::new();
        runs_table(&mut table, &[(file, summary())]).unwrap();
        let table = String::from_utf8(table).unwrap();
        assert!(table.contains("medium→high"), "{table}");
    }

    #[test]
    fn watch_hides_transport_noise_unless_asked() {
        let ws = Event {
            t_ms: Some(1),
            kind: EventKind::Note {
                kind: "ws".into(),
                detail: "connected".into(),
            },
        };
        assert!(event_line(&ws, false).is_none());
        assert!(event_line(&ws, true).unwrap().contains("connected"));
        let jev = Event {
            t_ms: Some(3600),
            kind: EventKind::Tool {
                name: "jev_effort".into(),
                ms: 550,
                is_error: false,
                from_sub: true,
                result_bytes: 60,
            },
        };
        let line = event_line(&jev, false).unwrap();
        assert!(
            line.contains("jev") && line.contains("550ms") && line.contains("(child)"),
            "{line}"
        );
    }
}
