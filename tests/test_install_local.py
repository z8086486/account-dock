import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('install_local', Path(__file__).resolve().parents[1] / 'scripts/install_local.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class InstallTests(unittest.TestCase):
    def bundle(self, path, build, identifier='app.accountdock.mac'):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'AccountDock', 'CFBundleVersion': str(build)}))
        return path

    def test_downgrade_never_stops_or_replaces_existing_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = self.bundle(root / 'installed.app', 9)
            source = self.bundle(root / 'source.app', 8)
            with patch.object(module, 'TARGET', old), patch.object(module, 'copies', return_value=[old]), patch.object(module.subprocess, 'run'), patch.object(module, 'stop_apps') as stop:
                with self.assertRaises(ValueError):
                    module.install(source)
                stop.assert_not_called()
                self.assertEqual(module.metadata(old), 9)

    def test_failed_final_verification_restores_previous_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = self.bundle(root / 'installed.app', 1)
            source = self.bundle(root / 'source.app', 2)
            with patch.object(module, 'TARGET', old), patch.object(module, 'copies', return_value=[old]), patch.object(module, 'stop_apps'), patch.object(module.subprocess, 'run', side_effect=[None, None, RuntimeError('fixture failure')]):
                with self.assertRaises(RuntimeError):
                    module.install(source)
                self.assertEqual(module.metadata(old), 1)
                self.assertEqual(module.metadata(source), 2)

    def test_unrelated_bundle_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.bundle(Path(tmp) / 'other.app', 1, 'other.app')
            with self.assertRaises(ValueError):
                module.metadata(app)
