"""Política de retomada, encerramento da janela e limpeza dos processos supervisionados."""
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from service_runner import load_settings, supervise
from manage_services import make_plist


class ServicesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.window = self.root / 'collector-config.json'
        self.settings = self.root / 'settings.json'
        self.now = datetime.now(timezone.utc)
        self.window.write_text(json.dumps({'start':(self.now-timedelta(hours=1)).isoformat(),
                                          'end':(self.now+timedelta(hours=1)).isoformat()}))
        self.config = {'collector_config':str(self.window), 'supervisor_python':sys.executable,
                       'environment':{'PATH':'/usr/bin:/bin'},
                       'services':{name:{'command':[sys.executable,'-c','pass'], 'cwd':str(self.root)}
                                   for name in ['collector','publisher']}}
        self.save()

    def save(self):
        self.settings.write_text(json.dumps(self.config))

    def status(self, name='publisher'):
        return json.loads((self.root / f'{name}-status.json').read_text())

    def test_even_successful_premature_exit_requests_restart(self):
        self.assertEqual(supervise(self.settings, 'publisher', poll_seconds=.01), 1)
        self.assertEqual(self.status()['phase'], 'restart_required')
        self.assertEqual(self.status()['child_exit_code'], 0)

    def test_crash_requests_restart(self):
        self.config['services']['publisher']['command'][-1] = 'import os,signal; os.kill(os.getpid(),signal.SIGKILL)'
        self.save()
        self.assertEqual(supervise(self.settings, 'publisher', poll_seconds=.01), 1)
        self.assertEqual(self.status()['child_exit_code'], -signal.SIGKILL)

    def test_finished_window_does_not_start_or_restart_child(self):
        with patch('service_runner.subprocess.Popen') as popen:
            self.assertEqual(supervise(self.settings, 'collector', now=lambda:self.now+timedelta(hours=2)), 0)
        popen.assert_not_called()
        self.assertEqual(self.status('collector')['phase'], 'window_finished')

    def test_running_child_is_stopped_when_window_ends(self):
        self.config['services']['publisher']['command'][-1] = 'import time; time.sleep(60)'
        self.save()
        calls = 0
        def clock():
            nonlocal calls
            calls += 1
            return self.now if calls < 3 else self.now+timedelta(hours=2)
        self.assertEqual(supervise(self.settings, 'publisher', now=clock, poll_seconds=.01), 0)
        self.assertEqual(self.status()['phase'], 'window_finished')

    def test_second_supervisor_is_refused_without_starting_another_child(self):
        with (self.root / '.publisher.supervisor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch('service_runner.subprocess.Popen') as popen, self.assertRaises(BlockingIOError):
                supervise(self.settings, 'publisher')
        popen.assert_not_called()

    def test_receipt_points_to_current_child_not_previous_pid(self):
        path = self.root / 'launch.json'
        path.write_text('{"pid":123}')
        self.config['services']['collector']['launch_receipt'] = str(path)
        self.save()
        supervise(self.settings, 'collector', poll_seconds=.01)
        receipt = json.loads(path.read_text())
        self.assertNotEqual(receipt['pid'], 123)
        self.assertEqual(receipt['pid'], self.status('collector')['child_pid'])
        self.assertEqual(receipt['managed_by'], 'launchd')

    def test_plist_starts_at_login_retries_failure_and_cleans_descendants(self):
        for name in ['collector','publisher']:
            plist = plistlib.loads(plistlib.dumps(make_plist(name,self.settings,self.config)))
            self.assertTrue(plist['RunAtLoad'])
            self.assertEqual(plist['KeepAlive'], {'SuccessfulExit':False})
            self.assertFalse(plist['AbandonProcessGroup'])
            self.assertEqual(plist['ThrottleInterval'], 20)
            self.assertIn(str(self.settings.resolve()), plist['ProgramArguments'])

    def test_invalid_window_without_timezone_is_rejected(self):
        self.window.write_text('{"start":"2026-10-25T17:00:00","end":"2026-10-26T08:00:00"}')
        with self.assertRaises(ValueError):
            load_settings(self.settings)

    def test_sigterm_cleans_child_and_requests_restart_before_end(self):
        self.config['services']['publisher']['command'][-1] = 'import time; time.sleep(60)'
        self.save()
        runner = Path(__file__).resolve().parents[1] / 'scripts/service_runner.py'
        child = subprocess.Popen([sys.executable,str(runner),'publisher','--settings',str(self.settings)],
                                 stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        try:
            deadline = time.monotonic()+5
            while not (self.root/'publisher-status.json').exists() and time.monotonic()<deadline:
                time.sleep(.01)
            worker_pid = self.status()['child_pid']
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=5), 1)
            self.assertEqual(self.status()['phase'], 'interrupted')
            with self.assertRaises(ProcessLookupError):
                os.kill(worker_pid, 0)
        finally:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGKILL)
                child.wait()


if __name__ == '__main__':
    unittest.main()
