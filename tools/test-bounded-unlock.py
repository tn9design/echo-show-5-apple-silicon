#!/usr/bin/env python3
"""Offline metadata checks; importing the helper cannot execute device commands."""
import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bounded_unlock', HERE / 'bounded-unlock.py')
helper = importlib.util.module_from_spec(spec)
with patch('subprocess.run', side_effect=AssertionError('device invocation')):
    spec.loader.exec_module(helper)

class ProfileTests(unittest.TestCase):
    def check_bad(self, profile):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'profile.json'
            path.write_text(json.dumps(profile))
            with self.assertRaises(ValueError), patch('subprocess.run', side_effect=AssertionError('device invocation')):
                helper.load_profile(path)

    def test_pinned_profile(self):
        profile, hashes = helper.load_profile()
        self.assertEqual(profile['id'], 'checkers-20240709-v1')
        self.assertEqual(set(hashes), {'fastboot', 'fastbrick-20240709.img'})

    def test_missing_profile(self):
        with self.assertRaises(FileNotFoundError):
            helper.load_profile(pathlib.Path('/nonexistent/echoguide-profile'))

    def test_duplicate_missing_and_malformed_artifacts(self):
        profile, _ = helper.load_profile()
        bad = copy.deepcopy(profile)
        bad['artifacts'].append(copy.deepcopy(bad['artifacts'][0]))
        self.check_bad(bad)
        bad = copy.deepcopy(profile)
        bad['artifacts'] = [a for a in bad['artifacts'] if a['name'] != 'fastboot']
        self.check_bad(bad)
        bad = copy.deepcopy(profile)
        bad['artifacts'][0]['sha256'] = 'not-a-hash'
        self.check_bad(bad)
        bad = copy.deepcopy(profile)
        bad['artifacts'][0]['name'] = '../escape'
        self.check_bad(bad)

    def test_unknown_id_and_schema(self):
        profile, _ = helper.load_profile()
        bad = copy.deepcopy(profile)
        bad['id'] = 'unsupported'
        self.check_bad(bad)
        bad = copy.deepcopy(profile)
        del bad['lkBuild']
        self.check_bad(bad)
        self.check_bad([])

if __name__ == '__main__':
    unittest.main()
