#!/usr/bin/env python3
"""Query a saved account in an ephemeral Codex process; credentials arrive only over stdin."""
from decimal import Decimal, InvalidOperation
import base64
import json
import math
import os
import selectors
import subprocess
import tempfile
import time
from doctor import discover, client_version


def claims(token):
    try:
        value = token.split('.')[1]
        return json.loads(base64.urlsafe_b64decode(value + '=' * (-len(value) % 4)))
    except (ValueError, IndexError, TypeError):
        return {}


def external_auth(credential):
    tokens = credential.get('tokens', {})
    token = tokens.get('access_token')
    account_id = tokens.get('account_id')
    if not isinstance(token, str) or not isinstance(account_id, str) or not account_id:
        raise ValueError('Unsupported saved authentication')
    expiry = claims(token).get('exp')
    if isinstance(expiry, (int, float)) and expiry <= time.time() + 30:
        raise PermissionError('Saved access token expired')
    return {'type': 'chatgptAuthTokens', 'accessToken': token, 'chatgptAccountId': account_id}


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def limit_groups(result):
    groups = result.get('rateLimitsByLimitId')
    groups = dict(groups) if isinstance(groups, dict) else {}
    single = result.get('rateLimits')
    if isinstance(single, dict):
        key = single.get('limitId') or 'codex'
        # The compatibility view may carry credits omitted from the multi-bucket view.
        groups[key] = {**single, **(groups.get(key) if isinstance(groups.get(key), dict) else {})}
        if groups[key].get('credits') is None and single.get('credits') is not None:
            groups[key]['credits'] = single['credits']
    return groups


def normalize_credits(result):
    credits = []
    for key, group in limit_groups(result).items():
        if not isinstance(group, dict) or not isinstance(group.get('credits'), dict):
            continue
        value = group['credits']
        balance = None
        raw = value.get('balance')
        if isinstance(raw, (str, int, float)) and not isinstance(raw, bool) and len(str(raw)) <= 64:
            try:
                numeric = Decimal(str(raw))
                if numeric.is_finite() and 0 <= numeric <= Decimal('1e18') and -8 <= numeric.as_tuple().exponent <= 18:
                    balance = format(numeric, 'f')
            except (InvalidOperation, ValueError):
                pass
        state = ('unlimited' if value.get('unlimited') is True else 'balance' if balance is not None
                 else 'empty' if value.get('hasCredits') is False else 'available' if value.get('hasCredits') is True else 'unknown')
        credits.append({'id': str(key), 'bucket': group.get('limitName') or str(key), 'status': state, 'balance': balance})
    resets = result.get('rateLimitResetCredits')
    count = resets.get('availableCount') if isinstance(resets, dict) else None
    return credits, count if isinstance(count, int) and not isinstance(count, bool) and 0 <= count <= 1_000_000 else None


def normalize_limits(result):
    groups = limit_groups(result)
    windows = []
    for key, group in groups.items():
        if not isinstance(group, dict):
            continue
        for role in ['primary', 'secondary']:
            value = group.get(role)
            if not isinstance(value, dict) or not number(value.get('usedPercent')):
                continue
            used = min(100, max(0, value['usedPercent']))
            minutes = value.get('windowDurationMins')
            reset = value.get('resetsAt')
            windows.append({'id': f'{key}:{role}', 'bucket': group.get('limitName') or str(key),
                            'usedPercent': used, 'remainingPercent': 100 - used,
                            'windowMinutes': minutes if number(minutes) and minutes > 0 else None,
                            'resetsAt': reset if number(reset) and reset > 0 else None})
    return windows


def normalize_activity(result):
    summary = result.get('summary') or {}
    if not isinstance(summary, dict):
        return {}
    return {key: value for key in ['lifetimeTokens', 'peakDailyTokens']
            if number(value := summary.get(key)) and value >= 0}


def read_usage(credential, binary=None, timeout=20):
    auth = external_auth(credential)
    binary = binary or discover()
    if not binary:
        raise FileNotFoundError('Codex not found')
    with tempfile.TemporaryDirectory(prefix='account-dock-usage-') as directory:
        env = dict(os.environ, CODEX_HOME=directory)
        for key in ['OPENAI_API_KEY', 'CODEX_ACCESS_TOKEN']:
            env.pop(key, None)
        with subprocess.Popen([str(binary), '-c', 'cli_auth_credentials_store="ephemeral"', 'app-server', '--stdio'],
                              cwd=directory, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, bufsize=0) as process:
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            def send(value):
                process.stdin.write((json.dumps(value) + '\n').encode())
            limits, activity = None, None
            credits, reset_count = [], None
            received = set()
            try:
                send({'id': 1, 'method': 'initialize', 'params': {
                    'clientInfo': {'name': 'account_dock_usage', 'version': client_version()},
                    'capabilities': {'experimentalApi': True}}})
                deadline = time.monotonic() + timeout
                buffer = b''
                while time.monotonic() < deadline:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        break
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        break
                    buffer += data
                    if len(buffer) > 2_000_000:
                        raise ValueError('Response too large')
                    while b'\n' in buffer:
                        line, buffer = buffer.split(b'\n', 1)
                        reply = json.loads(line)
                        if reply.get('method') == 'account/chatgptAuthTokens/refresh':
                            # Never rotate another application's refresh token while measuring usage.
                            raise PermissionError('Saved account needs login')
                        rid = reply.get('id')
                        if rid == 1:
                            if 'error' in reply:
                                raise RuntimeError('Unsupported service')
                            send({'method': 'initialized'})
                            send({'id': 2, 'method': 'account/login/start', 'params': auth})
                        elif rid == 2:
                            if 'error' in reply:
                                raise PermissionError('Authentication not accepted')
                            send({'id': 3, 'method': 'account/rateLimits/read'})
                            send({'id': 4, 'method': 'account/usage/read'})
                        elif rid in (3, 4):
                            received.add(rid)
                            if 'error' not in reply:
                                if rid == 3:
                                    limits = normalize_limits(reply.get('result', {}))
                                    credits, reset_count = normalize_credits(reply.get('result', {}))
                                else:
                                    activity = normalize_activity(reply.get('result', {}))
                        if received == {3, 4}:
                            return {'status': 'available' if limits or activity or credits or reset_count is not None else 'unavailable',
                                    'windows': limits or [], 'activity': activity or {}, 'credits': credits, 'resetCredits': reset_count, 'checkedAt': time.time()}
                if limits or activity or credits or reset_count is not None:
                    return {'status': 'partial', 'windows': limits or [], 'activity': activity or {}, 'credits': credits, 'resetCredits': reset_count, 'checkedAt': time.time()}
                raise TimeoutError('Usage request timed out')
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
    try:
        raw = __import__('sys').stdin.buffer.read(1_000_001)
        if len(raw) > 1_000_000:
            raise ValueError('Input too large')
        result = read_usage(json.loads(raw))
    except PermissionError:
        result = {'status': 'login_required', 'windows': [], 'activity': {}}
    except Exception:
        result = {'status': 'unavailable', 'windows': [], 'activity': {}}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
