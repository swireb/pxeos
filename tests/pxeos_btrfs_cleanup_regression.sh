#!/usr/bin/env bash
# Btrfs 扩容失败清理：全部挂载/扩容命令均为替身。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d /tmp/pxeos-btrfs-cleanup.XXXXXX)"
case "$tmp" in /tmp/pxeos-btrfs-cleanup.*) ;; *) exit 2 ;; esac
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/btrfs"
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$funcs"
for helper in rootpxe_diagnostic_begin rootpxe_diagnostic_call rootpxe_diagnostic_cleanup; do
    eval "$(sed -n "/^${helper}() {/,/^}/p" "$funcs" | sed "s|/tmp/log|$tmp/log|g")"
done
eval "$(sed -n '/^expandPartition() {/,/^}/p' "$funcs" | sed "s#/tmp/btrfs#$tmp/btrfs#g")"
failures=0
for scenario in resize_failed resize_and_unmount_failed success; do
    trace="$tmp/$scenario.trace"
    : >"$trace"
    status=0
    (
        debugPause() { :; }
        dots() { :; }
        getDiskFromPartition() { disk=/dev/mockdisk; }
        getPartitionNumber() { part_number=1; }
        fsTypeSetting() { fstype=btrfs; }
        mount() { printf 'mount:%s\n' "$*" >>"$trace"; }
        btrfs() { printf 'resize:%s\n' "$*" >>"$trace"; [[ $scenario == success ]]; }
        umount() { printf 'umount:%s\n' "$*" >>"$trace"; [[ $scenario != resize_and_unmount_failed ]]; }
        handleError() { printf 'error:%s\n' "$*" >>"$trace"; rootpxe_diagnostic_cleanup; exit 91; }
        runPartprobe() { printf 'partprobe:%s\n' "$*" >>"$trace"; }
        type=down
        expandPartition /dev/mockbtrfs ''
    ) >"$tmp/$scenario.stdout.log" 2>"$tmp/$scenario.stderr.log" || status=$?
    expected=91
    [[ $scenario == success ]] && expected=0
    if [[ $status -ne $expected ]]; then
        printf 'FAIL: %s status=%s expected=%s\n' "$scenario" "$status" "$expected" >&2
        failures=$((failures + 1))
    fi
    if [[ $(grep -Fc "umount:$tmp/btrfs" "$trace" || true) -ne 1 ]]; then
        printf 'FAIL: %s must attempt one normal umount\n' "$scenario" >&2
        failures=$((failures + 1))
    fi
    if [[ $scenario != success ]]; then
        cleanup_line=$(grep -n '^umount:' "$trace" | cut -d: -f1 || true)
        error_line=$(grep -n '^error:' "$trace" | cut -d: -f1 || true)
        if [[ -z $cleanup_line || -z $error_line || $cleanup_line -ge $error_line ]] || grep -q '^partprobe:' "$trace"; then
            printf 'FAIL: %s cleanup must precede fatal error and stop continuation\n' "$scenario" >&2
            failures=$((failures + 1))
        fi
    fi
done
printf 'Btrfs cleanup: 3 scenarios, %s failures\n' "$failures"
[[ $failures -eq 0 ]]
