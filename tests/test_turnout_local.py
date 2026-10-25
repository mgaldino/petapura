"""O acompanhamento experimental é local e sua API não controla o pipeline."""
from functools import partial
import json
from pathlib import Path
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from run_turnout_local import TurnoutHandler
import test_local_pipeline as baseline_tests


class TurnoutHTTPTests(baseline_tests.LocalHTTPTests):
    def setUp(self):
        super().setUp()
        self.server.RequestHandlerClass=partial(TurnoutHandler,directory=str(self.web))
        self.pipeline.report={'kind':'pet_local_turnout_uf','coefficients':86,
                              'national':{'learning':{'share':48.1}}}

    def test_only_json_same_origin_control_is_accepted(self):
        status,_,_=self.request('/api/control','POST',{'Content-Type':'application/json'},'{"action":"next"}')
        self.assertEqual(status,405)
        self.assertEqual(self.calls,[])

    def test_invalid_control_payloads_do_not_reach_pipeline(self):
        for body in ['not json','[]','{"action":"next"}','x'*257]:
            self.assertEqual(self.request('/api/control','POST',{'Content-Type':'application/json'},body)[0],405)
        self.assertEqual(self.calls,[])

    def test_report_is_same_origin_read_only_and_uncached(self):
        status,headers,body=self.request('/api/report')
        self.assertEqual(status,200)
        self.assertEqual(headers['Cache-Control'],'no-store')
        self.assertEqual(json.loads(body),self.pipeline.report)
        self.assertEqual(self.request('/api/report',headers={'Origin':'https://foreign.example'})[0],403)
        self.assertEqual(self.request('/api/report','POST',{'Content-Type':'application/json'},'{}')[0],405)

    def test_missing_report_is_explicitly_unavailable(self):
        self.pipeline.report=None
        self.assertEqual(self.request('/api/report')[0],503)
