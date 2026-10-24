"""Empacota arquivos estáticos sem instalar dependências."""
from pathlib import Path
import argparse
import os
import re
import shutil
from contract import atomic_write, read_json, require, validate

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--snapshot", type=Path, help="Snapshot público calculado pelo executor")
parser.add_argument("--production", action="store_true", help="Exige previsão real dos dois cenários")
parser.add_argument("--require-analytics", action="store_true")
args = parser.parse_args()
config = read_json(ROOT / "web/config.json")
snapshot = validate(read_json(args.snapshot or ROOT / "web/data/latest.json"), config)
if args.production:
    require(snapshot["mode"] == "live", "produção exige dados reais")
    require(snapshot["forecast"] is not None and snapshot.get("forecast_2022") is not None,
            "produção exige os dois cenários do mesmo checkpoint")
    require(all(c["name"] not in ("Candidata A", "Candidato B") for c in snapshot["candidates"].values()),
            "produção exige nomes das candidaturas")
token = os.environ.get("PET_ANALYTICS_TOKEN", config.get("cloudflare_web_analytics_token", "")).strip()
require(not token or re.fullmatch(r"[a-fA-F0-9]{32}", token), "token público do Cloudflare Web Analytics")
require(not args.require_analytics or bool(token), "analytics ainda não configurado; informe PET_ANALYTICS_TOKEN")
for s in read_json(ROOT / "web/demo/snapshots.json"):
    validate(s, config)
destination = ROOT / "dist"
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(ROOT / "web", destination)
atomic_write(destination / "data/latest.json", snapshot)
if token:
    config["cloudflare_web_analytics_token"] = token
atomic_write(destination / "config.json", config)
print(f"Site estático preparado: {destination}")
print(f"Origem: {snapshot['mode']}; dois cenários: {bool(snapshot.get('forecast_2022'))}; analytics: {'configurado' if token else 'pendente'}")
