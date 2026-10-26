"""Manual macOS hardware fault injection; never run in unattended CI.

Usage: python3 scripts/verify-kick75-crash.py [path/to/keyflux]
Requires USB Kick75 IO / 4.0.18.6 / Mac profile, no pending capture,
and no competing lighting clients. A finally block restores the initial effect.
A missed applied-write/pending-acknowledgement window fails the experiment.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

if sys.platform != "darwin":
    raise SystemExit("This manual hardware check requires macOS.")
if len(sys.argv) > 2:
    raise SystemExit(__doc__)
binary = str(
    Path(sys.argv[1]).resolve() if len(sys.argv) == 2
    else Path(__file__).resolve().parents[1] / "zig-out/bin/keyflux"
)
record_path = Path.home() / "Library/Application Support/Keyflux/kick75-recovery.json"


def call(*args, check=True):
    process = subprocess.run(
        [binary, *args], capture_output=True, text=True, timeout=10
    )
    value = json.loads(process.stdout)
    if check and process.returncode:
        raise RuntimeError(value)
    return process.returncode, value


_, before = call("hardware-probe")
if record_path.exists():
    raise SystemExit("Restore the previous capture before this crash experiment.")
writer = None
try:
    writer = subprocess.Popen(
        [binary, "hardware-solid", "#FF0000", "15"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if record_path.exists() and json.loads(record_path.read_text()).get("pending"):
            break
        if writer.poll() is not None:
            raise RuntimeError("Writer exited before fault injection.")
        time.sleep(0.005)
    else:
        raise RuntimeError("No durable pending transaction.")
    time.sleep(1.08)
    if writer.poll() is not None:
        raise RuntimeError("Writer already finished; fault was not injected.")
    writer.kill()
    writer.communicate(timeout=5)
    assert writer.returncode != 0
    assert json.loads(record_path.read_text())["pending"] is True
    _, interrupted = call("hardware-probe")
    code, rejected = call("hardware-solid", "#00FFFF", "15", check=False)
    assert code == 1 and rejected["code"] == "RecoveryRequired"
    result = {
        "signal": "SIGKILL",
        "setter_applied_before_termination": interrupted["state"][:9]
        == [3, 15, 2, 0, 0, 0, 255, 0, 0],
        "interrupted_state": interrupted["state"],
        "next_color_rejected": rejected["code"],
    }
finally:
    if writer is not None and writer.poll() is None:
        writer.kill()
        writer.communicate(timeout=5)
    call("hardware-restore")
_, after = call("hardware-probe")
assert before["state"] == after["state"]
assert not record_path.exists()
result.update(exact_original_restored=True, journal_removed_after_verification=True)
assert result["setter_applied_before_termination"], (
    "Setter had not applied: repeat the experiment; recovery still completed."
)
print(json.dumps(result))
