#!/usr/bin/env bash
# 真实枚举→候选挂载→安全根结构/独立 usr→唯一选择；只替换设备/LVM/mount 叶边界。
set -euo pipefail
umask 022
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-root-chain.XXXXXX)
cleanup(){
    local path
    if [[ -f $tmp/workspaces ]]; then
        while IFS= read -r path; do
            [[ $path =~ ^/tmp/rootpxe-cloud-mount\.[A-Za-z0-9]{6}$ && -d $path && ! -L $path ]] && rm -rf -- "$path"
        done <"$tmp/workspaces"
    fi
    [[ $tmp =~ ^/tmp/pxeos-root-chain\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
fail(){ printf 'FAIL case=%s: %s\n' "${case_name:-setup}" "$*" >&2; exit 1; }
. "$lib/cloud-init.sh"
for fn in rootpxe_linux_root_fstype_supported rootpxe_linux_mount_options rootpxe_linux_probe_root_candidate rootpxe_linux_validate_vg_target_pvs rootpxe_linux_lvs_for_vg_json rootpxe_linux_activate_vg_if_needed rootpxe_linux_cleanup_selected_vg rootpxe_find_linux_root_filesystem; do
    eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$lib/funcs.sh")"
done
declare -A fx_parts=() fx_fs=() fx_tree=() fx_canonical=() fx_rdev=() fx_vg=() fx_initial=()
taskType=deploy osid=50
rootpxe_lvm_safe_identifier(){ [[ $1 == uuid-* ]]; }
rootpxe_lvm_validate_vg_name(){ [[ $1 == vg* ]]; }
rootpxe_lvm_trim(){ printf '%s' "$1"; }
rootpxe_lvm_json_jq(){ jq "$@"; }
getPartitions(){ parts=${fx_parts[$1]:-}; }
rootpxe_verify_disk_permit_binding(){ [[ " $targets " == *" $1 "* && $2 == deploy_write ]]; }
fixture_active(){ [[ -z ${fx_vg[$1]:-} || $(<"$case_dir/${fx_vg[$1]}-state") == active ]]; }
rootpxe_ci_device_is_block(){ [[ -n ${fx_fs[$1]:-} ]] && fixture_active "$1"; }
rootpxe_linux_lvm_path_readable(){ rootpxe_ci_device_is_block "$1"; }
readlink(){
    if [[ $1 == -f && ${@: -1} == /dev/* ]]; then
        local device=${@: -1}
        fixture_active "$device" || return 1
        printf '%s\n' "${fx_canonical[$device]:-$device}"
    else command readlink "$@"; fi
}
stat(){
    local path=${@: -1} source destination options selected=''
    if [[ $1 == -c && $2 == %r && $path == /dev/* ]]; then
        printf '%s\n' "${fx_rdev[$path]:-0}"
    elif [[ $1 == -c && $2 == %d ]]; then
        while IFS=$'\t' read -r source destination options; do
            [[ $path != "$destination" && $path != "$destination/"* ]] || selected=$source
        done <"$case_dir/mounts"
        [[ -z $selected ]] && command stat "$@" || printf '%s\n' "${fx_rdev[$selected]}"
    else command stat "$@"; fi
}
rootpxe_ci_stat(){
    local info owner group mode links
    info=$(command stat -c '%u:%g:%a:%h' -- "$1") || return 1
    IFS=: read -r owner group mode links <<<"$info"
    # 普通文件不能 chown root；仅替代 owner，权限、链接数和解析均为真实值。
    printf '0:0:%s:%s\n' "$mode" "$links"
}
blkid(){
    local device=${@: -1}
    if [[ $1 == -U || $1 == -t ]]; then device=${uuid_device:-}; fi
    [[ -n $device && -n ${fx_fs[$device]:-} ]] && fixture_active "$device" || return 1
    if [[ $1 == -U || $1 == -t ]]; then printf '%s\n' "$device"; else printf '%s\n' "${fx_fs[$device]}"; fi
}
rootpxe_lvm_native(){
    local group=${@: -1} state report state_file state_group
    case $1 in
        pvs) printf '%s\n' "$fx_pvs_json";;
        lvs)
            report=$fx_lvs_json
            for state_file in "$case_dir/"*-state; do
                [[ -f $state_file ]] || continue
                state_group=${state_file##*/}; state_group=${state_group%-state}; state=$(<"$state_file")
                report=$(jq -c --arg group "$state_group" --arg state "$state" '.report[0].lv |= map(if .vg_name==$group then .lv_active=$state else . end)' <<<"$report")
            done
            if [[ -f $case_dir/$group-state ]]; then jq -c --arg group "$group" '.report[0].lv |= map(select(.vg_name==$group))' <<<"$report"
            else printf '%s\n' "$report"; fi
            ;;
        vgchange)
            printf '%s:%s\n' "$2" "$group" >>"$case_dir/vg-events"
            if [[ $2 == -ay ]]; then printf 'active\n' >"$case_dir/$group-state"
            elif [[ ${fault:-} == vg-cleanup ]]; then return 1
            else printf 'inactive\n' >"$case_dir/$group-state"; fi
            ;;
        *) fail "unexpected LVM command $1";;
    esac
}
rootpxe_run_logged_typed_native(){
    shift 2
    if [[ $1 == vgchange ]]; then rootpxe_lvm_native "$@"; else "$@"; fi
}
mktemp(){
    local path
    path=$(command mktemp "$@") || return 1
    [[ $path != /tmp/rootpxe-cloud-mount.* ]] || printf '%s\n' "$path" >>"$tmp/workspaces"
    printf '%s\n' "$path"
}
mountpoint(){
    local source destination options
    while IFS=$'\t' read -r source destination options; do [[ $destination != "${@: -1}" ]] || return 0; done <"$case_dir/mounts"
    return 1
}
findmnt(){
    local source destination options query='' column=TARGET arg
    while (( $# )); do
        arg=$1; shift
        case $arg in --mountpoint|-S) query=$1; shift;; -o) column=$1; shift;; esac
    done
    while IFS=$'\t' read -r source destination options; do
        [[ $query == "$source" || $query == "$destination" ]] || continue
        [[ $column == OPTIONS ]] && printf '%s\n' "$options" || printf '%s\n' "$destination"
        return 0
    done <"$case_dir/mounts"
    return 1
}
mount(){
    local device=${@: -2:1} destination=${@: -1} options=$4
    [[ -n ${fx_tree[$device]:-} && -d ${fx_tree[$device]} ]] || fail "unmodelled mount $device"
    fixture_active "$device" || return 1
    [[ ${fault:-} != mount || $device != "$expected_root" ]] || return 1
    case ${fx_fs[$device]} in
        ext3|ext4) [[ ,$options, == *,ro,* && ,$options, == *,noload,* ]] || fail 'ext journal replay permitted';;
        xfs) [[ ,$options, == *,ro,* && ,$options, == *,nouuid,* && ,$options, == *,norecovery,* ]] || fail 'XFS recovery permitted';;
        ext2) [[ $options == ro ]] || fail 'ext2 not readonly';;
        *) fail "unexpected mount filesystem ${fx_fs[$device]}";;
    esac
    printf '%s\t%s\t%s\n' "$device" "$destination" "$options" >>"$case_dir/mounts"
    printf '%s\n' "$device" >>"$case_dir/probes"
    cp -a "${fx_tree[$device]}/." "$destination/"
}
umount(){
    local destination=$1
    [[ ${fault:-} != unmount ]] || return 1
    [[ $destination == /tmp/rootpxe-cloud-mount.*/probe* ]] || fail "unexpected unmount $destination"
    find "$destination" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    awk -F '\t' -v target="$destination" '$2!=target' "$case_dir/mounts" >"$case_dir/mounts.next"
    mv "$case_dir/mounts.next" "$case_dir/mounts"
}
add_device(){
    local device=$1 kind=$2 contents=$3 group=${4:-}
    fx_fs[$device]=$kind; fx_tree[$device]=$case_dir/$contents; fx_canonical[$device]=$device
    fx_rdev[$device]=$((100 + ${#fx_fs[@]})); fx_vg[$device]=$group
    mkdir -p "${fx_tree[$device]}"
}
make_root(){
    local path=$1 layout=$2
    mkdir -p "$path/etc" "$path/sbin" "$path/usr" "$path/var"
    : >"$path/etc/passwd"
    case $layout in
        sysv) printf '#!/bin/sh\nexit 99\n' >"$path/sbin/init"; chmod 755 "$path/sbin/init";;
        lib-systemd) mkdir -p "$path/lib/systemd"; printf '#!/bin/sh\nexit 99\n' >"$path/lib/systemd/systemd"; chmod 755 "$path/lib/systemd/systemd"; ln -s /lib/systemd/systemd "$path/sbin/init";;
        usr-systemd-relative|usr-systemd-absolute)
            mkdir -p "$path/usr/lib/systemd"; printf '#!/bin/sh\nexit 99\n' >"$path/usr/lib/systemd/systemd"; chmod 755 "$path/usr/lib/systemd/systemd"
            [[ $layout == usr-systemd-relative ]] && ln -s ../usr/lib/systemd/systemd "$path/sbin/init" || ln -s /usr/lib/systemd/systemd "$path/sbin/init";;
        busybox) mkdir "$path/bin"; printf '#!/bin/sh\nexit 99\n' >"$path/bin/busybox"; chmod 755 "$path/bin/busybox"; ln -s ../bin/busybox "$path/sbin/init";;
        usr-merge) mkdir -p "$path/usr/sbin"; rmdir "$path/sbin"; ln -s usr/sbin "$path/sbin"; printf '#!/bin/sh\nexit 99\n' >"$path/usr/sbin/init"; chmod 755 "$path/usr/sbin/init";;
        split-usr) ln -s /usr/sbin/init "$path/sbin/init";;
    esac
}
run_case(){
    [[ -z $fx_case_filter || $1 == *"$fx_case_filter"* ]] || return 0
    case_name=$1; local topology=$2 filesystem=$3 layout=$4 expected=${5:-ok} source_kind=${6:-device} rc
    case_dir=$tmp/$case_name; mkdir "$case_dir"
    : >"$case_dir/mounts"; : >"$case_dir/probes"; : >"$case_dir/vg-events"
    fx_parts=(); fx_fs=(); fx_tree=(); fx_canonical=(); fx_rdev=(); fx_vg=(); fx_initial=()
    targets=/dev/A; expected_root=/dev/Aroot; fault=''; uuid_device=''; fx_pvs_json='{"report":[{"pv":[]}]}'; fx_lvs_json='{"report":[{"lv":[]}]}'
    add_device /dev/Aboot ext4 boot; mkdir "${fx_tree[/dev/Aboot]}/grub"; : >"${fx_tree[/dev/Aboot]}/vmlinuz"
    add_device /dev/Ahome ext4 home; mkdir "${fx_tree[/dev/Ahome]}/fixture-user"
    add_device /dev/Ausr ext4 usr; mkdir -p "${fx_tree[/dev/Ausr]}/sbin" "${fx_tree[/dev/Ausr]}/lib"
    printf '#!/bin/sh\nexit 99\n' >"${fx_tree[/dev/Ausr]}/sbin/init"; chmod 755 "${fx_tree[/dev/Ausr]}/sbin/init"
    printf 'NAME=not-a-root\n' >"${fx_tree[/dev/Ausr]}/lib/os-release"
    add_device /dev/Arelease ext4 release; mkdir -p "${fx_tree[/dev/Arelease]}/etc"; : >"${fx_tree[/dev/Arelease]}/etc/os-release"
    fx_parts[/dev/A]='/dev/Aboot /dev/Ahome /dev/Ausr /dev/Arelease'
    if [[ $topology == ordinary || $topology == ordinary-alias || $topology == split-usr-vg ]]; then
        add_device /dev/Aroot "$filesystem" root
        fx_parts[/dev/A]+=' /dev/Aroot'
    else
        add_device /dev/Apv LVM2_member pv
        add_device /dev/vgA/root "$filesystem" root vgA; expected_root=/dev/vgA/root
        fx_parts[/dev/A]+=' /dev/Apv'
        fx_pvs_json='{"report":[{"pv":[{"pv_name":"/dev/Apv","vg_name":"vgA","vg_uuid":"uuid-A"}]}]}'
        fx_lvs_json='{"report":[{"lv":[{"vg_name":"vgA","vg_uuid":"uuid-A","lv_name":"root","lv_path":"/dev/vgA/root","lv_active":"inactive"}]}]}'
        printf 'inactive\n' >"$case_dir/vgA-state"
        if [[ $topology == multi-pv || $topology == foreign-pv ]]; then
            add_device /dev/Bpv LVM2_member pvB; fx_parts[/dev/B]=/dev/Bpv
            [[ $topology != multi-pv ]] || targets='/dev/A /dev/B'
            fx_pvs_json=$(jq -c '.report[0].pv += [{pv_name:"/dev/Bpv",vg_name:"vgA",vg_uuid:"uuid-A"}]' <<<"$fx_pvs_json")
        fi
    fi
    make_root "${fx_tree[$expected_root]}" "$layout"
    if [[ $layout == split-usr ]]; then
        uuid_device=/dev/Ausr
        if [[ $topology == lvm || $topology == lvm-unrelated ]]; then
            add_device /dev/vgA/usr ext4 usr vgA; uuid_device=/dev/vgA/usr
            fx_lvs_json=$(jq -c '.report[0].lv += [{vg_name:"vgA",vg_uuid:"uuid-A",lv_name:"usr",lv_path:"/dev/vgA/usr",lv_active:"inactive"}]' <<<"$fx_lvs_json")
            if [[ $topology == lvm-unrelated ]]; then
                add_device /dev/vgZ/data ext4 unrelated vgZ; printf 'inactive\n' >"$case_dir/vgZ-state"
                fx_pvs_json=$(jq -c '.report[0].pv += [{pv_name:"/dev/FOREIGNpv",vg_name:"vgZ",vg_uuid:"uuid-Z"}]' <<<"$fx_pvs_json")
                fx_lvs_json=$(jq -c '.report[0].lv += [{vg_name:"vgZ",vg_uuid:"uuid-Z",lv_name:"data",lv_path:"/dev/vgZ/data",lv_active:"inactive"}]' <<<"$fx_lvs_json")
            fi
        elif [[ $topology == split-usr-vg || $topology == lvm-other-vg ]]; then
            local usr_group=vgU usr_lv=usr
            [[ $source_kind != mapper-escaped ]] || { usr_group=vg-U; usr_lv=usr-data; }
            add_device /dev/Ausrpv LVM2_member pvU; fx_parts[/dev/A]+=' /dev/Ausrpv'
            uuid_device=/dev/$usr_group/$usr_lv
            add_device "$uuid_device" ext4 usr "$usr_group"
            printf 'inactive\n' >"$case_dir/$usr_group-state"
            fx_pvs_json=$(jq -c --arg group "$usr_group" '.report[0].pv += [{pv_name:"/dev/Ausrpv",vg_name:$group,vg_uuid:"uuid-U"}]' <<<"$fx_pvs_json")
            fx_lvs_json=$(jq -c --arg group "$usr_group" --arg lv "$usr_lv" --arg path "$uuid_device" '.report[0].lv += [{vg_name:$group,vg_uuid:"uuid-U",lv_name:$lv,lv_path:$path,lv_active:"inactive"}]' <<<"$fx_lvs_json")
        fi
        local source=$uuid_device
        [[ $source_kind != uuid ]] || source=UUID=fixture-usr
        [[ $source_kind != partuuid ]] || source=PARTUUID=fixture-usr
        if [[ $source_kind == mapper || $source_kind == mapper-escaped ]]; then
            local group_name=${uuid_device#/dev/} lv_name=${uuid_device##*/}
            group_name=${group_name%%/*}; source=/dev/mapper/${group_name//-/--}-${lv_name//-/--}
            fx_fs[$source]=ext4; fx_canonical[$source]=$uuid_device; fx_rdev[$source]=${fx_rdev[$uuid_device]}; fx_vg[$source]=${fx_vg[$uuid_device]}
        fi
        case $case_name in
            *-unresolved) source=UUID=not-present; uuid_device=/dev/not-present;;
            *-invalid-source) source='UUID=not!valid';;
            *-missing-partuuid) source=PARTUUID=not-present; uuid_device=/dev/not-present;;
            *-foreign-usr) fx_pvs_json=$(jq -c '.report[0].pv |= map(if .vg_uuid=="uuid-U" then .pv_name="/dev/FOREIGNpv" else . end)' <<<"$fx_pvs_json");;
            *-borrowed-usr) printf 'active\n' >"$case_dir/vgU-state"; fx_initial[vgU]=active;;
        esac
        printf '%s /usr ext4 defaults 0 2\n' "$source" >"${fx_tree[$expected_root]}/etc/fstab"
    fi
    case $case_name in
        *-modern) : >"${fx_tree[$expected_root]}/etc/os-release";;
        *-root-mode) chmod 777 "${fx_tree[$expected_root]}";;
        *-passwd-mode) chmod 666 "${fx_tree[$expected_root]}/etc/passwd";;
        *-escape) rm "${fx_tree[$expected_root]}/sbin/init"; ln -s ../../../../bin/sh "${fx_tree[$expected_root]}/sbin/init";;
        *-no-passwd) rm "${fx_tree[$expected_root]}/etc/passwd";;
        *-no-init) rm "${fx_tree[$expected_root]}/sbin/init";;
        *-no-root) rm -r "${fx_tree[$expected_root]}/etc" "${fx_tree[$expected_root]}/sbin";;
        *-two-same-disk) add_device /dev/Aother ext4 other; make_root "${fx_tree[/dev/Aother]}" sysv; fx_parts[/dev/A]+=' /dev/Aother';;
        *-two-disks) add_device /dev/Broot ext4 other; make_root "${fx_tree[/dev/Broot]}" sysv; fx_parts[/dev/B]=/dev/Broot; targets='/dev/A /dev/B';;
        *-mount-failure) fault=mount;;
        *-unmount-failure) fault=unmount;;
        *-vg-cleanup-failure) fault=vg-cleanup;;
    esac
    if [[ $topology == ordinary-alias ]]; then
        fx_canonical[/dev/Aroot]=/dev/dm-alias
        fx_fs[/dev/dm-alias]=$filesystem; fx_rdev[/dev/dm-alias]=${fx_rdev[/dev/Aroot]}; fx_vg[/dev/dm-alias]=''
    fi
    rootpxe_cloud_init_error=''; rootpxe_linux_selected_candidate=''
    if [[ $case_name == *-missing-partuuid || $case_name == *-invalid-source ]]; then
        local -a ci_owned_mounts=() ci_vg_names=() ci_vg_uuids=() ci_vg_owned=()
        rootpxe_ci_mount_fstab "${fx_tree[$expected_root]}" /usr ro && fail 'invalid/missing partition source mounted'
        [[ ! -s $case_dir/vg-events ]] || fail 'invalid/PARTUUID source activated VG'
    fi
    if rootpxe_linux_select_unique_root_for_targets $targets; then rc=0; else rc=$?; fi
    if [[ $expected == ok ]]; then
        [[ $rc == 0 && $rootpxe_linux_selected_candidate == "$expected_root|$filesystem|"* ]] || fail "expected root $expected_root, rc=$rc reason=$rootpxe_cloud_init_error"
    else
        [[ $rc != 0 && $rootpxe_cloud_init_error == "$expected" ]] || fail "expected $expected, rc=$rc reason=$rootpxe_cloud_init_error"
    fi
    if [[ $fault != unmount ]]; then [[ ! -s $case_dir/mounts ]] || fail 'mount leaked'; fi
    if [[ $fault != vg-cleanup ]]; then
        for state_file in "$case_dir/"*-state; do
            [[ -f $state_file ]] || continue
            local group_name=${state_file##*/}; group_name=${group_name%-state}
            [[ $(<"$state_file") == "${fx_initial[$group_name]:-inactive}" ]] || fail "VG state changed: $group_name"
        done
    fi
    if [[ $topology == foreign-pv ]]; then [[ ! -s $case_dir/vg-events ]] || fail 'foreign VG activated'; fi
    if [[ $case_name == *-foreign-usr ]]; then ! grep -q ':vgU$' "$case_dir/vg-events" || fail 'foreign usr VG activated'; fi
    if [[ $case_name == *-borrowed-usr ]]; then ! grep -q ':vgU$' "$case_dir/vg-events" || fail 'borrowed usr VG changed'; fi
    if [[ $topology == lvm-unrelated ]]; then ! grep -q ':vgZ$' "$case_dir/vg-events" || fail 'unrelated VG activated'; fi
    printf 'CASE %s PASS selected=%s reason=%s probes=%s\n' "$case_name" "${rootpxe_linux_selected_candidate%%|*}" "${rootpxe_cloud_init_error:-none}" "$(wc -l <"$case_dir/probes")"
    count=$((count + 1))
}
count=0
group=${1:-ordinary}
fx_case_filter=${2:-}
case $group in
    ordinary)
        run_case ordinary-ext2-sysv ordinary ext2 sysv
        run_case ordinary-ext3-no-release ordinary ext3 sysv
        run_case ordinary-ext4-modern ordinary ext4 sysv
        run_case ordinary-xfs-lib-systemd ordinary xfs lib-systemd
        run_case ordinary-usr-systemd-relative ordinary ext4 usr-systemd-relative
        run_case ordinary-usr-systemd-absolute ordinary ext4 usr-systemd-absolute
        run_case ordinary-busybox ordinary ext4 busybox
        run_case ordinary-usr-merge ordinary ext4 usr-merge
        run_case ordinary-device-alias ordinary-alias ext4 sysv
        ;;
    lvm)
        run_case lvm-single-pv lvm ext4 sysv
        run_case lvm-multiple-permitted-pv multi-pv ext4 usr-systemd-relative
        run_case lvm-foreign-pv foreign-pv ext4 sysv cloud_init_root_probe_failed
        run_case lvm-vg-cleanup-failure lvm ext4 sysv cloud_init_root_probe_failed
        ;;
    usr)
        run_case ordinary-split-usr-device ordinary ext4 split-usr
        run_case ordinary-split-usr-uuid ordinary ext4 split-usr ok uuid
        run_case ordinary-split-usr-partuuid ordinary ext4 split-usr ok partuuid
        run_case lvm-same-vg-usr lvm ext4 split-usr
        run_case lvm-usr-unrelated-inactive-vg lvm-unrelated ext4 split-usr
        run_case ordinary-other-vg-usr-device split-usr-vg ext4 split-usr
        run_case ordinary-other-vg-usr-uuid split-usr-vg ext4 split-usr ok uuid
        run_case ordinary-other-vg-usr-mapper split-usr-vg ext4 split-usr ok mapper
        run_case ordinary-other-vg-usr-mapper-escaped split-usr-vg ext4 split-usr ok mapper-escaped
        run_case lvm-other-vg-usr-device lvm-other-vg ext4 split-usr
        run_case lvm-other-vg-usr-uuid lvm-other-vg ext4 split-usr ok uuid
        run_case ordinary-other-vg-unresolved split-usr-vg ext4 split-usr cloud_init_root_probe_failed uuid
        run_case ordinary-other-vg-invalid-source split-usr-vg ext4 split-usr cloud_init_root_probe_failed
        run_case ordinary-other-vg-missing-partuuid split-usr-vg ext4 split-usr cloud_init_root_probe_failed partuuid
        run_case ordinary-other-vg-foreign-usr split-usr-vg ext4 split-usr cloud_init_root_probe_failed
        run_case ordinary-other-vg-borrowed-usr split-usr-vg ext4 split-usr
        run_case ordinary-other-vg-cleanup-failure split-usr-vg ext4 split-usr cloud_init_root_probe_failed uuid
        ;;
    negative)
        for suffix in root-mode passwd-mode escape no-passwd no-init no-root; do run_case "ordinary-$suffix" ordinary ext4 sysv cloud_init_roots_not_unique; done
        run_case ordinary-two-same-disk ordinary ext4 sysv cloud_init_root_probe_failed
        run_case ordinary-two-disks ordinary ext4 sysv cloud_init_roots_not_unique
        run_case ordinary-mount-failure ordinary ext4 sysv cloud_init_root_probe_failed
        run_case ordinary-unmount-failure ordinary ext4 sysv cloud_init_probe_cleanup_failed
        ;;
    *) fail "unknown group $group";;
esac
[[ $count -gt 0 ]] || fail 'no matching matrix cases'
printf 'MATRIX group=%s passed=%s\n' "$group" "$count"
