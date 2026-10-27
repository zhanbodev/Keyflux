// Bounded JSONL reader, adapted from NuPhy Lab's MIT codex-event-tail.mjs.
// Copyright (c) 2026 NuPhy Lab contributors. See licenses/NuPhyLab-MIT.txt.
use std::{
    fs::{File, Metadata},
    io::{Read, Seek, SeekFrom},
    path::Path,
    time::SystemTime,
};
const WINDOW: u64 = 4 * 1024 * 1024;
const MAX_HISTORY: u64 = 32 * 1024 * 1024;
const MAX_LINE: usize = 1024 * 1024;

#[derive(Default)]
pub(super) struct Tail {
    identity: Option<(u64, u64)>,
    size: u64,
    modified: Option<SystemTime>,
    pub offset: u64,
    start: u64,
    fragment: Vec<u8>,
    discarding: bool,
    pub cold: bool,
}
pub(super) struct ReadResult {
    pub reset: bool,
    pub caught_up: bool,
    pub was_cold: bool,
}
fn identity(meta: &Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino())
    }
    #[cfg(not(unix))]
    {
        let created = meta
            .created()
            .ok()
            .and_then(|v| v.duration_since(SystemTime::UNIX_EPOCH).ok());
        (
            created.map(|v| v.as_secs()).unwrap_or(0),
            created.map(|v| v.subsec_nanos() as u64).unwrap_or(0),
        )
    }
}
impl Tail {
    pub fn read(
        &mut self,
        path: &Path,
        mut on_line: impl FnMut(&[u8]),
    ) -> Result<ReadResult, &'static str> {
        let mut file = File::open(path).map_err(|_| "CodexEventsUnavailable")?;
        let meta = file.metadata().map_err(|_| "CodexEventsUnavailable")?;
        if !meta.is_file() {
            return Err("InvalidCodexEventFile");
        }
        let id = identity(&meta);
        let reset = self.identity != Some(id)
            || meta.len() < self.size
            || (meta.len() == self.size && meta.modified().ok() != self.modified);
        if reset {
            on_line(&[]);
            self.identity = Some(id);
            self.start = meta.len().saturating_sub(WINDOW);
            self.offset = self.start;
            self.fragment.clear();
            self.discarding = self.start > 0;
            self.cold = true;
        }
        let was_cold = self.cold;
        let end = meta.len().min(self.offset.saturating_add(WINDOW));
        file.seek(SeekFrom::Start(self.offset))
            .map_err(|_| "CodexEventsUnavailable")?;
        let mut bytes = [0u8; 64 * 1024];
        while self.offset < end {
            let limit = bytes.len().min((end - self.offset) as usize);
            let n = file
                .read(&mut bytes[..limit])
                .map_err(|_| "CodexEventsUnavailable")?;
            if n == 0 {
                return Err("CodexEventsChanged");
            }
            self.offset += n as u64;
            for part in bytes[..n].split_inclusive(|v| *v == b'\n') {
                let newline = part.last() == Some(&b'\n');
                let body = if newline {
                    &part[..part.len() - 1]
                } else {
                    part
                };
                if !self.discarding {
                    if self.fragment.len() + body.len() > MAX_LINE {
                        self.fragment.clear();
                        self.discarding = true;
                    } else {
                        self.fragment.extend_from_slice(body);
                    }
                }
                if newline {
                    if !self.discarding && !self.fragment.is_empty() {
                        on_line(&self.fragment);
                    }
                    self.fragment.clear();
                    self.discarding = false;
                }
            }
        }
        self.size = meta.len();
        self.modified = meta.modified().ok();
        let caught_up = self.offset == meta.len();
        if caught_up {
            self.cold = false;
        }
        Ok(ReadResult {
            reset,
            caught_up,
            was_cold,
        })
    }
    // Search farther back only when the current window contained no correlated
    // lifecycle record. Each pass remains bounded and never retains message text.
    pub fn search_back(&mut self) -> bool {
        let next = self.start.saturating_sub(WINDOW);
        if next == self.start || self.size.saturating_sub(next) > MAX_HISTORY {
            return false;
        }
        self.start = next;
        self.offset = next;
        self.fragment.clear();
        self.discarding = next > 0;
        self.cold = true;
        true
    }
    pub fn retained_bytes(&self) -> usize {
        self.fragment.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn partial_oversized_truncated_and_replaced_records() {
        let dir = std::env::temp_dir().join(format!(
            "keyflux-tail-{}-{}",
            std::process::id(),
            crate::codex::now_ns()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("events.jsonl");
        std::fs::write(&path, b"one\ntw").unwrap();
        let mut tail = Tail::default();
        let mut lines = Vec::new();
        tail.read(&path, |v| {
            if !v.is_empty() {
                lines.push(v.to_vec())
            }
        })
        .unwrap();
        assert_eq!(lines, vec![b"one".to_vec()]);
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        f.write_all(b"o\n").unwrap();
        f.write_all(&vec![b'x'; MAX_LINE + 1]).unwrap();
        f.write_all(b"\nthree\n").unwrap();
        drop(f);
        tail.read(&path, |v| {
            if !v.is_empty() {
                lines.push(v.to_vec())
            }
        })
        .unwrap();
        assert_eq!(
            lines,
            vec![b"one".to_vec(), b"two".to_vec(), b"three".to_vec()]
        );
        assert_eq!(tail.retained_bytes(), 0);
        std::fs::write(&path, b"four\n").unwrap();
        assert!(
            tail.read(&path, |v| if !v.is_empty() {
                lines.push(v.to_vec())
            })
            .unwrap()
            .reset
        );
        let replacement = dir.join("replacement");
        std::fs::write(&replacement, b"five\n").unwrap();
        std::fs::rename(replacement, &path).unwrap();
        assert!(
            tail.read(&path, |v| if !v.is_empty() {
                lines.push(v.to_vec())
            })
            .unwrap()
            .reset
        );
        assert_eq!(lines.last().unwrap(), b"five");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
