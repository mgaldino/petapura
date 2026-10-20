"""Monta uma cópia descartável para inspeção de estados, sempre rotulada DEMO."""
from copy import deepcopy
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
target=ROOT/'tests/qa/site'
if target.exists():shutil.rmtree(target)
shutil.copytree(ROOT/'web',target)
items=[]
for name in ['prior','live-95','complete']:
    s=json.loads((ROOT/f'tests/fixtures/{name}.json').read_text())
    s['mode']='demo'
    if s['counting']:
        s['counting']['source']['area']='DEMO'
        s['counting']['source']['name']='Teste sintético'
    items.append(s)
(target/'demo/snapshots.json').write_text(json.dumps(items,ensure_ascii=False))
print('QA identificada como demonstração: http://127.0.0.1:4174/site/?demo=1')
