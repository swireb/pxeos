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
. "$lib/linux-hostname.sh"
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
rootpxe_linux_hostname_process_root(){ printf '%s\n' "$3" >>"$tmp/phases"; rootpxe_linux_hostname_verified=no; }
rootpxe_stage(){ :; }
mountpoint(){ return 1; }
taskType=deploy osid=50
scenario=same
rootpxe_cloud_init_install_for_targets /dev/A /dev/B || fail "same LV twice: ${rootpxe_cloud_init_error:-}"
[[ $(<"$tmp/phases") == $'ro\nrw' ]] || fail 'same LV was not installed exactly once'
changeHostname=true hostName=node-new
deploymentIdentityPolicyFile="$tmp/policy"
printf '{"version":1,"systemIdentity":{"sysprep":false},"taskHostname":"node-new","cloudInit":false}\n' >"$deploymentIdentityPolicyFile"
for entry in rootpxe_cloud_init_install_for_targets rootpxe_apply_linux_hostname_for_targets; do
    scenario=same
    : >"$tmp/phases"
    "$entry" /dev/A /dev/B || fail "$entry same permitted multi-PV LV rejected"
    [[ $(<"$tmp/phases") == $'ro\nrw' ]] || fail "$entry did not install unique root exactly once"
    for scenario in distinct conflict foreign; do
        : >"$tmp/phases"
        "$entry" /dev/A /dev/B && fail "$entry accepted $scenario roots"
        [[ ! -s $tmp/phases ]] || fail "$entry $scenario reached root write/preflight"
    done
done

# 设备状态保存在文件中，真实函数的命令替换/子 shell 仍能看到 VG 激活和停用。
# 每次重新激活分配不同 canonical 设备，捕获目标循环中提前清理导致的同根误判。
(
    lifecycle_reset(){
        lifecycle_topology="$1" lifecycle_initial="$2" lifecycle_failure="$3"
        rootpxe_cloud_init_error=''
        : >"$tmp/phases"; : >"$tmp/vg-events"
        for group in vg vgA vgB; do
            printf '%s\n' "$lifecycle_initial" >"$tmp/$group-state"
            printf '0\n' >"$tmp/$group-generation"
        done
    }
    readlink(){
        local device="${@: -1}" group
        if [[ $1 == -f && $device == /dev/* ]]; then
            case $device in
                /dev/vg/root|/dev/vgA/root|/dev/vgB/root)
                    group=${device#/dev/}; group=${group%%/*}
                    [[ $(<"$tmp/$group-state") == active ]] || return 1
                    printf '/dev/dm-fixture-%s-%s\n' "$group" "$(<"$tmp/$group-generation")"
                    ;;
                *) printf '%s\n' "$device";;
            esac
        else command readlink "$@"; fi
    }
    rootpxe_ci_device_is_block(){ [[ $lifecycle_failure != identity && ( $1 == /dev/dm-fixture-* || $1 == /dev/Ap1 ) ]]; }
    rootpxe_linux_lvm_path_readable(){
        local group=${1#/dev/}; group=${group%%/*}
        [[ $(<"$tmp/$group-state") == active ]]
    }
    blkid(){
        if [[ $lifecycle_topology == direct ]]; then printf ext4
        elif [[ ${@: -1} == /dev/*p1 ]]; then printf LVM2_member
        elif [[ $lifecycle_topology == conflict && $disk == /dev/B ]]; then printf xfs
        else printf ext4; fi
    }
    rootpxe_lvm_native(){
        local group="${@: -1}" uuid=uuid-good generation
        case $1 in
            pvs)
                case $lifecycle_topology in
                    single) printf '{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_name":"vg","vg_uuid":"uuid-good"}]}]}\n';;
                    distinct) printf '{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_name":"vgA","vg_uuid":"uuid-A"},{"pv_name":"/dev/Bp1","vg_name":"vgB","vg_uuid":"uuid-B"}]}]}\n';;
                    *) printf '{"report":[{"pv":[{"pv_name":"/dev/Ap1","vg_name":"vg","vg_uuid":"uuid-good"},{"pv_name":"/dev/Bp1","vg_name":"vg","vg_uuid":"uuid-good"}]}]}\n';;
                esac
                ;;
            lvs)
                [[ $group == vg ]] || uuid="uuid-${group#vg}"
                printf '{"report":[{"lv":[{"vg_name":"%s","vg_uuid":"%s","lv_name":"root","lv_path":"/dev/%s/root","lv_active":"%s"}]}]}\n' "$group" "$uuid" "$group" "$(<"$tmp/$group-state")"
                ;;
            vgchange)
                generation=$(<"$tmp/$group-generation")
                case $2 in
                    -ay)
                        [[ $lifecycle_failure != activation || $group != vgB || $generation -eq 0 ]] || return 1
                        generation=$((generation + 1))
                        printf '%s\n' "$generation" >"$tmp/$group-generation"
                        printf 'active\n' >"$tmp/$group-state"
                        printf 'activate:%s:%s\n' "$group" "$generation" >>"$tmp/vg-events"
                        ;;
                    -an)
                        printf 'deactivate:%s:%s\n' "$group" "$generation" >>"$tmp/vg-events"
                        if [[ $lifecycle_failure == cleanup && $group == "$lifecycle_cleanup_group" && $generation -ge 2 ]]; then return 1; fi
                        printf 'inactive\n' >"$tmp/$group-state"
                        ;;
                    *) fail unexpected-vgchange;;
                esac
                ;;
            *) fail unexpected-LVM;;
        esac
    }
    rootpxe_run_logged_typed_native(){ shift 2; rootpxe_lvm_native "$@"; }
    rootpxe_linux_probe_root_candidate(){
        [[ $lifecycle_failure != probe || $disk != /dev/B ]] || return 3
        case $lifecycle_failure in
            invalid-device) printf '/fixture-root|%s|%s|%s|\n' "$2" "$3" "$4";;
            invalid-fs) printf '%s|btrfs|%s|%s|\n' "$1" "$3" "$4";;
            invalid-subvol) printf '%s|%s|%s|%s|256\n' "$1" "$2" "$3" "$4";;
            invalid-extra) printf '%s|%s|%s|%s||unexpected\n' "$1" "$2" "$3" "$4";;
            *) printf '%s|%s|%s|%s|\n' "$1" "$2" "${3:-}" "${4:-}";;
        esac
    }
    mktemp(){
        [[ $lifecycle_failure != workspace || ${disk:-} != /dev/B || $* != *rootpxe-cloud-mount.* ]] || return 1
        command mktemp "$@"
    }
    for entry in rootpxe_cloud_init_install_for_targets rootpxe_apply_linux_hostname_for_targets; do
        for lifecycle_case in direct single same borrowed identity distinct conflict probe workspace activation cleanup cleanup-multiple invalid-device invalid-fs invalid-subvol invalid-extra; do
            topology=same initial=inactive failure='' expected_error='' lifecycle_cleanup_group=vg
            targets=(/dev/A /dev/B)
            case $lifecycle_case in
                direct|single) topology=$lifecycle_case; targets=(/dev/A);;
                borrowed) initial=active;;
                identity) topology=single; targets=(/dev/A); failure=identity; expected_error=cloud_init_root_identity_unverified;;
                distinct) topology=distinct; expected_error=cloud_init_roots_not_unique;;
                conflict) topology=conflict; expected_error=cloud_init_root_identity_conflict;;
                probe|workspace) failure=$lifecycle_case; expected_error=cloud_init_root_probe_failed;;
                activation) topology=distinct; failure=activation; expected_error=cloud_init_root_probe_failed;;
                cleanup) topology=single; targets=(/dev/A); failure=cleanup; expected_error=cloud_init_mount_cleanup_failed;;
                cleanup-multiple) topology=distinct; failure=cleanup; lifecycle_cleanup_group=vgB; expected_error=cloud_init_mount_cleanup_failed;;
                invalid-*) topology=single; targets=(/dev/A); failure=$lifecycle_case; expected_error=cloud_init_root_identity_unverified;;
            esac
            lifecycle_reset "$topology" "$initial" "$failure"
            if [[ -z $expected_error ]]; then
                "$entry" "${targets[@]}" || fail "$entry $lifecycle_case: ${rootpxe_cloud_init_error:-}"
                [[ $(<"$tmp/phases") == $'ro\nrw' ]] || fail "$entry $lifecycle_case did not process one root"
            else
                "$entry" "${targets[@]}" && fail "$entry accepted $lifecycle_case"
                [[ $rootpxe_cloud_init_error == "$expected_error" ]] || fail "$entry $lifecycle_case reason: $rootpxe_cloud_init_error"
                [[ ! -s $tmp/phases ]] || fail "$entry $lifecycle_case reached root preflight/write"
            fi
            for group in vg vgA vgB; do
                expected_state=$initial
                if [[ $failure == cleanup && $group == "$lifecycle_cleanup_group" ]]; then expected_state=active; fi
                [[ $(<"$tmp/$group-state") == "$expected_state" ]] || fail "$entry $lifecycle_case leaked or changed $group"
            done
            case $lifecycle_case in
                borrowed|direct) [[ ! -s $tmp/vg-events ]] || fail "$entry $lifecycle_case changed a VG";;
                single|same)
                    [[ $(grep -c '^activate:' "$tmp/vg-events") -eq 2 && $(grep -c '^deactivate:' "$tmp/vg-events") -eq 2 ]] || fail "$entry $lifecycle_case reactivated a held root between targets"
                    ;;
                invalid-*)
                    [[ $(grep -c '^activate:' "$tmp/vg-events") -eq 1 && $(grep -c '^deactivate:' "$tmp/vg-events") -eq 1 ]] || fail "$entry $lifecycle_case activated an invalid root candidate"
                    ;;
            esac
        done
    done
)
printf 'PASS: Cloud/offline-name roots retain owned VGs for identity and multi-PV dedupe; borrowed/direct roots and every failure cleanup remain safe\n'
