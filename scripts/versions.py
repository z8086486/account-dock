#!/usr/bin/env python3
"""Inventory and official update checks. Never reads account credentials."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

REPO = 'z8086486/account-dock'
CHATGPT_FEED = 'https://updates.oaistatic.com/codex/app/appcast'
MARKETPLACE = 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery'
CODE = Path('/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code')


def numeric_version(value):
    if not re.fullmatch(r'v?\d+(?:\.\d+)*', value or ''):
        raise ValueError('Invalid numeric version')
    return tuple(int(part) for part in value.lstrip('v').split('.'))


def newer(candidate, installed):
    try:
        a, b = numeric_version(candidate), numeric_version(installed)
        size = max(len(a), len(b))
        return a + (0,) * (size - len(a)) > b + (0,) * (size - len(b))
    except ValueError:
        return False


def fetch(url, payload=None):
    headers = {'User-Agent': 'AccountDock-version-check', 'Accept': 'application/json'}
    if payload is not None:
        headers.update({'Content-Type': 'application/json', 'Accept': 'application/json;api-version=3.0-preview.1'})
    request = urllib.request.Request(url, data=json.dumps(payload).encode() if payload else None, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read(16_000_001)
        if len(data) > 16_000_000:
            raise ValueError('Response too large')
        return data


def codex_inventory(root=None):
    root = root or Path.home() / '.vscode/extensions'
    # VS Code's installation index, not directory modification time.
    try:
        entries = json.loads((root / 'extensions.json').read_text())
        matches = [e for e in entries if e.get('identifier', {}).get('id', '').lower() == 'openai.chatgpt']
        versions = [e['version'] for e in matches if e.get('version')]
        if versions:
            return max(versions, key=numeric_version)
    except (OSError, ValueError, KeyError):
        pass
    return None


def installed_chatgpt(path=Path('/Applications/ChatGPT.app/Contents/Info.plist')):
    try:
        return plistlib.loads(path.read_bytes()).get('CFBundleShortVersionString')
    except (OSError, ValueError):
        return None


def parse_chatgpt_feed(data):
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    values = []
    for item in ET.fromstring(data).findall('./channel/item'):
        enclosure = item.find('enclosure')
        value = item.findtext(ns + 'shortVersionString')
        if value is None and enclosure is not None:
            value = enclosure.get(ns + 'shortVersionString')
        if value:
            numeric_version(value)
            values.append(value)
    if not values:
        raise ValueError('No release version')
    return max(values, key=numeric_version)


def parse_marketplace(data, architecture):
    candidates = []
    for result in json.loads(data).get('results', []):
        for extension in result.get('extensions', []):
            if extension.get('publisher', {}).get('publisherName', '').lower() != 'openai' or extension.get('extensionName', '').lower() != 'chatgpt':
                continue
            for version in extension.get('versions', []):
                if version.get('targetPlatform') not in (None, 'universal', architecture):
                    continue
                props = {p['key']: p['value'] for p in version.get('properties', [])}
                if props.get('Microsoft.VisualStudio.Code.PreRelease', '').lower() == 'true':
                    continue
                numeric_version(version['version'])
                candidates.append(version['version'])
    if not candidates:
        raise ValueError('No stable extension release')
    return max(candidates, key=numeric_version)


def latest(product):
    try:
        if product == 'chatgpt':
            value = parse_chatgpt_feed(fetch(CHATGPT_FEED))
        elif product == 'codex':
            architecture = 'darwin-arm64' if platform.machine() == 'arm64' else 'darwin-x64'
            value = parse_marketplace(fetch(MARKETPLACE, {'filters': [{'criteria': [{'filterType': 7, 'value': 'openai.chatgpt'}]}], 'flags': 19}), architecture)
        else:
            release = json.loads(fetch(f'https://api.github.com/repos/{REPO}/releases/latest'))
            if release.get('draft') or release.get('prerelease'):
                raise ValueError('Not a stable release')
            value = release['tag_name'].removeprefix('v')
            numeric_version(value)
        return {'latest': value, 'check': 'checked'}
    except urllib.error.HTTPError as error:
        return {'latest': None, 'check': 'not_released' if product == 'accountdock' and error.code == 404 else 'unavailable'}
    except Exception:
        return {'latest': None, 'check': 'unavailable'}


def inventory(manifest, online=False):
    installed = {'accountdock': manifest['version'], 'chatgpt': installed_chatgpt(), 'codex': codex_inventory()}
    remote = {}
    if online:
        with ThreadPoolExecutor(max_workers=3) as pool:
            remote = dict(zip(installed, pool.map(latest, installed)))
    result = []
    for product, version in installed.items():
        compat = manifest.get('compatibility', {}).get(product, {})
        row = {'id': product, 'installed': version, 'check': 'not_checked', 'latest': None,
               'tested': compat.get('versions', []), 'scope': compat.get('scope', ''),
               'known_version': version in compat.get('versions', [])}
        row.update(remote.get(product, {}))
        row['update_available'] = bool(version and row['latest'] and newer(row['latest'], version))
        result.append(row)
    return {'products': result}


def update_codex(version, runner=subprocess.run):
    numeric_version(version)
    if not CODE.is_file():
        raise FileNotFoundError('VS Code CLI not found')
    runner([str(CODE), '--install-extension', 'openai.chatgpt@' + version, '--force'],
           check=True, timeout=180, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if codex_inventory() != version:
        raise RuntimeError('Installed version did not match requested update')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--online', action='store_true')
    parser.add_argument('--update-codex')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if args.update_codex:
        # Recheck the official source before invoking an installer.
        available = latest('codex')
        installed = codex_inventory()
        if available['latest'] != args.update_codex or not installed or not newer(args.update_codex, installed):
            raise SystemExit('Update changed or is no longer newer. Check again.')
        try:
            update_codex(args.update_codex)
        except Exception:
            raise SystemExit('Extension update failed. Check VS Code and try again.')
    print(json.dumps(inventory(manifest, args.online), ensure_ascii=False))


if __name__ == '__main__':
    main()
