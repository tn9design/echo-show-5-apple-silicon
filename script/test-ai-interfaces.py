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
assert {t['name'] for t in replies[2]['result']['tools']} == {'inspect', 'inspect_guest_connection', 'prepare_downloads', 'prepare_workspace', 'status', 'powered_wait_status', 'verify_recovery', 'backup', 'request_unlock', 'request_install', 'report'}
connection_tool = next(t for t in replies[2]['result']['tools'] if t['name'] == 'inspect_guest_connection')
assert connection_tool['inputSchema']['additionalProperties'] is False
assert connection_tool['annotations']['readOnlyHint'] is True
assert replies[3]['result'] == {}
assert replies[4]['error']['code'] == -32602
assert replies[5]['error']['code'] == -32602
with tempfile.TemporaryDirectory(prefix='echoguide-cli-test-') as root:
    for command in ['prepare-workspace', 'reconcile-workspace', 'start-workspace', 'stop-workspace']:
        missing = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, command], capture_output=True, text=True, timeout=20)
        assert missing.returncode == 1 and 'Usage:' in missing.stderr
    invalid_root = pathlib.Path(root, 'private-destination-must-not-appear')
    invalid_root.write_text('not a state directory')
    invalid = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', str(invalid_root), 'status'], capture_output=True, text=True, timeout=20)
    assert invalid.returncode == 1 and not invalid.stdout
    diagnostic = json.loads(invalid.stderr)
    assert diagnostic['code'] == 'operation_failed'
    assert str(invalid_root) not in invalid.stderr and root not in invalid.stderr
    assert set(diagnostic) == {'code', 'message'}
    status = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'status'], capture_output=True, text=True, check=True, timeout=20)
    assert json.loads(status.stdout)['phase'] == 'setup'
    wait = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'powered-wait-status'], capture_output=True, text=True, check=True, timeout=20)
    assert json.loads(wait.stdout) is None
    connection = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'inspect-guest-connection'], capture_output=True, text=True, timeout=20)
    assert connection.returncode == 1 and not connection.stdout
    assert root not in connection.stderr
    session = json.loads(pathlib.Path(root, 'session.json').read_text())
    assert session['operations'][-1]['action'] == 'inspect_guest_connection'
    assert session.get('guest') is None
    private_request = '82CB81FD-3F14-41AF-AE54-F2E5D460BBA0'
    pathlib.Path(root, 'unlock-powered-wait.json').write_text(json.dumps({'requestID': private_request, 'requiredSeconds': 300, 'elapsedSeconds': 35, 'complete': False}))
    wait = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'powered-wait-status'], capture_output=True, text=True, check=True, timeout=20)
    observed = json.loads(wait.stdout)
    assert observed['elapsedSeconds'] == 35 and observed['complete'] is False
    assert 'Keep wall power connected' in observed['guidance']
    assert private_request not in wait.stdout and root not in wait.stdout

    denied = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'request-install'], capture_output=True, text=True, timeout=20)
    assert denied.returncode != 0
    report = subprocess.run([str(bin_dir / 'echo-guide'), '--state-root', root, 'report'], capture_output=True, text=True, check=True, timeout=20)
    assert root not in report.stdout
print('Protocol and isolated CLI smoke tests passed; no device writes.')
