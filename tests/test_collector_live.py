"""Exercícios de duplicação, revisão e agregação da entrada operacional."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import collector_live as live

core=live.load_core(ROOT/'modelo')
Collector=live.collector_class(core)
CFG={**json.loads((ROOT/'deployment/collector-2026.json').read_text()),'ufs':['AC'],
     'accepted_hash_statuses':['Totalizado','Recebido'],'direct_index_ufs':['AC'],
     'direct_index_sections_per_cycle':10,'workers':2}
SECTION={'uf':'AC','cd_mun':1007,'zona':9,'secao':1,'announced':False}


def bulletin(a=40,b=45):
    return {'identificacaoSecao':{'municipioZona':{'municipio':1007,'zona':9},'secao':1},
        'resultadosVotacaoPorEleicao':[{'idEleicao':6258,'qtdEleitoresAptos':100,
            'resultadosVotacao':[{'qtdComparecimento':a+b+5,'totaisVotosCargo':[{
                'codigoCargo':['constitucional','presidente'],'votosVotaveis':[
                    {'tipoVoto':'nominal','identificacaoVotavel':{'codigo':13},'quantidadeVotos':a},
                    {'tipoVoto':'nominal','identificacaoVotavel':{'codigo':22},'quantidadeVotos':b},
                    {'tipoVoto':'branco','quantidadeVotos':2},{'tipoVoto':'nulo','quantidadeVotos':3}]}]}]}]}


def version(identity='hash1',status='Recebido',hour='01:51:38'):
    return {'hash':identity,'st':status,'dr':'25/10/2026','hr':hour,'arq':[{'tp':'bu','nm':'bu.dat'}]}


class Codec:
    def decode(self,kind,raw):
        return {'conteudo':raw} if kind=='EntidadeEnvelopeGenerico' else json.loads(raw)


class HTTP:
    def __init__(self):
        self.versions=[version()];self.bu=bulletin();self.missing=False;self.announced=False;self.urls=[]
        self.sections=[{'ns':'0001'}]
    def get(self,url):
        self.urls.append(url)
        if '/config/' in url:
            sections=copy.deepcopy(self.sections)
            if self.announced:sections[0].update(da='25/10/2026',ha='02:00:00')
            return json.dumps({'cdp':3221,'abr':[{'cd':'ac','mu':[{'cd':'01007','zon':[
                {'cd':'0009','sec':sections}]}]}]}).encode()
        if '-aux.json' in url:
            if self.missing:raise RuntimeError('HTTP 404: '+url)
            return json.dumps({'hashes':self.versions}).encode()
        return json.dumps(self.bu,sort_keys=True).encode()


class TestSelection(unittest.TestCase):
    def test_received_and_totalized_priority(self):
        self.assertEqual(live.select_hash({'hashes':[version()]})['st'],'Recebido')
        self.assertEqual(live.select_hash({'hashes':[version(),version('official','Totalizado')]})['hash'],'official')
    def test_same_version_in_two_entries_is_one(self):
        v=version();self.assertEqual(live.select_hash({'hashes':[v,copy.deepcopy(v)]}),v)
    def test_multiple_received_choose_latest(self):
        self.assertEqual(live.select_hash({'hashes':[version('old'),version('new',hour='02:00:00')]})['hash'],'new')
    def test_conflicting_totalized_rejected(self):
        with self.assertRaises(live.InvalidBU):live.select_hash({'hashes':[version('x','Totalizado'),version('y','Totalizado')]})
    def test_received_tie_rejected(self):
        with self.assertRaises(live.InvalidBU):live.select_hash({'hashes':[version('x'),version('y')]})
    def test_unknown_status_and_path_rejected(self):
        for v in [version(status='Cancelado'),version('../bad')]:
            with self.assertRaises(live.InvalidBU):live.select_hash({'hashes':[v]})
    def test_totalized_only_policy_remains_available(self):
        with self.assertRaises(live.InvalidBU):live.select_hash({'hashes':[version()]},('Totalizado',))


class TestLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.http=HTTP()
        with mock.patch('asn1tools.compile_files',return_value=Codec()):
            self.collector=Collector(CFG,self.tmp.name,self.http)
        self.addCleanup(self.collector.close)
        self.collector.fetch_official=lambda:None
    def cycle(self):
        self.collector.db.execute('UPDATE attempts SET last=0');self.collector.db.commit()
        return self.collector.cycle()
    def rows(self):return self.collector.export()
    def test_discovery_repeat_announcement_and_confirmation_never_duplicate(self):
        self.assertEqual(self.cycle()['added'],1)
        first=self.rows()[0]
        self.assertEqual(self.cycle()['added'],0)
        self.http.announced=True
        self.cycle()
        self.assertEqual(self.rows()[0]['entry_paths'],['announced','direct_index'])
        self.http.versions=[version(status='Totalizado')]
        status=self.cycle()
        self.assertEqual((status['added'],status['changed'],status['confirmed']),(0,0,1))
        self.assertEqual(len(self.rows()),1)
        self.assertEqual(self.rows()[0]['bu_sha256'],first['bu_sha256'])
        self.assertEqual(self.collector.db.execute('SELECT count(*) FROM bu_versions').fetchone()[0],2)
    def test_revision_replaces_counts(self):
        self.cycle();self.http.versions=[version('hash2',hour='02:00:00')];self.http.bu=bulletin(45,40)
        self.assertEqual(self.cycle()['changed'],1)
        self.assertEqual([(r['votos_a'],r['votos_b']) for r in self.rows()],[(45,40)])
        self.assertEqual(self.collector.db.execute('SELECT count(*) FROM bu_versions').fetchone()[0],2)
    def test_older_received_does_not_roll_back(self):
        self.http.versions=[version(hour='02:00:00')];self.cycle()
        self.http.versions=[version('older',hour='01:00:00')];self.http.bu=bulletin(20,65)
        self.assertTrue(self.cycle()['errors']);self.assertEqual(self.rows()[0]['votos_a'],40)
    def test_status_regression_holds_last_valid(self):
        self.http.versions=[version(status='Totalizado')];self.cycle()
        self.http.versions=[version()]
        self.assertTrue(self.cycle()['errors']);self.assertEqual(self.rows()[0]['hash_status'],'Totalizado')
    def test_ambiguous_index_quarantines_active_row(self):
        self.cycle();self.http.versions=[version('x','Totalizado'),version('y','Totalizado')]
        self.assertEqual(self.cycle()['removed'],1);self.assertEqual(self.rows(),[])
    def test_identical_hash_with_changed_bytes_remains_quarantined(self):
        self.cycle();self.http.versions=[version(status='Totalizado')];self.http.bu=bulletin(45,40)
        self.assertEqual(self.cycle()['removed'],1)
        self.assertTrue(self.cycle()['errors']);self.assertEqual(self.rows(),[])
    def test_wrong_internal_section_rejected(self):
        self.http.bu['identificacaoSecao']['secao']=2
        self.assertTrue(self.cycle()['errors']);self.assertEqual(self.rows(),[])
    def test_wrong_election_rejected(self):
        self.http.bu['resultadosVotacaoPorEleicao'][0]['idEleicao']=6257
        self.assertTrue(self.cycle()['errors']);self.assertEqual(self.rows(),[])
    def test_invalid_accounting_rejected(self):
        self.http.bu['resultadosVotacaoPorEleicao'][0]['resultadosVotacao'][0]['qtdComparecimento']=99
        self.assertTrue(self.cycle()['errors']);self.assertEqual(self.rows(),[])
    def test_network_failure_preserves_last_valid(self):
        self.cycle();self.http.missing=True
        self.assertTrue(self.cycle()['errors']);self.assertEqual(len(self.rows()),1)
    def test_missing_discovery_has_backoff_and_announcement_bypasses_it(self):
        self.http.missing=True;self.assertEqual(self.cycle()['direct_index_missing'],1)
        self.assertEqual(self.cycle()['requested_sections'],0)
        self.http.missing=False;self.http.announced=True
        self.assertEqual(self.cycle()['added'],1)
    def test_discovery_scope_and_budget(self):
        self.collector.cfg={**CFG,'direct_index_ufs':['ZZ']}
        self.assertEqual(self.cycle()['requested_sections'],0)
        self.collector.cfg=CFG
        self.assertEqual(self.collector.cycle(limit=0)['requested_sections'],0)
    def test_inventory_change_preserves_previous_export(self):
        self.cycle();before=(Path(self.tmp.name)/'observed.csv').read_bytes()
        self.http.sections.append({'ns':'0002'})
        with self.assertRaises(live.InvalidBU):self.cycle()
        self.assertEqual((Path(self.tmp.name)/'observed.csv').read_bytes(),before)
        self.assertTrue(json.loads((Path(self.tmp.name)/'status.json').read_text())['blocked'])
    def test_aggregation_change_is_detected(self):
        self.cycle();self.http.sections=[{'ns':'0001','nsa':['0002']},{'ns':'0002','nsp':'0001'}]
        with self.assertRaises(live.InvalidBU):self.cycle()


class TestAggregation(unittest.TestCase):
    def document(self,sections):return {'abr':[{'cd':'zz','mu':[{'cd':'30805','zon':[{'cd':'0001','sec':sections}]}]}]}
    def test_parent_only_and_members_preserved(self):
        d=self.document([{'ns':'0001','nsa':['0002']},{'ns':'0002','nsp':'0001'}])
        self.assertEqual(live.topology(d),{('ZZ',30805,1,1):[1,2]})
        self.assertEqual(len(core.sections(d)),1)
    def test_orphan_child_rejected(self):
        with self.assertRaises(live.InvalidBU):live.topology(self.document([{'ns':'0002','nsp':'0001'}]))
    def test_child_in_two_parents_rejected(self):
        with self.assertRaises(live.InvalidBU):live.topology(self.document([
            {'ns':'0001','nsa':['0003']},{'ns':'0002','nsa':['0003']},{'ns':'0003','nsp':'0001'}]))


if __name__=='__main__':unittest.main(verbosity=2)
