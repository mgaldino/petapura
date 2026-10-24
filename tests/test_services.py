"""Política de retomada, encerramento da janela e limpeza dos processos supervisionados."""
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import pwd
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from service_runner import load_settings, supervise
from manage_services import make_plist, install, install_system, LABELS


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

    def test_system_plist_runs_as_common_user_with_real_home(self):
        account = pwd.getpwuid(os.getuid())
        plist = make_plist('publisher',self.settings,self.config,'system',account.pw_name)
        self.assertEqual(plist['UserName'],account.pw_name)
        self.assertEqual(plist['EnvironmentVariables']['HOME'],account.pw_dir)
        self.assertEqual(plist['EnvironmentVariables']['USER'],account.pw_name)
        self.assertNotIn('UserName',make_plist('publisher',self.settings,self.config))
        self.assertNotIn('HOME',self.config['environment'])

    def test_system_plist_rejects_root_as_component_user(self):
        with self.assertRaisesRegex(ValueError,'usuário comum'):
            make_plist('collector',self.settings,self.config,'system','root')

    def test_system_install_without_admin_does_not_prepare_or_stop_services(self):
        with patch('manage_services.os.geteuid',return_value=501), patch('manage_services.prepare') as prepare:
            with self.assertRaises(PermissionError):
                install(self.settings,'system')
        prepare.assert_not_called()

    def system_migration(self, fail_publisher=False):
        home = self.root/'home'
        agents = home/'Library/LaunchAgents'
        agents.mkdir(parents=True)
        daemons = self.root/'LaunchDaemons'
        daemons.mkdir()
        generated = self.root/'generated'
        generated.mkdir()
        account = SimpleNamespace(pw_name='operator',pw_dir=str(home),pw_uid=501,pw_gid=20)
        loaded = {(scope,name):scope == 'user' for scope in ['user','system'] for name in LABELS}
        paths = {}
        originals = {}
        owner_calls = []
        for name in LABELS:
            raw = plistlib.dumps(make_plist(name,self.settings,self.config))
            path = agents/f'{LABELS[name]}.plist'
            path.write_bytes(raw)
            originals[name] = raw
            paths[name] = generated/path.name
            paths[name].write_bytes(raw)
        def status(name,scope='user',user=None):
            return {'loaded':loaded[scope,name]}
        def launchctl(args,**kwargs):
            action,target = args[1],args[2]
            scope = 'system' if target.startswith('system') else 'user'
            if action == 'enable':return
            name = next(n for n,label in LABELS.items() if label in (target if action=='bootout' else args[3]))
            if action == 'bootstrap' and scope == 'system' and name == 'publisher' and fail_publisher:
                raise subprocess.CalledProcessError(5,args)
            loaded[scope,name] = action == 'bootstrap'
        def write(path,raw,uid,gid,mode):
            Path(path).write_bytes(raw)
            owner_calls.append((Path(path),uid,gid,mode))
        context = (patch('manage_services.account_name',return_value=account),
                   patch('manage_services.domain',side_effect=lambda scope='user',user=None:'system' if scope=='system' else 'gui/501'),
                   patch('manage_services.service_status',side_effect=status),
                   patch('manage_services.subprocess.run',side_effect=launchctl),
                   patch('manage_services.owned_write',side_effect=write),
                   patch('manage_services.wait_system_children'))
        from contextlib import ExitStack
        before = self.settings.read_bytes()
        with ExitStack() as stack:
            for mock in context:stack.enter_context(mock)
            if fail_publisher:
                with self.assertRaises(subprocess.CalledProcessError):
                    install_system(self.settings,paths,'operator',daemons)
            else:
                install_system(self.settings,paths,'operator',daemons)
        return dict(agents=agents,daemons=daemons,loaded=loaded,originals=originals,
                    owner_calls=owner_calls,config_before=before)

    def test_system_migration_removes_agents_and_installs_root_owned_daemons(self):
        result = self.system_migration()
        for name,label in LABELS.items():
            self.assertFalse((result['agents']/f'{label}.plist').exists())
            self.assertTrue(result['loaded']['system',name])
            self.assertFalse(result['loaded']['user',name])
            self.assertIn((result['daemons']/f'{label}.plist',0,0,0o644),result['owner_calls'])
        config = json.loads(self.settings.read_text())
        self.assertEqual(config['service_scope'],'system')
        self.assertEqual(config['service_user'],'operator')

    def test_failed_system_migration_restores_both_agents_and_previous_settings(self):
        result = self.system_migration(fail_publisher=True)
        for name,label in LABELS.items():
            self.assertEqual((result['agents']/f'{label}.plist').read_bytes(),result['originals'][name])
            self.assertTrue(result['loaded']['user',name])
            self.assertFalse(result['loaded']['system',name])
            self.assertFalse((result['daemons']/f'{label}.plist').exists())
        self.assertEqual(self.settings.read_bytes(),result['config_before'])

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
