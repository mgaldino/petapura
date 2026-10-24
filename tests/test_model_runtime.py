"""Reproduz a mudança de fontes durante uma execução sem alterar o modelo real."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from model_runtime import freeze_model, verify_model


class FrozenModelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.original = self.root / "original"
        self.original.mkdir()
        (self.original / "previsao_execucao.R").write_text("# API v1\n")
        self.frozen = self.root / "run/model-source"

    def test_changes_to_external_model_do_not_change_current_execution(self):
        freeze_model(self.original, self.frozen)
        before = verify_model(self.frozen)
        (self.original / "previsao_execucao.R").write_text("# API v2 com checkpoint incompatível\n")
        self.assertEqual(verify_model(self.frozen), before)
        self.assertEqual((self.frozen / "previsao_execucao.R").read_text(), "# API v1\n")
        another = self.root / "new-run/model-source"
        freeze_model(self.original, another)
        self.assertNotEqual(verify_model(another)["files"], before["files"])

    def test_tampered_frozen_source_is_rejected(self):
        freeze_model(self.original, self.frozen)
        (self.frozen / "previsao_execucao.R").write_text("# alterado")
        with self.assertRaisesRegex(ValueError, "alterada"):
            verify_model(self.frozen)

    def test_tested_release_can_be_reused_without_changing_any_source(self):
        freeze_model(self.original, self.frozen)
        release = self.root / "another-run/model-source"
        freeze_model(self.frozen, release)
        self.assertEqual(verify_model(release), verify_model(self.frozen))

    def test_missing_configuration_is_not_frozen_as_complete(self):
        (self.original / "componentes_locais.R").write_text('p <- "componentes_locais_v2.json"')
        with self.assertRaises(ValueError):
            freeze_model(self.original, self.frozen)
        self.assertFalse(self.frozen.exists())

    def test_sources_cannot_be_replaced_or_written_in_original(self):
        freeze_model(self.original, self.frozen)
        with self.assertRaises(ValueError):
            freeze_model(self.original, self.frozen)
        with self.assertRaises(ValueError):
            freeze_model(self.original, self.original / "copy")
