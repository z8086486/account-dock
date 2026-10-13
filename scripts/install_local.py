#!/usr/bin/env python3
"""Install one verified local build. Never touches account files or Keychain."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TARGET = Path.home() / 'Applications/Account Dock.app'
BUNDLE = 'app.accountdock.mac'


def metadata(path):
    if path.is_symlink():
        raise ValueError(f'Refusing symlink: {path}')
    with (path / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    allowed_id = info.get('CFBundleIdentifier') == BUNDLE or (path == ROOT / '.local/Account Dock.app' and info.get('CFBundleIdentifier') == 'app.accountdock.preview')
    if not allowed_id or info.get('CFBundleExecutable') != 'AccountDock':
        raise ValueError(f'Not an Account Dock bundle: {path}')
    return int(info['CFBundleVersion'])


def copies():
    found = {TARGET, Path('/Applications/Account Dock.app')}
    for directory in [ROOT / 'dist', ROOT / '.local']:
        if directory.exists():
            found.update(directory.rglob('Account Dock.app'))
    return sorted(p for p in found if p.exists() and not p.is_symlink())


def stop_apps(paths):
    allowed = {str(p / 'Contents/MacOS/AccountDock') for p in paths}
    allowed.update(str((ROOT / '.build' / configuration / 'AccountDock').resolve()) for configuration in ['debug', 'release'])
    allowed.update(str(p.resolve()) for p in (ROOT / '.build').glob('*/debug/AccountDock'))
    allowed.update(str(p.resolve()) for p in (ROOT / '.build').glob('*/release/AccountDock'))
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    pids = []
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, executable = int(parts[0]), parts[1]
        if Path(executable).name != 'AccountDock':
            continue
        if not executable.startswith('/'):
            result = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True)
            cwd = next((line[1:] for line in result.stdout.splitlines() if line.startswith('n/')), None)
            if not cwd:
                continue
            executable = str((Path(cwd) / executable).resolve())
        if executable in allowed:
            os.kill(pid, signal.SIGTERM)
            pids.append(pid)
    deadline = time.monotonic() + 8
    for pid in pids:
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('Account Dock is still running; installation stopped.')
            time.sleep(0.1)


def install(source):
    source = Path(source).absolute()
    if source == TARGET:
        raise ValueError('Choose a newly packaged app as source.')
    build = metadata(source)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    old = copies()
    for path in old:
        if metadata(path) > build:
            raise ValueError(f'Newer build already exists: {path}')
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.account-dock-install-', dir=TARGET.parent) as temp:
        staged = Path(temp) / 'Account Dock.app'
        backup = Path(temp) / 'previous.app'
        shutil.copytree(source, staged, symlinks=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        stop_apps(old)
        if TARGET.exists():
            TARGET.rename(backup)
        try:
            staged.rename(TARGET)
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(TARGET)], check=True)
        except Exception:
            if TARGET.exists():
                shutil.rmtree(TARGET)
            if backup.exists():
                backup.rename(TARGET)
            raise
    # Only identified Account Dock bundles in these explicit development/install locations.
    for path in old:
        if path != TARGET and path.exists():
            metadata(path)
            shutil.rmtree(path)
    if source.exists() and source != TARGET and source.is_relative_to(ROOT / 'dist'):
        shutil.rmtree(source)
    subprocess.run(['/usr/bin/open', str(TARGET)], check=True)
    print(f'Installed build {build}: {TARGET}')
    print('ZIP/DMG archives retained. Account files and Keychain were not changed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    install(parser.parse_args().app)
