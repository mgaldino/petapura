"""Prepara, instala e consulta os dois LaunchAgents do Pet Apura no macOS."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from service_runner import load_settings

ROOT = Path(__file__).resolve().parents[1]
LABELS = {'collector':'br.usp.petapura.collector', 'publisher':'br.usp.petapura.publisher'}


def make_plist(name, settings_path, config):
    folder = Path(settings_path).resolve().parent
    return {
        'Label': LABELS[name],
        'ProgramArguments': [config['supervisor_python'], '-u', str(ROOT / 'scripts/service_runner.py'),
                             name, '--settings', str(Path(settings_path).resolve())],
        'WorkingDirectory': str(ROOT),
        'EnvironmentVariables': config['environment'],
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit':False},
        'ThrottleInterval': 20,
        'ExitTimeOut': 30,
        'AbandonProcessGroup': False,
        'StandardOutPath': str(folder / f'{name}.out.log'),
        'StandardErrorPath': str(folder / f'{name}.err.log'),
    }


def service_status(name):
    target = f'gui/{os.getuid()}/{LABELS[name]}'
    result = subprocess.run(['/bin/launchctl', 'print', target], capture_output=True, text=True)
    status = {'label':LABELS[name], 'loaded':result.returncode == 0}
    for key, pattern in [('pid', r'\n\s*pid = (\d+)'), ('runs', r'\n\s*runs = (\d+)'),
                         ('state', r'\n\s*state = ([^\n]+)'), ('last_exit_code', r'\n\s*last exit code = (\d+)')]:
        match = re.search(pattern, result.stdout)
        if match:
            status[key] = int(match[1]) if key != 'state' else match[1].strip()
    return status


def prepare(settings_path):
    config, _, _ = load_settings(settings_path)
    generated = Path(settings_path).resolve().parent / 'launchagents'
    generated.mkdir(exist_ok=True)
    paths = {}
    for name in LABELS:
        path = generated / f'{LABELS[name]}.plist'
        path.write_bytes(plistlib.dumps(make_plist(name, settings_path, config)))
        subprocess.run(['/usr/bin/plutil', '-lint', str(path)], check=True)
        paths[name] = path
    return paths


def install(settings_path):
    generated = prepare(settings_path)
    destination = Path.home() / 'Library/LaunchAgents'
    destination.mkdir(parents=True, exist_ok=True)
    for name, source in generated.items():
        path = destination / source.name
        if path.is_symlink():
            raise ValueError(f'Não sobrescrever link simbólico: {path}')
        if path.exists():
            saved = plistlib.loads(path.read_bytes())
            if str(ROOT / 'scripts/service_runner.py') not in saved.get('ProgramArguments', []):
                raise ValueError(f'LaunchAgent existente não pertence a este projeto: {path}')
            if path.read_bytes() != source.read_bytes():
                backup = Path(settings_path).resolve().parent / 'backups'
                backup.mkdir(exist_ok=True)
                stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
                shutil.copy2(path, backup / f'{stamp}-{path.name}')
        target = f'gui/{os.getuid()}/{LABELS[name]}'
        if service_status(name)['loaded']:
            subprocess.run(['/bin/launchctl', 'bootout', target], check=True)
        shutil.copy2(source, path)
        path.chmod(0o644)
        subprocess.run(['/bin/launchctl', 'enable', target], check=True)
        subprocess.run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(path)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'install', 'status', 'stop'])
    parser.add_argument('--settings', type=Path, default=ROOT / 'local/services/settings.json')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.settings)
    elif args.action == 'install':
        install(args.settings)
    elif args.action == 'stop':
        # Retira da sessão atual. Os arquivos mantêm o início no próximo login.
        for name in LABELS:
            if service_status(name)['loaded']:
                subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{LABELS[name]}'], check=True)
    print(json.dumps({name:service_status(name) for name in LABELS}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
