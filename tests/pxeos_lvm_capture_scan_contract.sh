#!/usr/bin/env bash
# Mock-only public LVM discovery barrier.  It checks the disk-wide pvs scan
# before a group leaf, staging directory, or payload writer can run.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

: >"$tmp/proc-cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0
. "$tmp/funcs.sh"

trace="$tmp/scan.trace"
getPartitions() { parts=/dev/mock1; }
blkid() {
    [[ $SCAN_MODE == silent-missing-target ]] && { printf 'LVM2_member\n'; return 0; }
    printf 'ext4\n'
}
pvs() {
    printf 'pvs\n' >>"$trace"
    case $SCAN_MODE in
        warning-empty) printf 'pvs warning\n' >&2; printf '%s\n' '{"report":[{"pv":[]}]}' ;;
        warning-foreign) printf 'pvs warning\n' >&2; printf '%s\n' '{"report":[{"pv":[{"pv_name":"/dev/foreign"}]}]}' ;;
        *) printf '%s\n' '{"report":[{"pv":[]}]}' ;;
    esac
}
rootpxe_lvm_capture_preflight_single() { printf 'leaf\n' >>"$trace"; return 0; }

expect_reject() {
    SCAN_MODE="$1"; : >"$trace"
    if rootpxe_lvm_capture_preflight /dev/mock "$tmp/image"; then fail "$SCAN_MODE accepted"; fi
    grep -Fx pvs "$trace" >/dev/null || fail "$SCAN_MODE skipped scan"
    ! grep -Fx leaf "$trace" >/dev/null || fail "$SCAN_MODE reached leaf"
}

expect_reject warning-empty
expect_reject warning-foreign
expect_reject silent-missing-target

SCAN_MODE=ordinary-empty; : >"$trace"
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail ordinary-empty-rejected
grep -Fx pvs "$trace" >/dev/null || fail ordinary-empty-skipped-scan
! grep -Fx leaf "$trace" >/dev/null || fail ordinary-empty-reached-leaf
[[ ${rootpxe_lvm_active:-} == no ]] || fail ordinary-empty-marked-lvm
printf 'PASS: PXEOS LVM capture scan contract\n'
