//! Tails a trace graff is still writing. graff appends whole lines and
//! flushes each one, but a poll can still land mid-line, so the unfinished
//! tail is held back until its newline arrives.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub struct Follower {
    path: PathBuf,
    file: File,
    pos: u64,
    pending: Vec<u8>,
}

impl Follower {
    /// `from_start` replays the run so far; otherwise only new lines are returned.
    pub fn open(path: &Path, from_start: bool) -> io::Result<Self> {
        let file = File::open(path)?;
        let pos = if from_start {
            0
        } else {
            file.metadata()?.len()
        };
        Ok(Follower {
            path: path.to_path_buf(),
            file,
            pos,
            pending: Vec::new(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Complete lines appended since the last poll.
    pub fn poll(&mut self) -> io::Result<Vec<String>> {
        let len = self.file.metadata()?.len();
        if len < self.pos {
            // Truncated or replaced in place: start over.
            self.pos = 0;
            self.pending.clear();
        }
        if len > self.pos {
            self.file.seek(SeekFrom::Start(self.pos))?;
            let read = (&mut self.file)
                .take(len - self.pos)
                .read_to_end(&mut self.pending)?;
            self.pos += read as u64;
        }
        let mut lines = Vec::new();
        let mut start = 0;
        for (i, byte) in self.pending.iter().enumerate() {
            if *byte == b'\n' {
                let line = String::from_utf8_lossy(&self.pending[start..i]);
                let line = line.trim_end_matches('\r');
                if !line.trim().is_empty() {
                    lines.push(line.to_string());
                }
                start = i + 1;
            }
        }
        self.pending.drain(..start);
        Ok(lines)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    use std::io::Write;

    #[test]
    fn holds_back_a_partial_line_and_survives_truncation() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("run.jsonl");
        std::fs::write(&path, "{\"ev\":\"a\"}\n").unwrap();
        let mut skip = Follower::open(&path, false).unwrap();
        let mut replay = Follower::open(&path, true).unwrap();
        assert_eq!(replay.poll().unwrap(), ["{\"ev\":\"a\"}"]);
        assert!(skip.poll().unwrap().is_empty());

        let mut out = OpenOptions::new().append(true).open(&path).unwrap();
        out.write_all(b"{\"ev\":\"b\"").unwrap();
        assert!(replay.poll().unwrap().is_empty());
        out.write_all(b"}\r\n\n{\"ev\":\"c\"}\n").unwrap();
        assert_eq!(replay.poll().unwrap(), ["{\"ev\":\"b\"}", "{\"ev\":\"c\"}"]);
        assert_eq!(skip.poll().unwrap(), ["{\"ev\":\"b\"}", "{\"ev\":\"c\"}"]);

        std::fs::write(&path, "{\"ev\":\"d\"}\n").unwrap();
        assert_eq!(replay.poll().unwrap(), ["{\"ev\":\"d\"}"]);
    }
}
