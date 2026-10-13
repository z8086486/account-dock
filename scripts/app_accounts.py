#!/usr/bin/env python3
"""Identify each local app's auth store from its own running Codex process.

This deliberately reports stored identities, never claims to read in-memory sessions.
Only matching app-server processes are inspected; raw argv/environment never leave this module.
"""
import argparse
import base64
import ctypes
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

DESKTOP = '/Applications/ChatGPT.app/Contents/'
VSCODE = '/Applications/Visual Studio Code.app/Contents/'


def parse_process_arguments(raw):
    if len(raw) < 5:
        raise ValueError('Invalid process data')
    argc = struct.unpack_from('i', raw)[0]
    if not 1 <= argc <= 4096:
        raise ValueError('Invalid argument count')
    pos = raw.index(b'\0', 4) + 1  # skip executable path
    while pos < len(raw) and raw[pos] == 0:
        pos += 1
    argv = []
    for _ in range(argc):
        end = raw.index(b'\0', pos)
        argv.append(raw[pos:end].decode('utf-8', errors='replace'))
        pos = end + 1
    # Keep only paths required to identify the auth store, not credentials or other environment data.
    env = {}
    for value in raw[pos:].split(b'\0'):
        key, sep, data = value.partition(b'=')
        if sep and key in (b'HOME', b'CODEX_HOME'):
            env[key.decode()] = data.decode('utf-8')
    return argv, env


def process_arguments(pid):
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(1024 * 1024)
    data = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        raise PermissionError('Process information unavailable')
    return parse_process_arguments(data.raw[:size.value])


def process_table():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,comm='], capture_output=True, text=True, check=True, timeout=5)
    records = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            records[int(parts[0])] = (int(parts[1]), parts[2])
    return records


def classify(executable, parent):
    if executable.startswith(DESKTOP) and Path(executable).name == 'codex' and parent == DESKTOP + 'MacOS/ChatGPT':
        return 'chatgpt'
    if re.search(r'/\.vscode/extensions/openai\.chatgpt-[^/]+/bin/macos-[^/]+/codex$', executable) and parent.startswith(VSCODE) and 'Code Helper (Plugin)' in parent:
        return 'codex'
    return None


def store_home(argv, env):
    if 'app-server' not in argv:
        return None
    # CLI config overrides/profiles can change auth independently of the home.
    for arg in argv:
        if arg in ('--profile', '-p') or arg.startswith('--profile='):
            raise ValueError('Profile override')
        if 'cli_auth_credentials_store' in arg and not re.fullmatch(r'cli_auth_credentials_store\s*=\s*[\"\']?file[\"\']?', arg):
            raise ValueError('Authentication override')
    home = env.get('CODEX_HOME') or (str(Path(env['HOME']) / '.codex') if env.get('HOME') else None)
    if not home or not Path(home).is_absolute():
        raise ValueError('Unknown authentication home')
    return str(Path(home).resolve())


def stored_identity(home):
    from doctor import file_presets_supported
    if not file_presets_supported(Path(home)):
        return {'status': 'unsupported_store'}
    path = Path(home) / 'auth.json'
    if not path.exists():
        return {'status': 'no_saved_auth'}
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_000_000:
        return {'status': 'unavailable'}
    value = json.loads(path.read_bytes())
    tokens = value.get('tokens')
    if not isinstance(tokens, dict):
        return {'status': 'api_key' if value.get('OPENAI_API_KEY') else 'no_saved_auth'}
    token = tokens.get('id_token', '')
    part = token.split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    email = claims.get('email')
    plan = claims.get('https://api.openai.com/auth', {}).get('chatgpt_plan_type')
    if not isinstance(email, str) or len(email) > 320:
        return {'status': 'unavailable'}
    return {'status': 'stored_account', 'email': email, 'plan': plan if isinstance(plan, str) else None}


def collect(table=None, arguments=None, read_identity=None):
    table = process_table() if table is None else table
    arguments = arguments or process_arguments
    read_identity = read_identity or stored_identity
    rows, seen = [], set()
    running = {'chatgpt': any(e == DESKTOP + 'MacOS/ChatGPT' for _, e in table.values()),
               'codex': any(e == VSCODE + 'MacOS/Code' for _, e in table.values())}
    for pid, (ppid, executable) in table.items():
        product = classify(executable, table.get(ppid, (0, ''))[1])
        if not product:
            continue
        entry = {'product': product, 'status': 'unavailable'}
        try:
            argv, env = arguments(pid)
            home = store_home(argv, env)
            if home is None:
                continue
            entry.update({'home': home, **read_identity(home)})
            match = re.search(r'openai\.chatgpt-([0-9.]+)-', executable)
            if match:
                entry['version'] = match[1]
        except Exception:
            pass
        # Multiple local editor windows may use the same store and extension build.
        key = (product, entry.get('home'), entry.get('version'), entry['status'])
        if key not in seen:
            seen.add(key)
            entry['id'] = str(len(rows))
            rows.append(entry)
    for product in running:
        if not any(row['product'] == product for row in rows):
            rows.append({'id': product, 'product': product,
                         'status': 'process_unavailable' if running[product] else 'not_running'})
    return {'accounts': rows, 'checkedAt': time.time()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--show-email', action='store_true')
    args = parser.parse_args()
    try:
        result = collect()
    except Exception:
        result = {'accounts': [{'id':p,'product':p,'status':'unavailable'} for p in ['chatgpt','codex']], 'checkedAt':time.time()}
    if not args.show_email:
        for account in result['accounts']:
            if 'email' in account:
                account['email'] = '(hidden)'
    print(json.dumps(result, ensure_ascii=False))
