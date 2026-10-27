//! Read-only Codex Desktop source. State aggregation and all HID encoding stay in Zig.
//! Index/tail/writer design adapted from NuPhy Lab (MIT), pinned in THIRD_PARTY_NOTICES.md.
mod tail;
use crate::core::Core;
use chrono::DateTime;
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
const MAX_SESSIONS: usize = 48; // Below the Zig engine's 64-session capacity.
const MAX_FRAGMENTS: usize = 4 * 1024 * 1024;
const PROVIDER: &str = "codex.desktop.local";
pub(crate) fn now_ns() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let wall = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .min(u64::MAX as u128) as u64;
    let previous = LAST
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
            Some(wall.max(value.saturating_add(1)))
        })
        .unwrap();
    wall.max(previous.saturating_add(1))
}
fn valid_id(v: &str) -> bool {
    !v.is_empty()
        && v.len() <= 160
        && v.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}

// Only structural fields are deserialized. Prompt, reasoning, message, tool
// arguments/results and encrypted content are skipped, never copied into events.
#[derive(Default, Deserialize)]
struct Record {
    #[serde(default)]
    timestamp: String,
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    payload: Payload,
}
#[derive(Default, Deserialize)]
struct Payload {
    #[serde(rename = "type", default)]
    kind: String,
    turn_id: Option<String>,
    call_id: Option<String>,
    request_id: Option<String>,
    name: Option<String>,
    #[serde(default)]
    item: Item,
}
#[derive(Default, Deserialize)]
struct Item {
    #[serde(rename = "type", default)]
    kind: String,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Terminal {
    Complete,
    Cancelled,
    Error,
}
#[derive(Default)]
struct Observation {
    turn: Option<String>,
    last_ms: u64,
    progress: u64,
    terminal: Option<Terminal>,
    overflow: bool,
    requests: BTreeMap<String, bool>,
}
impl Observation {
    fn consume(&mut self, line: &[u8], serial: &mut u64) {
        if line.is_empty() {
            *self = Self::default();
            return;
        }
        let Ok(record) = serde_json::from_slice::<Record>(line) else {
            return;
        };
        let Ok(at) = DateTime::parse_from_rfc3339(&record.timestamp) else {
            return;
        };
        let Ok(ms) = u64::try_from(at.timestamp_millis()) else {
            return;
        };
        if ms < self.last_ms || ms > now_ns() / 1_000_000 + 5_000 {
            return;
        }
        let p = record.payload;
        let event = match (record.kind.as_str(), p.kind.as_str()) {
            ("turn_context", _) | ("event_msg", "task_started" | "turn_started") => "start",
            ("event_msg", "task_complete" | "turn_complete" | "turn_completed") => "complete",
            ("event_msg", "turn_aborted" | "turn_interrupted") => "cancel",
            ("event_msg", "task_failed" | "turn_failed" | "error") => "error",
            ("response_item", "function_call" | "custom_tool_call" | "mcp_tool_call") => "tool",
            (
                "response_item",
                "function_call_output" | "custom_tool_call_output" | "mcp_tool_call_output",
            ) => "tool_end",
            (
                "event_msg",
                "approval_request"
                | "permission_request"
                | "request_approval"
                | "waiting_on_user_input",
            ) => "attention",
            (
                "event_msg",
                "approval_response"
                | "permission_response"
                | "approval_result"
                | "permission_result",
            ) => "resolved",
            ("response_item", "reasoning" | "message")
            | ("event_msg", "agent_reasoning" | "agent_message") => "activity",
            ("event_msg", "item_completed")
                if matches!(
                    p.item.kind.as_str(),
                    "Reasoning"
                        | "AgentMessage"
                        | "CommandExecution"
                        | "McpToolCall"
                        | "FileChange"
                ) =>
            {
                "activity"
            }
            _ => return,
        };
        if let Some(turn) = p.turn_id.as_deref().filter(|v| valid_id(v)) {
            if self.turn.as_deref() != Some(turn) {
                if event != "start" && self.turn.is_some() {
                    return;
                }
                *self = Self {
                    turn: Some(turn.to_owned()),
                    ..Self::default()
                };
            }
        }
        if self.turn.is_none() {
            return;
        }
        // A delayed item cannot revive a terminal turn, even when its timestamp
        // is newer. Only a distinct, explicit turn ID starts another turn.
        if self.terminal.is_some() {
            return;
        }
        let request = p.call_id.or(p.request_id).filter(|v| valid_id(v));
        match event {
            "complete" => self.terminal = Some(Terminal::Complete),
            "cancel" => self.terminal = Some(Terminal::Cancelled),
            "error" => self.terminal = Some(Terminal::Error),
            "tool" => {
                if let Some(id) = request {
                    let attention = p
                        .name
                        .as_deref()
                        .is_some_and(|n| n.rsplit(['.', '/']).next() == Some("request_user_input"));
                    if self.requests.len() < 8 || self.requests.contains_key(&id) {
                        self.requests.insert(id, attention);
                    } else {
                        self.overflow = true;
                        return;
                    }
                }
            }
            "tool_end" => {
                if let Some(id) = request {
                    self.requests.remove(&id);
                }
            }
            "attention" => {
                if let Some(id) = request {
                    if self.requests.len() < 8 || self.requests.contains_key(&id) {
                        self.requests.insert(id, true);
                    } else {
                        self.overflow = true;
                        return;
                    }
                } else {
                    return;
                }
            }
            "resolved" => {
                if let Some(id) = request {
                    if let Some(waiting) = self.requests.get_mut(&id) {
                        *waiting = false;
                    }
                }
            }
            _ => {}
        }
        self.last_ms = ms;
        *serial += 1;
        self.progress = *serial;
    }
}
#[derive(Default)]
struct Publication {
    turn: String,
    requests: BTreeMap<String, bool>,
    progress: u64,
    lost: bool,
    terminal: bool,
}
#[derive(Default)]
struct Session {
    path: PathBuf,
    tail: tail::Tail,
    observation: Observation,
    published: Option<Publication>,
    observed_at: u64,
    new_record: bool,
}
#[derive(Clone)]
struct Row {
    id: String,
    path: PathBuf,
}
struct Reader {
    root: PathBuf,
    started_ms: u64,
    sessions: HashMap<String, Session>,
    serial: u64,
    forwarded: u64,
    latest_kind: Option<String>,
}
impl Reader {
    fn new(root: PathBuf) -> Self {
        Self {
            root,
            started_ms: now_ns() / 1_000_000,
            sessions: HashMap::new(),
            serial: 0,
            forwarded: 0,
            latest_kind: None,
        }
    }
    fn rows(&self) -> Result<Vec<Row>, &'static str> {
        let root = self.root.canonicalize().map_err(|_| "CodexDataNotFound")?;
        let database = fs::read_dir(&root)
            .map_err(|_| "CodexDataNotFound")?
            .filter_map(Result::ok)
            .filter_map(|e| {
                e.file_name()
                    .to_str()
                    .and_then(|v| {
                        v.strip_prefix("state_")?
                            .strip_suffix(".sqlite")?
                            .parse::<u32>()
                            .ok()
                    })
                    .map(|version| (version, e.path()))
            })
            .max_by_key(|e| e.0)
            .ok_or("CodexDataNotFound")?
            .1;
        let database = database
            .canonicalize()
            .map_err(|_| "CodexIndexUnavailable")?;
        if !database.starts_with(&root) {
            return Err("InvalidCodexIndexPath");
        }
        let db = Connection::open_with_flags(
            database,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|_| "CodexIndexUnavailable")?;
        db.busy_timeout(Duration::from_millis(100))
            .map_err(|_| "CodexIndexUnavailable")?;
        db.pragma_update(None, "query_only", true)
            .map_err(|_| "CodexIndexUnavailable")?;
        let columns: HashSet<String> = db
            .prepare("PRAGMA table_info(threads)")
            .and_then(|mut s| s.query_map([], |r| r.get(1))?.collect())
            .map_err(|_| "UnsupportedCodexSchema")?;
        if ![
            "id",
            "rollout_path",
            "originator",
            "source",
            "thread_source",
            "archived",
            "updated_at",
        ]
        .iter()
        .all(|v| columns.contains(*v))
        {
            return Err("UnsupportedCodexSchema");
        }
        let active: Vec<&str> = self
            .sessions
            .iter()
            .filter(|(_, s)| s.published.as_ref().is_some_and(|p| !p.terminal))
            .map(|(id, _)| id.as_str())
            .collect();
        let priority = if active.is_empty() {
            "archived".to_owned()
        } else {
            format!(
                "CASE WHEN id IN ({}) THEN 0 ELSE 1 END",
                vec!["?"; active.len()].join(",")
            )
        };
        let sql=format!("SELECT id,rollout_path FROM threads WHERE archived=0 AND originator='Codex Desktop' AND source IN ('vscode','desktop') AND thread_source IN ('user','agent_created_thread') ORDER BY {priority},updated_at DESC LIMIT {MAX_SESSIONS}");
        // Do not select titles, previews, first_user_message, cwd or account IDs.
        let pairs: Vec<(String, String)> = db
            .prepare(&sql)
            .and_then(|mut s| {
                s.query_map(rusqlite::params_from_iter(active), |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?
                .collect()
            })
            .map_err(|_| "CodexIndexUnavailable")?;
        let mut rows = Vec::new();
        for (id, path) in pairs {
            if !valid_id(&id) {
                continue;
            }
            let path = root.join(path);
            // Missing files remain visible to reconciliation as a source loss.
            let parent = path.parent().and_then(|p| p.canonicalize().ok());
            if !parent.as_ref().is_some_and(|p| p.starts_with(&root))
                || path.extension().is_none_or(|v| v != "jsonl")
            {
                continue;
            }
            if let Ok(real) = path.canonicalize() {
                if !real.starts_with(&root) {
                    continue;
                }
            }
            rows.push(Row { id, path });
        }
        Ok(rows)
    }
    fn emit(
        &mut self,
        emit: &mut impl FnMut(&Value) -> Result<(), String>,
        id: &str,
        turn: &str,
        kind: &str,
        request: Option<&str>,
    ) -> Result<(), String> {
        let stamp = now_ns();
        let mut event = json!({"schema_version":1,"provider":PROVIDER,"session_id":id,"turn_id":turn,"event_id":format!("local-{}-{stamp}",std::process::id()),"timestamp_ns":stamp,"kind":kind});
        if let Some(request) = request {
            event["request_id"] = json!(request);
        }
        emit(&event)?;
        self.forwarded += 1;
        self.latest_kind = Some(kind.to_owned());
        Ok(())
    }
    fn lose(
        &mut self,
        id: &str,
        session: &mut Session,
        emit: &mut impl FnMut(&Value) -> Result<(), String>,
    ) -> Result<(), String> {
        if let Some(p) = session
            .published
            .as_mut()
            .filter(|p| !p.terminal && !p.lost)
        {
            self.emit(emit, id, &p.turn, "source_lost", None)?;
            p.lost = true;
        }
        Ok(())
    }
    fn reconcile(
        &mut self,
        id: &str,
        s: &mut Session,
        now: u64,
        writer: Option<u64>,
        writers_known: bool,
        emit: &mut impl FnMut(&Value) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(turn) = s.observation.turn.clone() else {
            return self.lose(id, s, emit);
        };
        if s.published.as_ref().is_some_and(|p| p.turn != turn) {
            if let Some(p) = s.published.as_ref().filter(|p| !p.terminal) {
                self.emit(emit, id, &p.turn, "turn_cancelled", None)?;
            }
            s.published = None;
        }
        let o = &s.observation;
        if let Some(terminal) = o.terminal {
            let already = s.published.as_ref().is_some_and(|p| p.terminal);
            let recent = (s.new_record || o.last_ms > self.started_ms)
                && now.saturating_sub(o.last_ms) <= 15_000;
            if already || (s.published.is_none() && !recent) {
                return Ok(());
            }
            if s.published.is_none() {
                self.emit(emit, id, &turn, "turn_started", None)?;
            }
            let kind = match terminal {
                Terminal::Complete if recent => "turn_completed",
                Terminal::Error if recent => "turn_failed",
                _ => "turn_cancelled",
            };
            self.emit(emit, id, &turn, kind, None)?;
            s.published = Some(Publication {
                turn,
                terminal: true,
                ..Publication::default()
            });
            return Ok(());
        }
        let owned = writer.is_some_and(|start| o.last_ms >= start && o.last_ms <= now + 5_000);
        let fresh = !writers_known
            && s.observed_at > 0
            && now.saturating_sub(s.observed_at) <= 15_000
            && now.saturating_sub(o.last_ms) <= 15_000;
        if !owned && !fresh {
            return self.lose(id, s, emit);
        }
        if s.published.is_none() {
            self.emit(emit, id, &turn, "turn_started", None)?;
            s.published = Some(Publication {
                turn: turn.clone(),
                ..Publication::default()
            });
        }
        let p = s.published.as_mut().unwrap();
        // Reconnection/writer ownership alone cannot revive a lost phase.
        if p.lost && (!s.new_record || p.progress == o.progress) {
            return Ok(());
        }
        if p.lost || p.progress != o.progress {
            for request in p
                .requests
                .keys()
                .filter(|request| !o.requests.contains_key(*request))
                .cloned()
                .collect::<Vec<_>>()
            {
                self.emit(emit, id, &turn, "tool_finished", Some(&request))?;
                p.requests.remove(&request);
            }
            // This means confirmed structural activity, never inferred reasoning.
            self.emit(emit, id, &turn, "working", None)?;
            for (request, waiting) in &o.requests {
                if !p.requests.contains_key(request) {
                    self.emit(emit, id, &turn, "tool_started", Some(request))?;
                    p.requests.insert(request.clone(), false);
                }
                if p.requests.get(request) != Some(waiting) {
                    self.emit(
                        emit,
                        id,
                        &turn,
                        if *waiting {
                            "attention"
                        } else {
                            "attention_resolved"
                        },
                        Some(request),
                    )?;
                    p.requests.insert(request.clone(), *waiting);
                }
            }
            p.progress = o.progress;
            p.lost = false;
        }
        Ok(())
    }
    fn read_session(
        &mut self,
        id: &str,
        path: PathBuf,
        s: &mut Session,
        now: u64,
        emit: &mut impl FnMut(&Value) -> Result<(), String>,
    ) -> Result<bool, String> {
        if s.path != path {
            self.lose(id, s, emit)?;
            s.tail = tail::Tail::default();
            s.path = path;
        }
        let old = s.observation.progress;
        let read = match s.tail.read(&s.path, |line| {
            s.observation.consume(line, &mut self.serial)
        }) {
            Ok(read) => read,
            Err(_) => {
                self.lose(id, s, emit)?;
                return Ok(false);
            }
        };
        if read.reset && s.published.as_ref().is_some_and(|p| !p.terminal) {
            self.lose(id, s, emit)?;
        }
        s.new_record = !read.was_cold && s.observation.progress != old;
        if s.new_record {
            s.observed_at = now;
        }
        if read.caught_up && s.observation.turn.is_none() {
            s.tail.search_back();
        }
        if s.observation.overflow {
            return Err("CodexRequestCapacity".into());
        }
        if !read.caught_up {
            self.lose(id, s, emit)?;
        }
        Ok(read.caught_up)
    }
    fn refresh(
        &mut self,
        now: u64,
        writers: impl FnOnce(&Path, &[Row]) -> Option<HashMap<String, u64>>,
        mut emit: impl FnMut(&Value) -> Result<(), String>,
    ) -> Result<(), String> {
        let rows = match self.rows() {
            Ok(rows) => rows,
            Err(code) => {
                for id in self.sessions.keys().cloned().collect::<Vec<_>>() {
                    let mut s = self.sessions.remove(&id).unwrap();
                    let result = self.lose(&id, &mut s, &mut emit);
                    self.sessions.insert(id, s);
                    result?;
                }
                return Err(code.into());
            }
        };
        let live = writers(&self.root, &rows);
        let mut present = HashSet::new();
        let mut ordered = Vec::new();
        for row in rows {
            present.insert(row.id.clone());
            if !self.sessions.contains_key(&row.id) && self.sessions.len() >= MAX_SESSIONS {
                let old = self
                    .sessions
                    .iter()
                    .filter(|(_, s)| s.published.as_ref().is_none_or(|p| p.terminal))
                    .min_by_key(|(_, s)| s.observation.last_ms)
                    .map(|(id, _)| id.clone());
                if let Some(old) = old {
                    self.sessions.remove(&old);
                } else {
                    continue;
                }
            }
            let mut s = self.sessions.remove(&row.id).unwrap_or_default();
            let result = self.read_session(&row.id, row.path, &mut s, now, &mut emit);
            if result.as_ref().is_ok_and(|caught_up| *caught_up) {
                ordered.push((s.observation.last_ms, row.id.clone()));
            }
            self.sessions.insert(row.id, s);
            result?;
            if self
                .sessions
                .values()
                .map(|s| s.tail.retained_bytes())
                .sum::<usize>()
                > MAX_FRAGMENTS
            {
                return Err("CodexFragmentCapacity".into());
            }
        }
        // Phase order follows actual record timestamps, not database row order.
        ordered.sort();
        for (_, id) in ordered {
            let mut s = self.sessions.remove(&id).unwrap();
            let result = self.reconcile(
                &id,
                &mut s,
                now,
                live.as_ref().and_then(|m| m.get(&id).copied()),
                live.is_some(),
                &mut emit,
            );
            self.sessions.insert(id, s);
            result?;
        }
        for id in self
            .sessions
            .keys()
            .filter(|id| !present.contains(*id))
            .cloned()
            .collect::<Vec<_>>()
        {
            let turn = self.sessions[&id]
                .published
                .as_ref()
                .filter(|p| !p.terminal)
                .map(|p| p.turn.clone());
            if let Some(turn) = turn {
                self.emit(&mut emit, &id, &turn, "turn_cancelled", None)?;
            }
            self.sessions.remove(&id); // Removed/archived rows never create completion.
        }
        Ok(())
    }
}

pub struct Source {
    reader: Mutex<Reader>,
    status: Mutex<Value>,
    runtime: Mutex<Option<u64>>,
}
impl Default for Source {
    fn default() -> Self {
        let root = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                    .map(PathBuf::from)
                    .unwrap_or_default()
                    .join(".codex")
            });
        Self {
            reader: Mutex::new(Reader::new(root)),
            status: Mutex::new(json!({"available":false,"code":"CodexSourceStarting"})),
            runtime: Mutex::new(None),
        }
    }
}
impl Source {
    pub fn snapshot(&self) -> Value {
        self.status
            .lock()
            .map(|v| v.clone())
            .unwrap_or_else(|_| json!({"available":false,"code":"CodexSourceUnavailable"}))
    }
    pub fn poll(&self, core: &Core) {
        let Ok(mut reader) = self.reader.lock() else {
            return;
        };
        let status = core.call("status", None).or_else(|_| {
            core.ensure()?;
            core.call("status", None)
        });
        let result = status.and_then(|status| {
            if status["result"]["backend"] != "read-only" {
                return Err("SimulationNotAllowed".into());
            }
            let runtime = status["result"]["runtime_id"]
                .as_u64()
                .ok_or("UnsupportedCoreVersion")?;
            if let Ok(mut previous) = self.runtime.lock() {
                if *previous != Some(runtime) {
                    reader.started_ms = now_ns() / 1_000_000;
                    for s in reader.sessions.values_mut() {
                        s.published = None;
                    }
                    *previous = Some(runtime);
                }
            }
            reader.refresh(now_ns() / 1_000_000, live_writers, |event| {
                core.emit_local_event(event)
            })
        });
        if result.is_err() {
            // Fail closed even if a partial batch was forwarded before failure.
            for id in reader.sessions.keys().cloned().collect::<Vec<_>>() {
                let mut s = reader.sessions.remove(&id).unwrap();
                let _ = reader.lose(&id, &mut s, &mut |event| core.emit_local_event(event));
                reader.sessions.insert(id, s);
            }
        }
        let snapshot = json!({"available":result.is_ok(),"code":result.err(),"provider":PROVIDER,
            "tracked_sessions":reader.sessions.len(),"active_sessions":reader.sessions.values().filter(|s|s.published.as_ref().is_some_and(|p|!p.terminal && !p.lost)).count(),
            "events_forwarded":reader.forwarded,"last_event_kind":reader.latest_kind,
            "capabilities":["working","tool","attention","complete","error","cancel"],"streaming_phases":false});
        if let Ok(mut value) = self.status.lock() {
            *value = snapshot;
        }
    }
}

// Read writer ownership without acquiring or changing Codex lock files. This is
// only liveness evidence for an already observed turn, never a Thinking signal.
fn live_writers(root: &Path, rows: &[Row]) -> Option<HashMap<String, u64>> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let root = root.canonicalize().ok()?;
    let paths: HashMap<PathBuf, String> = rows
        .iter()
        .filter_map(|row| {
            let path = root
                .join("thread-writer-locks")
                .join(format!("{}.lock", row.id));
            let path = path.canonicalize().ok()?;
            path.starts_with(&root).then(|| (path, row.id.clone()))
        })
        .collect();
    if paths.is_empty() {
        return Some(HashMap::new());
    }
    let mut command = Command::new("/usr/sbin/lsof");
    command.args(["-nP", "-Fpcn"]);
    command.args(paths.keys());
    let text = bounded_command(command, Duration::from_millis(1500), 262144)?;
    let mut handles = Vec::new();
    let mut pid = None;
    let mut codex = false;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix('p') {
            pid = value.parse::<u32>().ok();
            codex = false;
        } else if let Some(value) = line.strip_prefix('c') {
            codex = value == "codex";
        } else if let Some(value) = line.strip_prefix('n') {
            if codex {
                if let (Some(pid), Some(id)) = (pid, paths.get(Path::new(value))) {
                    handles.push((id.clone(), pid));
                }
            }
        }
    }
    if handles.is_empty() {
        return Some(HashMap::new());
    }
    let pids = handles
        .iter()
        .map(|(_, pid)| pid.to_string())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
        .join(",");
    let mut command = Command::new("/bin/ps");
    command.args(["-p", &pids, "-o", "pid=,etime="]);
    let text = bounded_command(command, Duration::from_millis(500), 65536)?;
    let now = now_ns() / 1_000_000;
    let started: HashMap<u32, u64> = text
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse().ok()?;
            let elapsed = elapsed_seconds(fields.next()?)?;
            Some((pid, now.saturating_sub((elapsed + 2) * 1000)))
        })
        .collect();
    Some(
        handles
            .into_iter()
            .filter_map(|(id, pid)| started.get(&pid).map(|start| (id, *start)))
            .collect(),
    )
}
fn elapsed_seconds(text: &str) -> Option<u64> {
    let (days, time) = text
        .split_once('-')
        .map_or(Some((0, text)), |(days, time)| {
            Some((days.parse::<u64>().ok()?, time))
        })?;
    let values = time
        .split(':')
        .map(str::parse::<u64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let seconds = match values.as_slice() {
        [minutes, seconds] => minutes.checked_mul(60)?.checked_add(*seconds)?,
        [hours, minutes, seconds] => hours
            .checked_mul(3600)?
            .checked_add(minutes.checked_mul(60)?)?
            .checked_add(*seconds)?,
        _ => return None,
    };
    days.checked_mul(86400)?.checked_add(seconds)
}
fn bounded_command(mut command: Command, timeout: Duration, limit: u64) -> Option<String> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let output = child.stdout.take()?;
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = output.take(limit + 1).read_to_end(&mut bytes);
        bytes
    });
    let deadline = Instant::now() + timeout;
    let success = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success() || status.code() == Some(1),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let bytes = reader.join().ok()?;
    if !success || bytes.len() as u64 > limit {
        return None;
    }
    String::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    fn test_root() -> PathBuf {
        if cfg!(target_os = "macos") {
            PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        }
    }
    struct Fixture {
        root: PathBuf,
        file: PathBuf,
        reader: Reader,
        now: u64,
    }
    impl Fixture {
        fn new() -> Self {
            let root =
                test_root().join(format!("keyflux-codex-{}-{}", std::process::id(), now_ns()));
            fs::create_dir_all(root.join("sessions")).unwrap();
            let file = root.join("sessions/task.jsonl");
            fs::write(&file, b"").unwrap();
            let db = Connection::open(root.join("state_5.sqlite")).unwrap();
            db.execute_batch("CREATE TABLE threads(id TEXT,rollout_path TEXT,originator TEXT,source TEXT,thread_source TEXT,archived INTEGER,updated_at INTEGER);").unwrap();
            db.execute("INSERT INTO threads VALUES('task','sessions/task.jsonl','Codex Desktop','vscode','user',0,1)",[]).unwrap();
            let reader = Reader::new(root.clone());
            let now = reader.started_ms;
            Self {
                root,
                file,
                reader,
                now,
            }
        }
        fn append(&self, kind: &str, payload: Value) {
            let at = DateTime::from_timestamp_millis(self.now as i64)
                .unwrap()
                .to_rfc3339();
            let record = json!({"timestamp":at,"type":kind,"payload":payload});
            let mut file = fs::OpenOptions::new()
                .append(true)
                .open(&self.file)
                .unwrap();
            writeln!(file, "{record}").unwrap();
        }
        fn poll(&mut self, owned: bool) -> Vec<Value> {
            let mut events = Vec::new();
            let now = self.now;
            self.reader
                .refresh(
                    now,
                    move |_, _| {
                        Some(if owned {
                            HashMap::from([("task".into(), now - 1000)])
                        } else {
                            HashMap::new()
                        })
                    },
                    |v| {
                        events.push(v.clone());
                        Ok(())
                    },
                )
                .unwrap();
            events
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn kinds(events: &[Value]) -> Vec<&str> {
        events.iter().map(|v| v["kind"].as_str().unwrap()).collect()
    }

    #[test]
    fn live_turn_tools_attention_completion_and_duplicates() {
        let mut f = Fixture::new();
        f.append(
            "event_msg",
            json!({"type":"task_started","turn_id":"turn-1"}),
        );
        let initial = f.poll(true);
        assert_eq!(kinds(&initial), ["turn_started", "working"]);
        assert!(f.poll(true).is_empty());
        f.append("response_item",json!({"type":"function_call","call_id":"call-1","name":"request_user_input","arguments":"PRIVATE PROMPT"}));
        let events = f.poll(true);
        assert_eq!(kinds(&events), ["working", "tool_started", "attention"]);
        assert!(!serde_json::to_string(&events).unwrap().contains("PRIVATE"));
        f.append(
            "response_item",
            json!({"type":"function_call_output","call_id":"unrelated","output":"PRIVATE RESULT"}),
        );
        assert_eq!(kinds(&f.poll(true)), ["working"]); // Attention remains pending.
        f.append(
            "response_item",
            json!({"type":"function_call_output","call_id":"call-1"}),
        );
        assert_eq!(kinds(&f.poll(true)), ["tool_finished", "working"]);
        f.append("event_msg",json!({"type":"task_complete","turn_id":"turn-1","last_agent_message":"PRIVATE ANSWER"}));
        assert_eq!(kinds(&f.poll(false)), ["turn_completed"]);
        f.append(
            "response_item",
            json!({"type":"reasoning","summary":["PRIVATE REASONING"]}),
        );
        assert!(f.poll(true).is_empty());
        f.append(
            "event_msg",
            json!({"type":"task_started","turn_id":"turn-2"}),
        );
        assert_eq!(kinds(&f.poll(true)), ["turn_started", "working"]);
        f.append(
            "event_msg",
            json!({"type":"turn_aborted","turn_id":"turn-2"}),
        );
        assert_eq!(kinds(&f.poll(false)), ["turn_cancelled"]);
    }
    #[test]
    fn historical_completion_and_dead_writers_never_light() {
        let mut f = Fixture::new();
        f.append("event_msg", json!({"type":"task_started","turn_id":"old"}));
        assert!(f.poll(false).is_empty());
        f.append("event_msg", json!({"type":"task_complete","turn_id":"old"}));
        f.reader = Reader::new(f.root.clone());
        assert!(f.poll(true).is_empty());
    }
    #[test]
    fn completed_items_do_not_invent_streaming_phases_or_end_a_turn() {
        let mut f = Fixture::new();
        f.append("turn_context", json!({"turn_id":"turn"}));
        f.poll(true);
        for item in ["Reasoning", "AgentMessage"] {
            f.append("event_msg",json!({"type":"item_completed","turn_id":"turn","item":{"type":item,"content":"PRIVATE","phase":"final"}}));
            assert_eq!(kinds(&f.poll(true)), ["working"]);
        }
    }
    #[test]
    fn source_loss_and_reconnect_require_new_evidence() {
        let mut f = Fixture::new();
        f.append("turn_context", json!({"turn_id":"turn"}));
        f.poll(true);
        assert_eq!(kinds(&f.poll(false)), ["source_lost"]);
        assert!(f.poll(true).is_empty());
        f.append("response_item", json!({"type":"reasoning"}));
        assert_eq!(kinds(&f.poll(true)), ["working"]);
        let database = f.root.join("state_5.sqlite");
        let hidden = f.root.join("hidden.sqlite");
        fs::rename(&database, &hidden).unwrap();
        let mut events = Vec::new();
        assert_eq!(
            f.reader
                .refresh(
                    f.now,
                    |_, _| Some(HashMap::new()),
                    |v| {
                        events.push(v.clone());
                        Ok(())
                    }
                )
                .unwrap_err(),
            "CodexDataNotFound"
        );
        assert_eq!(kinds(&events), ["source_lost"]);
        fs::rename(hidden, database).unwrap();
        assert!(f.poll(true).is_empty());
    }
    #[test]
    fn new_file_partial_writes_and_index_scope() {
        let mut f = Fixture::new();
        f.append("turn_context", json!({"turn_id":"turn"}));
        f.poll(true);
        let replacement = f.root.join("new.jsonl");
        fs::copy(&f.file, &replacement).unwrap();
        fs::rename(replacement, &f.file).unwrap();
        assert_eq!(kinds(&f.poll(true)), ["source_lost"]);
        f.append("response_item", json!({"type":"reasoning"}));
        assert_eq!(kinds(&f.poll(true)), ["working"]);
        let mut file = fs::OpenOptions::new().append(true).open(&f.file).unwrap();
        let at = DateTime::from_timestamp_millis(f.now as i64)
            .unwrap()
            .to_rfc3339();
        let line=format!("{{\"timestamp\":\"{at}\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_complete\",\"turn_id\":\"turn\"}}}}");
        file.write_all(line.as_bytes()).unwrap();
        assert!(f.poll(true).is_empty());
        file.write_all(b"\n").unwrap();
        assert_eq!(kinds(&f.poll(false)), ["turn_completed"]);
        let db = Connection::open(f.root.join("state_5.sqlite")).unwrap();
        db.execute(
            "INSERT INTO threads VALUES('cli','sessions/task.jsonl','Codex CLI','cli','user',0,2)",
            [],
        )
        .unwrap();
        db.execute("INSERT INTO threads VALUES('guardian','sessions/task.jsonl','Codex Desktop','vscode','subagent',0,3)",[]).unwrap();
        assert_eq!(f.reader.rows().unwrap().len(), 1);
        db.execute(
            "UPDATE threads SET rollout_path='../escape.jsonl' WHERE id='task'",
            [],
        )
        .unwrap();
        assert!(f.reader.rows().unwrap().is_empty());
    }
    #[test]
    fn process_elapsed_parser_is_bounded() {
        assert_eq!(elapsed_seconds("01:02"), Some(62));
        assert_eq!(elapsed_seconds("02:01:02"), Some(7262));
        assert_eq!(elapsed_seconds("3-02:01:02"), Some(266462));
        assert_eq!(elapsed_seconds("invalid"), None);
        assert_eq!(elapsed_seconds("18446744073709551615-01:01"), None);
    }
    #[test]
    fn real_core_replay_aggregates_and_recovers_without_hardware() {
        let Ok(binary) = std::env::var("KEYFLUX_TEST_CORE") else {
            return;
        };
        let mut f = Fixture::new();
        let directory = f.root.join("keyflux");
        fs::create_dir(&directory).unwrap();
        let core = Core::new(binary.into(), Some(directory), false);
        core.ensure().unwrap();
        struct Stop<'a>(&'a Core);
        impl Drop for Stop<'_> {
            fn drop(&mut self) {
                self.0.stop_owned();
            }
        }
        let _stop = Stop(&core);
        let forward = |events: Vec<Value>| {
            for event in events {
                core.emit_local_event(&event).unwrap();
            }
        };
        f.append("turn_context", json!({"turn_id":"turn"}));
        forward(f.poll(true));
        assert_eq!(
            core.call("status", None).unwrap()["result"]["state"]["phase"],
            "working"
        );
        f.append(
            "response_item",
            json!({"type":"function_call","call_id":"ask","name":"request_user_input"}),
        );
        forward(f.poll(true));
        assert_eq!(
            core.call("status", None).unwrap()["result"]["state"]["phase"],
            "attention"
        );
        forward(f.poll(false));
        assert_eq!(
            core.call("status", None).unwrap()["result"]["state"]["phase"],
            "unknown"
        );
        f.append(
            "response_item",
            json!({"type":"function_call_output","call_id":"ask"}),
        );
        forward(f.poll(true));
        assert_eq!(
            core.call("status", None).unwrap()["result"]["state"]["phase"],
            "working"
        );
        f.append(
            "event_msg",
            json!({"type":"task_complete","turn_id":"turn"}),
        );
        forward(f.poll(false));
        assert_eq!(
            core.call("status", None).unwrap()["result"]["state"]["phase"],
            "complete"
        );
    }
    #[test]
    #[ignore = "Read-only verification against the user's current real Codex Desktop data"]
    fn manual_real_desktop_source() {
        let binary = std::env::var_os("KEYFLUX_TEST_CORE").expect("built Zig core");
        let directory = test_root().join(format!("keyflux-live-source-{}", now_ns()));
        fs::create_dir(&directory).unwrap();
        let core = Core::new(binary.into(), Some(directory.clone()), false);
        core.ensure().unwrap();
        struct Stop<'a>(&'a Core);
        impl Drop for Stop<'_> {
            fn drop(&mut self) {
                self.0.stop_owned();
            }
        }
        let stop = Stop(&core);
        let source = Source::default();
        source.poll(&core);
        let snapshot = source.snapshot();
        println!("source: {snapshot}");
        assert_eq!(snapshot["available"], true);
        assert!(snapshot["active_sessions"].as_u64().unwrap() > 0);
        let status = core.call("status", None).unwrap();
        println!("aggregated state: {}", status["result"]["state"]);
        assert!(matches!(
            status["result"]["state"]["phase"].as_str(),
            Some("working" | "tool" | "attention")
        ));
        drop(stop);
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn concurrent_roots_keep_the_other_turn_active() {
        let mut f = Fixture::new();
        f.append("event_msg", json!({"type":"task_started","turn_id":"one"}));
        let other = f.root.join("sessions/other.jsonl");
        fs::write(&other, b"").unwrap();
        let db = Connection::open(f.root.join("state_5.sqlite")).unwrap();
        db.execute("INSERT INTO threads VALUES('other','sessions/other.jsonl','Codex Desktop','vscode','user',0,2)",[]).unwrap();
        let original = std::mem::replace(&mut f.file, other);
        f.append("event_msg", json!({"type":"task_started","turn_id":"two"}));
        let mut events = Vec::new();
        let now = f.now;
        let writers = move |_: &Path, _: &[Row]| {
            Some(HashMap::from([
                ("task".into(), now - 1000),
                ("other".into(), now - 1000),
            ]))
        };
        f.reader
            .refresh(now, writers, |v| {
                events.push(v.clone());
                Ok(())
            })
            .unwrap();
        assert_eq!(
            events
                .iter()
                .filter(|v| v["kind"] == "turn_started")
                .count(),
            2
        );
        f.append("event_msg", json!({"type":"task_complete","turn_id":"two"}));
        events.clear();
        f.reader
            .refresh(now, writers, |v| {
                events.push(v.clone());
                Ok(())
            })
            .unwrap();
        assert_eq!(kinds(&events), ["turn_completed"]);
        assert_eq!(
            f.reader
                .sessions
                .values()
                .filter(|s| s.published.as_ref().is_some_and(|p| !p.terminal && !p.lost))
                .count(),
            1
        );
        f.file = original;
    }
    #[test]
    fn failed_emit_retains_the_session_for_fail_closed_recovery() {
        let mut f = Fixture::new();
        f.append("turn_context", json!({"turn_id":"turn"}));
        let now = f.now;
        let mut delivered = 0;
        let failure = f.reader.refresh(
            now,
            |_, _| Some(HashMap::from([("task".into(), now - 1000)])),
            |_| {
                delivered += 1;
                if delivered == 2 {
                    Err("CoreUnavailable".into())
                } else {
                    Ok(())
                }
            },
        );
        assert_eq!(failure.unwrap_err(), "CoreUnavailable");
        assert!(f.reader.sessions["task"].published.is_some());
        let mut session = f.reader.sessions.remove("task").unwrap();
        let mut events = Vec::new();
        f.reader
            .lose("task", &mut session, &mut |v| {
                events.push(v.clone());
                Ok(())
            })
            .unwrap();
        assert_eq!(kinds(&events), ["source_lost"]);
        f.reader.sessions.insert("task".into(), session);
        assert!(f.poll(true).is_empty());
        f.append("response_item", json!({"type":"reasoning"}));
        assert_eq!(kinds(&f.poll(true)), ["working"]);
    }
    #[test]
    fn pending_request_capacity_fails_closed() {
        let mut f = Fixture::new();
        f.append("turn_context", json!({"turn_id":"turn"}));
        f.poll(true);
        for i in 0..9 {
            f.append(
                "response_item",
                json!({"type":"function_call","call_id":format!("request-{i}")}),
            );
        }
        let now = f.now;
        assert_eq!(
            f.reader
                .refresh(
                    now,
                    |_, _| Some(HashMap::from([("task".into(), now - 1000)])),
                    |_| Ok(())
                )
                .unwrap_err(),
            "CodexRequestCapacity"
        );
        assert!(f.reader.sessions["task"].observation.overflow);
    }
    #[test]
    fn cold_start_searches_past_a_large_tool_record_without_replaying_completion() {
        let mut f = Fixture::new();
        f.append("turn_context", json!({"turn_id":"turn"}));
        let mut file = fs::OpenOptions::new().append(true).open(&f.file).unwrap();
        for _ in 0..8 {
            file.write_all(&vec![b'x'; 1024 * 1024]).unwrap();
        }
        file.write_all(b"\n").unwrap();
        drop(file);
        f.append("response_item", json!({"type":"reasoning"}));
        let mut events = Vec::new();
        for _ in 0..8 {
            events.extend(f.poll(true));
        }
        assert_eq!(kinds(&events), ["turn_started", "working"]);
        assert_eq!(f.reader.sessions["task"].tail.retained_bytes(), 0);
    }
    #[test]
    fn a_new_short_turn_completed_before_its_first_scan_still_signals_completion() {
        let mut f = Fixture::new();
        f.now += 1;
        f.append(
            "event_msg",
            json!({"type":"task_started","turn_id":"short"}),
        );
        f.append(
            "event_msg",
            json!({"type":"task_complete","turn_id":"short"}),
        );
        assert_eq!(kinds(&f.poll(false)), ["turn_started", "turn_completed"]);
        assert!(f.poll(false).is_empty());
    }
}
