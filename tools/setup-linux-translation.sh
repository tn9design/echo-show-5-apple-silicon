#!/bin/bash
# Run only inside the separate disposable Debian ARM guest. No USB commands.
set -euo pipefail
[[ $(uname -m) == aarch64 ]] || { echo 'Expected ARM64 Linux guest'; exit 1; }
[[ $EUID == 0 ]] || { echo 'Run with sudo inside validation guest'; exit 1; }
dpkg --add-architecture amd64
apt-get update
apt-get install -y binfmt-support libc6:amd64 libgcc-s1:amd64 python3
mkdir -p /media/rosetta
mountpoint -q /media/rosetta || mount -t virtiofs rosetta /media/rosetta
/usr/sbin/update-binfmts --install rosetta /media/rosetta/rosetta \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' \
    --mask '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --preserve yes --fix-binary yes
/usr/sbin/update-binfmts --display rosetta
echo 'Runtime prepared; original client execution and mock tests still required.'
