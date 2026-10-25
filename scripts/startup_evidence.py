"""Registra a partida dos serviços e confere um teste real de reinicialização."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess

from contract import atomic_write

ROOT = Path(__file__).resolve().parents[1]


def command_output(command, input_text=None):
    try:
        result = subprocess.run(command, input=input_text, capture_output=True,
                                text=True, timeout=3, check=False)
        return result.stdout.strip() if result.returncode == 0 else ''
    except (OSError, subprocess.SubprocessError):
        return ''


def host_context():
    """Diagnóstico tolerante a falhas, sem depender de rede ou de uma sessão gráfica."""
    boot_id = command_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'])
    boot_time = command_output(['/usr/sbin/sysctl', '-n', 'kern.boottime'])
    console = command_output(['/usr/sbin/scutil'], 'show State:/Users/ConsoleUser\n')
    seconds = re.search(r'\bsec\s*=\s*(\d+)', boot_time)
    console_name = re.search(r'^\s*Name\s*:\s*(\S+)', console, re.MULTILINE)
    console_uid = re.search(r'^\s*UID\s*:\s*(\d+)', console, re.MULTILINE)
    try:
        device_uid = os.stat('/dev/console').st_uid
    except OSError:
        device_uid = None
    return dict(observed_at_utc=datetime.now(timezone.utc).isoformat(),
                boot_session_uuid=boot_id if re.fullmatch(r'[A-Fa-f0-9-]{36}', boot_id) else None,
                boot_time_utc=datetime.fromtimestamp(int(seconds[1]), timezone.utc).isoformat() if seconds else None,
                console_user=console_name[1] if console_name else None,
                console_uid=int(console_uid[1]) if console_uid else None,
                console_device_uid=device_uid, process_euid=os.geteuid(), parent_pid=os.getppid())


def save_startup(folder, record):
    boot_id = record['startup']['boot_session_uuid'] or 'unknown-boot'
    path = Path(folder)/'startups'/boot_id/f"{record['service']}-{record['supervisor_pid']}.json"
    atomic_write(path, record)
    return path


def before_login(startup):
    # Exige confirmação positiva. Um campo ausente não é prova de ausência de login.
    return (startup.get('console_user') == 'loginwindow' and
            startup.get('console_uid') == 0 and startup.get('console_device_uid') == 0)


def verify(settings_path, baseline, current=None):
    from manage_services import LABELS, service_status
    current = current or host_context()
    config = json.loads(Path(settings_path).read_text())
    boot_id = current.get('boot_session_uuid')
    rebooted = bool(boot_id and baseline['host'].get('boot_session_uuid') and
                    boot_id != baseline['host']['boot_session_uuid'])
    report = dict(verified_at_utc=current['observed_at_utc'], physical_reboot_observed=rebooted,
                  startup_before_login_confirmed=False, services={})
    for name in LABELS:
        launch = service_status(name, 'system')
        records = Path(settings_path).parent/'startups'/(boot_id or 'unknown-boot')
        path = records/f"{name}-{launch.get('pid')}.json"
        saved = json.loads(path.read_text()) if path.exists() else {}
        state_path = Path(settings_path).parent/f'{name}-status.json'
        state = json.loads(state_path.read_text()) if state_path.exists() else {}
        startup = saved.get('startup', {})
        child_pid = saved.get('child_pid')
        process = command_output(['/bin/ps', '-p', str(child_pid), '-o', 'uid=,ppid=']).split() if child_pid else []
        fresh = False
        if state.get('observed_at_utc'):
            age = (datetime.fromisoformat(current['observed_at_utc'])-
                   datetime.fromisoformat(state['observed_at_utc'])).total_seconds()
            fresh = 0 <= age < 45
        continuous = bool(launch.get('loaded') and launch.get('state') == 'running' and
                          saved.get('supervisor_pid') == launch.get('pid') == state.get('supervisor_pid') and
                          child_pid == state.get('child_pid') and fresh and
                          process == [str(startup.get('process_euid')), str(launch.get('pid'))] and
                          state.get('phase') in ['running', 'waiting_window'])
        chronological = False
        if startup.get('observed_at_utc') and startup.get('boot_time_utc'):
            chronological = (datetime.fromisoformat(startup['boot_time_utc']) <=
                             datetime.fromisoformat(startup['observed_at_utc']) <=
                             datetime.fromisoformat(current['observed_at_utc']))
        confirmed = bool(rebooted and config.get('service_scope') == 'system' and
                         startup.get('boot_session_uuid') == boot_id and chronological and
                         startup.get('parent_pid') == 1 and startup.get('process_euid', 0) != 0 and
                         before_login(startup) and continuous)
        report['services'][name] = dict(system_job=launch, startup_record_found=bool(saved),
            started_at_utc=startup.get('observed_at_utc'),
            console_was_loginwindow=before_login(startup),
            same_processes_still_running=continuous, before_login_confirmed=confirmed)
    report['startup_before_login_confirmed'] = all(
        item['before_login_confirmed'] for item in report['services'].values())
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify'])
    parser.add_argument('--settings', type=Path, default=ROOT/'local/services/settings.json')
    args = parser.parse_args()
    baseline_path = args.settings.parent/'boot-test-baseline.json'
    if args.action == 'prepare':
        context = host_context()
        if not context['boot_session_uuid']:
            raise ValueError('Não foi possível registrar a identificação desta partida do macOS')
        atomic_write(baseline_path, dict(host=context, state='awaiting_physical_reboot'))
        print('Referência salva. Reinicie, aguarde 3 minutos na tela de login e entre na conta.')
        return 0
    report = verify(args.settings, json.loads(baseline_path.read_text()))
    atomic_write(args.settings.parent/'boot-test-result.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['startup_before_login_confirmed'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
