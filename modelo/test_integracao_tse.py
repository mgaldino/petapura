"""Integração de dados observados, com fixtures sintéticas e leitor R real."""
import copy
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import coletor
import operar
from publicar_tse import publish_snapshot

ROOT = Path(__file__).resolve().parent
CFG = json.loads((ROOT / "config.json").read_text())


class FixtureHTTP:
    def __init__(self):
        self.urls = []

    def get(self, url):
        self.urls.append(url)
        if "-cs.json" in url:
            doc = {"cdp": CFG["pleito"], "abr": [{"cd": "ac", "mu": [{"cd": "01007", "zon": [
                {"cd": "0009", "sec": [{"ns": "0001"}]}]}]}]}
        elif url.endswith("-u.json"):
            doc = {"ele": CFG["election"], "t": 2, "v": {"vv": 0}, "s": {"st": 0, "ts": 1},
                "dg": "20/10/2026", "hg": "12:00:00", "carg": [{"cd": 1, "agr": [{"par": [
                    {"cand": [{"n": 13, "vap": 0}, {"n": 22, "vap": 0}]}]}]}]}
        else:
            raise AssertionError(f"Não deveria consultar BU ainda não anunciado: {url}")
        return json.dumps(doc).encode()


class TestIntegration(unittest.TestCase):
    def setup_snapshot(self, folder):
        cfg = {**CFG, "ufs": ["AC"]}
        http = FixtureHTTP()
        collector = coletor.Collector(cfg, folder, http)
        self.addCleanup(collector.close)
        status = collector.cycle(limit=10)
        manifest = publish_snapshot(folder, cfg)
        return cfg, http, status, manifest

    def test_cycle_does_not_probe_unannounced_bulletins(self):
        with tempfile.TemporaryDirectory() as folder:
            _, http, status, _ = self.setup_snapshot(folder)
            self.assertEqual(status["requested_sections"], 0)
            self.assertFalse(any("-aux.json" in url for url in http.urls))

    def test_manifest_data_only_and_integrity(self):
        with tempfile.TemporaryDirectory() as folder:
            _, _, _, manifest = self.setup_snapshot(folder)
            self.assertEqual(manifest["mode"], "observed_data_only")
            self.assertEqual(manifest["inventory_sections"], 1)
            self.assertEqual(manifest["observed_sections"], 0)
            for entry in manifest["files"].values():
                raw = (Path(folder) / "tse_export" / entry["path"]).read_bytes()
                self.assertEqual(hashlib.sha256(raw).hexdigest(), entry["sha256"])

    def test_slots_alternate_preserving_previous_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            cfg, _, _, first = self.setup_snapshot(folder)
            path = Path(folder) / "tse_export" / first["files"]["observed.csv"]["path"]
            previous = path.read_bytes()
            second = publish_snapshot(folder, cfg)
            self.assertNotEqual(first["slot"], second["slot"])
            self.assertNotEqual(first["snapshot_id"], second["snapshot_id"])
            self.assertEqual(path.read_bytes(), previous)
            third = publish_snapshot(folder, cfg)
            self.assertEqual(third["slot"], first["slot"])

    def test_incomplete_snapshot_keeps_previous_pointer(self):
        with tempfile.TemporaryDirectory() as folder:
            cfg, _, _, _ = self.setup_snapshot(folder)
            pointer = Path(folder) / "tse_export/manifest.json"
            old = pointer.read_bytes()
            (Path(folder) / "official_selected.json").unlink()
            with self.assertRaises(ValueError):
                publish_snapshot(folder, cfg)
            self.assertEqual(pointer.read_bytes(), old)

    def test_r_reader_loads_consistent_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            self.setup_snapshot(folder)
            code = ('a<-commandArgs(TRUE);source(a[1]);d<-ler_dados_tse(a[2]);'
                'stopifnot(nrow(d$secoes)==0L,nrow(d$inventario)==1L,'
                'd$manifesto$mode=="observed_data_only")')
            result = subprocess.run(["Rscript", "--vanilla", "-e", code, str(ROOT / "ler_dados_tse.R"),
                str(Path(folder) / "tse_export")], capture_output=True, text=True,
                env={**os.environ, "LC_ALL": "pt_BR.UTF-8", "LANG": "pt_BR.UTF-8"})
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_r_reader_rejects_corrupted_file(self):
        with tempfile.TemporaryDirectory() as folder:
            _, _, _, manifest = self.setup_snapshot(folder)
            path = Path(folder) / "tse_export" / manifest["files"]["observed.csv"]["path"]
            path.write_text(path.read_text() + "corrupted\n")
            result = subprocess.run(["Rscript", "--vanilla", "-e",
                'a<-commandArgs(TRUE);source(a[1]);ler_dados_tse(a[2],tentativas=1L)',
                str(ROOT / "ler_dados_tse.R"), str(Path(folder) / "tse_export")],
                capture_output=True, text=True, env={**os.environ, "LC_ALL": "pt_BR.UTF-8", "LANG": "pt_BR.UTF-8"})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("integridade", result.stderr)

    def test_r_reader_loads_observed_counts_and_key(self):
        from test_coletor import Codec, SECTION, bulletin
        with tempfile.TemporaryDirectory() as folder:
            cfg, _, _, _ = self.setup_snapshot(folder)
            row = coletor.decode_president(b"fixture", Codec(bulletin()), SECTION, cfg)
            row.update(hash="fixture", hash_status="Totalizado")
            coletor.write_csv(Path(folder) / "observed.csv", coletor.FIELDS, [row])
            publish_snapshot(folder, cfg)
            code = ('a<-commandArgs(TRUE);source(a[1]);d<-ler_dados_tse(a[2]);'
                'stopifnot(nrow(d$secoes)==1L,d$secoes$uf=="AC",d$secoes$cd_mun==1007L,'
                'd$secoes$votos_a+d$secoes$votos_b==d$secoes$validos,'
                'd$secoes$validos+d$secoes$brancos+d$secoes$nulos==d$secoes$comparecimento)')
            result = subprocess.run(["Rscript", "--vanilla", "-e", code, str(ROOT / "ler_dados_tse.R"),
                str(Path(folder) / "tse_export")], capture_output=True, text=True,
                env={**os.environ, "LC_ALL": "pt_BR.UTF-8", "LANG": "pt_BR.UTF-8"})
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_update_cli_is_disabled_before_accessing_state(self):
        result = subprocess.run([sys.executable, str(ROOT / "coletor.py"), "once", "--update"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("desativado", result.stderr)

    def test_operator_no_longer_requires_model_or_runs_r(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config.json").write_text(json.dumps(CFG))
            with mock.patch.object(operar, "ROOT", root), mock.patch.object(operar, "interpreter", return_value=sys.executable), \
                 mock.patch.object(sys, "argv", ["operar.py", "check"]), contextlib.redirect_stdout(io.StringIO()) as stream:
                operar.main()
            receipt = json.loads(stream.getvalue())
            self.assertNotIn("--update", receipt["command"])
            self.assertEqual(receipt["mode"], "observed_data_only")


if __name__ == "__main__":
    unittest.main(verbosity=2)
