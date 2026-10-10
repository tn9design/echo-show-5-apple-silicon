#!/usr/bin/env python3
"""Offline checks only; never execute guest setup or system commands."""
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / "Sources/EchoGuideCore/Resources/setup-linux-translation.sh"

class TranslationConfigurationTests(unittest.TestCase):
    def test_shell_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_rendered_mount_and_service_ordering(self):
        rendered = subprocess.run(["bash", str(SCRIPT), "--print-units"], check=True, capture_output=True, text=True).stdout
        mount, ordering = rendered.split("=== binfmt-support.service.d/echoguide-rosetta.conf ===\n")
        self.assertIn("What=rosetta\nWhere=/media/rosetta\nType=virtiofs\nOptions=ro", mount)
        self.assertIn("TimeoutSec=30", mount)
        self.assertIn("Before=binfmt-support.service", mount)
        self.assertIn("Requires=media-rosetta.mount\nAfter=media-rosetta.mount", ordering)
        self.assertEqual(rendered, subprocess.run(["bash", str(SCRIPT), "--print-units"], check=True, capture_output=True, text=True).stdout)

    def test_setup_fails_closed_before_package_changes(self):
        text = SCRIPT.read_text()
        first_change = text.index("dpkg --add-architecture")
        for guard in ["Expected ARM64 Linux guest", "Expected the owned Debian 13 guest", "Expected systemd running inside the guest", "Existing unmanaged configuration must be reviewed"]:
            self.assertLess(text.index(guard), first_change)
        self.assertNotIn("/etc/fstab", text)
        self.assertNotIn("systemctl restart", text)
        self.assertIn("--remove rosetta /media/rosetta/rosetta", text)
        self.assertNotIn("--disable\n", text)
        self.assertIn("Guest restart", text)

if __name__ == "__main__":
    unittest.main()
