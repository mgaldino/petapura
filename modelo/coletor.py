#!/usr/bin/env python3
"""Coleta de dados públicos observados do TSE, por seção.

Origem da lógica de índices/BER: electoralFraud/.../data_collection_2026_R1/
fetch_api_bu_2026_R1.py e decode_api_bu_2026_R1.py, consultados em 20/10/2026.
Fonte: resultados.tse.jus.br/oficial/ele2026/arquivo-urna/3221.
Raw imutável por SHA256; SQLite mantém a versão atual, CSV é exportação atômica.
"""
import argparse
import concurrent.futures as cf
import csv
import datetime as dt
import fcntl
import hashlib
import json
import logging
import os
from pathlib import Path
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
BASE = "https://resultados.tse.jus.br/oficial"
FIELDS = ["uf", "cd_mun", "zona", "secao", "aptos", "comparecimento",
          "validos", "votos_a", "votos_b", "brancos", "nulos", "hash",
          "hash_status", "source_utc", "collected_utc", "bu_sha256"]
LOG = logging.getLogger(__name__)


class InvalidTotalized(ValueError):
    """Índice publicado sem versão totalizada única: retirar a versão ativa antiga."""


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


class HTTP:
    def __init__(self, root, rate=30):
        self.root, self.spacing = Path(root), 1 / rate
        self.lock, self.next_request = threading.Lock(), 0.0
        self.blocked_until = 0.0
        self.root.mkdir(parents=True, exist_ok=True)

    def get(self, url):
        if not url.startswith(BASE + "/"):
            raise ValueError("URL fora do domínio/caminho oficial")
        for attempt in range(4):
            with self.lock:
                wait = max(0, self.next_request - time.monotonic(), self.blocked_until - time.monotonic())
                self.next_request = max(self.next_request, time.monotonic()) + self.spacing
            if wait:
                time.sleep(wait)
            # Outro worker pode ter detectado bloqueio depois de reservarmos a vaga.
            with self.lock:
                cooldown = self.blocked_until - time.monotonic()
            if cooldown > 0:
                raise RuntimeError("Coleta em pausa após HTTP 403/429")
            status, body, error = 0, b"", ""
            try:
                req = urllib.request.Request(url, headers={
                    "User-Agent": "regressao-usp-laboratorio/1.0 (public TSE data)",
                    "Cache-Control": "no-cache"})
                with urllib.request.urlopen(req, timeout=20) as response:
                    if response.geturl() != url:
                        raise ValueError("Redirecionamento inesperado")
                    status, body = response.status, response.read()
            except urllib.error.HTTPError as exc:
                status, body, error = exc.code, exc.read(), str(exc)
            except Exception as exc:
                error = f"{type(exc).__name__}: {exc}"
            digest = hashlib.sha256(body).hexdigest()
            raw = self.root / digest[:2] / digest
            with self.lock:
                raw.parent.mkdir(parents=True, exist_ok=True)
                if not raw.exists():
                    raw.write_bytes(body)
                with (self.root / "manifest.jsonl").open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps({"url": url, "utc": utc(), "http": status,
                        "sha256": digest, "bytes": len(body), "error": error,
                        "path": str(raw.relative_to(self.root))}) + "\n")
            if status == 200:
                return body
            if status in (403, 429):
                with self.lock:
                    self.blocked_until = max(self.blocked_until, time.monotonic() + 610)
                raise RuntimeError(f"HTTP {status}; pausa global de 610s: {url}")
            if status == 404:
                raise RuntimeError(f"HTTP {status}: {url}")
            if attempt < 3:
                time.sleep(2 ** attempt)
        raise RuntimeError(f"HTTP {status}: {error}: {url}")


def sections(document):
    result = []
    for area in document["abr"]:
        for municipality in area["mu"]:
            for zone in municipality["zon"]:
                for section in zone["sec"]:
                    # Uma seção agregada não produz BU próprio: evitar dupla contagem.
                    if "nsp" not in section:
                        result.append({"uf": area["cd"].upper(),
                            "cd_mun": int(municipality["cd"]), "zona": int(zone["cd"]),
                            "secao": int(section["ns"]),
                            "source_utc": section.get("da", "") + " " + section.get("ha", ""),
                            "announced": bool(section.get("da") or section.get("ha"))})
    return result


def key(row):
    return (row["uf"], row["cd_mun"], row["zona"], row["secao"])


def normalize_official(doc, cfg, area):
    if int(doc["ele"]) != cfg["election"] or int(doc["t"]) != cfg["round"]:
        raise ValueError("Totalização de outra eleição/turno")
    numbers = {int(c["n"]): int(c["vap"]) for office in doc["carg"] if int(office["cd"]) == 1
        for group in office["agr"] for party in group["par"] for c in party["cand"]}
    if set(numbers) != {cfg["candidate_a"], cfg["candidate_b"]}:
        raise ValueError("Candidatos oficiais diferem da configuração")
    valid = int(doc["v"]["vv"])
    st, ts = int(doc["s"]["st"]), int(doc["s"]["ts"])
    if any(n < 0 for n in numbers.values()) or not 0 <= st <= ts:
        raise ValueError("Contagens negativas ou seções totalizadas fora do limite")
    if sum(numbers.values()) != valid:
        raise ValueError("Soma de candidatos difere dos válidos na totalização")
    return {"area": area, "st": int(doc["s"]["st"]), "ts": int(doc["s"]["ts"]),
        "votos_a": numbers[cfg["candidate_a"]], "votos_b": numbers[cfg["candidate_b"]],
        "validos": valid, "generated": dt.datetime.strptime(doc["dg"] + " " + doc["hg"], "%d/%m/%Y %H:%M:%S").isoformat(),
        "fetched_utc": utc(), "current": True}


def choose_official(sources, ufs):
    """Escolhe avanço da apuração; horário resolve empates e versões corrigidas."""
    br = sources.get("BR")
    states = [sources[u] for u in ufs if u in sources]
    aggregate = None
    if len(states) == len(ufs):
        aggregate = {k: sum(s[k] for s in states) for k in ("st", "ts", "votos_a", "votos_b", "validos")}
        aggregate.update(area="SOMA_UFS", generated=max(s["generated"] for s in states),
            oldest_generated=min(s["generated"] for s in states), current=all(s["current"] for s in states))
    candidates = [s for s in (br, aggregate) if s is not None]
    if not candidates:
        return None
    chosen = max(candidates, key=lambda s: (s["st"], s["generated"]))
    return {"chosen": chosen, "national": br, "sum_ufs": aggregate,
        "national_lag_sections": aggregate["st"] - br["st"] if br and aggregate else None,
        "totals_disagree": bool(br and aggregate and any(br[k] != aggregate[k] for k in ("st", "votos_a", "votos_b"))),
        "states": states, "utc": utc()}


def pick_hash(index):
    # Somente boletins Totalizados. Recebido não é apurado.
    choices = [h for h in index.get("hashes", []) if h.get("st") == "Totalizado"]
    if len(choices) != 1:
        raise InvalidTotalized(f"Esperado um hash Totalizado; encontrados {len(choices)}")
    return choices[0]


def decode_president(raw, codec, section, cfg):
    env = codec.decode("EntidadeEnvelopeGenerico", raw)
    bu = codec.decode("EntidadeBoletimUrna", env["conteudo"])
    ids = bu["identificacaoSecao"]
    if (ids["municipioZona"]["municipio"], ids["municipioZona"]["zona"], ids["secao"]) != key(section)[1:]:
        raise ValueError("Chave interna do BU difere da seção solicitada")
    blocks = []
    for election in bu["resultadosVotacaoPorEleicao"]:
        if election["idEleicao"] != cfg["election"]:
            continue
        for result in election["resultadosVotacao"]:
            for office in result["totaisVotosCargo"]:
                if office["codigoCargo"][1] == "presidente":
                    blocks.append((election, result, office))
    if len(blocks) != 1:
        raise ValueError(f"{len(blocks)} blocos presidenciais da eleição esperada")
    election, result, office = blocks[0]
    counts = {"votos_a": 0, "votos_b": 0, "brancos": 0, "nulos": 0}
    for vote in office["votosVotaveis"]:
        number = (vote.get("identificacaoVotavel") or {}).get("codigo")
        kind = vote["tipoVoto"]
        quantity = vote["quantidadeVotos"]
        if not isinstance(quantity, int) or quantity < 0:
            raise ValueError("Contagem inválida")
        if kind == "nominal" and number in (cfg["candidate_a"], cfg["candidate_b"]):
            field = "votos_a" if number == cfg["candidate_a"] else "votos_b"
        elif kind in ("branco", "nulo"):
            field = "brancos" if kind == "branco" else "nulos"
        else:
            raise ValueError(f"Voto inesperado: {kind}, {number}")
        counts[field] += quantity
    turnout, eligible = result["qtdComparecimento"], election["qtdEleitoresAptos"]
    if sum(counts.values()) != turnout or not 0 <= turnout <= eligible:
        raise ValueError("Soma de votos, comparecimento ou aptos inconsistentes")
    return {**{name: section[name] for name in FIELDS[:4]}, "aptos": eligible,
        "comparecimento": turnout, **counts, "validos": counts["votos_a"] + counts["votos_b"],
        "bu_sha256": hashlib.sha256(raw).hexdigest(), "collected_utc": utc(),
        "source_utc": section.get("source_utc", "")}


class Collector:
    def __init__(self, cfg, state, http):
        import asn1tools
        self.cfg, self.state, self.http = cfg, Path(state), http
        self.state.mkdir(parents=True, exist_ok=True)
        self.codec = asn1tools.compile_files(str(ROOT / "spec" / "bu.asn1"), codec="ber")
        self.db = sqlite3.connect(self.state / "state.sqlite")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, value TEXT)")
        identity = json.dumps({k: cfg[k] for k in ("year", "round", "election", "pleito", "candidate_a", "candidate_b")}, sort_keys=True)
        old = self.db.execute("SELECT value FROM meta WHERE name='identity'").fetchone()
        if old and old[0] != identity:
            self.db.close()
            raise ValueError("Estado pertence a outra eleição/configuração")
        self.db.execute("INSERT OR IGNORE INTO meta VALUES ('identity', ?)", (identity,))
        self.db.execute("CREATE TABLE IF NOT EXISTS results (uf TEXT, cd_mun INTEGER, zona INTEGER, secao INTEGER, payload TEXT, PRIMARY KEY(uf,cd_mun,zona,secao))")
        self.db.execute("CREATE TABLE IF NOT EXISTS attempts (uf TEXT, cd_mun INTEGER, zona INTEGER, secao INTEGER, last REAL, PRIMARY KEY(uf,cd_mun,zona,secao))")
        self.db.commit()

    def config_url(self, uf):
        p = self.cfg["pleito"]
        return f"{BASE}/ele{self.cfg['year']}/arquivo-urna/{p}/config/{uf.lower()}/{uf.lower()}-p{p:06d}-cs.json"

    def fetch_section(self, section, old):
        p, u = self.cfg["pleito"], section["uf"].lower()
        m, z, s = (f"{section['cd_mun']:05d}", f"{section['zona']:04d}", f"{section['secao']:04d}")
        base = f"{BASE}/ele{self.cfg['year']}/arquivo-urna/{p}/dados/{u}/{m}/{z}/{s}"
        aux = f"{base}/p{p:06d}-{u}-m{m}-z{z}-s{s}-aux.json"
        h = pick_hash(json.loads(self.http.get(aux)))
        # Revalida o índice também para seções já apuradas; revisões substituem a linha.
        if old and old.get("hash") == h["hash"]:
            return old
        files = [a["nm"] for a in h.get("arq", []) if a.get("tp") == "bu"] or [
            a["nm"] for a in h.get("arq", []) if a.get("tp") == "busa"]
        if len(files) != 1 or "/" in files[0] or "/" in h["hash"]:
            raise ValueError("Índice com arquivo/hash ausente ou ambíguo")
        row = decode_president(self.http.get(f"{base}/{h['hash']}/{files[0]}"), self.codec, section, self.cfg)
        return {**row, "hash": h["hash"], "hash_status": h["st"]}

    def cycle(self, limit=None, checkpoint=None):
        start = time.monotonic()
        old = {tuple(r[:4]): json.loads(r[4]) for r in self.db.execute("SELECT * FROM results")}
        last = {tuple(r[:4]): r[4] for r in self.db.execute("SELECT * FROM attempts")}
        inventory, failures, okay_ufs = [], [], []
        for uf in self.cfg["ufs"]:
            try:
                doc = json.loads(self.http.get(self.config_url(uf)))
                if int(doc["cdp"]) != self.cfg["pleito"]:
                    raise ValueError("Lista de seções de outro pleito")
                inventory.extend(sections(doc))
                okay_ufs.append(uf)
            except Exception as exc:
                failures.append({"uf": uf, "error": str(exc)})
        # Sem lista de todas as UFs, mantém o último inventário completo.
        if set(okay_ufs) == set(self.cfg["ufs"]):
            write_csv(self.state / "inventory.csv", FIELDS[:4], inventory)
        now = time.time()
        due = [s for s in inventory if now - last.get(key(s), 0) >= (900 if key(s) in old else 60)]
        # Menos tentativas primeiro entre anunciadas: não deixar erros/UFs iniciais monopolizarem.
        def spatial_order(s):
            return hashlib.blake2b(str(key(s)).encode(), digest_size=8).digest()
        due.sort(key=lambda s: (key(s) in old, not s["announced"], last.get(key(s), 0), spatial_order(s)))
        # Reserva consultas para correções antigas e para seções sem horário de recepção.
        budget = self.cfg["max_sections_per_cycle"] if limit is None else limit
        fresh = [s for s in due if key(s) not in old and s["announced"]]
        audits = [s for s in due if key(s) in old]
        unannounced = [s for s in due if key(s) not in old and not s["announced"]]
        reserve = max(1, budget // 10)
        # Antes da publicação, não sondar BUs inexistentes: 404 repetido pode bloquear o IP.
        probes = max(0, int(self.cfg.get("unannounced_probe_limit", 0)))
        chosen = (audits[:reserve] + unannounced[:min(probes, reserve)] + fresh)[:budget]
        if len(chosen) < budget:
            used = {key(s) for s in chosen}
            chosen.extend(s for s in audits if key(s) not in used)
            chosen = chosen[:budget]
        def worker(s):
            try:
                return s, self.fetch_section(s, old.get(key(s))), None
            except Exception as exc:
                return s, None, exc
        added, changed, finished = 0, 0, 0
        with cf.ThreadPoolExecutor(max_workers=self.cfg["workers"]) as pool:
            for section, row, error in pool.map(worker, chosen):
                k = key(section)
                self.db.execute("INSERT OR REPLACE INTO attempts VALUES (?,?,?,?,?)", (*k, time.time()))
                if error:
                    failures.append({"key": k, "error": str(error)})
                    if isinstance(error, InvalidTotalized):
                        self.db.execute("DELETE FROM results WHERE uf=? AND cd_mun=? AND zona=? AND secao=?", k)
                else:
                    added += k not in old
                    changed += k in old and row["bu_sha256"] != old[k]["bu_sha256"]
                    self.db.execute("INSERT OR REPLACE INTO results VALUES (?,?,?,?,?)", (*k, json.dumps(row)))
                self.db.commit()  # checkpoint por seção: interrupção não perde o lote
                finished += 1
                if checkpoint and finished % 500 == 0:
                    self.export()
                    current = self.fetch_official()
                    atomic(self.state / "status.json", json.dumps({"utc": utc(), "official_current": current is not None,
                        "inventory_ufs": okay_ufs, "cycle_in_progress": True, "errors": failures}, ensure_ascii=False))
                    checkpoint()
        rows = self.export()
        # Total oficial permite distinguir atraso da coleta de atraso da apuração.
        official = self.fetch_official()
        status = {"utc": utc(), "inventory_ufs": okay_ufs, "inventory_sections": len(inventory),
            "collected_sections": len(rows), "added": added, "changed": changed,
            "requested_sections": len(chosen), "duration_seconds": time.monotonic() - start,
            "official_current": official is not None, "errors": failures}
        atomic(self.state / "status.json", json.dumps(status, indent=2, ensure_ascii=False))
        LOG.info("%s seções coletadas; +%s, %s revisões, %s erros; %.1fs", len(rows), added, changed, len(failures), status["duration_seconds"])
        return status

    def fetch_official(self):
        cache = self.state / "official_sources.json"
        sources = json.loads(cache.read_text()) if cache.exists() else {}
        for source in sources.values():
            source["current"] = False
        def one(area):
            e, u = self.cfg["election"], area.lower()
            try:
                url = f"{BASE}/ele{self.cfg['year']}/{e}/dados/{u}/{u}-c0001-e{e:06d}-u.json"
                doc = json.loads(self.http.get(url))
                return area, normalize_official(doc, self.cfg, area), None
            except Exception as exc:
                return area, None, str(exc)
        failures = []
        with cf.ThreadPoolExecutor(max_workers=8) as pool:
            for area, value, error in pool.map(one, ["BR"] + self.cfg["ufs"]):
                if value is not None:
                    sources[area] = value
                else:
                    failures.append({"area": area, "error": error})
        atomic(cache, json.dumps(sources, ensure_ascii=False))
        result = choose_official(sources, self.cfg["ufs"])
        if result is not None:
            result["errors"] = failures
            atomic(self.state / "official_selected.json", json.dumps(result, indent=2, ensure_ascii=False))
        return result

    def export(self):
        rows = [json.loads(r[0]) for r in self.db.execute("SELECT payload FROM results ORDER BY uf,cd_mun,zona,secao")]
        write_csv(self.state / "observed.csv", FIELDS, rows)
        return rows

    def close(self):
        self.db.close()


def write_csv(path, fields, rows):
    import io
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    atomic(path, stream.getvalue())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["probe", "inventory", "once", "watch"])
    parser.add_argument("--config", type=Path, default=ROOT / "config.json")
    parser.add_argument("--state", type=Path, default=ROOT / "data" / "live")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--update", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.update:
        parser.error("--update foi desativado: este coletor publica apenas dados observados")
    if args.limit is not None and args.limit < 0:
        parser.error("--limit deve ser maior ou igual a zero")
    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    args.state.mkdir(parents=True, exist_ok=True)
    # Uma instância por pasta; o bloqueio é liberado pelo SO após crash.
    with (args.state / "collector.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        http = HTTP(ROOT / "data" / "raw", cfg["requests_per_second"])
        collector = Collector(cfg, args.state, http)
        if args.mode == "probe":
            report = []
            urls = [f"{BASE}/comum/config/ele-c.json", collector.config_url("AC"), collector.config_url("ZZ"),
                f"{BASE}/ele2026/{cfg['election']}/dados/br/br-c0001-e{cfg['election']:06d}-u.json"]
            for url in urls:
                try:
                    data = json.loads(http.get(url))
                    report.append({"url": url, "okay": True, "keys": list(data), "preview": str(data)[:900]})
                except Exception as exc:
                    report.append({"url": url, "okay": False, "error": str(exc)})
            atomic(args.state / "probe.json", json.dumps(report, indent=2, ensure_ascii=False))
            LOG.info("Probe salvo em %s", args.state / "probe.json")
            collector.close()
            return
        def publish():
            from publicar_tse import publish_snapshot
            publish_snapshot(args.state, cfg)
        if args.mode == "inventory":
            collector.cycle(limit=0)
            publish()
            collector.close()
            return
        start, end = dt.datetime.fromisoformat(cfg["start"]), dt.datetime.fromisoformat(cfg["end"])
        awake = None
        while True:
            now = dt.datetime.now(dt.timezone.utc)
            if args.mode == "watch" and now < start:
                time.sleep(min(30, (start - now).total_seconds()))
                continue
            if args.mode == "watch" and now >= end:
                LOG.info("Janela de coleta encerrada")
                break
            if args.mode == "watch" and awake is None and Path("/usr/bin/caffeinate").exists():
                awake = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())])
            try:
                collector.cycle(args.limit, checkpoint=publish)
                publish()
            except Exception:
                LOG.exception("Ciclo falhou; a versão anterior permanece disponível")
                if args.mode == "once":
                    raise
            if args.mode == "once":
                break
            time.sleep(cfg["interval_seconds"])
        collector.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    main()
