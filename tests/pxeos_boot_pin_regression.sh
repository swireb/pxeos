#!/usr/bin/env bash
# Private mock calls; no daemon or real Linux inode reuse is exercised.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-boot-pin-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
. <(sed "s|/tmp/log|$tmp/log|g" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/log-paths.sh")
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
native_pin(){
    captured_pin=$rootpxe_boot_pin
    captured_identity=$rootpxe_boot_identity
    rootpxe_log_pin_valid "$captured_pin" "$captured_identity" || return 91
    printf 'CURRENT\n'
}
rootpxe_log_boot_run cron.log foreground foreground native_pin
[[ ! -e /proc/self/fd/$captured_pin ]] || fail launcher-kept-pin
grep -q CURRENT "$tmp/log/cron.log" || fail missing-current
# A synchronous nested restart changes inode: old completion must not replace it.
native_restart(){
    old_pin=$rootpxe_boot_pin; old_identity=$rootpxe_boot_identity
    rootpxe_log_boot_run cron.log new foreground printf 'NEW_ONLY\n'
    rootpxe_log_pin_valid "$old_pin" "$old_identity" || return 92
    printf 'OLD_COMPLETION\n'
}
rootpxe_log_boot_run cron.log old foreground native_restart >"$tmp/old-call" 2>&1
grep -q NEW_ONLY "$tmp/log/cron.log" || fail latest-log
! grep -q OLD_COMPLETION "$tmp/log/cron.log" || fail old-call-wrote-new
[[ ! -e /proc/self/fd/$old_pin ]] || fail old-pin-not-released
for index in 1 2 3; do
    rootpxe_log_boot_run cron.log "$index" background native_pin
    [[ ! -e /proc/self/fd/$captured_pin ]] || fail repeated-pin-leak
done
printf 'Boot pin: PASS\n'
