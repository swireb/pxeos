#!/usr/bin/env bash
# Read-only capture display metadata.  This is deliberately separate from the
# deployable schema: it must never participate in a schema hash or geometry.

rootpxe_display_metadata_safe_mountpoint() {
    [[ $1 == /* ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    # jq rejects invalid UTF-8 while utf8bytelength and this expression match
    # the backend's 4096-byte, no-control-character contract.
    jq -en --arg point "$1" '$point | utf8bytelength <= 4096 and test("^[^\u0000-\u001f\u007f]*$")' >/dev/null
}

rootpxe_display_metadata_part_path() {
    local disk="$1" number="$2"
    [[ $number =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ $disk == *[0-9] ]]; then printf '%sp%s\n' "$disk" "$number"; else printf '%s%s\n' "$disk" "$number"; fi
}

rootpxe_display_metadata_cleanup_mount() {
    local mountpoint="$1"
    mountpoint -q "$mountpoint" 2>/dev/null && ! umount "$mountpoint" >/dev/null 2>&1 && return 2
    rmdir -- "$mountpoint" >/dev/null 2>&1 || return 2
}

rootpxe_display_metadata_append_mount() {
    local identity="$1" point="$2" rows="${rootpxe_display_metadata_mount_rows:-}"
    [[ -n $rows && -f $rows ]] || return 1
    rootpxe_display_metadata_safe_mountpoint "$point" || return 1
    printf '%s\t%s\n' "$identity" "$point" >>"$rows"
}

rootpxe_display_metadata_unescape_fstab_field() {
    local value="$1" decoded
    decoded=$(printf '%b' "${value//\\040/\\040}") || return 1
    [[ $decoded != *$'\n'* && $decoded != *$'\r'* && $decoded != *$'\t'* ]] || return 1
    printf '%s\n' "$decoded"
}

# Resolve fstab only against the capture source devices passed by the caller.
# It never follows a UUID/LABEL to an arbitrary PE environment disk.
rootpxe_display_metadata_fstab_identity() {
    local spec="$1" identities="$2" identity device value actual count=0 result="" IFS=$' \t\n'
    case "$spec" in
        UUID=*) value=${spec#UUID=}; for identity in $identities; do device=${identity#*|}; actual=$(blkid -s UUID -o value "$device" 2>/dev/null | tr -d '\r\n'); [[ $actual == "$value" ]] && { result=${identity%%|*}; count=$((count + 1)); }; done ;;
        PARTUUID=*) value=${spec#PARTUUID=}; for identity in $identities; do device=${identity#*|}; actual=$(blkid -s PARTUUID -o value "$device" 2>/dev/null | tr -d '\r\n'); [[ ${actual,,} == ${value,,} ]] && { result=${identity%%|*}; count=$((count + 1)); }; done ;;
        LABEL=*) value=${spec#LABEL=}; for identity in $identities; do device=${identity#*|}; actual=$(blkid -s LABEL -o value "$device" 2>/dev/null | tr -d '\r\n'); [[ $actual == "$value" ]] && { result=${identity%%|*}; count=$((count + 1)); }; done ;;
        /dev/*) for identity in $identities; do device=${identity#*|}; [[ $(readlink -f "$device" 2>/dev/null) == $(readlink -f "$spec" 2>/dev/null) ]] && { result=${identity%%|*}; count=$((count + 1)); }; done ;;
        *) return 1 ;;
    esac
    [[ $count -eq 1 ]] && printf '%s\n' "$result"
}

rootpxe_display_metadata_collect_fstab() {
    local device="$1" fstype="$2" identities="$3" source_identity="$4" mountpoint spec path identity options rows root_identity="" root_count=0
    mountpoint=$(mktemp -d /tmp/rootpxe-display-mount.XXXXXX) || return 1
    options=$(rootpxe_linux_mount_options ro "$fstype") || { rmdir -- "$mountpoint"; return 1; }
    if ! mount -t "$fstype" -o "$options" "$device" "$mountpoint" >/tmp/rootpxe-display-mount-output 2>&1; then
        rmdir -- "$mountpoint" || return 2
        return 1
    fi
    rows=$(mktemp /tmp/rootpxe-display-fstab.XXXXXX) || { rootpxe_display_metadata_cleanup_mount "$mountpoint"; return 2; }
    chmod 600 "$rows" || { rm -f -- "$rows"; rootpxe_display_metadata_cleanup_mount "$mountpoint"; return 2; }
    if [[ -d $mountpoint/etc && ! -L $mountpoint/etc && -f $mountpoint/etc/fstab && ! -L $mountpoint/etc/fstab ]]; then
        while IFS=$'\t' read -r spec path; do
            spec=$(rootpxe_display_metadata_unescape_fstab_field "$spec") || continue
            path=$(rootpxe_display_metadata_unescape_fstab_field "$path") || continue
            rootpxe_display_metadata_safe_mountpoint "$path" || continue
            identity=$(rootpxe_display_metadata_fstab_identity "$spec" "$identities") || continue
            if [[ $path == / ]]; then root_identity=$identity; root_count=$((root_count + 1)); fi
            printf '%s\t%s\n' "$identity" "$path" >>"$rows" || { rm -f -- "$rows"; rootpxe_display_metadata_cleanup_mount "$mountpoint"; return 2; }
        done < <(awk 'NF >= 2 && $1 !~ /^#/ { sub(/[[:space:]]*#.*/, ""); if (NF >= 2) print $1 "\t" $2 }' "$mountpoint/etc/fstab")
    fi
    if [[ $root_count -eq 1 && $root_identity == "$source_identity" ]]; then
        rootpxe_display_metadata_root_candidates+=" $source_identity"
        while IFS=$'\t' read -r identity path; do printf '%s\t%s\t%s\n' "$source_identity" "$identity" "$path" >>"${rootpxe_display_metadata_mount_rows:-/dev/null}" || { rm -f -- "$rows"; rootpxe_display_metadata_cleanup_mount "$mountpoint"; return 2; }; done <"$rows"
    fi
    rm -f -- "$rows"
    rootpxe_display_metadata_cleanup_mount "$mountpoint"
}

rootpxe_display_metadata_begin() {
    local primary_disk="$1" all_disks="$2" image_type="$3" disk disk_number=1 part number fs identities="" rows
    command -v jq >/dev/null 2>&1 || return 1
    rows=$(mktemp /tmp/rootpxe-display-mount-rows.XXXXXX) || return 1
    chmod 600 "$rows" || { rm -f -- "$rows"; return 1; }
    if [[ $image_type == mpa ]]; then
        for disk in $all_disks; do
            if declare -F rootpxe_verify_disk_permit_binding >/dev/null 2>&1; then rootpxe_verify_disk_permit_binding "$disk" capture_read_write || { rm -f -- "$rows"; return 1; }; fi
            getPartitions "$disk"
            for part in $parts; do number=${part##*[!0-9]}; identities+=" p:${disk_number}:${number}|${part}"; done
            disk_number=$((disk_number + 1))
        done
    else
        if declare -F rootpxe_verify_disk_permit_binding >/dev/null 2>&1; then rootpxe_verify_disk_permit_binding "$primary_disk" capture_read_write || { rm -f -- "$rows"; return 1; }; fi
        getPartitions "$primary_disk"
        for part in $parts; do number=${part##*[!0-9]}; identities+=" p:1:${number}|${part}"; done
    fi
    rootpxe_display_metadata_disks=$([[ $image_type == mpa ]] && printf '%s\n' "$all_disks" || printf '%s\n' "$primary_disk")
    export rootpxe_display_metadata_disks
    rootpxe_display_metadata_identities="$identities"
    export rootpxe_display_metadata_identities
    rootpxe_display_metadata_mount_rows="$rows"; rootpxe_display_metadata_root_candidates=""
    export rootpxe_display_metadata_mount_rows
    for identity in $identities; do
        part=${identity#*|}; fs=$(blkid -s TYPE -o value "$part" 2>/dev/null | tr -d '\r\n')
        rootpxe_linux_root_fstype_supported "$fs" || continue
        rootpxe_display_metadata_collect_fstab "$part" "$fs" "$identities" "${identity%%|*}" || {
            local rc=$?; [[ $rc -eq 2 ]] && return 2; continue
        }
    done
    rootpxe_display_metadata_file=$(mktemp /tmp/rootpxe-display-metadata.XXXXXX) || { rm -f -- "$rows"; return 1; }
    chmod 600 "$rootpxe_display_metadata_file" || { rm -f -- "$rows" "$rootpxe_display_metadata_file"; unset rootpxe_display_metadata_file; return 1; }
    set -- $rootpxe_display_metadata_root_candidates
    if [[ $# -eq 1 ]]; then
        jq -n --arg source "$1" --rawfile rows "$rows" '{mountsCollected:true,mounts:($rows|split("\n")|map(select(length>0)|split("\t")|select(.[0] == $source)|{id:.[1],mountPoint:.[2]}))}' >"$rootpxe_display_metadata_file" || { rm -f -- "$rows" "$rootpxe_display_metadata_file"; unset rootpxe_display_metadata_file; return 1; }
    else
        jq -n '{mountsCollected:false,mounts:[]}' >"$rootpxe_display_metadata_file" || { rm -f -- "$rows" "$rootpxe_display_metadata_file"; unset rootpxe_display_metadata_file; return 1; }
    fi
    rm -f -- "$rows"; unset rootpxe_display_metadata_mount_rows
    local drives merged drives_status
    drives=$(mktemp /tmp/rootpxe-display-drive-rows.XXXXXX) || return 1
    chmod 600 "$drives" || { rm -f -- "$drives"; return 1; }
    rootpxe_display_metadata_drive_rows="$drives"; export rootpxe_display_metadata_drive_rows
    if rootpxe_display_metadata_collect_windows "$identities"; then drives_status=0; else drives_status=$?; fi
    [[ $drives_status -eq 0 || $drives_status -eq 1 ]] || { rm -f -- "$drives"; unset rootpxe_display_metadata_drive_rows; return 2; }
    merged=$(mktemp /tmp/rootpxe-display-metadata-drives.XXXXXX) || { rm -f -- "$drives"; unset rootpxe_display_metadata_drive_rows; return 1; }
    jq --argjson collected "$([[ $drives_status -eq 0 ]] && printf true || printf false)" --rawfile rows "$drives" '.drivesCollected=$collected | .drives=($rows|split("\n")|map(select(length>0)|split("\t")|{id:.[0],driveLetter:.[1]}))' "$rootpxe_display_metadata_file" >"$merged" || { rm -f -- "$drives" "$merged"; unset rootpxe_display_metadata_drive_rows; return 1; }
    mv -- "$merged" "$rootpxe_display_metadata_file" || { rm -f -- "$drives" "$merged"; unset rootpxe_display_metadata_drive_rows; return 1; }
    rm -f -- "$drives"; unset rootpxe_display_metadata_drive_rows
    export rootpxe_display_metadata_file
}

rootpxe_display_metadata_merge_inventory() {
    local inventory="$1" metadata="${rootpxe_display_metadata_file:-}" temporary
    [[ -r $inventory ]] || return 1
    [[ -r $metadata ]] || return 0
    temporary=$(mktemp /tmp/rootpxe-partition-inventory-merged.XXXXXX) || return 1
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    jq --slurpfile metadata "$metadata" '
      ($metadata[0].mounts // []) as $mounts |
      ($metadata[0].mountsCollected // false) as $mountsCollected |
      ($metadata[0].drives // []) as $drives |
      ($metadata[0].drivesCollected // false) as $drivesCollected |
      def windowsRole: ((.typeGuid // "") | ascii_downcase) as $type |
        if ($type == "e3c9e316-0b5c-4db8-817d-f92df00215ae") then "msr"
        elif ($type == "de94bba4-06d1-4d40-a16a-bfd50179d6ac" or $type == "0x27" or $type == "27") then "recovery"
        elif ($type == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" or $type == "0xef" or $type == "ef") then "boot"
        else "" end;
      .disks |= map(. as $disk |
        (.partitions |= map(. as $part |
        ("p:" + ($disk.number|tostring) + ":" + ($part.number|tostring)) as $id |
        [$mounts[] | select(.id == $id) | .mountPoint] | unique as $points |
        [$drives[] | select(.id == $id) | .driveLetter] | unique as $letters |
        ($part | windowsRole) as $role |
        $part + (if $mountsCollected then {mountPoints:$points} else {} end) + (if $drivesCollected then {driveLetters:$letters} else {} end) + (if $role != "" then {windowsRole:$role} else {} end))) |
        if $disk.number == 1 and (($metadata[0].lvs // [])|length) > 0 then
          . + {logicalVolumes:[($metadata[0].lvs // [])[] as $lv | ($lv.uuid) as $uuid | [$mounts[] | select(.id == ("l:" + $uuid)) | .mountPoint] | unique as $points | {uuid:$uuid} + (if $mountsCollected then {mountPoints:$points} else {} end)]}
        else . end)' "$inventory" >"$temporary" || { rm -f -- "$temporary"; return 1; }
    mv -- "$temporary" "$inventory"
}

# LVM is activated only inside the existing capture window. Reuse its
# preflight UUID/path facts; never identify an LV by its human-readable name.
rootpxe_display_metadata_collect_lvm() {
    local rows identities="${rootpxe_display_metadata_identities:-}" identity source_identity device lv_name lv_uuid lv_path lv_size fs status temporary source
    [[ -r ${rootpxe_display_metadata_file:-} && -r ${rootpxe_lvm_lv_facts_file:-} ]] || return 0
    rows=$(mktemp /tmp/rootpxe-display-lvm-rows.XXXXXX) || return 1
    chmod 600 "$rows" || { rm -f -- "$rows"; return 1; }
    while IFS='|' read -r lv_name lv_uuid lv_path lv_size; do
        [[ -n $lv_uuid ]] && rootpxe_display_metadata_lv_readable "$lv_path" || { rm -f -- "$rows"; return 1; }
        identities+=" l:${lv_uuid}|${lv_path}"
    done <"$rootpxe_lvm_lv_facts_file"
    rootpxe_display_metadata_mount_rows="$rows"; rootpxe_display_metadata_root_candidates=""
    export rootpxe_display_metadata_mount_rows
    # Once LVM is active, re-read every trusted physical and logical source
    # with the complete identity list. This captures a physical / plus LV
    # /home without retaining the incomplete pre-activation result.
    for identity in $identities; do
        source_identity=${identity%%|*}; device=${identity#*|}
        fs=$(blkid -s TYPE -o value "$device" 2>/dev/null | tr -d '\r\n')
        rootpxe_linux_root_fstype_supported "$fs" || continue
        if rootpxe_display_metadata_collect_fstab "$device" "$fs" "$identities" "$source_identity"; then status=0; else status=$?; fi
        [[ $status -eq 0 || $status -eq 1 ]] || { rm -f -- "$rows"; unset rootpxe_display_metadata_mount_rows; return 2; }
    done
    temporary=$(mktemp /tmp/rootpxe-display-lvm-metadata.XXXXXX) || { rm -f -- "$rows"; unset rootpxe_display_metadata_mount_rows; return 1; }
    chmod 600 "$temporary" || { rm -f -- "$rows" "$temporary"; unset rootpxe_display_metadata_mount_rows; return 1; }
    set -- $rootpxe_display_metadata_root_candidates
    source="${1:-}"
    jq --arg source "$source" --argjson unique_root "$([[ $# -eq 1 ]] && printf true || printf false)" --rawfile rows "$rows" --rawfile lvs "$rootpxe_lvm_lv_facts_file" '
      .mountsCollected = $unique_root |
      .mounts = (if $unique_root then ($rows|split("\n")|map(select(length>0)|split("\t")|select(.[0] == $source)|{id:.[1],mountPoint:.[2]})) else [] end) |
      .lvs = ($lvs|split("\n")|map(select(length>0)|split("|")|{uuid:.[1]}))' "$rootpxe_display_metadata_file" >"$temporary" || { rm -f -- "$rows" "$temporary"; unset rootpxe_display_metadata_mount_rows; return 1; }
    mv -- "$temporary" "$rootpxe_display_metadata_file" || { rm -f -- "$rows" "$temporary"; unset rootpxe_display_metadata_mount_rows; return 1; }
    rm -f -- "$rows"; unset rootpxe_display_metadata_mount_rows
}

rootpxe_display_metadata_lv_readable() { [[ -b $1 && -r $1 ]]; }

rootpxe_display_metadata_reverse_hex_bytes() {
    local value="${1,,}" output="" index
    [[ $value =~ ^([0-9a-f][0-9a-f])+$ ]] || return 1
    for ((index=${#value}-2; index>=0; index-=2)); do output+="${value:index:2}"; done
    printf '%s\n' "$output"
}

rootpxe_display_metadata_guid_le_bytes() {
    local guid="${1,,}" a b c d e
    guid=${guid//-/}
    [[ $guid =~ ^[0-9a-f]{32}$ ]] || return 1
    a=$(rootpxe_display_metadata_reverse_hex_bytes "${guid:0:8}") || return 1
    b=$(rootpxe_display_metadata_reverse_hex_bytes "${guid:8:4}") || return 1
    c=$(rootpxe_display_metadata_reverse_hex_bytes "${guid:12:4}") || return 1
    d=${guid:16:4}; e=${guid:20:12}
    printf '%s%s%s%s%s\n' "$a" "$b" "$c" "$d" "$e"
}

rootpxe_display_metadata_mbr_volume_id() {
    local disk="$1" part="$2" label signature start logical offset offset_hex signature_le offset_le
    label=$(sfdisk -d "$disk" 2>/dev/null) || return 1
    signature=$(awk '/^label-id:/{print $2; exit}' <<<"$label")
    signature=${signature#0x}; signature=${signature,,}
    [[ $signature =~ ^[0-9a-f]{8}$ ]] || return 1
    # Linux exposes partition start in fixed 512-byte sectors, including on
    # 4Kn devices; multiplying by the disk logical sector size is incorrect.
    start=$(cat "/sys/class/block/${part##*/}/start" 2>/dev/null) || return 1
    [[ $start =~ ^[0-9]+$ ]] || return 1
    offset=$((start * 512))
    (( offset >= 0 )) || return 1
    printf -v offset_hex '%016x' "$offset" || return 1
    signature_le=$(rootpxe_display_metadata_reverse_hex_bytes "$signature") || return 1
    offset_le=$(rootpxe_display_metadata_reverse_hex_bytes "$offset_hex") || return 1
    printf '%s%s\n' "$signature_le" "$offset_le"
}

rootpxe_display_metadata_windows_hive() {
    local mountpoint="$1" windows system32 config hive
    windows=$(find -P "$mountpoint" -mindepth 1 -maxdepth 1 -type d -iname windows -print -quit 2>/dev/null) || return 1
    [[ -n $windows && ! -L $windows ]] || return 1
    system32=$(find -P "$windows" -mindepth 1 -maxdepth 1 -type d -iname system32 -print -quit 2>/dev/null) || return 1
    [[ -n $system32 && ! -L $system32 ]] || return 1
    config=$(find -P "$system32" -mindepth 1 -maxdepth 1 -type d -iname config -print -quit 2>/dev/null) || return 1
    [[ -n $config && ! -L $config ]] || return 1
    hive=$(find -P "$config" -mindepth 1 -maxdepth 1 -type f -iname system -print -quit 2>/dev/null) || return 1
    [[ -n $hive && ! -L $hive ]] || return 1
    printf '%s\n' "$hive"
}

rootpxe_display_metadata_collect_windows() {
    local identities="$1" identity device fs mountpoint candidate="" candidates=0 hive export_file parsed drive volume id matches=0 matched="" disk_number part_number disk part candidate_id temporary IFS=$' \t\n'
    command -v ntfs-3g >/dev/null 2>&1 && command -v reged >/dev/null 2>&1 && declare -F rootpxe_display_windows_parse_reg >/dev/null 2>&1 || return 1
    for identity in $identities; do
        device=${identity#*|}; fs=$(blkid -s TYPE -o value "$device" 2>/dev/null | tr -d '\r\n')
        [[ $fs == ntfs ]] || continue
        mountpoint=$(mktemp -d /tmp/rootpxe-display-windows.XXXXXX) || return 1
        if ntfs-3g -o ro "$device" "$mountpoint" >/tmp/rootpxe-display-ntfs-output 2>&1; then
            hive=$(rootpxe_display_metadata_windows_hive "$mountpoint") || hive=""
            if [[ -n $hive ]]; then
                candidate=$identity; candidates=$((candidates + 1))
            fi
            rootpxe_display_metadata_cleanup_mount "$mountpoint" || return 2
        else
            rmdir -- "$mountpoint" || return 2
        fi
    done
    [[ $candidates -eq 1 ]] || return 1
    device=${candidate#*|}
    mountpoint=$(mktemp -d /tmp/rootpxe-display-windows.XXXXXX) || return 1
    ntfs-3g -o ro "$device" "$mountpoint" >/tmp/rootpxe-display-ntfs-output 2>&1 || { rmdir -- "$mountpoint" || return 2; return 1; }
    hive=$(rootpxe_display_metadata_windows_hive "$mountpoint") || hive=""
    [[ -n $hive ]] || { rootpxe_display_metadata_cleanup_mount "$mountpoint" || return 2; return 1; }
    export_file=$(mktemp /tmp/rootpxe-display-mounted-devices.XXXXXX) || { rootpxe_display_metadata_cleanup_mount "$mountpoint"; return 2; }
    chmod 600 "$export_file" || { rm -f -- "$export_file"; rootpxe_display_metadata_cleanup_mount "$mountpoint"; return 2; }
    if ! reged -x "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' MountedDevices "$export_file" >/tmp/rootpxe-display-reged-output 2>&1; then
        rm -f -- "$export_file"
        rootpxe_display_metadata_cleanup_mount "$mountpoint" || return 2
        return 1
    fi
    rootpxe_display_metadata_cleanup_mount "$mountpoint" || { rm -f -- "$export_file"; return 2; }
    parsed=$(rootpxe_display_windows_parse_reg "$export_file") || { rm -f -- "$export_file"; return 1; }
    rm -f -- "$export_file"
    jq -e 'type == "array" and all(.[]; (.driveLetter|test("^[A-Z]:$")) and (.volumeId|test("^[0-9a-f]+$")))' <<<"$parsed" >/dev/null || return 1
    while IFS=$'\t' read -r drive volume; do
        drive=${drive//$'\r'/}
        volume=${volume//$'\r'/}
        matches=0; matched=""
        for identity in $identities; do
            [[ $identity == p:* ]] || continue
            candidate_id=${identity%%|*}; part=${identity#*|}; disk_number=${candidate_id#p:}; disk_number=${disk_number%%:*}; part_number=${candidate_id##*:}
            # The source device list is numbered exactly as final inventory.
            disk=""
            for disk in ${rootpxe_display_metadata_disks:-}; do
                rootpxe_display_metadata_part_path "$disk" "$part_number" | grep -Fxq "$part" && break
                disk=""
            done
            [[ -n $disk ]] || continue
            if [[ ${#volume} -eq 48 ]]; then
                [[ ${volume:0:16} == 444d494f3a49443a ]] || { matches=-1; break; }
                candidate_id=$(blkid -s PARTUUID -o value "$part" 2>/dev/null | tr -d '\r\n')
                [[ $(rootpxe_display_metadata_guid_le_bytes "$candidate_id" 2>/dev/null) == ${volume:16:32} ]] || continue
            elif [[ ${#volume} -eq 24 ]]; then
                [[ $(rootpxe_display_metadata_mbr_volume_id "$disk" "$part" 2>/dev/null) == "$volume" ]] || continue
            else
                matches=-1; break
            fi
            matched=${identity%%|*}; matches=$((matches + 1))
        done
        [[ $matches -ge 0 ]] || { : >"${rootpxe_display_metadata_drive_rows:-/dev/null}"; return 1; }
        # A stale Windows mapping may match no captured partition, which is
        # normal. More than one match must remain unknown: emitting empty
        # driveLetters would falsely claim a successful collection.
        [[ $matches -le 1 ]] || return 1
        [[ $matches -eq 1 ]] && printf '%s\t%s\n' "$matched" "$drive" >>"${rootpxe_display_metadata_drive_rows:-/dev/null}"
    done < <(jq -r '.[] | [.driveLetter,.volumeId] | @tsv' <<<"$parsed")
    return 0
}
