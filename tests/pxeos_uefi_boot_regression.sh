#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/uefi-boot.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -r $lib ]] || fail 'UEFI deployment registration feature is missing (uefi-boot.sh)'
. "$lib"
. "${lib%/*}/cloud-init.sh"
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
pe "$tmp/esp/EFI/debian/shimx64.efi"; pe "$tmp/esp/EFI/debian/grubx64.efi"
mkdir -p "$tmp/esp/EFI/BOOT"
cp "$tmp/esp/EFI/debian/shimx64.efi" "$tmp/esp/EFI/BOOT/BOOTX64.EFI"
cp "$tmp/esp/EFI/debian/grubx64.efi" "$tmp/esp/EFI/BOOT/grubx64.efi"
pe "$tmp/esp/EFI/BOOT/mmx64.efi"; pe "$tmp/esp/EFI/BOOT/fbx64.efi"
select_ok vendor_with_complete_fallback_chain amd64 50 /EFI/debian/shimx64.efi
for vendor in ubuntu rocky vendor; do
    reset_loader
    pe "$tmp/esp/EFI/$vendor/shimx64.efi"; pe "$tmp/esp/EFI/$vendor/grubx64.efi"
    mkdir -p "$tmp/esp/EFI/BOOT"
    cp "$tmp/esp/EFI/$vendor/shimx64.efi" "$tmp/esp/EFI/BOOT/BOOTX64.EFI"
    cp "$tmp/esp/EFI/$vendor/grubx64.efi" "$tmp/esp/EFI/BOOT/grubx64.efi"
    select_ok "${vendor}_with_fallback_companions" amd64 50 "/EFI/$vendor/shimx64.efi"
done
reset_loader; pe "$tmp/esp/EFI/BOOT/BOOTX64.EFI"; pe "$tmp/esp/EFI/BOOT/grubx64.efi"; pe "$tmp/esp/EFI/BOOT/systemd-bootx64.efi"
select_ok fallback_companions_select_canonical amd64 50 /EFI/BOOT/BOOTX64.EFI
for arch in i386 arm64; do
    reset_loader
    if [[ $arch == i386 ]]; then machine=332; fallback=BOOTIA32.EFI; manager=grubia32.efi
    else machine=43620; fallback=BOOTAA64.EFI; manager=grubaa64.efi; fi
    pe "$tmp/esp/EFI/BOOT/$fallback" "$machine"; pe "$tmp/esp/EFI/BOOT/$manager" "$machine"
    select_ok "${arch}_fallback_companion" "$arch" 50 "/EFI/BOOT/$fallback"
done
reset_loader; pe "$tmp/esp/EFI/Linux/linux.efi" 34404 yes; pe "$tmp/esp/EFI/BOOT/BOOTX64.EFI"; pe "$tmp/esp/EFI/BOOT/grubx64.efi"
select_ok unique_uki_before_fallback_chain amd64 50 /EFI/Linux/linux.efi
reset_loader; pe "$tmp/esp/EFI/BOOT/grubx64.efi"
select_ok boot_manager_without_canonical_preserved amd64 50 /EFI/BOOT/grubx64.efi
reset_loader; pe "$tmp/esp/EFI/BOOT/grubx64.efi"; printf broken >"$tmp/esp/EFI/BOOT/BOOTX64.EFI"
select_ok invalid_canonical_does_not_hide_manager amd64 50 /EFI/BOOT/grubx64.efi
reset_loader; pe "$tmp/esp/EFI/BOOT/grubx64.efi"; pe "$tmp/esp/EFI/BOOT/BOOTX64.EFI" 43620
select_ok wrong_arch_canonical_does_not_hide_manager amd64 50 /EFI/BOOT/grubx64.efi
reset_loader; pe "$tmp/esp/EFI/one/grubx64.efi"; pe "$tmp/esp/EFI/two/grubx64.efi"; pe "$tmp/esp/EFI/BOOT/BOOTX64.EFI"; pe "$tmp/esp/EFI/BOOT/grubx64.efi"
select_bad independent_vendors_with_fallback_still_ambiguous amd64 50 uefi_boot_loader_ambiguous
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

# Read NAME as target text; release-only metadata must not infer a name.
rootpxe_ci_stat(){ printf '0:0:%s\n' "$(stat -c '%a:%h' -- "$1")"; }
umask 077
mkdir -p "$tmp/os/etc" "$tmp/os/usr/lib"
printf 'NAME="Rocky Linux"\nPRETTY_NAME="Rocky Linux 10"\n' >"$tmp/os/etc/os-release"
[[ $(rootpxe_uefi_system_name "$tmp/os") == 'Rocky Linux' ]] || fail 'NAME was not preferred'
printf 'NAME="Example GNU/Linux"\nPRETTY_NAME="Ubuntu 24.04 LTS"\nID=rocky\n' >"$tmp/os/etc/os-release"
[[ $(rootpxe_uefi_system_name "$tmp/os") == 'Example GNU/Linux' ]] || fail 'NAME was mapped from other distribution metadata'
printf "NAME='Ubuntu'\n" >"$tmp/os/etc/os-release"
[[ $(rootpxe_uefi_system_name "$tmp/os") == Ubuntu ]] || fail 'single-quoted NAME was not read'
rm "$tmp/os/etc/os-release"
printf 'NAME="Rocky Linux"\n' >"$tmp/os/usr/lib/os-release"
ln -s ../usr/lib/os-release "$tmp/os/etc/os-release"
[[ $(rootpxe_uefi_system_name "$tmp/os") == 'Rocky Linux' ]] || fail 'target-relative os-release link failed'
rm "$tmp/os/etc/os-release"
ln -s /usr/lib/os-release "$tmp/os/etc/os-release"
[[ $(rootpxe_uefi_system_name "$tmp/os") == 'Rocky Linux' ]] || fail 'absolute os-release link escaped target root'
rm "$tmp/os/etc/os-release" "$tmp/os/usr/lib/os-release"
printf 'CentOS release 6.10 (Final)\n' >"$tmp/os/etc/centos-release"
if rootpxe_uefi_system_name "$tmp/os"; then fail 'release-only CentOS metadata supplied a name'; fi
rm "$tmp/os/etc/centos-release"
printf 'Red Hat Enterprise Linux Server release 6.10 (Santiago)\n' >"$tmp/os/etc/redhat-release"
if rootpxe_uefi_system_name "$tmp/os"; then fail 'release-only Red Hat metadata supplied a name'; fi
rm "$tmp/os/etc/redhat-release"
printf 'Example Linux release 1\n' >"$tmp/os/etc/system-release"
printf 'NAME=""\nPRETTY_NAME="Example Linux 1"\nID=example\n' >"$tmp/os/etc/os-release"
if rootpxe_uefi_system_name "$tmp/os"; then fail 'empty NAME was inferred from other metadata'; fi
rm "$tmp/os/etc/system-release"
printf 'NAME="$(touch %s/executed)"\n' "$tmp" >"$tmp/os/etc/os-release"
if rootpxe_uefi_system_name "$tmp/os"; then fail 'executable metadata accepted as a name'; fi
[[ ! -e $tmp/executed ]] || fail 'target metadata was executed'
rm "$tmp/os/etc/os-release"
ln -s ../../outside-os-release "$tmp/os/etc/os-release"
printf 'NAME=Foreign\n' >"$tmp/outside-os-release"
if rootpxe_uefi_system_name "$tmp/os"; then fail 'metadata escaped target root'; fi
pass target_name_metadata_safe

(
    rm "$tmp/os/etc/os-release"
    rootpxe_linux_select_unique_root_for_targets(){
        [[ $* == '/dev/A /dev/B' ]] || fail 'root discovery expanded its target set'
        rootpxe_linux_selected_disk=/dev/A
        rootpxe_linux_selected_candidate='/dev/Ap2|ext4|||'
    }
    rootpxe_ci_mount_root(){ [[ $1 == /dev/Ap2 && $2 == ext4 && $4 == ro ]] || fail 'root was not mounted read-only'; ci_mounted_root="$tmp/os"; name_work=$3; }
    rootpxe_ci_mount_fstab(){ [[ $2 == /usr && $3 == ro ]] || fail 'unexpected auxiliary mount'; printf 'NAME=Ubuntu\n' >"$tmp/os/usr/lib/os-release"; }
    rootpxe_ci_cleanup_mounts(){ [[ ${name_cleanup_failed:-no} == no ]]; }
    rootpxe_ci_workspace_remove(){ rmdir "$1"; }
    rootpxe_uefi_target_label /dev/A /dev/B || fail 'target name lifecycle failed'
    [[ $uefi_label == Ubuntu ]] || fail 'separate usr metadata not read'
    name_cleanup_failed=yes
    if rootpxe_uefi_target_label /dev/A /dev/B; then fail 'name cleanup failure swallowed'; fi
    [[ $rootpxe_uefi_error == uefi_boot_cleanup_failed ]] || fail 'wrong name cleanup error'
    rmdir "$name_work"
    uefi_name_work=''
    rootpxe_linux_select_unique_root_for_targets(){ return 1; }
    rootpxe_uefi_target_label /dev/A /dev/B || fail 'unknown root fallback failed'
    [[ $uefi_label == Linux ]] || fail 'unknown root did not fall back to Linux'
)
pass target_name_readonly_mount_lifecycle

# Use the real CI cleanup/workspace routines, replacing only umount/LVM leaves.
(
    eval "$(sed -n '/^rootpxe_linux_cleanup_selected_vg() {$/,/^}$/p' "${lib%/*}/funcs.sh")"
    uefi_work='' uefi_name_work=$(mktemp -d /tmp/rootpxe-cloud-mount.XXXXXX)
    mkdir "$uefi_name_work/root"
    uefi_name_mounts=("$uefi_name_work/root") uefi_name_vg_names=(owned borrowed)
    uefi_name_vg_uuids=(uuid-owned uuid-borrowed) uefi_name_vg_owned=(yes no)
    name_cleanup_failed=yes
    umount(){ [[ $name_cleanup_failed == no ]]; }
    mountpoint(){ return 1; }
    rootpxe_lvm_native(){ printf '%s\n' "$*" >>"$tmp/name-vg-cleanup"; }
    if rootpxe_uefi_cleanup; then fail 'failed name mount cleanup was accepted'; fi
    [[ -d $uefi_name_work/root && ${#uefi_name_mounts[@]} == 1 && ${#uefi_name_vg_names[@]} == 2 ]] || fail 'failed name cleanup lost ownership'
    [[ ! -e $tmp/name-vg-cleanup ]] || fail 'VG deactivated under a mounted root'
    name_cleanup_failed=no
    rootpxe_uefi_cleanup || fail 'name cleanup could not be retried'
    [[ -z $uefi_name_work && ${#uefi_name_mounts[@]} == 0 && ${#uefi_name_vg_names[@]} == 0 ]] || fail 'successful name cleanup retained ownership'
    [[ $(wc -l <"$tmp/name-vg-cleanup") == 1 ]] || fail 'borrowed VG was deactivated'
)
pass target_name_cleanup_retains_ownership

# 真实目录/PE头/固件文本；只替换块设备报告、mount和efibootmgr命令叶边界。
rootpxe_uefi_target_label(){ uefi_label=${fixture_system_name:-Linux}; }
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
            -b) id=$2; shift 2;; -a) action=active; shift;; -B) action=delete; shift;; -o) action=order; order=$2; shift 2;;
            *) fail "unexpected efibootmgr flag $1";;
        esac
    done
    case $action in
        read)
            [[ ${nvfail:-} != read ]] || return 1
            [[ ${nvfail:-} != warning ]] || printf 'Could not read variable Boot0009: Permission denied\n' >&2
            if [[ ${nvfail:-} == readback && -s $tmp/nv-events ]]; then grep -v '^Boot000[34]' "$tmp/nvram"; else cat "$tmp/nvram"; fi;;
        create)
            printf 'create\n' >>"$tmp/nv-events"
            [[ ${nvfail:-} != create ]] || return 1
            while printf -v id '%04X' "$n" && grep -q "^Boot$id" "$tmp/nvram"; do n=$((n+1)); done
            row=$(jq -c --argjson n "$number" '.partitiontable.partitions[$n-1]' "$tmp/table-${disk##*/}.json")
            kind=$(jq -r '.partitiontable.label' "$tmp/table-${disk##*/}.json")
            if [[ $kind == gpt ]]; then kind=GPT; signature=$(jq -r .uuid <<<"$row"); else kind=MBR; signature=$(jq -r '.partitiontable.id' "$tmp/table-${disk##*/}.json"); fi
            start=$(jq -r .start <<<"$row"); size=$(jq -r .size <<<"$row")
            printf 'Boot%s* %s\tHD(%s,%s,%s,0x%x,0x%x)/%s\n' "$id" "$label" "$number" "$kind" "$signature" "$start" "$size" "$loader" >>"$tmp/nvram";;
        active)
            printf 'active:%s\n' "$id" >>"$tmp/nv-events"
            [[ ${nvfail:-} != active ]] || return 1
            sed -i "s/^Boot$id /Boot$id* /" "$tmp/nvram";;
        order)
            printf 'order:%s\n' "$order" >>"$tmp/nv-events"
            [[ ${nvfail:-} != order ]] || return 1
            if grep -q "^BootOrder:" "$tmp/nvram"; then sed -i "s/^BootOrder:.*/BootOrder: $order/" "$tmp/nvram"; else printf "BootOrder: %s\n" "$order" >>"$tmp/nvram"; fi;;
        delete)
            printf 'delete:%s\n' "$id" >>"$tmp/nv-events"
            [[ ${nvfail:-} != delete ]] || return 1
            sed -i "/^Boot$id/d" "$tmp/nvram";;
    esac
}
flow_reset(){
    taskType=deploy imageBootMode=UEFI imageArch=amd64 osid=50
    rootpxe_uefi_firmware_dir="$tmp/firmware"
    mkdir -p "$rootpxe_uefi_firmware_dir/efivars"
    printf '64\n' >"$rootpxe_uefi_firmware_dir/fw_platform_size"
    uname(){ printf 'x86_64\n'; }
    nvfail='' deny_permit=no unsupported_fs=no variables_mode=rw mount_failed=no cleanup_failed=no fixture_system_name=Linux
    : >"$tmp/nv-events"
    cat >"$tmp/nvram" <<'EOF'
BootCurrent: 0001
BootOrder: 0001,0000,0002
Boot0000* Local NVMe	PciRoot(0x0)/NVMe(0x1,00)
Boot0001* PXE	PciRoot(0x0)/MAC(001122334455,0)
Boot0002* Shell	FvFile(1234)
EOF
    printf '%s\n' '{"partitiontable":{"label":"gpt","id":"11111111-2222-3333-4444-555555555555","unit":"sectors","sectorsize":512,"partitions":[{"node":"/dev/Ap1","start":2048,"size":409600,"type":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B","uuid":"d14174d8-a0ba-48c6-a463-e3537e91e6d4"}]}}' >"$tmp/table-A.json"
    rm -rf -- "$tmp/esp-Ap1" "$tmp/esp-Bp1"
    pe "$tmp/esp-Ap1/EFI/redhat/grub.efi"
}
flow_ok(){ rootpxe_uefi_ensure_boot_for_targets "${@:2}" || fail "$1 reason=${rootpxe_uefi_error:-unknown}"; pass "$1"; }
flow_bad(){ local name=$1 reason=$2; shift 2; if rootpxe_uefi_ensure_boot_for_targets "$@"; then fail "$name accepted"; fi; [[ $rootpxe_uefi_error == "$reason" ]] || fail "$name reason=$rootpxe_uefi_error"; pass "$name"; }
matching_entry(){ printf 'Boot0003%s %s\tHD(1,GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4,0x800,0x64000)/File(\\EFI\\redhat\\grub.efi)\n' "$1" "${2:-RootPXE Linux}" >>"$tmp/nvram"; }

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
grep -q $'^Boot0003\\* Linux\t' "$tmp/nvram" || fail 'unknown system fallback label missing'
flow_reset; fixture_system_name='Rocky Linux'
flow_ok new_entry_uses_actual_system_name /dev/A
grep -q $'^Boot0003\\* Rocky Linux\t' "$tmp/nvram" || fail 'new entry did not use NAME'
flow_reset; fixture_system_name='Debian GNU/Linux'
rm -rf "$tmp/esp-Ap1"
pe "$tmp/esp-Ap1/EFI/debian/grubx64.efi"
flow_ok debian_grub_only_registration_idempotent /dev/A
[[ $rootpxe_uefi_loader_path == /EFI/debian/grubx64.efi ]] || fail 'Debian GRUB-only loader was not selected'
grep -Fq $'Debian GNU/Linux\t' "$tmp/nvram" || fail 'Debian NAME was not preserved'
snapshot=$(sha256sum "$tmp/nvram")
rootpxe_uefi_ensure_boot_for_targets /dev/A || fail 'Debian GRUB-only repeat failed'
[[ $(sha256sum "$tmp/nvram") == "$snapshot" && $(grep -c '^create$' "$tmp/nv-events") == 1 ]] || fail 'Debian GRUB-only entry duplicated'
flow_reset; fixture_system_name='Rocky Linux'; matching_entry '*' 'RootPXE OS'
sed -i 's/0001,0000,0002/0001,0000,0003,0002/' "$tmp/nvram"
flow_ok managed_label_migrated_in_original_position /dev/A
grep -q '^BootOrder: 0001,0000,0004,0002$' "$tmp/nvram" || fail 'managed migration changed order'
! grep -q '^Boot0003' "$tmp/nvram" || fail 'old managed item retained after successful migration'
grep -q $'^Boot0004\\* Rocky Linux\t' "$tmp/nvram" || fail 'managed label was not migrated'
[[ $(tail -1 "$tmp/nv-events") == delete:0003 ]] || fail 'managed item deleted before verification'
flow_ok managed_migration_idempotent /dev/A
[[ $(grep -c '^create$' "$tmp/nv-events") == 1 ]] || fail 'managed migration duplicated new item'
flow_reset; matching_entry '*' 'RootPXE OS'
sed -i 's/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
flow_ok unknown_name_preserves_managed_item /dev/A
[[ ! -s $tmp/nv-events ]] || fail 'unknown name migrated managed item'
flow_reset; fixture_system_name=Ubuntu; matching_entry '*' 'My custom Linux'
sed -i 's/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
flow_ok custom_label_preserved /dev/A
[[ ! -s $tmp/nv-events ]] || fail 'custom name was changed'
flow_reset; fixture_system_name=CentOS; matching_entry '*' 'RootPXE OS'
sed -n '/^Boot0003/p' "$tmp/nvram" | sed 's/Boot0003/Boot0004/' >>"$tmp/nvram"
sed -i 's/0001,0000,0002/0001,0003,0004,0000,0002/' "$tmp/nvram"
flow_ok ambiguous_managed_items_preserved /dev/A
[[ ! -s $tmp/nv-events ]] || fail 'ambiguous managed items migrated'
for fault in create readback order delete; do
    flow_reset; fixture_system_name='Rocky Linux'; matching_entry '*' 'RootPXE OS'
    sed -i 's/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
    nvfail=$fault
    if rootpxe_uefi_ensure_boot_for_targets /dev/A; then fail "$fault migration unexpectedly passed"; fi
    grep -q '^Boot0003' "$tmp/nvram" || fail "$fault failure removed old managed item"
    nvfail=''
    flow_ok "managed_${fault}_failure_retry" /dev/A
    [[ $(grep -c '^Boot[[:xdigit:]]\{4\}' "$tmp/nvram") == 4 ]] || fail "$fault retry duplicated entries"
done
flow_reset; fixture_system_name=Ubuntu
printf 'Boot0003* fake\tHD(1,GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4,0x800,0x64000)/File(\\EFI\\redhat\\grub.efi)\tHD(1,GPT,ffffffff-ffff-ffff-ffff-ffffffffffff,0x800,0x64000)/File(\\EFI\\redhat\\grub.efi)\n' >>"$tmp/nvram"
flow_ok label_cannot_supply_matching_device_path /dev/A
grep -q '^create$' "$tmp/nv-events" || fail 'device path was taken from label'
flow_reset; fixture_system_name='RootPXE Linux'; matching_entry '*'; sed -i 's/d14174d8-a0ba-48c6-a463-e3537e91e6d4/ffffffff-ffff-ffff-ffff-ffffffffffff/' "$tmp/nvram"
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
flow_reset; printf 'BootOrder: 0002\nBoot0002* EFI Internal Shell\tFvFile(1234)\n' >"$tmp/nvram"
flow_ok shell_only_new_os_before_shell /dev/A
grep -q '^BootOrder: 0003,0002$' "$tmp/nvram" || fail 'new OS appended behind Shell'
flow_reset; sed -i 's/0001,0000,0002/0000,0001,0002/;s@PciRoot(0x0)/NVMe(0x1,00)@HD(1,GPT,ffffffff-ffff-ffff-ffff-ffffffffffff,0x800,0x64000)@' "$tmp/nvram"
flow_ok hd_only_local_anchor_retained /dev/A
grep -q '^BootOrder: 0003,0000,0001,0002$' "$tmp/nvram" || fail 'HD-only disk lost its original local priority'
flow_reset; sed -i 's/"gpt"/"dos"/;s/11111111-2222-3333-4444-555555555555/0xa1b2c3d4/;s/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ef/' "$tmp/table-A.json"
flow_ok mbr_ef_esp_created /dev/A
grep -q 'HD(1,MBR,0xa1b2c3d4,0x800,0x64000)' "$tmp/nvram" || fail 'MBR identity lost'
flow_ok mbr_entry_idempotent /dev/A
flow_reset; fixture_system_name='RootPXE Linux'; sed -i 's/"gpt"/"dos"/;s/11111111-2222-3333-4444-555555555555/0xa1b2c3d4/;s/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/0xef/' "$tmp/table-A.json"; matching_entry '*'; sed -i 's/GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4/MBR,0x11223344/' "$tmp/nvram"
flow_ok mbr_same_label_wrong_signature_preserved /dev/A
[[ $(grep -c '^Boot000[34]' "$tmp/nvram") == 2 ]] || fail 'wrong-signature item overwritten'
for boundary in start size; do
    flow_reset; fixture_system_name='RootPXE Linux'
    sed -i 's/"gpt"/"dos"/;s/11111111-2222-3333-4444-555555555555/0xa1b2c3d4/;s/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ef/' "$tmp/table-A.json"
    matching_entry '*'
    sed -i 's/GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4/MBR,0xa1b2c3d4/' "$tmp/nvram"
    if [[ $boundary == start ]]; then sed -i 's/0x800,0x64000/0x801,0x64000/' "$tmp/nvram"
    else sed -i 's/0x800,0x64000/0x800,0x64001/' "$tmp/nvram"; fi
    old_entry=$(grep '^Boot0003' "$tmp/nvram")
    flow_ok "mbr_same_signature_wrong_${boundary}_preserved" /dev/A
    [[ $(grep '^Boot0003' "$tmp/nvram") == "$old_entry" ]] || fail 'different MBR partition was overwritten'
    rootpxe_uefi_ensure_boot_for_targets /dev/A || fail 'MBR repeat registration failed'
    [[ $(grep -c '^Boot000[34]' "$tmp/nvram") == 2 ]] || fail 'MBR identity mismatch duplicated target'
done
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

# Keep the metadata-to-registration chain real. Only device/LVM reports and
# mount/firmware command leaves are substituted with ordinary directories.
(
    . "$lib"
    for fn in rootpxe_linux_root_fstype_supported rootpxe_linux_mount_options rootpxe_linux_probe_root_candidate rootpxe_find_linux_root_filesystem rootpxe_linux_validate_vg_target_pvs rootpxe_linux_activate_vg_if_needed rootpxe_linux_lvs_for_vg_json rootpxe_linux_cleanup_selected_vg rootpxe_lvm_safe_identifier rootpxe_lvm_validate_vg_name rootpxe_lvm_trim; do
        eval "$(sed -n "/^$fn() {/,/^}/p" "${lib%/*}/funcs.sh")"
    done
    rootpxe_lvm_json_jq(){ jq "$@"; }
    getPartitions(){ [[ $1 == /dev/A ]] || fail 'unexpected root-discovery disk'; parts='/dev/Ap1 /dev/Ap2'; }
    rootpxe_ci_device_is_block(){ [[ $1 == /dev/Ap2 || $1 == /dev/vg/root || $1 == /dev/vg/usr ]]; }
    rootpxe_linux_lvm_path_readable(){ [[ $(<"$tmp/matrix-vg-state") == active ]]; }
    rootpxe_run_logged_typed_native(){ shift 2; "$@"; }
    vgchange(){ rootpxe_lvm_native vgchange "$@"; }
    readlink(){
        if [[ $1 == -f && ${@: -1} == /dev/* ]]; then printf '%s\n' "${@: -1}"
        else command readlink "$@"; fi
    }
    stat(){
        if [[ $1 == -c && $2 == %r && ${@: -1} == /dev/* ]]; then command stat -c %d "$tmp"
        else command stat "$@"; fi
    }
    blkid(){
        case ${@: -1} in
            /dev/Ap1) printf 'vfat\n';;
            /dev/Ap2) [[ $topology == partition ]] && printf 'ext4\n' || printf 'LVM2_member\n';;
            /dev/vg/root|/dev/vg/usr) printf 'xfs\n';;
            *) fail 'unexpected metadata device';;
        esac
    }
    rootpxe_lvm_native(){
        case $1 in
            pvs) printf '%s\n' '{"report":[{"pv":[{"pv_name":"/dev/Ap2","vg_name":"vg","vg_uuid":"uuid-vg"}]}]}';;
            lvs) jq -n --arg state "$(<"$tmp/matrix-vg-state")" '{report:[{lv:["root","usr"]|map({vg_name:"vg",vg_uuid:"uuid-vg",lv_name:.,lv_path:("/dev/vg/"+.),lv_active:$state})}]}';;
            vgchange)
                [[ $2 == -ay ]] && printf 'active\n' >"$tmp/matrix-vg-state" || printf 'inactive\n' >"$tmp/matrix-vg-state";;
            *) fail 'unexpected LVM command';;
        esac
    }
    mountpoint(){
        [[ ${@: -1} == "$rootpxe_uefi_firmware_dir/efivars" ]] ||
            awk -F'|' -v target="${@: -1}" '$1==target {found=1} END {exit !found}' "$tmp/matrix-mounts"
    }
    findmnt(){
        case ${@: -1} in
            FSTYPE,OPTIONS) printf 'efivarfs rw\n';;
            TARGET) awk -F'|' -v source="$3" '$2==source {print $1}' "$tmp/matrix-mounts";;
            OPTIONS) awk -F'|' -v target="$3" '$1==target {print $3}' "$tmp/matrix-mounts";;
            *) fail 'unexpected mount query';;
        esac
    }
    mount(){
        local target=${@: -1} device=${@: -2:1} fixture options=$4
        case $device in
            /dev/Ap1) fixture="$tmp/esp-Ap1";;
            /dev/Ap2|/dev/vg/root) fixture="$tmp/matrix-root";;
            /dev/vg/usr) fixture="$tmp/matrix-usr";;
            *) fail 'mount escaped authorized targets';;
        esac
        [[ ,$options, == *,ro,* ]] || fail 'metadata mounted writable'
        cp -a "$fixture/." "$target/"
        printf '%s|%s|%s\n' "$target" "$device" "$options" >>"$tmp/matrix-mounts"
    }
    umount(){
        [[ $1 == /tmp/rootpxe-uefi.*/* || $1 == /tmp/rootpxe-cloud-mount.*/* ]] || fail 'unexpected metadata unmount'
        find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        awk -F'|' -v target="$1" '$1!=target' "$tmp/matrix-mounts" >"$tmp/matrix-mounts.next"
        mv "$tmp/matrix-mounts.next" "$tmp/matrix-mounts"
    }
    matrix_cases=0
    for system in centos6 centos7 rocky ubuntu debian; do
        system_cases=0
        states='new vendor custom inactive unlisted create readback order delete'
        case $system in
            centos6) expected=Linux; loader=/EFI/redhat/grub.efi; states='new vendor managed';;
            centos7) expected='CentOS Linux'; loader=/EFI/centos/shimx64.efi;;
            rocky) expected='Rocky Linux'; loader=/EFI/rocky/shimx64.efi;;
            ubuntu) expected=Ubuntu; loader=/EFI/ubuntu/shimx64.efi;;
            debian) expected='Debian GNU/Linux'; loader=/EFI/debian/shimx64.efi;;
        esac
        for topology in partition lvm_usr; do
            rm -rf "$tmp/matrix-root" "$tmp/matrix-usr"
            mkdir -p "$tmp/matrix-root/etc" "$tmp/matrix-root/sbin" "$tmp/matrix-root/usr" "$tmp/matrix-usr/lib/systemd"
            printf 'root:x:0:0:root:/root:/bin/sh\n' >"$tmp/matrix-root/etc/passwd"
            printf '#!/bin/sh\nexit 99\n' >"$tmp/matrix-usr/lib/systemd/systemd"
            chmod 755 "$tmp/matrix-usr/lib/systemd/systemd"
            if [[ $topology == partition ]]; then
                cp "$tmp/matrix-usr/lib/systemd/systemd" "$tmp/matrix-root/sbin/init"
                metadata="$tmp/matrix-root/etc"
            else
                ln -s /usr/lib/systemd/systemd "$tmp/matrix-root/sbin/init"
                printf '/dev/vg/usr /usr xfs defaults 0 0\n' >"$tmp/matrix-root/etc/fstab"
                ln -s /usr/lib/os-release "$tmp/matrix-root/etc/os-release"
                metadata="$tmp/matrix-usr/lib"
            fi
            if [[ $system == centos6 ]]; then
                printf 'CentOS release 6.10 (Final)\n' >"$tmp/matrix-root/etc/centos-release"
            else printf 'NAME="%s"\nPRETTY_NAME="unused version"\n' "$expected" >"$metadata/os-release"; fi
            for state in $states; do
                flow_reset
                if [[ $system == debian ]]; then
                    printf 'NAME="Debian GNU/Linux"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\n' >"$metadata/os-release"
                fi
                : >"$tmp/matrix-mounts"
                printf 'inactive\n' >"$tmp/matrix-vg-state"
                rm -rf "$tmp/esp-Ap1"
                pe "$tmp/esp-Ap1$loader"
                [[ $system == centos6 ]] || pe "$tmp/esp-Ap1${loader%/*}/grubx64.efi"
                if [[ $system != centos6 ]]; then
                    mkdir -p "$tmp/esp-Ap1/EFI/BOOT"
                    cp "$tmp/esp-Ap1$loader" "$tmp/esp-Ap1/EFI/BOOT/BOOTX64.EFI"
                    cp "$tmp/esp-Ap1${loader%/*}/grubx64.efi" "$tmp/esp-Ap1/EFI/BOOT/grubx64.efi"
                fi
                identity='GPT,d14174d8-a0ba-48c6-a463-e3537e91e6d4'
                if [[ $topology == lvm_usr ]]; then
                    sed -i 's/"gpt"/"dos"/;s/11111111-2222-3333-4444-555555555555/0xa1b2c3d4/;s/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ef/' "$tmp/table-A.json"
                    identity='MBR,0xa1b2c3d4'
                fi
                if [[ $state != new ]]; then
                    label=$expected; active='*'
                    case $state in
                        vendor)
                            case $system in centos6) label=CentOS;; debian) label=debian;; esac;;
                        custom) label='Custom operating system';;
                        inactive) active='';;
                        managed|create|readback|order|delete) label='RootPXE OS';;
                    esac
                    printf 'Boot0003%s %s\tHD(1,%s,0x800,0x64000)/File(%s)\n' "$active" "$label" "$identity" "$loader" >>"$tmp/nvram"
                    [[ $state == unlisted ]] || sed -i 's/0001,0000,0002/0001,0003,0000,0002/' "$tmp/nvram"
                fi
                case $state in
                    create|readback|order|delete)
                        nvfail=$state
                        if rootpxe_uefi_ensure_boot_for_targets /dev/A; then fail "$system/$topology/$state did not stop"; fi
                        grep -q '^Boot0003' "$tmp/nvram" || fail 'migration failure removed old entry'
                        nvfail='';;
                esac
                rootpxe_uefi_ensure_boot_for_targets /dev/A || fail "$system/$topology/$state: ${rootpxe_uefi_error:-unknown}"
                [[ ! -s $tmp/matrix-mounts && -z $uefi_name_work ]] || fail 'metadata mounts leaked'
                [[ $(<"$tmp/matrix-vg-state") == inactive ]] || fail 'owned VG leaked'
                id=0003
                case $state in create|readback|order|delete) id=0004;; esac
                [[ $state != custom ]] || expected_label='Custom operating system'
                [[ $state == custom ]] || expected_label=$expected
                [[ $system != debian || $state != vendor ]] || expected_label=debian
                [[ $system != centos6 || $state != vendor ]] || expected_label=CentOS
                [[ $state != managed ]] || expected_label='RootPXE OS'
                grep -Fq "$(printf 'Boot%s* %s\t' "$id" "$expected_label")" "$tmp/nvram" || fail "$system/$topology/$state lost target name"
                [[ $(grep -c '^Boot[[:xdigit:]]\{4\}' "$tmp/nvram") == 4 ]] || fail 'registration duplicated an existing target'
                if [[ $state == vendor || $state == custom || $state == inactive || $state == unlisted || $state == managed ]]; then
                    ! grep -q '^create$' "$tmp/nv-events" || fail 'matching target recreated by label'
                fi
                snapshot=$(sha256sum "$tmp/nvram")
                if [[ $system == debian ]]; then
                    printf 'NAME="Debian GNU/Linux"\nPRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nID=debian\n' >"$metadata/os-release"
                fi
                rootpxe_uefi_ensure_boot_for_targets /dev/A || fail 'repeat registration failed'
                [[ $(sha256sum "$tmp/nvram") == "$snapshot" ]] || fail 'repeat registration mutated entries'
                [[ $system != debian ]] || printf 'DEBIAN_MATRIX topology=%s state=%s NAME="%s" repeat=unchanged\n' "$topology" "$state" "$expected"
                matrix_cases=$((matrix_cases + 1))
                system_cases=$((system_cases + 1))
            done
        done
        printf 'SYSTEM_MATRIX system=%s cases=%s\n' "$system" "$system_cases"
    done
    printf 'SYSTEM_MATRIX_CASES=%s\n' "$matrix_cases"
)
pass five_system_metadata_registration_chain

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
        uefi_name_work=$(mktemp -d /tmp/rootpxe-cloud-mount.XXXXXX)
        mkdir "$uefi_name_work/root"
        printf '%s\n' "$uefi_name_work" >"$tmp/name-work-$signal"
        uefi_name_mounts=("$uefi_name_work/root") uefi_name_vg_names=() uefi_name_vg_uuids=() uefi_name_vg_owned=()
        umount(){ printf '%s\n' "$1" >>"$tmp/cleanup-events-$signal"; }
        eval "$cleanup_code"
        if [[ $signal == EXIT ]]; then exit 0; else kill -s "$signal" "$BASHPID"; fi
    )
    result=$?
    set -e
    case $signal:$result in EXIT:0|INT:130|TERM:143) ;; *) fail "cleanup hook $signal exit=$result";; esac
    [[ $(wc -l <"$tmp/cleanup-events-$signal") == 3 && ! -e $tmp/cleanup-$signal && ! -e $(cat "$tmp/name-work-$signal") ]] || fail "$signal cleanup missed or repeated owned mounts"
    pass "download_${signal}_owned_cleanup"
done
uefi_work='' uefi_own_esp=no uefi_own_vars=no
rootpxe_uefi_cleanup; rootpxe_uefi_cleanup
pass empty_cleanup_idempotent
printf 'UEFI_CASES=%s\n' "$cases"
