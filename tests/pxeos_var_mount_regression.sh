#!/usr/bin/env bash
# A Linux deployment may keep /var outside the root filesystem.  The identity
# marker lives below /var/lib, so its mount must be resolved from the frozen
# plan both before and after filesystem UUIDs change.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="${ROOTPXE_IDENTITY_LIB:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$lib"

target="$tmp/target"; mkdir -p "$target/etc" "$target/var"
printf 'UUID=old-var /var xfs defaults 0 0\n' >"$target/etc/fstab"
plan="$tmp/plan.json"
printf '%s\n' '{"plan":{"topology":{"disks":[{"partitions":[{"targetDevice":"/dev/mock-var","oldPartitionId":"old-var-part","originalFilesystemUuid":"old-var"}]}]},"disks":[{"partitions":[{"targetDevice":"/dev/mock-var","filesystem":"xfs","filesystemUuid":"new-var"}]}]}}' >"$plan"
rootpxe_deployment_identity_plan_file="$plan"

declare -A mounted=()
rootpxe_deployment_identity_plan_target_device() { [[ $1 == /dev/mock-var ]]; }
rootpxe_linux_mount_options() { printf rw; }
blkid() {
    case "$*" in
        '-U old-var') [[ ${POST_UUID_CHANGE:-0} == 1 ]] || printf /dev/mock-var ;;
        *'TYPE'*'/dev/mock-var') printf xfs ;;
        *) return 1 ;;
    esac
}
mountpoint() { [[ $1 == -q ]] && [[ -n ${mounted[$2]:-} ]]; }
mount() { local source="${@: -2:1}" target_path="${@: -1}"; mounted[$target_path]="$source"; }
umount() { unset 'mounted[$1]'; }
rootpxe_deployment_identity_boot_device_is_block() { [[ $1 == /dev/mock-var ]]; }
rootpxe_deployment_identity_boot_mount_device_numbers() { [[ ${mounted[$1]:-} == "$2" ]]; }

rootpxe_deployment_identity_mount_linux_var_filesystem "$target" || fail 'pre-change /var mount was rejected'
[[ ${mounted[$target/var]:-} == /dev/mock-var ]] || fail 'pre-change /var mount target mismatch'
rootpxe_deployment_identity_unmount_linux_var_filesystem || fail 'pre-change /var cleanup failed'
[[ -z ${mounted[$target/var]:-} ]] || fail 'pre-change /var remained mounted'

# The restored /var filesystem can be intentionally empty.  dracut defaults
# to /var/tmp, so application must provision that standard sticky directory
# after mounting /var rather than silently failing initramfs regeneration.
[[ ! -e $target/var/tmp ]] || fail 'empty /var fixture already has tmp'
var_tmp_mode=""
chmod() { var_tmp_mode="$1:$2"; }
rootpxe_deployment_identity_prepare_linux_var_tmpdir "$target" || fail 'empty /var did not get standard tmp dir'
[[ -d $target/var/tmp && ! -L $target/var/tmp ]] || fail '/var/tmp was not a directory'
[[ $var_tmp_mode == "1777:$target/var/tmp" ]] || fail '/var/tmp did not get sticky permissions'

# Once the target UUID has changed, the old fstab UUID no longer resolves
# through blkid.  The frozen topology must still bind it to its planned device.
POST_UUID_CHANGE=1 rootpxe_deployment_identity_mount_linux_var_filesystem "$target" || fail 'post-change /var mount did not use frozen topology'
[[ ${mounted[$target/var]:-} == /dev/mock-var ]] || fail 'post-change /var mount target mismatch'
rootpxe_deployment_identity_unmount_linux_var_filesystem || fail 'post-change /var cleanup failed'

# Reference repair runs after UUIDs have changed and may invoke the target's
# initramfs tooling.  Keep the same independently mounted /var available for
# that entire application window, including its failure cleanup path.
repair_events=()
rootpxe_deployment_identity_storage_enabled() { return 0; }
rootpxe_deployment_identity_linux_reference_map() { printf 'map\n'; }
rootpxe_deployment_identity_rewrite_linux_references() {
    repair_events+=("rewrite:${mounted[$target/var]:-}")
    [[ ${REPAIR_FAIL:-0} != 1 && ${mounted[$target/var]:-} == /dev/mock-var ]]
}
rootpxe_deployment_identity_mount_linux_boot_filesystems() {
    repair_events+=("boot-mount:${mounted[$target/var]:-}")
    [[ ${mounted[$target/var]:-} == /dev/mock-var ]]
}
rootpxe_deployment_identity_unmount_linux_boot_filesystems() {
    repair_events+=("boot-unmount:${mounted[$target/var]:-}")
}
rootpxe_deployment_identity_update_machine_id_boot_paths() { return 0; }
rootpxe_deployment_identity_rewrite_linux_grubenv() { return 0; }
rootpxe_deployment_identity_rebuild_linux_initramfs() {
    repair_events+=("initramfs:${mounted[$target/var]:-}")
    [[ ${mounted[$target/var]:-} == /dev/mock-var ]]
}

POST_UUID_CHANGE=1 rootpxe_deployment_identity_linux_repair_references_in_root "$target" || fail 'post-change repair rejected separate /var'
[[ ${mounted[$target/var]:-} == '' ]] || fail 'repair success left /var mounted'
printf '%s\n' "${repair_events[@]}" | grep -Fx 'rewrite:/dev/mock-var' >/dev/null || fail 'repair rewrote references without /var mounted'
printf '%s\n' "${repair_events[@]}" | grep -Fx 'initramfs:/dev/mock-var' >/dev/null || fail 'repair rebuilt initramfs without /var mounted'

repair_events=()
if POST_UUID_CHANGE=1 REPAIR_FAIL=1 rootpxe_deployment_identity_linux_repair_references_in_root "$target"; then
    fail 'repair failure fixture unexpectedly succeeded'
fi
[[ ${mounted[$target/var]:-} == '' ]] || fail 'repair failure left /var mounted'

printf 'PASS: PXEOS separate /var identity mount regression\n'
