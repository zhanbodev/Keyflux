#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/probe-codex-phases.py'
spec = importlib.util.spec_from_file_location('phase_probe', SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class PhaseProbeTest(unittest.TestCase):
    def test_structural_counts_are_read_only_and_never_a_realtime_pass(self):
        with tempfile.TemporaryDirectory(prefix='keyflux-phase-probe-') as directory:
            root = Path(directory)
            path = root / 'logs_2.sqlite'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,ts_nanos INTEGER,target TEXT,feedback_log_body TEXT,thread_id TEXT)')
                for done in (False, True):
                    scope = 'receiving_stream: handle_output_item_done: ' if done else ''
                    body = ('session_task.run: thread.id=private-session run_turn: turn.id=private-turn ' +
                            scope + 'Output item item_type="reasoning" item_id="private-item"')
                    db.execute("INSERT INTO logs(ts,ts_nanos,target,feedback_log_body,thread_id) VALUES(1,1,'codex_core::stream_events_utils',?,'private-session')", (body,))
                db.execute("INSERT INTO logs(ts,ts_nanos,target,feedback_log_body,thread_id) VALUES(1,1,'user_prompt','PRIVATE PROMPT AND CREDENTIAL','private-session')")
            db.close()
            before = hashlib.sha256(path.read_bytes()).digest()
            report = probe.probe(root)
            self.assertTrue(report['phase_callbacks_exist'])
            self.assertFalse(report['realtime_lighting_accepted'])
            self.assertEqual(report['structural_records']['reasoning/added'], 1)
            self.assertEqual(report['structural_records']['reasoning/completed'], 1)
            self.assertEqual(before, hashlib.sha256(path.read_bytes()).digest())
            serialized = json.dumps(report)
            for private in ['private-session', 'private-turn', 'private-item', 'PRIVATE', str(root)]:
                self.assertNotIn(private, serialized)
            result = subprocess.run([sys.executable, str(SCRIPT), '--home', str(root), '--assert-realtime'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(json.loads(result.stdout)['realtime_lighting_accepted'])

    def test_missing_and_unknown_schema_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(probe.probe(root)['code'], 'CodexPhaseLogsUnavailable')
            with sqlite3.connect(root / 'logs_1.sqlite') as db:
                db.execute('CREATE TABLE logs(id INTEGER)')
            db.close()
            self.assertEqual(probe.probe(root)['code'], 'UnsupportedCodexPhaseSchema')

    def test_conflicting_identity_and_uncorrelated_notifications_are_rejected(self):
        body = 'session_task.run: thread.id=thread run_turn: turn.id=turn Output item item_type="message" item_id="item"'
        self.assertEqual(probe.classify(body, 'thread'), ('message', 'added'))
        self.assertIsNone(probe.classify(body, 'another-thread'))
        self.assertIsNone(probe.classify(body.replace('turn.id=turn', 'turn.id=turn turn.id=another'), 'thread'))
        self.assertIsNone(probe.classify('app-server event: item/agentMessage/delta', 'thread'))
        self.assertIsNone(probe.classify('Output item item_type="reasoning"', 'thread'))


if __name__ == '__main__':
    unittest.main()
