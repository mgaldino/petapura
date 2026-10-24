"""Gerencia LaunchAgents por usuário e LaunchDaemons de sistema do Pet Apura."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import pwd
import grp
import re
import shutil
import subprocess
import tempfile
import time

from service_runner import load_settings

ROOT = Path(__file__).resolve().parents[1]
LABELS = {'collector':'br.usp.petapura.collector', 'publisher':'br.usp.petapura.publisher'}


def account_name(config, user=None):
    name = user or config.get('service_user') or os.environ.get('SUDO_USER') or pwd.getpwuid(os.getuid()).pw_name
    account = pwd.getpwnam(name)
    if account.pw_uid == 0:
        raise ValueError('Os componentes devem executar como usuário comum, não como root')
    return account


def domain(scope='user', user=None):
    if scope == 'system':
        return 'system'
    uid = pwd.getpwnam(user).pw_uid if user else os.getuid()
    return f'gui/{uid}'


def make_plist(name, settings_path, config, scope='user', user=None):
    folder = Path(settings_path).resolve().parent
    environment = dict(config['environment'])
    value = {
        'Label': LABELS[name],
        'ProgramArguments': [config['supervisor_python'], '-u', str(ROOT / 'scripts/service_runner.py'),
                             name, '--settings', str(Path(settings_path).resolve())],
        'WorkingDirectory': str(ROOT),
        'EnvironmentVariables': environment,
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit':False},
        'ThrottleInterval': 20,
        'ExitTimeOut': 30,
        'AbandonProcessGroup': False,
        'StandardOutPath': str(folder / f'{name}.out.log'),
        'StandardErrorPath': str(folder / f'{name}.err.log'),
    }
    if scope == 'system':
        account = account_name(config, user)
        value.update(UserName=account.pw_name, GroupName=grp.getgrgid(account.pw_gid).gr_name)
        # O daemon usa o diretório residencial real da conta e sua autenticação existente.
        environment.update(HOME=account.pw_dir, USER=account.pw_name, LOGNAME=account.pw_name)
    return value


def service_status(name, scope='user', user=None):
    target = f'{domain(scope,user)}/{LABELS[name]}'
    result = subprocess.run(['/bin/launchctl', 'print', target], capture_output=True, text=True)
    status = {'label':LABELS[name], 'scope':scope, 'loaded':result.returncode == 0}
    for key, pattern in [('pid', r'\n\s*pid = (\d+)'), ('runs', r'\n\s*runs = (\d+)'),
                         ('state', r'\n\s*state = ([^\n]+)'), ('last_exit_code', r'\n\s*last exit code = (\d+)')]:
        match = re.search(pattern, result.stdout)
        if match:
            status[key] = int(match[1]) if key != 'state' else match[1].strip()
    return status


def prepare(settings_path, scope='user', user=None):
    config, _, _ = load_settings(settings_path)
    generated = Path(settings_path).resolve().parent / ('launchdaemons' if scope == 'system' else 'launchagents')
    generated.mkdir(exist_ok=True)
    paths = {}
    for name in LABELS:
        path = generated / f'{LABELS[name]}.plist'
        path.write_bytes(plistlib.dumps(make_plist(name, settings_path, config, scope, user)))
        subprocess.run(['/usr/bin/plutil', '-lint', str(path)], check=True)
        paths[name] = path
    return paths


def install(settings_path, scope='user', user=None):
    if scope == 'system' and os.geteuid() != 0:
        raise PermissionError('Instalar LaunchDaemons requer sudo. Os serviços atuais foram preservados.')
    generated = prepare(settings_path, scope, user)
    if scope == 'system':
        return install_system(settings_path, generated, user)
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


def owned_write(path, raw, uid, gid, mode):
    """Troca atômica, com dono e permissões definidos antes da publicação do arquivo."""
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.'+path.name+'-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
        os.chown(temporary, uid, gid)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def wait_system_children(settings_path, user, timeout=45):
    folder = Path(settings_path).resolve().parent
    _, _, end = load_settings(settings_path)
    if datetime.now(timezone.utc) >= end:
        return  # A janela encerrada deve manter os serviços instalados e sem processos.
    uid = pwd.getpwnam(user).pw_uid
    deadline = time.monotonic()+timeout
    stable_since = None
    while time.monotonic() < deadline:
        healthy = True
        for name in LABELS:
            launch = service_status(name, 'system')
            try:
                state = json.loads((folder/f'{name}-status.json').read_text())
                details = subprocess.check_output(['ps','-p',str(state['child_pid']),'-o','uid=,ppid='],text=True).split()
                healthy &= (state['supervisor_pid'] == launch.get('pid') and
                            details == [str(uid),str(launch.get('pid'))] and
                            state['phase'] in ['running','waiting_window'])
            except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                healthy = False
        if healthy:
            stable_since = stable_since or time.monotonic()
            if time.monotonic()-stable_since >= 5:
                return
        else:
            stable_since = None
        time.sleep(.5)
    raise RuntimeError('LaunchDaemons não ficaram saudáveis. Restaurar os serviços anteriores.')


def install_system(settings_path, generated, user=None, system_folder=Path('/Library/LaunchDaemons')):
    config_raw = Path(settings_path).read_bytes()
    config = json.loads(config_raw)
    account = account_name(config, user)
    system_folder = Path(system_folder)
    agent_folder = Path(account.pw_dir)/'Library/LaunchAgents'
    backup = Path(settings_path).resolve().parent/'backups'/datetime.now(timezone.utc).strftime('system-%Y%m%dT%H%M%S%fZ')
    backup.mkdir(parents=True)
    snapshots = {}
    for name in LABELS:
        agent = agent_folder/f'{LABELS[name]}.plist'
        daemon = system_folder/agent.name
        for path in [agent,daemon]:
            if path.is_symlink():
                raise ValueError(f'Não sobrescrever link simbólico: {path}')
            if path.exists() and str(ROOT/'scripts/service_runner.py') not in plistlib.loads(path.read_bytes()).get('ProgramArguments',[]):
                raise ValueError(f'Serviço existente não pertence a este projeto: {path}')
        snapshots[name] = dict(agent=agent, daemon=daemon,
            agent_raw=agent.read_bytes() if agent.exists() else None,
            daemon_raw=daemon.read_bytes() if daemon.exists() else None,
            agent_loaded=service_status(name,'user',account.pw_name)['loaded'],
            daemon_loaded=service_status(name,'system')['loaded'])
        if snapshots[name]['agent_loaded'] and snapshots[name]['agent_raw'] is None:
            raise ValueError('LaunchAgent carregado sem arquivo reconhecido. Nenhum serviço foi alterado.')
        if snapshots[name]['daemon_loaded'] and snapshots[name]['daemon_raw'] is None:
            raise ValueError('LaunchDaemon carregado sem arquivo reconhecido. Nenhum serviço foi alterado.')
        for kind in ['agent','daemon']:
            if snapshots[name][kind+'_raw'] is not None:
                (backup/f'{kind}-{agent.name}').write_bytes(snapshots[name][kind+'_raw'])
    try:
        for name, saved in snapshots.items():
            for scope, loaded in [('user',saved['agent_loaded']),('system',saved['daemon_loaded'])]:
                if loaded:
                    subprocess.run(['/bin/launchctl','bootout',f'{domain(scope,account.pw_name)}/{LABELS[name]}'],check=True)
            if saved['agent'].exists():
                saved['agent'].unlink()
            owned_write(saved['daemon'],generated[name].read_bytes(),0,0,0o644)
        for name, saved in snapshots.items():
            subprocess.run(['/bin/launchctl','enable',f'system/{LABELS[name]}'],check=True)
            subprocess.run(['/bin/launchctl','bootstrap','system',str(saved['daemon'])],check=True)
        wait_system_children(settings_path,account.pw_name)
        config.update(service_scope='system',service_user=account.pw_name)
        owned_write(settings_path,(json.dumps(config,ensure_ascii=False,indent=2)+'\n').encode(),account.pw_uid,account.pw_gid,0o600)
    except Exception:
        for name, saved in snapshots.items():
            if service_status(name,'system')['loaded']:
                subprocess.run(['/bin/launchctl','bootout',f'system/{LABELS[name]}'],check=False)
            if saved['daemon_raw'] is None:
                saved['daemon'].unlink(missing_ok=True)
            else:
                owned_write(saved['daemon'],saved['daemon_raw'],0,0,0o644)
                if saved['daemon_loaded'] and not service_status(name,'system')['loaded']:
                    subprocess.run(['/bin/launchctl','bootstrap','system',str(saved['daemon'])],check=True)
            if saved['agent_raw'] is not None:
                owned_write(saved['agent'],saved['agent_raw'],account.pw_uid,account.pw_gid,0o644)
                if saved['agent_loaded'] and not service_status(name,'user',account.pw_name)['loaded']:
                    subprocess.run(['/bin/launchctl','bootstrap',domain('user',account.pw_name),str(saved['agent'])],check=True)
        owned_write(settings_path,config_raw,account.pw_uid,account.pw_gid,0o600)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'install', 'status', 'stop'])
    parser.add_argument('--settings', type=Path, default=ROOT / 'local/services/settings.json')
    parser.add_argument('--scope',choices=['user','system'])
    parser.add_argument('--user',help='Conta comum que executará os serviços de sistema')
    args = parser.parse_args()
    config = json.loads(args.settings.read_text())
    scope = args.scope or config.get('service_scope','user')
    user = args.user or config.get('service_user')
    if args.action == 'prepare':
        prepare(args.settings,scope,user)
    elif args.action == 'install':
        install(args.settings,scope,user)
    elif args.action == 'stop':
        if scope == 'system' and os.geteuid() != 0:
            raise PermissionError('Parar serviços do sistema requer sudo')
        # Retira do domínio atual. Os plists preservam o início no login ou na partida.
        for name in LABELS:
            if service_status(name,scope,user)['loaded']:
                subprocess.run(['/bin/launchctl','bootout',f'{domain(scope,user)}/{LABELS[name]}'],check=True)
    print(json.dumps({name:service_status(name,scope,user) for name in LABELS}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
