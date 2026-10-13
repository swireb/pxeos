#!/usr/bin/env bash
# Real raw parser buffers, fake filesystem tools; never access a device.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d /tmp/pxeos-fixed-fs-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$funcs"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rootpxe_task_log_initialize
rootpxe_diagnostic_begin ntfsresize.log
raw=$rootpxe_log_raw_path
ntfs_probe(){ printf 'you might resize at 123456789 bytes\npassword="fake probe secret"\n'; printf '%070000d\n' 0; printf 'Ended successfully\nLAST_FS_ERROR\n'; return "${native_rc:-0}"; }
rootpxe_diagnostic_call ntfsresize.log "$raw" overwrite ntfs_probe
size=$(sed -n 's/.*you might resize at\s\+\([0-9]\+\).*$/\1/pi' "$raw")
[[ $size == 123456789 ]] || fail changed-ntfs-size-parser
grep -q 'Ended successfully' "$raw" || fail raw-test-string-lost
grep -q 'fake probe secret' "$raw" || fail raw-was-redacted
! grep -q 'fake probe secret' "$tmp/log/ntfsresize.log" || fail published-secret
grep -q LAST_FS_ERROR "$tmp/log/ntfsresize.log" || fail tail-rootcause-lost
native_rc=1; rc=0; rootpxe_diagnostic_call ntfsresize.log "$raw" overwrite ntfs_probe || rc=$?
[[ $rc == 1 ]] || fail allowed-fsck-status-changed
TASK_LOG_TEST_LOCK_BUSY=yes
native_rc=7; rc=0; rootpxe_diagnostic_call ntfsresize.log "$raw" overwrite ntfs_probe || rc=$?
[[ $rc == 7 ]] || fail sink-failure-changed-native-status
grep -q 'you might resize at' "$raw" || fail sink-failure-lost-raw
TASK_LOG_TEST_LOCK_BUSY=no
rootpxe_diagnostic_cleanup
[[ ! -e $raw ]] || fail raw-not-cleaned
printf 'Fixed FS log: PASS\n'
