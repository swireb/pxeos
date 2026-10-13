#!/usr/bin/env bash
# Private mock streams; no daemon or real Linux inode reuse is exercised.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-boot-pin-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
. <(sed "s|/tmp/log|$tmp/log|g" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/log-paths.sh")
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eval "$(declare -f rootpxe_log_boot_stream | sed '1s/rootpxe_log_boot_stream/rootpxe_boot_pin_real_stream/')"
rootpxe_log_boot_stream(){
    local rootpxe_test_pin=${4:-} rootpxe_test_identity=$2
    [[ $rootpxe_test_pin =~ ^[1-9][0-9]+$ ]] || return 91
    rootpxe_log_pin_valid "$rootpxe_test_pin" "$rootpxe_test_identity" || return 92
    printf '%s\n' "$rootpxe_test_pin" >"$tmp/pin-$3"
    local rootpxe_test_stream_rc=0
    rootpxe_boot_pin_real_stream "$@" || rootpxe_test_stream_rc=$?
    printf '%s\n' "$rootpxe_test_stream_rc" >"$tmp/rc-$3"
    rootpxe_log_pin_valid "$rootpxe_test_pin" "$rootpxe_test_identity" && return 93
    printf 'RELEASED\n' >"$tmp/released-$3"
    return "$rootpxe_test_stream_rc"
}
rootpxe_log_boot_run cron.log foreground foreground printf 'CURRENT\n'
[[ -f $tmp/pin-foreground && -f $tmp/released-foreground ]] || fail missing-boot-pin-or-eof-release
pin=$(cat "$tmp/pin-foreground")
[[ ! -e /proc/self/fd/$pin ]] || fail launcher-kept-pin
mkfifo "$tmp/gate"
native(){ ( printf 'OLD_START\n'; read -r gate <"$tmp/gate"; printf 'OLD_LAST\n' ) & }
start=$SECONDS
rootpxe_log_boot_run cron.log old background native
[[ $((SECONDS-start)) -lt 2 ]] || fail launcher-waited-for-daemon
rootpxe_log_boot_run cron.log new1 foreground printf 'NEW_ONE\n'
rootpxe_log_boot_run cron.log new2 foreground printf 'NEW_TWO\n'
printf 'release\n' >"$tmp/gate"
for ((index=0;index<1000;index++)); do [[ -f $tmp/released-old ]] && break; sleep .02; done
[[ -f $tmp/released-old ]] || fail old-collector-pin-not-released
grep -q NEW_TWO "$tmp/log/cron.log" || fail latest-log
! grep -q OLD_ "$tmp/log/cron.log" || fail old-collector-wrote-new
printf 'Boot pin: PASS\n'
