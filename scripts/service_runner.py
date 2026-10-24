"""Supervisão de um componente do Pet Apura, executada pelo launchd."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

from contract import atomic_write, require


def utc_now():
    return datetime.now(timezone.utc)


def load_settings(path):
    config = json.loads(Path(path).read_text())
    require(Path(config['supervisor_python']).is_absolute() and
            os.access(config['supervisor_python'], os.X_OK), 'Python do supervisor inexistente')
    require(isinstance(config['environment'], dict) and
            all(isinstance(k, str) and isinstance(v, str) for k, v in config['environment'].items()),
            'variáveis de ambiente devem ser pares de texto')
    require(set(config['services']) == {'collector', 'publisher'}, 'configure coletor e publicador')
    for service in config['services'].values():
        command = service['command']
        require(isinstance(command, list) and command and
                all(isinstance(v, str) and v for v in command), 'comando deve ser uma lista de argumentos')
        require(Path(command[0]).is_absolute() and os.access(command[0], os.X_OK), 'interpretador inexistente')
        require(Path(service['cwd']).is_dir(), 'diretório de trabalho inexistente')
    window = json.loads(Path(config['collector_config']).read_text())
    start, end = (datetime.fromisoformat(window[key]) for key in ('start', 'end'))
    require(start.tzinfo is not None and end.tzinfo is not None and end > start,
            'janela de coleta deve ter fuso horário e fim posterior ao início')
    return config, start, end


def stop_child(child):
    if child.poll() is not None:
        return
    # SIGINT passa pelos finally existentes e preserva o último checkpoint completo.
    child.send_signal(signal.SIGINT)
    try:
        child.wait(timeout=20)
    except subprocess.TimeoutExpired:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def supervise(settings_path, name, stop_event=None, now=utc_now, poll_seconds=1):
    settings_path = Path(settings_path).resolve()
    config, start, end = load_settings(settings_path)
    require(name in config['services'], 'serviço desconhecido')
    service = config['services'][name]
    stop_event = stop_event or threading.Event()
    state_path = settings_path.parent / f'{name}-status.json'
    child = None

    def record(phase, **extra):
        value = dict(service=name, phase=phase, observed_at_utc=now().isoformat(),
                     supervisor_pid=os.getpid(), child_pid=child.pid if child else None,
                     window_start=start.isoformat(), window_end=end.isoformat(), **extra)
        atomic_write(state_path, value)
        return value

    with (settings_path.parent / f'.{name}.supervisor.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if now() >= end:
            record('window_finished')
            return 0
        try:
            child = subprocess.Popen(service['command'], cwd=service['cwd'], stdin=subprocess.DEVNULL)
            if service.get('launch_receipt'):
                atomic_write(Path(service['launch_receipt']), dict(
                    utc=now().isoformat(), running=True, pid=child.pid,
                    command=service['command'], start=start.isoformat(), end=end.isoformat(),
                    mode='observed_data_only' if name == 'collector' else 'two_real_scenarios',
                    managed_by='launchd', supervisor_pid=os.getpid()))
            print(json.dumps(record('running'), ensure_ascii=False), flush=True)
            last_status = time.monotonic()
            while child.poll() is None:
                if stop_event.is_set() or now() >= end:
                    stop_child(child)
                    break
                if time.monotonic() - last_status >= 15:
                    record('waiting_window' if name == 'collector' and now() < start else 'running')
                    last_status = time.monotonic()
                stop_event.wait(poll_seconds)
            # Uma saída zero inesperada também precisa provocar a retomada pelo launchd.
            finished = now() >= end
            phase = 'window_finished' if finished else 'interrupted' if stop_event.is_set() else 'restart_required'
            print(json.dumps(record(phase, child_exit_code=child.returncode), ensure_ascii=False), flush=True)
            return 0 if finished else 1
        finally:
            if child is not None:
                stop_child(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('service', choices=['collector', 'publisher'])
    parser.add_argument('--settings', type=Path, required=True)
    args = parser.parse_args()
    stopping = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stopping.set())
    try:
        return supervise(args.settings, args.service, stopping)
    except Exception as error:
        print(f'Supervisão não concluída: {error}', flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
