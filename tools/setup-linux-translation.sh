#!/bin/bash
# Run only inside the separate owned Debian 13 ARM guest. No USB/device commands.
# References: Debian update-binfmts(8), systemd.mount(5), systemd.unit(5).
set -euo pipefail
mount_content=$(cat <<'UNIT'
# Managed by EchoGuide: Linux translation mount v1
[Unit]
Description=EchoGuide Apple Linux translation share
Before=binfmt-support.service

[Mount]
What=rosetta
Where=/media/rosetta
Type=virtiofs
Options=ro
TimeoutSec=30

[Install]
WantedBy=multi-user.target
UNIT
)
ordering_content=$(cat <<'UNIT'
# Managed by EchoGuide: Linux translation ordering v1
[Unit]
Requires=media-rosetta.mount
After=media-rosetta.mount
UNIT
)
# Offline rendering is deliberately read-only and does not need Linux/root.
if [[ ${1:-} == --print-units && $# == 1 ]]; then
    printf '=== media-rosetta.mount ===\n%s\n=== binfmt-support.service.d/echoguide-rosetta.conf ===\n%s\n' "$mount_content" "$ordering_content"
    exit 0
fi
[[ $# == 0 ]] || { echo 'Usage: setup-linux-translation.sh [--print-units]'; exit 1; }
[[ $(uname -m) == aarch64 ]] || { echo 'Expected ARM64 Linux guest'; exit 1; }
[[ $EUID == 0 ]] || { echo 'Run with sudo inside the owned validation guest'; exit 1; }
# Fail closed on unrelated hosts and unsupported distributions.
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || { echo 'Expected the owned Debian 13 guest'; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'Expected systemd running inside the guest'; exit 1; }
mount_file=/etc/systemd/system/media-rosetta.mount
ordering_file=/etc/systemd/system/binfmt-support.service.d/echoguide-rosetta.conf
# Preserve existing administrator configuration, including symlinks.
for target in "$mount_file" "$ordering_file"; do
    [[ ! -L $target ]] || { echo "Refusing symlink configuration: $target"; exit 1; }
    if [[ -e $target ]] && ! head -n 1 "$target" | grep -q '^# Managed by EchoGuide:'; then
        echo "Existing unmanaged configuration must be reviewed: $target"; exit 1
    fi
done
dpkg --add-architecture amd64
apt-get update
apt-get install -y binfmt-support libc6:amd64 libgcc-s1:amd64 python3
mkdir -p /media/rosetta /etc/systemd/system/binfmt-support.service.d
install_owned_file() {
    local target=$1 content=$2 temporary
    if [[ -f $target ]] && cmp -s "$target" <(printf '%s\n' "$content"); then return; fi
    temporary=$(mktemp "${target}.XXXXXX")
    printf '%s\n' "$content" > "$temporary"
    chmod 644 "$temporary"
    mv -f "$temporary" "$target"
}
install_owned_file "$mount_file" "$mount_content"
install_owned_file "$ordering_file" "$ordering_content"
systemctl daemon-reload
systemctl enable media-rosetta.mount binfmt-support.service
systemctl start media-rosetta.mount
[[ -x /media/rosetta/rosetta ]] || { echo 'Enable Intel Linux translation in this VM, then retry'; exit 1; }
# Refresh only the named Rosetta handler; never disable all binary-format handlers.
if [[ -e /var/lib/binfmts/rosetta ]]; then
    [[ ! -L /var/lib/binfmts/rosetta ]] || { echo 'Refusing symlink Rosetta database entry'; exit 1; }
    existing=$(/usr/sbin/update-binfmts --display rosetta)
    printf '%s\n' "$existing" | grep -Eq '^[[:space:]]*interpreter = /media/rosetta/rosetta$' || {
        echo 'Existing rosetta handler has another interpreter; review it manually'; exit 1;
    }
    /usr/sbin/update-binfmts --remove rosetta /media/rosetta/rosetta
fi
/usr/sbin/update-binfmts --install rosetta /media/rosetta/rosetta \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' \
    --mask '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --preserve yes --fix-binary yes
/usr/sbin/update-binfmts --enable rosetta
/usr/sbin/update-binfmts --display rosetta
printf '%s\n' 'Persistent mount and registration configured. Guest restart and original-client mock validation are still required.'
