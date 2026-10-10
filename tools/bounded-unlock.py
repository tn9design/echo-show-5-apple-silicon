#!/usr/bin/env python3
"""Reviewed three-attempt candidate. No device access without --execute SERIAL."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time

BASE = pathlib.Path(__file__).resolve().parent
PROFILE = BASE.parent / 'Sources' / 'EchoGuideCore' / 'Resources' / 'checkers-v1.json'


def load_profile(path=PROFILE):
    """Read the bundled source profile; the CLI accepts no profile override."""
    profile = json.loads(path.read_text())
    required = {'id', 'product', 'lkBuild', 'minimumWritingOS', 'utmVersion',
                'guestVersion', 'recoveryVersion', 'romVersion', 'experimental', 'artifacts'}
    if not isinstance(profile, dict) or set(profile) != required:
        raise ValueError('invalid compatibility profile schema')
    if profile['id'] != 'checkers-20240709-v1':
        raise ValueError('unsupported compatibility profile')
    for field in ('product', 'lkBuild', 'utmVersion', 'guestVersion', 'recoveryVersion', 'romVersion'):
        if not isinstance(profile[field], str) or not re.fullmatch(r'[A-Za-z0-9._-]+', profile[field]):
            raise ValueError('invalid profile identity')
    if type(profile['minimumWritingOS']) is not int or profile['minimumWritingOS'] != 27 or type(profile['experimental']) is not bool:
        raise ValueError('invalid profile host metadata')
    artifacts = profile['artifacts']
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError('missing artifacts')
    hashes = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {'name', 'sha256', 'publisherURL', 'size'}:
            raise ValueError('invalid artifact schema')
        name, digest = artifact['name'], artifact['sha256']
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9._-]+', name) or name in hashes:
            raise ValueError('invalid or duplicated artifact name')
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('invalid artifact hash')
        size, publisher = artifact['size'], artifact['publisherURL']
        if size is not None and (type(size) is not int or size <= 0):
            raise ValueError('invalid artifact size')
        if publisher is not None and (not isinstance(publisher, str) or not publisher.startswith('https://')):
            raise ValueError('invalid publisher URL')
        hashes[name] = digest
    if not {'fastboot', 'fastbrick-20240709.img'} <= hashes.keys():
        raise ValueError('missing unlock artifacts')
    return profile, {name: hashes[name] for name in ('fastboot', 'fastbrick-20240709.img')}


def main():
    try:
        profile, HASHES = load_profile()
    except (OSError, ValueError, TypeError) as error:
        sys.exit(f'STOP: bundled compatibility profile unavailable or invalid: {error}')
    for name, expected in HASHES.items():
        path = BASE / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            sys.exit(f'STOP: missing or mismatched required file: {name}')
    if len(sys.argv) != 3 or sys.argv[1] != '--execute':
        print('Hashes verified. No device commands. Usage: bounded-unlock.py --execute SERIAL')
        sys.exit(0)
    serial = sys.argv[2]
    if not serial.isalnum():
        sys.exit('STOP: invalid serial')
    client = [str(BASE / 'fastboot'), '-s', serial]
    for key, expected in [('product', profile['product']), ('unlock_status', 'false'),
                          ('lk_build_desc', profile['lkBuild'])]:
        result = subprocess.run(client + ['getvar', key], capture_output=True, text=True, timeout=10)
        output = result.stdout + result.stderr
        print(output, flush=True)
        values = [line.split(':', 1)[1].strip() for line in output.splitlines()
                  if line.startswith(key + ':')]
        if result.returncode != 0 or values != [expected]:
            sys.exit(f'STOP: unexpected device identity for {key}')

    records = []
    log = BASE / f'bounded-retries-{time.time_ns()}.json'
    for attempt in range(1, 4):
        start = time.time()
        result = subprocess.run(['timeout', '--kill-after=2s', '8s'] + client +
                                ['flash', 'brick', str(BASE / 'fastbrick-20240709.img')],
                                capture_output=True, text=True)
        output = result.stdout + result.stderr
        records.append({'attempt': attempt, 'start_epoch': start, 'end_epoch': time.time(),
                        'exit': result.returncode, 'output': output})
        log.write_text(json.dumps(records, indent=2))
        print(json.dumps(records[-1], indent=2), flush=True)
        # Only the already-observed complete rejection permits another attempt.
        ordinary = result.returncode == 1 and re.fullmatch(
            r"target reported max download size of 114294784 bytes\n"
            r"Sending 'brick' \(111785 KB\)\.\.\.\n"
            r"OKAY \[ *[0-9]+\.[0-9]+s\]\n"
            r"Writing 'brick'\.\.\.\n"
            r"FAILED \(remote: the command you input is restricted on locked hw\)\n"
            r"Finished\. Total time: [0-9]+\.[0-9]+s\n?", output) is not None
        special = any(marker in output for marker in
                      ['eMMC-RO', 'Device mismatch', 'waiting for', 'error:', 'ERROR'])
        if not ordinary or special:
            print('STOP: changed or ambiguous response; timeout is not success.', flush=True)
            break
        if attempt < 3:
            time.sleep(2)
    print('STOP: bounded run ended. Keep wall power connected for five minutes. Log:', log, flush=True)


if __name__ == "__main__":
    main()
