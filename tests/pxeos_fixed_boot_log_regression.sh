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
wait_calls=0
wait(){ wait_calls=$((wait_calls+1)); builtin wait "$@"; }
saved_snapshot=$(declare -f rootpxe_log_snapshot)
rootpxe_log_snapshot(){ return 1; }
rc=0; rootpxe_log_boot_run cron.log read_failure foreground native >"$tmp/read-failure" 2>&1 || rc=$?
[[ $rc == 7 ]] || fail read-failure-native-rc
[[ $wait_calls == 0 ]] || fail read-failure-waited-for-eof
grep -q unavailable "$tmp/read-failure" || fail read-failure-notice
rootpxe_log_notice cron.log >"$tmp/read-notice"
grep -q unavailable "$tmp/read-notice" || fail read-failure-false-reference
unset -f wait
eval "$saved_snapshot"
rootpxe_log_boot_run ssh-keygen.log quiet foreground true
[[ ! -s $tmp/log/ssh-keygen.log ]] || fail quiet-success-noise
native(){ ( sleep .4; printf 'BACKGROUND_OLD\n' ) & }
wait_calls=0
wait(){ wait_calls=$((wait_calls+1)); builtin wait "$@"; }
start=$SECONDS
rootpxe_log_boot_run cron.log start background native
[[ $wait_calls == 0 && $((SECONDS-start)) -lt 10 ]] || fail daemon-waited
unset -f wait
rootpxe_log_boot_run cron.log restart foreground printf 'CURRENT\n'
sleep .8
grep -q CURRENT "$tmp/log/cron.log" || fail current
! grep -q BACKGROUND_OLD "$tmp/log/cron.log" || fail old-daemon-crossed
printf 'Fixed boot log: PASS\n'
