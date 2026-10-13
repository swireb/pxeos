#!/usr/bin/env bash
# Pure native text only: no Linux mount, VG, device or task runs.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
if grep -nE '/tmp/rootpxe-linux-(vgchange|mount)-output' "$funcs"; then
    printf 'FAIL: dispersed Linux diagnostic paths\n' >&2; exit 1
fi
tmp=$(mktemp -d /tmp/pxeos-linux-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$funcs"
eval "$(sed -n '/^rootpxe_run_logged_typed_native() {/,/^}/p' "$funcs")"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rootpxe_task_log_initialize
status=CALLER_STATUS; name=CALLER_NAME; target=CALLER_TARGET; raw=CALLER_RAW; dir=CALLER_DIR; file=CALLER_FILE
native(){
    [[ $status == CALLER_STATUS && $name == CALLER_NAME && $target == CALLER_TARGET && $raw == CALLER_RAW && $dir == CALLER_DIR && $file == CALLER_FILE ]] || return 91
    printf 'ARGS=%s\n' "$*" >>"$tmp/calls"
    printf 'WARNING native statistic token=FAKE_LINUX_SECRET\n'
    return "${native_rc:-0}"
}
protocol(){ if rootpxe_run_logged_typed_native linux-lvm.log vg0 native -ay --select vg_uuid=uuid vg0; then printf yes; else printf no; fi; }
[[ $(protocol) == yes ]] || fail activation-stdout
native_rc=7
[[ $(protocol) == no ]] || fail activation-rc
grep -q 'ARGS=-ay --select vg_uuid=uuid vg0' "$tmp/calls" || fail activation-argv
[[ -f $tmp/log/linux-lvm.log ]] || fail lvm-fixed-log
! grep -q FAKE_LINUX_SECRET "$tmp/log/linux-lvm.log" || fail lvm-secret
native_rc=0
rootpxe_run_logged_typed_native linux-mount.log /dev/mockroot native -t xfs -o rw,nouuid /dev/mockroot /private/mount
grep -q 'ARGS=-t xfs -o rw,nouuid /dev/mockroot /private/mount' "$tmp/calls" || fail mount-argv
[[ -f $tmp/log/linux-mount.log ]] || fail mount-fixed-log
# Reproduce the API's former all-chmod trace: log buffers legitimately get
# 0600, but this must not be mistaken for changing the existing hostname.
chmod(){ printf 'chmod:%s\n' "$*" >>"$tmp/all-mode-trace"; command chmod "$@"; }
rootpxe_run_logged_typed_native linux-mount.log /dev/mockroot native mode-trace
grep -q 'chmod:600 .*log/' "$tmp/all-mode-trace" || fail diagnostic-mode-trace
! grep -q '/etc/hostname' "$tmp/all-mode-trace" || fail unexpected-hostname-mode
printf 'Diagnostic-only mode trace: %s\n' "$(head -n 1 "$tmp/all-mode-trace")"
unset -f chmod
saved_raw=$(declare -f rootpxe_log_raw_file)
rootpxe_log_raw_file(){ return 1; }
native_rc=7; rc=0
rootpxe_run_logged_typed_native linux-mount.log /dev/mockroot native fault >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
[[ $rc == 7 && ! -s $tmp/stdout ]] || fail raw-fault-native-rc
grep -q 'ARGS=fault' "$tmp/calls" || fail raw-fault-skipped-native
grep -q unavailable "$tmp/stderr" || fail raw-fault-notice
eval "$saved_raw"
saved_publish=$(declare -f rootpxe_log_publish)
rootpxe_log_publish(){ return 1; }
native_rc=0
[[ $(protocol 2>"$tmp/publish-stderr") == yes ]] || fail publish-fault-protocol
grep -q unavailable "$tmp/publish-stderr" || fail publish-fault-notice
eval "$saved_publish"
grep -q 'CODE=LINUX_ROOT_MOUNT_FAILED' "$funcs" || fail mount-code
grep -q 'rootpxe_linux_cleanup_selected_vg.*handleError.*LINUX_ROOT_MOUNT_FAILED' "$funcs" || fail mount-cleanup
printf 'Fixed Linux log: PASS\n'
