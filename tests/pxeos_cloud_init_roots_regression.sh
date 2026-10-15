#!/usr/bin/env bash
# 真实root发现/VG全部PV校验及目标循环；只替换块设备、LVM报告和mount叶边界。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-cloud-init-roots.XXXXXX)
cleanup_fixture(){ [[ $tmp =~ ^/tmp/pxeos-cloud-init-roots\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1; rm -rf -- "$tmp"; }
trap cleanup_fixture EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_fixture_jq=$(command -v jq.exe); jq(){ "$rootpxe_ci_fixture_jq" -b "$@"; };; esac
. "$lib/cloud-init.sh"
for fn in rootpxe_find_linux_root_filesystem rootpxe_linux_validate_vg_target_pvs rootpxe_linux_activate_vg_if_needed rootpxe_linux_lvs_for_vg_json rootpxe_linux_cleanup_selected_vg; do
    eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$lib/funcs.sh")"
done
getPartitions(){ parts="${1}p1"; }
rootpxe_verify_disk_permit_binding(){ [[ $1 == /dev/A || $1 == /dev/B ]]; }
rootpxe_lvm_safe_identifier(){ [[ $1 == uuid-* ]]; }
rootpxe_lvm_validate_vg_name(){ [[ $1 == vg || $1 == vgA || $1 == vgB ]]; }
rootpxe_lvm_trim(){ printf '%s' "$1"; }
rootpxe_lvm_json_jq(){ jq "$@"; }
readlink(){ if [[ $1 == -f && ${@: -1} == /dev/* ]]; then printf '%s\n' "${@: -1}"; else command readlink "$@"; fi; }
stat(){ if [[ $1 == -c && $2 == %r ]]; then printf '101\n'; else command stat "$@"; fi; }
rootpxe_ci_device_is_block(){ [[ $1 == /dev/dm-fixture* ]]; }
blkid(){
    if [[ ${@: -1} == /dev/*p1 ]]; then printf LVM2_member; elif [[ ${scenario:-} == conflict && ${disk:-} == /dev/B ]]; then printf xfs; else printf ext4; fi
}
rootpxe_lvm_native(){
    local group="${@: -1}" path=/dev/dm-fixture uuid=uuid-good
    case $1 in
        pvs)
            if [[ ${scenario:-} == distinct ]]; then
                printf '{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_name":"vgA","vg_uuid":"uuid-A"},{"pv_name":"/dev/Bp1","vg_name":"vgB","vg_uuid":"uuid-B"}]}]}\n'
            elif [[ ${scenario:-} == foreign ]]; then
                printf '{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_name":"vg","vg_uuid":"uuid-good"},{"pv_name":"/dev/Bp1","vg_name":"vg","vg_uuid":"uuid-good"},{"pv_name":"/dev/FOREIGNp1","vg_name":"vg","vg_uuid":"uuid-good"}]}]}\n'
            else printf '{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_name":"vg","vg_uuid":"uuid-good"},{"pv_name":"/dev/Bp1","vg_name":"vg","vg_uuid":"uuid-good"}]}]}\n'; fi
            ;;
        lvs)
            if [[ ${scenario:-} == distinct ]]; then path="/dev/dm-fixture-$group"; uuid="uuid-${group#vg}"; fi
            printf '{"report":[{"lv":[{"vg_name":"%s","vg_uuid":"%s","lv_name":"root","lv_path":"%s","lv_active":"active"}]}]}\n' "$group" "$uuid" "$path"
            ;;
        vgchange) fail 'borrowed active VG changed';;
        *) fail unexpected-LVM;;
    esac
}
rootpxe_linux_probe_root_candidate(){ printf '%s|%s|%s|%s|\n' "$1" "$2" "$3" "$4"; }
rootpxe_cloud_init_process_root(){ printf '%s\n' "$3" >>"$tmp/phases"; rootpxe_cloud_init_seed_verified=no; }
mountpoint(){ return 1; }
taskType=deploy osid=50
scenario=same
rootpxe_cloud_init_install_for_targets /dev/A /dev/B || fail "same LV twice: ${rootpxe_cloud_init_error:-}"
[[ $(<"$tmp/phases") == $'ro\nrw' ]] || fail 'same LV was not installed exactly once'
for scenario in distinct conflict foreign; do
    : >"$tmp/phases"
    rootpxe_cloud_init_install_for_targets /dev/A /dev/B && fail "accepted $scenario roots"
    [[ ! -s $tmp/phases ]] || fail "$scenario reached root write/preflight"
done
printf 'PASS: real multi-PV root discovery dedupes same LV; distinct/conflicting/foreign roots reject\n'
