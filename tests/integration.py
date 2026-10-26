"""Black-box tests against the built Zig executable; never writes real HID."""
import http.client
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest

EXE = str(Path(sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/keyflux").resolve())


def varint(n):
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def message(field, data):
    return varint(field * 8 + 2) + varint(len(data)) + data


def attribute(key, value):
    return message(1, key.encode()) + message(2, message(1, value.encode()))


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        # Keep Unix socket path below sockaddr_un.sun_path's limit.
        self.temp = tempfile.TemporaryDirectory(prefix="kf-", dir="/private/tmp" if sys.platform == "darwin" else None)
        self.directory = Path(self.temp.name)
        self.process = None
        self.start()

    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.call("stop", check=False)
            self.process.wait(timeout=5)
        if self.process:
            self.process.stdout.close()
            self.process.stderr.close()
        self.temp.cleanup()

    def start(self, port=None):
        args = [EXE, "serve", "--simulate", "--state-dir", str(self.directory)]
        if port:
            args += ["--otlp-port", str(port)]
        self.process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(self.process.stdout.readline()), daemon=True).start()
        line = lines.get(timeout=8)
        self.assertTrue(line, "daemon exited without readiness")
        self.assertTrue(json.loads(line)["ready"], line)

    def call(self, *args, data=None, check=True):
        proc = subprocess.run([EXE, *args, "--state-dir", str(self.directory)], input=data, text=True, encoding="utf-8", capture_output=True, timeout=5)
        if check:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def emit(self, kind, session="test-session", turn="turn-1", **extra):
        now = time.time_ns()
        event = dict(schema_version=1, provider="codex", session_id=session, turn_id=turn, event_id=f"{now}-{kind}", timestamp_ns=now, kind=kind, **extra)
        return json.loads(self.call("emit", data=json.dumps(event)).stdout)

    def status(self):
        return json.loads(self.call("status").stdout)["result"]

    def test_hardware_commands_reject_isolated_state_before_device_access(self):
        for args in [("hardware-solid", "#06B6D4", "15"), ("hardware-restore",), ("hardware-verify-restore",)]:
            result = self.call(*args, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["code"], "HardwareRequiresDefaultStateDirectory")
        self.assertFalse((self.directory / "kick75-recovery.json").exists())
        self.assertEqual(self.status()["backend"], "simulated")

    def test_theme_v2_side_configuration_roundtrips_without_hardware_enable(self):
        theme = json.loads(self.call("theme-get").stdout)["theme"]
        self.assertEqual(theme["schema_version"], 1)
        self.assertNotIn("side", theme)
        theme["schema_version"] = 2
        theme["name"] = "冰蓝主题"
        theme["side"] = {"enabled": True, "mode": "independent", "signals": {"thinking": {"color": "#C084FC", "brightness": 25}}}
        self.call("theme-set", data=json.dumps(theme))
        saved = json.loads(self.call("theme-get").stdout)["theme"]
        self.assertEqual(saved["side"]["signals"]["thinking"]["color"], "#C084FC")
        self.assertEqual(saved["signals"]["thinking"]["color"], "#06B6D4")
        self.assertFalse(self.status()["side_write_enabled"])
        self.assertEqual(self.status()["theme_schema_versions"], [1, 2])
        self.emit("turn_started")
        self.emit("thinking")
        self.assertEqual(self.status()["acknowledged"]["color"], dict(r=6, g=182, b=212))
        invalid = json.loads(json.dumps(saved))
        invalid["side"]["signals"]["thinking"]["brightness"] = 101
        self.assertNotEqual(self.call("theme-set", data=json.dumps(invalid), check=False).returncode, 0)
        self.assertEqual(json.loads(self.call("theme-get").stdout)["theme"], saved)
        self.call("stop")
        self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()
        self.start()
        self.assertEqual(json.loads(self.call("theme-get").stdout)["theme"], saved)

    def test_event_ipc_theme_preview_and_restore(self):
        self.emit("turn_started")
        self.emit("thinking")
        state = self.status()
        self.assertEqual(state["state"]["phase"], "thinking")
        self.assertEqual(state["backend"], "simulated")
        self.assertFalse(state["release_ready"])
        self.assertIsNotNone(state["acknowledged"])
        journal = json.loads((self.directory / "recovery.json").read_text())
        self.assertEqual(journal["backend"], "simulated")
        self.emit("output")
        theme = json.loads(self.call("theme-get").stdout)["theme"]
        theme["signals"]["output"]["color"] = "#112233"
        self.call("theme-set", data=json.dumps(theme))
        self.assertEqual(self.status()["acknowledged"]["color"], dict(r=17, g=34, b=51))
        self.call("preview", "thinking")
        self.assertEqual(self.status()["preview"], "thinking")
        self.call("preview", "output", "--signal-stdin", data=json.dumps(dict(color="#445566", brightness=20)))
        self.assertEqual(self.status()["acknowledged"], dict(color=dict(r=68, g=85, b=102), brightness=20))
        self.assertEqual(json.loads(self.call("theme-get").stdout)["theme"]["signals"]["output"]["color"], "#112233")
        self.call("reset")
        self.assertEqual(self.status()["state"]["phase"], "idle")
        self.assertFalse((self.directory / "recovery.json").exists())

    def test_crash_recovery_restores_before_new_takeover(self):
        self.emit("turn_started")
        self.emit("output")
        original = json.loads((self.directory / "recovery.json").read_text())["original"]["main"]
        self.process.kill()
        self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()
        self.start()
        self.assertFalse((self.directory / "recovery.json").exists())
        self.assertEqual(json.loads((self.directory / "simulated-device.json").read_text()), original)

    def test_duplicate_daemon_cannot_steal_endpoint(self):
        second = self.call("serve", "--simulate", check=False)
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(self.status()["state"]["phase"], "idle")

    def test_invalid_theme_does_not_replace_last_valid_configuration(self):
        theme = json.loads(self.call("theme-get").stdout)["theme"]
        theme["signals"]["thinking"]["brightness"] = 255
        invalid = self.call("theme-set", data=json.dumps(theme), check=False)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(json.loads(self.call("theme-get").stdout)["theme"]["signals"]["thinking"]["brightness"], 50)

    def test_hooks_are_content_free_and_fail_open(self):
        secret = "DO_NOT_STORE_PROMPT_729"
        hook = dict(hook_event_name="UserPromptSubmit", session_id="hook-session", turn_id="hook-turn", prompt=secret)
        result = self.call("hook", data=json.dumps(hook))
        self.assertEqual(result.stdout, "{}\n")
        self.assertEqual(self.status()["state"]["phase"], "working")
        for path in self.directory.iterdir():
            if path.is_file():
                self.assertNotIn(secret.encode(), path.read_bytes())
        self.call("stop")
        self.process.wait(timeout=5)
        result = self.call("hook", data=json.dumps(hook))
        self.assertEqual(result.stdout, "{}\n")

    def test_explicit_source_loss_is_unknown(self):
        self.emit("turn_started")
        self.emit("source_lost")
        status = self.status()
        self.assertEqual(status["state"]["phase"], "unknown")
        self.assertIsNone(status["acknowledged"])

    def test_otlp_json_protobuf_auth_and_privacy(self):
        import socket
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.call("stop")
        self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()
        self.start(port)
        token = (self.directory / "otlp-token").read_text()
        self.emit("turn_started")

        def post(payload, content_type="application/json", bearer=token, **headers):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            conn.request("POST", "/v1/logs", payload, {"Content-Type": content_type, "Authorization": f"Bearer {bearer}", **headers})
            response = conn.getresponse()
            status, body = response.status, response.read()
            conn.close()
            return status, body

        self.assertEqual(post(b"{}", bearer="wrong")[0], 401)
        self.assertEqual(post(b"{}", Origin="https://example.com")[0], 400)
        attrs = lambda **values: [dict(key=k, value=dict(stringValue=v)) for k, v in values.items()]
        payload = dict(resourceLogs=[dict(scopeLogs=[dict(logRecords=[dict(timeUnixNano=str(time.time_ns()), attributes=attrs(**{"event.name": "codex.sse_event", "event.kind": "response.reasoning_summary_text.delta", "conversation.id": "test-session"}), body=dict(stringValue="SECRET_BODY_729"))])])])
        self.assertEqual(post(json.dumps(payload).encode())[0], 200)
        self.assertEqual(self.status()["state"]["phase"], "thinking")
        timestamp = varint(1 * 8 + 1) + time.time_ns().to_bytes(8, "little")
        record = timestamp
        for k, v in {"event.name": "codex.websocket_event", "event.kind": "response.output_text.delta", "conversation.id": "test-session"}.items():
            record += message(6, attribute(k, v))
        record += message(5, message(1, b"SECRET_PROTO_BODY_729"))
        binary = message(1, message(2, message(2, record)))
        self.assertEqual(post(binary, "application/x-protobuf"), (200, b""))
        status = self.status()
        self.assertEqual(status["state"]["phase"], "output")
        self.assertEqual(status["evidence"]["reasoning"], 1)
        self.assertEqual(status["evidence"]["output"], 1)
        self.assertFalse(status["release_ready"])
        self.assertEqual(post(b"\x0a\xff", "application/x-protobuf")[0], 400)
        for path in self.directory.iterdir():
            if path.is_file():
                self.assertNotIn(b"SECRET_", path.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
