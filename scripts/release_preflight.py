#!/usr/bin/env python3
"""Read-only distribution checks. Does not create keys, sign, publish, or print identities."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import subprocess


def output(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def check(app=None):
    code, identities = output('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning')
    report = {'developerIDAvailable': code == 0 and 'Developer ID Application:' in identities,
              'membershipStatus': 'not_checked', 'releaseReady': False}
    if app:
        app = str(app)
        with (Path(app) / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        code, signature = output('/usr/bin/codesign', '-dv', '--verbose=4', app)
        report['developerIDSigned'] = code == 0 and 'Authority=Developer ID Application:' in signature
        report['signatureValid'] = output('/usr/bin/codesign', '--verify', '--deep', '--strict', app)[0] == 0
        report['gatekeeperAccepted'] = output('/usr/sbin/spctl', '--assess', '--type', 'execute', app)[0] == 0
        report['notarizationStapled'] = output('/usr/bin/xcrun', 'stapler', 'validate', app)[0] == 0
        try:
            key_valid = len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) == 32
        except ValueError:
            key_valid = False
        report['updateFeedConfigured'] = key_valid and str(info.get('SUFeedURL', '')).startswith('https://')
        report['artifactChecksPassed'] = all(report[key] for key in ['developerIDSigned', 'signatureValid', 'gatekeeperAccepted', 'notarizationStapled', 'updateFeedConfigured'])
    report['remainingManualGates'] = ['two-account sessions and recovery', 'clean Mac installation', 'signed end-to-end self-update']
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    print(json.dumps(check(parser.parse_args().app), indent=2))
