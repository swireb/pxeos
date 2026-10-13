#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
. "$root/tests/task-log-test-support.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Load the production helper in isolation; only unavailable image libraries are
# stubbed, while rootpxe_activate_lvm_vg and rootpxe_console_message are real.
sed -e 's|^\. /usr/share/pxeos/lib/.*|:|' \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
cp "$overlay/usr/share/pxeos/lib/partclone-progress.sh" "$tmp/partclone-progress.sh"
sed "s|/tmp/log|$tmp/log|g" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/log-paths.sh" >"$tmp/log-paths.sh"
printf '\nif declare -F task_log_test_emulate_pin_flags >/dev/null; then task_log_test_emulate_pin_flags; fi\n' >>"$tmp/log-paths.sh"
for rootpxe_test_funcs_copy in "$tmp/funcs.sh" "$tmp/legacy-funcs.sh"; do
    [[ ! -f $rootpxe_test_funcs_copy ]] || sed -i -e "s|/tmp/log|$tmp/log|g" -e "s|^rootpxe_log_paths_lib=.*|rootpxe_log_paths_lib=$tmp/log-paths.sh|" "$rootpxe_test_funcs_copy"
done
. "$root/tests/task-log-test-support.sh"
set +u
. "$tmp/funcs.sh" 2>/dev/null
set -u
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
rootpxe_restore_lvm_fail() { rootpxe_task_console_failure ERROR "Mount failed CODE=$1 TARGET=$2"; }
xfs_mount_branch() { eval "$(grep -F 'rootpxe_run_logged_mutation mount "/dev/$vg/$lv_name" mount -t xfs -o rw,nouuid' "$overlay/usr/share/pxeos/lib/funcs.sh")"; }
rc=0; xfs_mount_branch >"$tmp/mount-console" 2>&1 || rc=$?
[[ $rc == 1 ]] || fail mount-branch-did-not-fail
[[ $(cat "$tmp/mount-argv") == '-t xfs -o rw,nouuid /dev/vg0/root /tmp/known-xfs-mount' ]] || fail explicit-xfs-mount-argv
grep -Fq 'CODE=LVM_XFS_GROW_MOUNT_FAILED' "$tmp/mount-console" || fail mount-failure-code-missing
! grep -Fq 'native XFS mount failure detail' "$tmp/mount-console" || fail mount-detail-console-leaked
grep -Fq 'native XFS mount failure detail' "$task_log" || fail mount-native-diagnostic-missing
pass 'explicit XFS mount preserves failure code and private native detail'

funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
grep -Fq 'rootpxe_activate_lvm_vg "$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name"' "$funcs" || fail capture-does-not-use-lvm-console-helper
! grep -Fq 'rootpxe_wait_before_data_imaging' "$overlay/usr/share/pxeos/lib/funcs.sh" "$overlay/bin/pxeos.upload" "$root/tests/pxeos_capture_regression.sh" "$root/tests/pxeos_partition_regression.sh" || fail imaging-wait-remains
printf 'PASS: PXEOS LVM console regression\n'
