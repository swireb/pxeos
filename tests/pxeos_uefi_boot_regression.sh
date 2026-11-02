#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/uefi-boot.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -r $lib ]] || fail 'UEFI deployment registration feature is missing (uefi-boot.sh)'
. "$lib"
tmp=$(mktemp -d /tmp/pxeos-uefi-tests.XXXXXX)
trap '[[ $tmp == /tmp/pxeos-uefi-tests.* && -d $tmp && ! -L $tmp ]] && rm -rf -- "$tmp"' EXIT
cases=0
pass(){ cases=$((cases+1)); printf 'PASS case=%s\n' "$1"; }
le(){
    local file=$1 offset=$2 value=$3 count=$4 bytes='' oct i
    for ((i=0;i<count;i++)); do printf -v oct '\\%03o' "$(( (value >> (i*8)) & 255 ))"; bytes+=$oct; done
    printf '%b' "$bytes" | dd of="$file" bs=1 seek="$offset" conv=notrunc status=none
}
pe(){
    local file=$1 machine=${2:-34404} uki=${3:-no} optional=240 magic=523 section=392
    mkdir -p "${file%/*}"
    dd if=/dev/zero of="$file" bs=1024 count=1 status=none
    printf MZ | dd of="$file" conv=notrunc status=none
    le "$file" 60 128 4
    printf 'PE\0\0' | dd of="$file" bs=1 seek=128 conv=notrunc status=none
    le "$file" 132 "$machine" 2
    le "$file" 134 2 2
    if [[ $machine == 332 ]]; then optional=224; magic=267; section=376; fi
    le "$file" 148 "$optional" 2
    le "$file" 152 "$magic" 2
    le "$file" 220 10 2
    if [[ $uki == yes ]]; then
        printf .linux | dd of="$file" bs=1 seek="$section" conv=notrunc status=none
        printf .osrel | dd of="$file" bs=1 seek="$((section+40))" conv=notrunc status=none
    fi
}
reset_loader(){ rm -rf -- "$tmp/esp"; mkdir "$tmp/esp"; rootpxe_uefi_error=''; }
select_ok(){ rootpxe_uefi_select_loader "$tmp/esp" "${2:-amd64}" "${3:-50}" || fail "$1: ${rootpxe_uefi_error:-unknown}"; [[ $rootpxe_uefi_loader_path == "$4" ]] || fail "$1 selected $rootpxe_uefi_loader_path"; pass "$1"; }
select_bad(){ if rootpxe_uefi_select_loader "$tmp/esp" "${2:-amd64}" "${3:-50}"; then fail "$1 accepted"; fi; [[ $rootpxe_uefi_error == "$4" ]] || fail "$1 reason=$rootpxe_uefi_error"; pass "$1"; }

taskType=deploy osid=50 imageBootMode=BIOS imageArch=''
rootpxe_uefi_ensure_boot_for_targets /dev/never-open || fail 'BIOS skip failed'
pass bios_skip_without_firmware_or_arch
reset_loader; pe "$tmp/esp/EFI/redhat/grub.efi"
select_ok el6_legacy_vendor_layout_no_posix_gate amd64 50 /EFI/redhat/grub.efi
osid=9 imageBootMode='' imageArch=''
rootpxe_uefi_ensure_boot_for_targets /dev/never-open || fail 'Windows scope skip failed'
pass windows_skip_without_metadata_or_firmware
osid=51
rootpxe_uefi_ensure_boot_for_targets /dev/never-open || fail 'other OS scope skip failed'
pass other_os_scope_skip
osid=50 taskType=capture
rootpxe_uefi_ensure_boot_for_targets /dev/never-open || fail 'capture scope skip failed'
pass capture_scope_skip
taskType=deploy
reset_loader; pe "$tmp/esp/EFI/ubuntu/shimx64.efi"; pe "$tmp/esp/EFI/ubuntu/grubx64.efi"
select_ok shim_grub_same_chain_prefers_shim amd64 50 /EFI/ubuntu/shimx64.efi
reset_loader
for loader in shimx64-centos.efi shim.efi shimx64.efi grubx64.efi; do pe "$tmp/esp/EFI/centos/$loader"; done
select_ok el7_shim_aliases_choose_canonical amd64 50 /EFI/centos/shimx64.efi
reset_loader; pe "$tmp/esp/EFI/vendor/grubx64.efi"; pe "$tmp/esp/EFI/vendor/systemd-bootx64.efi"
select_bad same_directory_independent_managers amd64 50 uefi_boot_loader_ambiguous
reset_loader; pe "$tmp/esp/EFI/vendor/grub-rescue.efi"; pe "$tmp/esp/EFI/vendor/shim-old.efi"
select_bad backup_names_not_managers amd64 50 uefi_boot_loader_unknown
reset_loader; pe "$tmp/esp/EFI/systemd/systemd-bootx64.efi"; pe "$tmp/esp/EFI/Linux/a.efi" 34404 yes; pe "$tmp/esp/EFI/Linux/b.efi" 34404 yes
select_ok systemd_manager_multiple_uki_without_esp_entries amd64 50 /EFI/systemd/systemd-bootx64.efi
reset_loader; pe "$tmp/esp/EFI/Linux/linux.efi" 34404 yes
select_ok direct_uki_without_certificate_gate amd64 50 /EFI/Linux/linux.efi
reset_loader; pe "$tmp/esp/EFI/BOOT/BOOTX64.EFI"
select_ok explicit_default_path amd64 50 /EFI/BOOT/BOOTX64.EFI
reset_loader; pe "$tmp/esp/EFI/BOOT/BOOTAA64.EFI" 43620
select_ok arm64_default_path arm64 50 /EFI/BOOT/BOOTAA64.EFI
reset_loader; pe "$tmp/esp/EFI/BOOT/BOOTIA32.EFI" 332
select_ok i386_default_path i386 50 /EFI/BOOT/BOOTIA32.EFI
reset_loader
select_bad no_loader amd64 50 uefi_boot_loader_missing
reset_loader; pe "$tmp/esp/EFI/unknown/custom.efi"
select_bad unknown_loader amd64 50 uefi_boot_loader_unknown
reset_loader; pe "$tmp/esp/EFI/redhat/grub.efi" 43620
select_bad wrong_arch amd64 50 uefi_boot_loader_arch_mismatch
reset_loader; mkdir -p "$tmp/esp/EFI/redhat"; printf broken >"$tmp/esp/EFI/redhat/grub.efi"
select_bad invalid_pe amd64 50 uefi_boot_loader_invalid
reset_loader; pe "$tmp/esp/EFI/redhat/grub.efi" 332; le "$tmp/esp/EFI/redhat/grub.efi" 152 523 2
select_bad incompatible_ia32_optional_header i386 50 uefi_boot_loader_invalid
reset_loader; pe "$tmp/esp/EFI/one/grubx64.efi"; pe "$tmp/esp/EFI/two/grubx64.efi"
select_bad independent_managers_ambiguous amd64 50 uefi_boot_loader_ambiguous
reset_loader; pe "$tmp/esp/EFI/Linux/a.efi" 34404 yes; pe "$tmp/esp/EFI/Linux/b.efi" 34404 yes
select_bad direct_multiple_uki_ambiguous amd64 50 uefi_boot_loader_ambiguous
reset_loader; pe "$tmp/esp/EFI/redhat/grub.efi"; pe "$tmp/esp/EFI/redhat/mmx64.efi"; pe "$tmp/esp/EFI/redhat/fwupdx64.efi"
select_ok firmware_tools_not_os_candidates amd64 50 /EFI/redhat/grub.efi

# 真实目录/PE头/固件文本；只替换块设备报告、mount和efibootmgr命令叶边界。
rootpxe_verify_disk_permit_binding(){ [[ $1 == /dev/A || $1 == /dev/B ]] && [[ $2 == deploy_write && ${deny_permit:-no} == no ]]; }
# sfdisk mock uses a basename because its input is an absolute device path.
sfdisk(){ local disk=${@: -1}; cat "$tmp/table-${disk##*/}.json"; }
blkid(){ [[ ${unsupported_fs:-no} == no ]] && printf 'vfat\n' || printf 'ext4\n'; }
mountpoint(){ [[ ${@: -1} == "$rootpxe_uefi_firmware_dir/efivars" ]]; }
findmnt(){ printf 'efivarfs %s\n' "${variables_mode:-rw}"; }
mount(){
    local target=${@: -1} device=${@: -2:1}
    [[ ${mount_failed:-no} == no ]] || return 1
    [[ $target == /tmp/rootpxe-uefi.??????/* ]] || fail "unexpected mount $target"
    printf '%s\n' "${target%/*}" >>"$tmp/workdirs"
    cp -R "$tmp/esp-${device##*/}/." "$target/"
}
umount(){
    [[ $1 == /tmp/rootpxe-uefi.??????/* ]] || fail "unexpected umount $1"
    rm -rf -- "$1/EFI"
    [[ ${cleanup_failed:-no} == no ]]
}
efibootmgr(){
    local id='' loader='' disk='' number='' label='' order='' action='' n=3 row signature kind start size
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v) action=read; shift;;
            -C|--create-only) action=create; shift;;
            -d) disk=$2; shift 2;; -p) number=$2; shift 2;; -L) label=$2; shift 2;; -l) loader=$2; shift 2;;
            -b) id=$2; shift 2;; -a) action=active; shift;; -o) action=order; order=$2; shift 2;;
            *) fail "unexpected efibootmgr flag $1";;
        esac
    done
    case $action in
        read)
            [[ ${nvfail:-} != read ]] || return 1
            [[ ${nvfail:-} != warning ]] || printf 'Could not read variable Boot0009: Permission denied\n' >&2
            if [[ ${nvfail:-} == readback && -s $tmp/nv-events ]]; then grep -v '^Boot0003' "$tmp/nvram"; else cat "$tmp/nvram"; fi;;
        create)
            printf 'create\n' >>"$tmp/nv-events"
            [[ ${nvfail:-} != create ]] || return 1
            while printf -v id '%04X' "$n" && grep -q "^Boot$id" "$tmp/nvram"; do n=$((n+1)); done
            row=$(jq -c --argjson n "$number" '.partitiontable.partitions[$n-1]' "$tmp/table-${disk##*/}.json")
            kind=$(jq -r '.partitiontable.label' "$tmp/table-${disk##*/}.json")
            if [[ $kind == gpt ]]; then kind=GPT; signature=$(jq -r .uuid <<<"$row"); else kind=MBR; signature=$(jq -r '.partitiontable.id' "$tmp/table-${disk##*/}.json"); fi
            start=$(jq -r .start <<<"$row"); size=$(jq -r .size <<<"$row")
            printf 'Boot%s* %s HD(%s,%s,%s,0x%x,0x%x)/%s\n' "$id" "$label" "$number" "$kind" "$signature" "$start" "$size" "$loader" >>"$tmp/nvram";;
        active)
            printf 'active:%s\n' "$id" >>"$tmp/nv-events"
            [[ ${nvfail:-} != active ]] || return 1
            sed -i "s/^Boot$id /Boot$id* /" "$tmp/nvram";;
        order)
            printf 'order:%s\n' "$order" >>"$tmp/nv-events"
            [[ ${nvfail:-} != order ]] || return 1
            if grep -q "^BootOrder:" "$tmp/nvram"; then sed -i "s/^BootOrder:.*/BootOrder: $order/" "$tmp/nvram"; else printf "BootOrder: %s\n" "$order" >>"$tmp/nvram"; fi;;
    esac
}
flow_reset(){
    taskType=deploy imageBootMode=UEFI imageArch=amd64 osid=50
    rootpxe_uefi_firmware_dir="$tmp/firmware"
    mkdir -p "$rootpxe_uefi_firmware_dir/efivars"
    printf '64\n' >"$rootpxe_uefi_firmware_dir/fw_platform_size"
    uname(){ printf 'x86_64\n'; }
    nvfail='' deny_permit=no unsupported_fs=no variables_mode=rw mount_failed=no cleanup_failed=no
    : >"$tmp/nv-events"
    cat >"$tmp/nvram" <<'EOF'
BootCurrent: 0001
BootOrder: 0001,0000,0002
Boot0000* Local NVMe PciRoot(0x0)/NVMe(0x1,00)
Boot0001* PXE PciRoot(0x0)/MAC(001122334455,0)
Boot0002* Shell FvFile(1234)
EOF
    printf '%s\n' '{"partitiontable":{"label":"gpt","id":"11111111-2222-3333-4444-555555555555","unit":"sectors","sectorsize":512,"partitions":[{"node":"/dev/Ap1","start":2048,"size":409600,"type":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B","uuid":"d14174d8-a0ba-48c6-a463-e3537e91e6d4"}]}}' >"$tmp/table-A.json"
    rm -rf -- "$tmp/esp-Ap1" "$tmp/esp-Bp1"
    pe "$tmp/esp-Ap1/EFI/redhat/grub.efi"
}
flow_ok(){ rootpxe_uefi_ensure_boot_for_targets "${@:2}" || fail "$1 reason=${rootpxe_uefi_error:-unknown}"; pass "$1"; }
flow_bad(){ local name=$1 reason=$2; shift 2; if rootpxe_uefi_ensure_boot_for_targets "$@"; then fail "$name accepted"; fi; [[ $rootpxe_uefi_error == "$reason" ]] || fail "$name reason=$rootpxe_uefi_error"; pass "$name"; }
matching_entry(){ printf 'Boot0003%s RootPXE Linux HD(1,GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4,0x800,0x64000)/File(\\EFI\\redhat\\grub.efi)\n' "$1" >>"$tmp/nvram"; }

flow_reset; imageBootMode=''
flow_bad metadata_missing uefi_boot_metadata_missing /dev/A
flow_reset; rootpxe_uefi_firmware_dir="$tmp/no-firmware"
flow_bad uefi_image_bios_runtime uefi_boot_mode_mismatch /dev/A
flow_reset; printf '32\n' >"$rootpxe_uefi_firmware_dir/fw_platform_size"
flow_bad firmware_bitness_mismatch uefi_boot_firmware_arch_mismatch /dev/A
flow_reset
sed -i '/^BootOrder:/d' "$tmp/nvram"
printf 'No BootOrder is set; firmware will attempt recovery\n' >>"$tmp/nvram"
flow_ok missing_bootorder_stdout_notice /dev/A
flow_reset; nvfail=read
flow_bad variables_read_failure uefi_boot_variables_unavailable /dev/A
flow_reset; nvfail=warning
flow_bad partial_variable_read_exit_zero uefi_boot_variables_unavailable /dev/A
flow_reset; deny_permit=yes
flow_bad unpermitted_disk uefi_boot_target_binding_changed /dev/A
flow_reset; sed -i 's/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/other/' "$tmp/table-A.json"
flow_bad no_esp uefi_boot_esp_missing /dev/A
flow_reset; unsupported_fs=yes
flow_bad esp_not_fat uefi_boot_esp_filesystem_unsupported /dev/A
flow_reset; mount_failed=yes
flow_bad readonly_mount_failure uefi_boot_esp_mount_failed /dev/A
flow_reset
flow_ok gpt_create_keeps_pxe_priority /dev/A
grep -q '^BootOrder: 0001,0003,0000,0002$' "$tmp/nvram" || fail 'PXE/original order changed'
flow_ok repeated_execution_idempotent /dev/A
[[ $(grep -c '^create$' "$tmp/nv-events") == 1 ]] || fail 'duplicate entry created'
flow_reset; matching_entry '*'; sed -i 's/d14174d8-a0ba-48c6-a463-e3537e91e6d4/ffffffff-ffff-ffff-ffff-ffffffffffff/' "$tmp/nvram"
flow_ok same_label_wrong_guid_preserved /dev/A
[[ $(grep -c '^Boot000[34]' "$tmp/nvram") == 2 ]] || fail 'old entry overwritten'
flow_reset; matching_entry ''; sed -i 's/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
flow_ok matching_inactive_activated /dev/A
grep -q '^active:0003$' "$tmp/nv-events" || fail 'inactive not activated'
! grep -q '^create$' "$tmp/nv-events" || fail 'inactive duplicated'
flow_reset; matching_entry '*'
flow_ok active_entry_missing_order_repaired /dev/A
! grep -q '^create$' "$tmp/nv-events" || fail 'unlisted entry duplicated'
flow_reset; matching_entry '*'; sed -i 's/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"; variables_mode=ro
flow_ok correct_borrowed_readonly_vars_unchanged /dev/A
[[ ! -s $tmp/nv-events ]] || fail 'correct entry mutated'
flow_reset; matching_entry '*'; sed -i 's/grub.efi)/grub.efi.old)/' "$tmp/nvram"
flow_ok efi_old_suffix_not_matching_loader /dev/A
grep -q '^create$' "$tmp/nv-events" || fail '.efi.old incorrectly matched current loader'
flow_reset; matching_entry '*'; sed -i 's/redhat/REDHAT/;s/grub.efi/GRUB.EFI/;s/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
flow_ok file_node_case_insensitive_match /dev/A
[[ ! -s $tmp/nv-events ]] || fail 'case variant duplicated'
flow_reset; matching_entry '*'; sed -i 's@/File(\\EFI\\redhat\\grub.efi)@/\\EFI\\redhat\\grub.efi@;s/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
flow_ok plain_path_node_exact_match /dev/A
[[ ! -s $tmp/nv-events ]] || fail 'plain path duplicated'
flow_reset; matching_entry '*'; sed -i 's/0001,0000,0002/0001,0000,0002,0003/' "$tmp/nvram"
flow_ok existing_active_order_preserved_even_after_shell /dev/A
grep -q '^BootOrder: 0001,0000,0002,0003$' "$tmp/nvram" || fail 'existing active OS moved'
[[ ! -s $tmp/nv-events ]] || fail 'existing ordered entry mutated'
! grep -q '^create$' "$tmp/nv-events" || fail 'blocked existing entry duplicated'
flow_reset; printf 'BootOrder: 0002\nBoot0002* EFI Internal Shell FvFile(1234)\n' >"$tmp/nvram"
flow_ok shell_only_new_os_before_shell /dev/A
grep -q '^BootOrder: 0003,0002$' "$tmp/nvram" || fail 'new OS appended behind Shell'
flow_reset; sed -i 's/0001,0000,0002/0000,0001,0002/;s@PciRoot(0x0)/NVMe(0x1,00)@HD(1,GPT,ffffffff-ffff-ffff-ffff-ffffffffffff,0x800,0x64000)@' "$tmp/nvram"
flow_ok hd_only_local_anchor_retained /dev/A
grep -q '^BootOrder: 0003,0000,0001,0002$' "$tmp/nvram" || fail 'HD-only disk lost its original local priority'
flow_reset; sed -i 's/"gpt"/"dos"/;s/11111111-2222-3333-4444-555555555555/0xa1b2c3d4/;s/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ef/' "$tmp/table-A.json"
flow_ok mbr_ef_esp_created /dev/A
grep -q 'HD(1,MBR,0xa1b2c3d4,0x800,0x64000)' "$tmp/nvram" || fail 'MBR identity lost'
flow_ok mbr_entry_idempotent /dev/A
flow_reset; sed -i 's/"gpt"/"dos"/;s/11111111-2222-3333-4444-555555555555/0xa1b2c3d4/;s/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/0xef/' "$tmp/table-A.json"; matching_entry '*'; sed -i 's/GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4/MBR,0x11223344/' "$tmp/nvram"
flow_ok mbr_same_label_wrong_signature_preserved /dev/A
[[ $(grep -c '^Boot000[34]' "$tmp/nvram") == 2 ]] || fail 'wrong-signature item overwritten'
flow_reset; sed 's/Ap1/Bp1/g;s/d14174d8-a0ba-48c6-a463-e3537e91e6d4/ffffffff-ffff-ffff-ffff-ffffffffffff/g' "$tmp/table-A.json" >"$tmp/table-B.json"; pe "$tmp/esp-Bp1/EFI/ubuntu/grubx64.efi"
flow_bad multiple_target_esps_ambiguous uefi_boot_loader_ambiguous /dev/A /dev/B
[[ ! -s $tmp/nv-events ]] || fail 'ambiguous selection mutated NVRAM'
flow_reset; nvfail=create
flow_bad nvram_create_failure uefi_boot_entry_create_failed /dev/A
flow_reset; matching_entry ''; nvfail=active
flow_bad nvram_active_failure uefi_boot_entry_activate_failed /dev/A
flow_reset; nvfail=order
flow_bad boot_order_write_failure uefi_boot_order_update_failed /dev/A
flow_reset; nvfail=readback
flow_bad create_readback_failure uefi_boot_entry_readback_failed /dev/A
flow_reset; cleanup_failed=yes
flow_bad owned_mount_cleanup_failure uefi_boot_cleanup_failed /dev/A
old_work=$uefi_work
if rootpxe_uefi_ensure_boot_for_targets /dev/A; then fail 'persistent cleanup failure accepted'; fi
[[ $uefi_work == "$old_work" && $uefi_own_esp == yes ]] || fail 'persistent failure lost old workspace ownership'
pass persistent_cleanup_failure_preserves_workspace
cleanup_failed=no
rootpxe_uefi_cleanup || fail 'failed mount could not be retried'
[[ -z $uefi_work && $uefi_own_esp == no ]] || fail 'successful retry retained ownership'
rootpxe_uefi_cleanup || fail 'repeated completed cleanup failed'
pass failed_cleanup_retry_success

# The mock has no real mounts. Remove only work directories recorded by this test.
if [[ -f $tmp/workdirs ]]; then while IFS= read -r dir; do [[ $dir == /tmp/rootpxe-uefi.?????? && -d $dir && ! -L $dir ]] && rm -rf -- "$dir"; done <"$tmp/workdirs"; fi

# 执行真实正常/初始化续跑分支；仅把最终 finish 叶替换为事件记录。
for entry in normal cloud_init_resume; do
    for gate in pass fail; do
        : >"$tmp/finish-events"
        if (
            type=down imageBootMode=UEFI imageArch=amd64 resumeStage=cloud_init hd=/dev/A disks=/dev/A changeHostname=false
            killStatusReporter(){ :; }; rootpxe_partition_progress_flush(){ :; }; rootpxe_progress_data_phase_active(){ return 1; }
            rootpxe_deployment_identity_policy_enabled(){ return 1; }; rootpxe_deployment_identity_private_enabled(){ return 1; }
            rootpxe_deployment_identity_windows_policy_enabled(){ return 1; }; rootpxe_cloud_init_policy_enabled(){ return 0; }
            rootpxe_deployment_identity_cleanup_private(){ :; }
            rootpxe_apply_cloud_init(){ echo cloud_init >>"$tmp/finish-events"; }
            rootpxe_stage(){ printf 'stage:%s\n' "$1" >>"$tmp/finish-events"; }
            rootpxe_uefi_ensure_boot_for_targets(){ echo uefi_check >>"$tmp/finish-events"; [[ $gate == pass ]] || { rootpxe_uefi_error=uefi_boot_entry_create_failed; return 1; }; }
            fixture_finish(){ echo finish >>"$tmp/finish-events"; }
            handleError(){ echo rejected >>"$tmp/finish-events"; exit 73; }
            rootpxe_clear_disk_permit(){ :; }; rootpxe_disk_stable_identity(){ printf disk-a; }; rootpxe_record_disk_permit_binding(){ :; }
            rootpxe_wait_for_disk_permit(){ return 0; }; rootpxe_verify_disk_permit_binding(){ return 0; }; rootpxe_activate_disk_permit_binding(){ :; }
            if [[ $entry == normal ]]; then
                code=$(sed -n '/^completeTasking() {$/,/^}$/p' "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh")
                code=${code//. \/bin\/pxeos.imgcomplete/fixture_finish}
                eval "$code"
                completeTasking
            else
                code=$(sed -n '/^if \[\[ \${resumeStage:-} == customizing_hostname/,/^fi$/p' "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.download")
                code=${code//. \/bin\/pxeos.imgcomplete/fixture_finish}
                eval "$code"
            fi
        ); then result=0; else result=$?; fi
        if [[ $gate == fail ]]; then
            [[ $result == 73 ]] || fail "$entry bypassed failed UEFI registration result=$result"
            ! grep -qx finish "$tmp/finish-events" || fail "$entry finished after UEFI failure"
        else
            [[ $result == 0 ]] || fail "$entry success result=$result"
            [[ $(grep -c '^uefi_check$' "$tmp/finish-events") == 1 ]] || fail "$entry missed or duplicated registration"
            [[ $(tail -1 "$tmp/finish-events") == finish ]] || fail "$entry did not finish last"
        fi
        pass "${entry}_${gate}_finish_gate"
    done
done
# 正常回收及实际download EXIT/INT/TERM hook只清理本库自有挂载。
cleanup_code=$(sed -n '/^rootpxe_download_cleanup_initialization_private()/,/^rootpxe_partition_progress_initialize_runtime/p' "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.download")
cleanup_code=${cleanup_code%rootpxe_partition_progress_initialize_runtime*}
for signal in EXIT INT TERM; do
    mkdir -p "$tmp/cleanup-$signal/esp"
    : >"$tmp/cleanup-$signal/efibootmgr.stderr"
    set +e
    (
        killStatusReporter(){ :; }; rootpxe_cleanup_session(){ :; }
        uefi_work="$tmp/cleanup-$signal" uefi_vars="$tmp/own-vars" uefi_own_esp=yes uefi_own_vars=yes uefi_esp_cleanup_attempted=no uefi_vars_cleanup_attempted=no
        umount(){ printf '%s\n' "$1" >>"$tmp/cleanup-events-$signal"; }
        eval "$cleanup_code"
        if [[ $signal == EXIT ]]; then exit 0; else kill -s "$signal" "$BASHPID"; fi
    )
    result=$?
    set -e
    case $signal:$result in EXIT:0|INT:130|TERM:143) ;; *) fail "cleanup hook $signal exit=$result";; esac
    [[ $(wc -l <"$tmp/cleanup-events-$signal") == 2 && ! -e $tmp/cleanup-$signal ]] || fail "$signal cleanup missed or repeated owned mounts"
    pass "download_${signal}_owned_cleanup"
done
uefi_work='' uefi_own_esp=no uefi_own_vars=no
rootpxe_uefi_cleanup; rootpxe_uefi_cleanup
pass empty_cleanup_idempotent
printf 'UEFI_CASES=%s\n' "$cases"
