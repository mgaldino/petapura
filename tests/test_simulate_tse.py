"""Reprodução sintética e limites de escrita, sem acessar a rede."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import simulate_tse


class FakePublisher:
    def __init__(self):
        self.calls = []

    @staticmethod
    def atomic(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def publish_snapshot(self, state, cfg):
        self.calls.append((state, cfg))
        selected = json.loads((state / "official_selected.json").read_text())
        result = {"snapshot_id": "fake-original-id", "schema_version": 1,
                  "mode": "observed_data_only", "notes": ["original publisher note"],
                  "official_source_selected": selected["chosen"]["area"],
                  "files": {name: {"sha256": hashlib.sha256((state / name).read_bytes()).hexdigest()}
                            for name in ("inventory.csv", "observed.csv", "status.json")}}
        self.atomic(state / "tse_export/manifest.json", json.dumps(result))
        return result


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.model = self.root / "model"
        self.model.mkdir()
        self.config = {"year": 2026, "round": 2, "election": 6258, "pleito": 3221,
                       "candidate_a": 13, "candidate_b": 22}
        (self.model / "config.json").write_text(json.dumps(self.config))
        self.runtime = self.root / "runtime"
        self.fixture = self.runtime / "fixture"
        self.fixture.mkdir(parents=True)
        self.scenario = {"kind": "pet_synthetic_replay", "fractions": [0, .34, .8, 1]}
        self.rows = [{"uf": "AC" if i < 3 else "AL", "cd_mun": "1" if i < 3 else "2",
                      "zona": "1", "secao": str(i + 1), "aptos": "200",
                      "comparecimento": "150", "validos": "140", "votos_a": str(50 + i),
                      "votos_b": str(90 - i), "brancos": "5", "nulos": "5", "hash": f"s{i}"}
                     for i in range(6)]
        self.write_scenario()
        self.write_rows()
        self.publisher = FakePublisher()
        self.loader = patch.object(simulate_tse, "_load_publisher", return_value=self.publisher)
        self.loader.start()
        self.addCleanup(self.loader.stop)
        self.addCleanup(self.temp.cleanup)

    def write_scenario(self):
        (self.fixture / "scenario.json").write_text(json.dumps(self.scenario))

    def write_rows(self):
        for filename, fields in (("inventory.csv", simulate_tse.KEYS),
                                 ("truth.csv", (*simulate_tse.KEYS, *simulate_tse.COUNTS, "hash"))):
            with (self.fixture / filename).open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
                writer.writeheader()
                writer.writerows(self.rows)

    def publish(self, stage):
        return simulate_tse.publish_demo_stage(self.model, self.runtime, stage)

    def observed(self):
        return list(csv.DictReader(io.StringIO((self.runtime / "collector/observed.csv").read_text())))

    def selected(self):
        return json.loads((self.runtime / "collector/official_selected.json").read_text())

    def test_zero_stage_keeps_header_and_all_inventory(self):
        manifest = self.publish(0)
        self.assertEqual(self.observed(), [])
        self.assertEqual(self.selected()["chosen"]["ts"], 6)
        self.assertEqual(self.selected()["chosen"]["st"], 0)
        self.assertEqual(manifest["official_source_selected"], "BR")
        self.assertEqual(len(list(csv.DictReader(io.StringIO((self.runtime / "collector/inventory.csv").read_text())))), 6)

    def test_fraction_is_floored_and_arrival_order_preserved(self):
        self.publish(1)
        self.assertEqual([row["hash"] for row in self.observed()], ["s0", "s1"])
        self.assertEqual(self.selected()["chosen"]["st"], 2)
        self.assertEqual(self.selected()["chosen"]["votos_a"], 101)
        self.assertEqual(self.observed()[0]["hash_status"], "Totalizado")

    def test_final_stage_contains_every_section_once(self):
        self.publish(3)
        self.assertEqual(len(self.observed()), 6)
        self.assertEqual(self.selected()["chosen"]["st"], 6)
        self.assertEqual(self.selected()["chosen"]["validos"], 840)

    def test_alternates_br_and_sum_states_without_double_counting(self):
        for stage, expected in ((1, "SOMA_UFS"), (2, "BR")):
            with self.subTest(stage=stage):
                self.publish(stage)
                data = self.selected()
                self.assertEqual(data["chosen"]["area"], expected)
                for field in ("ts", "st", "votos_a", "votos_b", "validos"):
                    self.assertEqual(sum(uf[field] for uf in data["states"]), data["chosen"][field])
                self.assertEqual(data["national"]["votos_a"], data["sum_ufs"]["votos_a"])

    def test_delegates_and_marks_synthetic_without_changing_hashes(self):
        result = self.publish(1)
        self.assertEqual(self.publisher.calls, [(self.runtime / "collector", self.config)])
        self.assertEqual(result["snapshot_id"], "fake-original-id")
        self.assertEqual(result["mode"], "observed_data_only")
        self.assertIn("SYNTHETIC", result["notes"][-1])
        status = json.loads((self.runtime / "collector/status.json").read_text())
        self.assertTrue(status["synthetic"])
        self.assertEqual(status["kind"], "pet_synthetic_replay")
        for name, entry in result["files"].items():
            self.assertEqual(hashlib.sha256((self.runtime / "collector" / name).read_bytes()).hexdigest(), entry["sha256"])
        self.assertEqual(result, json.loads((self.runtime / "collector/tse_export/manifest.json").read_text()))

    def test_pointer_is_published_once_with_the_synthetic_note(self):
        original = self.publisher.atomic
        pointer_writes = []

        def record(path, content):
            if path.name == "manifest.json":
                pointer_writes.append(json.loads(content))
            original(path, content)

        self.publisher.atomic = record
        self.publish(0)
        self.assertEqual(len(pointer_writes), 1)
        self.assertIn("SYNTHETIC", pointer_writes[0]["notes"][-1])

    def test_refuses_runtime_inside_model(self):
        with self.assertRaisesRegex(ValueError, "separado"):
            simulate_tse.publish_demo_stage(self.model, self.model / "data/live", 0)
        self.assertFalse((self.model / "data").exists())

    def test_refuses_runtime_inside_web(self):
        with patch.object(simulate_tse, "ROOT", self.root):
            with self.assertRaisesRegex(ValueError, "web/"):
                simulate_tse.publish_demo_stage(self.model, self.root / "web/runtime", 0)

    def test_refuses_symlink_escape(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.runtime / "collector").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "escapa"):
            self.publish(0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_refuses_existing_nested_symlink(self):
        folder = self.runtime / "collector/tse_export"
        folder.mkdir(parents=True)
        (folder / "manifest.json").symlink_to(self.model / "config.json")
        with self.assertRaisesRegex(ValueError, "simbólicos"):
            self.publish(0)

    def test_requires_explicit_marker(self):
        self.scenario["kind"] = "real_data"
        self.write_scenario()
        with self.assertRaisesRegex(ValueError, "identificação"):
            self.publish(0)
        self.assertEqual(self.publisher.calls, [])

    def test_rejects_invalid_stage(self):
        for stage in (-1, 4, True, .5, "1"):
            with self.subTest(stage=stage), self.assertRaisesRegex(ValueError, "Estágio"):
                self.publish(stage)

    def test_rejects_invalid_fractions(self):
        for fractions in ([0, .8, .2, 1], [0, float("nan"), 1], [0, True, 1], [.1, 1], [0, .9]):
            self.scenario["fractions"] = fractions
            self.write_scenario()
            with self.subTest(fractions=fractions), self.assertRaisesRegex(ValueError, "Frações"):
                self.publish(0)

    def test_rejects_mismatched_inventory(self):
        self.write_rows()
        with (self.fixture / "truth.csv").open("a") as handle:
            handle.write("SP,3,1,7,200,150,140,70,70,5,5,s7\n")
        with self.assertRaisesRegex(ValueError, "mesmas seções"):
            self.publish(0)

    def test_rejects_inconsistent_votes_before_writing(self):
        self.rows[0]["votos_a"] = "999"
        self.write_rows()
        with self.assertRaisesRegex(ValueError, "inconsistentes"):
            self.publish(0)
        self.assertFalse((self.runtime / "collector").exists())

    def test_real_module_loader_restores_modules_and_avoids_bytecode(self):
        (self.model / "coletor.py").write_text("def atomic(*args): pass\ndef utc(): return 'fake'\n")
        (self.model / "publicar_tse.py").write_text("from coletor import atomic, utc\ndef publish_snapshot(*args): return utc()\n")
        previous = SimpleNamespace(marker="already imported")
        with patch.dict(sys.modules, {"coletor": previous}):
            # Bypass only the fixture's loader mock for this import test.
            self.loader.stop()
            try:
                module = simulate_tse._load_publisher(self.model)
                self.assertEqual(module.publish_snapshot(), "fake")
                self.assertIs(sys.modules["coletor"], previous)
            finally:
                self.loader.start()
        self.assertFalse((self.model / "__pycache__").exists())

    @unittest.skipUnless(os.environ.get("PET_MODEL_DIR"), "Defina PET_MODEL_DIR para exercitar o publicador original")
    def test_real_collector_publisher_and_site_reader(self):
        self.loader.stop()
        try:
            model = Path(os.environ["PET_MODEL_DIR"]).resolve()
            result = simulate_tse.publish_demo_stage(model, self.runtime, 1)
        finally:
            self.loader.start()
        from import_tse import read_selected
        manifest, chosen = read_selected(self.runtime / "collector/tse_export")
        self.assertEqual(manifest, result)
        self.assertEqual(result["observed_sections"], 2)
        self.assertEqual(chosen["area"], "SOMA_UFS")
        for entry in manifest["files"].values():
            path = self.runtime / "collector/tse_export" / entry["path"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), entry["sha256"])


if __name__ == "__main__":
    unittest.main()
