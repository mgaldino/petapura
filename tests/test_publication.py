from copy import deepcopy
from pathlib import Path
import fcntl
import hashlib
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from contract import ContractError, publish, read_json, validate
from import_tse import adapt, read_selected

CONFIG=read_json(ROOT/'web/config.json')
def fixture(name='live-95'):
    return read_json(ROOT/f'tests/fixtures/{name}.json')

class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.output=self.root/'latest.json'
    def tearDown(self):
        self.temp.cleanup()
    def test_fixtures(self):
        for name in ['waiting','live-95','prior','complete']:
            with self.subTest(name=name):validate(fixture(name),CONFIG)
    def test_idempotent(self):
        one,changed=publish(fixture(),self.output,CONFIG)
        raw=self.output.read_bytes()
        two,changed2=publish(fixture(),self.output,CONFIG)
        self.assertTrue(changed);self.assertFalse(changed2)
        self.assertEqual(one,two);self.assertEqual(raw,self.output.read_bytes())
    def test_invalid_preserves_last_valid(self):
        publish(fixture(),self.output,CONFIG);raw=self.output.read_bytes()
        bad=fixture();bad['counting']['valid_votes']+=1
        with self.assertRaises(ContractError):publish(bad,self.output,CONFIG)
        self.assertEqual(raw,self.output.read_bytes())
    def test_corrected_snapshot_may_reduce_progress(self):
        first,_=publish(fixture(),self.output,CONFIG)
        s=fixture();s['snapshot_id']='correcao';s['generated_at']='2026-10-25T23:31:00Z'
        s['counting']['reported_sections']=6000
        second,_=publish(s,self.output,CONFIG)
        self.assertEqual(second['history'][-1]['reported_sections'],6000)
        self.assertEqual(len(second['history']),len(first['history'])+1)
    def test_old_snapshot_rejected(self):
        s=fixture();s['snapshot_id']='novo';s['generated_at']='2026-10-25T23:31:00Z';publish(s,self.output,CONFIG)
        with self.assertRaises(ContractError):publish(fixture(),self.output,CONFIG)
    def test_same_id_different_content_rejected(self):
        publish(fixture(),self.output,CONFIG)
        s=fixture();s['forecast']['share_a']=52
        with self.assertRaises(ContractError):publish(s,self.output,CONFIG)
    def test_wrong_election_rejected(self):
        s=fixture();s['election']['round']=1
        with self.assertRaises(ContractError):validate(s,CONFIG)
    def test_probability_not_derived(self):
        s,_=publish(fixture(),self.output,CONFIG)
        self.assertIsNone(s['forecast']['win_probability_a'])
        self.assertEqual(s['forecast']['interval']['level'],.95)
    def test_real_endpoint_cannot_change_to_demo(self):
        publish(fixture(),self.output,CONFIG)
        s=read_json(ROOT/'web/demo/snapshots.json')[1]
        with self.assertRaises(ContractError):publish(s,self.output,CONFIG)
    def test_atomic_failure_preserves_previous(self):
        publish(fixture(),self.output,CONFIG);raw=self.output.read_bytes()
        s=fixture();s['snapshot_id']='novo';s['generated_at']='2026-10-25T23:31:00Z'
        with patch('contract.os.replace',side_effect=OSError('falha simulada')):
            with self.assertRaises(OSError):publish(s,self.output,CONFIG)
        self.assertEqual(raw,self.output.read_bytes())
        self.assertEqual(list(self.root.glob('.latest.json.*')),[self.root/'.latest.json.lock'])
    def test_single_writer_lock(self):
        with (self.root/'.latest.json.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(ContractError):publish(fixture(),self.output,CONFIG)
    def test_private_fields_rejected(self):
        s=fixture();s['forecast']['posterior']=[1,2]
        with self.assertRaises(ContractError):validate(s,CONFIG)
    def test_boolean_not_count(self):
        s=fixture();s['counting']['reported_sections']=True
        with self.assertRaises(ContractError):validate(s,CONFIG)

class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        chosen={'ts':10000,'st':6520,'votos_a':3233920,'votos_b':3286080,'validos':6520000,'area':'BR','generated':'2026-10-25T20:30:00'}
        raw=json.dumps({'chosen':chosen}).encode();(self.root/'selected.json').write_bytes(raw)
        self.manifest={'schema_version':1,'snapshot_id':'test-source','mode':'observed_data_only',
            'published_utc':'2026-10-25T23:30:00+00:00','identity':{'year':2026,'round':2,'election':6258,'pleito':3221},
            'candidate_columns':{'votos_a':13,'votos_b':22},'observed_sections':6500,'official_source_selected':'BR',
            'files':{'official_selected.json':{'path':'selected.json','sha256':hashlib.sha256(raw).hexdigest()}}}
        self.save_manifest()
    def save_manifest(self):
        (self.root/'manifest.json').write_text(json.dumps(self.manifest))
    def tearDown(self):self.temp.cleanup()
    def test_observed_only_import(self):
        s=adapt(self.root,CONFIG,{'a':'A','b':'B'})
        self.assertIsNone(s['forecast']);self.assertEqual(s['counting']['votes_a'],3233920)
        self.assertEqual(s['generated_at'],'2026-10-25T23:30:00Z')
        self.assertEqual(s['counting']['source']['generated_raw'],'2026-10-25T20:30:00')
    def test_forecast_same_snapshot(self):
        f=fixture()['forecast'];f['source_snapshot_id']='test-source'
        s=adapt(self.root,CONFIG,{'a':'A','b':'B'},f)
        self.assertEqual(s['forecast']['interval']['level'],.95)
    def test_forecast_wrong_snapshot(self):
        with self.assertRaises(ContractError):adapt(self.root,CONFIG,{'a':'A','b':'B'},fixture()['forecast'])
    def test_bad_hash(self):
        (self.root/'selected.json').write_text('{}')
        with self.assertRaises(ContractError):read_selected(self.root)
    def test_path_traversal(self):
        self.manifest['files']['official_selected.json']['path']='../fora.json';self.save_manifest()
        with self.assertRaises(ContractError):read_selected(self.root)
    def test_no_double_counting(self):
        raw=json.dumps({'chosen':{'ts':10000,'st':10,'votos_a':70,'votos_b':30,'validos':100,'area':'SOMA_UFS'},'national':{'votos_a':7000},'sum_ufs':{'votos_a':70}}).encode()
        (self.root/'selected.json').write_bytes(raw);self.manifest['files']['official_selected.json']['sha256']=hashlib.sha256(raw).hexdigest();self.manifest['official_source_selected']='SOMA_UFS';self.save_manifest()
        s=adapt(self.root,CONFIG,{'a':'A','b':'B'});self.assertEqual(s['counting']['votes_a'],70)

if __name__=='__main__':unittest.main()
