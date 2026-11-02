#!/bin/bash
# 仅配置目标加载器入口。PE检查不证明签名信任或目标系统能成功启动。
rootpxe_uefi_fail() { rootpxe_uefi_error="$1"; return 1; }
rootpxe_uefi_le() {
    local file=$1 offset=$2 count=$3 bytes i value=0
    bytes=$(od -An -v -tu1 -j "$offset" -N "$count" -- "$file" 2>/dev/null) || return 1
    local -a octets
    read -r -a octets <<<"$bytes"
    [[ ${#octets[@]} == "$count" ]] || return 1
    for ((i=0;i<count;i++)); do value=$((value | octets[i] << (8*i))); done
    printf '%s\n' "$value"
}
rootpxe_uefi_pe() {
    local file=$1 arch=$2 bytes offset machine optional magic subsystem sections start i name linux=no osrel=no
    rootpxe_uefi_pe_uki=no
    [[ -f $file && ! -L $file ]] || return 1
    bytes=$(stat -c %s -- "$file") || return 1
    (( bytes >= 64 )) || return 1
    [[ $(rootpxe_uefi_le "$file" 0 2) == 23117 ]] || return 1
    offset=$(rootpxe_uefi_le "$file" 60 4) || return 1
    (( offset >= 64 && offset + 24 <= bytes )) || return 1
    [[ $(rootpxe_uefi_le "$file" "$offset" 4) == 17744 ]] || return 1
    machine=$(rootpxe_uefi_le "$file" "$((offset+4))" 2) || return 1
    optional=$(rootpxe_uefi_le "$file" "$((offset+20))" 2) || return 1
    (( optional >= 70 && offset + 24 + optional <= bytes )) || return 1
    magic=$(rootpxe_uefi_le "$file" "$((offset+24))" 2) || return 1
    case $machine:$magic in 332:267|34404:523|43620:523) ;; *) return 1;; esac
    subsystem=$(rootpxe_uefi_le "$file" "$((offset+24+68))" 2) || return 1
    [[ $subsystem == 10 ]] || return 1
    case $arch:$machine in i386:332|amd64:34404|arm64:43620) ;; *) return 2;; esac
    # 只有直接 UKI 候选需要辨认这些节；不执行 EFI 或检查整个 OS 配置。
    if [[ ${file,,} == */efi/linux/*.efi ]]; then
        sections=$(rootpxe_uefi_le "$file" "$((offset+6))" 2) || return 1
        start=$((offset+24+optional))
        (( sections > 0 && start + sections*40 <= bytes )) || return 1
        for ((i=0;i<sections;i++)); do
            name=$(od -An -v -tx1 -j "$((start+i*40))" -N 8 -- "$file" 2>/dev/null) || return 1
            name=${name//[[:space:]]/}
            [[ $name != 2e6c696e75780000 ]] || linux=yes
            [[ $name != 2e6f7372656c0000 ]] || osrel=yes
            [[ $linux != yes || $osrel != yes ]] || { rootpxe_uefi_pe_uki=yes; break; }
        done
    fi
}
rootpxe_uefi_select_loader() {
    local root=$1 arch=$2 file path lower base group rank rc seen=no invalid=no wrong_arch=no
    local -a uki=() fallback=() candidates=()
    local -A managers=() ranks=() ambiguous=()
    rootpxe_uefi_loader_path='' rootpxe_uefi_loader_kind=''
    while IFS= read -r -d '' file; do
        path=${file#"$root"}; lower=${path,,}; base=${lower##*/}; rank=0; group=''
        [[ $lower == /efi/* ]] || continue
        case $base in mm*.efi|mokmanager.efi|fwupd*.efi|fbx64.efi|fbia32.efi|fbaa64.efi|fallback.efi|memtest*.efi) continue;; esac
        seen=yes
        if rootpxe_uefi_pe "$file" "$arch"; then :; else rc=$?; [[ $rc != 2 ]] && invalid=yes || wrong_arch=yes; continue; fi
        if [[ $lower == /efi/boot/bootx64.efi || $lower == /efi/boot/bootia32.efi || $lower == /efi/boot/bootaa64.efi ]]; then
            fallback+=("$path"); continue
        fi
        case $base in
            shimx64.efi|shimia32.efi|shimaa64.efi) group=${lower%/*}:grub; rank=30;;
            shim.efi) group=${lower%/*}:grub; rank=20;;
            shimx64-centos.efi|shimx64-redhat.efi|shimx64-fedora.efi) group=${lower%/*}:grub; rank=10;;
            grubx64.efi|grubia32.efi|grubaa64.efi) group=${lower%/*}:grub; rank=2;;
            grub.efi) group=${lower%/*}:grub; rank=1;;
            systemd-bootx64.efi|systemd-bootia32.efi|systemd-bootaa64.efi) group=${lower%/*}:systemd; rank=1;;
            *) [[ $rootpxe_uefi_pe_uki != yes ]] || uki+=("$path");;
        esac
        [[ -n $group ]] || continue
        if (( rank > ${ranks[$group]:-0} )); then managers[$group]=$path; ranks[$group]=$rank; ambiguous[$group]=no
        elif (( rank == ${ranks[$group]:-0} )) && [[ ${managers[$group]} != "$path" ]]; then ambiguous[$group]=yes; fi
    done < <(find "$root" -maxdepth 4 -type f -iname '*.efi' -print0)
    for group in "${!managers[@]}"; do
        [[ ${ambiguous[$group]} != yes ]] || { rootpxe_uefi_fail uefi_boot_loader_ambiguous; return 1; }
        candidates+=("${managers[$group]}")
    done
    rootpxe_uefi_loader_kind=manager
    if [[ ${#candidates[@]} == 0 && ${#uki[@]} != 0 ]]; then candidates=("${uki[@]}"); rootpxe_uefi_loader_kind=uki; fi
    if [[ ${#candidates[@]} == 0 && ${#fallback[@]} != 0 ]]; then candidates=("${fallback[@]}"); rootpxe_uefi_loader_kind=fallback; fi
    if [[ ${#candidates[@]} == 0 ]]; then
        if [[ $wrong_arch == yes ]]; then rootpxe_uefi_fail uefi_boot_loader_arch_mismatch
        elif [[ $invalid == yes ]]; then rootpxe_uefi_fail uefi_boot_loader_invalid
        elif [[ $seen == yes ]]; then rootpxe_uefi_fail uefi_boot_loader_unknown
        else rootpxe_uefi_fail uefi_boot_loader_missing; fi
        return 1
    fi
    [[ ${#candidates[@]} == 1 ]] || { rootpxe_uefi_fail uefi_boot_loader_ambiguous; return 1; }
    rootpxe_uefi_loader_path=${candidates[0]}
}
rootpxe_uefi_path_key() {
    local path=${1,,}
    path=${path//\//\\}
    while [[ $path == \\* ]]; do path=${path#\\}; done
    printf '\\%s\n' "$path"
}
rootpxe_uefi_read_entries() {
    local text line id active node number kind signature start size suffix path classification order='' count=0
    text=$(LC_ALL=C efibootmgr -v 2>"$uefi_work/efibootmgr.stderr") || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
    # efibootmgr 可在部分 Boot 变量读取失败时仍返回0。此时不能据部分列表新建条目。
    [[ ! -s $uefi_work/efibootmgr.stderr ]] || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
    uefi_entries=(); uefi_order=''
    while IFS= read -r line; do
        if [[ $line == BootOrder:* ]]; then
            order=${line#BootOrder:}; order=${order//[[:space:]]/}; order=${order^^}
            [[ -z $order || $order =~ ^[0-9A-F]{4}(,[0-9A-F]{4})*$ ]] || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
            count=$((count+1)); uefi_order=$order
        elif [[ $line =~ ^Boot([[:xdigit:]]{4})(\*)?[[:space:]] ]]; then
            id=${BASH_REMATCH[1]^^}; active=no; [[ ${BASH_REMATCH[2]:-} != '*' ]] || active=yes
            if [[ $line =~ HD\(([0-9]+),(GPT|MBR),([^,]+),([^,]+),([^\)]+)\) ]]; then
                node=${BASH_REMATCH[0]}; number=${BASH_REMATCH[1]}; kind=${BASH_REMATCH[2]}; signature=${BASH_REMATCH[3],,}; start=${BASH_REMATCH[4]}; size=${BASH_REMATCH[5]}
                [[ $start =~ ^(0x[[:xdigit:]]+|[0-9]+)$ && $size =~ ^(0x[[:xdigit:]]+|[0-9]+)$ ]] || continue
                suffix=${line#*"$node"}
                path=''
                if [[ ${suffix,,} == /file\(* ]]; then
                    path=${suffix:6}
                    if [[ $path == *')'* ]]; then path=${path%%\)*}; else path=''; fi
                elif [[ $suffix == /* || $suffix == \\* ]]; then path=$suffix
                fi
                [[ -z $path ]] || path=$(rootpxe_uefi_path_key "$path")
                if [[ $kind == MBR ]]; then
                    [[ $signature =~ ^0x[[:xdigit:]]{1,8}$ ]] || continue
                    printf -v signature '0x%08x' "$((16#${signature#0x}))"
                fi
                classification=local
                uefi_entries+=("$id|$active|$number|$kind|$signature|$((start))|$((size))|$path|$classification")
            elif [[ $line == *'MAC('* || $line == *'IPv4('* || $line == *'IPv6('* || $line == *'Uri('* ]]; then
                uefi_entries+=("$id|$active|||||||network")
            elif [[ $line == *'HD('* || $line == *'NVMe('* || $line == *'Sata('* || $line == *'Ata('* ]]; then
                uefi_entries+=("$id|$active|||||||local")
            else uefi_entries+=("$id|$active|||||||other"); fi
        fi
    done <<<"$text"
    (( count <= 1 )) || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
}
rootpxe_uefi_write_ready() {
    if [[ $uefi_own_vars == yes ]]; then
        mount -o remount,rw "$uefi_vars" || { rootpxe_uefi_fail uefi_boot_variables_readonly; return 1; }
    else
        [[ ,$uefi_vars_options, == *,rw,* ]] || { rootpxe_uefi_fail uefi_boot_variables_readonly; return 1; }
    fi
}
rootpxe_uefi_find_entry() {
    local entry id active number kind signature start size path classification
    uefi_match='' uefi_match_active=no
    for entry in "${uefi_entries[@]}"; do
        IFS='|' read -r id active number kind signature start size path classification <<<"$entry"
        [[ $number == "$uefi_number" && $kind == "$uefi_kind" && $signature == "$uefi_signature" && $path == "$uefi_path_key" ]] || continue
        [[ $kind != MBR || ( $start == "$uefi_start" && $size == "$uefi_size" ) ]] || continue
        if [[ -z $uefi_match || ( $active == yes && ,$uefi_order, == *,$id,* ) ]]; then uefi_match=$id; uefi_match_active=$active; fi
        [[ $active != yes || ,$uefi_order, != *,$id,* ]] || break
    done
}
rootpxe_uefi_register_selected() {
    local original_order=$uefi_order entry id active number kind signature start size path classification item desired='' inserted=no anchor='' last_network='' listed=no
    local -a order_items=()
    local -A types=()
    for entry in "${uefi_entries[@]}"; do IFS='|' read -r id active number kind signature start size path classification <<<"$entry"; types[$id]=$classification; done
    rootpxe_uefi_find_entry
    IFS=, read -r -a order_items <<<"$original_order"
    for item in "${order_items[@]}"; do
        [[ $item != "$uefi_match" ]] || { listed=yes; break; }
    done
    if [[ $listed == yes && $uefi_match_active == yes ]]; then return 0; fi
    rootpxe_uefi_write_ready || return 1
    if [[ -z $uefi_match ]]; then
        # -C 不抢占 BootOrder 首位；不删除相同 label 的其它磁盘条目。
        LC_ALL=C efibootmgr -C -d "$uefi_disk" -p "$uefi_number" -L 'RootPXE OS' -l "$uefi_path_key" >/dev/null 2>&1 || { rootpxe_uefi_fail uefi_boot_entry_create_failed; return 1; }
        rootpxe_uefi_read_entries || return 1
        rootpxe_uefi_find_entry
        [[ -n $uefi_match ]] || { rootpxe_uefi_fail uefi_boot_entry_readback_failed; return 1; }
    fi
    if [[ $uefi_match_active != yes ]]; then
        LC_ALL=C efibootmgr -b "$uefi_match" -a >/dev/null 2>&1 || { rootpxe_uefi_fail uefi_boot_entry_activate_failed; return 1; }
    fi
    if [[ $listed == no ]]; then
        for item in "${order_items[@]}"; do
            [[ $item != "$uefi_match" ]] || continue
            if [[ ${types[$item]:-} == local && -z $anchor ]]; then anchor=$item; fi
            [[ ${types[$item]:-} != network ]] || last_network=$item
        done
        if [[ -z $anchor && -z $last_network ]]; then desired=$uefi_match; inserted=yes; fi
        for item in "${order_items[@]}"; do
            [[ $item != "$uefi_match" ]] || continue
            if [[ -n $anchor && $item == "$anchor" ]]; then desired+="${desired:+,}$uefi_match"; inserted=yes; fi
            desired+="${desired:+,}$item"
            if [[ -z $anchor && -n $last_network && $item == "$last_network" ]]; then desired+=",$uefi_match"; inserted=yes; fi
        done
        [[ $inserted == yes ]] || desired+="${desired:+,}$uefi_match"
    else desired=$original_order; fi
    if [[ $uefi_order != "$desired" ]]; then
        LC_ALL=C efibootmgr -o "$desired" >/dev/null 2>&1 || { rootpxe_uefi_fail uefi_boot_order_update_failed; return 1; }
    fi
    rootpxe_uefi_read_entries || return 1
    rootpxe_uefi_find_entry
    [[ -n $uefi_match && $uefi_match_active == yes && $uefi_order == "$desired" ]] || { rootpxe_uefi_fail uefi_boot_entry_readback_failed; return 1; }
}
rootpxe_uefi_process_targets() {
    local bits hardware disk table part number start size type uuid label signature candidate rc best_error=uefi_boot_esp_missing
    local -a candidates=() fallback=()
    local -a uefi_entries=()
    local uefi_order='' uefi_match='' uefi_match_active=no
    [[ -d $uefi_firmware ]] || { rootpxe_uefi_fail uefi_boot_mode_mismatch; return 1; }
    bits=$(cat "$uefi_firmware/fw_platform_size" 2>/dev/null) || { rootpxe_uefi_fail uefi_boot_firmware_arch_mismatch; return 1; }
    hardware=$(uname -m) || return 1
    case $imageArch:$hardware:$bits in amd64:x86_64:64|i386:x86_64:32|i386:i?86:32|arm64:aarch64:64) ;; *) rootpxe_uefi_fail uefi_boot_firmware_arch_mismatch; return 1;; esac
    command -v efibootmgr >/dev/null 2>&1 || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
    if mountpoint -q "$uefi_vars"; then
        IFS=' ' read -r type uefi_vars_options < <(findmnt -rn -M "$uefi_vars" -o FSTYPE,OPTIONS)
        [[ $type == efivarfs ]] || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
    else
        mount -t efivarfs -o ro efivarfs "$uefi_vars" || { rootpxe_uefi_fail uefi_boot_variables_unavailable; return 1; }
        uefi_own_vars=yes
    fi
    rootpxe_uefi_read_entries || return 1
    for disk in "$@"; do
        rootpxe_verify_disk_permit_binding "$disk" deploy_write || { rootpxe_uefi_fail uefi_boot_target_binding_changed; return 1; }
        table=$(sfdisk --json "$disk" 2>/dev/null) || { rootpxe_uefi_fail uefi_boot_partition_metadata_invalid; return 1; }
        jq -e '.partitiontable | (.label == "gpt" or .label == "dos") and .unit == "sectors" and (.partitions|type == "array") and all(.partitions[]; (.node|type == "string" and startswith("/dev/")) and (.start|type == "number" and . >= 0 and floor == .) and (.size|type == "number" and . > 0 and floor == .) and (.type|type == "string"))' <<<"$table" >/dev/null || { rootpxe_uefi_fail uefi_boot_partition_metadata_invalid; return 1; }
        while IFS='|' read -r part start size type uuid label signature; do
            case $label:$type in gpt:c12a7328-f81f-11d2-ba4b-00a0c93ec93b|dos:ef|dos:0xef) ;; *) continue;; esac
            number=${part##*[!0-9]}
            [[ $number =~ ^[1-9][0-9]*$ ]] || { rootpxe_uefi_fail uefi_boot_partition_metadata_invalid; return 1; }
            if [[ $label == gpt ]]; then
                [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { rootpxe_uefi_fail uefi_boot_partition_metadata_invalid; return 1; }
                label=GPT; signature=${uuid,,}
            else
                [[ $signature =~ ^0x[[:xdigit:]]{1,8}$ ]] || { rootpxe_uefi_fail uefi_boot_partition_metadata_invalid; return 1; }
                label=MBR; printf -v signature '0x%08x' "$((16#${signature#0x}))"
            fi
            [[ $(blkid -s TYPE -o value "$part" 2>/dev/null) == vfat ]] || { rootpxe_uefi_fail uefi_boot_esp_filesystem_unsupported; return 1; }
            mount -t vfat -o ro,nosuid,nodev,noexec "$part" "$uefi_work/esp" || { rootpxe_uefi_fail uefi_boot_esp_mount_failed; return 1; }
            uefi_own_esp=yes
            if rootpxe_uefi_select_loader "$uefi_work/esp" "$imageArch"; then
                candidate="$disk|$number|$label|$signature|$start|$size|$rootpxe_uefi_loader_path"
                if [[ $rootpxe_uefi_loader_kind == fallback ]]; then fallback+=("$candidate"); else candidates+=("$candidate"); fi
            else
                rc=$?; best_error=$rootpxe_uefi_error
                [[ $best_error != uefi_boot_loader_ambiguous ]] || return "$rc"
            fi
            umount "$uefi_work/esp" || { rootpxe_uefi_fail uefi_boot_cleanup_failed; return 1; }
            uefi_own_esp=no
        done < <(jq -r '.partitiontable as $t | $t.partitions[] | [.node, (.start|tostring), (.size|tostring), (.type|ascii_downcase), (.uuid//"-"), $t.label, ($t.id//"-")]|join("|")' <<<"$table")
    done
    [[ ${#candidates[@]} != 0 ]] || candidates=("${fallback[@]}")
    if [[ ${#candidates[@]} == 0 ]]; then rootpxe_uefi_fail "$best_error"; return 1; fi
    [[ ${#candidates[@]} == 1 ]] || { rootpxe_uefi_fail uefi_boot_loader_ambiguous; return 1; }
    local uefi_disk uefi_number uefi_kind uefi_signature uefi_start uefi_size uefi_path uefi_path_key
    IFS='|' read -r uefi_disk uefi_number uefi_kind uefi_signature uefi_start uefi_size uefi_path <<<"${candidates[0]}"
    uefi_path_key=$(rootpxe_uefi_path_key "$uefi_path")
    rootpxe_verify_disk_permit_binding "$uefi_disk" deploy_write || { rootpxe_uefi_fail uefi_boot_target_binding_changed; return 1; }
    rootpxe_uefi_register_selected
}
# 状态仅由本库创建资源时设置，供正常收尾与下载退出共用。
rootpxe_uefi_cleanup() {
    local result=0
    [[ -n ${uefi_work:-} ]] || return 0
    if [[ ${uefi_own_esp:-no} == yes ]]; then
        if umount "$uefi_work/esp"; then uefi_own_esp=no; else result=1; fi
    fi
    if [[ ${uefi_own_vars:-no} == yes ]]; then
        if umount "$uefi_vars"; then uefi_own_vars=no; else result=1; fi
    fi
    if [[ ${uefi_own_esp:-no} != yes && ${uefi_own_vars:-no} != yes ]]; then
        rm -f -- "$uefi_work/efibootmgr.stderr"
        if rmdir "$uefi_work/esp" "$uefi_work"; then uefi_work=''; else result=1; fi
    fi
    [[ $result == 0 ]] || rootpxe_uefi_error=uefi_boot_cleanup_failed
    return "$result"
}
rootpxe_uefi_ensure_boot_for_targets() {
    [[ ${taskType:-} == deploy && ${osid:-} == 50 ]] || return 0
    rootpxe_uefi_error=''
    [[ ${imageBootMode:-} != BIOS ]] || return 0
    [[ -n ${imageBootMode:-} && -n ${imageArch:-} ]] || { rootpxe_uefi_fail uefi_boot_metadata_missing; return 1; }
    local result=0
    rootpxe_uefi_cleanup || return 1
    uefi_firmware=${rootpxe_uefi_firmware_dir:-/sys/firmware/efi}
    uefi_vars_options='' uefi_own_vars=no uefi_own_esp=no
    uefi_vars="$uefi_firmware/efivars"
    uefi_work=$(mktemp -d /tmp/rootpxe-uefi.XXXXXX) || { rootpxe_uefi_fail uefi_boot_workspace_failed; return 1; }
    mkdir "$uefi_work/esp" || result=1
    [[ $result != 0 ]] || rootpxe_uefi_process_targets "$@" || result=1
    rootpxe_uefi_cleanup || result=1
    return "$result"
}
rootpxe_prepare_uefi_boot() {
    [[ ${taskType:-} == deploy && ${osid:-} == 50 ]] || return 0
    [[ ${imageBootMode:-} != BIOS ]] || return 0
    rootpxe_stage uefi_boot 'checking UEFI boot entry' || true
    if ! rootpxe_uefi_ensure_boot_for_targets "$@"; then
        local code=UEFI_BOOT_REGISTRATION_FAILED
        [[ $rootpxe_uefi_error != uefi_boot_metadata_missing ]] || code=UEFI_BOOT_METADATA_MISSING
        handleError "PXEOS_STAGE=uefi_boot CODE=$code REASON=${rootpxe_uefi_error:-uefi_boot_variables_unavailable}"
        return 1
    fi
    rootpxe_stage uefi_boot 'UEFI boot entry verified' || true
}
