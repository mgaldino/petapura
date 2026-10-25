"""Reproduz a entrada com respostas TSE preservadas, sem rede ou escrita na produção."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil

import collector_live as policy

ROOT = Path(__file__).resolve().parents[1]


def run(audit, destination):
    production = json.loads((ROOT/'local/cloudflare-production/current.json').read_text())['settings']
    model = Path(production['model_dir'])
    live = model/'data/live'
    core = policy.load_core(model)
    cfg = json.loads((ROOT/'deployment/collector-2026.json').read_text())
    expected = [v for v in json.loads((audit/'sections.json').read_text()) if v['status']=='verified']
    requests = {v['url']:v for v in json.loads((audit/'requests.json').read_text())}
    for request in requests.values():
        assert hashlib.sha256((audit/request['file']).read_bytes()).hexdigest()==request['sha256']

    class ReplayHTTP:
        def get(self, url):
            request = requests.get(url)
            if request is None or request['http']!=200:
                raise RuntimeError('HTTP 404: '+url)
            return (audit/request['file']).read_bytes()

    class ReplayCollector(policy.collector_class(core)):
        def fetch_official(self):
            for name in ('official_sources.json','official_selected.json'):
                shutil.copy2(live/name, self.state/name)
            return json.loads((self.state/'official_selected.json').read_text())

    destination.mkdir(parents=True, exist_ok=False)
    state = destination/'collector'
    collector = ReplayCollector({**cfg,'ufs':['ZZ'],'workers':4}, state, ReplayHTTP())
    first = collector.cycle()
    rows = collector.export()
    assert len(rows)==len(expected)==166 and first['errors']==[]
    assert len({core.key(v) for v in rows})==166
    actual = {core.key(v):v for v in rows}
    for row in expected:
        assert all(actual[core.key(row)][k]==row[k] for k in (*policy.COUNTS,'bu_sha256','hash_status'))
    # Reconsultar o mesmo conjunto, incluindo os índices já conhecidos, não soma votos.
    columns = [r[1] for r in collector.db.execute('PRAGMA table_info(attempts)')]
    collector.db.execute('UPDATE attempts SET '+columns[-1]+'=0')
    collector.db.commit()
    second = collector.cycle()
    assert second['collected_sections']==166 and second['added']==second['changed']==0
    assert sum(v['validos'] for v in collector.export())==sum(v['validos'] for v in expected)
    collector.close()

    # Confere também todas as UFs contra os últimos inventários brutos do coletor.
    raw = model/'data/raw'
    configs = {}
    with (raw/'manifest.jsonl').open() as stream:
        for line in stream:
            record = json.loads(line)
            if record['http']==200 and '/config/' in record['url'] and record['url'].endswith('-cs.json'):
                configs[record['url']] = record
    keys, full_groups, config_hashes = set(), {}, {}
    for record in configs.values():
        content = (raw/record['path']).read_bytes()
        assert hashlib.sha256(content).hexdigest()==record['sha256']
        doc = json.loads(content)
        groups = policy.topology(doc)
        keys.update(groups);full_groups.update(groups)
        config_hashes[record['url']] = record['sha256']
    with (live/'inventory.csv').open() as stream:
        existing = {core.key({**v,**{k:int(v[k]) for k in ('cd_mun','zona','secao')}}) for v in csv.DictReader(stream)}
    assert len(configs)==len(cfg['ufs']) and keys==existing and len(keys)==499248
    (destination/'inventory-topology.json').write_text(json.dumps(
        {':'.join(map(str,k)):v for k,v in full_groups.items() if len(v)>1},sort_keys=True))

    t1_path = Path('/Users/manoelgaldino/Documents/DCP/Papers/electoralFraud/data/raw/tse/2026/api_arquivo_urna_config/20261005T032315519144Z/zz-p003220-cs.json')
    t1_raw = t1_path.read_bytes()
    old = policy.topology(json.loads(t1_raw))
    new = policy.topology(json.loads((audit/'raw/zz-config.json').read_bytes()))
    topology_check = {'t1_source':str(t1_path),'t1_sha256':hashlib.sha256(t1_raw).hexdigest(),
        't2_source':str(audit/'raw/zz-config.json'),
        't2_sha256':hashlib.sha256((audit/'raw/zz-config.json').read_bytes()).hexdigest(),
        't1_units':len(old),'t2_units':len(new),'added':list(new.keys()-old.keys()),
        'removed':list(old.keys()-new.keys()),
        'changed_membership':[list(k) for k in old.keys()&new.keys() if old[k]!=new[k]]}
    assert old==new
    (destination/'zz-section-changes.json').write_text(json.dumps(topology_check,ensure_ascii=False,indent=2))

    # Snapshot isolado com a população completa e os BUs reais reproduzidos.
    snapshot = destination/'input'
    snapshot.mkdir()
    for name in ('inventory.csv','official_sources.json','official_selected.json'):
        shutil.copy2(live/name,snapshot/name)
    for name in ('observed.csv','status.json'):
        shutil.copy2(state/name,snapshot/name)
    import publicar_tse
    manifest = publicar_tse.publish_snapshot(snapshot,cfg)
    for label,pointer in [('public',ROOT/'local/cloudflare-production/current.json'),
                          ('local',ROOT/'local/comparecimento-uf/live/current.json')]:
        settings = json.loads(pointer.read_text())['settings']
        runtime = destination/label
        runtime.mkdir()
        settings = {**settings,'runtime':str(runtime),'source':str(snapshot/'tse_export')}
        (runtime/'settings.json').write_text(json.dumps(settings,ensure_ascii=False,indent=2))
    report = {'utc':datetime.now(timezone.utc).isoformat(),'audit':str(audit),
        'network_requests':0,'production_modified':False,'first_cycle':first,'second_cycle':second,
        'unique_sections':166,'source_snapshot_id':manifest['snapshot_id'],
        'full_inventory_sections':len(keys),'config_hashes':config_hashes,'zz_topology':topology_check,
        'input_policy_sha256':hashlib.sha256((ROOT/'scripts/collector_live.py').read_bytes()).hexdigest()}
    (destination/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps({'destination':str(destination),'sections':166,'full_inventory':len(keys),
                      'repeat_added':second['added'],'repeat_changed':second['changed']}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit',required=True,type=Path)
    parser.add_argument('--destination',required=True,type=Path)
    args=parser.parse_args()
    run(args.audit.resolve(),args.destination.resolve())
