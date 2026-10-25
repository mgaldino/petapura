"""Política operacional de entrada de BUs, sem modificar o modelo congelado.

Acrescenta Recebido a Totalizado e descobre índices sem anúncio em escopo limitado.
O decoder BER, a publicação atômica e o lock continuam sendo os do coletor original.
"""
import argparse
import concurrent.futures as cf
import csv
from datetime import datetime
import hashlib
import importlib.util
import json
import logging
from pathlib import Path
import sys
import time

POLICY_VERSION = 1
ORIGINAL_COLLECTOR_SHA256 = '76a76d791d14daa9ea78bfc98403a7715eff6b046035c931cfbdd106b3ff5986'
COUNTS = ('aptos', 'comparecimento', 'validos', 'votos_a', 'votos_b', 'brancos', 'nulos')
RANK = {'Recebido': 1, 'Totalizado': 2}


class InvalidBU(ValueError):
    pass


class StaleIndex(ValueError):
    """Resposta regrediu. Preservar o último BU válido e registrar a divergência."""


def select_hash(index, accepted=('Totalizado', 'Recebido')):
    """Uma versão por seção. Status tem prioridade, depois recepção inequívoca."""
    for status in sorted(accepted, key=lambda v: RANK[v], reverse=True):
        versions = {}
        for version in index.get('hashes', []):
            if version.get('st') != status:
                continue
            identity = version.get('hash')
            if not isinstance(identity, str) or not identity or '/' in identity:
                raise InvalidBU('Hash ausente ou inválido')
            if identity in versions and versions[identity] != version:
                raise InvalidBU('Mesmo hash com metadados contraditórios')
            versions[identity] = version
        if len(versions) == 1:
            return next(iter(versions.values()))
        if len(versions) > 1:
            # Totalizados conflitantes não são resolvidos por ordem da lista.
            if status == 'Totalizado':
                raise InvalidBU('Mais de um hash Totalizado')
            try:
                dated = [(datetime.strptime(v['dr']+' '+v['hr'], '%d/%m/%Y %H:%M:%S'), v)
                         for v in versions.values()]
            except (KeyError, ValueError) as exc:
                raise InvalidBU('Recebidos múltiplos sem cronologia verificável') from exc
            latest = max(stamp for stamp, _ in dated)
            choices = [v for stamp, v in dated if stamp == latest]
            if len(choices) == 1:
                return choices[0]
            raise InvalidBU('Recebidos conflitantes no mesmo horário')
    raise InvalidBU('Índice sem versão aceita')


def topology(document):
    """Mapeia seções agregadas para sua unidade de BU, usando nsp/nsa do TSE."""
    groups, parents = {}, {}
    for area in document['abr']:
        for municipality in area['mu']:
            for zone in municipality['zon']:
                prefix = (area['cd'].upper(), int(municipality['cd']), int(zone['cd']))
                for section in zone['sec']:
                    identity = (*prefix, int(section['ns']))
                    if 'nsp' in section:
                        parents[identity] = (*prefix, int(section['nsp']))
                    else:
                        if identity in groups:
                            raise InvalidBU('Unidade de BU duplicada no inventário')
                        groups[identity] = sorted({identity[-1], *(int(v) for v in section.get('nsa', []))})
    for child, parent in parents.items():
        if parent not in groups or child[-1] not in groups[parent]:
            raise InvalidBU('Agregação nsp/nsa inconsistente')
    claimed = {}
    for parent, members in groups.items():
        for member in members:
            child = (*parent[:3], member)
            if child in claimed and claimed[child] != parent:
                raise InvalidBU('Seção pertence a mais de uma unidade de BU')
            claimed[child] = parent
    return groups


def load_core(model_dir, verify=True):
    model_dir = Path(model_dir).resolve()
    path = model_dir / 'coletor.py'
    if verify and hashlib.sha256(path.read_bytes()).hexdigest() != ORIGINAL_COLLECTOR_SHA256:
        raise ValueError('Coletor original mudou. Rever a camada operacional antes de executar.')
    spec = importlib.util.spec_from_file_location('coletor', path)
    core = importlib.util.module_from_spec(spec)
    sys.modules['coletor'] = core
    spec.loader.exec_module(core)
    if str(model_dir) not in sys.path:
        sys.path.insert(0, str(model_dir))
    return core


def collector_class(core):
    class LiveCollector(core.Collector):
        def __init__(self, cfg, state, http):
            super().__init__(cfg, state, http)
            self.accepted = tuple(cfg.get('accepted_hash_statuses', ['Totalizado']))
            if not self.accepted or any(v not in RANK for v in self.accepted):
                raise ValueError('Status de BU não reconhecido')
            self.db.execute('CREATE TABLE IF NOT EXISTS bu_versions '
                '(uf TEXT, cd_mun INTEGER, zona INTEGER, secao INTEGER, hash TEXT, hash_status TEXT, '
                'bu_sha256 TEXT, counts_json TEXT, first_seen TEXT, last_seen TEXT, payload TEXT, '
                'PRIMARY KEY(uf,cd_mun,zona,secao,hash,hash_status))')
            self.db.execute('CREATE TABLE IF NOT EXISTS bu_events '
                '(id INTEGER PRIMARY KEY, utc TEXT, kind TEXT, section_key TEXT, previous TEXT, current TEXT, details TEXT)')
            self.db.execute('CREATE TABLE IF NOT EXISTS discovery_retry '
                '(uf TEXT, cd_mun INTEGER, zona INTEGER, secao INTEGER, next REAL, '
                'PRIMARY KEY(uf,cd_mun,zona,secao))')
            self.db.commit()

        def event(self, kind, identity, previous=None, current=None, details=None):
            self.db.execute('INSERT INTO bu_events(utc,kind,section_key,previous,current,details) VALUES (?,?,?,?,?,?)',
                (core.utc(), kind, json.dumps(identity), json.dumps(previous, ensure_ascii=False),
                 json.dumps(current, ensure_ascii=False), json.dumps(details, ensure_ascii=False)))

        def fetch_section(self, section, old):
            p, u = self.cfg['pleito'], section['uf'].lower()
            m, z, s = (f"{section['cd_mun']:05d}", f"{section['zona']:04d}", f"{section['secao']:04d}")
            base = f"{core.BASE}/ele{self.cfg['year']}/arquivo-urna/{p}/dados/{u}/{m}/{z}/{s}"
            aux = f'{base}/p{p:06d}-{u}-m{m}-z{z}-s{s}-aux.json'
            index_raw = self.http.get(aux)
            index = json.loads(index_raw)
            version = select_hash(index, self.accepted)
            same_hash = old and old.get('hash') == version['hash']
            if old and old.get('hash_status') == 'Totalizado' and version['st'] != 'Totalizado':
                raise StaleIndex('Índice regrediu de Totalizado para Recebido. Último BU válido preservado.')
            if old and not same_hash and old.get('hash_status') == version['st'] == 'Recebido':
                try:
                    previous_date = datetime.strptime(old['source_utc'], '%d/%m/%Y %H:%M:%S')
                    current_date = datetime.strptime(version['dr']+' '+version['hr'], '%d/%m/%Y %H:%M:%S')
                except (KeyError,ValueError) as exc:
                    raise InvalidBU('Revisão Recebido sem cronologia verificável') from exc
                if current_date < previous_date:
                    raise StaleIndex('Índice Recebido mais antigo que o BU ativo. Último BU válido preservado.')
                if current_date == previous_date:
                    raise InvalidBU('Hashes Recebido distintos com o mesmo horário')
            files = [v['nm'] for v in version.get('arq', []) if v.get('tp') == 'bu'] or [
                     v['nm'] for v in version.get('arq', []) if v.get('tp') == 'busa']
            if len(files) != 1 or '/' in files[0]:
                raise InvalidBU('Arquivo de BU ausente ou ambíguo')
            # Mudança de status também baixa novamente o arquivo e verifica sua integridade.
            recheck = (not same_hash or old.get('hash_status') != version['st'] or
                       time.time() - old.get('content_checked_at', 0) >= 900)
            if recheck:
                raw = self.http.get(f"{base}/{version['hash']}/{files[0]}")
                try:
                    row = core.decode_president(raw, self.codec, section, self.cfg)
                except ValueError as exc:
                    raise InvalidBU(str(exc)) from exc
                if same_hash and old.get('bu_sha256') != row['bu_sha256']:
                    raise InvalidBU('Mesmo hash do TSE com bytes diferentes')
                row['content_checked_at'] = time.time()
            else:
                row = dict(old)
            paths = set(old.get('entry_paths', [])) if old else set()
            paths.add('announced' if section['announced'] else 'direct_index')
            return {**row, 'hash':version['hash'], 'hash_status':version['st'],
                'source_utc':(version.get('dr', '')+' '+version.get('hr', '')).strip() or section.get('source_utc', ''),
                'entry_paths':sorted(paths), 'aux_sha256':hashlib.sha256(index_raw).hexdigest(),
                'index_checked_utc':core.utc(), 'index_versions':index.get('hashes', []),
                'aggregation_members':section.get('aggregation_members', [section['secao']])}

        def store_result(self, row, old=None):
            identity = core.key(row)
            counts = json.dumps({k:row[k] for k in COUNTS}, sort_keys=True)
            cached = self.db.execute('SELECT bu_sha256,counts_json FROM bu_versions '
                'WHERE uf=? AND cd_mun=? AND zona=? AND secao=? AND hash=?',
                (*identity, row['hash'])).fetchone()
            if cached and cached != (row['bu_sha256'], counts):
                raise InvalidBU('Versão já registrada com conteúdo contraditório')
            stamp, payload = core.utc(), json.dumps(row, ensure_ascii=False)
            self.db.execute('INSERT INTO bu_versions VALUES (?,?,?,?,?,?,?,?,?,?,?) '
                'ON CONFLICT(uf,cd_mun,zona,secao,hash,hash_status) DO UPDATE SET last_seen=excluded.last_seen',
                (*identity, row['hash'], row['hash_status'], row['bu_sha256'], counts, stamp, stamp, payload))
            different = old is None or any(old.get(k) != row.get(k) for k in (*COUNTS,'hash','hash_status'))
            if different:
                kind = ('added' if old is None else 'confirmed' if
                    old.get('bu_sha256') == row['bu_sha256'] and old.get('hash_status') != row['hash_status'] else
                    'revised' if any(old.get(k) != row[k] for k in COUNTS) else 'new_hash_same_counts')
                self.event(kind, identity, old, row)
            self.db.execute('INSERT OR REPLACE INTO results VALUES (?,?,?,?,?)', (*identity, payload))
            self.db.execute('DELETE FROM discovery_retry WHERE uf=? AND cd_mun=? AND zona=? AND secao=?', identity)
            return different

        def check_inventory(self, inventory, groups):
            keys = {core.key(v) for v in inventory}
            path = self.state / 'inventory.csv'
            previous = keys
            if path.exists():
                with path.open(encoding='utf-8', newline='') as stream:
                    previous = {(v['uf'],int(v['cd_mun']),int(v['zona']),int(v['secao']))
                                for v in csv.DictReader(stream)}
            aggregates = {':'.join(map(str,k)):v for k,v in groups.items() if len(v)>1}
            topo_path = self.state / 'inventory-topology.json'
            old_topology = json.loads(topo_path.read_text()) if topo_path.exists() else aggregates
            changed = [k for k in set(aggregates)|set(old_topology) if aggregates.get(k)!=old_topology.get(k)]
            if keys != previous or changed:
                details = {'utc':core.utc(),'added':[list(k) for k in sorted(keys-previous)],
                    'removed':[list(k) for k in sorted(previous-keys)],
                    'aggregation_changes':{k:{'before':old_topology.get(k),'after':aggregates.get(k)} for k in changed},
                    'action':'Último snapshot preservado. Reconciliar T1 e gerar nova população inicial antes de retomar.'}
                core.atomic(self.state/'inventory-change.json', json.dumps(details, ensure_ascii=False, indent=2))
                raise InvalidBU('Inventário ou agregação mudou. Último snapshot preservado. Consulte inventory-change.json.')
            if not topo_path.exists():
                core.atomic(topo_path,json.dumps(aggregates,sort_keys=True))
            core.write_csv(path,core.FIELDS[:4],inventory)

        def cycle(self, limit=None, checkpoint=None):
            start = time.monotonic()
            old = {tuple(r[:4]):json.loads(r[4]) for r in self.db.execute('SELECT * FROM results')}
            last = {tuple(r[:4]):r[4] for r in self.db.execute('SELECT * FROM attempts')}
            retry = {tuple(r[:4]):r[4] for r in self.db.execute('SELECT * FROM discovery_retry')}
            inventory, groups, failures, okay_ufs = [], {}, [], []
            for uf in self.cfg['ufs']:
                try:
                    doc = json.loads(self.http.get(self.config_url(uf)))
                    if int(doc['cdp']) != self.cfg['pleito']:
                        raise InvalidBU('Inventário de outro pleito')
                    current_groups = topology(doc)
                    current = core.sections(doc)
                    for section in current:
                        section['aggregation_members'] = current_groups[core.key(section)]
                    inventory.extend(current);groups.update(current_groups);okay_ufs.append(uf)
                except Exception as exc:
                    failures.append({'uf':uf,'error':str(exc)})
            try:
                if set(okay_ufs) != set(self.cfg['ufs']):
                    raise InvalidBU('Inventário incompleto. Último snapshot preservado: '+json.dumps(failures))
                self.check_inventory(inventory,groups)
            except InvalidBU as exc:
                status_path = self.state/'status.json'
                previous_status = json.loads(status_path.read_text()) if status_path.exists() else {}
                core.atomic(status_path,json.dumps({**previous_status,'utc':core.utc(),'blocked':True,
                    'errors':[{'error':str(exc)}]},ensure_ascii=False,indent=2))
                raise
            now = time.time()
            def due(section):
                identity = core.key(section)
                delay = 900 if old.get(identity,{}).get('hash_status') == 'Totalizado' else 60
                return now-last.get(identity,0)>=delay
            due_rows = [v for v in inventory if due(v)]
            def spatial(section):
                return hashlib.blake2b(str(core.key(section)).encode(),digest_size=8).digest()
            audits = sorted((v for v in due_rows if core.key(v) in old),key=lambda v:(last.get(core.key(v),0),spatial(v)))
            fresh = sorted((v for v in due_rows if core.key(v) not in old and v['announced']),
                           key=lambda v:(last.get(core.key(v),0),spatial(v)))
            scope = set(self.cfg.get('direct_index_ufs', []))
            priority = set(self.cfg.get('direct_index_priority_municipalities', []))
            discovery = sorted((v for v in due_rows if core.key(v) not in old and not v['announced'] and
                                 v['uf'] in scope and retry.get(core.key(v),0)<=now),
                               key=lambda v:(v['cd_mun'] not in priority,last.get(core.key(v),0),spatial(v)))
            budget = self.cfg['max_sections_per_cycle'] if limit is None else limit
            direct_limit = max(0,int(self.cfg.get('direct_index_sections_per_cycle',0)))
            reserve = max(1,budget//10)
            chosen = (audits[:reserve]+discovery[:direct_limit]+fresh)[:budget]
            used = {core.key(v) for v in chosen}
            for section in audits[reserve:]:
                if len(chosen) >= budget:
                    break
                if core.key(section) not in used:
                    chosen.append(section)
            added=changed=confirmed=removed=missing=0
            def worker(section):
                try:return section,self.fetch_section(section,old.get(core.key(section))),None
                except Exception as exc:return section,None,exc
            with cf.ThreadPoolExecutor(max_workers=self.cfg['workers']) as pool:
                for number,(section,row,error) in enumerate(pool.map(worker,chosen),1):
                    identity=core.key(section)
                    self.db.execute('INSERT OR REPLACE INTO attempts VALUES (?,?,?,?,?)',(*identity,time.time()))
                    previous=old.get(identity)
                    if error is not None:
                        if 'HTTP 404:' in str(error) and previous is None and not section['announced']:
                            missing+=1
                            self.db.execute('INSERT OR REPLACE INTO discovery_retry VALUES (?,?,?,?,?)',
                                (*identity,time.time()+self.cfg.get('direct_index_missing_retry_seconds',900)))
                        else:
                            failures.append({'key':identity,'error':str(error)})
                            if isinstance(error,StaleIndex):
                                self.event('stale_index_held',identity,previous,details=str(error))
                            if isinstance(error,InvalidBU):
                                self.event('quarantined',identity,previous,details=str(error))
                                self.db.execute('DELETE FROM results WHERE uf=? AND cd_mun=? AND zona=? AND secao=?',identity)
                                removed+=int(previous is not None)
                    else:
                        try:
                            self.store_result(row,previous)
                            added+=int(previous is None)
                            changed+=int(previous is not None and any(previous.get(k)!=row[k] for k in COUNTS))
                            confirmed+=int(previous is not None and previous.get('hash_status')!=row['hash_status'])
                        except InvalidBU as exc:
                            failures.append({'key':identity,'error':str(exc)})
                            self.event('quarantined',identity,previous,details=str(exc))
                            self.db.execute('DELETE FROM results WHERE uf=? AND cd_mun=? AND zona=? AND secao=?',identity)
                            removed+=int(previous is not None)
                    self.db.commit()
                    if checkpoint and number%500==0:
                        self.export(); self.fetch_official()
                        core.atomic(self.state/'status.json',json.dumps({'utc':core.utc(),'cycle_in_progress':True,'errors':failures}))
                        checkpoint()
            rows=self.export();official=self.fetch_official()
            result={'utc':core.utc(),'policy_version':POLICY_VERSION,'accepted_hash_statuses':list(self.accepted),
                'inventory_ufs':okay_ufs,'inventory_sections':len(inventory),'collected_sections':len(rows),
                'received_sections':sum(v.get('hash_status')=='Recebido' for v in rows),
                'totalized_sections':sum(v.get('hash_status')=='Totalizado' for v in rows),
                'added':added,'changed':changed,'confirmed':confirmed,'removed':removed,
                'requested_sections':len(chosen),'direct_index_missing':missing,
                'duration_seconds':time.monotonic()-start,'official_current':official is not None,'errors':failures}
            core.atomic(self.state/'status.json',json.dumps(result,ensure_ascii=False,indent=2))
            logging.info('%s BUs ativos, +%s, %s revisões, %s confirmações, %s erros',len(rows),added,changed,confirmed,len(failures))
            return result
    return LiveCollector


def main():
    parser=argparse.ArgumentParser(add_help=False)
    parser.add_argument('--model-dir',type=Path,required=True)
    args,remaining=parser.parse_known_args()
    core=load_core(args.model_dir)
    core.Collector=collector_class(core)
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    sys.argv=[str(args.model_dir/'coletor.py'),*remaining]
    core.main()


if __name__=='__main__':
    main()
