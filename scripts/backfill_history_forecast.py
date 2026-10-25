"""Preenche a projeção das entradas antigas do histórico a partir do historico.csv do modelo.

Só preenche quando o checkpoint da entrada existe no historico.csv e o número de seções
com BU do modelo coincide com reported_sections da entrada (mesma posição no eixo x).
Uso: scripts/backfill_history_forecast.py RUNTIME [--write] [--output ARQUIVO]
"""
import argparse
import csv
import fcntl
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from contract import atomic_write, read_json, validate  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument('runtime', type=Path)
p.add_argument('--write', action='store_true')
p.add_argument('--output', type=Path)
args = p.parse_args()
destination = args.runtime / 'public/latest.json'
config = read_json(ROOT / 'web/config.json')
rows = {r['checkpoint_id']: r for r in csv.DictReader((args.runtime / 'model/historico.csv').open(encoding='utf-8'))}

with (destination.parent / f'.{destination.name}.lock').open('a') as lock:
    if args.write:
        fcntl.flock(lock, fcntl.LOCK_EX)
    s = json.loads(destination.read_text(encoding='utf-8'))
    filled = skipped_x = missing = already = 0
    for h in s['history']:
        if 'forecast_a' in h:
            already += 1
            continue
        m = re.fullmatch(r'cp-([0-9a-f]{64})-[0-9a-f]{16}', h['snapshot_id'])
        r = rows.get(m.group(1)) if m else None
        if r is None:
            missing += 1
            continue
        if int(r['secoes_apuradas_coletor']) != h['reported_sections']:
            skipped_x += 1
            continue
        h.update(forecast_a=float(r['pct_a_projetado']), forecast_lower=float(r['pct_a_q025']),
                 forecast_upper=float(r['pct_a_q975']))
        if r.get('pct_a_2022'):
            h.update(forecast_2022_a=float(r['pct_a_2022']), forecast_2022_lower=float(r['pct_a_2022_q025']),
                     forecast_2022_upper=float(r['pct_a_2022_q975']))
        filled += 1
    validate(s, config)
    print(json.dumps(dict(entries=len(s['history']), filled=filled, already=already,
                          skipped_position=skipped_x, missing_checkpoint=missing)))
    if args.output:
        atomic_write(args.output, s)
    if args.write:
        atomic_write(destination, s)
        print(f'gravado: {destination}')
