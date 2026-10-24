#!/usr/bin/env python3
"""Inicia uma única vigia local; não mantém o Mac acordado antes da janela."""
import argparse
import datetime as dt
import fcntl
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent


def interpreter():
    candidates = [ROOT / ".venv" / "bin" / "python", Path(sys.executable),
        Path.home() / "Documents/DCP/Papers/electoralFraud/.venv_tse_bu/bin/python"]
    for candidate in candidates:
        if candidate.exists() and subprocess.run([str(candidate), "-c", "import asn1tools"], capture_output=True).returncode == 0:
            return str(candidate)
    raise RuntimeError("Instale requirements.txt na .venv local; nenhum Python com asn1tools foi encontrado")


def locked(path):
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True


def stop_worker(state):
    if not locked(state / "collector.lock"):
        return
    receipt = json.loads((state / "launch.json").read_text())
    pid = int(receipt["pid"])
    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
        capture_output=True, text=True, check=True).stdout
    if str(ROOT / "coletor.py") not in command or "watch" not in command or pid == os.getpid():
        raise RuntimeError("Identidade da vigia não conferiu; nenhum processo foi encerrado")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while locked(state / "collector.lock") and time.monotonic() < deadline:
        time.sleep(.1)
    if locked(state / "collector.lock"):
        raise RuntimeError("Vigia não encerrou após SIGTERM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "status", "check", "stop", "restart"])
    args = parser.parse_args()
    cfg = json.loads((ROOT / "config.json").read_text())
    state = ROOT / "data" / "live"
    state.mkdir(parents=True, exist_ok=True)
    running = locked(state / "collector.lock")
    launch = json.loads((state / "launch.json").read_text()) if (state / "launch.json").exists() else {}
    mode = ("legacy_with_analysis" if "--update" in launch.get("command", []) else
            "observed_data_only" if launch.get("command") or not running else "unknown")
    status = {"utc": dt.datetime.now(dt.timezone.utc).isoformat(), "running": running,
        "start": cfg["start"], "end": cfg["end"], "mode": mode}
    if args.action == "status":
        print(json.dumps(status)); return
    py = interpreter()
    command = [py, str(ROOT / "coletor.py"), "watch"]
    if args.action == "check":
        print(json.dumps({**status, "command": command})); return
    with (state / "start.lock").open("a") as start_lock:
        fcntl.flock(start_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action in ("stop", "restart"):
            stop_worker(state)
            if args.action == "stop":
                print(json.dumps({**status, "running": False})); return
        if locked(state / "collector.lock"):
            if mode != "observed_data_only":
                raise RuntimeError("Vigia antiga ativa; use restart para iniciar coleta sem análises")
            print(json.dumps(status)); return
        if dt.datetime.now(dt.timezone.utc) >= dt.datetime.fromisoformat(cfg["end"]):
            raise RuntimeError("A janela eleitoral já terminou")
        with (state / "watch.log").open("ab", buffering=0) as log:
            child = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        time.sleep(1)
        if child.poll() is not None:
            raise RuntimeError("Vigia encerrou ao iniciar; consulte data/live/watch.log")
        receipt = {**status, "pid": child.pid, "running": locked(state / "collector.lock"),
            "command": command, "mode": "observed_data_only"}
        (state / "launch.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        print(json.dumps(receipt))


if __name__ == "__main__":
    main()
