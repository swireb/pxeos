#!/bin/bash
# Restore artifact checks run before the disk-write permit.  Keep this file
# free of PXEOS top-level state and disk writers so it can also be exercised
# against ordinary files by the regression harness.

rootpxe_preflight_regular_file() {
    [[ -f $1 && ! -L $1 && -r $1 && -s $1 ]]
}

rootpxe_preflight_safe_artifact() {
    local value="$1" segment
    [[ -n $value && $value != /* && $value != */ && $value != *\\* && $value != *//* && $value != *$'\n'* && $value != *$'\r'* ]] || return 1
    IFS=/ read -r -a _rootpxe_preflight_segments <<<"$value"
    for segment in "${_rootpxe_preflight_segments[@]}"; do
        [[ -n $segment && $segment != . && $segment != .. ]] || return 1
    done
}

# A capture writer finalizes an unsplit payload as BASE.  Split captures retain
# BASE.000, BASE.001, ...; accept exactly one representation, never a glob
# that can silently skip a numbered hole.
rootpxe_validate_artifact_fragments() {
    local base="$1" directory filename candidate suffix expected=0 found=0
    [[ -n $base ]] || return 1
    directory=${base%/*}; filename=${base##*/}
    [[ $directory != "$base" && -d $directory && -n $filename ]] || return 1
    if [[ -e $base ]]; then
        rootpxe_preflight_regular_file "$base" || return 1
        for candidate in "$directory/$filename".*; do
            [[ -e $candidate ]] && return 1
        done
        return 0
    fi
    for candidate in "$directory/$filename".*; do
        [[ -e $candidate ]] || continue
        suffix=${candidate##*.}
        [[ $suffix =~ ^[0-9]{3}$ ]] || return 1
        rootpxe_preflight_regular_file "$candidate" || return 1
        [[ $((10#$suffix)) -eq $expected ]] || return 1
        expected=$((expected + 1))
        found=1
    done
    [[ $found -eq 1 ]]
}

rootpxe_preflight_table_type() {
    local table_file="$1"
    rootpxe_preflight_regular_file "$table_file" || return 1
    awk '
      /^label:[[:space:]]*/ { count++; value=tolower($2) }
      END {
        if (count != 1) exit 1
        if (value == "dos") value="mbr"
        if (value != "mbr" && value != "gpt") exit 1
        print value
      }' "$table_file"
}

# Prints the exact numeric partition facts present in an sfdisk dump as
# number|startSectors|originalSectors|type.  A malformed or duplicate row is
# rejected rather than being turned into a partial expected-payload list.
rootpxe_preflight_table_rows() {
    local table_file="$1"
    rootpxe_preflight_table_type "$table_file" >/dev/null || return 1
    awk '
      /^\/dev\/[^[:space:]]+[[:space:]]*:/ {
        device=$1; number=device; sub(/^.*[^0-9]/,"",number)
        if (number !~ /^[1-9][0-9]*$/ || seen[number]++) exit 1
        if (match($0, /start=[[:space:]]*[0-9]+/) == 0) exit 1
        start=substr($0, RSTART, RLENGTH); sub(/^start=[[:space:]]*/, "", start)
        if (match($0, /size=[[:space:]]*[0-9]+/) == 0) exit 1
        size=substr($0, RSTART, RLENGTH); sub(/^size=[[:space:]]*/, "", size)
        if (size !~ /^[1-9][0-9]*$/) exit 1
        if (match($0, /(type|Id)=[[:space:]]*[^,[:space:]]+/) == 0) exit 1
        type=substr($0, RSTART, RLENGTH); sub(/^(type|Id)=[[:space:]]*/, "", type)
        print number "|" start "|" size "|" type
        rows++
      }
      END { if (rows < 1) exit 1 }' "$table_file"
}

rootpxe_preflight_normalized_type() {
    local value=${1,,}
    value=${value#0x}
    if [[ $value =~ ^0[0-9a-f]$ ]]; then
        value=${value#0}
    elif [[ $value =~ ^[0-9]+$ ]]; then
        while [[ ${#value} -gt 1 && $value == 0* ]]; do value=${value#0}; done
    fi
    printf '%s\n' "$value"
}

rootpxe_preflight_extended_type() {
    case "$(rootpxe_preflight_normalized_type "$1")" in 5|f|85) return 0 ;; esac
    return 1
}

rootpxe_preflight_swap_type() {
    case "$(rootpxe_preflight_normalized_type "$1")" in 82|8200|0657fd6d-a4ab-43c4-84e5-0933c84b4f4f) return 0 ;; esac
    return 1
}

rootpxe_preflight_known_non_lvm_type() {
    case "$(rootpxe_preflight_normalized_type "$1")" in
        5|f|85|6|b|c|e|82|8200|83|7|ef|27|12|af|0fc63daf-8483-4772-8e79-3d69d8477de4|c12a7328-f81f-11d2-ba4b-00a0c93ec93b|ebd0a0a2-b9e5-4433-87c0-68b6b72699c7|e3c9e316-0b5c-4db8-817d-f92df00215ae|de94bba4-06d1-4d40-a16a-bfd50179d6ac|21686148-6449-6e6f-744e-656564454649|0657fd6d-a4ab-43c4-84e5-0933c84b4f4f|48465300-0000-11aa-aa11-00306543ecac|7c3457ef-0000-11aa-aa11-00306543ecac) return 0 ;;
    esac
    return 1
}

rootpxe_preflight_fixed_boot_artifact() {
    local image_path="$1" disk_number="$2" table
    table=$(rootpxe_preflight_table_type "$image_path/d${disk_number}.partitions") || return 1
    # dN.mbr is always used by MBRFileName: for GPT it is the sgdisk backup,
    # and for DOS it is the saved MBR/boot region.  A DOS has_grub marker does
    # not switch that filename.  GPT may additionally carry a GRUB embedding.
    rootpxe_preflight_regular_file "$image_path/d${disk_number}.mbr" || return 1
    [[ $table != gpt || ! -e $image_path/d${disk_number}.grub.mbr ]] || rootpxe_preflight_regular_file "$image_path/d${disk_number}.grub.mbr"
}

rootpxe_preflight_inventory_rows() {
    local inventory="$1" output
    command -v jq >/dev/null 2>&1 || return 1
    output=$(jq -er '
      def whole_positive: type == "number" and . > 0 and . == floor;
      def valid_partition:
        (.number | whole_positive) and
        ((.startSectors|type) == "number" and .startSectors >= 0 and .startSectors == (.startSectors|floor)) and
        (.originalSectors | whole_positive) and
        (.typeGuid|type) == "string" and (.fs|type) == "string";
      def valid_disk:
        (.partitionTable == "mbr" or .partitionTable == "gpt") and
        (.originalDiskBytes | whole_positive) and (.logicalSectorBytes | whole_positive) and
        ((.physicalSectorBytes|type) == "number" and .physicalSectorBytes >= .logicalSectorBytes and .physicalSectorBytes == (.physicalSectorBytes|floor)) and
        (.partitions|type) == "array" and
        all(.partitions[]; valid_partition) and
        ([.partitions[].number] | unique | length) == (.partitions|length);
      if (.version == 1 and (.disks|type) == "array" and (.disks|length) > 0 and
          all(.disks[].number; type == "number" and . >= 1 and . == floor) and
          ([.disks[].number] | unique | length) == (.disks|length) and
          ([.disks[].number] | sort) == [range(1; (.disks|length) + 1)] and
          all(.disks[]; valid_disk))
      then .disks | sort_by(.number)[] | [.number,.originalDiskBytes] | @tsv
      else error("invalid fixed-image inventory") end
    ' "$inventory") || return 1
    output=${output//$'\r'/}
    printf '%s\n' "$output"
}

rootpxe_preflight_validate_inventory_table() {
    local inventory="$1" disk_number="$2" table_file="$3" expected actual expected_table actual_table actual_rows normalized_expected row_number row_start row_size row_type
    expected_table=$(jq -er --argjson disk "$disk_number" '.disks[] | select(.number == $disk) | .partitionTable' "$inventory") || return 1
    expected_table=${expected_table//$'\r'/}
    actual_table=$(rootpxe_preflight_table_type "$table_file") || return 1
    [[ $expected_table == "$actual_table" ]] || return 1
    expected=$(jq -er --argjson disk "$disk_number" '.disks[] | select(.number == $disk) | .partitions[] | [.number,.startSectors,.originalSectors,.typeGuid] | @tsv' "$inventory") || return 1
    expected=${expected//$'\r'/}
    expected=$(printf '%s\n' "$expected" | sort -n) || return 1
    actual_rows=$(rootpxe_preflight_table_rows "$table_file") || return 1
    actual=""
    while IFS='|' read -r row_number row_start row_size row_type; do
        actual+="${actual:+$'\n'}${row_number}"$'\t'"${row_start}"$'\t'"${row_size}"$'\t'"$(rootpxe_preflight_normalized_type "$row_type")"
    done <<<"$actual_rows"
    actual=$(printf '%s\n' "$actual" | sort -n) || return 1
    normalized_expected=""
    while IFS=$'\t' read -r row_number row_start row_size row_type; do
        normalized_expected+="${normalized_expected:+$'\n'}${row_number}"$'\t'"${row_start}"$'\t'"${row_size}"$'\t'"$(rootpxe_preflight_normalized_type "$row_type")"
    done <<<"$expected"
    expected=$(printf '%s\n' "$normalized_expected" | sort -n) || return 1
    [[ $expected == "$actual" ]]
}

rootpxe_preflight_no_unlisted_disk_facts() {
    local image_path="$1" maximum="$2" candidate name number
    shopt -s nullglob
    for candidate in "$image_path"/d*.size "$image_path"/d*.partitions; do
        name=${candidate##*/}
        [[ $name =~ ^d([1-9][0-9]*)\.(size|partitions)$ ]] || continue
        number=${BASH_REMATCH[1]}
        [[ $number -le $maximum ]] || { shopt -u nullglob; return 1; }
    done
    shopt -u nullglob
}

# Emits diskNumber|bytes in numerical order.  Inventory is authoritative when
# present and never falls back to legacy files after a parse failure.  Legacy
# mpa can prove bytes with dN.size; mps never captured that file and therefore
# intentionally has no disk-fact output contract.
rootpxe_fixed_restore_disk_facts() {
    local image_path="$1" inventory="$1/.rootpxe-partition-inventory.json" rows row number bytes table_file maximum=0
    [[ -d $image_path && ! -L $image_path ]] || return 1
    if [[ -e $inventory ]]; then
        rootpxe_preflight_regular_file "$inventory" || return 1
        rows=$(rootpxe_preflight_inventory_rows "$inventory") || return 1
        while IFS=$'\t' read -r number bytes; do
            [[ $number =~ ^[1-9][0-9]*$ && $bytes =~ ^[1-9][0-9]*$ ]] || return 1
            table_file="$image_path/d${number}.partitions"
            rootpxe_preflight_validate_inventory_table "$inventory" "$number" "$table_file" || return 1
            printf '%s|%s\n' "$number" "$bytes"
            maximum=$number
        done <<<"$rows"
        rootpxe_preflight_no_unlisted_disk_facts "$image_path" "$maximum" || return 1
        return 0
    fi
    number=1
    while [[ -e $image_path/d${number}.size || -e $image_path/d${number}.partitions ]]; do
        rootpxe_preflight_regular_file "$image_path/d${number}.size" || return 1
        bytes=$(awk -v expected="$number" '
          NR == 1 { value=$0; sub(/\r$/, "", value); split(value,a,":"); if (length(a) != 2 || a[1] != expected || a[2] !~ /^[1-9][0-9]*$/) exit 1; print a[2]; rows++ }
          END { if (rows != 1) exit 1 }' "$image_path/d${number}.size") || return 1
        rootpxe_preflight_table_rows "$image_path/d${number}.partitions" >/dev/null || return 1
        printf '%s|%s\n' "$number" "$bytes"
        number=$((number + 1))
    done
    [[ $number -gt 1 ]] && rootpxe_preflight_no_unlisted_disk_facts "$image_path" "$((number - 1))"
}

rootpxe_preflight_validate_fixed_inventory_payloads() {
    local image_path="$1" inventory="$2" rows row disk number type fs
    rows=$(jq -er '.disks[] | .number as $disk | .partitions[] | [$disk,.number,.typeGuid,.fs] | @tsv' "$inventory") || return 1
    rows=${rows//$'\r'/}
    while IFS=$'\t' read -r disk number type fs; do
        [[ $disk =~ ^[1-9][0-9]*$ && $number =~ ^[1-9][0-9]*$ ]] || return 1
        if [[ $fs == swap ]] || rootpxe_preflight_extended_type "$type" || rootpxe_preflight_swap_type "$type"; then continue; fi
        rootpxe_validate_artifact_fragments "$image_path/d${disk}p${number}.img" || return 1
    done <<<"$rows"
}

rootpxe_preflight_validate_fixed_legacy_payloads() {
    local image_path="$1" image_type="$2" number=1 rows part type
    if [[ $image_type == mps ]]; then
        rows=$(rootpxe_preflight_table_rows "$image_path/d1.partitions") || return 1
        while IFS='|' read -r part _ _ type; do rootpxe_preflight_extended_type "$type" || rootpxe_preflight_swap_type "$type" || rootpxe_validate_artifact_fragments "$image_path/d1p${part}.img" || return 1; done <<<"$rows"
        rootpxe_preflight_fixed_boot_artifact "$image_path" 1
        rootpxe_preflight_no_unlisted_disk_facts "$image_path" 1
        return
    fi
    rootpxe_fixed_restore_disk_facts "$image_path" >/dev/null || return 1
    while [[ -e $image_path/d${number}.size || -e $image_path/d${number}.partitions ]]; do
        rootpxe_preflight_regular_file "$image_path/d${number}.size" || return 1
        rows=$(rootpxe_preflight_table_rows "$image_path/d${number}.partitions") || return 1
        while IFS='|' read -r part _ _ type; do rootpxe_preflight_extended_type "$type" || rootpxe_preflight_swap_type "$type" || rootpxe_validate_artifact_fragments "$image_path/d${number}p${part}.img" || return 1; done <<<"$rows"
        rootpxe_preflight_fixed_boot_artifact "$image_path" "$number" || return 1
        number=$((number + 1))
    done
    [[ $number -gt 1 ]]
}

rootpxe_preflight_validate_fixed_selected_payload() {
    local image_path="$1" disk="$2" part="$3" type="$4" fs="${5:-}"
    [[ $disk =~ ^[1-9][0-9]*$ && $part =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ $fs == swap ]] || rootpxe_preflight_extended_type "$type" || rootpxe_preflight_swap_type "$type"; then return 0; fi
    rootpxe_validate_artifact_fragments "$image_path/d${disk}p${part}.img"
}

rootpxe_preflight_validate_fixed_selected() {
    local image_path="$1" image_type="$2" scope="$3" inventory="$image_path/.rootpxe-partition-inventory.json" rows facts disk part type fs found=0 number
    [[ $scope =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ -e $inventory ]]; then
        facts=$(rootpxe_fixed_restore_disk_facts "$image_path") || return 1
        while IFS='|' read -r number _; do rootpxe_preflight_fixed_boot_artifact "$image_path" "$number" || return 1; done <<<"$facts"
        rows=$(jq -er --argjson part "$scope" '.disks[] | .number as $disk | .partitions[] | select(.number == $part) | [$disk,.number,.typeGuid,.fs] | @tsv' "$inventory") || return 1
        rows=${rows//$'\r'/}
        while IFS=$'\t' read -r disk part type fs; do
            rootpxe_preflight_validate_fixed_selected_payload "$image_path" "$disk" "$part" "$type" "$fs" || return 1
            found=1
        done <<<"$rows"
    else
        if [[ $image_type == mpa ]]; then rootpxe_fixed_restore_disk_facts "$image_path" >/dev/null || return 1; fi
        number=1
        while [[ -e $image_path/d${number}.size || -e $image_path/d${number}.partitions ]]; do
            rows=$(rootpxe_preflight_table_rows "$image_path/d${number}.partitions") || return 1
            while IFS='|' read -r part _ _ type; do
                [[ $part == "$scope" ]] || continue
                rootpxe_preflight_validate_fixed_selected_payload "$image_path" "$number" "$part" "$type" || return 1
                found=1
            done <<<"$rows"
            rootpxe_preflight_fixed_boot_artifact "$image_path" "$number" || return 1
            [[ $image_type == mps ]] && break
            number=$((number + 1))
        done
    fi
    [[ $found -eq 1 ]]
}

rootpxe_validate_fixed_image_lvm_inventory() {
    local image_path="$1" inventory="$1/.rootpxe-partition-inventory.json" image_type="${imgType:-}" number
    case "${imgType:-}" in mps|mpa) ;; *) return 0 ;; esac
    if [[ -e $inventory ]]; then
        rootpxe_preflight_regular_file "$inventory" || return 1
        rootpxe_preflight_inventory_rows "$inventory" >/dev/null || return 1
        ! jq -e '[.disks[].partitions[] | select(((.fs|ascii_downcase) == "lvm2_member") or ((.typeGuid|ascii_downcase|sub("^0x";"")) == "8e") or ((.typeGuid|ascii_downcase) == "e6d6d379-f507-44c2-a23c-238f2a3df928"))] | length > 0' "$inventory" >/dev/null 2>&1
        return
    fi
    if [[ $image_type == mps ]]; then
        local rows
        rows=$(rootpxe_preflight_table_rows "$image_path/d1.partitions") || return 1
        while IFS='|' read -r _ _ _ type; do rootpxe_preflight_known_non_lvm_type "$type" || return 1; done <<<"$rows"
        rootpxe_preflight_no_unlisted_disk_facts "$image_path" 1
        return
    fi
    rootpxe_fixed_restore_disk_facts "$image_path" >/dev/null || return 1
    number=1
    while [[ -e $image_path/d${number}.size || -e $image_path/d${number}.partitions ]]; do
        local rows
        rows=$(rootpxe_preflight_table_rows "$image_path/d${number}.partitions") || return 1
        while IFS='|' read -r _ _ _ type; do rootpxe_preflight_known_non_lvm_type "$type" || return 1; done <<<"$rows"
        number=$((number + 1))
    done
    [[ $number -gt 1 ]]
}

rootpxe_preflight_n_artifacts() {
    local image_path="$1" schema_file="$2" scope="$3" rows kind number artifact
    command -v jq >/dev/null 2>&1 || return 1
    rootpxe_preflight_regular_file "$schema_file" || return 1
    rows=$(jq -er '
      . as $schema |
      if (($schema.version == 1 or $schema.version == 2) and
          ($schema.partitionTable == "mbr" or $schema.partitionTable == "gpt") and
          (($schema.partitions|type) == "array") and ($schema.partitions|length > 0) and
          ([$schema.partitions[].number] | all(type == "number" and . >= 1 and floor == .)) and
          ([$schema.partitions[].number] | unique | length) == ($schema.partitions|length) and
          ([$schema.partitions[] | select((.role|type) != "string" or (.fs|type) != "string" or (.artifact|type) != "string")] | length) == 0)
      then $schema.partitions[] else error("invalid schema") end |
      if (.role == "swap" and .fs == "swap" and .artifact == "") then ["skip",.number,""]
      elif (.kind == "extended" and .role == "extended_container" and .artifact == "") then ["skip",.number,""]
      elif ((.role == "lvm_pv" or .fs == "LVM2_member") and .artifact == "") then ["pv",.number,""]
      elif (.artifact|length) > 0 then ["payload",.number,.artifact]
      else error("missing required partition artifact") end | @tsv
    ' "$schema_file") || return 1
    rows=${rows//$'\r'/}
    if [[ $scope == all ]]; then
        :
    elif [[ $scope =~ ^[1-9][0-9]*$ ]]; then
        rows=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$scope" '$2 == n { print; found=1 } END { exit(found ? 0 : 1) }') || return 1
    else
        return 1
    fi
    while IFS=$'\t' read -r kind number artifact; do
        [[ $number =~ ^[1-9][0-9]*$ ]] || return 1
        case $kind in
            payload) rootpxe_preflight_safe_artifact "$artifact" && rootpxe_validate_artifact_fragments "$image_path/$artifact" || return 1 ;;
            skip|pv) : ;;
            *) return 1 ;;
        esac
    done <<<"$rows"
    if grep -Fq $'pv\t' <<<"$rows"; then
        local lvm_artifacts
        lvm_artifacts=$(jq -er '
          . as $schema | ($schema.lvm // null) as $lvm |
          def positive_integer: type == "number" and . >= 1 and . == floor;
          def pv_is_declared:
            .partitionNumber as $number |
            [$schema.partitions[] | select(.number == $number and (.role == "lvm_pv" or .fs == "LVM2_member"))] | length == 1;
          if ($lvm|type) != "object" or $lvm.version != 1 or $lvm.captureMode != "per_lv" or $lvm.resizePolicy != "grow_only" or
             (($lvm.pvs|type) != "array") or ($lvm.pvs|length) == 0 or (($lvm.vgs|type) != "array") or ($lvm.vgs|length) == 0 or
             (all($lvm.pvs[]; (.partitionNumber|positive_integer) and (.artifact|type) == "string" and (.artifact|length) > 0 and (.vgConfigArtifact|type) == "string" and (.vgConfigArtifact|length) > 0 and pv_is_declared) | not) or
             (all($lvm.vgs[]; (.lvs|type) == "array" and (.lvs|length) > 0 and all(.lvs[]; if .fs == "swap" then (.role == "swap" and .artifact == "" and (.swapUuid|type) == "string" and (.swapUuid|length) > 0) else ((.artifact|type) == "string" and (.artifact|length) > 0) end)) | not)
          then error("invalid lvm restore artifacts")
          else ($lvm.pvs[] | .artifact, .vgConfigArtifact), ($lvm.vgs[].lvs[] | select(.fs != "swap") | .artifact)
          end
        ' "$schema_file") || return 1
        lvm_artifacts=${lvm_artifacts//$'\r'/}
        while IFS= read -r artifact; do
            [[ -n $artifact ]] || return 1
            rootpxe_preflight_safe_artifact "$artifact" && rootpxe_validate_artifact_fragments "$image_path/$artifact" || return 1
        done <<<"$lvm_artifacts"
    else
        ! jq -e '[.partitions[] | select(.role == "lvm_pv" or .fs == "LVM2_member")] | length > 0' "$schema_file" >/dev/null 2>&1 || return 1
    fi
}

rootpxe_preflight_n_mbr() {
    local image_path="$1" schema_file="$2" table boot_file facts logical first_start expected_sectors expected_bytes size
    rootpxe_preflight_regular_file "$schema_file" || return 1
    facts=$(jq -er '
      .partitionTable as $table |
      (.logicalSectorBytes // 512) as $logical |
      ([.partitions[]? | select((.startSectors|type) == "number" and .startSectors > 0 and .startSectors == (.startSectors|floor)) | .startSectors] | min) as $first |
      if ($table == "mbr" or $table == "gpt") and ($logical|type) == "number" and $logical > 0 and $logical == ($logical|floor) and ($first|type) == "number" and $first == ($first|floor) then [$table,$logical,$first] | @tsv else error("invalid boot facts") end
    ' "$schema_file") || return 1
    facts=${facts//$'\r'/}
    IFS=$'\t' read -r table logical first_start <<<"$facts"
    [[ $table == mbr || $table == gpt ]] || return 1
    [[ $(rootpxe_preflight_table_type "$image_path/d1.partitions") == "$table" ]] || return 1
    expected_sectors=$first_start
    [[ $expected_sectors -gt 2048 ]] && expected_sectors=2048
    [[ $expected_sectors == 8 || $expected_sectors == 63 ]] && expected_sectors=1
    expected_bytes=$((expected_sectors * logical))
    [[ $expected_bytes -ge 512 ]] || return 1
    if [[ $table == mbr ]]; then
        boot_file="$image_path/d1.mbr"
    elif [[ -e $image_path/d1.grub.mbr ]]; then
        boot_file="$image_path/d1.grub.mbr"
    else
        return 0
    fi
    rootpxe_preflight_regular_file "$boot_file" || return 1
    size=$(wc -c <"$boot_file") || return 1
    [[ $size =~ ^[0-9]+$ && $size -eq $expected_bytes ]]
}

rootpxe_validate_restore_artifacts() {
    local image_path="$1" image_type="$2" scope="$3" schema_file="${4:-}" inventory="$1/.rootpxe-partition-inventory.json" number facts
    [[ -d $image_path && ! -L $image_path ]] || return 1
    case "$image_type:$scope" in
        dd:all) [[ -n ${img:-} ]] && rootpxe_preflight_safe_artifact "$img" && rootpxe_validate_artifact_fragments "$image_path/$img" ;;
        [Nn]:all) rootpxe_preflight_n_artifacts "$image_path" "$schema_file" all && rootpxe_preflight_n_mbr "$image_path" "$schema_file" ;;
        [Nn]:[1-9]* ) rootpxe_preflight_n_artifacts "$image_path" "$schema_file" "$scope" ;;
        [Nn]:mbr) rootpxe_preflight_n_mbr "$image_path" "$schema_file" ;;
        mps:all|mpa:all)
            if [[ -e $inventory ]]; then
                facts=$(rootpxe_fixed_restore_disk_facts "$image_path") || return 1
                rootpxe_preflight_validate_fixed_inventory_payloads "$image_path" "$inventory" || return 1
                while IFS='|' read -r number _; do rootpxe_preflight_fixed_boot_artifact "$image_path" "$number" || return 1; done <<<"$facts"
            else
                rootpxe_preflight_validate_fixed_legacy_payloads "$image_path" "$image_type"
            fi
            ;;
        mps:mbr|mpa:mbr)
            if [[ -e $inventory ]]; then
                facts=$(rootpxe_fixed_restore_disk_facts "$image_path") || return 1
                while IFS='|' read -r number _; do rootpxe_preflight_fixed_boot_artifact "$image_path" "$number" || return 1; done <<<"$facts"
            elif [[ $image_type == mps ]]; then
                rootpxe_preflight_table_rows "$image_path/d1.partitions" >/dev/null && rootpxe_preflight_fixed_boot_artifact "$image_path" 1
            else
                rootpxe_fixed_restore_disk_facts "$image_path" >/dev/null && rootpxe_preflight_validate_fixed_legacy_payloads "$image_path" "$image_type"
            fi
            ;;
        mps:[1-9]*|mpa:[1-9]*) rootpxe_preflight_validate_fixed_selected "$image_path" "$image_type" "$scope" ;;
        *) return 1 ;;
    esac
}
