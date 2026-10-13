#!/usr/bin/env python3
"""Sign a Sparkle update and appcast using the private key in local Keychain."""
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = 'app.accountdock.updates'


def main():
    release = json.loads((ROOT / 'Sources/AccountDock/Resources/release.json').read_text())
    version = release['version']
    arch = platform.machine()
    directory = ROOT / 'dist' / f'{version}-{arch}'
    archive = directory / f'AccountDock-{version}-{arch}-preview.zip'
    if not archive.is_file():
        raise SystemExit('Package the preview ZIP before generating its update feed.')
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    public_key = subprocess.check_output([tools / 'generate_keys', '--account', ACCOUNT, '-p'], text=True).strip()
    if public_key != release.get('updatePublicKey'):
        raise SystemExit('The local signing key does not match the public key embedded in the app.')
    feed = directory / f'appcast-{arch}.xml'
    with tempfile.TemporaryDirectory(prefix='account-dock-appcast-') as temp:
        shutil.copy2(archive, Path(temp) / archive.name)
        subprocess.run([tools / 'generate_appcast', '--account', ACCOUNT,
            '--download-url-prefix', f'https://github.com/z8086486/account-dock/releases/download/v{version}/',
            '--maximum-deltas', '0', '-o', feed, temp], check=True)
    subprocess.run([tools / 'sign_update', '--account', ACCOUNT, '--verify', feed], check=True)
    print(f'Verified signed feed: {feed}')
    print('Upload the archive first, then publish this feed under updates/ in the repository.')


if __name__ == '__main__':
    main()
