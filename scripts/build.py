"""Empacota arquivos estáticos sem instalar dependências."""
from pathlib import Path
import shutil
from contract import read_json, validate

ROOT = Path(__file__).resolve().parents[1]
config = read_json(ROOT / "web/config.json")
validate(read_json(ROOT / "web/data/latest.json"), config)
for s in read_json(ROOT / "web/demo/snapshots.json"):
    validate(s, config)
destination = ROOT / "dist"
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(ROOT / "web", destination)
print(f"Site estático preparado: {destination}")
