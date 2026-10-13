#!/usr/bin/env python3
"""Read local Codex account metadata without exposing credentials."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import time


def discover():
    candidates = list((Path.home() / '.vscode/extensions').glob('openai.chatgpt-*/bin/macos-*/codex'))
    return max(candidates, key=lambda p: p.stat().st_mtime) if candidates else None


def summarize(result, show_email=False):
    if not isinstance(result, dict) or 'account' not in result:
        raise ValueError('Unexpected account response')
    account = result['account']
    if account is None:
        return {'status': 'signed_out'}
    if not isinstance(account, dict) or not isinstance(account.get('type'), str):
        raise ValueError('Unexpected account type')
    summary = {'status': 'cached_account', 'type': account['type']}
    email = account.get('email')
    if isinstance(email, str):
        summary['email'] = email if show_email else '(hidden)'
    if isinstance(account.get('planType'), str):
        summary['plan'] = account['planType']
    return summary


def read_account(binary, codex_home, show_email=False, timeout=12):
    env = dict(os.environ, CODEX_HOME=str(codex_home))
    with subprocess.Popen([str(binary), 'app-server', '--stdio'], env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0) as process:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def send(message):
            process.stdin.write((json.dumps(message) + '\n').encode())

        try:
            send({'id': 1, 'method': 'initialize', 'params': {
                'clientInfo': {'name': 'account_dock', 'version': '0.1.0'}}})
            deadline = time.monotonic() + timeout
            buffer = b''
            while time.monotonic() < deadline:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('Account service ended before replying')
                buffer += chunk
                if len(buffer) > 2_000_000:
                    raise RuntimeError('Account service response too large')
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    reply = json.loads(line)
                    if reply.get('id') not in (1, 2):
                        continue
                    if 'error' in reply:
                        raise RuntimeError('Account service rejected the request')
                    if reply.get('id') == 1:
                        send({'method': 'initialized'})
                        send({'id': 2, 'method': 'account/read', 'params': {'refreshToken': False}})
                    elif reply.get('id') == 2:
                        return summarize(reply.get('result'), show_email)
            raise TimeoutError('Account service timed out')
        finally:
            selector.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--show-email', action='store_true')
    args = parser.parse_args()
    binary = args.binary or discover()
    report = {'chatgpt_installed': Path('/Applications/ChatGPT.app').exists(),
              'vscode_installed': Path('/Applications/Visual Studio Code.app').exists(),
              'scope': 'local Codex auth store; running app identity not verified'}
    if not binary:
        report['codex'] = {'status': 'unavailable'}
    else:
        try:
            report['codex'] = read_account(binary, args.codex_home.expanduser().resolve(), args.show_email)
        except Exception as error:
            # Never surface raw server output or exception text containing credentials.
            report['codex'] = {'status': 'error', 'reason': type(error).__name__}
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
