import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import versions


class VersionTests(unittest.TestCase):
    def test_numeric_comparison_not_lexicographic(self):
        self.assertTrue(versions.newer('26.1007.100', '26.1007.99'))
        self.assertFalse(versions.newer('1.2', '1.2.0'))
        self.assertFalse(versions.newer('1.2.0-beta', '1.1'))

    def test_marketplace_excludes_other_publishers_platforms_and_prereleases(self):
        entries = [{'version': '1.0.0', 'targetPlatform': 'darwin-arm64'},
                   {'version': '9.0.0', 'targetPlatform': 'win32-x64'},
                   {'version': '8.0.0', 'targetPlatform': 'darwin-arm64', 'properties': [{'key': 'Microsoft.VisualStudio.Code.PreRelease', 'value': 'true'}]}]
        data = {'results': [{'extensions': [
            {'publisher': {'publisherName': 'openai'}, 'extensionName': 'chatgpt', 'versions': entries},
            {'publisher': {'publisherName': 'other'}, 'extensionName': 'chatgpt', 'versions': [{'version': '99.0.0'}]}
        ]}]}
        self.assertEqual(versions.parse_marketplace(json.dumps(data), 'darwin-arm64'), '1.0.0')

    def test_sparkle_short_version_from_element_or_attribute(self):
        data = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:shortVersionString>26.9.9</sparkle:shortVersionString></item>
        <item><enclosure sparkle:shortVersionString="26.10.1"/></item></channel></rss>'''
        self.assertEqual(versions.parse_chatgpt_feed(data), '26.10.1')

    def test_unavailable_feed_is_not_reported_up_to_date(self):
        with patch('versions.fetch', side_effect=OSError('offline')):
            self.assertEqual(versions.latest('chatgpt'), {'latest': None, 'check': 'unavailable'})

    def test_index_selects_version_not_old_leftover_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'extensions.json').write_text(json.dumps([{'identifier': {'id': 'openai.chatgpt'}, 'version': '1.2.3'}]))
            (root / 'openai.chatgpt-99.0.0').mkdir()
            self.assertEqual(versions.codex_inventory(root), '1.2.3')

    def test_update_uses_exact_extension_and_checks_installed_version(self):
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / 'code'
            cli.touch()
            with patch('versions.CODE', cli), patch('versions.codex_inventory', return_value='1.2.3'):
                calls = []
                versions.update_codex('1.2.3', runner=lambda *a, **k: calls.append((a, k)))
                self.assertEqual(calls[0][0][0], [str(cli), '--install-extension', 'openai.chatgpt@1.2.3', '--force'])
                self.assertEqual(calls[0][1]['timeout'], 180)
            with patch('versions.CODE', cli), patch('versions.codex_inventory', return_value='1.2.2'):
                with self.assertRaises(RuntimeError):
                    versions.update_codex('1.2.3', runner=lambda *a, **k: None)

    def test_installer_rejects_non_version_input_before_running(self):
        with self.assertRaises(ValueError):
            versions.update_codex('../../other.vsix')

    def test_new_version_requires_reverification(self):
        manifest = {'version':'0.3.0','compatibility':{'codex':{'versions':['1.0.0'],'scope':'account-read'}}}
        with patch('versions.codex_inventory', return_value='2.0.0'), patch('versions.installed_chatgpt', return_value=None):
            report = versions.inventory(manifest)
        codex = next(row for row in report['products'] if row['id'] == 'codex')
        self.assertFalse(codex['known_version'])
        self.assertEqual(codex['check'], 'not_checked')


if __name__ == '__main__':
    unittest.main()
