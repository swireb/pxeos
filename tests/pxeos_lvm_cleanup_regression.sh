#!/usr/bin/env bash
# 执行真实 single 入口；所有块设备、VG、writer 与 mount 叶操作均为隔离夹具。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d /tmp/pxeos-lvm-cleanup.XXXXXX)
trap 'command rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for function_name in rootpxe_capture_lvm_volumes_single rootpxe_restore_lvm_volumes_single rootpxe_activate_lvm_vg; do
    eval "$(sed -n "/^$function_name() {\$/,/^}\$/p" "$funcs")"
done
rootpxe_lvm_is_pv_partition(){ return 0; }
rootpxe_lvm_capture_lv_facts_prepared(){ return 0; }
rootpxe_lvm_validate_capture_artifact_names(){ return 0; }
rootpxe_safe_relative_path(){ [[ $1 != /* && $1 != *..* ]]; }
rootpxe_lvm_safe_identifier(){ [[ $1 =~ ^[A-Za-z0-9._:+-]+$ ]]; }
rootpxe_lvm_validate_vg_name(){ [[ $1 == vg0 ]]; }
rootpxe_lvm_validate_mapper_name(){ [[ $1 == vg0 && $2 == swap || $1 == vg0 && $2 == root ]]; }
rootpxe_lvm_storage_filename(){ [[ $1 != */* && -n $1 ]]; }
rootpxe_lvm_pv_sidecar_binds_uuid(){ return 0; }
rootpxe_lvm_json_jq(){ jq "$@"; }
rootpxe_disk_stable_identity(){ printf 'fixture-target\n'; }
rootpxe_lvm_partition_path(){ printf '/dev/fixturep1\n'; }
rootpxe_console_message(){ :; }
rootpxe_task_console_failure(){ :; }
rootpxe_partition_progress_item(){ :; }
rootpxe_partition_progress_clear_current_item(){ :; }
rootpxe_xfs_restore_postcheck(){ return 0; }
rootpxe_display_metadata_collect_lvm(){ [[ $primary_failure != yes ]] || return 2; }
writeImage(){ [[ $restore_write_failure != yes ]]; }
blkid(){ [[ $* == *UUID* ]] && printf 'swap-1\n' || printf '%s\n' "$fixture_fs"; }
blockdev(){
    [[ $1 == --getsize64 && $2 == /dev/vg0/* ]] || fail 'unexpected block device query'
    [[ $restore_grown != yes ]] && printf '1048576\n' || printf '2097152\n'
}
mktemp(){
    local created
    created=$(command mktemp "$@") || return
    [[ ! -f $created ]] || printf '%s\n' "$created" >>"$case_dir/temp-files"
    printf '%s\n' "$created"
}
rm(){
    # 生产 fifo 固定在 /tmp；测试只登记意图，不删除宿主同名对象。
    for argument in "$@"; do
        if [[ $argument == /tmp/pigz1 ]]; then printf 'fifo-cleanup\n' >>"$trace"; return 0; fi
    done
    command rm "$@"
}
mv(){
    [[ $1 != *d1.lvm.schema.json ]] || printf 'publish-marker\n' >>"$trace"
    command mv "$@"
}
umount(){
    printf 'unmount\n' >>"$trace"
    [[ $unmount_failure != yes ]] || return 1
    command rm -f -- "$case_dir/mounted"
}
findmnt(){
    [[ $1 == -rn && $2 == --mountpoint && $4 == -o && $5 == TARGET ]] || fail 'unexpected mount state query'
    case ${mount_query_failure:-} in error) return 2;; mismatch) printf '/unexpected-mount\n'; return 0;; esac
    [[ -f $case_dir/mounted && $(cat "$case_dir/mounted") == "$3" ]] || return 1
    printf '%s\n' "$3"
}
rootpxe_run_logged_mutation(){ shift 2; rootpxe_lvm_native "$@"; }
rootpxe_lvm_native(){
    local command_name=$1; shift
    case $command_name in
        vgchange)
            printf 'vg:%s\n' "$1" >>"$trace"
            [[ $1 != -an || $cleanup_failure != yes ]]
            ;;
        pvdisplay) printf 'fixture PV metadata\n';;
        vgcfgbackup) printf 'fixture VG metadata\n' >"$2";;
        vgcfgrestore) restore_imported=yes;;
        pvcreate|pvresize|mkswap) return 0;;
        lvextend) restore_grown=yes;;
        vgs)
            if [[ $restore_imported == yes ]]; then printf '{"report":[{"vg":[{"vg_name":"vg0","vg_uuid":"vg-1"}]}]}\n'
            else printf '{"report":[{"vg":[]}]}\n'; fi
            ;;
        pvs)
            if [[ $restore_imported == yes ]]; then printf '{"report":[{"pv":[{"pv_name":"/dev/fixturep1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"}]}]}\n'
            else printf '{"report":[{"pv":[]}]}\n'; fi
            ;;
        lvs) printf '{"report":[{"lv":[{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"%s","lv_uuid":"lv-1","lv_path":"/dev/vg0/%s"}]}]}\n' "$fixture_lv" "$fixture_lv";;
        mount)
            printf 'mount\n' >>"$trace"
            printf '%s\n' "${@: -1}" >"$case_dir/mounted"
            ;;
        xfs_growfs) [[ $primary_failure != yes ]];;
        *) fail "unexpected native operation: $command_name";;
    esac
}
reset_case(){
    case_dir="$tmp/$1"
    mkdir -p "$case_dir/image"
    trace="$case_dir/trace"; : >"$trace"
    cleanup_failure=no primary_failure=no unmount_failure=no restore_write_failure=no
    fixture_fs=swap fixture_lv=swap restore_imported=no restore_grown=no
    rootpxe_lvm_active=yes
    unset rootpxe_lvm_captured rootpxe_lvm_capture_fragment_path
    rootpxe_lvm_lv_facts_file="$case_dir/lvs"
    printf 'swap|lv-1|/dev/vg0/swap|1048576|swap\n' >"$rootpxe_lvm_lv_facts_file"
    rootpxe_lvm_pv_path=/dev/fixturep1 rootpxe_lvm_pv_number=1 rootpxe_lvm_pv_uuid=pv-1
    rootpxe_lvm_vg_name=vg0 rootpxe_lvm_vg_uuid=vg-1
    rootpxe_lvm_pv_bytes=8388608 rootpxe_lvm_pe_start_bytes=1048576 rootpxe_lvm_vg_extent_bytes=4194304 rootpxe_lvm_vg_free_bytes=0
    rootpxe_disk_permit_granted=yes rootpxe_disk_permit_target_id=fixture-target rootpxe_disk_permit_operation=deploy_write
    rootpxe_resolved_lvm_layout_file="$case_dir/plan.json"
}
check_temporary_cleanup(){
    [[ -z $(find "$case_dir/image" -maxdepth 1 -type d -name '.rootpxe-lvm.*' -print -quit) ]] || fail 'capture staging retained'
    if [[ $kind == capture ]]; then grep -Fq fifo-cleanup "$trace" || fail 'independent capture fifo cleanup skipped'; fi
    if [[ -f $case_dir/temp-files ]]; then
        while IFS= read -r temporary_file; do [[ ! -e $temporary_file ]] || fail 'independent temporary file cleanup skipped'; done <"$case_dir/temp-files"
    fi
}
if [[ ${PXEOS_CLEANUP_TEST_KIND:-all} == all || ${PXEOS_CLEANUP_TEST_KIND:-all} == capture ]]; then
    for capture_case in cleanup normal fragment-cleanup fragment-normal primary primary-cleanup marker-existing fragment-existing; do
        kind=capture
        reset_case "capture-$capture_case"
        marker="$case_dir/image/d1.lvm.schema.json"
        case $capture_case in
            cleanup) cleanup_failure=yes;;
            fragment-*) rootpxe_lvm_capture_fragment_path="$case_dir/fragment.json"; marker=$rootpxe_lvm_capture_fragment_path; [[ $capture_case != fragment-cleanup ]] || cleanup_failure=yes; [[ $capture_case != fragment-existing ]] || printf 'user-owned-marker\n' >"$marker";;
            primary) primary_failure=yes;;
            primary-cleanup) primary_failure=yes; cleanup_failure=yes;;
            marker-existing) printf 'user-owned-marker\n' >"$marker";;
        esac
        if rootpxe_capture_lvm_volumes_single "$case_dir/image" >"$case_dir/output" 2>&1; then rc=0; else rc=$?; fi
        [[ $(grep -c '^vg:-an$' "$trace") == 1 ]] || fail "$capture_case deactivation not attempted exactly once"
        if [[ $capture_case == normal || $capture_case == fragment-normal ]]; then
            [[ $rc == 0 && -s $marker && ${rootpxe_lvm_captured:-no} == yes ]] || fail "$capture_case success changed"
            [[ $(grep -E '^vg:-an$|^publish-marker$' "$trace") == $'vg:-an\npublish-marker' ]] || fail 'capture marker published before VG cleanup'
        else
            [[ $rc != 0 && ${rootpxe_lvm_captured:-no} != yes ]] || fail "$capture_case reported success"
            if [[ $capture_case == *existing ]]; then [[ $(cat "$marker") == user-owned-marker ]] || fail 'existing marker changed'
            else [[ ! -e $marker ]] || fail "$capture_case published a marker"; fi
            case $capture_case in
                cleanup|fragment-cleanup) [[ $rootpxe_lvm_capture_error_code == LVM_CAPTURE_CLEANUP_FAILED && $rootpxe_lvm_capture_error_reason == vg_deactivation_failed ]] || fail 'capture cleanup reason missing';;
                primary*) [[ $rootpxe_lvm_capture_error_code == DISPLAY_METADATA_CLEANUP_FAILED && $rootpxe_lvm_capture_error_reason == read_only_probe_cleanup_failed ]] || fail 'capture primary error overwritten';;
            esac
            if [[ $capture_case == primary-cleanup ]]; then grep -Fq LVM_CAPTURE_CLEANUP_FAILED "$case_dir/output" || fail 'secondary capture cleanup failure hidden'; fi
        fi
        check_temporary_cleanup
        printf 'PASS: capture %s\n' "$capture_case"
    done
fi
if [[ ${PXEOS_CLEANUP_TEST_KIND:-all} == all || ${PXEOS_CLEANUP_TEST_KIND:-all} == restore ]]; then
    for restore_case in cleanup normal primary primary-cleanup xfs-normal xfs-unmount xfs-primary-unmount; do
        kind=restore
        reset_case "restore-$restore_case"
        case $restore_case in
            cleanup) cleanup_failure=yes;;
            primary|primary-cleanup|xfs-*) fixture_fs=xfs; fixture_lv=root;;
        esac
        case $restore_case in
            primary) restore_write_failure=yes;;
            primary-cleanup) restore_write_failure=yes; cleanup_failure=yes;;
            xfs-unmount) unmount_failure=yes;;
            xfs-primary-unmount) primary_failure=yes; unmount_failure=yes;;
        esac
        printf 'metadata\n' >"$case_dir/image/pv.meta"
        printf 'config\n' >"$case_dir/image/vg.cfg"
        printf 'image\n' >"$case_dir/image/root.img"
        jq -n --arg fs "$fixture_fs" --arg name "$fixture_lv" '{pv:{uuid:"pv-1",partitionNumber:1,originalBytes:8388608,artifact:"pv.meta",vgConfigArtifact:"vg.cfg"},vg:{name:"vg0",uuid:"vg-1",extentBytes:4194304},pvBytes:8388608,volumes:[{name:$name,uuid:"lv-1",fs:$fs,artifact:(if $fs=="swap" then "" else "root.img" end),resolvedBytes:(if $fs=="swap" then 1048576 else 2097152 end),swapUuid:(if $fs=="swap" then "swap-1" else "" end)}]}' >"$rootpxe_resolved_lvm_layout_file"
        if rootpxe_restore_lvm_volumes_single "$case_dir/image" /dev/fixture >"$case_dir/output" 2>&1; then rc=0; else rc=$?; fi
        if [[ $restore_case == normal || $restore_case == xfs-normal ]]; then
            [[ $rc == 0 ]] || fail 'normal restore failed'
        else
            [[ $rc != 0 ]] || fail "$restore_case reported success"
            case $restore_case in
                cleanup) [[ $rootpxe_restore_lvm_error_code == LVM_RESTORE_CLEANUP_FAILED && $rootpxe_restore_lvm_error_reason == vg_deactivation_failed ]] || fail 'restore cleanup reason missing';;
                primary*) [[ $rootpxe_restore_lvm_error_code == LVM_LV_IMAGE_RESTORE_FAILED ]] || fail 'restore primary error overwritten';;
                xfs-unmount) [[ $rootpxe_restore_lvm_error_code == LVM_XFS_GROW_UNMOUNT_FAILED ]] || fail 'unmount primary error overwritten';;
                xfs-primary-unmount) [[ $rootpxe_restore_lvm_error_code == LVM_XFS_GROW_FAILED ]] || fail 'restore primary error overwritten';;
            esac
        fi
        if [[ -e $case_dir/mounted ]]; then
            ! grep -Fq 'vg:-an' "$trace" || fail 'restore deactivated VG with a failed unmount'
            retained_mount=$(cat "$case_dir/mounted")
            [[ -d $retained_mount ]] || fail 'failed mount ownership path removed'
            command rmdir "$retained_mount"
        else [[ $(grep -c '^vg:-an$' "$trace") == 1 ]] || fail 'restore VG cleanup missing'; fi
        if [[ $restore_case == primary-cleanup ]]; then grep -Fq LVM_RESTORE_CLEANUP_FAILED "$case_dir/output" || fail 'secondary restore cleanup failure hidden'; fi
        check_temporary_cleanup
        printf 'PASS: restore %s\n' "$restore_case"
    done
fi
if [[ ${PXEOS_CLEANUP_TEST_KIND:-all} == all || ${PXEOS_CLEANUP_TEST_KIND:-all} == trap ]]; then
    # 直接执行生产 EXIT 设置，覆盖主操作成功但挂载状态不可核实的退出边界。
    cleanup_setup=$(sed -n '/^rootpxe_restore_lvm_volumes_single() {$/,/^}$/p' "$funcs" | awk '
      /^    rootpxe_restore_lvm_cleanup_exit\(\) {/ {copy=1}
      /^    trap .* EXIT$/ {print; exit}
      copy {print}')
    [[ -n $cleanup_setup ]] || fail 'production restore EXIT setup missing'
    for mount_query_failure in error mismatch; do
        reset_case "restore-query-$mount_query_failure"
        xfs_mount="$case_dir/owned-mount"; mkdir "$xfs_mount"
        printf '%s\n' "$xfs_mount" >"$case_dir/mounted"
        unmount_failure=yes
        lv_list="$case_dir/independent-file"; : >"$lv_list"
        rootpxe_restore_status_file="$case_dir/status"
        printf 'PRIMARY_DEFAULT|none\n' >"$rootpxe_restore_status_file"
        trap_rc=0
        (
            vg_active=yes vg=vg0 vg_uuid=vg-1
            eval "$cleanup_setup"
            :
        ) >"$case_dir/output" 2>&1 || trap_rc=$?
        [[ $trap_rc != 0 ]] || fail "findmnt $mount_query_failure reported success"
        ! grep -Fq 'vg:-an' "$trace" || fail "findmnt $mount_query_failure deactivated an unverified mounted VG"
        [[ $(cat "$rootpxe_restore_status_file") == 'LVM_RESTORE_CLEANUP_FAILED|xfs_mount_state_unavailable' ]] || fail 'mount query cleanup error missing'
        [[ ! -e $lv_list && -d $xfs_mount ]] || fail 'mount query failure skipped independent cleanup or removed mount ownership'
        printf 'PASS: restore EXIT findmnt %s\n' "$mount_query_failure"
    done
fi
printf 'PASS: production LVM capture/restore cleanup, marker gate and primary failure preservation\n'
