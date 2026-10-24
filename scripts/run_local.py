"""TSE -> executor R -> JSON público -> site local. Padrão: simulação isolada."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
from functools import partial
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid

from contract import atomic_write, digest, publish, read_json, require
from serve import Handler as StaticHandler
from simulate_tse import publish_demo_stage
from model_runtime import freeze_model, verify_model

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = ROOT.parent.parent / "Cursos/Regressao/2026/lab-regressao-aula/projeto_agna/previsao_tempo_real"


@contextmanager
def runtime_lock(folder):
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / ".pipeline.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Esta pasta já está sendo usada por outro pipeline local") from exc
        yield


class Pipeline:
    def __init__(self, args):
        self.args = args
        self.base = args.runtime.resolve()
        self.model_dir = args.model_dir.resolve()
        require(self.model_dir.is_dir(), "pasta do modelo inexistente; use --model-dir")
        require(not self.base.is_relative_to(self.model_dir), "saída dentro do módulo do modelo")
        require(not self.model_dir.is_relative_to(self.base), "saída contém o módulo do modelo")
        require(not self.base.is_relative_to(ROOT / "web"), "saída dentro de web/")
        self.config = read_json(ROOT / "web/config.json")
        self.condition = threading.Condition()
        self.running = True
        self.busy = False
        self.pending = None
        self.error = None
        self.closed = False
        self.stage = 0
        self.stages = 1
        self.interval = args.interval or (8 if args.mode == "demo" else 60)
        self.next_at = time.monotonic() + self.interval
        self.latest = None
        self.child = None
        self.last_seconds = None
        self.thread = None
        self.runtime = None

    def r(self, command):
        verify_model(self.runtime / "model-source")
        env = {**os.environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
        with (self.runtime / "pipeline.log").open("ab") as log:
            log.write(f"\n[{datetime.now(timezone.utc).isoformat()}] {command}\n".encode())
            log.flush()
            self.child = subprocess.Popen([self.args.rscript, "--vanilla",
                str(ROOT / "integracao/executar_pipeline.R"), command,
                str(self.runtime / "settings.json")], cwd=ROOT, env=env,
                stdout=log, stderr=subprocess.STDOUT)
            result = self.child.wait()
            self.child = None
        if result:
            raise RuntimeError(f"O executor R falhou ({command}). Consulte {self.runtime / 'pipeline.log'}")

    def settings(self):
        return dict(mode=self.args.mode, model_dir=str(self.model_dir), runtime=str(self.runtime),
            model_source=str(self.runtime / "model-source"),
            source=str(self.runtime / "collector/tse_export") if self.args.mode == "demo" else str(self.args.source.resolve()),
            initial_state=str(self.runtime / "initial") if self.args.mode == "demo" else str(self.args.initial_state.resolve()),
            draws=self.args.draws, seed=self.args.seed, sections_per_uf=self.args.sections_per_uf,
            name_a=self.args.name_a, name_b=self.args.name_b)

    def remember(self):
        atomic_write(self.base / "current.json", dict(kind="pet_local_pipeline", mode=self.args.mode,
            run=self.runtime.name, stage=self.stage, settings=self.settings()))

    def new_run(self):
        previous = (self.runtime, self.stage, self.stages, self.latest, self.last_seconds)
        try:
            self._new_run()
        except Exception:
            # Um reinício que falha mantém a execução anterior disponível.
            with self.condition:
                self.runtime, self.stage, self.stages, self.latest, self.last_seconds = previous
            raise

    def _new_run(self):
        self.runtime = self.base / "runs" / uuid.uuid4().hex
        self.runtime.mkdir(parents=True)
        freeze_model(self.args.model_code or self.model_dir, self.runtime / "model-source")
        atomic_write(self.runtime / "settings.json", self.settings())
        self.stage = 0
        if self.args.mode == "demo":
            self.r("fixture")
            scenario = read_json(self.runtime / "fixture/scenario.json")
            self.stages = len(scenario["fractions"])
            publish_demo_stage(self.runtime / "model-source", self.runtime, 0)
            self.r("inicializar")
        self.update()
        self.remember()

    def prepare(self):
        pointer = self.base / "current.json"
        if not pointer.exists():
            self.new_run()
            return
        saved = read_json(pointer)
        require(saved.get("kind") == "pet_local_pipeline" and saved.get("mode") == self.args.mode, "pasta de execução pertence a outro modo")
        if not saved.get("settings", {}).get("model_source"):
            # Checkpoints antigos não têm os componentes das novas APIs.
            # Preserva o diretório anterior e começa uma execução compatível.
            print("Preparando execução compatível; os arquivos anteriores foram preservados.", flush=True)
            self.new_run()
            return
        run = saved["run"]
        require(isinstance(run, str) and len(run) == 32 and all(c in "0123456789abcdef" for c in run), "identidade da execução")
        self.runtime = self.base / "runs" / run
        require(saved["settings"] == self.settings(), "configuração mudou; use outro --runtime")
        self.stage = saved["stage"]
        if self.args.mode == "demo":
            self.stages = len(read_json(self.runtime / "fixture/scenario.json")["fractions"])
            require(0 <= self.stage < self.stages, "etapa salva inválida")
        # Se houve interrupção depois do checkpoint, republica a mesma saída.
        self.update()
        if self.args.mode == "demo":
            self.stage = self.exported_stage()
        self.remember()
        if self.args.mode == "demo" and self.stage == self.stages - 1:
            self.running = False

    def exported_stage(self):
        folder = self.runtime / "collector/tse_export"
        manifest = read_json(folder / "manifest.json")
        entry = manifest["files"]["status.json"]
        path = (folder / entry["path"]).resolve()
        require(path.is_relative_to(folder.resolve()), "caminho do status sintético")
        raw = path.read_bytes()
        require(digest(raw) == entry["sha256"], "hash do status sintético")
        status = json.loads(raw)
        require(status.get("kind") == "pet_synthetic_replay" and status.get("synthetic") is True, "status não é fictício")
        stage = status["stage"]
        require(type(stage) is int and 0 <= stage < self.stages, "etapa do export inválida")
        return stage

    def update(self):
        started = time.monotonic()
        self.r("atualizar")
        snapshot = read_json(self.runtime / "snapshot-site.json")
        require(snapshot["mode"] == ("demo" if self.args.mode == "demo" else "live"), "modo inesperado do executor")
        latest, _ = publish(snapshot, self.runtime / "public/latest.json", self.config)
        with self.condition:
            self.latest = latest
            self.last_seconds = round(time.monotonic() - started, 3)

    def status(self):
        with self.condition:
            return dict(mode=self.args.mode, running=self.running, busy=self.busy,
                stage=self.stage, stages=self.stages, interval=self.interval,
                error=self.error, seconds=self.last_seconds,
                snapshot_id=self.latest["snapshot_id"] if self.latest else None,
                complete=bool(self.latest and self.latest["counting"] and
                    self.latest["counting"]["reported_sections"] == self.latest["counting"]["total_sections"]),
                draws=self.args.draws)

    def control(self, action, interval=None):
        require(self.args.mode == "demo", "controles disponíveis somente na simulação")
        with self.condition:
            require(action in ("play", "pause", "next", "restart", "speed"), "ação desconhecida")
            if action == "speed":
                require(type(interval) is int and interval in (3, 8, 20), "velocidade inválida")
                self.interval = interval
                self.next_at = time.monotonic() + self.interval
            elif action == "pause":
                self.running = False
            elif action == "play":
                require(self.stage < self.stages - 1, "simulação concluída; use Reiniciar")
                self.running = True
                self.next_at = time.monotonic()
            else:
                require(not self.busy and self.pending is None, "aguarde o cálculo atual")
                require(action == "restart" or self.stage < self.stages - 1, "simulação concluída")
                self.running = False
                self.pending = action
            self.condition.notify_all()

    def work(self):
        while True:
            with self.condition:
                while not self.closed and self.pending is None and not (self.running and time.monotonic() >= self.next_at):
                    self.condition.wait(timeout=max(.1, self.next_at - time.monotonic()) if self.running else None)
                if self.closed:
                    return
                action = self.pending or "next"
                self.pending = None
                self.busy = True
                self.error = None
            try:
                if action == "restart":
                    self.new_run()
                else:
                    if self.args.mode == "demo":
                        new_stage = self.stage + 1
                        # Se o cálculo/publicação anterior falhou, retoma o export já
                        # existente, preservando seu ID em vez de fabricar outro.
                        exported = self.exported_stage()
                        require(exported in (self.stage, new_stage), "export fora da sequência")
                        if exported != new_stage:
                            publish_demo_stage(self.runtime / "model-source", self.runtime, new_stage)
                    self.update()
                    if self.args.mode == "demo":
                        self.stage = new_stage
                    self.remember()
            except Exception as exc:
                with self.condition:
                    self.error = str(exc)
                    if self.args.mode == "demo":
                        self.running = False
                print(f"Erro: {exc}", flush=True)
            finally:
                with self.condition:
                    self.busy = False
                    if self.args.mode == "demo" and self.stage >= self.stages - 1:
                        self.running = False
                    self.next_at = time.monotonic() + self.interval

    def start(self):
        self.thread = threading.Thread(target=self.work, name="pet-pipeline", daemon=True)
        self.thread.start()

    def close(self):
        with self.condition:
            self.closed = True
            self.condition.notify_all()
        if self.child is not None:
            try:
                self.child.terminate()
            except ProcessLookupError:
                pass
        if self.thread:
            self.thread.join(timeout=10)


class Handler(StaticHandler):
    def json(self, value, code=200):
        raw = (json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def trusted_local_request(self):
        # Não permite controle por páginas de terceiros nem por DNS rebinding.
        allowed = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        origin = self.headers.get("Origin")
        return self.headers.get("Host") in allowed and (origin is None or origin in {f"http://{host}" for host in allowed})

    def do_GET(self):
        if not self.trusted_local_request():
            return self.json({"error": "Origem local inválida"}, 403)
        path = urlsplit(self.path).path
        p = self.server.pipeline
        if path == "/api/status":
            return self.json(p.status())
        if path == "/config.json":
            return self.json({**p.config, "poll_interval_ms": 5000,
                "local_simulation": p.args.mode == "demo"})
        if path == "/data/latest.json":
            with p.condition:
                value = p.latest
            return self.json(value) if value else self.json({"error": "Aguardando executor"}, 503)
        if path.startswith("/api/"):
            return self.json({"error": "Rota inexistente"}, 404)
        super().do_GET()

    def do_POST(self):
        if not self.trusted_local_request() or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.json({"error": "Origem ou formato inválido"}, 403)
        if urlsplit(self.path).path != "/api/control":
            return self.json({"error": "Rota inexistente"}, 404)
        try:
            size = int(self.headers.get("Content-Length", "0"))
            require(0 < size <= 256, "tamanho da ação")
            data = json.loads(self.rfile.read(size))
            require(isinstance(data, dict) and set(data) <= {"action", "interval"}, "campos da ação")
            self.server.pipeline.control(data.get("action"), data.get("interval"))
            self.json(self.server.pipeline.status(), 202)
        except (ValueError, KeyError) as exc:
            self.json({"error": str(exc)}, 409)


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=("demo", "tse"), default="demo")
    p.add_argument("--model-dir", type=Path, default=Path(os.environ.get("PET_MODEL_DIR", DEFAULT_MODEL)))
    p.add_argument("--model-code", type=Path, help="Cópia de fontes já testada; dados históricos continuam em --model-dir")
    p.add_argument("--runtime", type=Path)
    p.add_argument("--source", type=Path, help="Export do coletor existente; somente leitura")
    p.add_argument("--initial-state", type=Path)
    p.add_argument("--rscript", default=shutil.which("Rscript") or "Rscript")
    p.add_argument("--draws", type=int, default=400)
    p.add_argument("--seed", type=int, default=618360)
    p.add_argument("--sections-per-uf", type=int, default=100)
    p.add_argument("--interval", type=float)
    p.add_argument("--name-a", default="Candidata A")
    p.add_argument("--name-b", default="Candidato B")
    p.add_argument("--port", type=int, default=4173)
    p.add_argument("--once", action="store_true", help="Processa um snapshot e encerra")
    return p


def main():
    args = parser().parse_args()
    require(args.draws >= 100 and 1 <= args.sections_per_uf <= 1000, "sorteios ou seções inválidos")
    require(args.interval is None or args.interval >= 1, "intervalo deve ser pelo menos 1 segundo")
    args.runtime = args.runtime or ROOT / "local" / args.mode
    args.source = args.source or args.model_dir / "data/live/tse_export"
    args.initial_state = args.initial_state or args.model_dir / "data/processed/estado_inicial_v2"
    pipeline = Pipeline(args)
    with runtime_lock(args.runtime.resolve()):
        try:
            print(f"Preparando {args.mode}: coletor -> modelo -> site...", flush=True)
            pipeline.prepare()
            if args.once:
                print(json.dumps(pipeline.status(), ensure_ascii=False), flush=True)
                return
            server = ThreadingHTTPServer(("127.0.0.1", args.port), partial(Handler, directory=str(ROOT / "web")))
            server.pipeline = pipeline
            pipeline.start()
            print(f"Local: http://127.0.0.1:{server.server_port}/\nModo: {args.mode}; Ctrl+C encerra este servidor e o executor local.", flush=True)
            try:
                server.serve_forever()
            finally:
                server.server_close()
        finally:
            pipeline.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nPipeline local encerrado.")
