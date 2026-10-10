#!/bin/bash
set -euo pipefail
fixture_source=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$fixture_source/../.." && pwd)
fixture_output=${1:-"$PWD/results"}
readline_prefix=${READLINE_PREFIX:-/opt/homebrew/opt/readline}
if [ ! -f "$readline_prefix/include/readline/readline.h" ]; then
    echo 'Set READLINE_PREFIX to an existing GNU Readline 8.x installation. This harness installs nothing.' >&2
    exit 2
fi
mkdir -p "$fixture_output"
fixture_output=$(cd "$fixture_output" && pwd)
fixture_runtime=$(mktemp -d /private/tmp/echoguide-serial-harness.XXXXXX)
trap 'rm -rf "$fixture_runtime"' EXIT
cp "$fixture_source/Harness.swift" "$fixture_source/pty_shell.py" "$fixture_source/readline_shell.c" "$fixture_runtime/"
mkdir -p "$fixture_runtime/inputs"
python3 - "$repo_root" "$fixture_runtime/inputs" <<'PYTHON'
import pathlib,sys
source=pathlib.Path(sys.argv[1])/'Sources/EchoGuideCore'
output=pathlib.Path(sys.argv[2])
for name in ['SerialTransport.swift','SerialLogin.swift']:
    (output/name).write_bytes((source/name).read_bytes())
username=(source/'GuestUsername.swift').read_text().split('extension WorkflowEngine')[0]
(output/'GuestUsername.swift').write_text(username)
fixed=(source/'GuestBootstrap.swift').read_text()
new="printf '\\\\nECHOGUIDE-BEGIN"
old="printf 'ECHOGUIDE-BEGIN"
assert fixed.count(new)==1, 'Expected the reviewed newline producer'
(output/'GuestBootstrap.fixed.swift').write_text(fixed)
(output/'GuestBootstrap.original.swift').write_text(fixed.replace(new,old))
PYTHON
xcrun clang -I"$readline_prefix/include" -L"$readline_prefix/lib" -lreadline "$fixture_runtime/readline_shell.c" -o "$fixture_runtime/readline-shell"
for variant in original fixed; do
    xcrun swiftc -parse-as-library -module-cache-path "$fixture_runtime/module-cache" \
        "$fixture_runtime/Harness.swift" "$fixture_runtime/inputs/GuestBootstrap.$variant.swift" \
        "$fixture_runtime/inputs/GuestUsername.swift" "$fixture_runtime/inputs/SerialTransport.swift" \
        "$fixture_runtime/inputs/SerialLogin.swift" -o "$fixture_runtime/$variant-harness"
    /usr/bin/python3 "$fixture_runtime/pty_shell.py" "$fixture_runtime/$variant-harness"
    cp "$fixture_runtime/$variant-harness-results.json" "$fixture_output/"
done
/usr/bin/python3 - "$fixture_output" <<'PY'
import json,sys,pathlib
root=pathlib.Path(sys.argv[1])
a=json.loads((root/'original-harness-results.json').read_text())
b=json.loads((root/'fixed-harness-results.json').read_text())
assert len(a)==6 and len(b)==6
for row in a:
    if row['shell']=='readline-shell':
        assert row['exit']==1 and 'begin markers: 0, end markers: 1' in row['error'],row
    else:
        assert row['exit']==0 and row['parsed']==2,row
assert all(row['exit']==0 and row['parsed']==2 for row in b),b
print('Verified: original fails both modern-Readline fixtures; fixed passes all six scenarios / twelve exchanges.')
PY
