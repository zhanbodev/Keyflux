"""Measure the simulated local pipeline; never certifies HID or Codex latency."""
import argparse
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path
import platform
import queue
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("executable")
parser.add_argument("--output", required=True)
parser.add_argument("--idle-seconds", type=float, default=5)
parser.add_argument("--samples", type=int, default=100)
args = parser.parse_args()
if not 1 <= args.idle_seconds <= 60 or not 20 <= args.samples <= 1000:
    parser.error("idle-seconds must be 1–60; samples must be 20–1000")
exe = str(Path(args.executable).resolve())

with tempfile.TemporaryDirectory(prefix="kf-bench-", dir="/private/tmp" if platform.system() == "Darwin" else None) as directory:
    def call(*command, data=None):
        run = subprocess.run([exe, *command, "--state-dir", directory], input=data, text=True, capture_output=True, timeout=5, check=True)
        return json.loads(run.stdout)

    daemon = subprocess.Popen([exe, "serve", "--simulate", "--state-dir", directory], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(daemon.stdout.readline()), daemon=True).start()
        if not json.loads(lines.get(timeout=8)).get("ready"):
            raise RuntimeError("daemon failed to start")
        before = call("status")["result"]["process_metrics"]
        time.sleep(args.idle_seconds)
        after = call("status")["result"]["process_metrics"]
        if not before["available"] or not after["available"]:
            raise RuntimeError("process metrics unavailable")
        cpu_percent = (after["cpu_time_ns"] - before["cpu_time_ns"]) / (after["monotonic_ns"] - before["monotonic_ns"]) * 100

        def emit(kind, index):
            event = dict(schema_version=1, provider="benchmark", session_id="session", turn_id="turn", event_id=f"event-{index}", timestamp_ns=time.time_ns(), kind=kind)
            return call("emit", data=json.dumps(event))

        emit("turn_started", 0)
        timings = []
        for index in range(1, args.samples + 1):
            started = time.perf_counter_ns()
            response = emit("thinking" if index % 2 else "output", index)
            if not response.get("ok"):
                raise RuntimeError(response)
            timings.append((time.perf_counter_ns() - started) / 1_000_000)
        loaded = call("status")["result"]["process_metrics"]
        p95 = sorted(timings)[int(len(timings) * .95 + .999999) - 1]
        report = dict(
            measured_at=datetime.now(timezone(timedelta(hours=8))).isoformat(),
            version=call("version")["version"],
            host=dict(system=platform.system(), release=platform.release(), architecture=platform.machine()),
            backend="simulated",
            idle_seconds=args.idle_seconds,
            idle_cpu_percent_one_core=round(cpu_percent, 4),
            idle_resident_bytes=after["resident_bytes"],
            after_samples_resident_bytes=loaded["resident_bytes"],
            samples=len(timings),
            simulated_cli_to_ack_p95_ms=round(p95, 3),
            note="Includes CLI startup, IPC and simulated durable writes. Does not measure real HID, actual Codex export delay or physical lighting.",
            real_hid_verified=False,
            live_codex_desktop_verified=False,
            release_ready=False,
        )
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        if daemon.poll() is None:
            try:
                call("stop")
                daemon.wait(timeout=5)
            except Exception:
                daemon.kill()
                daemon.wait(timeout=5)
        daemon.stdout.close()
        daemon.stderr.close()
