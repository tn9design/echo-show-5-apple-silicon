#!/usr/bin/env python3
"""Offline validation/render checks only; never dispatch or inspect a guest."""
from pathlib import Path
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
