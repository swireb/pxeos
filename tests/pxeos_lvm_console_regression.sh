#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Load the production helper in isolation; only unavailable image libraries are
# stubbed, while rootpxe_activate_lvm_vg and rootpxe_console_message are real.
sed -e 's|^\. /usr/share/pxeos/lib/.*|:|' \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
cp "$overlay/usr/share/pxeos/lib/partclone-progress.sh" "$tmp/partclone-progress.sh"
set +u
. "$tmp/funcs.sh" 2>/dev/null
set -u

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
[[ $(grep -c '^\[ERROR\]' "$tmp/failure.out") -ge 2 ]] || fail failure-not-wrapped
grep -Fq '[ERROR] vgchange failed:' "$tmp/failure.out" || fail failure-diagnostic-missing
grep -Fq 'vgchange:-an --select vg_uuid=vg-1 vg0' "$trace" || fail failure-not-deactivated
unset VGCHANGE_FAIL VGCHANGE_OUTPUT
pass 'LVM activation failure preserves rc, wraps diagnostics, and cleans up'

funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
grep -Fq 'rootpxe_activate_lvm_vg "$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name"' "$funcs" || fail capture-does-not-use-lvm-console-helper
! grep -Fq 'rootpxe_wait_before_data_imaging' "$overlay/usr/share/pxeos/lib/funcs.sh" "$overlay/bin/pxeos.upload" "$root/tests/pxeos_capture_regression.sh" "$root/tests/pxeos_partition_regression.sh" || fail imaging-wait-remains
printf 'PASS: PXEOS LVM console regression\n'
