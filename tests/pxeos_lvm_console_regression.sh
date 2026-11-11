#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
. "$root/tests/task-log-test-support.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Exercise only the production logging and LVM helpers needed by this fixture.
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
task_log_test_load_helpers "$funcs"
for helper in rootpxe_activate_lvm_vg rootpxe_lvm_native; do
    eval "$(sed -n "/^$helper() {/,/^}/p" "$funcs")"
done
rootpxe_task_log_initialize || fail task-log-initialize
task_log=$(rootpxe_task_log_path)

trace="$tmp/trace"
vgchange() {
    printf 'vgchange:%s\n' "$*" >>"$trace"
    if [[ $1 == -ay && ${VGCHANGE_OUTPUT:-} != '' ]]; then
        printf '%s\n' "$VGCHANGE_OUTPUT"
    fi
    if [[ $1 == -ay && ${VGCHANGE_FAIL:-0} == 1 ]]; then
        printf '%s\n' "${VGCHANGE_OUTPUT:-vgchange failed}" >&2
        return 7
    fi
    return 0
}

export VGCHANGE_OUTPUT='udevd: conflicting device node /dev/mapper/root found, link to /dev/dm-0 will not be created'
: >"$trace"
rootpxe_activate_lvm_vg vg-1 vg0 >"$tmp/success.out" 2>&1 || fail success-status
! grep -Fq "$VGCHANGE_OUTPUT" "$tmp/success.out" || fail success-output-leaked
grep -Fq "$VGCHANGE_OUTPUT" "$task_log" || fail success-warning-not-retained
grep -Fq 'vgchange:-ay --select vg_uuid=vg-1 vg0' "$trace" || fail success-not-activated
unset VGCHANGE_OUTPUT
pass 'LVM activation success is silent'

export VGCHANGE_FAIL=1 VGCHANGE_OUTPUT='vgchange failed: this deliberately long diagnostic must be wrapped by the PXEOS console formatter before display'
: >"$trace"
set +e
rootpxe_activate_lvm_vg vg-1 vg0 >"$tmp/failure.out" 2>&1
vg_status=$?
set -e
[[ $vg_status -eq 7 ]] || fail "failure-status-$vg_status"
[[ $(grep -c '^\[ERROR\]' "$tmp/failure.out") -eq 1 ]] || fail failure-not-concise
grep -Fq 'Task log:' "$tmp/failure.out" || fail failure-log-location-missing
! grep -Fq "$VGCHANGE_OUTPUT" "$tmp/failure.out" || fail failure-console-diagnostic-leaked
grep -Fq "$VGCHANGE_OUTPUT" "$task_log" || fail failure-diagnostic-not-retained
grep -Fq 'vgchange:-an --select vg_uuid=vg-1 vg0' "$trace" || fail failure-not-deactivated
unset VGCHANGE_FAIL VGCHANGE_OUTPUT
pass 'LVM activation failure preserves rc, logs diagnostics, and cleans up'

# Execute the precise production XFS mount branch with a fake native mount;
# neither the dispatcher nor mount may probe unrelated filesystem types.
vg=vg0; lv_name=root; xfs_mount=/tmp/known-xfs-mount
mount() { printf '%s\n' "$*" >"$tmp/mount-argv"; printf 'native XFS mount failure detail\n' >&2; return 7; }
rootpxe_restore_status_file="$tmp/restore-status"
eval "$(sed -n '/^    rootpxe_restore_lvm_fail() {/,/^    }/p' "$funcs")"
xfs_mount_branch() { eval "$(grep -F 'rootpxe_run_logged_mutation mount "/dev/$vg/$lv_name" mount -t xfs -o rw,nouuid' "$funcs")"; }
rc=0; xfs_mount_branch >"$tmp/mount-console" 2>&1 || rc=$?
[[ $rc == 1 ]] || fail mount-branch-did-not-fail
[[ $(cat "$tmp/mount-argv") == '-t xfs -o rw,nouuid /dev/vg0/root /tmp/known-xfs-mount' ]] || fail explicit-xfs-mount-argv
[[ $(<"$rootpxe_restore_status_file") == 'LVM_XFS_GROW_MOUNT_FAILED|lv_root' ]] || fail mount-failure-code-missing
grep -Fq 'CODE=${rootpxe_restore_lvm_error_code:-LVM_RESTORE_FAILED} REASON=${rootpxe_restore_lvm_error_reason:-unknown}' "$overlay/bin/pxeos.download" || fail mount-failure-status-not-forwarded
. "$overlay/usr/share/pxeos/lib/message-format.sh"
IFS='|' read -r mount_code mount_reason <"$rootpxe_restore_status_file"
rootpxe_task_console_failure ERROR "PXEOS_STAGE=restore_lvm CODE=$mount_code REASON=$mount_reason" >>"$tmp/mount-console"
grep -Fq 'XFS growth mount failed' "$tmp/mount-console" || fail mount-console-summary-missing
! grep -Fq 'CODE=' "$tmp/mount-console" || fail mount-code-console-leaked
! grep -Fq 'native XFS mount failure detail' "$tmp/mount-console" || fail mount-detail-console-leaked
grep -Fq 'CODE=LVM_XFS_GROW_MOUNT_FAILED REASON=lv_root' "$task_log" || fail mount-failure-code-not-logged
grep -Fq 'native XFS mount failure detail' "$task_log" || fail mount-native-diagnostic-missing
pass 'explicit XFS mount preserves failure code and private native detail'

grep -Fq 'rootpxe_activate_lvm_vg "$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name"' "$funcs" || fail capture-does-not-use-lvm-console-helper
! grep -Fq 'rootpxe_wait_before_data_imaging' "$overlay/usr/share/pxeos/lib/funcs.sh" "$overlay/bin/pxeos.upload" "$root/tests/pxeos_capture_regression.sh" "$root/tests/pxeos_partition_regression.sh" || fail imaging-wait-remains
printf 'PASS: PXEOS LVM console regression\n'
