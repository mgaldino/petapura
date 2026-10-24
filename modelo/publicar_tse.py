"""Publica snapshots consistentes de dados observados, sem executar análises.

Fonte: arquivos locais coletados de resultados.tse.jus.br pelo coletor.py.
Dois slots alternados limitam o uso de disco; manifest.json é trocado por último.
Brutos, manifesto de download e estado SQLite não são removidos.
"""
import csv
import hashlib
import io
import json
from pathlib import Path
import uuid

from coletor import atomic, utc


def publish_snapshot(state, cfg):
    state = Path(state)
    destination = state / "tse_export"
    pointer = destination / "manifest.json"
    old = json.loads(pointer.read_text(encoding="utf-8")) if pointer.exists() else {}
    slot = 1 - old.get("slot", 1)
    folder = destination / "slots" / str(slot)
    files = {}

    def save(name, content, kind):
        path = folder / name
        atomic(path, content)
        files[name] = {"path": str(path.relative_to(destination)),
            "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(), "kind": kind}

    for name in ("inventory.csv", "observed.csv", "official_sources.json", "official_selected.json"):
        source = state / name
        if not source.exists():
            raise ValueError(f"Snapshot incompleto: {source}")
        save(name, source.read_text(encoding="utf-8"), source.suffix[1:])
    status = state / "status.json"
    if status.exists():
        save("status.json", status.read_text(encoding="utf-8"), "json")
    sources = json.loads((state / "official_sources.json").read_text(encoding="utf-8"))
    selected = json.loads((state / "official_selected.json").read_text(encoding="utf-8"))
    fields = ["area", "st", "ts", "votos_a", "votos_b", "validos", "generated", "fetched_utc", "current"]
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(sources[k] for k in sorted(sources))
    save("official_sources.csv", stream.getvalue(), "csv")
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
    writer.writeheader(); writer.writerow(selected["chosen"])
    save("official_selected.csv", stream.getvalue(), "csv")
    inventory_count = sum(1 for _ in csv.DictReader(io.StringIO((folder / "inventory.csv").read_text())))
    observed_count = sum(1 for _ in csv.DictReader(io.StringIO((folder / "observed.csv").read_text())))
    manifest = {"schema_version": 1, "snapshot_id": str(uuid.uuid4()), "slot": slot,
        "published_utc": utc(), "mode": "observed_data_only",
        "identity": {k: cfg[k] for k in ("year", "round", "election", "pleito")},
        "keys": ["uf", "cd_mun", "zona", "secao"],
        "candidate_columns": {"votos_a": cfg["candidate_a"], "votos_b": cfg["candidate_b"]},
        "inventory_sections": inventory_count, "observed_sections": observed_count,
        "official_source_selected": selected["chosen"]["area"],
        "files": files,
        "notes": ["Counts are observed data, not projections.",
            "National and state-sum totals are alternatives; never add both.",
            "source_utc in observed.csv is original TSE date/time text; the legacy name does not assert UTC.",
            "Slots rotate; verify hashes and snapshot_id when reading."]}
    atomic(pointer, json.dumps(manifest, ensure_ascii=False, indent=2))
    return manifest
