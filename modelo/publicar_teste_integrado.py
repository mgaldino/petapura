"""Publica snapshots de TESTE com o código real do coletor, sem acesso à rede.

Uso exclusivo dos testes integrados: os BUs vêm de um CSV sintético e as
totalizações de uma especificação JSON servida por um HTTP simulado no formato
do TSE. Passam pelo mesmo caminho da vigia: tabela SQLite de resultados,
Collector.export(), Collector.fetch_official() (normalize_official e
choose_official) e publish_snapshot(). Nunca apontar para data/live.

Uso: python publicar_teste_integrado.py ESTADO_DE_TESTE ESPECIFICACAO.json
"""
import csv
import json
from pathlib import Path
import sys
import time

import coletor
from publicar_tse import publish_snapshot

INTEGERS = ("cd_mun", "zona", "secao", "aptos", "comparecimento", "validos",
            "votos_a", "votos_b", "brancos", "nulos")


class OfficialHTTP:
    """Responde às URLs de totalização; áreas marcadas como falha retornam erro."""

    def __init__(self, cfg, areas):
        self.cfg, self.areas = cfg, areas

    def get(self, url):
        if not url.startswith(coletor.BASE + "/"):
            raise ValueError("URL fora do domínio oficial")
        area = url.rsplit("/", 1)[1].split("-")[0].upper()
        spec = self.areas.get(area)
        if spec is None or spec == "falha":
            raise RuntimeError(f"HTTP 503 simulado: {url}")
        a, b = int(spec["votos_a"]), int(spec["votos_b"])
        doc = {"ele": str(self.cfg["election"]), "t": str(self.cfg["round"]),
               "dg": spec["dg"], "hg": spec["hg"],
               "s": {"st": str(int(spec["st"])), "ts": str(int(spec["ts"]))}, "v": {"vv": str(a + b)},
               "carg": [{"cd": "1", "agr": [{"par": [{"cand": [
                   {"n": str(self.cfg["candidate_a"]), "vap": str(a)},
                   {"n": str(self.cfg["candidate_b"]), "vap": str(b)}]}]}]}]}
        return json.dumps(doc).encode("utf-8")


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    for row in rows:
        for k in INTEGERS:
            row[k] = int(row[k])
    return rows


def main():
    state, spec_path = Path(sys.argv[1]), Path(sys.argv[2])
    if state.resolve() == (coletor.ROOT / "data" / "live").resolve():
        raise SystemExit("Teste não pode publicar no estado operacional")
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    cfg = json.loads((coletor.ROOT / "config.json").read_text(encoding="utf-8"))
    started = time.monotonic()
    collector = coletor.Collector(cfg, state, OfficialHTTP(cfg, spec["official"]))
    try:
        if spec.get("inventory"):
            coletor.write_csv(state / "inventory.csv", coletor.FIELDS[:4], read_rows_keys(spec["inventory"]))
        desired = {coletor.key(r): json.dumps({k: r[k] for k in coletor.FIELDS}) for r in read_rows(spec["observed"])}
        current = {tuple(r[:4]): r[4] for r in collector.db.execute("SELECT * FROM results")}
        # BU retirado do índice Totalizado sai da tabela; corrigido substitui a versão ativa.
        for k in current.keys() - desired.keys():
            collector.db.execute("DELETE FROM results WHERE uf=? AND cd_mun=? AND zona=? AND secao=?", k)
        changed = [(*k, p) for k, p in desired.items() if current.get(k) != p]
        collector.db.executemany("INSERT OR REPLACE INTO results VALUES (?,?,?,?,?)", changed)
        collector.db.commit()
        rows = collector.export()
        official = collector.fetch_official()
        coletor.atomic(state / "status.json", json.dumps({"utc": coletor.utc(), "fixture": "teste_integrado",
            "collected_sections": len(rows), "official_current": official is not None,
            "errors": official.get("errors", []) if official else []}, ensure_ascii=False))
    finally:
        collector.close()
    exported = time.monotonic()
    manifest = publish_snapshot(state, cfg)
    print(json.dumps({"snapshot_id": manifest["snapshot_id"], "slot": manifest["slot"],
        "observed_sections": manifest["observed_sections"], "chosen": manifest["official_source_selected"],
        "rows_written": len(changed), "export_seconds": round(exported - started, 3),
        "publish_seconds": round(time.monotonic() - exported, 3)}))


def read_rows_keys(path):
    with open(path, newline="", encoding="utf-8") as stream:
        return [{"uf": r["uf"], "cd_mun": int(r["cd_mun"]), "zona": int(r["zona"]), "secao": int(r["secao"])}
                for r in csv.DictReader(stream)]


if __name__ == "__main__":
    main()
