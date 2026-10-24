"""Controles, retomada e isolamento do servidor local sem executar R ou rede externa."""
from concurrent.futures import ThreadPoolExecutor
from functools import partial
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import run_local


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.model = self.root / "model"
        self.model.mkdir()
        self.base = self.root / "runtime"

    def args(self, mode="demo", runtime=None):
        args = run_local.parser().parse_args([
            "--mode", mode, "--model-dir", str(self.model),
            "--runtime", str(runtime or self.base),
        ])
        args.source = self.model / "data/live/tse_export"
        args.initial_state = self.model / "data/processed/estado_inicial_v2"
        return args

    def pipeline(self, mode="demo"):
        pipeline = run_local.Pipeline(self.args(mode))
        pipeline.stages = 3
        return pipeline

    def fixture_export(self, p, stage=1, status_updates=None, path="slots/0/status.json"):
        p.runtime = self.base / "runs" / ("a" * 32)
        folder = p.runtime / "collector/tse_export"
        folder.mkdir(parents=True, exist_ok=True)
        status = {"kind": "pet_synthetic_replay", "synthetic": True, "stage": stage}
        status.update(status_updates or {})
        target = (folder / path).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        raw = json.dumps(status).encode()
        target.write_bytes(raw)
        manifest = {"snapshot_id": "collector-stage-1", "files": {
            "status.json": {"path": path, "sha256": hashlib.sha256(raw).hexdigest()}}}
        (folder / "manifest.json").write_text(json.dumps(manifest))
        return folder, manifest

    def test_constructor_only_inspects_without_starting_or_writing(self):
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        with patch.object(run_local.subprocess, "Popen") as popen:
            p = self.pipeline()
        self.assertIsNone(p.runtime)
        self.assertIsNone(p.thread)
        self.assertTrue(p.running)
        self.assertFalse(self.base.exists())
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))
        popen.assert_not_called()

    def test_rejects_runtime_model_directory_descendant_and_ancestor_before_writing(self):
        for destination in (self.model, self.model / "data/live/demo", self.root):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                run_local.Pipeline(self.args(runtime=destination))
        self.assertEqual(list(self.model.iterdir()), [])
        self.assertFalse((self.root / ".pipeline.lock").exists())

    def test_rejects_runtime_in_web(self):
        with self.assertRaisesRegex(ValueError, "web/"):
            run_local.Pipeline(self.args(runtime=run_local.ROOT / "web/local-test"))

    def test_next_rejects_busy_and_only_queues_one_concurrent_request(self):
        p = self.pipeline()
        p.busy = True
        with self.assertRaisesRegex(ValueError, "cálculo"):
            p.control("next")
        self.assertIsNone(p.pending)
        p.busy = False
        barrier = threading.Barrier(2)

        def next_request():
            barrier.wait()
            try:
                p.control("next")
                return True
            except ValueError:
                return False

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: next_request(), range(2)))
        self.assertEqual(sorted(results), [False, True])
        self.assertEqual(p.pending, "next")

    def test_pause_stops_future_cycles_while_a_calculation_is_busy(self):
        p = self.pipeline()
        p.busy = True
        p.running = True
        p.control("pause")
        self.assertFalse(p.running)
        self.assertTrue(p.busy)

    def test_speed_validation_does_not_accept_booleans_or_arbitrary_values(self):
        p = self.pipeline()
        for invalid in (True, 3.0, 0, 1, 100, "3", None):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "velocidade"):
                p.control("speed", invalid)
        for valid in (3, 8, 20):
            p.control("speed", valid)
            self.assertEqual(p.interval, valid)

    def test_complete_demo_requires_restart(self):
        p = self.pipeline()
        p.stage = p.stages - 1
        for action in ("next", "play"):
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, "concluída"):
                p.control(action)
        p.control("restart")
        self.assertEqual(p.pending, "restart")

    def test_real_mode_refuses_all_simulation_controls(self):
        p = self.pipeline("tse")
        for action in ("next", "restart", "play", "pause", "speed"):
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, "somente na simulação"):
                p.control(action, 3)
        self.assertTrue(p.running)
        self.assertIsNone(p.pending)

    def test_runtime_lock_excludes_second_writer_and_is_released(self):
        with run_local.runtime_lock(self.base):
            with self.assertRaisesRegex(ValueError, "outro pipeline"):
                with run_local.runtime_lock(self.base):
                    self.fail("Segundo escritor adquiriu lock")
        with run_local.runtime_lock(self.base):
            pass

    def test_exported_stage_checks_hash_and_synthetic_marker(self):
        p = self.pipeline()
        folder, manifest = self.fixture_export(p)
        self.assertEqual(p.exported_stage(), 1)
        (folder / manifest["files"]["status.json"]["path"]).write_text("{}")
        with self.assertRaisesRegex(ValueError, "hash"):
            p.exported_stage()
        self.fixture_export(p, status_updates={"synthetic": False})
        with self.assertRaisesRegex(ValueError, "fictício"):
            p.exported_stage()

    def test_exported_stage_rejects_escape_and_invalid_stage(self):
        p = self.pipeline()
        self.fixture_export(p, path="../outside-status.json")
        with self.assertRaisesRegex(ValueError, "caminho"):
            p.exported_stage()
        for invalid in (True, -1, 3):
            self.fixture_export(p, stage=invalid)
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "etapa"):
                p.exported_stage()

    def test_resume_recovers_export_stage_after_crash_before_current_json(self):
        p = self.pipeline()
        self.fixture_export(p, stage=1)
        (p.runtime / "fixture").mkdir()
        (p.runtime / "fixture/scenario.json").write_text(json.dumps({"fractions": [0, .5, 1]}))
        saved = {"kind": "pet_local_pipeline", "mode": "demo", "run": p.runtime.name,
                 "stage": 0, "settings": p.settings()}
        run_local.atomic_write(self.base / "current.json", saved)
        with patch.object(p, "update") as update:
            p.prepare()
        update.assert_called_once_with()
        self.assertEqual(p.stage, 1)
        self.assertEqual(run_local.read_json(self.base / "current.json")["stage"], 1)

    def test_failure_retries_existing_export_without_creating_another_snapshot(self):
        p = self.pipeline()
        self.fixture_export(p, stage=1)
        p.pending = "next"

        def failing_update():
            p.closed = True  # Executa somente este ciclo do worker no teste.
            raise RuntimeError("R indisponível")

        with patch.object(p, "update", side_effect=failing_update), patch.object(run_local, "publish_demo_stage") as publish:
            p.work()
        publish.assert_not_called()
        self.assertEqual(p.stage, 0)
        self.assertIn("R indisponível", p.error)
        self.assertFalse(p.running)

        p.closed = False
        p.pending = "next"
        with patch.object(p, "update", side_effect=lambda: setattr(p, "closed", True)), patch.object(run_local, "publish_demo_stage") as publish:
            p.work()
        publish.assert_not_called()
        self.assertEqual(p.stage, 1)
        self.assertIsNone(p.error)

    def test_failed_restart_restores_previous_run_and_can_continue(self):
        p = self.pipeline()
        self.fixture_export(p, stage=1)
        p.stage = 1
        p.latest = {"snapshot_id": "last-valid", "counting": None}
        p.last_seconds = 2.5
        p.remember()
        previous = (p.runtime, p.stage, p.stages, p.latest, p.last_seconds)
        pointer_before = (self.base / "current.json").read_bytes()

        def fail_after_new_state():
            p.runtime = self.base / "runs" / ("b" * 32)
            p.stage, p.stages = 0, 24
            p.latest, p.last_seconds = {"snapshot_id": "unconfirmed-new-run"}, .1
            raise RuntimeError("Falha ao confirmar o reinício")

        with patch.object(p, "_new_run", side_effect=fail_after_new_state):
            with self.assertRaisesRegex(RuntimeError, "confirmar"):
                p.new_run()
        self.assertEqual((p.runtime, p.stage, p.stages, p.latest, p.last_seconds), previous)
        self.assertEqual((self.base / "current.json").read_bytes(), pointer_before)
        self.assertEqual(p.exported_stage(), 1)
        p.control("next")
        self.assertEqual(p.pending, "next")

    def test_r_failure_preserves_last_valid_public_result(self):
        p = self.pipeline()
        p.runtime = self.base / "runs/failure-test"
        p.runtime.mkdir(parents=True)
        (self.model / "previsao_execucao.R").write_text("# modelo simulado no teste")
        run_local.freeze_model(self.model, p.runtime / "model-source")
        p.latest = {"snapshot_id": "last-valid"}
        child = Mock()
        child.wait.return_value = 1
        with patch.object(run_local.subprocess, "Popen", return_value=child) as popen, patch.object(run_local, "publish") as publish:
            with self.assertRaisesRegex(RuntimeError, "executor R falhou"):
                p.update()
        self.assertEqual(p.latest, {"snapshot_id": "last-valid"})
        publish.assert_not_called()
        self.assertIsInstance(popen.call_args.args[0], list)
        self.assertFalse(popen.call_args.kwargs.get("shell", False))

    def test_demo_rejects_real_model_output_before_publication(self):
        p = self.pipeline()
        p.runtime = self.base / "runs/mode-test"
        p.runtime.mkdir(parents=True)
        (p.runtime / "snapshot-site.json").write_text(json.dumps({"mode": "live"}))
        with patch.object(p, "r"), patch.object(run_local, "publish") as publish:
            with self.assertRaisesRegex(ValueError, "modo inesperado"):
                p.update()
        publish.assert_not_called()


class LocalHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.web = root / "web"
        self.web.mkdir()
        (self.web / "index.html").write_text("<!doctype html><title>Teste</title>")
        private = root / "runtime"
        private.mkdir()
        (private / "secret.txt").write_text("PRIVATE CHECKPOINT")
        self.calls = []
        self.pipeline = SimpleNamespace(args=SimpleNamespace(mode="demo"), config={"endpoint": "./data/latest.json"},
            latest={"snapshot_id": "demo-public-only"}, condition=threading.Condition(),
            status=lambda: {"mode": "demo", "stage": 0},
            control=lambda action, interval: self.calls.append((action, interval)))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(run_local.Handler, directory=str(self.web)))
        self.server.pipeline = self.pipeline
        self.port = self.server.server_port
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=.01), daemon=True)
        log_patch = patch.object(run_local.Handler, "log_message", return_value=None)
        log_patch.start()
        self.addCleanup(log_patch.stop)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, path="/api/status", method="GET", headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.request(method, path, body=body, headers={"Host": f"127.0.0.1:{self.port}", **(headers or {})})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_same_origin_reads_public_state_and_explicit_demo_config(self):
        status, headers, body = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"mode": "demo", "stage": 0})
        self.assertEqual(headers["Cache-Control"], "no-store")
        status, _, body = self.request("/config.json")
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["local_simulation"])
        self.assertEqual(json.loads(self.request("/data/latest.json")[2]), {"snapshot_id": "demo-public-only"})

    def test_foreign_origins_and_rebound_host_cannot_read_or_control(self):
        for headers in ({"Origin": "https://foreign.example"}, {"Host": "foreign.example"}):
            for method in ("GET", "POST"):
                with self.subTest(headers=headers, method=method):
                    status, _, _ = self.request("/api/control" if method == "POST" else "/api/status", method,
                        headers={"Content-Type": "application/json", **headers}, body='{"action":"next"}' if method == "POST" else None)
                    self.assertEqual(status, 403)
        self.assertEqual(self.calls, [])

    def test_only_json_same_origin_control_is_accepted(self):
        status, _, _ = self.request("/api/control", "POST", {"Content-Type": "text/plain"}, '{"action":"next"}')
        self.assertEqual(status, 403)
        status, _, _ = self.request("/api/control", "POST", {"Content-Type": "application/json",
            "Origin": f"http://localhost:{self.port}"}, '{"action":"next"}')
        self.assertEqual(status, 202)
        self.assertEqual(self.calls, [("next", None)])

    def test_invalid_control_payloads_do_not_reach_pipeline(self):
        for body in ("not json", "[]", '{"action":"next","private":"x"}', "x" * 257):
            with self.subTest(body=body):
                status, _, _ = self.request("/api/control", "POST", {"Content-Type": "application/json"}, body)
                self.assertEqual(status, 409)
        self.assertEqual(self.calls, [])

    def test_unknown_routes_and_path_traversal_do_not_expose_runtime_files(self):
        for path in ("/api/private", "/runtime/secret.txt", "/../runtime/secret.txt", "/%2e%2e/runtime/secret.txt", "/.pipeline.lock"):
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 404)
                self.assertNotIn(b"PRIVATE CHECKPOINT", body)
        self.assertEqual(self.request("/")[0], 200)

    def test_no_model_result_yet_is_not_served_as_success(self):
        self.pipeline.latest = None
        self.assertEqual(self.request("/data/latest.json")[0], 503)


if __name__ == "__main__":
    unittest.main()
