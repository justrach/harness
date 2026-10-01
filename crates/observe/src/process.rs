//! Memory and CPU of a live graff process and everything it started (shell
//! commands, MCP servers). graff does not trace these itself; every trace
//! line carries its pid, so the observer samples the process from outside.

use std::collections::{HashMap, HashSet};
use std::process::Command;

use serde::Serialize;

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ProcSample {
    pub pid: u32,
    /// The executable name, to tell a reused pid from graff.
    pub command: String,
    pub rss_kb: u64,
    /// `ps`'s CPU percentage (a decaying average on macOS).
    pub cpu_pct: f32,
    /// CPU time used so far.
    pub cpu_ms: u64,
    /// The process plus all of its descendants.
    pub tree_rss_kb: u64,
    pub tree_procs: u32,
}

/// `None` when the process is gone or `ps` is unavailable (Windows).
pub fn sample_process(pid: u32) -> Option<ProcSample> {
    if cfg!(windows) {
        return None;
    }
    let out = Command::new("ps")
        .args(["-Ao", "pid=,ppid=,rss=,%cpu=,time=,comm="])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    from_ps(&String::from_utf8_lossy(&out.stdout), pid)
}

struct Row<'a> {
    rss_kb: u64,
    cpu_pct: f32,
    cpu_ms: u64,
    command: &'a str,
}

fn from_ps(table: &str, pid: u32) -> Option<ProcSample> {
    let mut rows = HashMap::new();
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for line in table.lines() {
        let mut cols = line.split_whitespace();
        let (Some(p), Some(pp), Some(rss), Some(cpu), Some(time)) = (
            cols.next(),
            cols.next(),
            cols.next(),
            cols.next(),
            cols.next(),
        ) else {
            continue;
        };
        let (Ok(p), Ok(ppid)) = (p.parse::<u32>(), pp.parse::<u32>()) else {
            continue;
        };
        rows.insert(
            p,
            Row {
                rss_kb: rss.parse().unwrap_or(0),
                cpu_pct: cpu.parse().unwrap_or(0.0),
                cpu_ms: cpu_time_ms(time).unwrap_or(0),
                // The command is the rest of the line and may contain spaces.
                command: field_start(line, 5).map_or("", |at| line[at..].trim_end()),
            },
        );
        children.entry(ppid).or_default().push(p);
    }
    let me = rows.get(&pid)?;
    let mut sample = ProcSample {
        pid,
        // `comm` is the executable's path, which may contain spaces.
        command: me
            .command
            .rsplit('/')
            .next()
            .unwrap_or(me.command)
            .to_string(),
        rss_kb: me.rss_kb,
        cpu_pct: me.cpu_pct,
        cpu_ms: me.cpu_ms,
        ..Default::default()
    };
    let mut seen = HashSet::new();
    let mut stack = vec![pid];
    while let Some(p) = stack.pop() {
        if !seen.insert(p) {
            continue;
        }
        if let Some(row) = rows.get(&p) {
            sample.tree_rss_kb += row.rss_kb;
            sample.tree_procs += 1;
        }
        if let Some(kids) = children.get(&p) {
            stack.extend(kids);
        }
    }
    Some(sample)
}

/// Byte offset of the `n`th (0-based) whitespace-separated field.
fn field_start(line: &str, n: usize) -> Option<usize> {
    let mut seen = 0;
    let mut in_field = false;
    for (i, c) in line.char_indices() {
        if c.is_whitespace() {
            in_field = false;
        } else if !in_field {
            if seen == n {
                return Some(i);
            }
            seen += 1;
            in_field = true;
        }
    }
    None
}

/// `ps` CPU time: `M:SS.ss` on macOS, `[D-]HH:MM:SS` on Linux.
fn cpu_time_ms(text: &str) -> Option<u64> {
    let (days, clock) = match text.split_once('-') {
        Some((d, rest)) => (d.parse::<u64>().ok()?, rest),
        None => (0, text),
    };
    let mut secs = 0.0;
    for part in clock.split(':') {
        secs = secs * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(days * 86_400_000 + (secs * 1000.0).round() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums_the_process_tree() {
        let table = "\
    1     0  9000   0.0   1:00.00 /sbin/launchd
  500     1 30000   2.5   0:00.91 /Users/me/.local/bin/graff
  501   500 20000   0.1   0:00.10 /bin/zsh -c cargo test
  502   501  3000   0.0   0:00.01 sleep 5
  600     1 99999   9.9   0:09.00 other
";
        let s = from_ps(table, 500).unwrap();
        assert_eq!(s.command, "graff");
        assert_eq!((s.rss_kb, s.cpu_ms), (30_000, 910));
        assert!((s.cpu_pct - 2.5).abs() < 1e-6);
        assert_eq!((s.tree_rss_kb, s.tree_procs), (53_000, 3));
        assert!(from_ps(table, 4242).is_none());
    }

    #[test]
    fn reads_both_cpu_time_formats() {
        assert_eq!(cpu_time_ms("0:00.91"), Some(910));
        assert_eq!(cpu_time_ms("12:34.50"), Some(754_500));
        assert_eq!(cpu_time_ms("01:02:03"), Some(3_723_000));
        assert_eq!(cpu_time_ms("1-00:00:01"), Some(86_401_000));
        assert_eq!(cpu_time_ms("x"), None);
    }

    #[cfg(unix)]
    #[test]
    fn samples_this_test_process() {
        let s = sample_process(std::process::id()).expect("ps sees us");
        assert!(s.rss_kb > 0 && s.tree_procs >= 1);
    }
}
