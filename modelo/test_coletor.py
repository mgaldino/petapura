"""Testes de falhas que poderiam mudar os totais da previsão."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from coletor import Collector, FIELDS, InvalidTotalized, choose_official, decode_president, key, pick_hash, sections

ROOT = Path(__file__).resolve().parent
CFG = json.loads((ROOT / "config.json").read_text())
SECTION = {"uf": "AC", "cd_mun": 1007, "zona": 9, "secao": 1}


def bulletin():
    return {"identificacaoSecao": {"municipioZona": {"municipio": 1007, "zona": 9}, "secao": 1},
      "resultadosVotacaoPorEleicao": [{"idEleicao": 6258, "qtdEleitoresAptos": 100,
        "resultadosVotacao": [{"qtdComparecimento": 90, "totaisVotosCargo": [{"codigoCargo": ("constitucional", "presidente"),
          "votosVotaveis": [{"tipoVoto": "nominal", "identificacaoVotavel": {"codigo": 13}, "quantidadeVotos": 40},
            {"tipoVoto": "nominal", "identificacaoVotavel": {"codigo": 22}, "quantidadeVotos": 45},
            {"tipoVoto": "branco", "quantidadeVotos": 2}, {"tipoVoto": "nulo", "quantidadeVotos": 3}]}]}]}]}


class Codec:
    def __init__(self, bu):
        self.bu = bu

    def decode(self, kind, raw):
        return {"conteudo": b"x"} if kind == "EntidadeEnvelopeGenerico" else self.bu


class HTTPFixture:
    def __init__(self):
        self.hash = "hash1"
        self.st = "Totalizado"
        self.urls = []

    def get(self, url):
        self.urls.append(url)
        if "-aux.json" in url:
            return json.dumps({"hashes": [{"hash": self.hash, "st": self.st,
                "arq": [{"nm": "bu.dat", "tp": "bu"}]}]}).encode()
        return b"raw"


class TestCollector(unittest.TestCase):
    def test_real_ber_bulletin(self):
        import asn1tools
        fixture = json.loads((ROOT / "fixtures/bu_real_t1.json").read_text())
        codec = asn1tools.compile_files(str(ROOT / "spec/bu.asn1"), codec="ber")
        section = dict(uf="AC",cd_mun=1040,zona=4,secao=182)
        row = decode_president((ROOT / "fixtures/bu_real_t1.dat").read_bytes(),codec,section,{**CFG,"election":6257,"round":1})
        for k,v in fixture["expected"].items():
            self.assertEqual(row[k],v)

    def test_national_frozen_states_advance(self):
        def source(area, st, generated="2026-10-25T18:00:00"):
            return dict(area=area, st=st, ts=100, votos_a=st*40, votos_b=st*60,
                validos=st*100, generated=generated, current=True)
        result = choose_official({"BR": source("BR", 20), "AC": source("AC", 15), "SP": source("SP", 25)}, ["AC", "SP"])
        self.assertEqual(result["chosen"]["area"], "SOMA_UFS")
        self.assertEqual(result["chosen"]["st"], 40)
        self.assertEqual(result["national_lag_sections"], 20)
        self.assertEqual(result["chosen"]["votos_a"], 1600)  # BR não é somado às UFs

    def test_states_stale_national_advances(self):
        sources = {"BR": dict(area="BR",st=50,ts=200,votos_a=2000,votos_b=3000,validos=5000,generated="2026-10-25T18:02:00",current=True),
            "AC": dict(area="AC",st=10,ts=100,votos_a=400,votos_b=600,validos=1000,generated="2026-10-25T18:00:00",current=True)}
        self.assertEqual(choose_official(sources, ["AC"])["chosen"]["area"], "BR")

    def test_missing_state_does_not_form_incomplete_national(self):
        sources = {"BR": dict(area="BR",st=10,ts=200,votos_a=400,votos_b=600,validos=1000,generated="2026-10-25T18:00:00",current=True)}
        self.assertIsNone(choose_official(sources, ["AC", "SP"])["sum_ufs"])

    def test_aggregated_section(self):
        doc = {"abr": [{"cd": "ac", "mu": [{"cd": "01007", "zon": [{"cd": "0009",
            "sec": [{"ns": "0001", "nsa": ["0002"]}, {"ns": "0002", "nsp": "0001"}]}]}]}]}
        self.assertEqual(len(sections(doc)), 1)

    def test_received_is_not_counted(self):
        with self.assertRaises(InvalidTotalized):
            pick_hash({"hashes": [{"hash": "x", "st": "Recebido"}]})

    def test_ambiguous_totalized(self):
        with self.assertRaises(InvalidTotalized):
            pick_hash({"hashes": [{"hash": "x", "st": "Totalizado"}, {"hash": "y", "st": "Totalizado"}]})

    def test_counts(self):
        row = decode_president(b"raw", Codec(bulletin()), SECTION, CFG)
        self.assertEqual((row["validos"], row["votos_a"], row["votos_b"]), (85, 40, 45))

    def test_wrong_election_rejected(self):
        bu = bulletin(); bu["resultadosVotacaoPorEleicao"][0]["idEleicao"] = 6257
        with self.assertRaises(ValueError):
            decode_president(b"raw", Codec(bu), SECTION, CFG)

    def test_wrong_section_rejected(self):
        bu = bulletin(); bu["identificacaoSecao"]["secao"] = 2
        with self.assertRaises(ValueError):
            decode_president(b"raw", Codec(bu), SECTION, CFG)

    def test_turnout_rejected(self):
        bu = bulletin(); bu["resultadosVotacaoPorEleicao"][0]["resultadosVotacao"][0]["qtdComparecimento"] = 89
        with self.assertRaises(ValueError):
            decode_president(b"raw", Codec(bu), SECTION, CFG)

    def test_unknown_nominal_rejected(self):
        bu = bulletin(); bu["resultadosVotacaoPorEleicao"][0]["resultadosVotacao"][0]["totaisVotosCargo"][0]["votosVotaveis"][0]["identificacaoVotavel"]["codigo"] = 99
        with self.assertRaises(ValueError):
            decode_president(b"raw", Codec(bu), SECTION, CFG)

    def test_zero_padding_and_revision(self):
        with tempfile.TemporaryDirectory() as folder:
            http = HTTPFixture()
            collector = Collector(CFG, folder, http)
            self.addCleanup(collector.close)
            collector.codec = Codec(bulletin())
            row1 = collector.fetch_section(SECTION, None)
            self.assertIn("/ac/01007/0009/0001/p003221-ac-m01007-z0009-s0001-aux.json", http.urls[0])
            http.hash = "hash2"
            row2 = collector.fetch_section(SECTION, row1)
            self.assertEqual(row2["hash"], "hash2")
            http.st = "Recebido"
            with self.assertRaises(InvalidTotalized):
                collector.fetch_section(SECTION, row2)

    def test_state_refuses_other_election(self):
        with tempfile.TemporaryDirectory() as folder:
            collector = Collector(CFG, folder, HTTPFixture())
            self.addCleanup(collector.close)
            other = {**CFG, "election": 6257}
            with self.assertRaises(ValueError):
                Collector(other, folder, HTTPFixture())


if __name__ == "__main__":
    unittest.main(verbosity=2)
