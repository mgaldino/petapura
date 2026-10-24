"""Exercita o servidor e o worker reais até 100%, somente por leituras HTTP."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from contract import validate, read_json, atomic_write


def checkpoint_hashes(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in folder.glob("runs/*/model/pacotes/*/checkpoint.rds")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, default=ROOT / "local/validacao-automatica")
    parser.add_argument("--legacy-runtime", type=Path)
    args = parser.parse_args()
    args.runtime = args.runtime.resolve()
    assert not args.runtime.exists(), "Use uma pasta de teste nova"
    if args.legacy_runtime:
        shutil.copytree(args.legacy_runtime, args.runtime)
    else:
        args.runtime.mkdir(parents=True)
    previous = read_json(args.runtime / "current.json") if args.legacy_runtime else None
    before = checkpoint_hashes(args.runtime)
    log = args.runtime / "automatic-test.log"
    started = time.monotonic()
    with log.open("w") as stream:
        child = subprocess.Popen([sys.executable, str(ROOT / "scripts/run_local.py"),
            "--model-dir", str(args.model_dir), "--runtime", str(args.runtime), "--port", "0",
            "--interval", "1"], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
    stages = {}
    try:
        url = None
        while time.monotonic() - started < 180:
            assert child.poll() is None, log.read_text()[-3000:]
            if url is None:
                found = re.search(r"Local: (http://127\.0\.0\.1:\d+)/", log.read_text())
                if not found:
                    time.sleep(.1)
                    continue
                url = found[1]
            with urlopen(url + "/api/status", timeout=10) as response:
                status = json.load(response)
            assert not status["error"], status["error"]
            with urlopen(url + "/data/latest.json", timeout=10) as response:
                snapshot = validate(json.load(response))
            assert snapshot["mode"] == "demo" and snapshot["forecast"]["interval"]["level"] == .95
            reported = snapshot["counting"]["reported_sections"]
            stages[reported] = {"reported_sections":reported, "share_a":snapshot["forecast"]["share_a"],
                "snapshot_id":snapshot["snapshot_id"]}
            if status["complete"] and not status["busy"]:
                break
            time.sleep(.15)
        else:
            raise AssertionError("A simulação automática não terminou em 180 segundos")
        assert status["running"] is False
        assert len(stages) == status["stages"], (len(stages), status)
        html = (ROOT / "web/index.html").read_text()
        assert not any(f'id="simulation-{name}"' in html for name in ("play", "next", "restart", "speed"))
        pointer = read_json(args.runtime / "current.json")
        if previous:
            assert pointer["run"] != previous["run"], "Reutilizou o checkpoint incompatível"
        assert all(checkpoint_hashes(args.runtime).get(k) == v for k, v in before.items())
        run = args.runtime / "runs" / pointer["run"]
        with (run / "fixture/truth.csv").open() as stream:
            truth = list(csv.DictReader(stream))
        a = sum(int(row["votos_a"]) for row in truth)
        b = sum(int(row["votos_b"]) for row in truth)
        assert snapshot["counting"]["votes_a"] == a and snapshot["counting"]["votes_b"] == b
        assert abs(snapshot["forecast"]["share_a"] - 100*a/(a+b)) < 1e-9
        report = dict(kind="automatic_http_end_to_end", passed=True, stages=len(stages),
            automatic_without_posts=True, legacy_checkpoint_migrated=bool(previous),
            previous_checkpoints_preserved=True, no_calculation_errors=True,
            seconds=round(time.monotonic()-started,3), observations=list(stages.values()),
            frozen_source=read_json(run / "model-source/source-manifest.json"),
            final_votes_a=a, final_votes_b=b, final_share_a=100*a/(a+b))
        atomic_write(args.runtime / "verification.json", report)
        print(json.dumps({k:v for k,v in report.items() if k not in ("observations", "frozen_source")}, ensure_ascii=False))
    finally:
        child.send_signal(signal.SIGINT)
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


if __name__ == "__main__":
    main()
