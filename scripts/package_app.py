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
FEED = 'https://raw.githubusercontent.com/z8086486/account-dock/main/updates/appcast-{architecture}.xml'


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    parser.add_argument('--dmg', action='store_true')
    parser.add_argument('--development', action='store_true', help='Ad-hoc development build without the release vault or updater')
    parser.add_argument('--install', action='store_true', help='Keep one current local installation')
    parser.add_argument('--preview-signing-identity', help='Persistent local code signing identity for preview releases')
    parser.add_argument('--signing-identity')
    parser.add_argument('--notary-profile')
    parser.add_argument('--sparkle-public-key')
    args = parser.parse_args()
    release = json.loads(MANIFEST.read_text())
    public_key = None if args.development else args.sparkle_public_key or release.get('updatePublicKey')
    preview_identity = args.preview_signing_identity or release.get('codeSigningCertificate')
    if args.development:
        preview_identity = None
    signed = bool(args.signing_identity and args.notary_profile)
    if args.preview_signing_identity and (args.signing_identity or args.notary_profile):
        parser.error('Choose preview signing or Developer ID signing, not both.')
    if bool(args.signing_identity) != bool(args.notary_profile):
        parser.error('Developer ID packaging requires both signing identity and notary profile.')
    if public_key:
        try:
            if len(base64.b64decode(public_key, validate=True)) != 32:
                raise ValueError()
        except ValueError:
            parser.error('Sparkle public key must be a base64-encoded 32-byte Ed25519 key.')
    run('swift', 'build', '-c', args.configuration)
    binary_dir = Path(subprocess.check_output(['swift', 'build', '-c', args.configuration, '--show-bin-path'], cwd=ROOT, text=True).strip())
    destination = ROOT / 'dist' / f"{release['version']}-{platform.machine()}"
    if destination.exists():
        raise SystemExit(f'Output already exists: {destination}. Move it before rebuilding.')
    destination.mkdir(parents=True)
    app = destination / 'Account Dock.app'
    contents = app / 'Contents'
    for name in ['MacOS', 'Resources', 'Frameworks', 'Helpers']:
        (contents / name).mkdir(parents=True)
    if not args.development:
        vault = ROOT / '.local/vault/AccountDockVault'
        if not vault.is_file() or hashlib.sha256(vault.read_bytes()).hexdigest() != release.get('vaultHelperSHA256'):
            raise SystemExit('Restore the exact signed AccountDockVault from the previous release into .local/vault/. Do not rebuild it for UI updates.')
        requirement = f'=identifier "app.accountdock.vault" and certificate leaf = H"{release["codeSigningCertificate"]}"'
        run('codesign', '--verify', '--strict', '-R', requirement, vault)
        shutil.copy2(vault, contents / 'Helpers/AccountDockVault')
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
            'NSHighResolutionCapable': True, 'CFBundleIconFile': 'AppIcon',
            'AccountDockDevelopmentBuild': args.development}
    if public_key:
        info.update({'SUFeedURL': FEED.format(architecture=platform.machine()), 'SUPublicEDKey': public_key,
                     'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False,
                     'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True})
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
        run('codesign', '--force', '--sign', preview_identity or '-', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    label = 'development' if args.development else release.get('channel', 'preview')
    suffix = '' if label == 'stable' else f'-{label}'
    stem = f"AccountDock-{release['version']}-{platform.machine()}{suffix}"
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
