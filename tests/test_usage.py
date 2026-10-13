import base64
import json
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from usage import external_auth, normalize_limits, normalize_activity, read_usage


class UsageTests(unittest.TestCase):
    credential = {'tokens': {'access_token': 'fixture-access', 'account_id': 'fixture-account',
                             'refresh_token': 'must-not-be-sent'}}

    def server(self, body):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / 'codex'
        path.write_text('''#!/usr/bin/env python3
import sys,json,os
from pathlib import Path
assert 'cli_auth_credentials_store="ephemeral"' in sys.argv
assert not Path(os.environ['CODEX_HOME'],'auth.json').exists()
assert Path.cwd().resolve() == Path(os.environ['CODEX_HOME']).resolve()
assert 'fixture-access' not in str(sys.argv)
for line in sys.stdin:
 r=json.loads(line)
 assert 'must-not-be-sent' not in line
 if r['method']=='initialize':
  assert r['params']['capabilities']['experimentalApi']
  print(json.dumps({'id':r['id'],'result':{}}),flush=True)
 elif r['method']=='account/login/start':
  assert r['params']=={'type':'chatgptAuthTokens','accessToken':'fixture-access','chatgptAccountId':'fixture-account'}
  print(json.dumps({'id':r['id'],'result':{}}),flush=True)
''' + body)
        path.chmod(0o700)
        return path

    def test_limits_without_token_activity_and_no_refresh_token_transmission(self):
        binary = self.server(''' elif r['method']=='account/rateLimits/read':
  print(json.dumps({'id':r['id'],'result':{'rateLimits':{'primary':{'usedPercent':25,'windowDurationMins':300,'resetsAt':2000000000}}}}),flush=True)
 elif r['method']=='account/usage/read':
  print(json.dumps({'id':r['id'],'error':{'message':'private server detail'}}),flush=True)
''')
        result = read_usage(self.credential, binary=binary, timeout=2)
        self.assertEqual(result['status'], 'available')
        self.assertEqual(result['windows'][0]['remainingPercent'], 75)
        self.assertEqual(result['activity'], {})
        self.assertNotIn('fixture-access', str(result))
        self.assertNotIn('private server detail', str(result))

    def test_refresh_request_requires_login(self):
        binary = self.server(''' elif r['method']=='account/rateLimits/read':
  print(json.dumps({'id':99,'method':'account/chatgptAuthTokens/refresh','params':{}}),flush=True)
''')
        with self.assertRaises(PermissionError):
            read_usage(self.credential, binary=binary, timeout=2)

    def test_expired_token_is_rejected_before_launch(self):
        body = base64.urlsafe_b64encode(json.dumps({'exp':1}).encode()).decode().rstrip('=')
        with self.assertRaises(PermissionError):
            external_auth({'tokens': {'access_token': 'x.'+body+'.x', 'account_id':'fixture'}})

    def test_numeric_validation_and_allowlist(self):
        result = normalize_limits({'rateLimitsByLimitId': {'codex': {
            'primary': {'usedPercent':130}, 'secondary': {'usedPercent':float('nan')}}}})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['remainingPercent'], 0)
        self.assertEqual(normalize_activity({'summary': {'lifetimeTokens': 123, 'peakDailyTokens': -1,
                                                         'private': 'hidden'}}), {'lifetimeTokens':123})

    def test_unsupported_usage_is_not_zero_remaining(self):
        binary = self.server(''' elif r['method'] in ['account/rateLimits/read','account/usage/read']:
  print(json.dumps({'id':r['id'],'result':{}}),flush=True)
''')
        result = read_usage(self.credential, binary=binary, timeout=2)
        self.assertEqual(result['status'], 'unavailable')
        self.assertEqual(result['windows'], [])

if __name__ == '__main__':
    unittest.main()
