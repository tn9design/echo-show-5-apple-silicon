#!/usr/bin/env python3
"""Offline validation/render checks only; never dispatch or inspect a guest."""
from pathlib import Path
import os
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'Sources/EchoGuideCore/Resources/translation-attempt.sh'
UUID = '01234567-89ab-cdef-0123-456789abcdef'
ARGS = [UUID, UUID, UUID, 'a' * 64, UUID, 'echotest']

class TranslationAttemptTests(unittest.TestCase):
    def invoke(self, mode, args=ARGS):
        return subprocess.run(['/bin/bash', str(SCRIPT), mode, *args], capture_output=True, text=True)

    def test_syntax(self):
        subprocess.run(['/bin/bash', '-n', str(SCRIPT)], check=True)

    def test_render_fixed_unit(self):
        result = self.invoke('render')
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in ['Type=exec', 'ExitType=cgroup', 'RemainAfterExit=no', 'Restart=no',
                         'StandardInput=null', 'StandardOutput=null', 'StandardError=null',
                         f'ExecStart=/bin/bash /var/lib/echoguide/translation/{UUID}/helper.sh run',
                         'ExecStopPost=/bin/bash']:
            self.assertIn(expected, result.stdout)
        self.assertNotIn('[Install]', result.stdout)

    def test_reject_injection_before_linux_access(self):
        for index, bad in [(0, '../bad'), (1, '$(id)'), (2, 'x\n'), (3, 'A' * 64),
                           (4, '/tmp'), (5, 'user;id'), (5, 'Echo Test')]:
            args = ARGS.copy(); args[index] = bad
            result = self.invoke('render', args)
            self.assertEqual(result.returncode, 64)
            self.assertEqual(result.stdout, '')
        self.assertEqual(self.invoke('arbitrary').returncode, 64)

    def running_frame(self, properties, populated='1', started='invocation=' + 'b' * 32):
        # Execute the production pure decision/emission function, without sourcing
        # privileged script initialization or reading real Linux paths.
        source = SCRIPT.read_text()
        function = source.split('# BEGIN PURE RUNNING FRAME\n', 1)[1].split('# END PURE RUNNING FRAME', 1)[0]
        env = os.environ.copy()
        env.update(TEST_PROPERTIES=properties, TEST_POPULATED=populated, TEST_STARTED=started,
                   TEST_UNIT=f'echoguide-translation-{UUID}.service', TEST_BINDING='version=1')
        program = function + '\nunit=$TEST_UNIT; binding=$TEST_BINDING; emit_running "$TEST_STARTED" "$TEST_PROPERTIES" "$TEST_POPULATED"\n'
        return subprocess.run(['/bin/bash', '-c', program], env=env, capture_output=True, text=True)

    def test_real_running_emitter(self):
        properties = f"LoadState=loaded\nActiveState=active\nSubState=running\nResult=success\nExecMainCode=0\nExecMainStatus=0\nInvocationID={'b' * 32}\nControlGroup=/system.slice/echoguide-translation-{UUID}.service"
        result = self.running_frame(properties)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('receiptState=running\n', result.stdout)
        self.assertEqual(result.stdout.count('invocation='), 1)
        self.assertIn('cgroupPopulated=1\n', result.stdout)
        self.assertTrue(result.stdout.endswith('END\n'))
        for active in ['inactive', 'failed', 'deactivating']:
            rejected = self.running_frame(properties.replace('ActiveState=active', 'ActiveState=' + active))
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(rejected.stdout, '')
        for changed in [properties.replace('LoadState=loaded', 'LoadState=not-found'),
                        properties.replace('InvocationID=' + 'b' * 32, 'InvocationID=' + 'c' * 32),
                        properties.replace('ControlGroup=/system.slice/', 'ControlGroup=/wrong/'),
                        properties + '\nInvocationID=' + 'b' * 32]:
            self.assertNotEqual(self.running_frame(changed).returncode, 0)
        for populated in ['0', 'unknown', '1\n0']:
            self.assertNotEqual(self.running_frame(properties, populated).returncode, 0)
        self.assertNotEqual(self.running_frame(properties, started='bad').returncode, 0)

    def test_dispatch_order_and_inspection_no_mutators(self):
        source = SCRIPT.read_text()
        dispatch = source.split('if [ "$mode" = dispatch ]; then', 1)[1].split('\nfi\nsafe_root', 1)[0]
        ordered = ['mkdir -m 755 "$root"', 'cp -- "$source"', 'sha256sum -c -',
                   'cp -- "$0"', 'render >', 'systemctl daemon-reload', 'systemctl start']
        positions = [dispatch.index(part) for part in ordered]
        self.assertEqual(positions, sorted(positions))
        inspection = source.split('# Facts only:', 1)[1]
        for forbidden in ['sudo', 'systemctl start', 'systemctl stop', 'rm ', 'apt-get', 'dpkg --configure']:
            self.assertNotIn(forbidden, inspection)
        self.assertIn('category=unknown', inspection)
        self.assertIn('packageState=unverified', inspection)
        self.assertNotIn('RuntimeMaxSec', source)

if __name__ == '__main__':
    unittest.main()
