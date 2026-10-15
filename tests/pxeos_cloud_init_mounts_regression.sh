#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-cloud-init-mounts.XXXXXX)
cleanup_fixture(){
    [[ $tmp =~ ^/tmp/pxeos-cloud-init-mounts\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    rm -rf -- "$tmp"
}
trap cleanup_fixture EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_fixture_jq=$(command -v jq.exe); jq(){ "$rootpxe_ci_fixture_jq" -b "$@"; };; esac
. "$lib/cloud-init.sh"
declare -F rootpxe_ci_mount_fstab >/dev/null || fail 'authorized native fstab helper missing'
funcs="$lib/funcs.sh"
for fn in rootpxe_linux_validate_vg_target_pvs rootpxe_linux_mount_options; do eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$funcs")"; done
target="$tmp/root"
fixture_root="$target"
mkdir -p "$target/etc" "$target/usr" "$target/var"
events="$tmp/events"
rootpxe_ci_stat(){ printf '0:0:700:1\n'; }
rootpxe_ci_device_is_block(){ return 0; }
readlink(){ [[ $1 != -f ]] && command readlink "$@" || printf '%s\n' "${@: -1}"; }
rootpxe_verify_disk_permit_binding(){ [[ $1 == /dev/A || $1 == /dev/B ]]; }
getPartitions(){ [[ $1 != /dev/A ]] && parts=/dev/Bp1 || parts=$'/dev/Ap1\n/dev/Ap2'; }
rootpxe_lvm_safe_identifier(){ [[ $1 == uuid-good ]]; }
rootpxe_lvm_json_jq(){ jq "$@"; }
rootpxe_lvm_trim(){ printf '%s\n' "$1"; }
rootpxe_lvm_native(){
    case $1 in
        pvs) printf '%s\n' "$pv_json";;
        lvs) printf '{"report":[{"lv":[{"lv_path":"/dev/vg/var","vg_name":"vg","vg_uuid":"uuid-good"}]}]}\n';;
        *) fail unexpected-native;;
    esac
}
rootpxe_linux_activate_vg_if_needed(){ printf 'no\n'; }
rootpxe_linux_cleanup_selected_vg(){ printf 'vg-clean:%s:%s\n' "$1" "$3" >>"$events"; }
blkid(){ [[ ${@: -1} == /dev/Ap2 || ${@: -1} == /dev/vg/var ]] && printf ext4 || printf xfs; }
mountpoint(){ [[ ( ${borrowed:-no} == yes && ${@: -1} == "$fixture_root/var" ) || ( ${cloud_shadow:-no} == yes && ${@: -1} == "$fixture_root/var/lib/cloud" ) ]]; }
rootpxe_ci_mount_matches(){ [[ ${wrong_device:-no} != yes ]]; }
mount(){ printf 'mount:%s\n' "$*" >>"$events"; }
umount(){ printf 'umount:%s\n' "$1" >>"$events"; [[ ${cleanup_fail:-no} != yes ]]; }
rootpxe_cloud_init_allowed_disks='/dev/A /dev/B'
declare -a ci_owned_mounts=() ci_vg_names=() ci_vg_uuids=() ci_vg_owned=()
printf '/dev/Ap2 /var ext4 defaults 0 2\n' >"$target/etc/fstab"
rootpxe_ci_mount_fstab "$target" /var rw || fail 'permitted /var failed'
rootpxe_ci_cleanup_mounts || fail 'owned cleanup failed'
grep -Fq 'umount:' "$events" || fail 'owned /var not unmounted'
printf '/dev/FOREIGN /var xfs defaults 0 2\n' >"$target/etc/fstab"
rootpxe_ci_mount_fstab "$target" /var rw && fail 'foreign /var accepted'
printf '/dev/Ap2 /var ext4 defaults 0 2\n/dev/Ap1 /var xfs defaults 0 2\n' >"$target/etc/fstab"
rootpxe_ci_mount_fstab "$target" /var rw && fail 'duplicate /var accepted'
printf '/dev/Ap2 /var/lib/cloud ext4 defaults 0 2\n' >"$target/etc/fstab"
rootpxe_ci_mount_fstab "$target" /var rw && fail 'shadowing /var/lib/cloud accepted'
mkdir -p "$target/var/lib/cloud/instances"
cloud_shadow=yes
printf '/dev/Ap2 /usr ext4 defaults 0 2\n/dev/FOREIGN /var/lib/cloud ext4 defaults 0 2\n/dev/FOREIGN /etc/cloud ext4 defaults 0 2\n' >"$target/etc/fstab"
: >"$events"
rootpxe_ci_mount_fstab "$target" /usr ro || fail 'independent /usr probe depended on unrelated Cloud-init mounts/cache'
rootpxe_ci_cleanup_mounts || fail 'owned /usr cleanup failed'
grep -Fq 'ro,noload' "$events" || fail '/usr probe not mounted readonly'
rootpxe_ci_mount_fstab "$target" /var rw && fail '/var shadowing bypassed after /usr probe split'
[[ ! -e $target/var/lib/cloud/seed ]] || fail '/usr probe or rejected /var wrote a seed'
cloud_shadow=no
printf '/dev/Ap2 /var ext4 defaults 0 2\n' >"$target/etc/fstab"
borrowed=yes
: >"$events"
rootpxe_ci_mount_fstab "$target" /var rw || fail 'correct borrowed /var rejected'
rootpxe_ci_cleanup_mounts || fail 'borrowed cleanup failed'
[[ ! -s $events ]] || fail 'borrowed mount changed or unmounted'
wrong_device=yes
rootpxe_ci_mount_fstab "$target" /var rw && fail 'wrong borrowed identity accepted'
wrong_device=no borrowed=no
pv_json='{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_uuid":"uuid-good"},{"pv_name":"/dev/Bp1","vg_uuid":"uuid-good"}]}]}'
rootpxe_linux_validate_vg_target_pvs /dev/A uuid-good || fail 'VG across two permitted targets rejected'
pv_json='{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_uuid":"uuid-good"},{"pv_name":"/dev/OTHERp1","vg_uuid":"uuid-good"}]}]}'
rootpxe_linux_validate_vg_target_pvs /dev/A uuid-good && fail 'VG foreign PV accepted'
ci_owned_mounts=("$target/var") cleanup_fail=yes
rootpxe_ci_cleanup_mounts && fail 'unmount failure swallowed'
[[ ${#ci_owned_mounts[@]} == 1 ]] || fail 'failed cleanup evidence discarded'
printf 'PASS: independent readonly /usr probe, strict /var permissions, all VG PVs, shadowing fstab, borrowed/failed cleanup\n'
