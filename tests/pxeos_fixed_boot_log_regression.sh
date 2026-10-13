#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
. "$root/tests/task-log-test-support.sh"
tmp=$(mktemp -d /tmp/pxeos-boot-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for script in S40network S50crond S50sshd; do
    grep -q log-paths.sh "$overlay/etc/init.d/$script" || fail "$script missing-safe-log-helper"
done
. <(sed "s|/tmp/log|$tmp/log|g" "$overlay/usr/share/pxeos/lib/log-paths.sh")
native(){ printf 'OK token=boot-fake-secret\n'; return "${native_rc:-0}"; }
rootpxe_log_boot_run ssh-service.log start foreground native
grep -q 'token=\[REDACTED\]' "$tmp/log/ssh-service.log" || fail redact
split_secret(){ printf 'password="first'; sleep .02; printf ' second" token=foo\n'; }
rootpxe_log_boot_run dhcp.log dhcp:eth0 foreground-append split_secret
rootpxe_log_boot_run dhcp.log dhcp:eth1 foreground-append printf 'SECOND_INTERFACE\n'
grep -q 'OP=dhcp:eth0' "$tmp/log/dhcp.log" || fail first-interface
grep -q 'OP=dhcp:eth1' "$tmp/log/dhcp.log" || fail second-interface
! grep -Eq 'first|second|foo' "$tmp/log/dhcp.log" || fail split-secret
native_rc=7; rc=0; rootpxe_log_boot_run ssh-service.log start foreground native || rc=$?
[[ $rc == 7 ]] || fail native-rc
TASK_LOG_TEST_LOCK_BUSY=yes
called=no; native(){ called=yes; return 7; }
rc=0; rootpxe_log_boot_run ssh-service.log start background native >"$tmp/failure" 2>&1 || rc=$?
[[ $called == yes && $rc == 7 ]] || fail sink-skipped-native
grep -q unavailable "$tmp/failure" || fail sink-notice
rootpxe_log_notice ssh-service.log >"$tmp/failed-notice"
grep -q unavailable "$tmp/failed-notice" || fail old-lifecycle-reference
! grep -q Details "$tmp/failed-notice" || fail stale-details
TASK_LOG_TEST_LOCK_BUSY=no
native(){ return 7; }
saved_stream=$(declare -f rootpxe_log_boot_stream)
rootpxe_log_boot_stream(){ return 0; }
close_calls=0; held_fd=''; wait_calls=0
wait(){ wait_calls=$((wait_calls+1)); builtin wait "$@"; }
saved_run=$(declare -f rootpxe_log_boot_run)
# Inject only the close boundary in the exact current function. Mocking all
# exec calls would also distort acquisition of the real dynamic descriptors.
rootpxe_boot_test_close_failure(){ close_calls=$((close_calls+1)); held_fd=$rootpxe_boot_log_fd; return 1; }
eval "$(printf '%s\n' "$saved_run" | sed 's/if exec {rootpxe_boot_log_fd}>&-; then/if rootpxe_boot_test_close_failure; then/')"
rc=0; rootpxe_log_boot_run cron.log fd_close foreground native >"$tmp/close-failure" 2>&1 || rc=$?
[[ $rc == 7 ]] || fail close-failure-native-rc
[[ $close_calls == 1 ]] || fail close-failure-boundary-not-exercised
[[ $wait_calls == 0 ]] || fail close-failure-waited-for-eof
grep -q unavailable "$tmp/close-failure" || fail close-failure-notice
exec {held_fd}>&-
unset -f rootpxe_boot_test_close_failure wait
eval "$saved_run"
eval "$saved_stream"
native(){ ( sleep .4; printf 'BACKGROUND_OLD\n' ) & }
start=$SECONDS
rootpxe_log_boot_run cron.log start background native
[[ $((SECONDS-start)) -lt 2 ]] || fail daemon-waited
rootpxe_log_boot_run cron.log restart foreground printf 'CURRENT\n'
sleep .8
grep -q CURRENT "$tmp/log/cron.log" || fail current
! grep -q BACKGROUND_OLD "$tmp/log/cron.log" || fail old-daemon-crossed
printf 'Fixed boot log: PASS\n'
