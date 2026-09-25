//! Per-session on-disk event journal (port of harness's `run-journal.ts`, JSONL-shaped).
//!
//! One append-only JSONL file per chat under `{data_dir}/journals/{chat_id}.jsonl`; each
//! line is `{"seq": n, "event": AgentEvent}` with a monotonically increasing `seq`. The
//! journal is the durable replay source for live streams (`Subscribe` = replay then tail
//! the broadcast hub) and the crash-recovery gauge: a journal whose LAST event is not
//! `Done` belongs to a run that died mid-stream — boot recovery stamps its doc entry
//! `aborted` and closes the journal with a synthetic `Done`.
//!
//! Bounded-window compaction is deferred (whole file kept for now, per M2 scope); a torn
//! trailing line from a crash mid-write is tolerated everywhere.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use serde::{Deserialize, Serialize};

use harness_proto::AgentEvent;

#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct JournalLine {
    seq: u64,
    event: AgentEvent,
}

/// [`JournalLine`]'s wire shape over a borrowed event: appends run once per
/// streamed token and must not deep-clone the event just to serialize it.
#[derive(Serialize)]
struct JournalLineRef<'a> {
    seq: u64,
    event: &'a AgentEvent,
}

struct ChatJournal {
    file: File,
    next_seq: u64,
    /// Append clock value of the last write — eviction drops the stalest.
    last_used: u64,
    /// True when the file ends without a newline (torn write) — the next append
    /// starts with one so the torn line stays isolated.
    needs_newline: bool,
}

/// Append-only JSONL journal store, one file per chat.
pub struct RunJournal {
    dir: PathBuf,
    open_files: Mutex<OpenJournals>,
}

#[derive(Default)]
struct OpenJournals {
    files: HashMap<String, ChatJournal>,
    clock: u64,
}

impl RunJournal {
    pub fn open(dir: impl AsRef<Path>) -> Result<Self, JournalError> {
        let dir = dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&dir)?;
        Ok(Self {
            dir,
            open_files: Mutex::new(OpenJournals::default()),
        })
    }

    fn lock(&self) -> MutexGuard<'_, OpenJournals> {
        self.open_files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn path_for(&self, chat_id: &str) -> PathBuf {
        self.dir.join(format!("{}.jsonl", sanitize_id(chat_id)))
    }

    fn attempts_path(&self, chat_id: &str) -> PathBuf {
        self.dir.join(format!("{}.resume", sanitize_id(chat_id)))
    }

    /// Auto-resume revival budget (harness `resumeAttempt`/`MAX_AUTO_RESUME`):
    /// persisted beside the journal so a run that CRASHES THE ENGINE cannot
    /// revive itself in an infinite boot loop.
    pub fn resume_attempts(&self, chat_id: &str) -> u32 {
        std::fs::read_to_string(self.attempts_path(chat_id))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0)
    }

    pub fn note_resume_attempt(&self, chat_id: &str) -> u32 {
        let next = self.resume_attempts(chat_id) + 1;
        if let Err(err) = std::fs::write(self.attempts_path(chat_id), next.to_string()) {
            tracing::warn!(chat = %chat_id, error = %err, "resume-attempt ledger write failed");
        }
        next
    }

    /// A cleanly completed turn resets the budget — only consecutive
    /// crash-revive-crash cycles exhaust it.
    pub fn clear_resume_attempts(&self, chat_id: &str) {
        let _ = std::fs::remove_file(self.attempts_path(chat_id));
    }

    /// Append one event; returns its journal seq.
    pub fn append(&self, chat_id: &str, event: &AgentEvent) -> Result<u64, JournalError> {
        let mut open = self.lock();
        open.clock += 1;
        let now = open.clock;
        let files = &mut open.files;
        if !files.contains_key(chat_id) {
            // Bound the open-fd set: entries were never removed, so every chat
            // ever run held a descriptor for the process lifetime. Dropping is
            // safe — the next append reopens and rescans the tail. The cap
            // comfortably exceeds concurrent runs; past it only the least
            // recently written journal closes, so live runs keep their files.
            const OPEN_FILE_CAP: usize = 16;
            if files.len() >= OPEN_FILE_CAP
                && let Some(stalest) = files
                    .iter()
                    .min_by_key(|(_, journal)| journal.last_used)
                    .map(|(id, _)| id.clone())
            {
                files.remove(&stalest);
            }
            let path = self.path_for(chat_id);
            let (next_seq, needs_newline) = scan_tail(&path)?;
            let file = OpenOptions::new().create(true).append(true).open(&path)?;
            files.insert(
                chat_id.to_string(),
                ChatJournal {
                    file,
                    next_seq,
                    last_used: now,
                    needs_newline,
                },
            );
        }
        // Entry guaranteed present; avoid unwrap in a library path regardless.
        let Some(journal) = files.get_mut(chat_id) else {
            return Err(JournalError::Io(std::io::Error::other(
                "journal entry vanished under lock",
            )));
        };
        journal.last_used = now;
        let seq = journal.next_seq;
        let line = serde_json::to_string(&JournalLineRef { seq, event })?;
        let mut buf = Vec::with_capacity(line.len() + 2);
        if journal.needs_newline {
            buf.push(b'\n');
        }
        buf.extend_from_slice(line.as_bytes());
        buf.push(b'\n');
        journal.file.write_all(&buf)?;
        journal.file.flush()?;
        journal.needs_newline = false;
        journal.next_seq = seq + 1;
        Ok(seq)
    }

    /// Events with `seq > after_seq`, in order. A cursor ahead of the last issued seq is
    /// from a previous era (file replaced) — falls back to a full replay, mirroring harness.
    pub fn replay(
        &self,
        chat_id: &str,
        after_seq: u64,
    ) -> Result<Vec<(u64, AgentEvent)>, JournalError> {
        let path = self.path_for(chat_id);
        if !path.exists() {
            return Ok(Vec::new());
        }
        let all = read_lines(&path)?;
        let last_seq = all.last().map(|(seq, _)| *seq).unwrap_or(0);
        let from = if after_seq > last_seq { 0 } else { after_seq };
        Ok(all.into_iter().filter(|(seq, _)| *seq > from).collect())
    }

    /// The last event in a chat's journal, if any (ignores a torn tail line).
    pub fn last_event(&self, chat_id: &str) -> Result<Option<(u64, AgentEvent)>, JournalError> {
        let path = self.path_for(chat_id);
        if !path.exists() {
            return Ok(None);
        }
        Ok(last_valid_line(&path)?.0)
    }

    /// Crash-recovery scan: chat ids whose journal's last event is NOT a `Done` — their
    /// runs died mid-stream and need recovery (stamp `aborted`, close the journal).
    pub fn stale_sessions(&self) -> Result<Vec<String>, JournalError> {
        let mut stale = Vec::new();
        for entry in std::fs::read_dir(&self.dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let Some(chat_id) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            // Boot runs this over every journal ever written (never
            // compacted): read each tail, not each history.
            let (last, _) = last_valid_line(&path)?;
            match last {
                Some((_, AgentEvent::Done { .. })) | None => {}
                Some(_) => stale.push(chat_id.to_string()),
            }
        }
        stale.sort();
        Ok(stale)
    }

    /// Remove a chat's journal file entirely (tests / future compaction).
    pub fn discard(&self, chat_id: &str) -> Result<(), JournalError> {
        self.lock().files.remove(chat_id);
        let path = self.path_for(chat_id);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        Ok(())
    }
}

/// Parse every valid line; malformed lines (torn tail writes) are skipped.
fn read_lines(path: &Path) -> Result<Vec<(u64, AgentEvent)>, JournalError> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    let mut out = Vec::new();
    for line in BufReader::new(file).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<JournalLine>(&line) {
            Ok(parsed) => out.push((parsed.seq, parsed.event)),
            Err(err) => {
                tracing::warn!(path = %path.display(), error = %err, "journal: skipping malformed line");
            }
        }
    }
    Ok(out)
}

/// Next seq (last valid seq + 1, starting at 1) and whether the file ends mid-line.
fn scan_tail(path: &Path) -> Result<(u64, bool), JournalError> {
    let (last, needs_newline) = last_valid_line(path)?;
    Ok((last.map_or(1, |(seq, _)| seq + 1), needs_newline))
}

/// The last parseable line (what [`read_lines`] would return last) and
/// whether the file ends mid-line, reading backwards from the end in growing
/// windows — journals are append-only and never compacted, so their tails
/// are what boot recovery and reopen need, not their whole history.
fn last_valid_line(path: &Path) -> Result<(Option<(u64, AgentEvent)>, bool), JournalError> {
    const FIRST_WINDOW: u64 = 64 * 1024;
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((None, false)),
        Err(e) => return Err(e.into()),
    };
    let len = file.metadata()?.len();
    if len == 0 {
        return Ok((None, false));
    }
    let mut window = FIRST_WINDOW.min(len);
    let mut needs_newline = None;
    loop {
        let start = len - window;
        file.seek(SeekFrom::Start(start))?;
        let mut bytes = Vec::with_capacity(window as usize);
        (&mut file).take(window).read_to_end(&mut bytes)?;
        let needs_newline = *needs_newline.get_or_insert(bytes.last() != Some(&b'\n'));
        // Unless the window reaches the file start, its first segment may be
        // the cut-off end of an earlier line: never parse it.
        let segments: Vec<&[u8]> = bytes.split(|b| *b == b'\n').collect();
        let skip = usize::from(start > 0);
        for segment in segments.iter().skip(skip).rev() {
            let Ok(line) = std::str::from_utf8(segment) else {
                continue;
            };
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(parsed) = serde_json::from_str::<JournalLine>(line) {
                return Ok((Some((parsed.seq, parsed.event)), needs_newline));
            }
        }
        if start == 0 {
            return Ok((None, needs_newline));
        }
        window = (window * 4).min(len);
    }
}

/// Journal (`.jsonl`) and resume-budget (`.resume`) paths for `chat_id` under an
/// arbitrary journals directory — profile import copies these files between
/// profiles without opening a `RunJournal`.
pub fn journal_paths(dir: &Path, chat_id: &str) -> (PathBuf, PathBuf) {
    let stem = sanitize_id(chat_id);
    (
        dir.join(format!("{stem}.jsonl")),
        dir.join(format!("{stem}.resume")),
    )
}

/// Chat ids become file names; anything outside a conservative set is replaced so a
/// hostile id cannot traverse paths. (Ids are uuids in practice.)
fn sanitize_id(chat_id: &str) -> String {
    chat_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_proto::DoneStatus;

    fn text(s: &str) -> AgentEvent {
        AgentEvent::TextDelta { text: s.into() }
    }

    fn done() -> AgentEvent {
        AgentEvent::Done {
            status: DoneStatus::Completed,
            result: None,
            error: None,
            session_id: None,
        }
    }

    #[test]
    fn appends_are_monotonic_and_replayable() {
        let dir = tempfile::tempdir().unwrap();
        let journal = RunJournal::open(dir.path()).unwrap();
        assert_eq!(journal.append("chat-1", &text("a")).unwrap(), 1);
        assert_eq!(journal.append("chat-1", &text("b")).unwrap(), 2);
        assert_eq!(journal.append("chat-1", &done()).unwrap(), 3);

        let all = journal.replay("chat-1", 0).unwrap();
        assert_eq!(all.len(), 3);
        let after = journal.replay("chat-1", 2).unwrap();
        assert_eq!(after.len(), 1);
        assert!(matches!(after[0].1, AgentEvent::Done { .. }));
        // Era fallback: cursor ahead of last seq replays everything.
        assert_eq!(journal.replay("chat-1", 99).unwrap().len(), 3);
    }

    #[test]
    fn seq_continues_across_reopen() {
        let dir = tempfile::tempdir().unwrap();
        {
            let journal = RunJournal::open(dir.path()).unwrap();
            journal.append("chat-1", &text("a")).unwrap();
        }
        let journal = RunJournal::open(dir.path()).unwrap();
        assert_eq!(journal.append("chat-1", &text("b")).unwrap(), 2);
    }

    #[test]
    fn stale_scan_flags_journals_without_terminal_done() {
        let dir = tempfile::tempdir().unwrap();
        let journal = RunJournal::open(dir.path()).unwrap();
        journal.append("dead", &text("partial")).unwrap();
        journal.append("clean", &text("full")).unwrap();
        journal.append("clean", &done()).unwrap();
        assert_eq!(journal.stale_sessions().unwrap(), vec!["dead".to_string()]);
        // Closing the stale journal with a Done clears the flag.
        journal.append("dead", &done()).unwrap();
        assert!(journal.stale_sessions().unwrap().is_empty());
    }

    #[test]
    fn torn_tail_line_is_tolerated() {
        let dir = tempfile::tempdir().unwrap();
        {
            let journal = RunJournal::open(dir.path()).unwrap();
            journal.append("chat-1", &text("a")).unwrap();
        }
        // Simulate a crash mid-write: garbage with no trailing newline.
        let path = dir.path().join("chat-1.jsonl");
        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{\"seq\":2,\"event\":{\"type\":\"textD")
            .unwrap();
        drop(f);

        let journal = RunJournal::open(dir.path()).unwrap();
        assert_eq!(journal.replay("chat-1", 0).unwrap().len(), 1);
        assert_eq!(journal.append("chat-1", &text("b")).unwrap(), 2);
        let all = journal.replay("chat-1", 0).unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[1].0, 2);
    }

    /// The backward tail scan agrees with a full parse when lines straddle
    /// the read windows, when the tail is torn, and when the only valid line
    /// sits at the very start of a large file.
    #[test]
    fn tail_scan_matches_a_full_parse_across_windows() {
        let dir = tempfile::tempdir().unwrap();
        let journal = RunJournal::open(dir.path()).unwrap();
        let path = dir.path().join("big.jsonl");
        // ~100KB lines put every window edge mid-line.
        for i in 0..7 {
            journal.append("big", &text(&"x".repeat(100_000 + i))).unwrap();
        }
        let full = read_lines(&path).unwrap();
        let (last, torn) = last_valid_line(&path).unwrap();
        assert_eq!(last.as_ref().map(|(seq, _)| *seq), Some(7));
        assert_eq!(last, full.last().cloned());
        assert!(!torn);

        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(&vec![b'y'; 200_000]).unwrap();
        drop(f);
        let (last, torn) = last_valid_line(&path).unwrap();
        assert_eq!(last.map(|(seq, _)| seq), Some(7), "torn garbage is skipped");
        assert!(torn);
        assert_eq!(scan_tail(&path).unwrap(), (8, true));

        let lone = dir.path().join("lone.jsonl");
        let mut bytes = serde_json::to_vec(&JournalLine { seq: 4, event: done() }).unwrap();
        bytes.push(b'\n');
        bytes.extend(vec![b'z'; 300_000]);
        std::fs::write(&lone, bytes).unwrap();
        assert!(matches!(last_valid_line(&lone).unwrap().0, Some((4, AgentEvent::Done { .. }))));
        assert_eq!(last_valid_line(&dir.path().join("none.jsonl")).unwrap(), (None, false));
    }

    /// Past the open-file cap only the least recently written journal
    /// closes; a live run keeps its handle and its seq continues.
    #[test]
    fn eviction_closes_only_the_stalest_journal() {
        let dir = tempfile::tempdir().unwrap();
        let journal = RunJournal::open(dir.path()).unwrap();
        journal.append("live", &text("a")).unwrap();
        for i in 0..15 {
            journal.append(&format!("idle-{i}"), &text("a")).unwrap();
        }
        journal.append("live", &text("b")).unwrap();
        journal.append("newcomer", &text("a")).unwrap();
        let open = journal.lock();
        assert_eq!(open.files.len(), 16);
        assert!(open.files.contains_key("live"));
        assert!(!open.files.contains_key("idle-0"), "the stalest closes");
        drop(open);
        assert_eq!(journal.append("live", &text("c")).unwrap(), 3);
        assert_eq!(journal.append("idle-0", &text("b")).unwrap(), 2, "reopen rescans");
    }
}
