"""Valida um snapshot do modelo e o publica atomicamente para o site."""
import argparse
from pathlib import Path
from contract import publish, read_json

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "web/data/latest.json")
    parser.add_argument("--config", type=Path, default=ROOT / "web/config.json")
    args = parser.parse_args()
    result, changed = publish(read_json(args.input), args.output, read_json(args.config))
    print(f"{'Publicado' if changed else 'Sem alteração'}: {result['snapshot_id']} → {args.output}")

if __name__ == "__main__":
    main()
