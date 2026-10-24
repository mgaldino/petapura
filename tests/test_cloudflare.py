from copy import deepcopy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from contract import read_json
from run_cloudflare import upload


class CloudflarePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name)
        self.config = read_json(ROOT / 'web/config.json')
        self.snapshot = read_json(ROOT / 'tests/fixtures/prior.json')
        self.snapshot['forecast_2022'] = deepcopy(self.snapshot['forecast'])

    def test_upload_sends_exact_validated_snapshot_to_remote_binding(self):
        with patch('run_cloudflare.subprocess.run') as command:
            upload(self.snapshot, self.runtime, self.config, '/tools/wrangler')
        self.assertEqual(read_json(self.runtime / 'cloudflare-upload.json'), self.snapshot)
        args = command.call_args.args[0]
        self.assertEqual(args[:5], ['/tools/wrangler', 'kv', 'key', 'put', 'latest'])
        self.assertIn('--remote', args)
        self.assertEqual(args[args.index('--binding') + 1], 'SNAPSHOTS')

    def test_invalid_or_synthetic_snapshot_never_reaches_cloudflare(self):
        for mutate in (lambda s:s.update(forecast_2022=None),lambda s:s['election'].update(election_id='outra'),lambda s:s.update(mode='demo')):
            s=deepcopy(self.snapshot);mutate(s)
            with patch('run_cloudflare.subprocess.run') as command, self.assertRaises(ValueError):
                upload(s,self.runtime,self.config,'/tools/wrangler')
            command.assert_not_called()

    def test_remote_failure_is_reported_without_deleting_retry_input(self):
        with patch('run_cloudflare.subprocess.run',side_effect=subprocess.CalledProcessError(1,'wrangler')):
            with self.assertRaises(subprocess.CalledProcessError):
                upload(self.snapshot,self.runtime,self.config,'/tools/wrangler')
        self.assertEqual(read_json(self.runtime / 'cloudflare-upload.json'), self.snapshot)
