import base64
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from app_accounts import collect, parse_process_arguments, stored_identity, store_home, DESKTOP, VSCODE


class AppAccountTests(unittest.TestCase):
    def test_process_environment_keeps_only_auth_home_paths(self):
        raw = struct.pack('i', 2) + b'/path/codex\0\0/path/codex\0app-server\0HOME=/Users/test\0CODEX_HOME=/separate/home\0API_KEY=private\0'
        argv, env = parse_process_arguments(raw)
        self.assertEqual(argv, ['/path/codex', 'app-server'])
        self.assertEqual(env, {'HOME':'/Users/test', 'CODEX_HOME':'/separate/home'})
        self.assertNotIn('private', str(env))

    def test_separate_app_stores_are_not_replaced_by_manager_home(self):
        desktop = DESKTOP + 'Resources/codex-cli/bin/codex'
        extension = '/Users/test/.vscode/extensions/openai.chatgpt-1.2.3-darwin-arm64/bin/macos-aarch64/codex'
        table = {1:(0,DESKTOP+'MacOS/ChatGPT'), 2:(1,desktop), 3:(0,VSCODE+'MacOS/Code'),
                 4:(3,VSCODE+'Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)'),
                 5:(4,extension), 6:(99,extension)}
        def args(pid):
            return ['codex','app-server'], {'CODEX_HOME': '/desktop-auth' if pid==2 else '/vscode-auth'}
        def identity(home):
            return {'status':'stored_account','email':home[1:]+'@example.com'}
        result = collect(table, args, identity)['accounts']
        self.assertEqual(len(result), 2)
        self.assertEqual({x['email'] for x in result}, {'desktop-auth@example.com','vscode-auth@example.com'})
        self.assertTrue(all(x['status']=='stored_account' for x in result))

    def test_process_denied_and_stopped_apps_do_not_inherit_shared_identity(self):
        table = {1:(0,DESKTOP+'MacOS/ChatGPT'), 2:(1,DESKTOP+'Resources/codex-cli/bin/codex')}
        def denied(pid): raise PermissionError()
        result = collect(table, denied, lambda _: self.fail('must not read guessed home'))['accounts']
        self.assertEqual([x['status'] for x in result], ['unavailable','not_running'])
        self.assertFalse(any('email' in x for x in result))

    def test_unsupported_auth_override_is_not_reported_as_file_account(self):
        with self.assertRaises(ValueError):
            store_home(['codex','-c','cli_auth_credentials_store="ephemeral"','app-server'],{'HOME':'/Users/test'})
        self.assertIsNone(store_home(['codex','exec'],{'HOME':'/Users/test'}))
        with self.assertRaises(ValueError):
            store_home(['codex','app-server'],{})

    def test_cached_identity_is_read_without_mutation_or_token_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'auth.json'
            payload = base64.urlsafe_b64encode(json.dumps({'email':'fixture@example.com','https://api.openai.com/auth':{'chatgpt_plan_type':'plus'}}).encode()).decode()
            raw = json.dumps({'tokens':{'id_token':'x.'+payload+'.x','refresh_token':'private-token'}}).encode()
            path.write_bytes(raw)
            result = stored_identity(directory)
            self.assertEqual(result,{'status':'stored_account','email':'fixture@example.com','plan':'plus'})
            self.assertEqual(path.read_bytes(),raw)
            self.assertNotIn('private-token',str(result))
            path.unlink()
            self.assertEqual(stored_identity(directory)['status'],'no_saved_auth')

if __name__=='__main__': unittest.main()
