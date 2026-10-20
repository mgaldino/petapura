"""Lê o export do coletor sem modificá-lo e combina uma previsão opcional."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
from contract import ContractError, canonical, digest, publish, read_json, require, stamp, validate

ROOT = Path(__file__).resolve().parents[1]

def read_selected(directory, attempts=3):
    directory = Path(directory).resolve()
    pointer = directory / "manifest.json"
    error = None
    for _ in range(attempts):
        try:
            raw_manifest = pointer.read_bytes()
            manifest = json.loads(raw_manifest)
            require(manifest.get("schema_version") == 1 and manifest.get("mode") == "observed_data_only", "manifesto do coletor")
            entry = manifest["files"]["official_selected.json"]
            path = (directory / entry["path"]).resolve()
            require(path.is_relative_to(directory), "caminho fora do export")
            require(path.stat().st_size <= 2_000_000, "totalização excede 2 MB")
            raw = path.read_bytes()
            require(digest(raw) == entry["sha256"], "hash da totalização")
            selected = json.loads(raw)["chosen"]
            require(selected["area"] in ("BR", "SOMA_UFS") and selected["area"] == manifest["official_source_selected"], "fonte oficial escolhida")
            require(pointer.read_bytes() == raw_manifest, "manifesto mudou durante leitura")
            return manifest, selected
        except (ValueError, KeyError, OSError) as exc:
            error = exc
    raise ContractError(f"Snapshot consistente indisponível: {error}")

def adapt(directory, config, names, forecast=None):
    manifest, chosen = read_selected(directory)
    identity = manifest["identity"]
    require(identity["year"] == 2026 and identity["round"] == 2, "identidade do coletor")
    for key, slot in (("votos_a", "a"), ("votos_b", "b")):
        require(str(manifest["candidate_columns"][key]) == config["expected_candidates"][slot], "candidaturas do coletor")
    published = datetime.fromisoformat(manifest["published_utc"].replace("Z", "+00:00"))
    require(published.tzinfo is not None, "published_utc sem fuso horário")
    generated = published.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    observed_at = generated
    if forecast:
        require(forecast["source_snapshot_id"] == manifest["snapshot_id"], "previsão pertence a outro snapshot do coletor")
        generated = max((generated, forecast["generated_at"]), key=stamp)
    suffix = digest(canonical(forecast).encode("utf-8"))[:12] if forecast else "observed"
    c = {"total_sections":chosen["ts"], "reported_sections":chosen["st"],
         "collected_sections":manifest["observed_sections"], "votes_a":chosen["votos_a"],
         "votes_b":chosen["votos_b"], "valid_votes":chosen["validos"],
         "generated_at":observed_at,
         "source":{"name":"TSE", "area":chosen["area"], "generated_raw":chosen.get("generated")}}
    s = {"version":1, "mode":"live", "snapshot_id":f"{manifest['snapshot_id']}-{suffix}",
         "source_snapshot_id":manifest["snapshot_id"], "generated_at":generated,
         "election":{"year":identity["year"], "round":identity["round"], "office":"president",
                     "election_id":str(identity["election"]), "pleito_id":str(identity["pleito"])},
         "candidates":{slot:{"id":config["expected_candidates"][slot], "name":names[slot]} for slot in ("a","b")},
         "counting":c, "forecast":forecast, "history":[]}
    return validate(s, config)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Diretório tse_export")
    parser.add_argument("--forecast", type=Path, help="Objeto forecast exportado pelo modelo")
    parser.add_argument("--output", type=Path, default=ROOT / "web/data/latest.json")
    parser.add_argument("--config", type=Path, default=ROOT / "web/config.json")
    parser.add_argument("--name-a", default="Candidata A")
    parser.add_argument("--name-b", default="Candidato B")
    args = parser.parse_args()
    config = read_json(args.config)
    snapshot = adapt(args.source, config, {"a":args.name_a,"b":args.name_b}, read_json(args.forecast) if args.forecast else None)
    result, changed = publish(snapshot, args.output, config)
    print(f"{'Publicado' if changed else 'Sem alteração'}: {result['snapshot_id']}; modo real; previsão {'presente' if result['forecast'] else 'ainda indisponível'}")

if __name__ == "__main__":
    main()
