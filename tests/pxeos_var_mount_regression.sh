#!/usr/bin/env bash
# A Linux image can keep /var outside the root filesystem. Hostname and
# system-identity initialization need the ordinary fstab mount only; no
# deployment identity plan or storage-reference rewrite is involved.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="${ROOTPXE_IDENTITY_LIB:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$lib"

target="$tmp/target"; mkdir -p "$target/etc" "$target/var"
printf 'UUID=var-id /var xfs defaults 0 0\n' >"$target/etc/fstab"

declare -A mounted=()
rootpxe_linux_mount_options() { printf rw; }
blkid() {
    case "$*" in
        '-U var-id') [[ ${BLKID_MISSING:-0} != 1 ]] && printf /dev/mock-var ;;
        *'TYPE'*'/dev/mock-var') printf xfs ;;
        *) return 1 ;;
    esac
}
mountpoint() { [[ $1 == -q ]] && [[ -n ${mounted[$2]:-} ]]; }
mount() { local source="${@: -2:1}" target_path="${@: -1}"; mounted[$target_path]="$source"; }
umount() { unset 'mounted[$1]'; }
rootpxe_deployment_identity_target_device_is_block() { [[ $1 == /dev/mock-var ]]; }
rootpxe_deployment_identity_mount_matches_device() { [[ ${mounted[$1]:-} == "$2" ]]; }

rootpxe_deployment_identity_mount_linux_var_filesystem "$target" || fail '/var mount was rejected'
[[ ${mounted[$target/var]:-} == /dev/mock-var ]] || fail '/var mount target mismatch'
rootpxe_deployment_identity_unmount_linux_var_filesystem || fail '/var cleanup failed'
[[ -z ${mounted[$target/var]:-} ]] || fail '/var remained mounted'

# A missing fstab UUID is fail-closed. There is deliberately no frozen-plan
# fallback because this feature no longer changes filesystem identifiers.
if BLKID_MISSING=1 rootpxe_deployment_identity_mount_linux_var_filesystem "$target"; then
    fail 'missing /var UUID unexpectedly mounted'
fi
[[ -z ${mounted[$target/var]:-} ]] || fail 'failed mount left /var mounted'

printf 'PASS: PXEOS separate /var hostname initialization mount regression\n'
