#!/usr/bin/env python3
"""Check the published source archive without executing its contents."""
import pathlib
import plistlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(archive) as package:
    names = package.namelist()
    assert len(names) == len(set(names)), 'Duplicate archive entries'
    for entry in package.infolist():
        path = pathlib.PurePosixPath(entry.filename)
        assert not path.is_absolute() and '..' not in path.parts, 'Unsafe archive path'
        assert path.parts[0] == 'EchoGuide-source', 'Unexpected archive root'
        assert not stat.S_ISLNK(entry.external_attr >> 16), 'Archive contains a symlink'
        assert not any(part in {'.git', '.build', 'dist', '__MACOSX', '__pycache__'}
                       or part.startswith('._') for part in path.parts), 'Build metadata in archive'
        assert path.suffix.lower() not in {'.img', '.iso', '.dmg', '.heic'}, 'Device or VM image in archive'
    required = ['Package.swift', 'LICENSE', 'README.md',
                'Sources/EchoGuide/EchoGuideApp.swift',
                'Sources/EchoGuideCLI/main.swift',
                'Sources/EchoGuideMCP/main.swift',
                'Sources/EchoGuideCore/Workflow.swift',
                'Sources/EchoGuideCore/NativeApprovalController.swift',
                'Sources/EchoGuideCore/NativePilotComposition.swift',
                'Sources/EchoGuideCore/NativePilotCoordinator.swift',
                'Sources/EchoGuideCore/Resources/checkers-v1.json',
                'Sources/EchoGuideCore/Resources/compare-mock.py',
                'Sources/EchoGuideCore/Resources/setup-linux-translation.sh',
                'Sources/EchoGuideCore/Resources/translation-attempt.sh',
                'tools/test-translation-attempt.py',
                'Assets/EchoGuide-icon.png', 'Assets/EchoGuide.icns',
                'script/build-icon.sh',
                'skills/echo-guide/SKILL.md', 'script/automation.entitlements',
                'tools/bounded-unlock.py']
    for path in required:
        assert 'EchoGuide-source/' + path in names, 'Missing source deliverable: ' + path
    entitlements = plistlib.loads(package.read('EchoGuide-source/script/automation.entitlements'))
    icon = package.read('EchoGuide-source/Assets/EchoGuide.icns')
    assert icon[:4] == b'icns' and int.from_bytes(icon[4:8], 'big') == len(icon), 'Invalid icon family'
    assert entitlements == {'com.apple.security.automation.apple-events': True}, 'Unexpected signing permissions'
print('Source archive structure, deliverables and signing permissions passed')
