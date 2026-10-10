#!/bin/bash
# Fixed guest-only supervision protocol. No live validation is claimed.
set -eu
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$#" -eq 7 ] || exit 64
mode=$1; attempt=$2; vm=$3; session=$4; hash=$5; boot=$6; account=$7
uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
for value in "$attempt" "$vm" "$session" "$boot"; do [[ "$value" =~ $uuid ]] || exit 64; done
[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || exit 64
[[ "$account" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || exit 64
case "$mode" in dispatch|run|terminal|inspect|render) ;; *) exit 64;; esac
base=/var/lib/echoguide/translation
root=$base/$attempt
unit=echoguide-translation-$attempt.service
binding=$(printf 'version=1\nattempt=%s\nvm=%s\nsession=%s\nhash=%s\nboot=%s\naccount=%s' "$attempt" "$vm" "$session" "$hash" "$boot" "$account")
render() {
  printf '[Service]\nType=exec\nExitType=cgroup\nRemainAfterExit=no\nRestart=no\nKillMode=control-group\nStandardInput=null\nStandardOutput=null\nStandardError=null\n'
  printf 'ExecStart=/bin/bash %s/helper.sh run %s %s %s %s %s %s\n' "$root" "$attempt" "$vm" "$session" "$hash" "$boot" "$account"
  printf 'ExecStopPost=/bin/bash %s/helper.sh terminal %s %s %s %s %s %s\n' "$root" "$attempt" "$vm" "$session" "$hash" "$boot" "$account"
}
[ "$mode" != render ] || { render; exit 0; }
# Dispatch, run and terminal are privileged; inspect remains unprivileged.
[ "$mode" = inspect ] || [ "$(id -u)" -eq 0 ] || exit 77
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || exit 65
safe_root() {
  for p in /var /var/lib /var/lib/echoguide "$base" "$root"; do
    [ -d "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] || return 1
    permissions=$(stat -c %a "$p")
    (( (8#$permissions & 0022) == 0 )) || return 1
  done
}
regular() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ] && [ "$(stat -c %s "$1")" -le 4096 ] || return 1
  permissions=$(stat -c %a "$1"); (( (8#$permissions & 0022) == 0 ))
}
if [ "$mode" = dispatch ]; then
  for p in /var /var/lib /run /run/systemd /run/systemd/system; do
    [ -d "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] || exit 65
    permissions=$(stat -c %a "$p"); (( (8#$permissions & 0022) == 0 )) || exit 65
  done
  for p in /var/lib/echoguide "$base"; do
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then mkdir -m 755 "$p"; fi
    [ -d "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] || exit 65
    permissions=$(stat -c %a "$p"); (( (8#$permissions & 0022) == 0 )) || exit 65
  done
  [ ! -e /run/systemd/system/"$unit" ] && [ ! -L /run/systemd/system/"$unit" ] || exit 65
  mkdir -m 755 "$root" # Exclusive: never reuse an attempt.
  umask 022
  printf '%s\n' "$binding" > "$root/binding"
  source=/home/$account/echoguide/setup-linux-translation.sh
  [ -f "$source" ] && [ ! -L "$source" ] || exit 65
  cp -- "$source" "$root/setup.sh"
  chmod 600 "$root/setup.sh"
  printf '%s  %s\n' "$hash" "$root/setup.sh" | sha256sum -c - >/dev/null
  cp -- "$0" "$root/helper.sh"; chmod 644 "$root/helper.sh"
  render > "$root/unit"
  cp -- "$root/unit" /run/systemd/system/"$unit"
  systemctl daemon-reload
  systemctl start "$unit"
  printf 'ECHOGUIDE-DISPATCHED-v1\n'
  exit 0
fi
safe_root || exit 65
regular "$root/binding" && [ "$(cat "$root/binding")" = "$binding" ] || exit 65
if [ "$mode" = run ]; then
  [[ "${INVOCATION_ID:-}" =~ ^[0-9a-f]{32}$ ]] || exit 65
  [ ! -e "$root/started" ] && [ ! -L "$root/started" ] || exit 65
  umask 022
  printf 'invocation=%s\n' "$INVOCATION_ID" > "$root/started.tmp"
  mv -- "$root/started.tmp" "$root/started"
  [ -f "$root/setup.sh" ] && [ ! -L "$root/setup.sh" ] && [ "$(stat -c %u "$root/setup.sh")" = 0 ] || exit 65
  [ "$(stat -c %a "$root/setup.sh")" = 600 ] || exit 65
  printf '%s  %s\n' "$hash" "$root/setup.sh" | sha256sum -c - >/dev/null
  exec /bin/bash "$root/setup.sh"
fi
if [ "$mode" = terminal ]; then
  [[ "${INVOCATION_ID:-}" =~ ^[0-9a-f]{32}$ ]] || exit 65
  [[ "${SERVICE_RESULT:-}" =~ ^[a-z-]{1,40}$ ]] || exit 65
  [[ "${EXIT_CODE:-unset}" =~ ^[a-z]{1,16}$ ]] || exit 65
  [[ "${EXIT_STATUS:-unset}" =~ ^[A-Za-z0-9]{1,24}$ ]] || exit 65
  [ ! -e "$root/terminal" ] && [ ! -L "$root/terminal" ] || exit 65
  umask 022
  printf 'invocation=%s\nresult=%s\ncode=%s\nstatus=%s\n' "$INVOCATION_ID" "$SERVICE_RESULT" "${EXIT_CODE:-unset}" "${EXIT_STATUS:-unset}" > "$root/terminal.tmp"
  mv -- "$root/terminal.tmp" "$root/terminal"
  exit 0
fi
# BEGIN PURE RUNNING FRAME
emit_running() {
  local started=$1 properties=$2 populated=$3 invocation live active group loaded
  [[ "$started" =~ ^invocation=[0-9a-f]{32}$ ]] || return 1
  [ "${#properties}" -le 4096 ] || return 1
  invocation=${started#invocation=}
  live=$(printf '%s\n' "$properties" | sed -n 's/^InvocationID=//p')
  active=$(printf '%s\n' "$properties" | sed -n 's/^ActiveState=//p')
  group=$(printf '%s\n' "$properties" | sed -n 's/^ControlGroup=//p')
  loaded=$(printf '%s\n' "$properties" | sed -n 's/^LoadState=//p')
  [ "$live" = "$invocation" ] && [ "$loaded" = loaded ] && [ "$group" = /system.slice/"$unit" ] && [ "$populated" = 1 ] || return 1
  case "$active" in active|activating) ;; *) return 1;; esac
  printf 'ECHOGUIDE-INSPECTION-v1\n%s\nreceiptState=running\n%s\n%s\ncgroupPopulated=1\ncategory=unknown\npackageState=unverified\nEND\n' "$binding" "$started" "$properties"
}
# END PURE RUNNING FRAME
# Facts only: no package-clean claim, reconciliation, service control or mutation.
unknown() { printf 'ECHOGUIDE-INSPECTION-v1\ncategory=unknown\nEND\n'; }
regular "$root/started" || { unknown; exit 0; }
started=$(cat "$root/started")
[[ "$started" =~ ^invocation=[0-9a-f]{32}$ ]] || { unknown; exit 0; }
properties=$(systemctl show "$unit" --property=LoadState,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,InvocationID,ControlGroup) || { unknown; exit 0; }
[ "${#properties}" -le 4096 ] || { unknown; exit 0; }
cgroup=$(printf '%s\n' "$properties" | sed -n 's/^ControlGroup=//p')
populated=unknown
if [ "$cgroup" = /system.slice/"$unit" ]; then
  events=/sys/fs/cgroup$cgroup/cgroup.events
  if [ -f "$events" ] && [ ! -L "$events" ]; then
    value=$(sed -n 's/^populated //p' "$events")
    case "$value" in 0|1) populated=$value;; esac
  fi
fi
if [ ! -e "$root/terminal" ] && [ ! -L "$root/terminal" ]; then
  emit_running "$started" "$properties" "$populated" || unknown
  exit 0
fi
regular "$root/terminal" || { unknown; exit 0; }
terminal=$(cat "$root/terminal")
[[ "$terminal" =~ ^invocation=[0-9a-f]{32}$'\n'result=[a-z-]{1,40}$'\n'code=[a-z]{1,16}$'\n'status=[A-Za-z0-9]{1,24}$ ]] || { unknown; exit 0; }
[ "${terminal%%$'\n'*}" = "$started" ] || { unknown; exit 0; }
printf 'ECHOGUIDE-INSPECTION-v1\n%s\n%s\n%s\n%s\ncgroupPopulated=%s\ncategory=unknown\npackageState=unverified\nEND\n' "$binding" "$started" "$terminal" "$properties" "$populated"
