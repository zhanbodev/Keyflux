"""P0 IPC + real child-process check results; never touches HID or user state."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else str(Path('zig-out/bin/keyflux').resolve())

class Workflow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='keyflux-p0-', dir='/private/tmp' if sys.platform == 'darwin' else None)
        self.server = subprocess.Popen([BINARY, 'serve', '--state-dir', self.tmp.name], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for _ in range(80):
            if self.cli('status', check=False).returncode == 0:
                return
            time.sleep(.05)
        self.fail('Core did not start')
    def tearDown(self):
        self.cli('stop', check=False)
        self.server.communicate(timeout=5)
        self.tmp.cleanup()
    def cli(self, *args, **kwargs):
        return subprocess.run([BINARY, '--state-dir', self.tmp.name, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, **kwargs)
    def tasks(self):
        return json.loads(self.cli('tasks', check=True).stdout)['tasks']
    def test_real_pass_fail_cancel_and_ack(self):
        result = self.cli('check', 'test', '--label', 'project-a', '--', sys.executable, '-c', 'print("private output"); raise SystemExit(0)')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'private output', result.stdout)
        task = self.tasks()[0]
        self.assertEqual((task['phase'], task['label']), ('verified', 'project-a'))
        self.assertNotIn('private output', json.dumps(self.tasks()))
        result = self.cli('check', 'build', '--', sys.executable, '-c', 'raise SystemExit(7)')
        self.assertEqual(result.returncode, 7, result.stderr)
        failed = next(t for t in self.tasks() if t['phase'] == 'check_failed')
        self.assertEqual(json.loads(self.cli('status').stdout)['result']['state']['phase'], 'check_failed')
        self.cli('acknowledge', input=json.dumps({k: failed[k] for k in ['provider', 'session_id', 'turn_id']}).encode(), check=True)
        self.assertTrue(next(t for t in self.tasks() if t['session_id'] == failed['session_id'])['acknowledged'])
        self.assertNotEqual(json.loads(self.cli('status').stdout)['result']['state']['phase'], 'check_failed')
        result = self.cli('check', 'test', '--', sys.executable, '-c', 'raise SystemExit(130)')
        self.assertEqual(result.returncode, 130)
        self.assertTrue(any(t['cancelled'] for t in self.tasks()))
    def test_arguments_are_literal_and_child_runs_only_after_valid_event(self):
        literals = ['--state-dir', 'literal value', '$(echo unsafe)', 'quoted "value"', 'trailing' + chr(92), '']
        result = self.cli('check', 'build', '--', sys.executable, '-c', 'import json,sys; print(json.dumps(sys.argv[1:]))', *literals)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), literals)
        result = self.cli('check', 'test', '--label', 'bad label', '--', sys.executable, '-c', 'print("MUST_NOT_RUN")')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'MUST_NOT_RUN', result.stdout)
    @unittest.skipIf(os.name == 'nt', 'POSIX signal-specific; Windows exit mapping tested separately')
    def test_sigterm_reports_cancellation_and_reaps_child(self):
        child = subprocess.Popen([BINARY, '--state-dir', self.tmp.name, 'check', 'test', '--', sys.executable, '-c', 'import time; time.sleep(20)'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(50):
                if self.tasks(): break
                time.sleep(.03)
            time.sleep(.1)
            child.send_signal(signal.SIGTERM)
            child.communicate(timeout=5)
            self.assertEqual(child.returncode, 143)
            self.assertTrue(self.tasks()[0]['cancelled'])
        finally:
            if child.poll() is None: child.kill(); child.communicate()

if __name__ == '__main__': unittest.main()
