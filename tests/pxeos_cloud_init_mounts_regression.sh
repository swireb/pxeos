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
for shadow in /etc /etc/cloud /etc/cloud/cloud.cfg.d; do
    printf '/dev/Ap2 %s ext4 defaults 0 2\n' "$shadow" >"$target/etc/fstab"
    rootpxe_ci_mount_fstab "$target" /var rw && fail "shadowing $shadow accepted"
done
printf '/dev/Ap2 /etc/resolv.conf ext4 defaults 0 2\n' >"$target/etc/fstab"
rootpxe_ci_mount_fstab "$target" /var rw || fail 'unrelated /etc/resolv.conf entry rejected'
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

# Mount leaf substitutes expose a separate /var directory only while mounted.
# The real ro/rw processor and installer must put boot config under root /etc.
if [[ $EUID == 0 && $(uname -s) == Linux ]]; then
(
    . "$lib/cloud-init.sh"
    system="$tmp/independent-var-root" external_var="$tmp/independent-var-data"
    mkdir -p "$system/etc/cloud" "$system/usr/bin" "$system/var" "$external_var"
    printf '# image cloud config\n' >"$system/etc/cloud/cloud.cfg"
    printf '#!/bin/sh\nexit 99\n' >"$system/usr/bin/cloud-init"; chmod 755 "$system/usr/bin/cloud-init"
    printf '/dev/fixture-var /var xfs defaults 0 2\n' >"$system/etc/fstab"
    printf '#cloud-config\nruncmd: []\n' >"$tmp/independent-user-data"
    printf 'instance-id: independent-var\n' >"$tmp/independent-meta-data"
    cloudInitUserDataFile="$tmp/independent-user-data" cloudInitMetaDataFile="$tmp/independent-meta-data"
    cloudInitUserDataSha256=$(rootpxe_ci_hash "$cloudInitUserDataFile")
    cloudInitMetaDataSha256=$(rootpxe_ci_hash "$cloudInitMetaDataFile")
    cloudInitNetworkConfigFile='' cloudInitNetworkConfigSha256='' cloudInitVendorDataFile='' cloudInitVendorDataSha256=''
    rootpxe_ci_device_is_block(){ return 0; }
    rootpxe_ci_device_permitted(){ [[ $1 == /dev/fixture-var ]]; }
    rootpxe_ci_mount_matches(){ return 0; }
    rootpxe_ci_mount_root(){ ci_mounted_root="$system"; }
    blkid(){ printf xfs; }
    var_mounted=no
    mountpoint(){ [[ $var_mounted == yes && ${@: -1} == "$system/var" ]]; }
    mount(){
        [[ ${@: -1} == "$system/var" ]] || return 1
        mv "$system/var" "$system/hidden-var"; mv "$external_var" "$system/var"; var_mounted=yes
    }
    umount(){
        [[ $1 == "$system/var" ]] || return 1
        mv "$system/var" "$external_var"; mv "$system/hidden-var" "$system/var"; var_mounted=no
    }
    rootpxe_cloud_init_process_root /dev/A '/dev/Ap1|xfs|||' ro || fail 'separate /var readonly preflight'
    [[ ! -e $system/etc/cloud/cloud.cfg.d && ! -e $external_var/lib ]] || fail 'readonly separate /var preflight wrote files'
    rootpxe_cloud_init_process_root /dev/A '/dev/Ap1|xfs|||' rw || fail 'separate /var injection'
    config="$system/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg"
    printf 'datasource_list: [NoCloud]\n' | cmp -s - "$config" || fail 'separate /var boot config missing from root /etc'
    cmp -s "$cloudInitUserDataFile" "$external_var/lib/cloud/seed/nocloud/user-data" || fail 'seed not installed on separate /var'
    [[ ! -e $external_var/etc && ! -e $system/var/lib && $var_mounted == no ]] || fail 'config/seed used hidden mount path or mount leaked'
    rm "$config"
    rootpxe_cloud_init_process_root /dev/A '/dev/Ap1|xfs|||' ro || fail 'separate /var missing-config preflight'
    rootpxe_cloud_init_process_root /dev/A '/dev/Ap1|xfs|||' rw || fail 'separate /var matching seed config repair'
    cmp -s "$cloudInitUserDataFile" "$external_var/lib/cloud/seed/nocloud/user-data" || fail 'separate /var repeat injection bytes'
    [[ -f $config && $var_mounted == no ]] || fail 'separate /var repeat injection missing config or leaked mount'
    printf 'PASS: separate /var ro/rw injection keeps NoCloud config on root /etc\n'
) || fail 'separate /var NoCloud boot config'
else
    printf 'SKIP: separate /var installer metadata fixture requires Linux root\n'
fi

# 使用真实 ownership 清理；失败项保留后再次清理也不得漏掉稀疏数组中的 VG。
(
    . "$lib/cloud-init.sh"
    eval "$(sed -n '/^rootpxe_linux_cleanup_selected_vg() {$/,/^}$/p' "$funcs")"
    cleanup_events="$tmp/cleanup-events"
    rootpxe_lvm_native(){
        [[ $1 == vgchange && $2 == -an ]] || fail 'unexpected cleanup command'
        printf 'vg:%s\n' "${@: -1}" >>"$cleanup_events"
        [[ ${@: -1} != ${failed_vg:-} ]]
    }
    umount(){ printf 'mount:%s\n' "$1" >>"$cleanup_events"; [[ $1 != ${failed_mount:-} ]]; }
    for failed_vg in '' vg-root vg-usr vg-var; do
        : >"$cleanup_events"
        failed_mount=''
        ci_owned_mounts=(root-mount usr-mount var-mount)
        ci_vg_names=(vg-root vg-borrowed vg-usr vg-var)
        ci_vg_uuids=(uuid-root uuid-borrowed uuid-usr uuid-var)
        ci_vg_owned=(yes no yes yes)
        if rootpxe_ci_cleanup_mounts; then cleanup_rc=0; else cleanup_rc=$?; fi
        [[ $(cat "$cleanup_events") == $'mount:var-mount\nmount:usr-mount\nmount:root-mount\nvg:vg-var\nvg:vg-usr\nvg:vg-root' ]] || fail 'VG failure skipped independent cleanup or changed normal order'
        [[ ${#ci_owned_mounts[@]} == 0 ]] || fail 'successful unmount ownership retained'
        if [[ -n $failed_vg ]]; then
            [[ $cleanup_rc == 1 && ${ci_vg_names[*]} == "$failed_vg" && ${ci_vg_owned[*]} == yes ]] || fail 'failed VG ownership/status lost'
            [[ ${ci_vg_uuids[*]} == "uuid-${failed_vg#vg-}" ]] || fail 'failed VG UUID ownership lost'
            : >"$cleanup_events"
            retry_vg=$failed_vg; failed_vg=''
            rootpxe_ci_cleanup_mounts || fail 'remaining VG cleanup retry failed'
            [[ $(cat "$cleanup_events") == "vg:$retry_vg" ]] || fail 'sparse VG ownership was skipped or borrowed VG changed'
        else [[ $cleanup_rc == 0 ]] || fail 'normal VG cleanup failed'; fi
        [[ ${#ci_vg_names[@]} == 0 && ${#ci_vg_uuids[@]} == 0 && ${#ci_vg_owned[@]} == 0 ]] || fail 'successful VG ownership retained'
    done
    : >"$cleanup_events"
    failed_mount=var-mount
    ci_owned_mounts=(root-mount var-mount)
    ci_vg_names=(vg-root vg-var) ci_vg_uuids=(uuid-root uuid-var) ci_vg_owned=(yes yes)
    rootpxe_ci_cleanup_mounts && fail 'unmount failure accepted'
    [[ $(cat "$cleanup_events") == mount:var-mount && ${ci_owned_mounts[*]} == 'root-mount var-mount' && ${ci_vg_names[*]} == 'vg-root vg-var' ]] || fail 'failed unmount changed dependent ownership or deactivated a VG'
    printf 'PASS: all independent owned VGs attempted, failed ownership retry, borrowed VG and failed unmount dependency preserved\n'
)

# 仅创建临时块设备节点并读取元数据，不打开设备；保留真实 mount_matches/stat/readlink。
case $(uname -s):$EUID in
    Linux:0)
        (
            . "$lib/cloud-init.sh"
            identity_root="$tmp/mount-identities"
            mkdir -p "$identity_root/mounted" "$identity_root/work" "$identity_root/system/etc" "$identity_root/system/var"
            mknod -m 600 "$identity_root/device" b 7 201 || fail 'native block fixture unavailable'
            mknod -m 600 "$identity_root/wrong-device" b 7 202 || fail 'native wrong-device fixture unavailable'
            ln -s device "$identity_root/device-alias"
            ln -s missing-device "$identity_root/dangling-alias"
            printf 'not a block device\n' >"$identity_root/regular-file"
            rootpxe_ci_device_is_block(){ [[ -b $1 ]]; } # 临时节点位于私有 /tmp，而非宿主 /dev。
            stat(){
                if [[ $1 == -c && $2 == %d ]]; then
                    case ${@: -1} in
                        "$identity_root/mounted"|"$identity_root/work/root"|"$identity_root/system/var") printf '%s\n' "$fixture_mount_device"; return;;
                    esac
                fi
                command stat "$@"
            }
            readlink(){
                if [[ $1 == -f && ( ${@: -1} == /dev/vg/var || ${@: -1} == /dev/Ap2 ) ]]; then
                    command readlink -f "$identity_root/device-alias"
                else command readlink "$@"; fi
            }
            findmnt(){ [[ ${@: -1} == OPTIONS ]] && printf '%s\n' "$fixture_mount_options"; }
            mountpoint(){ [[ ${fixture_borrowed_var:-no} == yes && ${@: -1} == "$identity_root/system/var" ]]; }
            mount(){ printf 'mount:%s\n' "$*" >>"$events"; }
            umount(){ printf 'umount:%s\n' "$1" >>"$events"; }
            blkid(){ printf xfs; } # 不读取临时块设备节点。
            fixture_mount_device=1993 # major=7, minor=201，独立于待测 stat 实现。
            for fixture_mount_mode in ro rw; do
                fixture_mount_options="$fixture_mount_mode,relatime"
                for device in "$identity_root/device" "$identity_root/device-alias"; do
                    rootpxe_ci_mount_matches "$identity_root/mounted" "$device" "$fixture_mount_mode" || fail "native $fixture_mount_mode identity rejected: ${device##*/}"
                done
                for device in "$identity_root/wrong-device" "$identity_root/dangling-alias" "$identity_root/regular-file"; do
                    rootpxe_ci_mount_matches "$identity_root/mounted" "$device" "$fixture_mount_mode" && fail "native $fixture_mount_mode wrong/nonblock identity accepted"
                done
                if [[ $fixture_mount_mode == ro ]]; then wrong_mode=rw; else wrong_mode=ro; fi
                rootpxe_ci_mount_matches "$identity_root/mounted" "$identity_root/device-alias" "$wrong_mode" && fail 'wrong native mount mode accepted'
            done
            fixture_mount_options=ro,relatime
            declare -a ci_owned_mounts=() ci_vg_names=() ci_vg_uuids=() ci_vg_owned=()
            rootpxe_ci_mount_root "$identity_root/device-alias" xfs "$identity_root/work" ro || fail 'root mount rejected a native device alias'
            rootpxe_ci_cleanup_mounts || fail 'native alias root fixture cleanup failed'
            printf '/dev/vg/var /var xfs defaults 0 2\n' >"$identity_root/system/etc/fstab"
            for fixture_borrowed_var in no yes; do
                for fixture_mount_mode in ro rw; do
                    fixture_mount_options="$fixture_mount_mode,relatime"
                    rootpxe_ci_mount_fstab "$identity_root/system" /var "$fixture_mount_mode" || fail 'fstab alias rejected a matching native block identity'
                    rootpxe_ci_cleanup_mounts || fail 'fstab native fixture cleanup failed'
                done
            done
            fixture_borrowed_var=yes fixture_mount_options=ro,relatime
            fixture_mount_device=1994
            rootpxe_ci_mount_fstab "$identity_root/system" /var ro && fail 'fstab alias accepted a different mounted device'
            fixture_mount_device=1993
            rootpxe_ci_mount_fstab "$identity_root/system" /var rw && fail 'fstab alias accepted the wrong mounted mode'
            printf 'PASS: native block/symlink identities, root/fstab aliases, wrong devices and ro/rw mode rejection\n'
        )
        ;;
    *) printf 'SKIP: native block-node metadata checks require Linux root\n';;
esac
