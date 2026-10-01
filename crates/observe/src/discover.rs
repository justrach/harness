//! Finds trace files. graff writes `<project>/.graff/traces/<run-id>.jsonl`,
//! one file per graff process, and never renames them.

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, bail};
use serde::Serialize;

use crate::event::{EventKind, parse_line};

/// How deep a folder without its own traces is searched for projects.
const MAX_DEPTH: usize = 4;
/// Folders that never hold a project's traces but can be huge.
const SKIP: &[&str] = &["node_modules", "target", "Library", "zig-cache", "zig-out"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TraceFile {
    pub path: PathBuf,
    pub run_id: String,
    #[serde(skip)]
    pub modified: SystemTime,
    pub modified_unix: u64,
    pub size: u64,
}

impl TraceFile {
    pub fn open(path: &Path) -> io::Result<Self> {
        let meta = fs::metadata(path)?;
        let modified = meta.modified().unwrap_or(UNIX_EPOCH);
        Ok(TraceFile {
            path: path.to_path_buf(),
            run_id: path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default(),
            modified,
            modified_unix: modified
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_secs()),
            size: meta.len(),
        })
    }

    /// The project folder's name: the parent of `.graff`.
    pub fn project(&self) -> Option<String> {
        let graff = self.path.parent()?.parent()?;
        if graff.file_name()? != ".graff" {
            return None;
        }
        Some(graff.parent()?.file_name()?.to_string_lossy().into_owned())
    }
}

/// Trace files under `roots`, newest first. A root may be a trace file, a
/// `.graff/traces` folder, a `.graff` folder, a project, or a folder of
/// projects (searched a few levels deep, skipping hidden folders other than
/// `.worktrees`).
pub fn discover(roots: &[PathBuf]) -> anyhow::Result<Vec<TraceFile>> {
    let mut dirs = BTreeSet::new();
    let mut files = BTreeSet::new();
    for root in roots {
        let meta = fs::metadata(root).with_context(|| format!("{}", root.display()))?;
        if meta.is_file() {
            files.insert(root.clone());
        } else if root.file_name().is_some_and(|n| n == "traces") {
            dirs.insert(root.clone());
        } else if root.file_name().is_some_and(|n| n == ".graff") {
            dirs.insert(root.join("traces"));
        } else {
            walk(root, 0, &mut dirs);
        }
    }
    for dir in &dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "jsonl") {
                files.insert(path);
            }
        }
    }
    let mut out: Vec<TraceFile> = files
        .iter()
        .filter_map(|p| TraceFile::open(p).ok())
        .collect();
    out.sort_by(|a, b| {
        b.modified
            .cmp(&a.modified)
            .then_with(|| a.path.cmp(&b.path))
    });
    Ok(out)
}

fn walk(dir: &Path, depth: usize, out: &mut BTreeSet<PathBuf>) {
    let traces = dir.join(".graff").join("traces");
    if traces.is_dir() {
        out.insert(traces);
    }
    if depth >= MAX_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        // `file_type` does not follow symlinks, so a link loop is never walked.
        if !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if (name.starts_with('.') && name != ".worktrees") || SKIP.contains(&name.as_ref()) {
            continue;
        }
        walk(&entry.path(), depth + 1, out);
    }
}

/// Keeps runs written at or after `since`.
pub fn written_since(files: Vec<TraceFile>, since: Option<SystemTime>) -> Vec<TraceFile> {
    match since {
        Some(since) => files.into_iter().filter(|f| f.modified >= since).collect(),
        None => files,
    }
}

/// `90m`, `24h`, `7d`, `2w` ago, or a `YYYY-MM-DD` date (UTC midnight).
pub fn parse_since(text: &str) -> anyhow::Result<SystemTime> {
    let text = text.trim();
    if let Some((y, md)) = text.split_once('-') {
        let (m, d) = md.split_once('-').context("dates look like 2026-09-23")?;
        let days = days_from_civil(y.parse()?, m.parse()?, d.parse()?);
        let secs = u64::try_from(days * 86_400).context("dates before 1970 are not supported")?;
        return Ok(UNIX_EPOCH + Duration::from_secs(secs));
    }
    let split = text
        .find(|c: char| !c.is_ascii_digit())
        .context("give a unit: 90m, 24h, 7d")?;
    let n: u64 = text[..split]
        .parse()
        .context("give a number before the unit")?;
    let unit = match &text[split..] {
        "m" => 60,
        "h" => 3600,
        "d" => 86_400,
        "w" => 7 * 86_400,
        other => bail!("unknown unit `{other}`: use m, h, d or w"),
    };
    Ok(SystemTime::now() - Duration::from_secs(n * unit))
}

/// Days since 1970-01-01 for a proleptic Gregorian date.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// A run id or prefix, or a trace file path; `None` picks the newest run.
pub fn resolve(roots: &[PathBuf], run: Option<&str>) -> anyhow::Result<TraceFile> {
    if let Some(run) = run {
        let path = Path::new(run);
        if path.is_file() {
            return Ok(TraceFile::open(path)?);
        }
    }
    let files = discover(roots)?;
    let Some(run) = run else {
        return files
            .into_iter()
            .next()
            .context("no graff traces here (looked for .graff/traces)");
    };
    let mut matches: Vec<TraceFile> = files
        .into_iter()
        .filter(|f| f.run_id.starts_with(run))
        .collect();
    match matches.len() {
        0 => bail!("no run matching `{run}`"),
        1 => Ok(matches.remove(0)),
        n => bail!(
            "`{run}` matches {n} runs; give more of the id: {}",
            matches
                .iter()
                .take(5)
                .map(|f| f.run_id.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// The newest run written by the graff process `pid`.
pub fn find_by_pid(roots: &[PathBuf], pid: u32) -> Option<TraceFile> {
    discover(roots)
        .ok()?
        .into_iter()
        .find(|f| first_pid(&f.path) == Some(pid))
}

fn first_pid(path: &Path) -> Option<u32> {
    let mut line = String::new();
    BufReader::new(File::open(path).ok()?)
        .read_line(&mut line)
        .ok()?;
    parse_line(&line)?.0.pid
}

/// The newest run that served the ACP session `acp_session_id`.
pub fn find_by_acp_session(roots: &[PathBuf], acp_session_id: &str) -> Option<TraceFile> {
    discover(roots)
        .ok()?
        .into_iter()
        .find(|f| served(&f.path, acp_session_id))
}

fn served(path: &Path, acp_session_id: &str) -> bool {
    let Ok(file) = File::open(path) else {
        return false;
    };
    BufReader::new(file).lines().map_while(Result::ok).any(|line| {
        line.contains("\"acp_prompt\"")
            && line.contains(acp_session_id)
            && matches!(parse_line(&line), Some((_, e)) if matches!(&e.kind,
                EventKind::Note { kind, detail } if kind == "acp_prompt" && detail == acp_session_id))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread::sleep;

    fn write(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    #[test]
    fn finds_projects_newest_first_and_skips_heavy_folders() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let old = root.join("alpha/.graff/traces/run-old.jsonl");
        write(
            &old,
            "{\"run_id\":\"run-old\",\"pid\":11,\"t\":0,\"ev\":\"session\",\"detail\":\"m\"}\n",
        );
        sleep(Duration::from_millis(20));
        let new = root.join("work/beta/.worktrees/wt/.graff/traces/run-new.jsonl");
        write(
            &new,
            "{\"run_id\":\"run-new\",\"pid\":22,\"t\":0,\"ev\":\"session\",\"detail\":\"m\"}\n\
             {\"run_id\":\"run-new\",\"pid\":22,\"t\":5,\"ev\":\"acp_prompt\",\"detail\":\"session-9\"}\n",
        );
        write(
            &root.join("node_modules/x/.graff/traces/hidden.jsonl"),
            "{}\n",
        );
        write(&root.join(".cache/.graff/traces/hidden2.jsonl"), "{}\n");
        let found = discover(&[root.to_path_buf()]).unwrap();
        let ids: Vec<&str> = found.iter().map(|f| f.run_id.as_str()).collect();
        assert_eq!(ids, ["run-new", "run-old"]);
        assert_eq!(found[1].project().as_deref(), Some("alpha"));
        assert_eq!(found[0].project().as_deref(), Some("wt"));
        // A traces folder or a single file works as a root too.
        assert_eq!(
            discover(&[root.join("alpha/.graff/traces")]).unwrap().len(),
            1
        );
        assert_eq!(discover(&[old]).unwrap()[0].run_id, "run-old");
        let roots = [root.to_path_buf()];
        assert_eq!(find_by_pid(&roots, 11).unwrap().run_id, "run-old");
        assert!(find_by_pid(&roots, 99).is_none());
        assert_eq!(
            find_by_acp_session(&roots, "session-9").unwrap().run_id,
            "run-new"
        );
        assert!(find_by_acp_session(&roots, "session-1").is_none());
        assert_eq!(resolve(&roots, None).unwrap().run_id, "run-new");
        assert_eq!(resolve(&roots, Some("run-o")).unwrap().run_id, "run-old");
        assert!(resolve(&roots, Some("run-")).is_err());
        assert!(resolve(&roots, Some("zzz")).is_err());
        assert!(discover(&[root.join("missing")]).is_err());
    }

    #[test]
    fn since_takes_durations_and_dates() {
        let day = parse_since("2026-09-23").unwrap();
        assert_eq!(
            day.duration_since(UNIX_EPOCH).unwrap().as_secs(),
            1_790_121_600
        );
        assert_eq!(parse_since("1970-01-01").unwrap(), UNIX_EPOCH);
        let week = parse_since("7d").unwrap();
        let ago = SystemTime::now().duration_since(week).unwrap().as_secs();
        assert!((7 * 86_400..7 * 86_400 + 5).contains(&ago));
        assert!(parse_since("7").is_err());
        assert!(parse_since("7y").is_err());
        assert!(parse_since("2026-09").is_err());
    }
}
