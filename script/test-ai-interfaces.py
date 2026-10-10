#!/usr/bin/env python3
"""Offline transport/CLI smoke test. Does not access USB or default session state."""
import json
import pathlib
import subprocess
import sys
import tempfile

bin_dir = pathlib.Path(sys.argv[1])
requests = [
    '{broken',
    json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05'}}),
    json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
    json.dumps({'jsonrpc': '2.0', 'id': 3, 'method': 'ping'}),
    json.dumps({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'approve', 'arguments': {}}}),
    json.dumps({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {'name': 'inspect', 'arguments': {'path': '/tmp'}}}),
]
result = subprocess.run([str(bin_dir / 'echo-guide-mcp')], input='\n'.join(requests) + '\n', text=True, capture_output=True, check=True, timeout=20)
replies = [json.loads(line) for line in result.stdout.splitlines()]
assert len(replies) == 6, replies
assert replies[0]['error']['code'] == -32700
assert replies[1]['result']['protocolVersion'] == '2024-11-05'
assert {t['name'] for t in replies[2]['result']['tools']} == {'inspect', 'status', 'verify_recovery', 'backup', 'request_unlock', 'request_install', 'report'}
assert replies[3]['result'] == {}
assert replies[4]['error']['code'] == -32602
assert replies[5]['error']['code'] == -32602
with tempfile.TemporaryDirectory(prefix='echoguide-cli-test-') as root:
    for command in ['prepare-workspace', 'reconcile-workspace']:
        missing = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, command], capture_output=True, text=True, timeout=20)
        assert missing.returncode == 1 and 'Usage:' in missing.stderr
    status = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'status'], capture_output=True, text=True, check=True, timeout=20)
    assert json.loads(status.stdout)['phase'] == 'setup'
    denied = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'request-install'], capture_output=True, text=True, timeout=20)
    assert denied.returncode != 0
    report = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'report'], capture_output=True, text=True, check=True, timeout=20)
    assert root not in report.stdout
print('Protocol and isolated CLI smoke tests passed; no device writes.')
