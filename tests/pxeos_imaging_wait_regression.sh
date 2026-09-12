#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Load the production helpers in an isolated copy.  The PXEOS image-only
# libraries are not available on the host, so replace only their source lines
# and retain the production function bodies under test.
sed -e 's|^\. /usr/share/pxeos/lib/.*|:|' \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
cp "$overlay/usr/share/pxeos/lib/partclone-progress.sh" "$tmp/partclone-progress.sh"
set +u
. "$tmp/funcs.sh" 2>/dev/null
set -u

rootpxe_data_imaging_wait_marker="$tmp/imaging-wait.marker"
trace="$tmp/trace"
sleep() {
    printf 'sleep:%s\n' "$*" >>"$trace"
    [[ ${WAIT_SLEEP_FAIL:-0} != 1 ]]
}
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

# Successful activation captures all output and keeps the console clean.
rootpxe_partition_progress_enabled=no
rootpxe_partition_progress_initialize_runtime
export VGCHANGE_OUTPUT='udevd: conflicting device node /dev/mapper/root found, link to /dev/dm-0 will not be created'
: >"$trace"
rootpxe_activate_lvm_vg vg-1 vg0 >"$tmp/vg-success.out" 2>&1 || fail lvm-success-status
! grep -Fq "$VGCHANGE_OUTPUT" "$tmp/vg-success.out" || fail lvm-success-output-leaked
grep -Fq 'vgchange:-ay --select vg_uuid=vg-1 vg0' "$trace" || fail lvm-success-not-activated
unset VGCHANGE_OUTPUT
pass 'LVM activation success is silent'

# Failed activation keeps rc=7, wraps a long diagnostic, and deactivates.
export VGCHANGE_FAIL=1 VGCHANGE_OUTPUT='vgchange failed: this deliberately long diagnostic must be wrapped by the PXEOS console formatter before display'
: >"$trace"
set +e
rootpxe_activate_lvm_vg vg-1 vg0 >"$tmp/vg-failure.out" 2>&1
vg_status=$?
set -e
[[ $vg_status -eq 7 ]] || fail "lvm-failure-status-$vg_status"
[[ $(grep -c '^\[ERROR\]' "$tmp/vg-failure.out") -ge 2 ]] || fail lvm-failure-not-wrapped
grep -Fq '[ERROR] vgchange failed:' "$tmp/vg-failure.out" || fail lvm-failure-diagnostic-missing
grep -Fq 'vgchange:-an --select vg_uuid=vg-1 vg0' "$trace" || fail lvm-failure-not-deactivated
unset VGCHANGE_FAIL VGCHANGE_OUTPUT
pass 'LVM activation failure preserves rc, wraps diagnostics, and cleans up'

# The marker is shared by the LVM child shell and its parent, resets for the
# next task, and is removed when the sleep command fails.
: >"$trace"
rootpxe_partition_progress_initialize_runtime
(
    rootpxe_wait_before_data_imaging || exit 1
) || fail imaging-wait-child
rootpxe_wait_before_data_imaging || fail imaging-wait-parent
[[ $(grep -c '^sleep:3$' "$trace") -eq 1 ]] || fail imaging-wait-cross-shell
rootpxe_partition_progress_initialize_runtime
rootpxe_wait_before_data_imaging || fail imaging-wait-reset
[[ $(grep -c '^sleep:3$' "$trace") -eq 2 ]] || fail imaging-wait-next-task
export WAIT_SLEEP_FAIL=1
rootpxe_partition_progress_initialize_runtime
rootpxe_wait_before_data_imaging && fail imaging-wait-failure-hidden
[[ ! -e "$rootpxe_data_imaging_wait_marker" ]] || fail imaging-wait-marker-left
unset WAIT_SLEEP_FAIL
! grep -Eiq 'waiting[[:space:]]+3[[:space:]]+seconds|等待.?3秒' "$overlay/usr/share/pxeos/lib/funcs.sh" "$overlay/bin/pxeos.upload" || fail imaging-wait-extra-prompt
pass 'imaging wait marker is cross-shell, task-scoped, and rollback-safe'

# Every production imaging engine has a wait immediately before its first
# invocation; no unrelated probe/metadata/dd path gets the wait helper.  Keep
# this as explicit line adjacency so dynamic partclone.$fstype is covered and
# no AWK END clause can mask a failed assertion.
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
mapfile -t wait_lines < <(grep -n -F 'rootpxe_wait_before_data_imaging ||' "$funcs" | cut -d: -f1)
[[ ${#wait_lines[@]} -eq 7 ]] || fail imaging-wait-function-call-count
assert_adjacent() {
    local wait_line="$1" engine_line="$2" label="$3"
    [[ $wait_line =~ ^[1-9][0-9]*$ && $engine_line =~ ^[1-9][0-9]*$ && $engine_line -gt $wait_line && $((engine_line - wait_line)) -le 2 ]] || fail "$label-wait-not-adjacent"
}
lvm_engine_line=$(grep -n -F 'partclone.extfs' "$funcs" | cut -d: -f1)
assert_adjacent "${wait_lines[0]}" "$lvm_engine_line" lvm-capture
mapfile -t write_engine_lines < <({ grep -n -F 'partclone.restore' "$funcs"; grep -n -F 'if ( set -o pipefail; pigz -dc </tmp/pigz1 | partimage restore' "$funcs"; } | sort -n | cut -d: -f1)
[[ ${#write_engine_lines[@]} -eq 4 ]] || fail writeImage-engine-count
for index in 0 1 2 3; do
    assert_adjacent "${wait_lines[$((index + 1))]}" "${write_engine_lines[$index]}" "writeImage-engine-$index"
done
mapfile -t save_engine_lines < <(grep -n -F 'partclone.$fstype "${rootpxe_partclone_progress_args' "$funcs" | cut -d: -f1)
[[ ${#save_engine_lines[@]} -eq 2 ]] || fail savePartition-engine-count
assert_adjacent "${wait_lines[5]}" "${save_engine_lines[0]}" savePartition-first
assert_adjacent "${wait_lines[6]}" "${save_engine_lines[1]}" savePartition-second
upload="$overlay/bin/pxeos.upload"
upload_wait=$(grep -n -F 'rootpxe_wait_before_data_imaging || handleError' "$upload" | cut -d: -f1)
upload_engine=$(grep -n -F 'partclone.imager' "$upload" | cut -d: -f1)
[[ $upload_wait =~ ^[1-9][0-9]*$ && $upload_engine =~ ^[1-9][0-9]*$ && $upload_wait -lt $upload_engine ]] || fail imaging-wait-upload-order
[[ $(grep -Fc 'rootpxe_wait_before_data_imaging || handleError' "$upload") -eq 1 ]] || fail imaging-wait-upload-count
pass 'all Partclone/Partimage data engines are guarded once before first use'

printf 'PASS: PXEOS imaging wait regression\n'
