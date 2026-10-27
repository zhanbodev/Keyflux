#!/usr/bin/env python3
"""Read-only developer probe. Reports structural counts, never conversation content.

This is a development diagnostic, not an App runtime dependency or lighting source.
"""
import argparse
import collections
from contextlib import closing
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import sys
import time

REFERENCE = "fd591b6049c2745a2097baab41180fbdb19bdac0"
IDENTIFIER = r"[A-Za-z0-9_.:-]{1,160}"


def newest(root, prefix):
    found = []
    for path in root.glob(prefix + "_*.sqlite"):
        try:
            version = int(path.stem[len(prefix) + 1:])
            real = path.resolve(strict=True)
            real.relative_to(root)
            found.append((version, real))
        except (ValueError, OSError):
            continue
    return max(found, default=(0, None))[1]


def connect(path):
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.1)
    connection.execute("PRAGMA query_only=ON")
    return connection


def field(text, name):
    values = re.findall(r"(?<![A-Za-z0-9_.])" + re.escape(name) +
                        r'=(?:"(' + IDENTIFIER + r')"|(' + IDENTIFIER + r"))", text)
    values = {a or b for a, b in values}
    return next(iter(values)) if len(values) == 1 else None


def classify(body, thread_id):
    if len(body) > 4096 or "Output item " not in body:
        return None
    scope, fields = body.rsplit("Output item ", 1)
    if "session_task.run:" not in scope or "run_turn:" not in scope:
        return None
    if field(scope, "thread.id") != thread_id or not field(scope, "turn.id"):
        return None
    kind = field(fields, "item_type")
    if kind not in ("reasoning", "message") or not field(fields, "item_id"):
        return None
    done = "receiving_stream:" in scope and "handle_output_item_done:" in scope
    start = "receiving_stream:" not in scope and "handle_output_item_done:" not in scope
    return (kind, "completed" if done else "added") if done or start else None


def transport_summary():
    # Process arguments are examined locally and discarded. No arguments, PIDs,
    # private socket paths, endpoints or credential values appear in the report.
    if sys.platform != "darwin":
        return {"inspected": False, "reason": "macOS-only process inspection"}
    try:
        pids = subprocess.run(["/usr/bin/pgrep", "-x", "codex"], capture_output=True,
                              text=True, timeout=2).stdout.split()
        counts = collections.Counter()
        if pids:
            lines = subprocess.run(["/bin/ps", "-p", ",".join(pids), "-o", "command="],
                                   capture_output=True, text=True, timeout=2).stdout.splitlines()
            for line in lines:
                try:
                    args = shlex.split(line)
                except ValueError:
                    continue
                if len(args) < 2 or args[1] != "app-server":
                    continue
                match = re.search(r"--listen\s+(stdio|unix|ws)://", line)
                counts[match.group(1) if match else "not-established"] += 1
        return {"inspected": True, "app_server_transport_counts": dict(counts),
                "subscription_tested": False}
    except (OSError, subprocess.SubprocessError):
        return {"inspected": False, "reason": "process metadata unavailable"}


def probe(root, observe_seconds=0, interval_ms=100, inspect_transports=False):
    root = root.resolve()
    path = newest(root, "logs")
    report = {
        "schema_version": 1,
        "candidate": "codex_feedback_sqlite",
        "reference_commit": REFERENCE,
        "realtime_lighting_accepted": False,
        "reason": "BatchedDiagnosticLogIsNotARealtimeSubscription",
        "reference_default_flush_ms": 10000,
        "reference_batch_size": 512,
        "phase_callbacks_exist": False,
        "content_retained": False,
        "configuration_changed": False,
        "root_session_liveness_checked": False,
    }
    if inspect_transports:
        report["transport"] = transport_summary()
    if path is None:
        report["code"] = "CodexPhaseLogsUnavailable"
        return report
    counts = collections.Counter()
    delays = []
    with closing(connect(path)) as db:
        columns = {row[1] for row in db.execute("PRAGMA table_info(logs)")}
        required = {"id", "ts", "ts_nanos", "target", "feedback_log_body", "thread_id"}
        if not required.issubset(columns):
            report["code"] = "UnsupportedCodexPhaseSchema"
            return report
        head = db.execute("SELECT COALESCE(MAX(id),0) FROM logs").fetchone()[0]
        cursor = max(0, head - 10000)
        deadline = time.monotonic() + observe_seconds
        first = True
        while True:
            rows = db.execute(
                "SELECT id,ts,ts_nanos,substr(feedback_log_body,1,4097),thread_id "
                "FROM logs WHERE id>? AND target='codex_core::stream_events_utils' "
                "AND instr(feedback_log_body,'Output item ')>0 ORDER BY id LIMIT 2049",
                (cursor,),
            ).fetchall()
            observed = time.time_ns()
            if len(rows) > 2048:
                report["code"] = "ProbeBacklogLimit"
                break
            for ident, seconds, nanos, body, thread in rows:
                cursor = ident
                value = classify(body, thread)
                if value:
                    counts["/".join(value)] += 1
                    if not first and seconds > 0 and 0 <= nanos < 1000000000:
                        delay = observed - (seconds * 1000000000 + nanos)
                        if delay >= 0:
                            delays.append(round(delay / 1000000, 3))
            # Bound observation memory without persisting any source record.
            if len(delays) > 4096:
                report["code"] = "ProbeSampleLimit"
                break
            first = False
            if time.monotonic() >= deadline:
                break
            time.sleep(min(interval_ms / 1000, max(0, deadline - time.monotonic())))
    report["phase_callbacks_exist"] = bool(counts)
    report["structural_records"] = dict(counts)
    report["observation_seconds"] = observe_seconds
    report["new_record_delay_ms"] = {
        "samples": len(delays),
        "max": max(delays) if delays else None,
        "includes_diagnostic_batching": True,
        "not_model_to_light_latency": True,
    }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path,
                        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--observe-seconds", type=float, default=0)
    parser.add_argument("--interval-ms", type=int, default=100)
    parser.add_argument("--inspect-transports", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--assert-realtime", action="store_true")
    args = parser.parse_args()
    if not 0 <= args.observe_seconds <= 30 or not 50 <= args.interval_ms <= 1000:
        parser.error("observation must be 0..30 seconds, interval 50..1000 ms")
    try:
        result = probe(args.home, args.observe_seconds, args.interval_ms, args.inspect_transports)
    except (OSError, sqlite3.Error):
        result = {"schema_version": 1, "realtime_lighting_accepted": False,
                  "code": "CodexPhaseProbeUnavailable", "content_retained": False,
                  "configuration_changed": False}
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")
    return 2 if args.assert_realtime and not result["realtime_lighting_accepted"] else 0


if __name__ == "__main__":
    sys.exit(main())
