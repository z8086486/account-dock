import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from doctor import summarize


class AccountSummaryTests(unittest.TestCase):
    def test_tokens_never_leak_and_email_is_hidden(self):
        result = summarize({'account': {'type': 'chatgpt', 'email': 'test@example.com',
                            'accessToken': 'secret', 'planType': 'plus'}})
        self.assertNotIn('secret', str(result))
        self.assertNotIn('test@example.com', str(result))

    def test_missing_response_is_not_signed_out(self):
        with self.assertRaises(ValueError):
            summarize({})
        self.assertEqual(summarize({'account': None})['status'], 'signed_out')

    def test_api_key_has_no_email(self):
        self.assertEqual(summarize({'account': {'type': 'apiKey'}}),
                         {'status': 'cached_account', 'type': 'apiKey'})




class ProtocolTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)

    def server(self, source):
        path = self.home / 'fake-codex'
        path.write_text('#!/usr/bin/env python3\n' + source)
        path.chmod(0o700)
        return path

    def test_logout_protocol(self):
        from doctor import read_account
        binary = self.server('''import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if r['method']=='initialize': print(json.dumps({'id':r['id'],'result':{}}),flush=True)
 if r['method']=='account/logout': print(json.dumps({'id':r['id'],'result':{}}),flush=True)
''')
        self.assertEqual(read_account(binary, self.home, action='logout'), {'status': 'signed_out'})

    def test_login_opens_official_url_and_waits_for_completion(self):
        from doctor import read_account
        from unittest.mock import patch
        binary = self.server('''import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if r['method']=='initialize': print(json.dumps({'id':r['id'],'result':{}}),flush=True)
 if r['method']=='account/login/start':
  print(json.dumps({'id':r['id'],'result':{'authUrl':'https://auth.openai.com/test'}}),flush=True)
  print(json.dumps({'method':'account/login/completed','params':{'success':True}}),flush=True)
''')
        with patch('doctor.subprocess.run') as launch:
            self.assertEqual(read_account(binary, self.home, action='login'), {'status':'login_completed'})
            self.assertEqual(launch.call_args.args[0], ['/usr/bin/open','https://auth.openai.com/test'])

    def test_untrusted_login_url_is_rejected(self):
        from doctor import read_account
        from unittest.mock import patch
        binary = self.server('''import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if 'id' in r: print(json.dumps({'id':r['id'],'result':{'authUrl':'https://example.com'}}),flush=True)
''')
        with patch('doctor.subprocess.run') as launch:
            with self.assertRaises(RuntimeError):
                read_account(binary, self.home, action='login')
            launch.assert_not_called()

    def test_timeout(self):
        from doctor import read_account
        binary = self.server('import time\ntime.sleep(10)\n')
        with self.assertRaises(TimeoutError):
            read_account(binary, self.home, timeout=0.1)

    def test_keyring_and_invalid_configuration_disable_file_presets(self):
        from doctor import file_presets_supported
        for text in ['cli_auth_credentials_store="keyring"', 'invalid [']:
            (self.home / 'config.toml').write_text(text)
            self.assertFalse(file_presets_supported(self.home))


if __name__ == '__main__':
    unittest.main()
