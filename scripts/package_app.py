#!/usr/bin/env python3
"""Build a local preview, or a signed/notarized app when release credentials exist."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'Sources/AccountDock/Resources/release.json'
FEED = 'https://github.com/z8086486/account-dock/releases/latest/download/appcast.xml'


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    parser.add_argument('--dmg', action='store_true')
    parser.add_argument('--install', action='store_true', help='Keep one current local installation')
    parser.add_argument('--signing-identity')
    parser.add_argument('--notary-profile')
    parser.add_argument('--sparkle-public-key')
    args = parser.parse_args()
    signed = all([args.signing_identity, args.notary_profile, args.sparkle_public_key])
    if any([args.signing_identity, args.notary_profile, args.sparkle_public_key]) and not signed:
        parser.error('Release signing requires identity, notary profile, and Sparkle public key together.')
    if signed:
        try:
            if len(base64.b64decode(args.sparkle_public_key, validate=True)) != 32:
                raise ValueError()
        except ValueError:
            parser.error('Sparkle public key must be a base64-encoded 32-byte Ed25519 key.')
    release = json.loads(MANIFEST.read_text())
    run('swift', 'build', '-c', args.configuration)
    binary_dir = Path(subprocess.check_output(['swift', 'build', '-c', args.configuration, '--show-bin-path'], cwd=ROOT, text=True).strip())
    destination = ROOT / 'dist' / f"{release['version']}-{platform.machine()}"
    if destination.exists():
        raise SystemExit(f'Output already exists: {destination}. Move it before rebuilding.')
    destination.mkdir(parents=True)
    app = destination / 'Account Dock.app'
    contents = app / 'Contents'
    for name in ['MacOS', 'Resources', 'Frameworks']:
        (contents / name).mkdir(parents=True)
    shutil.copy2(binary_dir / 'AccountDock', contents / 'MacOS/AccountDock')
    shutil.copytree(binary_dir / 'Sparkle.framework', contents / 'Frameworks/Sparkle.framework', symlinks=True)
    shutil.copy2(MANIFEST, contents / 'Resources/release.json')
    for asset in ['AppIcon.icns', 'AccountDock.png']:
        shutil.copy2(MANIFEST.parent / asset, contents / 'Resources' / asset)
    for bundle in binary_dir.glob('AccountDock_AccountDock.bundle'):
        shutil.copytree(bundle, contents / 'Resources' / bundle.name, symlinks=True)
    license_path = ROOT / '.build/checkouts/Sparkle/LICENSE'
    if not license_path.exists():
        license_path = ROOT / '.build/checkouts/sparkle/LICENSE'
    if license_path.exists():
        shutil.copy2(license_path, contents / 'Resources/Sparkle-LICENSE.txt')
    info = {'CFBundleIdentifier': 'app.accountdock.mac', 'CFBundleName': 'Account Dock',
            'CFBundleDisplayName': 'Account Dock', 'CFBundleExecutable': 'AccountDock',
            'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': release['version'],
            'CFBundleVersion': str(release['build']), 'LSMinimumSystemVersion': release['minimumMacOS'],
            'NSHighResolutionCapable': True, 'CFBundleIconFile': 'AppIcon'}
    if signed:
        info.update({'SUFeedURL': FEED, 'SUPublicEDKey': args.sparkle_public_key,
                     'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False,
                     'SUVerifyUpdateBeforeExtraction': True})
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    if signed:
        # Sign Sparkle's nested code inside-out, then the enclosing application.
        framework = contents / 'Frameworks/Sparkle.framework'
        for path in [framework / 'Versions/B/XPCServices/Downloader.xpc',
                     framework / 'Versions/B/XPCServices/Installer.xpc',
                     framework / 'Versions/B/Updater.app', framework / 'Versions/B/Autoupdate', framework, app]:
            if path.exists():
                run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', args.signing_identity, path)
        archive = destination / 'notarization.zip'
        run('ditto', '-c', '-k', '--keepParent', app, archive)
        run('xcrun', 'notarytool', 'submit', archive, '--keychain-profile', args.notary_profile, '--wait')
        archive.unlink()
        run('xcrun', 'stapler', 'staple', app)
    else:
        run('codesign', '--force', '--sign', '-', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    label = 'signed' if signed else 'preview'
    stem = f"AccountDock-{release['version']}-{platform.machine()}-{label}"
    zip_path = destination / (stem + '.zip')
    run('ditto', '-c', '-k', '--keepParent', app, zip_path)
    artifacts = [zip_path]
    if args.dmg:
        with tempfile.TemporaryDirectory(prefix='account-dock-image-') as temp:
            staging = Path(temp)
            shutil.copytree(app, staging / app.name, symlinks=True)
            (staging / 'Applications').symlink_to('/Applications')
            dmg = destination / (stem + '.dmg')
            run('hdiutil', 'create', '-volname', 'Account Dock', '-srcfolder', staging, '-format', 'UDZO', dmg)
        if signed:
            run('codesign', '--sign', args.signing_identity, '--timestamp', dmg)
            run('xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile, '--wait')
            run('xcrun', 'stapler', 'staple', dmg)
        artifacts.append(dmg)
    (destination / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in artifacts))
    print(f'Built {label} artifacts: {destination}')
    print('No GitHub Release was created. Runtime requires an installed official Codex binary; no Python required.')
    if args.install:
        from install_local import install
        install(app)


if __name__ == '__main__':
    main()
