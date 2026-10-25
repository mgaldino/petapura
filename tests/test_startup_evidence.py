"""A prova de início antes do login exige uma nova partida e processos contínuos."""
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from startup_evidence import host_context, save_startup, verify
from service_runner import supervise


class StartupEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.settings = self.root/'settings.json'
        self.settings.write_text(json.dumps({'service_scope':'system'}))
        self.baseline = {'host':{'boot_session_uuid':'old-boot'}}
        self.context = dict(boot_session_uuid='new-boot',boot_time_utc='2026-10-24T17:00:00+00:00',
            observed_at_utc='2026-10-24T17:00:30+00:00',console_user='loginwindow',
            console_uid=0,console_device_uid=0,process_euid=501,parent_pid=1)
        self.current = dict(self.context,observed_at_utc='2026-10-24T17:04:00+00:00',console_user='operator',console_uid=501)
        self.jobs = {}
        for index,name in enumerate(['collector','publisher']):
            pid = 100+index
            self.jobs[name] = dict(loaded=True,state='running',pid=pid)
            record = dict(service=name,supervisor_pid=pid,child_pid=200+index,startup=dict(self.context),
                          observed_at_utc=self.current['observed_at_utc'],phase='running')
            save_startup(self.root,record)
            (self.root/f'{name}-status.json').write_text(json.dumps(record))

    def check(self):
        def process(command, *args):
            pid = int(command[2])
            return f'501 {pid-100}'
        with patch('manage_services.service_status',side_effect=lambda name,scope:self.jobs[name]), \
             patch('startup_evidence.command_output',side_effect=process):
            return verify(self.settings,self.baseline,self.current)

    def change_record(self, service='publisher', **changes):
        path = self.root/'startups/new-boot'/f"{service}-{self.jobs[service]['pid']}.json"
        record = json.loads(path.read_text())
        record['startup'].update(changes)
        path.write_text(json.dumps(record))

    def test_new_boot_with_loginwindow_and_surviving_children_is_confirmed(self):
        self.assertTrue(self.check()['startup_before_login_confirmed'])

    def test_same_boot_cannot_be_reported_as_physical_reboot(self):
        self.baseline['host']['boot_session_uuid'] = 'new-boot'
        self.assertFalse(self.check()['startup_before_login_confirmed'])

    def test_logged_in_or_unknown_console_cannot_prove_before_login(self):
        for name,uid in [('operator',501),(None,None),('loginwindow',None)]:
            with self.subTest(name=name,uid=uid):
                self.change_record(console_user=name,console_uid=uid)
                self.assertFalse(self.check()['startup_before_login_confirmed'])

    def test_new_generation_and_stale_heartbeat_do_not_pass(self):
        self.jobs['publisher']['pid'] = 333
        self.assertFalse(self.check()['startup_before_login_confirmed'])
        self.jobs['publisher']['pid'] = 101
        path = self.root/'publisher-status.json'
        state = json.loads(path.read_text())
        state['observed_at_utc'] = '2026-10-24T17:00:00+00:00'
        path.write_text(json.dumps(state))
        self.assertFalse(self.check()['startup_before_login_confirmed'])

    def test_diagnostic_unavailability_is_recorded_without_raising(self):
        with patch('startup_evidence.command_output',return_value=''), \
             patch('startup_evidence.os.stat',side_effect=OSError('unavailable')):
            result = host_context()
        self.assertIsNone(result['boot_session_uuid'])
        self.assertIsNone(result['console_uid'])

    def test_supervisor_preserves_startup_record_after_child_finishes(self):
        window = self.root/'window.json'
        window.write_text('{"start":"2026-10-24T00:00:00-03:00","end":"2026-10-26T08:00:00-03:00"}')
        config = dict(collector_config=str(window),supervisor_python=sys.executable,environment={},
                      services={name:dict(command=[sys.executable,'-c','pass'],cwd=str(self.root))
                                for name in ['collector','publisher']})
        self.settings.write_text(json.dumps(config))
        with patch('service_runner.host_context',return_value=self.context):
            supervise(self.settings,'publisher',poll_seconds=.01,
                      now=lambda:datetime(2026,10,24,17,4,tzinfo=timezone.utc))
        state = json.loads((self.root/'publisher-status.json').read_text())
        record = json.loads((self.root/'startups/new-boot'/f"publisher-{state['supervisor_pid']}.json").read_text())
        self.assertEqual(state['phase'],'restart_required')
        self.assertEqual(record['phase'],'running')
        self.assertEqual(record['startup'],self.context)
        self.assertEqual(record['child_pid'],state['child_pid'])


if __name__ == '__main__':
    unittest.main()
