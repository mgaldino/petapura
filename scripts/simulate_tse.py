"""Replay sintético pelo publicador real do coletor, sem consultas de rede.

As entradas ficam em runtime/fixture; somente runtime/collector recebe dados.
O contrato interno continua observed_data_only para exercitar o leitor real.
O adaptador público deve publicar estes resultados com mode=demo.
"""
from collections import Counter
import csv
from datetime import datetime, timezone
import importlib.util
import io
import json
import math
from pathlib import Path
import re
import sys
from model_runtime import verify_model

ROOT = Path(__file__).resolve().parents[1]
KEYS = ("uf", "cd_mun", "zona", "secao")
COUNTS = ("aptos", "comparecimento", "validos", "votos_a", "votos_b", "brancos", "nulos")
FIELDS = (*KEYS, *COUNTS, "hash", "hash_status", "source_utc", "collected_utc", "bu_sha256")
KIND = "pet_synthetic_replay"


def _inside(path, parent):
    return path == parent or parent in path.parents


def _guard_paths(model_dir, runtime):
    model_dir = Path(model_dir).resolve(strict=True)
    runtime = Path(runtime).resolve()
    frozen = model_dir == runtime / "model-source"
    if frozen:
        verify_model(model_dir)
    if _inside(runtime, model_dir) or (_inside(model_dir, runtime) and not frozen):
        raise ValueError("A simulação exige um runtime separado do diretório do modelo")
    if _inside(runtime, (ROOT / "web").resolve()):
        raise ValueError("O runtime sintético não pode ficar em web/")
    for folder in (runtime / "fixture", runtime / "collector"):
        if not _inside(folder.resolve(), runtime):
            raise ValueError("Caminho da simulação escapa do runtime")
    collector = runtime / "collector"
    if collector.exists() and any(p.is_symlink() for p in collector.rglob("*")):
        raise ValueError("O coletor sintético não aceita links simbólicos")
    return model_dir, runtime


def _read_csv(path, required):
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        fields = reader.fieldnames or []
        if len(fields) != len(set(fields)) or not set(required) <= set(fields):
            raise ValueError(f"Colunas ausentes ou duplicadas em {path.name}")
        rows = list(reader)
    if any(None in row or any(v is None for v in row.values()) for row in rows):
        raise ValueError(f"Linha CSV incompleta em {path.name}")
    return rows


def _key(row):
    if not re.fullmatch(r"[A-Z]{2}", row["uf"]):
        raise ValueError("UF sintética inválida")
    result = [row["uf"]]
    for name in KEYS[1:]:
        if not re.fullmatch(r"[0-9]+", row[name]) or int(row[name]) <= 0:
            raise ValueError(f"Chave sintética inválida: {name}")
        result.append(int(row[name]))
    return tuple(result)


def _fixture(runtime, stage):
    directory = runtime / "fixture"
    for name in ("scenario.json", "inventory.csv", "truth.csv"):
        if not _inside((directory / name).resolve(strict=True), directory.resolve()):
            raise ValueError("Entrada sintética escapa de fixture/")
    scenario = json.loads((directory / "scenario.json").read_text(encoding="utf-8"))
    if not isinstance(scenario, dict) or scenario.get("kind") != KIND:
        raise ValueError("Fixture sem identificação pet_synthetic_replay")
    fractions = scenario.get("fractions")
    if (not isinstance(fractions, list) or len(fractions) < 2 or
            any(isinstance(f, bool) or not isinstance(f, (int, float)) or
                not math.isfinite(f) or not 0 <= f <= 1 for f in fractions) or
            fractions != sorted(fractions) or fractions[0] != 0 or fractions[-1] != 1):
        raise ValueError("Frações da simulação devem avançar de zero até um")
    if isinstance(stage, bool) or not isinstance(stage, int) or not 0 <= stage < len(fractions):
        raise ValueError("Estágio sintético fora do intervalo")
    inventory = _read_csv(directory / "inventory.csv", KEYS)
    truth = _read_csv(directory / "truth.csv", (*KEYS, *COUNTS, "hash"))
    inv_keys = [_key(row) for row in inventory]
    truth_keys = [_key(row) for row in truth]
    if (not inventory or len(set(inv_keys)) != len(inv_keys) or
            len(set(truth_keys)) != len(truth_keys) or set(inv_keys) != set(truth_keys)):
        raise ValueError("Inventário e verdade sintética devem ter as mesmas seções únicas")
    for row in truth:
        for field in COUNTS:
            if not re.fullmatch(r"[0-9]+", row[field]):
                raise ValueError(f"Contagem sintética inválida: {field}")
            row[field] = int(row[field])
        if (row["votos_a"] + row["votos_b"] != row["validos"] or
                row["validos"] + row["brancos"] + row["nulos"] != row["comparecimento"] or
                row["comparecimento"] > row["aptos"] or not row["hash"]):
            raise ValueError("Contagens sintéticas inconsistentes")
    fraction = fractions[stage]
    count = len(truth) if stage == len(fractions) - 1 else math.floor(fraction * len(truth))
    return inventory, truth[:count], fraction, len(truth)


def _csv(rows, fields):
    stream = io.StringIO(newline="")
    writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    return stream.getvalue()


def _load_publisher(model_dir):
    """Carrega estes fontes sem criar bytecode nem reaproveitar outro coletor."""
    old_bytecode = sys.dont_write_bytecode
    old_path = list(sys.path)
    old_collector = sys.modules.get("coletor")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(model_dir))
    try:
        spec = importlib.util.spec_from_file_location("coletor", model_dir / "coletor.py")
        collector = importlib.util.module_from_spec(spec)
        sys.modules["coletor"] = collector
        spec.loader.exec_module(collector)
        spec = importlib.util.spec_from_file_location("_pet_publicar_tse", model_dir / "publicar_tse.py")
        publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(publisher)
        return publisher
    finally:
        sys.dont_write_bytecode = old_bytecode
        sys.path[:] = old_path
        if old_collector is None:
            sys.modules.pop("coletor", None)
        else:
            sys.modules["coletor"] = old_collector


def publish_demo_stage(model_dir, runtime, stage):
    """Publica um índice de fractions pelo publicador original do coletor.

    Retorna o manifesto escrito em runtime/collector/tse_export/manifest.json.
    Não inicia vigia, não baixa BUs e não modifica o diretório do modelo.
    """
    model_dir, runtime = _guard_paths(model_dir, runtime)
    inventory, observed, fraction, total = _fixture(runtime, stage)
    config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    for name in ("year", "round", "election", "pleito", "candidate_a", "candidate_b"):
        value = config.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise ValueError(f"Configuração eleitoral inválida: {name}")
    publisher = _load_publisher(model_dir)
    stamp = datetime.now(timezone.utc).isoformat()
    for row in observed:
        row.setdefault("hash_status", "Totalizado")
        row.setdefault("source_utc", stamp)
        row.setdefault("collected_utc", stamp)
        row.setdefault("bu_sha256", "")
    sections_by_uf = Counter(row["uf"] for row in inventory)
    observed_by_uf = {uf: [] for uf in sections_by_uf}
    for row in observed:
        observed_by_uf[row["uf"]].append(row)

    def area(name, rows, size):
        return {"area": name, "ts": size, "st": len(rows),
                "votos_a": sum(row["votos_a"] for row in rows),
                "votos_b": sum(row["votos_b"] for row in rows),
                "validos": sum(row["validos"] for row in rows),
                "generated": stamp, "fetched_utc": stamp, "current": True}

    national = area("BR", observed, total)
    states = [area(uf, observed_by_uf[uf], sections_by_uf[uf]) for uf in sorted(sections_by_uf)]
    state_sum = {**national, "area": "SOMA_UFS", "oldest_generated": stamp}
    selected = {"chosen": national if stage % 2 == 0 else state_sum,
                "national": national, "sum_ufs": state_sum,
                "states": states, "national_lag_sections": 0,
                "totals_disagree": False, "utc": stamp, "errors": []}
    collector = runtime / "collector"
    contents = {
        "inventory.csv": _csv(inventory, KEYS),
        "observed.csv": _csv(observed, FIELDS),
        "official_sources.json": json.dumps({"BR": national, **{s["area"]: s for s in states}}, ensure_ascii=False),
        "official_selected.json": json.dumps(selected, ensure_ascii=False),
        "status.json": json.dumps({"kind": KIND, "synthetic": True, "stage": stage,
                                   "fraction": fraction, "observed_sections": len(observed),
                                   "inventory_sections": total, "utc": stamp,
                                   "message": "DEMONSTRAÇÃO: votos e seções fictícios; sem consulta ao TSE."},
                                  ensure_ascii=False),
    }
    for name, content in contents.items():
        publisher.atomic(collector / name, content)
    pointer = collector / "tse_export" / "manifest.json"
    original_atomic = publisher.atomic

    def marked_atomic(path, content):
        # A nota entra antes da única troca do ponteiro. Reescrever depois da
        # publicação exporia temporariamente dois conteúdos para o mesmo ID.
        if Path(path) == pointer:
            manifest = json.loads(content)
            manifest["notes"].append("PET SYNTHETIC REPLAY: every BU, count and section in this snapshot is fictitious; do not publish as live data.")
            content = json.dumps(manifest, ensure_ascii=False, indent=2)
        original_atomic(path, content)

    publisher.atomic = marked_atomic
    try:
        publisher.publish_snapshot(collector, config)
    finally:
        publisher.atomic = original_atomic
    return json.loads(pointer.read_text(encoding="utf-8"))
