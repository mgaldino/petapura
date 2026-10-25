"""Congela a previsão sem aprendizado de cada seção, usada para comparar com o apurado.

Lê o secoes.csv do checkpoint corrente. Nas seções pendentes, usa pct_a_2022, que mantém
coeficientes, choques municipais e razão de válidos na prior. Nas seções já apuradas, cujo
pct_a_2022 é o observado, usa pct_a_modelo; o peso do aprendizado no momento do
congelamento fica registrado no manifesto. Não sobrescreve uma tabela existente.
Uso: scripts/freeze_prior_sections.py RUNTIME
"""
import argparse
import csv
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('runtime', type=Path)
args = p.parse_args()
model = args.runtime / 'model'
latest = json.loads((model / 'latest.json').read_text(encoding='utf-8'))
package = model / 'pacotes' / latest['package']
output = args.runtime / 'previsao-sem-aprendizado.csv'
if output.exists():
    raise SystemExit(f'{output} já existe; preserve a tabela congelada')
summary = next(csv.DictReader((package / 'resumo.csv').open(encoding='utf-8')))
tmp = output.with_suffix('.csv.tmp')
counted = total = 0
with (package / 'secoes.csv').open(encoding='utf-8') as source, tmp.open('w', encoding='utf-8', newline='') as target:
    writer = csv.writer(target)
    writer.writerow(['uf', 'cd_mun', 'zona', 'secao', 'pct_a_sem_aprendizado', 'origem'])
    for r in csv.DictReader(source):
        done = r['apurada'] in ('TRUE', 'True', 'true', '1')
        counted += done
        total += 1
        writer.writerow([r['uf'], r['cd_mun'], r['zona'], r['secao'],
                         r['pct_a_modelo'] if done else r['pct_a_2022'], 'pct_a_modelo' if done else 'pct_a_2022'])
tmp.replace(output)
manifest = dict(created_utc=datetime.now(timezone.utc).isoformat(), package=latest['package'],
                checkpoint_id=latest['id'], sequence=latest['sequence'], sections=total,
                counted_sections_at_freeze=counted, peso_atualizacao_at_freeze=float(summary['peso_atualizacao']),
                sha256=hashlib.sha256(output.read_bytes()).hexdigest())
(args.runtime / 'previsao-sem-aprendizado.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps(manifest))
