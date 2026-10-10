#!/usr/bin/env python3
"""Reviewed three-attempt candidate. No device access without --execute SERIAL."""
import hashlib
import json
import pathlib
import subprocess
import sys
import time

BASE = pathlib.Path(__file__).resolve().parent
HASHES = {
    'fastboot': 'cb3d13b850143da85eb4b2099462514894459213da93d03d6ff4782d927d6e20',
    'fastbrick-20240709.img': 'c57acac911b8dc9c7f5fec2df25ba04ba8b70a26da14313c8a0d242e984d6091',
}
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
for key, expected in [('product', 'CHECKERS'), ('unlock_status', 'false'),
                      ('lk_build_desc', '44072a3-20240709_170103')]:
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
    ordinary = (result.returncode == 1 and 'OKAY [' in output and
                'FAILED (remote: the command you input is restricted on locked hw)' in output and
                'Finished. Total time:' in output)
    special = any(marker in output for marker in
                  ['eMMC-RO', 'Device mismatch', 'waiting for', 'error:', 'ERROR'])
    if not ordinary or special:
        print('STOP: changed or ambiguous response; timeout is not success.', flush=True)
        break
    if attempt < 3:
        time.sleep(2)
print('STOP: bounded run ended. Keep wall power connected for five minutes. Log:', log, flush=True)
