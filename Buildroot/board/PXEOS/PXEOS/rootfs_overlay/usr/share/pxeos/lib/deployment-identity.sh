#!/bin/bash
# Deployment identity v1.  This library deliberately consumes only the
# server-frozen plan; it never generates disk IDs, filesystem UUIDs or keys.

rootpxe_deployment_identity_policy_enabled() {
    [[ -r ${deploymentIdentityPolicyFile:-} ]] || return 1
    jq -e '.version == 1 and ((.randomizeStorageIdentifiers == true) or (.systemIdentity.machineId == true) or (.systemIdentity.sshHostKeys == true) or (.systemIdentity.sshLoginPublicKeys == true) or (.systemIdentity.rootPassword == true) or (.systemIdentity.sysprep == true))' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}

rootpxe_deployment_identity_private_enabled() {
    [[ -r ${deploymentIdentityPolicyFile:-} ]] || return 1
    jq -e '.version == 1 and ((.systemIdentity.sshLoginPublicKeys == true) or (.systemIdentity.rootPassword == true) or (.systemIdentity.sysprep == true))' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}

rootpxe_deployment_identity_request_private() {
    local api="${pxeapi:-${web:-}}" request response body code file
    rootpxe_deployment_identity_private_enabled || return 0
    [[ -n $api && ${taskid:-} =~ ^[1-9][0-9]*$ && -n ${task_token:-} && -n ${mac:-} && ${progress_attempt:-} =~ ^[1-9][0-9]*$ ]] || return 1
    api="${api%/}/"
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --argjson attempt "$progress_attempt" '{taskId:$taskId,token:$token,mac:$mac,attempt:$attempt}') || return 1
    response=$(curl -Lks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-initialization" 2>/dev/null) || return 1
    code=${response##*$'\n'}; body=${response%$'\n'*}
    [[ $code == 200 ]] || return 1
    file=$(mktemp /tmp/rootpxe-deployment-initialization.XXXXXX) || return 1
    chmod 0600 "$file" || { rm -f -- "$file"; return 1; }
    printf '%s' "$body" >"$file" || { rm -f -- "$file"; return 1; }
    jq -e '.version == 1 and ((.sshLoginPublicKeys|type) == "array") and ((.rootPasswordHash|type) == "string") and ((.unattendXml|type) == "string")' "$file" >/dev/null 2>&1 || { rm -f -- "$file"; return 1; }
    rootpxe_deployment_initialization_private_file="$file"; export rootpxe_deployment_initialization_private_file
}

rootpxe_deployment_identity_cleanup_private() {
    local file="${rootpxe_deployment_initialization_private_file:-}"
    if [[ -n $file ]]; then
        [[ -f $file && ! -L $file && $file == /tmp/rootpxe-deployment-initialization.* ]] && rm -f -- "$file"
    fi
    unset rootpxe_deployment_initialization_private_file
}

rootpxe_deployment_identity_private_value() {
    local filter="$1" file="${rootpxe_deployment_initialization_private_file:-}"
    [[ -r $file && ! -L $file ]] || return 1
    jq -er "$filter" "$file"
}

rootpxe_deployment_identity_storage_enabled() {
    [[ -r ${deploymentIdentityPolicyFile:-} ]] || return 1
    jq -e '.version == 1 and .randomizeStorageIdentifiers == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}

rootpxe_deployment_identity_linux_policy_enabled() {
    rootpxe_deployment_identity_policy_enabled || return 1
    [[ ${osid:-} == 50 ]]
}

rootpxe_deployment_identity_windows_policy_enabled() {
    rootpxe_deployment_identity_policy_enabled || return 1
    case ${osid:-} in 2|5|6|7|9|10) ;; *) return 1;; esac
}

rootpxe_deployment_identity_linux_capabilities_installed() {
    local tool
    # Storage UUID, initramfs and SSH operations are deliberately advertised
    # only by images containing every executable used by their apply/readback
    # paths.  A policy is never silently accepted by an older PXEOS ISO.
    for tool in jq sgdisk sfdisk partprobe tune2fs xfs_admin mkswap lvchange ssh-keygen chroot rootpxe-offline-identities; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
}

rootpxe_deployment_identity_windows_hostname_capability_installed() {
    local tool
    for tool in jq ntfs-3g reged rootpxe-offline-identities; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
}

rootpxe_deployment_identity_windows_sysprep_capability_installed() {
    local tool
    for tool in jq ntfs-3g xmlstarlet; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
}

rootpxe_deployment_identity_target_binding() {
    local disk="$1" map_disk mapped_id operation
    [[ $disk == /dev/* ]] || return 1
    if [[ -r ${rootpxe_disk_permit_disk_map_file:-} ]]; then
        IFS=$'\t' read -r map_disk mapped_id operation < <(awk -F '\t' -v disk="$disk" '$1 == disk { print; exit }' "$rootpxe_disk_permit_disk_map_file") || return 1
        [[ $map_disk == "$disk" && $mapped_id =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || return 1
        printf '%s\n' "$mapped_id"
        return 0
    fi
    [[ ${rootpxe_disk_permit_granted:-} == yes ]] || return 1
    rootpxe_disk_stable_identity "$disk" | grep -Fx -- "${rootpxe_disk_permit_target_id:-}" >/dev/null || return 1
    printf '%s\n' "$rootpxe_disk_permit_target_id"
}

rootpxe_deployment_identity_partition_path() {
    local disk="$1" number="$2"
    [[ $disk == /dev/* && $number =~ ^[1-9][0-9]*$ ]] || return 1
    [[ $disk == *[0-9] ]] && printf '%sp%s\n' "$disk" "$number" || printf '%s%s\n' "$disk" "$number"
}

# Storage plans are constructed from the signed/captured source metadata, not
# from an old target table.  The n schema describes d1; fixed and multi-disk
# images use their separately frozen partition inventory.
rootpxe_deployment_identity_source_disk_topology() {
    local disk="$1" disk_number="$2" source_table="$3" schema="$4" binding table disk_id parts='[]' number fs uuid part_id target lvs vg_name lv_name lv_uuid lv_fs lv_fs_uuid
    binding=$(rootpxe_deployment_identity_target_binding "$disk") || return 1
    [[ $disk_number == 1 && -r $source_table && -r $schema ]] || return 1
    table=$(awk '/^label:/{value=tolower($2); if (value == "dos") value="mbr"; print value; exit}' "$source_table")
    [[ $table == gpt || $table == mbr ]] || return 1
    disk_id=$(awk '/^label-id:/{print $2; exit}' "$source_table" | tr -d '\r\n')
    [[ -n $disk_id ]] || return 1
    if [[ $table == gpt ]]; then
        [[ $disk_id =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
    else
        disk_id=${disk_id#0x}; disk_id=${disk_id#0X}; disk_id=${disk_id^^}
        [[ $disk_id =~ ^[0-9A-F]{8}$ ]] || return 1
    fi
    while IFS=$'\x1f' read -r number fs uuid part_id; do
        number=${number//$'\r'/}; fs=${fs//$'\r'/}; uuid=${uuid//$'\r'/}; part_id=${part_id//$'\r'/}
        [[ $number =~ ^[1-9][0-9]*$ && -n $part_id ]] || return 1
        target=$(rootpxe_deployment_identity_partition_path "$disk" "$number") || return 1
        if [[ $table == gpt ]]; then
            [[ $part_id =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1
        else
            part_id="${disk_id}:${number}"
        fi
        lvs='[]'
        if [[ $fs == LVM2_member ]]; then
            while IFS=$'\x1f' read -r vg_name lv_name lv_uuid lv_fs lv_fs_uuid; do
                vg_name=${vg_name//$'\r'/}; lv_name=${lv_name//$'\r'/}; lv_uuid=${lv_uuid//$'\r'/}; lv_fs=${lv_fs//$'\r'/}; lv_fs_uuid=${lv_fs_uuid//$'\r'/}
                [[ $vg_name =~ ^[A-Za-z0-9._+-]+$ && $lv_name =~ ^[A-Za-z0-9._+-]+$ && $lv_uuid =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
                case $lv_fs in ext2|ext3|ext4|xfs|swap) ;; *) return 1;; esac
                # Older schemas omit this for ext/XFS logical volumes. It is
                # unsafe to generate a storage plan for them because the old
                # fstab value cannot later be matched exactly.
                [[ -n $lv_fs_uuid ]] || return 1
                lvs=$(jq -c --arg targetDevice "/dev/$vg_name/$lv_name" --arg oldPartitionId "$lv_uuid" --arg filesystem "$lv_fs" --arg originalFilesystemUuid "$lv_fs_uuid" '. + [{targetDevice:$targetDevice,oldPartitionId:$oldPartitionId,filesystem:$filesystem,originalFilesystemUuid:$originalFilesystemUuid}]' <<<"$lvs") || return 1
            done < <(jq -r --argjson part "$number" '.lvm as $lvm | $lvm.pvs[] | select(.partitionNumber == $part) | .vgUuid as $vgid | $lvm.vgs[] | select(.uuid == $vgid and (.pvPartitionNumbers|index($part))) | .name as $vg | .lvs[] | [$vg,.name,.uuid,.fs,(.filesystemUuid // .swapUuid // "")] | join("\u001f")' "$schema")
        fi
        parts=$(jq -c --arg targetDevice "$target" --argjson number "$number" --arg oldPartitionId "$part_id" --arg filesystem "$fs" --arg originalFilesystemUuid "$uuid" --argjson logicalVolumes "$lvs" '. + [{targetDevice:$targetDevice,number:$number,oldPartitionId:$oldPartitionId,filesystem:$filesystem,originalFilesystemUuid:$originalFilesystemUuid,logicalVolumes:$logicalVolumes}]' <<<"$parts") || return 1
    done < <(jq -r '.partitions[] | select(.role != "extended_container") | [(.number|tostring), (.fs // ""), (.uuid // ""), (.partuuid // "")] | join("\u001f")' "$schema")
    jq -cn --arg targetDevice "$disk" --arg targetBinding "$binding" --arg oldDiskId "$disk_id" --arg partitionTable "$table" --argjson sourceDiskNumber "$disk_number" --argjson partitions "$parts" '{targetDevice:$targetDevice,targetBinding:$targetBinding,sourceDiskNumber:$sourceDiskNumber,oldDiskId:$oldDiskId,partitionTable:$partitionTable,partitions:$partitions}'
}

rootpxe_deployment_identity_inventory_disk_topology() {
    local disk="$1" disk_number="$2" source_table="$3" inventory="$4" binding table disk_id parts='[]' number fs uuid part_id target
    binding=$(rootpxe_deployment_identity_target_binding "$disk") || return 1
    [[ $disk_number =~ ^[1-9][0-9]*$ && -r $source_table && -r $inventory ]] || return 1
    table=$(jq -er --argjson number "$disk_number" '.disks[] | select(.number == $number) | .partitionTable' "$inventory") || return 1
    [[ $table == gpt || $table == mbr ]] || return 1
    disk_id=$(awk '/^label-id:/{print $2; exit}' "$source_table" | tr -d '\r\n')
    if [[ $table == gpt ]]; then
        [[ $disk_id =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
    else
        disk_id=${disk_id#0x}; disk_id=${disk_id#0X}; disk_id=${disk_id^^}
        [[ $disk_id =~ ^[0-9A-F]{8}$ ]] || return 1
    fi
    while IFS=$'\x1f' read -r number fs uuid part_id; do
        number=${number//$'\r'/}; fs=${fs//$'\r'/}; uuid=${uuid//$'\r'/}; part_id=${part_id//$'\r'/}
        [[ $number =~ ^[1-9][0-9]*$ ]] || return 1
        # Fixed/multi-disk inventory does not freeze enough LVM ownership and
        # LV filesystem facts for v1. Reject before writes rather than changing
        # a PV while leaving a logical-volume UUID duplicated.
        [[ $fs != LVM2_member ]] || return 1
        target=$(rootpxe_deployment_identity_partition_path "$disk" "$number") || return 1
        if [[ $table == gpt ]]; then [[ $part_id =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1; else part_id="${disk_id}:${number}"; fi
        parts=$(jq -c --arg targetDevice "$target" --argjson number "$number" --arg oldPartitionId "$part_id" --arg filesystem "$fs" --arg originalFilesystemUuid "$uuid" '. + [{targetDevice:$targetDevice,number:$number,oldPartitionId:$oldPartitionId,filesystem:$filesystem,originalFilesystemUuid:$originalFilesystemUuid,logicalVolumes:[]}]' <<<"$parts") || return 1
    done < <(jq -r --argjson disk "$disk_number" '.disks[] | select(.number == $disk) | .partitions[] | [(.number|tostring),(.fs // ""),(.uuid // ""),(.partuuid // "")] | join("\u001f")' "$inventory")
    jq -cn --arg targetDevice "$disk" --arg targetBinding "$binding" --arg oldDiskId "$disk_id" --arg partitionTable "$table" --argjson sourceDiskNumber "$disk_number" --argjson partitions "$parts" '{targetDevice:$targetDevice,targetBinding:$targetBinding,sourceDiskNumber:$sourceDiskNumber,oldDiskId:$oldDiskId,partitionTable:$partitionTable,partitions:$partitions}'
}

rootpxe_deployment_identity_minimal_disk_topology() {
    local disk="$1" binding
    binding=$(rootpxe_deployment_identity_target_binding "$disk") || return 1
    jq -cn --arg targetDevice "$disk" --arg targetBinding "$binding" '{targetDevice:$targetDevice,targetBinding:$targetBinding}'
}

rootpxe_deployment_identity_request_plan() {
    local disk api topology disks='[]' request response body http_code attempt plan_file source_hash=''
    rootpxe_deployment_identity_policy_enabled || return 0
    [[ ${progress_attempt:-} =~ ^[1-9][0-9]*$ ]] || return 1
    (( $# > 0 )) || return 1
    if rootpxe_deployment_identity_storage_enabled; then
        if [[ ${imgType:-} == [Nn] ]]; then
            [[ $# == 1 && -r ${originalSchemaFile:-} && -r ${imagePath:-}/d1.partitions && ${schemaHash:-} =~ ^[a-fA-F0-9]{64}$ ]] || return 1
            source_hash="$schemaHash"
            topology=$(rootpxe_deployment_identity_source_disk_topology "$1" 1 "$imagePath/d1.partitions" "$originalSchemaFile") || return 1
            disks=$(jq -cn --argjson disk "$topology" '[$disk]') || return 1
        else
            [[ -r ${partitionInventoryFile:-} && ${partitionInventoryHash:-} =~ ^[a-fA-F0-9]{64}$ ]] || return 1
            source_hash="$partitionInventoryHash"
            local index=1
            for disk in "$@"; do
                topology=$(rootpxe_deployment_identity_inventory_disk_topology "$disk" "$index" "$imagePath/d${index}.partitions" "$partitionInventoryFile") || return 1
                disks=$(jq -c --argjson disk "$topology" '. + [$disk]' <<<"$disks") || return 1
                index=$((index + 1))
            done
        fi
    else
        for disk in "$@"; do
            topology=$(rootpxe_deployment_identity_minimal_disk_topology "$disk") || return 1
            disks=$(jq -c --argjson disk "$topology" '. + [$disk]' <<<"$disks") || return 1
        done
    fi
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --argjson attempt "$progress_attempt" --arg sourceLayoutHash "$source_hash" --argjson disks "$disks" '{taskId:$taskId,token:$token,mac:$mac,attempt:$attempt,topology:({disks:$disks} + (if $sourceLayoutHash == "" then {} else {sourceLayoutHash:$sourceLayoutHash} end))}') || return 1
    api="${pxeapi:-${web:-}}"; [[ -n $api ]] || return 1
    response=$(curl -Lks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-identity-plan" 2>/dev/null) || return 1
    http_code=${response##*$'\n'}; body=${response%$'\n'*}
    body=${body//$'\r'/}
    [[ $http_code =~ ^2[0-9][0-9]$ ]] || return 1
    jq -e --argjson attempt "$progress_attempt" --argjson topology "$(jq -c '.topology' <<<"$request")" '
      .attempt == $attempt and (.plan.version == 1) and
      (.plan.planId | type == "string" and length > 0) and
      (.planHash | type == "string" and test("^[a-f0-9]{64}$")) and
      .plan.topology == $topology' <<<"$body" >/dev/null || return 1
    plan_file=$(mktemp /tmp/rootpxe-deployment-identity-plan.XXXXXX) || return 1
    printf '%s\n' "$body" >"$plan_file" && chmod 600 "$plan_file" || { rm -f -- "$plan_file"; return 1; }
    rootpxe_deployment_identity_plan_file="$plan_file"; export rootpxe_deployment_identity_plan_file
}

rootpxe_deployment_identity_gpt_partition_map() {
    local disk="$1" plan="$rootpxe_deployment_identity_plan_file"
    [[ $disk == /dev/* && -r $plan ]] || return 1
    ROOTPXE_IDENTITY_PLAN_TARGET="x$disk" jq -er '
      [ .plan.topology.disks[] | select(("x" + .targetDevice) == env.ROOTPXE_IDENTITY_PLAN_TARGET) ] as $oldDisks |
      [ .plan.disks[] | select(("x" + .targetDevice) == env.ROOTPXE_IDENTITY_PLAN_TARGET) ] as $newDisks |
      if (($oldDisks|length) != 1) or (($newDisks|length) != 1) then error("missing or duplicate plan disk") else . end |
      $oldDisks[0] as $old | $newDisks[0] as $new |
      ([ $old.partitions[]?.targetDevice ] | sort) as $oldTargets |
      ([ $new.partitions[]?.targetDevice ] | sort) as $newTargets |
      if $oldTargets != $newTargets then error("partition target set changed") else . end |
      $old.partitions[]? as $oldPart |
      ([ $new.partitions[]? | select(.targetDevice == $oldPart.targetDevice) ]) as $newParts |
      if ($newParts|length) != 1 then error("missing or duplicate plan partition") else $newParts[0] end as $newPart |
      [$newPart.targetDevice, $oldPart.number, ($newPart.partitionGuid // "")] | @tsv' "$plan"
}

rootpxe_deployment_identity_apply_windows_storage() {
    local disk="$1" plan="$rootpxe_deployment_identity_plan_file" table disk_guid signature plan_disk plan_target target number guid map row
    local -a gpt_mappings=()
    [[ $disk == /dev/* && -r $plan ]] || return 1
    plan_disk=$(ROOTPXE_IDENTITY_PLAN_TARGET="x$disk" jq -ec '[.plan.disks[] | select(("x" + .targetDevice) == env.ROOTPXE_IDENTITY_PLAN_TARGET)] | if length == 1 then .[0] else error("missing or duplicate storage plan disk") end' "$plan") || return 1
    plan_target=$(jq -er '.targetDevice' <<<"$plan_disk") || return 1
    [[ $plan_target == "$disk" ]] || return 1
    table=$(jq -er '.partitionTable' <<<"$plan_disk") || return 1
    case "$table" in
        gpt)
            disk_guid=$(jq -er '.diskGuid // empty' <<<"$plan_disk") || return 1
            [[ $disk_guid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
            map=$(rootpxe_deployment_identity_gpt_partition_map "$disk") || return 1
            [[ -n $map ]] || return 1
            # Validate and retain every mapping before changing the disk GUID.
            # A final newline from a shell here-string must not become a fake row.
            while IFS=$'\t' read -r target number guid || [[ -n ${target:-} ]]; do
                target=${target//$'\r'/}; number=${number//$'\r'/}; guid=${guid//$'\r'/}
                [[ $target == /dev/* && $number =~ ^[1-9][0-9]*$ && $guid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
                gpt_mappings+=("$number"$'\t'"$guid")
            done < <(printf '%s' "$map")
            (( ${#gpt_mappings[@]} > 0 )) || return 1
            sgdisk -U "$disk_guid" "$disk" >/dev/null 2>&1 || return 1
            for row in "${gpt_mappings[@]}"; do
                IFS=$'\t' read -r number guid <<<"$row"
                sgdisk -u "$number:$guid" "$disk" >/dev/null 2>&1 || return 1
            done
            ;;
        mbr)
            signature=$(jq -er '.diskSignature // empty' <<<"$plan_disk") || return 1
            [[ $signature =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
            sfdisk --disk-id "$disk" "0x$signature" >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac
    partprobe "$disk" >/dev/null 2>&1 || return 1
}
rootpxe_deployment_identity_apply_windows_storage_targets() {
    local disk
    (( $# > 0 )) || return 1
    for disk in "$@"; do rootpxe_deployment_identity_apply_windows_storage "$disk" || return 1; done
}

rootpxe_deployment_identity_linux_storage_preflight() {
    local disk="$1" spec device fs vg vg_uuid subvol activated=no options root="${rootpxe_deployment_identity_linux_state_root:-/tmp/rootpxe-identity-root}" rc=1
    spec=$(rootpxe_find_linux_root_filesystem "$disk") || return 1
    device=${spec%%|*}; spec=${spec#*|}; fs=${spec%%|*}; spec=${spec#*|}; vg=${spec%%|*}; spec=${spec#*|}; vg_uuid=${spec%%|*}; subvol=${spec#*|}
    [[ $device == /dev/* && -n $fs ]] || return 1
    if [[ -n $vg || -n $vg_uuid ]]; then
        activated=$(rootpxe_linux_activate_vg_if_needed "$disk" "$vg" "$vg_uuid") || return 1
    fi
    mkdir -p "$root" || return 1
    mountpoint -q "$root" 2>/dev/null && umount "$root" || true
    # The EFI lifecycle state belongs to the target root.  Keep this mount path
    # stable across preflight and the post-UUID remount so native repair never
    # follows PXEOS paths or a different target root.
    options=$(rootpxe_linux_mount_options rw "$fs" "$subvol") || { rootpxe_linux_cleanup_selected_vg "$vg" "$vg_uuid" "$activated"; return 1; }
    mount -t "$fs" -o "$options" "$device" "$root" || { rootpxe_linux_cleanup_selected_vg "$vg" "$vg_uuid" "$activated"; return 1; }
    if rootpxe_linux_paths_safe_for_write "$root" && [[ -f $root/etc/fstab && ! -L $root/etc/fstab ]] && rootpxe_deployment_identity_linux_reference_map "$rootpxe_deployment_identity_plan_file" >/dev/null && { [[ -x $root/usr/bin/dracut || -x $root/usr/sbin/dracut || -x $root/usr/sbin/update-initramfs || -x $root/usr/bin/mkinitcpio ]]; }; then
        rootpxe_deployment_identity_mount_linux_boot_filesystems "$root" && rootpxe_deployment_identity_linux_efi_preflight "$root"
        rc=$?
        rootpxe_deployment_identity_unmount_linux_boot_filesystems || rc=1
    fi
    umount "$root" >/dev/null 2>&1 || rc=1
    rootpxe_linux_cleanup_selected_vg "$vg" "$vg_uuid" "$activated" || rc=1
    return $rc
}

rootpxe_deployment_identity_apply_swap_uuid() {
    local target="$1" uuid="$2" label
    label=$(blkid -s LABEL -o value "$target" 2>/dev/null || true)
    label=${label//$'\r'/}; label=${label//$'\n'/}
    if [[ -n $label ]]; then
        mkswap -L "$label" -U "$uuid" "$target"
    else
        mkswap -U "$uuid" "$target"
    fi
}

rootpxe_deployment_identity_apply_linux_storage() {
    local disk="$1" plan="$rootpxe_deployment_identity_plan_file" table guid disk_guid signature target uuid fs plan_disk plan_target number map row
    local -a gpt_mappings=()
    [[ $disk == /dev/* && -r $plan ]] || return 1
    # The plan is frozen before any clone write.  Select by the permitted target
    # path and reject duplicate/missing entries instead of relying on array order.
    plan_disk=$(ROOTPXE_IDENTITY_PLAN_TARGET="x$disk" jq -ec '[.plan.disks[] | select(("x" + .targetDevice) == env.ROOTPXE_IDENTITY_PLAN_TARGET)] | if length == 1 then .[0] else error("missing or duplicate storage plan disk") end' "$plan") || return 1
    plan_target=$(jq -er '.targetDevice' <<<"$plan_disk") || return 1
    [[ $plan_target == "$disk" ]] || return 1
    table=$(jq -er '.partitionTable' <<<"$plan_disk") || return 1
    if [[ $table == gpt ]]; then
        disk_guid=$(jq -er '.diskGuid // empty' <<<"$plan_disk") || return 1
        [[ -z $disk_guid || $disk_guid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
        map=$(rootpxe_deployment_identity_gpt_partition_map "$disk") || return 1
        [[ -n $map ]] || return 1
        # Validate the complete frozen-topology mapping before the first GPT write.
        while IFS=$'\t' read -r target number guid || [[ -n ${target:-} ]]; do
            target=${target//$'\r'/}; number=${number//$'\r'/}; guid=${guid//$'\r'/}
            [[ $target == /dev/* && $number =~ ^[1-9][0-9]*$ ]] || return 1
            [[ -z $guid || $guid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
            gpt_mappings+=("$number"$'\t'"$guid")
        done < <(printf '%s' "$map")
        (( ${#gpt_mappings[@]} > 0 )) || return 1
        [[ -z $disk_guid ]] || sgdisk -U "$disk_guid" "$disk" >/dev/null 2>&1 || return 1
        for row in "${gpt_mappings[@]}"; do
            IFS=$'\t' read -r number guid <<<"$row"
            [[ -z $guid ]] || sgdisk -u "$number:$guid" "$disk" >/dev/null 2>&1 || return 1
        done
    elif [[ $table == mbr ]]; then
        signature=$(jq -er '.diskSignature // empty' <<<"$plan_disk") || return 1
        [[ -z $signature ]] || sfdisk --disk-id "$disk" "0x$signature" >/dev/null 2>&1 || return 1
    else
        return 1
    fi
    while IFS=$'\t' read -r target fs uuid; do
        target=${target//$'\r'/}; fs=${fs//$'\r'/}; uuid=${uuid//$'\r'/}
        [[ $target == /dev/* ]] || return 1
        [[ -z $uuid ]] && continue
        case "$fs" in
            ext2|ext3|ext4) tune2fs -U "$uuid" "$target" >/dev/null 2>&1 ;;
            xfs) xfs_admin -U "$uuid" "$target" >/dev/null 2>&1 ;;
            swap) rootpxe_deployment_identity_apply_swap_uuid "$target" "$uuid" >/dev/null 2>&1 ;;
            *) continue ;;
        esac || return 1
    done < <(jq -r '.partitions[] | [.targetDevice,.filesystem,(.filesystemUuid // "")] | @tsv' <<<"$plan_disk")
    # An LVM2_member partition retains its own LVM UUID.  Only its planned
    # logical-volume filesystem UUIDs change, after activating the exact LV.
    while IFS=$'\t' read -r target fs uuid; do
        target=${target//$'\r'/}; fs=${fs//$'\r'/}; uuid=${uuid//$'\r'/}
        [[ $target == /dev/* && $target != *'..'* ]] || return 1
        [[ -z $uuid ]] && continue
        command -v lvchange >/dev/null 2>&1 || return 1
        lvchange -ay "$target" >/dev/null 2>&1 || return 1
        case "$fs" in
            ext2|ext3|ext4) tune2fs -U "$uuid" "$target" >/dev/null 2>&1 ;;
            xfs) xfs_admin -U "$uuid" "$target" >/dev/null 2>&1 ;;
            swap) rootpxe_deployment_identity_apply_swap_uuid "$target" "$uuid" >/dev/null 2>&1 ;;
            *) return 1 ;;
        esac || return 1
    done < <(jq -r '.partitions[] | .logicalVolumes[]? | [.targetDevice,.filesystem,(.filesystemUuid // "")] | @tsv' <<<"$plan_disk")
    rootpxe_deployment_identity_storage_result=true
}

rootpxe_deployment_identity_apply_linux_storage_targets() {
    local disk
    (( $# > 0 )) || return 1
    for disk in "$@"; do
        rootpxe_deployment_identity_apply_linux_storage "$disk" || return 1
    done
}

rootpxe_deployment_identity_source_partition_geometry() {
    local source_disk="$1" number="$2"
    [[ $source_disk =~ ^[1-9][0-9]*$ && $number =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ ${imgType:-} == [Nn] ]]; then
        [[ $source_disk == 1 && -r ${originalSchemaFile:-} ]] || return 1
        jq -er --argjson n "$number" '.logicalSectorBytes as $s | .partitions[] | select(.number == $n) | [$s, (.startSectors * $s), (.originalSectors * $s)] | @tsv' "$originalSchemaFile"
    else
        [[ -r ${partitionInventoryFile:-} ]] || return 1
        jq -er --argjson d "$source_disk" --argjson n "$number" '.disks[] | select(.number == $d) | .logicalSectorBytes as $s | .partitions[] | select(.number == $n) | [$s, (.startSectors * $s), (.originalSectors * $s)] | @tsv' "$partitionInventoryFile"
    fi
}

rootpxe_deployment_identity_target_partition_geometry() {
    local target="$1" parent disk
    [[ $target == /dev/* ]] || return 1
    parent=$(lsblk -no PKNAME "$target" 2>/dev/null | head -n1) || return 1
    [[ $parent =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    disk="/dev/$parent"
    # sfdisk reports both START and SIZE in the disk's actual logical sectors.
    # lsblk START alone is insufficient on a 4Kn target.
    sfdisk --json "$disk" 2>/dev/null | jq -er --arg target "x$target" '
      .partitiontable.sectorsize as $s |
      .partitiontable.partitions[] | select(("x" + .node) == $target) |
      [$s, (.start * $s), (.size * $s)] | @tsv'
}

rootpxe_deployment_identity_efi_volume_map() {
    local plan="$rootpxe_deployment_identity_plan_file" target source_disk number table binding old_disk new_disk old_part new_part old_sector old_offset old_size new_sector new_offset new_size map='[]'
    [[ -r $plan ]] || return 1
    while IFS=$'\t' read -r target source_disk number table binding old_disk new_disk old_part new_part; do
        target=${target//$'\r'/}; source_disk=${source_disk//$'\r'/}; number=${number//$'\r'/}; table=${table//$'\r'/}; binding=${binding//$'\r'/}; old_disk=${old_disk//$'\r'/}; new_disk=${new_disk//$'\r'/}; old_part=${old_part//$'\r'/}; new_part=${new_part//$'\r'/}
        [[ $target == /dev/* && $source_disk =~ ^[1-9][0-9]*$ && $number =~ ^[1-9][0-9]*$ && $table =~ ^(gpt|mbr)$ && -n $binding && -n $old_disk && -n $new_disk ]] || return 1
        read -r old_sector old_offset old_size < <(rootpxe_deployment_identity_source_partition_geometry "$source_disk" "$number") || return 1
        read -r new_sector new_offset new_size < <(rootpxe_deployment_identity_target_partition_geometry "$target") || return 1
        old_sector=${old_sector//$'\r'/}; old_offset=${old_offset//$'\r'/}; old_size=${old_size//$'\r'/}; new_sector=${new_sector//$'\r'/}; new_offset=${new_offset//$'\r'/}; new_size=${new_size//$'\r'/}
        [[ $old_sector =~ ^[1-9][0-9]*$ && $old_offset =~ ^[0-9]+$ && $old_size =~ ^[1-9][0-9]*$ && $new_sector =~ ^[1-9][0-9]*$ && $new_offset =~ ^[0-9]+$ && $new_size =~ ^[1-9][0-9]*$ ]] || return 1
        map=$(jq -c --arg partitionTable "$table" --arg diskBinding "$binding" --argjson partitionNumber "$number" --arg oldDiskId "$old_disk" --arg newDiskId "$new_disk" --arg oldPartitionGuid "$old_part" --arg newPartitionGuid "$new_part" --argjson oldOffsetBytes "$old_offset" --argjson newOffsetBytes "$new_offset" --argjson oldSizeBytes "$old_size" --argjson newSizeBytes "$new_size" --argjson oldLogicalSectorBytes "$old_sector" --argjson newLogicalSectorBytes "$new_sector" '. + [{partitionTable:$partitionTable,diskBinding:$diskBinding,partitionNumber:$partitionNumber,oldDiskId:$oldDiskId,newDiskId:$newDiskId,oldPartitionGuid:$oldPartitionGuid,newPartitionGuid:$newPartitionGuid,oldOffsetBytes:$oldOffsetBytes,newOffsetBytes:$newOffsetBytes,oldSizeBytes:$oldSizeBytes,newSizeBytes:$newSizeBytes,oldLogicalSectorBytes:$oldLogicalSectorBytes,newLogicalSectorBytes:$newLogicalSectorBytes}]' <<<"$map") || return 1
    done < <(jq -er '
      .plan.topology.disks[] as $old |
      ([.plan.disks[] | select(.targetDevice == $old.targetDevice)]) as $newDisks |
      if ($newDisks | length) != 1 then error("unmatched plan disk") else $newDisks[0] end as $new |
      $old.partitions[] as $oldPart |
      ([ $new.partitions[] | select(.targetDevice == $oldPart.targetDevice) ]) as $newParts |
      if ($newParts | length) != 1 then error("unmatched plan partition") else $newParts[0] end as $newPart |
      [$oldPart.targetDevice, $old.sourceDiskNumber, $oldPart.number, $old.partitionTable, $old.targetBinding, $old.oldDiskId, ($new.diskGuid // $new.diskSignature // ""), ($oldPart.oldPartitionId // ""), ($newPart.partitionGuid // "")] | @tsv' "$plan") || return 1
    printf '%s\n' "$map"
}

rootpxe_deployment_identity_source_esp_targets() {
    local query
    query='def esp: ((.role // "") == "efi" or ((.typeGuid // "" | tostring | ascii_downcase) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b") or ((.typeGuid // "" | tostring | ascii_downcase) == "0xef") or ((.typeGuid // "" | tostring | ascii_downcase) == "ef"));'
    if [[ ${imgType:-} == [Nn] ]]; then
        [[ -r ${originalSchemaFile:-} ]] || return 1
        jq -r "$query .partitions[] | select(esp) | .number" "$originalSchemaFile"
    else
        [[ -r ${partitionInventoryFile:-} ]] || return 1
        jq -r "$query .disks[] as \$disk | .partitions[] | select(esp) | [\$disk.number, .number] | @tsv" "$partitionInventoryFile"
    fi
}

rootpxe_deployment_identity_linux_esp_target_device() {
    local source_disk="$1" number="$2" plan="$rootpxe_deployment_identity_plan_file"
    [[ $source_disk =~ ^[1-9][0-9]*$ && $number =~ ^[1-9][0-9]*$ && -r $plan ]] || return 1
    jq -er --argjson sourceDisk "$source_disk" --argjson number "$number" '
      .plan.topology.disks[] | select(.sourceDiskNumber == $sourceDisk) |
      .partitions[] | select(.number == $number) | .targetDevice' "$plan"
}

rootpxe_deployment_identity_linux_efi_fallback_name() {
    case $(uname -m) in aarch64) printf '%s\n' BOOTAA64.EFI ;; i?86) printf '%s\n' BOOTIA32.EFI ;; *) printf '%s\n' BOOTX64.EFI ;; esac
}

rootpxe_deployment_identity_linux_efi_mount_for_target() {
    local target="$1" record
    for record in "${rootpxe_deployment_identity_boot_mount_records[@]:-}"; do
        [[ ${record#*$'\x1f'} == "$target" ]] && { printf '%s\n' "${record%%$'\x1f'*}"; return 0; }
    done
    return 1
}

rootpxe_deployment_identity_linux_efi_esp_mounts() {
    local number target mount source_disk=1 row
    if [[ ${imgType:-} == [Nn] ]]; then
        while IFS= read -r number; do
            number=${number//$'\r'/}
            target=$(rootpxe_deployment_identity_linux_esp_target_device "$source_disk" "$number") || return 1
            target=${target//$'\r'/}
            mount=$(rootpxe_deployment_identity_linux_efi_mount_for_target "$target") || continue
            printf '%s\n' "$mount"
        done < <(rootpxe_deployment_identity_source_esp_targets)
    else
        while IFS=$'\t' read -r source_disk number; do
            source_disk=${source_disk//$'\r'/}; number=${number//$'\r'/}
            target=$(rootpxe_deployment_identity_linux_esp_target_device "$source_disk" "$number") || return 1
            target=${target//$'\r'/}
            mount=$(rootpxe_deployment_identity_linux_efi_mount_for_target "$target") || continue
            printf '%s\n' "$mount"
        done < <(rootpxe_deployment_identity_source_esp_targets)
    fi
}

rootpxe_deployment_identity_linux_efi_detected() {
    local mount file
    while IFS= read -r mount; do
        for file in "$mount"/EFI/*/*.EFI "$mount"/EFI/*/*.efi; do
            [[ -f $file && ! -L $file ]] && return 0
        done
    done < <(rootpxe_deployment_identity_linux_efi_esp_mounts)
    return 1
}

rootpxe_deployment_identity_linux_efi_fallback_present() {
    local mount fallback
    fallback=$(rootpxe_deployment_identity_linux_efi_fallback_name) || return 1
    while IFS= read -r mount; do
        [[ -f "$mount/EFI/BOOT/$fallback" && ! -L "$mount/EFI/BOOT/$fallback" ]] && return 0
    done < <(rootpxe_deployment_identity_linux_efi_esp_mounts)
    return 1
}

rootpxe_deployment_identity_linux_efi_manifest() {
    local root="$1" plan="$rootpxe_deployment_identity_plan_file" plan_id state manifest volumes
    [[ $root == /* && -d $root && ! -L $root && -r $plan ]] || return 1
    plan_id=$(jq -er '.plan.planId | select(type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))' "$plan") || return 1
    state=".rootpxe-offline-identities/$plan_id/efi"
    rootpxe_deployment_identity_safe_target_dir "$root" "$state" || return 1
    manifest="$root/$state/manifest.json"
    [[ ! -e $manifest || ( -f $manifest && ! -L $manifest ) ]] || return 1
    volumes=$(rootpxe_deployment_identity_efi_volume_map) || return 1
    jq -e 'type == "array" and length > 0' <<<"$volumes" >/dev/null || return 1
    jq -cn --arg stateRoot "$root" --arg efiVarFs "${rootpxe_deployment_identity_efi_var_fs:-/sys/firmware/efi/efivars}" --argjson volumes "$volumes" '{version:1,stateRoot:$stateRoot,efiVarFs:$efiVarFs,volumes:$volumes}' >"$manifest" || return 1
    chmod 600 "$manifest" || return 1
    rootpxe_deployment_identity_linux_efi_manifest_file="$manifest"
}

rootpxe_deployment_identity_linux_efi_phase() {
    local root="$1" phase="$2" manifest result matched
    [[ $phase == preflight || $phase == apply || $phase == verify ]] || return 1
    manifest="${rootpxe_deployment_identity_linux_efi_manifest_file:-$root/.rootpxe-offline-identities/$(jq -r '.plan.planId // empty' "$rootpxe_deployment_identity_plan_file")/efi/manifest.json}"
    [[ -f $manifest && ! -L $manifest ]] || return 1
    if [[ ! -d ${rootpxe_deployment_identity_efi_var_fs:-/sys/firmware/efi/efivars} ]]; then
        rootpxe_deployment_identity_linux_efi_fallback_present
        return $?
    fi
    command -v rootpxe-offline-identities >/dev/null 2>&1 || return 1
    result=$(mktemp "/tmp/rootpxe-linux-efi-${phase}.XXXXXX") || return 1
    rm -f "$result"
    rootpxe-offline-identities efi-repair --manifest "$manifest" --plan "$rootpxe_deployment_identity_plan_file" --result "$result" --phase "$phase" || return 1
    if [[ $phase == preflight ]]; then
        jq -e '.version == 1 and .efi.available == true and (.efi.matched | type) == "number"' "$result" >/dev/null || return 1
        matched=$(jq -er '.efi.matched' "$result") || return 1
        [[ $matched -gt 0 ]] || rootpxe_deployment_identity_linux_efi_fallback_present || return 1
    elif [[ $phase == apply ]]; then
        jq -e '.version == 1 and .efi.available == true and (.efi.updated | type) == "number"' "$result" >/dev/null || return 1
    else
        jq -e '.version == 1 and .efi.available == true and .efi.verified == true and (.efi.updated | type) == "number"' "$result" >/dev/null || return 1
    fi
}

rootpxe_deployment_identity_linux_efi_preflight() {
    local root="$1"
    rootpxe_deployment_identity_linux_efi_detected || return 0
    rootpxe_deployment_identity_linux_efi_manifest "$root" || return 1
    rootpxe_deployment_identity_linux_efi_phase "$root" preflight
}

rootpxe_deployment_identity_linux_reference_map() {
    local plan="$1" number old_part new_part old_uuid new_uuid disk_signature
    [[ -r $plan ]] || return 1
    # Match every returned disk/partition/LV by its frozen target device.  The
    # API may canonicalize disk ordering, so array position is not identity.
    while IFS=$'\x1f' read -r number old_part new_part old_uuid new_uuid disk_signature; do
        number=${number//$'\r'/}; old_part=${old_part//$'\r'/}; new_part=${new_part//$'\r'/}; old_uuid=${old_uuid//$'\r'/}; new_uuid=${new_uuid//$'\r'/}; disk_signature=${disk_signature//$'\r'/}
        if [[ -n $old_uuid && -n $new_uuid ]]; then printf 'UUID\t%s\t%s\n' "$old_uuid" "$new_uuid"; fi
        if [[ -n $old_part ]]; then
            if [[ -n $new_part ]]; then
                printf 'PARTUUID\t%s\t%s\n' "$old_part" "$new_part"
            elif [[ $disk_signature =~ ^[0-9A-Fa-f]{8}$ && $number =~ ^[1-9][0-9]*$ ]]; then
                if [[ $old_part =~ ^[0-9A-Fa-f]{8}:[1-9][0-9]*$ ]]; then old_part="${old_part%%:*}-${old_part#*:}"; fi
                printf -v old_part '%s-%02x' "${old_part%-*}" "$((10#${old_part##*-}))"
                printf 'PARTUUID\t%s\t%s-%02x\n' "${old_part,,}" "${disk_signature,,}" "$((10#$number))"
            fi
        fi
    done < <(jq -r '
      .plan.topology.disks[] as $oldDisk |
      ([.plan.disks[] | select(.targetDevice == $oldDisk.targetDevice)]) as $newDisks |
      if ($newDisks|length) != 1 then error("unmatched plan disk") else $newDisks[0] end as $newDisk |
      ($newDisk.diskSignature // "") as $diskSignature |
      $oldDisk.partitions[] as $oldPart |
      ([ $newDisk.partitions[] | select(.targetDevice == $oldPart.targetDevice) ]) as $newParts |
      if ($newParts|length) != 1 then error("unmatched plan partition") else $newParts[0] end as $newPart |
      [$oldPart.number, ($oldPart.oldPartitionId // ""), ($newPart.partitionGuid // ""), ($oldPart.originalFilesystemUuid // ""), ($newPart.filesystemUuid // ""), $diskSignature] | map(tostring) | join("\u001f")' "$plan") || return 1
    while IFS=$'\x1f' read -r old_uuid new_uuid; do
        old_uuid=${old_uuid//$'\r'/}; new_uuid=${new_uuid//$'\r'/}
        [[ -n $old_uuid && -n $new_uuid ]] && printf 'UUID\t%s\t%s\n' "$old_uuid" "$new_uuid"
    done < <(jq -r '
      .plan.topology.disks[] as $oldDisk |
      ([.plan.disks[] | select(.targetDevice == $oldDisk.targetDevice)]) as $newDisks |
      if ($newDisks|length) != 1 then error("unmatched plan disk") else $newDisks[0] end as $newDisk |
      $oldDisk.partitions[] as $oldPart |
      ([ $newDisk.partitions[] | select(.targetDevice == $oldPart.targetDevice) ]) as $newParts |
      if ($newParts|length) != 1 then error("unmatched plan partition") else $newParts[0] end as $newPart |
      $oldPart.logicalVolumes[]? as $oldLv |
      ([ $newPart.logicalVolumes[]? | select(.targetDevice == $oldLv.targetDevice) ]) as $newLvs |
      if ($newLvs|length) != 1 then error("unmatched plan logical volume") else $newLvs[0] end as $newLv |
      [$oldLv.originalFilesystemUuid, ($newLv.filesystemUuid // "")] | map(tostring) | join("\u001f")' "$plan") || return 1
}

rootpxe_deployment_identity_rewrite_linux_reference_text() {
    local map="$1"
    [[ -r $map ]] || return 1
    awk -F '\t' '
      NR == FNR { replacement[$1 SUBSEP $2]=$3; next }
      function replace_refs(line,key,pattern,segment,token,value,replacement_value,before,out,start,quote,closing,prefix,suffix) {
        pattern="(" key "=\"[A-Za-z0-9._:-]+\"|" key "=[A-Za-z0-9._:-]+)"; start=1; out=""
        while (match(substr(line,start),pattern)) {
          segment=substr(line,start); before=substr(segment,1,RSTART-1); token=substr(segment,RSTART,RLENGTH)
          value=substr(token,length(key)+2); quote=(substr(value,1,1)=="\""); closing=(quote && substr(value,length(value),1)=="\"")
          if (quote) { value=substr(value,2); if (closing) value=substr(value,1,length(value)-1) }
          replacement_value=replacement[key SUBSEP value]
          prefix=key "=" (quote ? "\"" : ""); suffix=(closing ? "\"" : "")
          out=out before ((replacement_value == "") ? token : prefix replacement_value suffix)
          start += RSTART + RLENGTH - 1
        }
        return out substr(line,start)
      }
      function replace_search_uuid(line,pattern,segment,token,value,replacement_value,before,out,start,pieces,count,last,prefix,quote,closing) {
        start=1; out=""
        pattern="--fs-uuid([[:space:]]+--[^[:space:]]+)*([[:space:]]+\\[[^]]+\\])*[[:space:]]+(\"[A-Za-z0-9._:-]+\"|[A-Za-z0-9._:-]+)"
        while (match(substr(line,start),pattern)) {
          segment=substr(line,start); before=substr(segment,1,RSTART-1); token=substr(segment,RSTART,RLENGTH)
          count=split(token,pieces,/[[:space:]]+/); last=pieces[count]; value=last
          quote=(substr(value,1,1)=="\""); closing=(quote && substr(value,length(value),1)=="\"")
          if (quote) { value=substr(value,2); if (closing) value=substr(value,1,length(value)-1) }
          replacement_value=replacement["UUID" SUBSEP value]
          prefix=substr(token,1,length(token)-length(last))
          out=out before ((replacement_value == "") ? token : prefix (quote ? "\"" : "") replacement_value (closing ? "\"" : ""))
          start += RSTART + RLENGTH - 1
        }
        return out substr(line,start)
      }
      { print replace_search_uuid(replace_refs(replace_refs($0,"UUID"),"PARTUUID")) }' "$map" -
}

rootpxe_deployment_identity_safe_target_file() {
    local root="$1" file="$2" relative parent cursor segment
    [[ $root == /* && -d $root && ! -L $root && $file == "$root/"* ]] || return 1
    relative="${file#"$root/"}"
    [[ -n $relative && $relative != *'..'* ]] || return 1
    parent="${relative%/*}"; cursor="$root"
    if [[ $parent != "$relative" ]]; then
        IFS=/ read -r -a _rootpxe_identity_segments <<<"$parent"
        for segment in "${_rootpxe_identity_segments[@]}"; do
            [[ -n $segment && $segment != . ]] || return 1
            cursor="$cursor/$segment"
            [[ -d $cursor && ! -L $cursor ]] || return 1
        done
    fi
    [[ -f $file && ! -L $file ]]
}

rootpxe_deployment_identity_rewrite_linux_references() {
    local root="$1" map="$2" file temporary
    [[ -r $map ]] || return 1
    for file in "$root/etc/fstab" "$root/etc/crypttab" "$root/etc/default/grub" "$root/boot/grub2/grub.cfg" "$root/boot/grub/grub.cfg"; do
        [[ -e $file ]] || continue
        rootpxe_deployment_identity_safe_target_file "$root" "$file" || return 1
        temporary=$(mktemp "${file}.rootpxe.XXXXXX") || return 1
        rootpxe_deployment_identity_rewrite_linux_reference_text "$map" <"$file" >"$temporary" || { rm -f -- "$temporary"; return 1; }
        cmp -s "$file" "$temporary" || cat "$temporary" >"$file" || { rm -f -- "$temporary"; return 1; }
        rm -f -- "$temporary"
    done
    if [[ -e $root/boot/loader/entries ]]; then
        [[ -d $root/boot/loader/entries && ! -L $root/boot/loader/entries ]] || return 1
        [[ -d $root/boot && ! -L $root/boot && -d $root/boot/loader && ! -L $root/boot/loader ]] || return 1
        for file in "$root"/boot/loader/entries/*.conf; do
            [[ -e $file ]] || continue
            rootpxe_deployment_identity_safe_target_file "$root" "$file" || return 1
            temporary=$(mktemp "${file}.rootpxe.XXXXXX") || return 1
            rootpxe_deployment_identity_rewrite_linux_reference_text "$map" <"$file" >"$temporary" || { rm -f -- "$temporary"; return 1; }
            cmp -s "$file" "$temporary" || cat "$temporary" >"$file" || { rm -f -- "$temporary"; return 1; }
            rm -f -- "$temporary"
        done
    fi
}

rootpxe_deployment_identity_rewrite_linux_grubenv() {
    local root="$1" map="$2" grubenv tool env_path output kernelopts rewritten count
    [[ -r $map ]] || return 1
    for grubenv in "$root/boot/grub2/grubenv" "$root/boot/grub/grubenv"; do
        [[ -e $grubenv ]] || continue
        [[ -f $grubenv && ! -L $grubenv ]] || return 1
        env_path="${grubenv#"$root"}"
        tool=""
        for tool in /usr/bin/grub2-editenv /usr/sbin/grub2-editenv /usr/bin/grub-editenv /usr/sbin/grub-editenv; do
            [[ -x "$root$tool" && ! -L "$root$tool" ]] && break
            tool=""
        done
        [[ -n $tool ]] || return 1
        output=$(chroot "$root" "$tool" "$env_path" list) || return 1
        count=$(printf '%s\n' "$output" | awk -F= '$1 == "kernelopts" { count++ } END { print count+0 }') || return 1
        [[ $count =~ ^[01]$ ]] || return 1
        [[ $count == 0 ]] && continue
        kernelopts=$(printf '%s\n' "$output" | awk 'index($0,"kernelopts=") == 1 { print substr($0,12); exit }') || return 1
        rewritten=$(printf '%s\n' "$kernelopts" | rootpxe_deployment_identity_rewrite_linux_reference_text "$map") || return 1
        [[ $rewritten == "$kernelopts" ]] && continue
        chroot "$root" "$tool" "$env_path" set "kernelopts=$rewritten" || return 1
        output=$(chroot "$root" "$tool" "$env_path" list) || return 1
        [[ $(printf '%s\n' "$output" | awk 'index($0,"kernelopts=") == 1 { print substr($0,12); exit }') == "$rewritten" ]] || return 1
    done
}

rootpxe_deployment_identity_plan_target_device() {
    local device="$1"
    [[ $device == /dev/* ]] || return 1
    ROOTPXE_IDENTITY_PLAN_TARGET="x$device" jq -e '[.plan.disks[].partitions[]?.targetDevice, .plan.disks[].partitions[]?.logicalVolumes[]?.targetDevice] | map("x" + .) | index(env.ROOTPXE_IDENTITY_PLAN_TARGET) != null' "$rootpxe_deployment_identity_plan_file" >/dev/null 2>&1
}

rootpxe_deployment_identity_fstab_identifier() {
    local value="$1"
    if [[ $value == \"* ]]; then
        [[ ${#value} -gt 2 && $value == *\" ]] || return 1
        value="${value:1:${#value}-2}"
    elif [[ $value == *\"* ]]; then
        return 1
    fi
    [[ $value =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    printf '%s' "$value"
}

rootpxe_deployment_identity_mount_linux_boot_filesystems() {
    local root="$1" source target identifier device fs options
    rootpxe_deployment_identity_boot_mounts=()
    rootpxe_deployment_identity_boot_mount_records=()
    [[ -e $root/etc/fstab ]] || return 0
    rootpxe_deployment_identity_safe_target_file "$root" "$root/etc/fstab" || return 1
    while IFS=$'\t' read -r source target; do
        [[ $target == /boot || $target == /boot/efi ]] || continue
        [[ -d "$root$target" && ! -L "$root$target" ]] || return 1
        case "$source" in
            UUID=*) identifier=$(rootpxe_deployment_identity_fstab_identifier "${source#UUID=}") || return 1; device=$(blkid -U "$identifier" 2>/dev/null) ;;
            PARTUUID=*) identifier=$(rootpxe_deployment_identity_fstab_identifier "${source#PARTUUID=}") || return 1; device=$(blkid -t "PARTUUID=$identifier" -o device 2>/dev/null) ;;
            /dev/*) device="$source" ;;
            *) return 1 ;;
        esac
        [[ -b $device ]] || return 1
        rootpxe_deployment_identity_plan_target_device "$device" || return 1
        fs=$(blkid -s TYPE -o value "$device" 2>/dev/null | tr -d '\r\n') || return 1
        case "$fs" in vfat|ext2|ext3|ext4|xfs) ;; *) return 1;; esac
        mountpoint -q "$root$target" 2>/dev/null && continue
        options=$(rootpxe_linux_mount_options rw "$fs") || return 1
        mount -t "$fs" -o "$options" "$device" "$root$target" || return 1
        rootpxe_deployment_identity_boot_mounts+=("$root$target")
        rootpxe_deployment_identity_boot_mount_records+=("$root$target"$'\x1f'"$device")
    done < <(awk '!/^[[:space:]]*#/ && NF >= 2 { print $1 "\t" $2 }' "$root/etc/fstab")
}

rootpxe_deployment_identity_unmount_linux_boot_filesystems() {
    local index
    for ((index=${#rootpxe_deployment_identity_boot_mounts[@]}-1; index>=0; index--)); do
        umount "${rootpxe_deployment_identity_boot_mounts[$index]}" >/dev/null 2>&1 || return 1
    done
    rootpxe_deployment_identity_boot_mounts=()
    rootpxe_deployment_identity_boot_mount_records=()
}

rootpxe_deployment_identity_rebuild_linux_initramfs() {
    local root="$1" tool kernel result kernels=()
    rootpxe_deployment_identity_storage_enabled || return 0
    rootpxe_deployment_identity_safe_target_dir "$root" dev || return 1
    rootpxe_deployment_identity_safe_target_dir "$root" proc || return 1
    rootpxe_deployment_identity_safe_target_dir "$root" sys || return 1
    for kernel in "$root"/lib/modules/*; do [[ -d $kernel && ! -L $kernel ]] && kernels+=("${kernel##*/}"); done
    (( ${#kernels[@]} > 0 )) || return 1
    mount --rbind /dev "$root/dev" || return 1
    mount --make-rslave "$root/dev" || { umount -l "$root/dev" >/dev/null 2>&1 || true; return 1; }
    mount -t proc proc "$root/proc" || { umount -l "$root/dev" >/dev/null 2>&1 || true; return 1; }
    mount -t sysfs sysfs "$root/sys" || { umount "$root/proc" >/dev/null 2>&1 || true; umount -l "$root/dev" >/dev/null 2>&1 || true; return 1; }
    for tool in /usr/bin/dracut /usr/sbin/dracut; do
        if [[ -x "$root$tool" && ! -L "$root$tool" ]]; then
            # Never let dracut pick PXEOS' uname kernel.  Each installed target
            # kernel receives its own image; chroot has no host module fallback.
            for kernel in "${kernels[@]}"; do chroot "$root" "$tool" -f --kver "$kernel" || { result=1; break; }; done
            umount "$root/sys" >/dev/null 2>&1 || result=1
            umount "$root/proc" >/dev/null 2>&1 || result=1
            umount -l "$root/dev" >/dev/null 2>&1 || result=1
            return ${result:-0}
        fi
    done
    if [[ -x $root/usr/sbin/update-initramfs && ! -L $root/usr/sbin/update-initramfs ]]; then chroot "$root" /usr/sbin/update-initramfs -u -k all; result=$?
    elif [[ -x $root/usr/bin/mkinitcpio && ! -L $root/usr/bin/mkinitcpio ]]; then chroot "$root" /usr/bin/mkinitcpio -P; result=$?
    else result=1; fi
    umount "$root/sys" >/dev/null 2>&1 || result=1
    umount "$root/proc" >/dev/null 2>&1 || result=1
    umount -l "$root/dev" >/dev/null 2>&1 || result=1
    return "$result"
}

rootpxe_deployment_identity_update_machine_id_boot_paths() {
    local root="$1" old_id="$2" new_id="$3" entry file destination
    [[ $old_id =~ ^[0-9a-f]{32}$ && $new_id =~ ^[0-9a-f]{32}$ && $old_id != "$new_id" ]] || return 0
    entry="$root/etc/kernel/entry-token"
    if [[ -e $entry ]]; then
        rootpxe_deployment_identity_safe_target_file "$root" "$entry" || return 1
        if [[ $(tr -d '\r\n' <"$entry") == "$old_id" ]]; then
            printf '%s\n' "$new_id" >"$entry" || return 1
        fi
    fi
    [[ -d $root/boot/loader/entries && ! -L $root/boot/loader/entries ]] || return 0
    rootpxe_deployment_identity_safe_target_dir "$root" boot/loader/entries || return 1
    for file in "$root"/boot/loader/entries/"$old_id"-*.conf; do
        [[ -e $file ]] || continue
        rootpxe_deployment_identity_safe_target_file "$root" "$file" || return 1
        destination="${file/$old_id-/$new_id-}"
        [[ ! -e $destination ]] || return 1
        mv -- "$file" "$destination" || return 1
    done
}

rootpxe_deployment_identity_linux_repair_references_in_root() {
    local root="$1" map result
    rootpxe_deployment_identity_storage_enabled || return 0
    map=$(mktemp /tmp/rootpxe-identity-map.XXXXXX) || return 1
    chmod 600 "$map" || { rm -f -- "$map"; return 1; }
    rootpxe_deployment_identity_linux_reference_map "$rootpxe_deployment_identity_plan_file" >"$map" || { rm -f -- "$map"; return 1; }
    [[ -s $map ]] || { rm -f -- "$map"; return 1; }
    # The physical UUIDs were already changed.  Rewrite the root fstab first,
    # then resolve /boot and /boot/efi through the planned new identifiers.
    rootpxe_deployment_identity_rewrite_linux_references "$root" "$map" || { rm -f -- "$map"; return 1; }
    rootpxe_deployment_identity_mount_linux_boot_filesystems "$root" || { rm -f -- "$map"; return 1; }
    rootpxe_deployment_identity_update_machine_id_boot_paths "$root" "${rootpxe_deployment_identity_old_machine_id:-}" "${rootpxe_deployment_identity_new_machine_id:-}" || { rootpxe_deployment_identity_unmount_linux_boot_filesystems || true; rm -f -- "$map"; return 1; }
    rootpxe_deployment_identity_rewrite_linux_references "$root" "$map"
    result=$?
    [[ $result -eq 0 ]] && rootpxe_deployment_identity_rewrite_linux_grubenv "$root" "$map"
    result=$?
    [[ $result -eq 0 ]] && rootpxe_deployment_identity_rebuild_linux_initramfs "$root"
    result=$?
    if [[ $result -eq 0 ]]; then
        rootpxe_deployment_identity_linux_efi_manifest_file="$root/.rootpxe-offline-identities/$(jq -r '.plan.planId // empty' "$rootpxe_deployment_identity_plan_file")/efi/manifest.json"
        if [[ -e $rootpxe_deployment_identity_linux_efi_manifest_file ]]; then
            jq -e --arg root "$root" '.version == 1 and .stateRoot == $root and (.volumes | type) == "array" and length > 0' "$rootpxe_deployment_identity_linux_efi_manifest_file" >/dev/null || result=1
            [[ $result -ne 0 ]] || rootpxe_deployment_identity_linux_efi_phase "$root" apply || result=1
            [[ $result -ne 0 ]] || rootpxe_deployment_identity_linux_efi_phase "$root" verify || result=1
        fi
    fi
    rootpxe_deployment_identity_unmount_linux_boot_filesystems || result=1
    rm -f -- "$map"
    return $result
}

rootpxe_deployment_identity_windows_unmount_context() {
    local index
    for ((index=${#rootpxe_deployment_identity_windows_mounts[@]}-1; index>=0; index--)); do
        umount "${rootpxe_deployment_identity_windows_mounts[$index]}" >/dev/null 2>&1 || return 1
    done
    rootpxe_deployment_identity_windows_mounts=()
}

rootpxe_deployment_identity_windows_mount_context() {
    local plan="$rootpxe_deployment_identity_plan_file" target fs mount_dir path index=0
    rootpxe_deployment_identity_windows_mounts=()
    rootpxe_deployment_identity_windows_mount_records=()
    rootpxe_deployment_identity_windows_bcd=()
    rootpxe_deployment_identity_windows_xml=()
    rootpxe_deployment_identity_windows_root=""
    [[ -r $plan ]] || return 1
    [[ -n ${rootpxe_deployment_identity_windows_dir:-} ]] || rootpxe_deployment_identity_windows_dir=$(mktemp -d /tmp/rootpxe-windows-identity.XXXXXX) || return 1
    chmod 0700 "$rootpxe_deployment_identity_windows_dir" || return 1
    while IFS= read -r target; do
        target=${target//$'\r'/}
        [[ $target == /dev/* ]] || return 1
        fs=$(blkid -s TYPE -o value "$target" 2>/dev/null | tr -d '\r\n') || return 1
        case "$fs" in ntfs) ;; vfat|fat|fat32) fs=vfat ;; *) continue ;; esac
        mount_dir="$rootpxe_deployment_identity_windows_dir/v$index"; index=$((index+1))
        [[ -d $mount_dir && ! -L $mount_dir ]] || mkdir "$mount_dir" || return 1
        if [[ $fs == ntfs ]]; then ntfs-3g -o rw "$target" "$mount_dir" || return 1
        else mount -t vfat -o rw "$target" "$mount_dir" || return 1; fi
        rootpxe_deployment_identity_windows_mounts+=("$mount_dir")
        rootpxe_deployment_identity_windows_mount_records+=("$target"$'\x1f'"$mount_dir"$'\x1f'"$fs")
        [[ -f "$mount_dir/Windows/System32/config/SYSTEM" && ! -L "$mount_dir/Windows/System32/config/SYSTEM" ]] && {
            [[ -z $rootpxe_deployment_identity_windows_root ]] || return 1
            rootpxe_deployment_identity_windows_root="$mount_dir"
        }
        for path in "$mount_dir/Boot/BCD" "$mount_dir/EFI/Microsoft/Boot/BCD"; do
            [[ -f $path && ! -L $path ]] && rootpxe_deployment_identity_windows_bcd+=("$path")
        done
    done < <(jq -r '.plan.disks[].partitions[]?.targetDevice' "$plan")
    [[ -n $rootpxe_deployment_identity_windows_root && ${#rootpxe_deployment_identity_windows_bcd[@]} -gt 0 ]] || return 1
    path="$rootpxe_deployment_identity_windows_root/Windows/System32/Recovery/ReAgent.xml"
    [[ -f $path && ! -L $path ]] && rootpxe_deployment_identity_windows_xml+=("$path")
    return 0
}

rootpxe_deployment_identity_windows_manifest() {
    local plan="$rootpxe_deployment_identity_plan_file" manifest map='[]' target mount record remainder old_offset old_size old_sector new_offset new_size new_sector source_disk number table binding old_disk new_disk old_part new_part parent bcd_json xml_json efi_var_fs
    [[ -n ${rootpxe_deployment_identity_windows_root:-} && -r $plan ]] || return 1
    while IFS=$'\t' read -r target mount source_disk number table binding old_disk new_disk old_part new_part; do
        target=${target//$'\r'/}; mount=${mount//$'\r'/}; source_disk=${source_disk//$'\r'/}; number=${number//$'\r'/}; table=${table//$'\r'/}; binding=${binding//$'\r'/}; old_disk=${old_disk//$'\r'/}; new_disk=${new_disk//$'\r'/}; old_part=${old_part//$'\r'/}; new_part=${new_part//$'\r'/}
        [[ -n $target && $source_disk =~ ^[1-9][0-9]*$ && $number =~ ^[1-9][0-9]*$ ]] || return 1
        mount=""
        for record in "${rootpxe_deployment_identity_windows_mount_records[@]}"; do
            [[ ${record%%$'\x1f'*} == "$target" ]] && { remainder=${record#*$'\x1f'}; mount=${remainder%%$'\x1f'*}; break; }
        done
        # MSR and other unmountable partitions cannot contain BCD, SYSTEM or
        # ReAgent files, so they are intentionally absent from the file-map.
        [[ -n $mount ]] || continue
        read -r old_sector old_offset old_size < <(rootpxe_deployment_identity_source_partition_geometry "$source_disk" "$number") || return 1
        read -r new_sector new_offset new_size < <(rootpxe_deployment_identity_target_partition_geometry "$target") || return 1
        old_sector=${old_sector//$'\r'/}; old_offset=${old_offset//$'\r'/}; old_size=${old_size//$'\r'/}; new_sector=${new_sector//$'\r'/}; new_offset=${new_offset//$'\r'/}; new_size=${new_size//$'\r'/}
        [[ $old_sector =~ ^[1-9][0-9]*$ && $old_offset =~ ^[0-9]+$ && $old_size =~ ^[1-9][0-9]*$ && $new_sector =~ ^[1-9][0-9]*$ && $new_offset =~ ^[0-9]+$ && $new_size =~ ^[1-9][0-9]*$ ]] || return 1
        map=$(jq -c --arg mount "$mount" --arg partitionTable "$table" --arg diskBinding "$binding" --argjson partitionNumber "$number" --arg oldDiskId "$old_disk" --arg newDiskId "$new_disk" --arg oldPartitionGuid "$old_part" --arg newPartitionGuid "$new_part" --argjson oldOffsetBytes "$old_offset" --argjson newOffsetBytes "$new_offset" --argjson oldSizeBytes "$old_size" --argjson newSizeBytes "$new_size" --argjson oldLogicalSectorBytes "$old_sector" --argjson newLogicalSectorBytes "$new_sector" '. + [{mount:$mount,partitionTable:$partitionTable,diskBinding:$diskBinding,partitionNumber:$partitionNumber,oldDiskId:$oldDiskId,newDiskId:$newDiskId,oldPartitionGuid:$oldPartitionGuid,newPartitionGuid:$newPartitionGuid,oldOffsetBytes:$oldOffsetBytes,newOffsetBytes:$newOffsetBytes,oldSizeBytes:$oldSizeBytes,newSizeBytes:$newSizeBytes,oldLogicalSectorBytes:$oldLogicalSectorBytes,newLogicalSectorBytes:$newLogicalSectorBytes}]' <<<"$map") || return 1
    done < <(jq -r '
      .plan.topology.disks[] as $old | (.plan.disks[] | select(.targetDevice==$old.targetDevice)) as $new |
      $old.partitions[] as $op | ($new.partitions[] | select(.targetDevice==$op.targetDevice)) as $np |
      [$op.targetDevice,$op.targetDevice,$old.sourceDiskNumber,$op.number,$old.partitionTable,$old.targetBinding,$old.oldDiskId,($new.diskGuid // $new.diskSignature // ""),($op.oldPartitionId // ""),($np.partitionGuid // "")] | @tsv' "$plan")
    manifest=$(mktemp /tmp/rootpxe-windows-manifest.XXXXXX) || return 1
    bcd_json=$(jq -cn '$ARGS.positional' --args "${rootpxe_deployment_identity_windows_bcd[@]}") || return 1
    xml_json=$(jq -cn '$ARGS.positional' --args "${rootpxe_deployment_identity_windows_xml[@]}") || return 1
    efi_var_fs="${rootpxe_deployment_identity_efi_var_fs:-/sys/firmware/efi/efivars}"
    jq -cn --arg windowsRoot "$rootpxe_deployment_identity_windows_root" --arg stateRoot "$rootpxe_deployment_identity_windows_root" --arg systemHive "$rootpxe_deployment_identity_windows_root/Windows/System32/config/SYSTEM" --arg efiVarFs "$efi_var_fs" --argjson volumes "$map" --argjson bcdStores "$bcd_json" --argjson reAgentXml "$xml_json" '{version:1,windowsRoot:$windowsRoot,stateRoot:$stateRoot,systemHive:$systemHive,efiVarFs:$efiVarFs,volumes:$volumes,bcdStores:$bcdStores,reAgentXml:$reAgentXml}' >"$manifest" || { rm -f "$manifest"; return 1; }
    chmod 600 "$manifest" || { rm -f "$manifest"; return 1; }
    rootpxe_deployment_identity_windows_manifest_file="$manifest"
}

rootpxe_deployment_identity_windows_repair_phase() {
    local phase="$1" result
    [[ $phase == preflight || $phase == apply || $phase == verify ]] || return 1
    command -v rootpxe-offline-identities >/dev/null 2>&1 || return 1
    result=$(mktemp "/tmp/rootpxe-windows-${phase}.XXXXXX") || return 1
    rm -f "$result"
    rootpxe-offline-identities windows-repair --manifest "$rootpxe_deployment_identity_windows_manifest_file" --plan "$rootpxe_deployment_identity_plan_file" --result "$result" --phase "$phase" || return 1
    jq -e --arg phase "$phase" '.version==1 and .phase==$phase and (if $phase=="preflight" then .storage==false and .bcd==false and .mountedDevices==false else .storage==false and .bcd==true and .mountedDevices==true end)' "$result" >/dev/null || return 1
}

rootpxe_deployment_identity_windows_preflight() {
    rootpxe_deployment_identity_windows_mount_context || { rootpxe_deployment_identity_windows_unmount_context || true; return 1; }
    rootpxe_deployment_identity_windows_manifest || { rootpxe_deployment_identity_windows_unmount_context || true; return 1; }
    rootpxe_deployment_identity_windows_repair_phase preflight && rootpxe_deployment_identity_windows_efi_phase preflight
    local rc=$?
    rootpxe_deployment_identity_windows_unmount_context || rc=1
    return $rc
}

rootpxe_deployment_identity_windows_efi_mount_for_target() {
    local target="$1" record remainder mount fs
    for record in "${rootpxe_deployment_identity_windows_mount_records[@]}"; do
        [[ ${record%%$'\x1f'*} == "$target" ]] || continue
        remainder=${record#*$'\x1f'}; mount=${remainder%%$'\x1f'*}; fs=${remainder#*$'\x1f'}
        [[ $fs == vfat && -d $mount && ! -L $mount ]] || return 1
        printf '%s\n' "$mount"
        return 0
    done
    return 1
}

rootpxe_deployment_identity_windows_efi_esp_mounts() {
    local source_disk=1 number target mount row
    if [[ ${imgType:-} == [Nn] ]]; then
        while IFS= read -r number; do
            number=${number//$'\r'/}; [[ -n $number ]] || continue
            target=$(rootpxe_deployment_identity_linux_esp_target_device "$source_disk" "$number") || return 1
            mount=$(rootpxe_deployment_identity_windows_efi_mount_for_target "${target//$'\r'/}") || return 1
            printf '%s\n' "$mount"
        done < <(rootpxe_deployment_identity_source_esp_targets)
    else
        while IFS=$'\t' read -r source_disk number; do
            source_disk=${source_disk//$'\r'/}; number=${number//$'\r'/}; [[ -n $source_disk && -n $number ]] || continue
            target=$(rootpxe_deployment_identity_linux_esp_target_device "$source_disk" "$number") || return 1
            mount=$(rootpxe_deployment_identity_windows_efi_mount_for_target "${target//$'\r'/}") || return 1
            printf '%s\n' "$mount"
        done < <(rootpxe_deployment_identity_source_esp_targets)
    fi
}

rootpxe_deployment_identity_windows_efi_detected() {
    local mounts mount file
    mounts=$(rootpxe_deployment_identity_windows_efi_esp_mounts) || return 1
    [[ -n $mounts ]] || return 2
    while IFS= read -r mount; do
        # bootmgfw.efi is three levels below EFI.  Check its canonical Windows
        # path explicitly on the controlled vfat ESP; do not recursively scan
        # arbitrary directories.  vfat itself provides case-insensitive lookup.
        [[ -f "$mount/EFI/Microsoft/Boot/bootmgfw.efi" && ! -L "$mount/EFI/Microsoft/Boot/bootmgfw.efi" ]] && return 0
        for file in "$mount"/EFI/*/*.EFI "$mount"/EFI/*/*.efi; do
            [[ -f $file && ! -L $file ]] && return 0
        done
    done <<<"$mounts"
    return 1
}

rootpxe_deployment_identity_windows_efi_fallback_present() {
    local fallback=BOOTX64.EFI mount mounts
    case $(uname -m) in aarch64) fallback=BOOTAA64.EFI ;; i?86) fallback=BOOTIA32.EFI ;; esac
    mounts=$(rootpxe_deployment_identity_windows_efi_esp_mounts) || return 1
    [[ -n $mounts ]] || return 1
    while IFS= read -r mount; do
        [[ -f "$mount/EFI/Boot/$fallback" && ! -L "$mount/EFI/Boot/$fallback" ]] && return 0
    done <<<"$mounts"
    return 1
}

rootpxe_deployment_identity_windows_efi_phase() {
    local phase="$1" result efi_var_fs matched
    [[ $phase == preflight || $phase == apply || $phase == verify ]] || return 1
    # Firmware mode is inferred from the frozen ESP role/type and real loader
    # components on its controlled vfat mount.  PXEOS' boottype is a transport
    # argument (PXE/USB), not the target firmware mode.
    rootpxe_deployment_identity_windows_efi_detected
    case $? in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    efi_var_fs="${rootpxe_deployment_identity_efi_var_fs:-/sys/firmware/efi/efivars}"
    if [[ ! -d $efi_var_fs ]]; then
        rootpxe_deployment_identity_windows_efi_fallback_present
        return $?
    fi
    command -v rootpxe-offline-identities >/dev/null 2>&1 || return 1
    result=$(mktemp "/tmp/rootpxe-windows-efi-${phase}.XXXXXX") || return 1; rm -f "$result"
    rootpxe-offline-identities efi-repair --manifest "$rootpxe_deployment_identity_windows_manifest_file" --plan "$rootpxe_deployment_identity_plan_file" --result "$result" --phase "$phase" || return 1
    if [[ $phase == preflight ]]; then
        jq -e '.version==1 and .efi.available==true and (.efi.matched|type)=="number"' "$result" >/dev/null || return 1
        matched=$(jq -er '.efi.matched' "$result") || return 1
        [[ $matched -gt 0 ]] || rootpxe_deployment_identity_windows_efi_fallback_present
    elif [[ $phase == apply ]]; then
        jq -e '.version==1 and .efi.available==true and ((.efi.updated|type)=="number")' "$result" >/dev/null
    else
        jq -e '.version==1 and .efi.available==true and .efi.verified==true and ((.efi.updated|type)=="number")' "$result" >/dev/null
    fi
}

rootpxe_deployment_identity_windows_repair_efi() {
    rootpxe_deployment_identity_windows_efi_phase apply && rootpxe_deployment_identity_windows_efi_phase verify
}

rootpxe_deployment_identity_windows_apply_repair() {
    rootpxe_deployment_identity_windows_mount_context || { rootpxe_deployment_identity_windows_unmount_context || true; return 1; }
    rootpxe_deployment_identity_windows_repair_phase apply && rootpxe_deployment_identity_windows_repair_phase verify && rootpxe_deployment_identity_windows_repair_efi
    local rc=$?
    rootpxe_deployment_identity_windows_unmount_context || rc=1
    return $rc
}

rootpxe_deployment_identity_report_result() {
    local storage="$1" hostname="$2" machine_id="$3" ssh_host_keys="$4" ssh_login_public_keys="$5" root_password="$6" sysprep="$7" api request response http_code
    rootpxe_deployment_identity_policy_enabled || return 0
    [[ -r ${rootpxe_deployment_identity_plan_file:-} ]] || return 1
    api="${pxeapi:-${web:-}}"; [[ -n $api ]] || return 1
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --arg planId "$(jq -r '.plan.planId' "$rootpxe_deployment_identity_plan_file")" --arg planHash "$(jq -r '.planHash' "$rootpxe_deployment_identity_plan_file")" --argjson attempt "$progress_attempt" --argjson storage "$storage" --argjson hostname "$hostname" --argjson machineId "$machine_id" --argjson sshHostKeys "$ssh_host_keys" --argjson sshLoginPublicKeys "$ssh_login_public_keys" --argjson rootPassword "$root_password" --argjson sysprep "$sysprep" '{taskId:$taskId,token:$token,mac:$mac,planId:$planId,planHash:$planHash,attempt:$attempt,result:{storage:$storage,hostname:$hostname,machineId:$machineId,sshHostKeys:$sshHostKeys,sshLoginPublicKeys:$sshLoginPublicKeys,rootPassword:$rootPassword,sysprep:$sysprep}}') || return 1
    response=$(curl -Lks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-identity-result" 2>/dev/null) || return 1
    http_code=${response##*$'\n'}
    [[ $http_code =~ ^2[0-9][0-9]$ ]]
}

rootpxe_deployment_identity_safe_target_dir() {
    local root="$1" relative="$2" cursor segment
    [[ $root == /* && $relative != /* && $relative != *'..'* && ! -L $root && -d $root ]] || return 1
    cursor="$root"
    IFS=/ read -r -a _rootpxe_identity_segments <<<"$relative"
    for segment in "${_rootpxe_identity_segments[@]}"; do
        [[ -n $segment && $segment != . ]] || continue
        cursor="$cursor/$segment"
        [[ ! -L $cursor ]] || return 1
        if [[ ! -e $cursor ]]; then
            mkdir "$cursor" || return 1
        fi
        [[ -d $cursor && ! -L $cursor ]] || return 1
    done
}

rootpxe_deployment_identity_key_pair_valid() {
    local private="$1" public="$2" rendered rendered_type rendered_material ignored public_type public_material
    [[ -f $private && ! -L $private && -f $public && ! -L $public ]] || return 1
    rendered=$(ssh-keygen -y -f "$private" 2>/dev/null) || return 1
    read -r rendered_type rendered_material ignored <<<"$rendered"
    read -r public_type public_material ignored <"$public"
    [[ $rendered_type =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp256)$ && $rendered_material =~ ^[A-Za-z0-9+/]+={0,2}$ && $public_type == "$rendered_type" && $public_material == "$rendered_material" ]]
}

# Resolve the normal root AuthorizedKeysFile setting without executing a
# target-side service.  Standard non-recursive /etc/ssh Include snippets are
# supported; Match and arbitrary paths fail closed because their effective
# value cannot be established safely in the offline target.
rootpxe_deployment_identity_root_authorized_keys_relative() {
    local root="$1" ssh_dir config file line directive value extra include_path index result=''
    local -a config_files include_matches
    ssh_dir="$root/etc/ssh"; config="$ssh_dir/sshd_config"
    [[ -d $ssh_dir && ! -L $ssh_dir ]] || return 1
    [[ ! -e $config ]] && { printf '%s\n' '.ssh/authorized_keys'; return 0; }
    rootpxe_deployment_identity_safe_target_file "$root" "$config" || return 1
    config_files=("$config")
    for ((index=0; index<${#config_files[@]}; index++)); do
        file=${config_files[$index]}
        rootpxe_deployment_identity_safe_target_file "$root" "$file" || return 1
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%%#*}; line=${line//$'\r'/}
            read -r directive value extra <<<"$line"; directive=${directive,,}
            [[ -n $directive ]] || continue
            case $directive in
                match) return 1 ;;
                authorizedkeysfile)
                    [[ -n $value && -z $extra ]] || return 1
                    # Offline parsing cannot safely reproduce every sshd
                    # Match precedence edge case.  Multiple identical values
                    # are harmless; conflicting values must fail rather than
                    # claim a key was installed at a path sshd may not read.
                    [[ -z $result || $result == "$value" ]] || return 1
                    result=$value
                    ;;
                include)
                    (( index == 0 )) || return 1
                    [[ $value == /etc/ssh/* && -n $value && -z $extra ]] || return 1
                    include_path="$root$value"; include_matches=()
                    while IFS= read -r file; do include_matches+=("$file"); done < <(compgen -G "$include_path" || true)
                    for file in "${include_matches[@]}"; do
                        [[ $file == "$ssh_dir/"* ]] || return 1
                        rootpxe_deployment_identity_safe_target_file "$root" "$file" || return 1
                        config_files+=("$file")
                    done
                    ;;
            esac
        done <"$file"
    done
    [[ -n $result ]] || result='.ssh/authorized_keys'
    [[ $result == '.ssh/authorized_keys' || $result == '.ssh/authorized_keys2' ]] || return 1
    printf '%s\n' "$result"
}

# Read the active HostKey policy, including supported /etc/ssh include files.
# A custom key path would need a separate key algorithm declaration, so reject
# it instead of generating an arbitrary key that sshd may not use.
rootpxe_deployment_identity_collect_ssh_host_keys() {
    local root="$1" ssh_dir config file line directive value extra include_path index
    local -a config_files include_matches
    ssh_dir="$root/etc/ssh"; config="$ssh_dir/sshd_config"
    rootpxe_deployment_identity_ssh_keys=()
    [[ -d $ssh_dir && ! -L $ssh_dir ]] || return 1
    if [[ ! -e $config ]]; then
        rootpxe_deployment_identity_ssh_keys=(rsa ecdsa ed25519)
        return 0
    fi
    [[ -f $config && ! -L $config ]] || return 1
    config_files=("$config")
    # Support the standard, non-recursive /etc/ssh Include form.  Anything
    # else is rejected before modifying keys: it could select a nonstandard
    # HostKey that PXEOS cannot safely regenerate.
    for ((index=0; index<${#config_files[@]}; index++)); do
        file=${config_files[$index]}
        [[ -f $file && ! -L $file ]] || return 1
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%%#*}; line=${line//$'\r'/}
            read -r directive value extra <<<"$line"
            directive=${directive,,}
            [[ -n $directive ]] || continue
            case $directive in
                hostkey)
                    case "$value" in
                        /etc/ssh/ssh_host_rsa_key) rootpxe_deployment_identity_ssh_keys+=(rsa) ;;
                        /etc/ssh/ssh_host_ecdsa_key) rootpxe_deployment_identity_ssh_keys+=(ecdsa) ;;
                        /etc/ssh/ssh_host_ed25519_key) rootpxe_deployment_identity_ssh_keys+=(ed25519) ;;
                        *) return 1 ;;
                    esac
                    ;;
                include)
                    # Included snippets must not recursively include another
                    # file: resolving arbitrary sshd configuration is unsafe
                    # inside the offline target root.
                    (( index == 0 )) || return 1
                    [[ $value == /etc/ssh/* && -n $value && -z $extra ]] || return 1
                    include_path="$root$value"
                    include_matches=()
                    while IFS= read -r file; do include_matches+=("$file"); done < <(compgen -G "$include_path" || true)
                    # An empty standard glob is normal on distributions that
                    # create sshd_config.d before adding any snippets.
                    (( ${#include_matches[@]} > 0 )) || continue
                    for file in "${include_matches[@]}"; do
                        [[ $file == "$ssh_dir/"* && -f $file && ! -L $file ]] || return 1
                        config_files+=("$file")
                    done
                    ;;
            esac
        done <"$file"
    done
    if (( ${#rootpxe_deployment_identity_ssh_keys[@]} == 0 )); then
        rootpxe_deployment_identity_ssh_keys=(rsa ecdsa ed25519)
    fi
    # Ensure one requested standard key per algorithm even when configurations
    # repeat a HostKey line.  Do not touch any unconfigured path.
    rootpxe_deployment_identity_ssh_keys=( $(printf '%s\n' "${rootpxe_deployment_identity_ssh_keys[@]}" | sort -u) )
}

rootpxe_deployment_identity_reuse_linux_system_identity() {
    local root="$1" marker="$2" plan="$3" machine_id key
    [[ -f $marker && ! -L $marker ]] || return 1
    jq -e --arg planHash "$(jq -r '.planHash' "$plan")" '.version == 1 and .planHash == $planHash' "$marker" >/dev/null 2>&1 || return 1
    if jq -e '.systemIdentity.machineId == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        machine_id=$(jq -r '.plan.systemIdentity.machineId // empty' "$plan" 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 1
        [[ $machine_id =~ ^[0-9a-f]{32}$ && -f $root/etc/machine-id && ! -L $root/etc/machine-id ]] || return 1
        [[ $(tr -d '\r\n' <"$root/etc/machine-id") == "$machine_id" ]] || return 1
        rootpxe_deployment_identity_machine_id_result=true
    fi
    if jq -e '.systemIdentity.sshHostKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        rootpxe_deployment_identity_collect_ssh_host_keys "$root" || return 1
        for key in "${rootpxe_deployment_identity_ssh_keys[@]}"; do
            rootpxe_deployment_identity_key_pair_valid "$root/etc/ssh/ssh_host_${key}_key" "$root/etc/ssh/ssh_host_${key}_key.pub" || return 1
        done
        rootpxe_deployment_identity_ssh_host_keys_result=true
    fi
}

rootpxe_deployment_identity_machine_id_dbus_link_target_safe() {
    [[ $1 == /etc/machine-id || $1 == ../../../etc/machine-id ]]
}

rootpxe_deployment_identity_machine_id_dbus_path() {
    local root="$1" path target directory
    [[ $root == /* && -d $root && ! -L $root ]] || return 1
    path="$root/var/lib/dbus/machine-id"
    [[ -e $path || -L $path ]] || return 0
    for directory in "$root/var" "$root/var/lib" "$root/var/lib/dbus"; do [[ -d $directory && ! -L $directory ]] || return 1; done
    if [[ -L $path ]]; then
        target=$(readlink "$path") || return 1
        # These are the standard dbus compatibility links.  Do not open an
        # absolute target through the PXEOS mount namespace; it would resolve
        # to PXEOS rather than the offline target root.
        rootpxe_deployment_identity_machine_id_dbus_link_target_safe "$target"
        return $?
    fi
    [[ -f $path && ! -L $path ]]
}

rootpxe_deployment_identity_linux_system_in_root() {
    local root="$1" plan="${rootpxe_deployment_identity_plan_file:-}" machine_id old_machine_id marker ssh_dir key stage private public machine_tmp dbus_path dbus_tmp marker_tmp
    rootpxe_deployment_identity_linux_policy_enabled || return 0
    [[ -d $root/etc && ! -L $root/etc && -r $plan ]] || return 1
    rootpxe_deployment_identity_safe_target_dir "$root" var/lib/rootpxe || return 1
    marker="$root/var/lib/rootpxe/deployment-identity-v1"
    if rootpxe_deployment_identity_reuse_linux_system_identity "$root" "$marker" "$plan"; then
        # Private login initialization is independently frozen.  A marker from
        # an earlier attempt only proves machine-id/host-key work; it must not
        # skip public-key or root-password application and result reporting.
        rootpxe_deployment_identity_linux_login_in_root "$root"
        return $?
    fi
    machine_id=$(jq -r '.plan.systemIdentity.machineId // empty' "$plan" 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 1
    if jq -e '.systemIdentity.machineId == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        [[ $machine_id =~ ^[0-9a-f]{32}$ && ! -L $root/etc/machine-id ]] || return 1
        old_machine_id=""
        [[ -e $root/etc/machine-id ]] && old_machine_id=$(tr -d '\r\n' <"$root/etc/machine-id")
        machine_tmp=$(mktemp "$root/etc/.machine-id.rootpxe.XXXXXX") || return 1
        printf '%s\n' "$machine_id" >"$machine_tmp" || { rm -f -- "$machine_tmp"; return 1; }
        chmod 0444 "$machine_tmp" && mv -f -- "$machine_tmp" "$root/etc/machine-id" || { rm -f -- "$machine_tmp"; return 1; }
        dbus_path="$root/var/lib/dbus/machine-id"
        rootpxe_deployment_identity_machine_id_dbus_path "$root" || return 1
        if [[ -e $dbus_path && ! -L $dbus_path ]]; then
            dbus_tmp=$(mktemp "$root/var/lib/dbus/.machine-id.rootpxe.XXXXXX") || return 1
            printf '%s\n' "$machine_id" >"$dbus_tmp" || { rm -f -- "$dbus_tmp"; return 1; }
            chmod 0444 "$dbus_tmp" && mv -f -- "$dbus_tmp" "$dbus_path" || { rm -f -- "$dbus_tmp"; return 1; }
        fi
        [[ $(tr -d '\r\n' <"$root/etc/machine-id") == "$machine_id" ]] || return 1
        rootpxe_deployment_identity_old_machine_id="$old_machine_id"
        rootpxe_deployment_identity_new_machine_id="$machine_id"
        rootpxe_deployment_identity_machine_id_result=true
    fi
    if jq -e '.systemIdentity.sshHostKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        ssh_dir="$root/etc/ssh"; [[ -d $ssh_dir && ! -L $ssh_dir ]] || return 1
        rootpxe_deployment_identity_collect_ssh_host_keys "$root" || return 1
        stage=$(mktemp -d "$ssh_dir/.rootpxe-hostkeys.XXXXXX") || return 1
        chmod 0700 "$stage" || { rm -rf -- "$stage"; return 1; }
        for key in "${rootpxe_deployment_identity_ssh_keys[@]}"; do
            private="$stage/ssh_host_${key}_key"
            case $key in rsa) ssh-keygen -q -t rsa -b 3072 -N '' -f "$private" ;; ecdsa) ssh-keygen -q -t ecdsa -b 256 -N '' -f "$private" ;; ed25519) ssh-keygen -q -t ed25519 -N '' -f "$private" ;; *) rm -rf -- "$stage"; return 1;; esac || { rm -rf -- "$stage"; return 1; }
            rootpxe_deployment_identity_key_pair_valid "$private" "$private.pub" || { rm -rf -- "$stage"; return 1; }
        done
        for key in "${rootpxe_deployment_identity_ssh_keys[@]}"; do
            private="$ssh_dir/ssh_host_${key}_key"; public="$private.pub"
            [[ ! -e $private || ( -f $private && ! -L $private ) ]] || { rm -rf -- "$stage"; return 1; }
            [[ ! -e $public || ( -f $public && ! -L $public ) ]] || { rm -rf -- "$stage"; return 1; }
        done
        # All replacements are prepared and validated before an existing key is
        # replaced.  A power loss after one rename leaves a marker absent; the
        # next same-plan attempt regenerates a complete, matching set.
        for key in "${rootpxe_deployment_identity_ssh_keys[@]}"; do
            mv -f -- "$stage/ssh_host_${key}_key" "$ssh_dir/ssh_host_${key}_key" || { rm -rf -- "$stage"; return 1; }
            mv -f -- "$stage/ssh_host_${key}_key.pub" "$ssh_dir/ssh_host_${key}_key.pub" || { rm -rf -- "$stage"; return 1; }
            chmod 0600 "$ssh_dir/ssh_host_${key}_key" && chmod 0644 "$ssh_dir/ssh_host_${key}_key.pub" || { rm -rf -- "$stage"; return 1; }
        done
        rmdir "$stage" >/dev/null 2>&1 || true
        for key in "${rootpxe_deployment_identity_ssh_keys[@]}"; do rootpxe_deployment_identity_key_pair_valid "$ssh_dir/ssh_host_${key}_key" "$ssh_dir/ssh_host_${key}_key.pub" || return 1; done
        rootpxe_deployment_identity_ssh_host_keys_result=true
    fi
	rootpxe_deployment_identity_linux_login_in_root "$root" || return 1
    [[ ! -e $marker || ( -f $marker && ! -L $marker ) ]] || return 1
    marker_tmp=$(mktemp "$root/var/lib/rootpxe/.deployment-identity-v1.XXXXXX") || return 1
    jq -cn --arg planHash "$(jq -r '.planHash' "$plan")" --argjson machineId "${rootpxe_deployment_identity_machine_id_result:-false}" --argjson sshHostKeys "${rootpxe_deployment_identity_ssh_host_keys_result:-false}" '{version:1,planHash:$planHash,machineId:$machineId,sshHostKeys:$sshHostKeys}' >"$marker_tmp" || { rm -f -- "$marker_tmp"; return 1; }
    chmod 0600 "$marker_tmp" && mv -f -- "$marker_tmp" "$marker" || { rm -f -- "$marker_tmp"; return 1; }
}

# PXEOS cannot apply the target SELinux policy to a file from its own mount
# namespace.  Preserve metadata for replacements and, for an enabled target
# policy, request the distribution's first-boot relabel for new files.
rootpxe_deployment_identity_request_selinux_relabel() {
    local root="$1" config="$1/etc/selinux/config" mode marker="$1/.autorelabel" service
    [[ -d $root && ! -L $root ]] || return 1
    [[ ! -e $config ]] && return 0
    rootpxe_deployment_identity_safe_target_file "$root" "$config" || return 1
    mode=$(awk -F= 'BEGIN{IGNORECASE=1} /^[[:space:]]*SELINUX[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print tolower($2); exit}' "$config") || return 1
    case $mode in
        disabled|'') return 0 ;;
        enforcing|permissive) ;;
        *) return 1 ;;
    esac
    # Do not assume that every enabled policy honours .autorelabel.  Rocky/RHEL
    # images expose the relabel service (or fixfiles); unknown targets fail
    # before changing credentials rather than reporting a false success.
    service="$root/usr/lib/systemd/system/selinux-autorelabel-mark.service"
    [[ -x $root/sbin/fixfiles || -x $root/usr/sbin/fixfiles || ( -f $service && ! -L $service ) ]] || return 1
    if [[ -e $marker ]]; then
        [[ -f $marker && ! -L $marker ]] || return 1
        return 0
    fi
    : >"$marker" || return 1
    chmod 600 "$marker" || return 1
    [[ -f $marker && ! -L $marker ]]
}

rootpxe_deployment_identity_linux_login_in_root() {
	local root="$1" private="${rootpxe_deployment_initialization_private_file:-}" home home_relative authorized authorized_relative parent keys_tmp line key_blob hash shadow shadow_tmp root_line root_hash today ssh_config last_byte
	[[ -r $private && ! -L $private ]] || { rootpxe_deployment_identity_private_enabled || return 0; return 1; }
	if jq -e '.systemIdentity.sshLoginPublicKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
		rootpxe_deployment_identity_safe_target_file "$root" "$root/etc/passwd" || return 1
		home=$(awk -F: '$1=="root" {print $6; exit}' "$root/etc/passwd" 2>/dev/null) || return 1
		[[ $home == /* && $home != / && $home != *".."* ]] || return 1
		home_relative=${home#/}
		authorized_relative='.ssh/authorized_keys'
		authorized_relative=$(rootpxe_deployment_identity_root_authorized_keys_relative "$root") || return 1
		# Do not claim success for a server whose root login uses an arbitrary
		# AuthorizedKeysFile path or an Include file we cannot safely resolve.
		[[ $authorized_relative == '.ssh/authorized_keys' || $authorized_relative == '.ssh/authorized_keys2' ]] || return 1
		authorized="$root$home/$authorized_relative"
		parent=$(dirname "$authorized")
		rootpxe_deployment_identity_safe_target_dir "$root" "$home_relative/.ssh" || return 1
		[[ -d "$root$home" && ! -L "$root$home" && -d $parent && ! -L $parent && ( ! -e $authorized || ( -f "$authorized" && ! -L "$authorized" ) ) ]] || return 1
		[[ ! -e $authorized ]] || rootpxe_deployment_identity_safe_target_file "$root" "$authorized" || return 1
		rootpxe_deployment_identity_request_selinux_relabel "$root" || return 1
		chmod 0700 "$parent" || return 1
		keys_tmp=$(mktemp "$parent/.authorized_keys.rootpxe.XXXXXX") || return 1
		[[ ! -e $authorized ]] || cp -a -- "$authorized" "$keys_tmp" || { rm -f -- "$keys_tmp"; return 1; }
		last_byte=$(tail -c 1 "$keys_tmp" 2>/dev/null | od -An -tu1 | tr -d '[:space:]')
		if [[ -s $keys_tmp && $last_byte != 10 ]]; then
			printf '\n' >>"$keys_tmp" || { rm -f -- "$keys_tmp"; return 1; }
		fi
		while IFS= read -r line; do
			[[ -n $line && ${#line} -le 16384 ]] || { rm -f -- "$keys_tmp"; return 1; }
			case "$line" in
				ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
				*) rm -f -- "$keys_tmp"; return 1 ;;
			esac
			key_blob=$(awk '{print $2; exit}' <<<"$line")
			[[ $key_blob =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || { rm -f -- "$keys_tmp"; return 1; }
			awk -v blob="$key_blob" '$0 !~ /^[[:space:]]*#/ {for (i=1;i<NF;i++) if ($i ~ /^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)$/ && $(i+1)==blob) found=1} END{exit found?0:1}' "$keys_tmp" || printf '%s\n' "$line" >>"$keys_tmp" || { rm -f -- "$keys_tmp"; return 1; }
		done < <(jq -r '.sshLoginPublicKeys[]' "$private")
		[[ -s $keys_tmp ]] || { rm -f -- "$keys_tmp"; return 1; }
		chmod 0600 "$keys_tmp" && mv -f -- "$keys_tmp" "$authorized" || { rm -f -- "$keys_tmp"; return 1; }
		awk 'NF >= 2 {ok=1} END{exit ok?0:1}' "$authorized" || return 1
		command -v restorecon >/dev/null 2>&1 && restorecon "$parent" "$authorized" >/dev/null 2>&1 || true
		rootpxe_deployment_identity_ssh_login_public_keys_result=true
	fi
	if jq -e '.systemIdentity.rootPassword == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
		hash=$(jq -r '.rootPasswordHash' "$private" 2>/dev/null) || return 1
		rootpxe_deployment_identity_safe_target_file "$root" "$root/etc/shadow" || return 1
		rootpxe_deployment_identity_request_selinux_relabel "$root" || return 1
		[[ $hash == '$6$'* && ${#hash} -le 512 ]] || return 1
		root_line=$(awk -F: '$1=="root" {count++; line=$0} END {if(count==1) print line; else exit 1}' "$root/etc/shadow") || return 1
		[[ -n $root_line ]] || return 1
		root_hash=${root_line#*:}; root_hash=${root_hash%%:*}
		# Keep account expiry and the other aging controls untouched. A new hash
		# needs a current last-change day so images with 0 do not force an
		# immediate password change on the first login. A retried frozen hash
		# preserves the first successful day and remains idempotent.
		if [[ $root_hash == "$hash" ]]; then
			awk -F: -v replacement="$hash" '$1=="root" && $2==replacement {ok=1} END {exit ok?0:1}' "$root/etc/shadow" || return 1
			rootpxe_deployment_identity_root_password_result=true
			return 0
		fi
		today=$(( $(date -u +%s) / 86400 )) || return 1
		[[ $today =~ ^[1-9][0-9]*$ ]] || return 1
		shadow_tmp=$(mktemp "$root/etc/.shadow.rootpxe.XXXXXX") || return 1
		cp -a -- "$root/etc/shadow" "$shadow_tmp" || { rm -f -- "$shadow_tmp"; return 1; }
		awk -F: -v replacement="$hash" -v last_change="$today" 'BEGIN{OFS=FS} $1=="root" {$2=replacement; $3=last_change} {print}' "$root/etc/shadow" >"$shadow_tmp.new" || { rm -f -- "$shadow_tmp" "$shadow_tmp.new"; return 1; }
		cat "$shadow_tmp.new" >"$shadow_tmp" || { rm -f -- "$shadow_tmp" "$shadow_tmp.new"; return 1; }
		rm -f -- "$shadow_tmp.new"
		awk -F: -v replacement="$hash" -v last_change="$today" '$1=="root" && $2==replacement && $3==last_change {ok=1} END {exit ok?0:1}' "$shadow_tmp" || { rm -f -- "$shadow_tmp"; return 1; }
		mv -f -- "$shadow_tmp" "$root/etc/shadow" || { rm -f -- "$shadow_tmp"; return 1; }
		command -v restorecon >/dev/null 2>&1 && restorecon "$root/etc/shadow" >/dev/null 2>&1 || true
		awk -F: -v replacement="$hash" -v last_change="$today" '$1=="root" && $2==replacement && $3==last_change {ok=1} END {exit ok?0:1}' "$root/etc/shadow" || return 1
		rootpxe_deployment_identity_root_password_result=true
	fi
	return 0
}
