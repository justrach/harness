//! Tool-output x-ray: where a session's context goes. Every tool output graff sent
//! the model is sized (estimated tokens, `ceil(characters / 4)`, not billing
//! data) and checked for the common sources of context growth, each with the
//! tokens a compact form would save:
//!
//! - large output: a result near or over graff's handle threshold;
//! - repeated content: the same line many times in one output;
//! - repeated keys: a JSON array whose objects repeat the same field names;
//! - repeated paths: one directory prefix written out on line after line;
//! - repeated calls: a tool returning an output it already returned.
//!
//! Savings are estimates of what a compact rendering would drop. Outputs are
//! read from the local transcript and never leave the machine.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

use crate::transcript::{ToolCall, Transcript, est_tokens};

/// Outputs this size and up are flagged as large (~8 KiB of text).
const LARGE_TOKENS: u64 = 2_048;
/// A finding must save at least this much to be reported.
const MIN_SAVINGS: u64 = 32;
/// A line must repeat this often, and be this long, to count.
const LINE_REPEATS: usize = 3;
const LINE_MIN_CHARS: usize = 8;
/// A path prefix must appear this often, and be this long, to count.
const PATH_REPEATS: u64 = 5;
const PATH_MIN_CHARS: usize = 12;
/// Shorter outputs are not compared for repeated calls.
const REPEAT_MIN_CHARS: usize = 100;
/// Tools whose large outputs are command logs, where an errors-and-warnings
/// filter is a fair compaction. A file read or a schema is not a log.
const LOG_TOOLS: &[&str] = &[
    "shell",
    "bash",
    "bash_output",
    "exec",
    "exec_command",
    "run_command",
    "terminal",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FindingKind {
    LargeOutput,
    RepeatedContent,
    RepeatedKeys,
    RepeatedPaths,
    RepeatedCalls,
}

impl FindingKind {
    pub fn label(self) -> &'static str {
        match self {
            FindingKind::LargeOutput => "large output",
            FindingKind::RepeatedContent => "repeated content",
            FindingKind::RepeatedKeys => "repeated keys",
            FindingKind::RepeatedPaths => "repeated paths",
            FindingKind::RepeatedCalls => "repeated calls",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub kind: FindingKind,
    /// Which session, when several are totalled.
    pub session: String,
    pub tool: String,
    /// The call's position among the session's tool outputs, from 1.
    pub call: usize,
    pub savings_tokens: u64,
    /// What repeats, how often, or what a filter would keep.
    pub detail: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ToolBudget {
    pub tool: String,
    pub calls: u64,
    pub tokens: u64,
    pub largest_tokens: u64,
    /// Tokens times the requests made after each output (upper bound).
    pub carried_tokens: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct KindSummary {
    pub kind: Option<FindingKind>,
    pub count: u64,
    pub savings_tokens: u64,
    /// Largest savings first.
    pub examples: Vec<Finding>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Xray {
    pub sessions: u64,
    pub calls: u64,
    pub requests: u64,
    /// Estimated tokens of every tool output sent to the model.
    pub output_tokens: u64,
    /// Estimated tokens of the calls' arguments (written by the model).
    pub argument_tokens: u64,
    /// Outputs graff already replaced with a handle (preview plus file).
    pub handles: u64,
    /// Σ output tokens × requests made after it: an upper bound on re-sending.
    pub carried_tokens: u64,
    /// Most tokens first.
    pub by_tool: Vec<ToolBudget>,
    /// One entry per finding kind that occurred.
    pub findings: Vec<KindSummary>,
    /// Per output the largest applicable saving, so overlaps count once.
    pub savings_tokens: u64,
}

/// Builds an X-ray over one or more sessions.
#[derive(Default)]
pub struct XrayBuilder {
    xray: Xray,
    tools: HashMap<String, ToolBudget>,
    findings: Vec<Finding>,
    top: usize,
}

impl XrayBuilder {
    /// `top`: examples kept per finding kind.
    pub fn new(top: usize) -> Self {
        XrayBuilder {
            top,
            ..Default::default()
        }
    }

    pub fn add(&mut self, session: &str, transcript: &Transcript) {
        let x = &mut self.xray;
        x.sessions += 1;
        x.calls += transcript.calls.len() as u64;
        x.requests += transcript.requests;
        let mut seen: HashMap<(&str, &str), usize> = HashMap::new();
        for (i, call) in transcript.calls.iter().enumerate() {
            let tokens = est_tokens(&call.output);
            x.output_tokens += tokens;
            x.argument_tokens += est_tokens(&call.arguments);
            x.carried_tokens += tokens * call.requests_after;
            x.handles += u64::from(is_handle(&call.output));
            let budget = self
                .tools
                .entry(call.name.clone())
                .or_insert_with(|| ToolBudget {
                    tool: call.name.clone(),
                    ..Default::default()
                });
            budget.calls += 1;
            budget.tokens += tokens;
            budget.largest_tokens = budget.largest_tokens.max(tokens);
            budget.carried_tokens += tokens * call.requests_after;

            let finding = |kind, savings_tokens, detail| Finding {
                kind,
                session: session.to_string(),
                tool: call.name.clone(),
                call: i + 1,
                savings_tokens,
                detail,
            };
            // A repeat of an earlier output is wholly redundant; nothing else applies.
            if call.output.chars().count() >= REPEAT_MIN_CHARS {
                if let Some(first) = seen.get(&(call.name.as_str(), call.output.as_str())) {
                    let same_args = transcript.calls[*first].arguments == call.arguments;
                    let how = if same_args {
                        "same arguments"
                    } else {
                        "different arguments"
                    };
                    self.findings.push(finding(
                        FindingKind::RepeatedCalls,
                        tokens,
                        format!("same output as call {} ({how})", first + 1),
                    ));
                    x.savings_tokens += tokens;
                    continue;
                }
                seen.insert((call.name.as_str(), call.output.as_str()), i);
            }
            let found: Vec<Finding> = [
                large_output(call).map(|(s, d)| finding(FindingKind::LargeOutput, s, d)),
                repeated_lines(&call.output)
                    .map(|(s, d)| finding(FindingKind::RepeatedContent, s, d)),
                repeated_keys(&call.output).map(|(s, d)| finding(FindingKind::RepeatedKeys, s, d)),
                repeated_paths(&call.output)
                    .map(|(s, d)| finding(FindingKind::RepeatedPaths, s, d)),
            ]
            .into_iter()
            .flatten()
            .collect();
            x.savings_tokens += found
                .iter()
                .map(|f| f.savings_tokens)
                .max()
                .unwrap_or(0)
                .min(tokens);
            self.findings.extend(found);
        }
    }

    pub fn finish(mut self) -> Xray {
        let mut by_tool: Vec<ToolBudget> = self.tools.into_values().collect();
        by_tool.sort_by(|a, b| b.tokens.cmp(&a.tokens).then_with(|| a.tool.cmp(&b.tool)));
        self.xray.by_tool = by_tool;
        let mut kinds: HashMap<FindingKind, KindSummary> = HashMap::new();
        self.findings.sort_by(|a, b| {
            b.savings_tokens
                .cmp(&a.savings_tokens)
                .then_with(|| a.call.cmp(&b.call))
        });
        for f in self.findings {
            let summary = kinds.entry(f.kind).or_insert_with(|| KindSummary {
                kind: Some(f.kind),
                ..Default::default()
            });
            summary.count += 1;
            summary.savings_tokens += f.savings_tokens;
            if summary.examples.len() < self.top {
                summary.examples.push(f);
            }
        }
        let mut findings: Vec<KindSummary> = kinds.into_values().collect();
        findings.sort_by_key(|k| k.kind);
        self.xray.findings = findings;
        self.xray
    }
}

/// graff's handle for a result over its threshold (preview plus file).
fn is_handle(output: &str) -> bool {
    output.contains("handle tr_") || output.contains(".graff/tool-results/tr_")
}

/// A large output; for a command log, what keeping errors and warnings
/// (±1 line), plus the first and last five lines, would save.
fn large_output(call: &ToolCall) -> Option<(u64, String)> {
    let tokens = est_tokens(&call.output);
    if tokens < LARGE_TOKENS {
        return None;
    }
    let lines: Vec<&str> = call.output.lines().collect();
    let handle = if is_handle(&call.output) {
        ", already a handle"
    } else {
        ""
    };
    let important = |l: &str| {
        let l = l.to_ascii_lowercase();
        ["error", "warn", "fail", "panic", "exception", "fatal"]
            .iter()
            .any(|w| l.contains(w))
    };
    if lines.len() >= 40 && LOG_TOOLS.contains(&call.name.as_str()) {
        let mut keep = vec![false; lines.len()];
        for (i, line) in lines.iter().enumerate() {
            if i < 5 || i + 5 >= lines.len() {
                keep[i] = true;
            }
            if important(line) {
                for k in keep
                    .iter_mut()
                    .take((i + 2).min(lines.len()))
                    .skip(i.saturating_sub(1))
                {
                    *k = true;
                }
            }
        }
        let kept: Vec<&str> = lines
            .iter()
            .zip(&keep)
            .filter(|(_, k)| **k)
            .map(|(l, _)| *l)
            .collect();
        let saved = tokens.saturating_sub(est_tokens(&kept.join("\n")));
        let detail = format!(
            "{} lines; errors/warnings ±1 keep {}{handle}",
            lines.len(),
            kept.len()
        );
        return Some((saved, detail));
    }
    Some((0, format!("{} tokens{handle}", tokens)))
}

/// Lines repeated in one output: keeping one copy of each saves the rest.
fn repeated_lines(output: &str) -> Option<(u64, String)> {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for line in output
        .lines()
        .map(str::trim)
        .filter(|l| l.chars().count() >= LINE_MIN_CHARS)
    {
        *counts.entry(line).or_default() += 1;
    }
    let mut saved = 0;
    let mut best: Option<(u64, &str, usize)> = None;
    for (line, n) in counts.into_iter().filter(|(_, n)| *n >= LINE_REPEATS) {
        let s = (n as u64 - 1) * est_tokens(line);
        saved += s;
        if best.is_none_or(|(b, l, _)| s > b || (s == b && line < l)) {
            best = Some((s, line, n));
        }
    }
    let (_, line, n) = best?;
    (saved >= MIN_SAVINGS).then(|| (saved, format!("{} ×{n}", quote(line))))
}

/// JSON arrays of objects with the same fields: naming each field once (a
/// table) saves the repeated names.
fn repeated_keys(output: &str) -> Option<(u64, String)> {
    let text = output.trim();
    if !(text.starts_with('{') || text.starts_with('[')) {
        return None;
    }
    let value: Value = serde_json::from_str(text).ok()?;
    let mut saved = 0;
    let mut best: Option<(u64, usize, usize)> = None;
    walk_arrays(&value, &mut |items| {
        let mut groups: HashMap<Vec<&str>, usize> = HashMap::new();
        for item in items {
            if let Value::Object(map) = item {
                let mut keys: Vec<&str> = map.keys().map(String::as_str).collect();
                keys.sort_unstable();
                *groups.entry(keys).or_default() += 1;
            }
        }
        for (keys, n) in groups.into_iter().filter(|(k, n)| *n >= 3 && !k.is_empty()) {
            let per_object: u64 = keys.iter().map(|k| est_tokens(&format!("\"{k}\":"))).sum();
            let s = (n as u64 - 1) * per_object;
            saved += s;
            if best.is_none_or(|(b, ..)| s > b) {
                best = Some((s, n, keys.len()));
            }
        }
    });
    let (_, n, keys) = best?;
    (saved >= MIN_SAVINGS).then(|| (saved, format!("{n} objects × {keys} keys")))
}

fn walk_arrays<'a>(value: &'a Value, visit: &mut impl FnMut(&'a [Value])) {
    match value {
        Value::Array(items) => {
            visit(items);
            for item in items {
                walk_arrays(item, visit);
            }
        }
        Value::Object(map) => {
            for item in map.values() {
                walk_arrays(item, visit);
            }
        }
        _ => {}
    }
}

/// One directory prefix written out again and again: an alias for it saves
/// all but one copy.
fn repeated_paths(output: &str) -> Option<(u64, String)> {
    let mut counts: HashMap<&str, u64> = HashMap::new();
    let is_path_char = |c: char| c.is_ascii_alphanumeric() || "._-~/@+".contains(c);
    for word in output.split(|c: char| !is_path_char(c)) {
        if word.matches('/').count() < 2 {
            continue;
        }
        // Every ancestor directory of the word, each counted once per word.
        for (i, _) in word.match_indices('/').skip(1) {
            let prefix = &word[..=i];
            if prefix.chars().count() >= PATH_MIN_CHARS {
                *counts.entry(prefix).or_default() += 1;
            }
        }
    }
    let (prefix, n) = counts
        .into_iter()
        .filter(|(_, n)| *n >= PATH_REPEATS)
        .max_by_key(|(p, n)| ((n - 1) * est_tokens(p), std::cmp::Reverse(*p)))?;
    let saved = (n - 1) * est_tokens(prefix);
    (saved >= MIN_SAVINGS).then(|| (saved, format!("{} ×{n}", quote(prefix))))
}

fn quote(text: &str) -> String {
    let clipped: String = text.chars().take(60).collect();
    if clipped.len() < text.len() {
        format!("\"{clipped}…\"")
    } else {
        format!("\"{clipped}\"")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(name: &str, arguments: &str, output: &str, requests_after: u64) -> ToolCall {
        ToolCall {
            name: name.into(),
            arguments: arguments.into(),
            output: output.into(),
            requests_after,
        }
    }

    fn xray(calls: Vec<ToolCall>) -> Xray {
        let transcript = Transcript {
            requests: 10,
            calls,
            ..Default::default()
        };
        let mut builder = XrayBuilder::new(3);
        builder.add("s1", &transcript);
        builder.finish()
    }

    fn kind(x: &Xray, kind: FindingKind) -> &KindSummary {
        x.findings
            .iter()
            .find(|k| k.kind == Some(kind))
            .unwrap_or_else(|| panic!("no {kind:?} in {x:#?}"))
    }

    #[test]
    fn repeated_lines_keep_one_copy() {
        let warning = "warning: unused import `std::fmt`";
        let output = format!("{}\nbuild ok\n", vec![warning; 50].join("\n"));
        let (saved, detail) = repeated_lines(&output).unwrap();
        assert_eq!(saved, 49 * est_tokens(warning));
        assert!(detail.ends_with("×50"), "{detail}");
        assert!(repeated_lines("a long line here\na long line here\nother line").is_none());
    }

    #[test]
    fn repeated_keys_count_field_names_after_the_first_object() {
        let rows: Vec<String> = (0..20)
            .map(|i| format!(r#"{{"id":{i},"name":"n{i}","status":"open"}}"#))
            .collect();
        let output = format!(r#"{{"items":[{}]}}"#, rows.join(","));
        let (saved, detail) = repeated_keys(&output).unwrap();
        let per_object =
            est_tokens("\"id\":") + est_tokens("\"name\":") + est_tokens("\"status\":");
        assert_eq!(saved, 19 * per_object);
        assert_eq!(detail, "20 objects × 3 keys");
        assert!(repeated_keys("not json").is_none());
        assert!(repeated_keys(r#"[{"a":1},{"b":2},{"c":3}]"#).is_none());
    }

    #[test]
    fn repeated_paths_pick_the_most_expensive_prefix() {
        let lines: Vec<String> = (0..30)
            .map(|i| format!("/workspace/project/src/module_{i}.rs:12: match"))
            .collect();
        let (saved, detail) = repeated_paths(&lines.join("\n")).unwrap();
        assert_eq!(detail, "\"/workspace/project/src/\" ×30");
        assert_eq!(saved, 29 * est_tokens("/workspace/project/src/"));
        assert!(repeated_paths("one/two/three/file.rs and nothing else").is_none());
    }

    #[test]
    fn large_logs_estimate_an_errors_and_warnings_filter() {
        let mut log: Vec<String> = (0..1000)
            .map(|i| format!("   Compiling crate_{i:04} v0.1.0 (/home/me/deps/crate_{i:04})"))
            .collect();
        log[500] = "error[E0308]: mismatched types".into();
        let c = call("shell", r#"{"cmd":"cargo build"}"#, &log.join("\n"), 1);
        let (saved, detail) = large_output(&c).unwrap();
        assert!(
            detail.starts_with("1000 lines; errors/warnings ±1 keep 13"),
            "{detail}"
        );
        assert!(saved > est_tokens(&c.output) * 9 / 10);
        let short = call("read_file", "", &"x".repeat(9000), 1);
        assert_eq!(large_output(&short).unwrap().0, 0);
        // The same lines read from a file are not a log to filter.
        let file = call("read_file", r#"{"path":"build.log"}"#, &log.join("\n"), 1);
        assert_eq!(large_output(&file).unwrap().0, 0);
        assert!(large_output(&call("read_file", "", "small", 1)).is_none());
    }

    #[test]
    fn a_repeated_output_is_one_finding_and_counts_whole() {
        let body = "line of the file that is long enough to count as content\n".repeat(4);
        let x = xray(vec![
            call("read_file", r#"{"path":"a"}"#, &body, 5),
            call("shell", "{}", "short", 4),
            call("read_file", r#"{"path":"a"}"#, &body, 3),
            call("read_file", r#"{"path":"b"}"#, &body, 1),
        ]);
        let repeats = kind(&x, FindingKind::RepeatedCalls);
        assert_eq!(repeats.count, 2);
        assert_eq!(
            repeats.examples[0].detail,
            "same output as call 1 (same arguments)"
        );
        assert_eq!(
            repeats.examples[1].detail,
            "same output as call 1 (different arguments)"
        );
        let tokens = est_tokens(&body);
        // The first copy's own repeated lines count once; the two repeats count whole.
        let first_lines = repeated_lines(&body).unwrap().0;
        assert_eq!(x.savings_tokens, 2 * tokens + first_lines);
        assert_eq!(
            x.carried_tokens,
            tokens * 5 + est_tokens("short") * 4 + tokens * 3 + tokens
        );
        assert_eq!(x.by_tool[0].tool, "read_file");
        assert_eq!(x.by_tool[0].calls, 3);
        assert_eq!((x.calls, x.requests, x.sessions), (4, 10, 1));
    }

    #[test]
    fn overlapping_findings_count_the_largest_saving_once() {
        let lines: Vec<String> = (0..60)
            .map(|_| "/workspace/project/src/lib.rs:1: warning: unused".to_string())
            .collect();
        let x = xray(vec![call("grep", "{}", &lines.join("\n"), 2)]);
        let content = kind(&x, FindingKind::RepeatedContent).savings_tokens;
        let paths = kind(&x, FindingKind::RepeatedPaths).savings_tokens;
        assert_eq!(x.savings_tokens, content.max(paths));
    }

    #[test]
    fn handles_are_counted() {
        let x = xray(vec![call(
            "shell",
            "{}",
            "preview…\n[handle tr_3 · 120000 bytes · .graff/tool-results/tr_3.txt]",
            1,
        )]);
        assert_eq!(x.handles, 1);
    }
}
