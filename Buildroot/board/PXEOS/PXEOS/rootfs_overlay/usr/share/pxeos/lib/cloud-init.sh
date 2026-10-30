#!/bin/bash
# 仅离线安装原生 NoCloud seed 与数据源配置；不执行目标程序或任何配置正文。
# SELinux 由目标系统/镜像准备负责关闭；PXEOS 不识别、修改或校验其策略和标签。

rootpxe_ci_stat() { stat -c '%u:%g:%a:%h' -- "$1"; }
rootpxe_ci_is_root() { [[ $EUID == 0 ]]; }
rootpxe_ci_executable() { [[ -x $1 ]]; }
rootpxe_ci_hash() {
    local value
    value=$(sha256sum -- "$1" 2>/dev/null) || return 1
    printf '%s\n' "${value%%[[:space:]]*}"
}
rootpxe_ci_metadata_safe() {
    local path="$1" kind="$2" exact="${3:-}" info uid gid mode links
    [[ ! -L $path ]] || return 1
    case $kind in directory) [[ -d $path ]];; file) [[ -f $path ]];; *) return 1;; esac || return 1
    info=$(rootpxe_ci_stat "$path") || return 1
    IFS=: read -r uid gid mode links <<<"$info"
    [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ -z $exact || $mode == "$exact" ]] || return 1
    [[ $kind != file || $links == 1 ]]
}

# 按目标根解析每一个组件；绝对链接重新从目标根开始，最多40次链接。
# 不使用宿主 readlink -f 解析镜像路径，也不允许 .. 越过目标根。
rootpxe_ci_resolve_target() {
    local root="$1" requested="$2" kind="$3" pending component cursor link info count=0
    local -a resolved=()
    [[ $requested == /* && -d $root && ! -L $root ]] || return 1
    rootpxe_ci_metadata_safe "$root" directory || return 1
    pending="${requested#/}"
    while [[ -n $pending ]]; do
        component="${pending%%/*}"
        if [[ $pending == */* ]]; then pending="${pending#*/}"; else pending=""; fi
        case $component in
            ''|.) continue;;
            ..) (( ${#resolved[@]} > 0 )) || return 1; unset 'resolved[${#resolved[@]}-1]'; continue;;
        esac
        [[ $component != *$'\n'* && $component != *$'\r'* ]] || return 1
        cursor="$root"
        for link in "${resolved[@]}"; do cursor="$cursor/$link"; done
        cursor="$cursor/$component"
        if [[ -L $cursor ]]; then
            info=$(rootpxe_ci_stat "$cursor") || return 1
            [[ $info == 0:0:* ]] || return 1
            count=$((count + 1)); (( count <= 40 )) || return 1
            link=$(readlink -- "$cursor") || return 1
            [[ -n $link && $link != *$'\n'* && $link != *$'\r'* ]] || return 1
            if [[ $link == /* ]]; then resolved=(); link="${link#/}"; fi
            pending="$link${pending:+/$pending}"
        else
            if [[ -n $pending ]]; then rootpxe_ci_metadata_safe "$cursor" directory || return 1
            else rootpxe_ci_metadata_safe "$cursor" "$kind" || return 1; fi
            resolved+=("$component")
        fi
    done
    cursor="$root"
    for component in "${resolved[@]}"; do cursor="$cursor/$component"; done
    rootpxe_ci_metadata_safe "$cursor" "$kind" || return 1
    printf '%s\n' "$cursor"
}

rootpxe_ci_safe_write_directory() {
    local root="$1" relative="$2" create="${3:-no}" cursor component
    cursor="$root"
    local -a components
    rootpxe_ci_metadata_safe "$root" directory || return 1
    IFS=/ read -r -a components <<<"${relative#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || return 1
        cursor="$cursor/$component"
        if [[ ! -e $cursor && ! -L $cursor && $create == yes ]]; then
            mkdir -m 755 -- "$cursor" || return 1
            chown 0:0 -- "$cursor" || return 1
        fi
        rootpxe_ci_metadata_safe "$cursor" directory || return 1
    done
}

rootpxe_ci_inode() { stat -c '%d:%i' -- "$1"; }
rootpxe_cloud_init_policy_enabled() {
    [[ ${taskType:-} == deploy && ${osid:-} == 50 && -r ${deploymentIdentityPolicyFile:-} ]] &&
        jq -e '.version == 1 and .cloudInit == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}
rootpxe_cloud_init_configured() { [[ -n ${cloudInitUserDataFile:-} || -n ${cloudInitMetaDataFile:-} || -n ${cloudInitNetworkConfigFile:-} || -n ${cloudInitVendorDataFile:-} ]]; }
rootpxe_ci_private_file_valid() {
    local file="$1" hash="$2" inode="$3" pid="$4" kind="$5" info owner group mode links
    case $kind in
        user-data) [[ $file =~ ^/tmp/rootpxe-cloud-init\.[A-Za-z0-9]{6}$ ]];;
        meta-data) [[ $file =~ ^/tmp/rootpxe-cloud-meta\.[A-Za-z0-9]{6}$ ]];;
        network-config) [[ $file =~ ^/tmp/rootpxe-cloud-network\.[A-Za-z0-9]{6}$ ]];;
        vendor-data) [[ $file =~ ^/tmp/rootpxe-cloud-vendor\.[A-Za-z0-9]{6}$ ]];;
        *) return 1;;
    esac || return 1
    [[ -f $file && ! -L $file && -O $file ]] || return 1
    info=$(rootpxe_ci_stat "$file") || return 1
    IFS=: read -r owner group mode links <<<"$info"
    [[ $owner == "$EUID" && $mode == 600 && $links == 1 && $pid == "$BASHPID" && $(rootpxe_ci_inode "$file") == "$inode" ]] || return 1
    [[ $hash =~ ^[0-9a-f]{64}$ && $(rootpxe_ci_hash "$file") == "$hash" && $(wc -c <"$file") -le 65536 ]]
}
rootpxe_cloud_init_private_valid() {
    [[ ${rootpxe_cloud_init_valid_pid:-} == "$BASHPID" ]] || return 1
    rootpxe_ci_private_file_valid "${cloudInitUserDataFile:-}" "${cloudInitUserDataSha256:-}" "${rootpxe_cloud_init_private_inode:-}" "${rootpxe_cloud_init_private_pid:-}" user-data || return 1
    rootpxe_ci_private_file_valid "${cloudInitMetaDataFile:-}" "${cloudInitMetaDataSha256:-}" "${rootpxe_cloud_init_meta_private_inode:-}" "${rootpxe_cloud_init_meta_private_pid:-}" meta-data || return 1
    [[ -s $cloudInitMetaDataFile ]] || return 1
    if [[ -n ${cloudInitNetworkConfigFile:-} || -n ${cloudInitNetworkConfigSha256:-} ]]; then
        rootpxe_ci_private_file_valid "${cloudInitNetworkConfigFile:-}" "${cloudInitNetworkConfigSha256:-}" "${rootpxe_cloud_init_network_private_inode:-}" "${rootpxe_cloud_init_network_private_pid:-}" network-config || return 1
        [[ -s $cloudInitNetworkConfigFile ]] || return 1
    fi
    if [[ -n ${cloudInitVendorDataFile:-} || -n ${cloudInitVendorDataSha256:-} ]]; then
        rootpxe_ci_private_file_valid "${cloudInitVendorDataFile:-}" "${cloudInitVendorDataSha256:-}" "${rootpxe_cloud_init_vendor_private_inode:-}" "${rootpxe_cloud_init_vendor_private_pid:-}" vendor-data || return 1
        [[ -s $cloudInitVendorDataFile ]] || return 1
    fi
    return 0
}
rootpxe_ci_private_names() {
    case $1 in
        user-data) ci_file_var=cloudInitUserDataFile; ci_hash_var=cloudInitUserDataSha256; ci_inode_var=rootpxe_cloud_init_private_inode; ci_pid_var=rootpxe_cloud_init_private_pid; ci_field=cloudInitUserData; ci_prefix=/tmp/rootpxe-cloud-init.XXXXXX;;
        meta-data) ci_file_var=cloudInitMetaDataFile; ci_hash_var=cloudInitMetaDataSha256; ci_inode_var=rootpxe_cloud_init_meta_private_inode; ci_pid_var=rootpxe_cloud_init_meta_private_pid; ci_field=cloudInitMetaData; ci_prefix=/tmp/rootpxe-cloud-meta.XXXXXX;;
        network-config) ci_file_var=cloudInitNetworkConfigFile; ci_hash_var=cloudInitNetworkConfigSha256; ci_inode_var=rootpxe_cloud_init_network_private_inode; ci_pid_var=rootpxe_cloud_init_network_private_pid; ci_field=cloudInitNetworkConfig; ci_prefix=/tmp/rootpxe-cloud-network.XXXXXX;;
        vendor-data) ci_file_var=cloudInitVendorDataFile; ci_hash_var=cloudInitVendorDataSha256; ci_inode_var=rootpxe_cloud_init_vendor_private_inode; ci_pid_var=rootpxe_cloud_init_vendor_private_pid; ci_field=cloudInitVendorData; ci_prefix=/tmp/rootpxe-cloud-vendor.XXXXXX;;
        *) return 1;;
    esac
}
rootpxe_cloud_init_cleanup_private() {
    local result=0 kind file ci_file_var ci_hash_var ci_inode_var ci_pid_var ci_field ci_prefix
    # 整份快照的有效标记不可继承；先失效，再独立清理各文件并保留失败proof。
    unset rootpxe_cloud_init_valid_pid
    for kind in user-data meta-data network-config vendor-data; do
        rootpxe_ci_private_names "$kind" || return 1
        file=${!ci_file_var-}
        if [[ -n $file ]]; then
            if rootpxe_ci_private_file_valid "$file" "${!ci_hash_var-}" "${!ci_inode_var-}" "${!ci_pid_var-}" "$kind" && rm -f -- "$file"; then
                unset "$ci_file_var" "$ci_hash_var" "$ci_inode_var" "$ci_pid_var"
            else result=1; fi
        else unset "$ci_hash_var" "$ci_inode_var" "$ci_pid_var"; fi
    done
    return "$result"
}
rootpxe_ci_capture_private_field() {
    local document="$1" kind="$2" expected="$3" file inode actual result=0
    local ci_file_var ci_hash_var ci_inode_var ci_pid_var ci_field ci_prefix
    rootpxe_ci_private_names "$kind" || return 1
    file=$(mktemp "$ci_prefix") || return 1
    inode=$(rootpxe_ci_inode "$file") || { rm -f -- "$file"; return 1; }
    printf -v "$ci_file_var" '%s' "$file"
    printf -v "$ci_inode_var" '%s' "$inode"
    printf -v "$ci_pid_var" '%s' "$BASHPID"
    export -n "$ci_inode_var" "$ci_pid_var"
    chmod 600 "$file" && jq -j --arg field "$ci_field" '.[$field]' <<<"$document" >"$file" || result=1
    actual=$(rootpxe_ci_hash "$file") || return 1
    # 解析失败也按实际字节保留可清理proof；只有全字段吻合后才设置有效标记。
    printf -v "$ci_hash_var" '%s' "$actual"
    rootpxe_ci_private_file_valid "$file" "$actual" "$inode" "$BASHPID" "$kind" || return 1
    [[ $result -eq 0 && $actual == "$expected" ]]
}
rootpxe_apply_json_cloud_init() {
    local document="$1" hash meta_hash network_hash vendor_hash
    rootpxe_cloud_init_cleanup_private || return 1
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$document" || return 1
    jq -e '[has("cloudInitUserData"),has("cloudInitUserDataSha256"),has("cloudInitMetaData"),has("cloudInitMetaDataSha256"),has("cloudInitNetworkConfig"),has("cloudInitNetworkConfigSha256"),has("cloudInitVendorData"),has("cloudInitVendorDataSha256"),has("cloudInitInstanceId"),has("cloudInitHostname")] | any' >/dev/null 2>&1 <<<"$document" || return 0
    [[ ${taskType:-} == deploy && ${osid:-} == 50 ]] || return 1
    jq -e '.type == "deploy" and (.osid | type == "number") and .osid == 50 and
      (has("cloudInitInstanceId") | not) and (has("cloudInitHostname") | not) and
      (.cloudInitUserData | type == "string" and utf8bytelength <= 65536 and (contains("\u0000") | not)) and
      (.cloudInitUserDataSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.cloudInitMetaData | type == "string" and utf8bytelength > 0 and utf8bytelength <= 65536 and (contains("\u0000") | not)) and
      (.cloudInitMetaDataSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.cloudInitNetworkConfig | type == "string" and utf8bytelength <= 65536 and (contains("\u0000") | not)) and
      (.cloudInitNetworkConfigSha256 | type == "string") and
      (if .cloudInitNetworkConfig == "" then .cloudInitNetworkConfigSha256 == "" else (.cloudInitNetworkConfigSha256 | test("^[0-9a-f]{64}$")) end) and
      (.cloudInitVendorData | type == "string" and utf8bytelength <= 65536 and (contains("\u0000") | not)) and
      (.cloudInitVendorDataSha256 | type == "string") and
      (if .cloudInitVendorData == "" then .cloudInitVendorDataSha256 == "" else (.cloudInitVendorDataSha256 | test("^[0-9a-f]{64}$")) end)' >/dev/null 2>&1 <<<"$document" || return 1
    hash=$(jq -r '.cloudInitUserDataSha256' <<<"$document") || return 1
    meta_hash=$(jq -r '.cloudInitMetaDataSha256' <<<"$document") || return 1
    network_hash=$(jq -r '.cloudInitNetworkConfigSha256' <<<"$document") || return 1
    vendor_hash=$(jq -r '.cloudInitVendorDataSha256' <<<"$document") || return 1
    if ! rootpxe_ci_capture_private_field "$document" user-data "$hash" ||
       ! rootpxe_ci_capture_private_field "$document" meta-data "$meta_hash" ||
       { [[ -n $network_hash ]] && ! rootpxe_ci_capture_private_field "$document" network-config "$network_hash"; } ||
       { [[ -n $vendor_hash ]] && ! rootpxe_ci_capture_private_field "$document" vendor-data "$vendor_hash"; }; then
        rootpxe_cloud_init_cleanup_private || return 1
        return 1
    fi
    rootpxe_cloud_init_valid_pid=$BASHPID
    export -n rootpxe_cloud_init_valid_pid
    export cloudInitUserDataFile cloudInitUserDataSha256 cloudInitMetaDataFile cloudInitMetaDataSha256 cloudInitNetworkConfigFile cloudInitNetworkConfigSha256 cloudInitVendorDataFile cloudInitVendorDataSha256
    if ! rootpxe_cloud_init_private_valid; then rootpxe_cloud_init_cleanup_private || return 1; return 1; fi
}

rootpxe_ci_reject() { rootpxe_cloud_init_error="$2"; return "$1"; }
rootpxe_ci_check_prerequisites() {
    local root="$1" binary path dir file link
    rootpxe_ci_metadata_safe "$root" directory || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    [[ -d $root/etc/cloud && -f $root/etc/cloud/cloud.cfg ]] || { rootpxe_ci_reject 41 cloud_init_not_installed; return $?; }
    rootpxe_ci_safe_write_directory "$root" /etc/cloud && rootpxe_ci_metadata_safe "$root/etc/cloud/cloud.cfg" file || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    [[ -e $root/usr/bin/cloud-init || -L $root/usr/bin/cloud-init ]] || { rootpxe_ci_reject 41 cloud_init_not_installed; return $?; }
    binary=$(rootpxe_ci_resolve_target "$root" /usr/bin/cloud-init file) || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    rootpxe_ci_executable "$binary" || { rootpxe_ci_reject 41 cloud_init_not_installed; return $?; }
    [[ ! -e $root/etc/cloud/cloud-init.disabled && ! -L $root/etc/cloud/cloud-init.disabled ]] || { rootpxe_ci_reject 42 cloud_init_explicitly_disabled; return $?; }
    for dir in /etc/systemd/system /run/systemd/system; do
        [[ ! -e $root$dir && ! -L $root$dir ]] && continue
        rootpxe_ci_safe_write_directory "$root" "$dir" || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
        for file in cloud-init-local.service cloud-init-network.service cloud-init.service cloud-config.service cloud-final.service cloud-init.target; do
            path="$root$dir/$file"
            [[ -e $path || -L $path ]] || continue
            if [[ -L $path ]]; then
                [[ $(rootpxe_ci_stat "$path") == 0:0:* ]] || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
                link=$(readlink -- "$path") || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
                [[ $link != /dev/null ]] || { rootpxe_ci_reject 42 cloud_init_explicitly_disabled; return $?; }
                rootpxe_ci_resolve_target "$root" "$dir/$file" file >/dev/null || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
            else rootpxe_ci_metadata_safe "$path" file || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }; fi
        done
    done
    # 原生 YAML 合并、模块与启动启用状态由镜像管理员验证。
    return 0
}
rootpxe_ci_readonly_preflight() {
    local root="$1" path
    rootpxe_ci_check_prerequisites "$root" || return $?
    for path in /etc/cloud/cloud.cfg.d /var /var/lib /var/lib/cloud /var/lib/cloud/seed /var/lib/cloud/seed/nocloud; do
        [[ -e $root$path || -L $root$path ]] || continue
        rootpxe_ci_safe_write_directory "$root" "$path" || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    done
    for path in /etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg /var/lib/cloud/seed/nocloud/user-data /var/lib/cloud/seed/nocloud/meta-data /var/lib/cloud/seed/nocloud/network-config /var/lib/cloud/seed/nocloud/vendor-data; do
        [[ -e $root$path || -L $root$path ]] || continue
        rootpxe_ci_metadata_safe "$root$path" file || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    done
}

# fstab 源只做数据解析；只有全部 PV/分区属于当前许可集合才可挂载。
rootpxe_ci_device_is_block() { [[ $1 == /dev/* && -b $1 ]]; }
rootpxe_ci_fstab_device() {
    local source="$1" identifier device
    case $source in
        UUID=*|PARTUUID=*)
            identifier=${source#*=}
            if [[ $identifier == \"*\" ]]; then identifier=${identifier:1:${#identifier}-2}; fi
            [[ $identifier =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
            if [[ $source == UUID=* ]]; then device=$(blkid -U "$identifier" 2>/dev/null) || return 1; else device=$(blkid -t "PARTUUID=$identifier" -o device 2>/dev/null) || return 1; fi
            ;;
        /dev/*) device="$source";;
        *) return 1;;
    esac
    [[ $device == /dev/* && $device != *$'\n'* && $device != *$'\r'* ]] || return 1
    device=$(readlink -f -- "$device") || return 1
    rootpxe_ci_device_is_block "$device" || return 1
    printf '%s\n' "$device"
}
rootpxe_ci_device_permitted() {
    local device="$1" disk part resolved rows lv name uuid match=0 selected_name="" selected_uuid="" owned
    for disk in ${rootpxe_cloud_init_allowed_disks:-}; do
        rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1
        getPartitions "$disk"
        for part in ${parts:-}; do
            resolved=$(readlink -f -- "$part") || return 1
            [[ $resolved != "$device" ]] || return 0
        done
    done
    rows=$(rootpxe_lvm_native lvs --reportformat json -o lv_path,vg_name,vg_uuid 2>/dev/null) || return 1
    rootpxe_lvm_json_jq -e '.report|type=="array" and length==1 and (.[0].lv|type=="array") and all(.[0].lv[]; (.lv_path|type=="string") and (.vg_name|type=="string") and (.vg_uuid|type=="string"))' <<<"$rows" >/dev/null || return 1
    while IFS=$'\t' read -r lv name uuid; do
        [[ -n $lv && -n $name && -n $uuid ]] || return 1
        resolved=$(readlink -f -- "$lv") || return 1
        [[ $resolved == "$device" ]] || continue
        if [[ $match -gt 0 ]]; then [[ $name == "$selected_name" && $uuid == "$selected_uuid" ]] || return 1; else selected_name="$name"; selected_uuid="$uuid"; fi
        match=$((match + 1))
    done < <(rootpxe_lvm_json_jq -r '.report[0].lv[]|[.lv_path,.vg_name,.vg_uuid]|@tsv' <<<"$rows")
    [[ $match -gt 0 && -n ${rootpxe_cloud_init_allowed_disks:-} ]] || return 1
    disk=${rootpxe_cloud_init_allowed_disks%% *}
    rootpxe_linux_validate_vg_target_pvs "$disk" "$selected_uuid" || return 1
    owned=$(rootpxe_linux_activate_vg_if_needed "$disk" "$selected_name" "$selected_uuid") || return 1
    if [[ $owned == yes ]]; then ci_vg_names+=("$selected_name"); ci_vg_uuids+=("$selected_uuid"); ci_vg_owned+=("yes"); fi
}
rootpxe_ci_mount_matches() {
    local path="$1" device="$2" mode="$3" actual expected options
    device=$(readlink -f -- "$device") || return 1
    rootpxe_ci_device_is_block "$device" || return 1
    actual=$(stat -c %d -- "$path") && expected=$(stat -c %r -- "$device") || return 1
    [[ $actual == "$expected" ]] || return 1
    options=$(findmnt -rn --mountpoint "$path" -o OPTIONS) || return 1
    [[ ,$options, == *",$mode,"* ]]
}
rootpxe_ci_mount_fstab() {
    local root="$1" requested="$2" mode="$3" source target declared options rest count=0 selected_source="" selected_fs="" device fs mount_options path
    [[ $requested == /var || $requested == /usr ]] || return 1
    rootpxe_ci_safe_write_directory "$root" "$requested" || return 1
    if [[ $requested == /var ]]; then
        for path in /var/lib /var/lib/cloud /var/lib/cloud/seed /var/lib/cloud/seed/nocloud; do
            mountpoint -q "$root$path" 2>/dev/null && return 1
        done
    fi
    if [[ -e $root/etc/fstab || -L $root/etc/fstab ]]; then
        rootpxe_ci_safe_write_directory "$root" /etc && rootpxe_ci_metadata_safe "$root/etc/fstab" file || return 1
        while read -r source target declared options rest; do
            [[ -n $source && $source != \#* ]] || continue
            case $target in
                /usr/*) return 1;;
                /var/*|/etc|/etc/cloud|/etc/cloud/*) [[ $requested != /var ]] || return 1;;
            esac
            [[ $target == "$requested" ]] || continue
            count=$((count + 1)); [[ $count -eq 1 && -n $declared && -n $options ]] || return 1
            selected_source="$source"; selected_fs="$declared"
        done <"$root/etc/fstab"
    fi
    if [[ $count -eq 0 ]]; then
        ! mountpoint -q "$root$requested" 2>/dev/null
        return $?
    fi
    device=$(rootpxe_ci_fstab_device "$selected_source") || return 1
    rootpxe_ci_device_permitted "$device" || return 1
    fs=$(blkid -s TYPE -o value "$device" 2>/dev/null) || return 1
    [[ $fs == "$selected_fs" ]] || return 1
    case $fs in ext2|ext3|ext4|xfs) ;; *) return 1;; esac
    if mountpoint -q "$root$requested" 2>/dev/null; then rootpxe_ci_mount_matches "$root$requested" "$device" "$mode"; return $?; fi
    mount_options=$(rootpxe_linux_mount_options "$mode" "$fs") || return 1
    mount -t "$fs" -o "$mount_options" "$device" "$root$requested" || return 1
    ci_owned_mounts+=("$root$requested")
    rootpxe_ci_mount_matches "$root$requested" "$device" "$mode"
}
rootpxe_ci_cleanup_mounts() {
    local index vg_index result=0
    for ((index=${#ci_owned_mounts[@]}-1; index>=0; index--)); do
        if umount "${ci_owned_mounts[$index]}"; then unset 'ci_owned_mounts[index]'; else result=1; break; fi
    done
    # 任一卸载失败时不撤销它依赖的 VG，也不丢弃本次 ownership 证据。
    [[ $result -eq 0 ]] || return 1
    local -a vg_indices=("${!ci_vg_names[@]}")
    for ((index=${#vg_indices[@]}-1; index>=0; index--)); do
        vg_index=${vg_indices[$index]}
        if rootpxe_linux_cleanup_selected_vg "${ci_vg_names[$vg_index]}" "${ci_vg_uuids[$vg_index]}" "${ci_vg_owned[$vg_index]}"; then unset 'ci_vg_names[vg_index]' 'ci_vg_uuids[vg_index]' 'ci_vg_owned[vg_index]'; else result=1; fi
    done
    return "$result"
}
rootpxe_ci_workspace_remove() {
    local work="$1" directory
    [[ $work == /tmp/rootpxe-cloud-mount.* && -d $work && ! -L $work ]] || return 1
    for directory in "$work/root" "$work/probe"; do
        [[ ! -e $directory && ! -L $directory ]] && continue
        [[ -d $directory && ! -L $directory ]] && ! mountpoint -q "$directory" && rmdir -- "$directory" || return 1
    done
    rmdir -- "$work"
}
rootpxe_ci_mount_root() {
    local device="$1" fs="$2" work="$3" mode="$4" borrowed options
    borrowed=$(findmnt -rn -S "$device" -o TARGET) || borrowed=""
    if [[ -n $borrowed ]]; then
        [[ $borrowed != *$'\n'* ]] && rootpxe_ci_metadata_safe "$borrowed" directory && rootpxe_ci_mount_matches "$borrowed" "$device" "$mode" || return 1
        ci_mounted_root="$borrowed"
    else
        [[ ! -e $work/root && ! -L $work/root ]] || return 1
        mkdir -m 700 -- "$work/root" || return 1
        options=$(rootpxe_linux_mount_options "$mode" "$fs") || return 1
        mount -t "$fs" -o "$options" "$device" "$work/root" || return 1
        ci_owned_mounts+=("$work/root"); ci_mounted_root="$work/root"
        rootpxe_ci_mount_matches "$ci_mounted_root" "$device" "$mode" || return 1
    fi
}
rootpxe_cloud_init_probe_root_marker() {
    local root="$1" path result=1 cleanup=0
    local -a ci_owned_mounts=() ci_vg_names=() ci_vg_uuids=() ci_vg_owned=()
    for path in /etc/os-release /usr/lib/os-release; do rootpxe_ci_resolve_target "$root" "$path" file >/dev/null && return 0; done
    if rootpxe_ci_mount_fstab "$root" /usr ro; then
        for path in /etc/os-release /usr/lib/os-release; do rootpxe_ci_resolve_target "$root" "$path" file >/dev/null && result=0; done
    else result=2; fi
    rootpxe_ci_cleanup_mounts || return 2
    return "$result"
}
rootpxe_cloud_init_process_root() {
    local disk="$1" candidate="$2" mode="$3" device fs vg uuid subvol extra work owned=no result=0 ci_mounted_root=""
    local -a ci_owned_mounts=() ci_vg_names=() ci_vg_uuids=() ci_vg_owned=()
    IFS='|' read -r device fs vg uuid subvol extra <<<"$candidate"
    [[ $device == /dev/* && -z $subvol && -z $extra ]] || return 1
    case $fs in ext2|ext3|ext4|xfs) ;; *) return 1;; esac
    rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1
    work=$(mktemp -d /tmp/rootpxe-cloud-mount.XXXXXX) || return 1
    if [[ -n $vg ]]; then
        owned=$(rootpxe_linux_activate_vg_if_needed "$disk" "$vg" "$uuid") || result=1
        if [[ $owned == yes ]]; then ci_vg_names+=("$vg"); ci_vg_uuids+=("$uuid"); ci_vg_owned+=("yes"); fi
    fi
    if [[ $result -eq 0 ]]; then rootpxe_ci_mount_root "$device" "$fs" "$work" "$mode" || result=1; fi
    if [[ $result -eq 0 ]]; then rootpxe_ci_mount_fstab "$ci_mounted_root" /usr ro || result=1; fi
    if [[ $result -eq 0 ]]; then rootpxe_ci_mount_fstab "$ci_mounted_root" /var "$mode" || result=1; fi
    if [[ $result -eq 0 ]]; then
        if [[ $mode == ro ]]; then
            rootpxe_ci_readonly_preflight "$ci_mounted_root" || result=1
        else rootpxe_cloud_init_install_at_root "$ci_mounted_root" || result=1; fi
    fi
    rootpxe_ci_cleanup_mounts || { result=1; rootpxe_cloud_init_error=cloud_init_mount_cleanup_failed; }
    rootpxe_ci_workspace_remove "$work" || { result=1; rootpxe_cloud_init_error=cloud_init_probe_cleanup_failed; }
    return "$result"
}
rootpxe_ci_candidate_identity() {
    local candidate="$1" device fs vg uuid subvol extra canonical rdev
    IFS='|' read -r device fs vg uuid subvol extra <<<"$candidate"
    [[ $device == /dev/* && -z $subvol && -z $extra ]] || return 1
    case $fs in ext2|ext3|ext4|xfs) ;; *) return 1;; esac
    canonical=$(readlink -f -- "$device") || return 1
    rootpxe_ci_device_is_block "$canonical" || return 1
    rdev=$(stat -c %r -- "$canonical") || return 1
    [[ $rdev =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s|%s|%s|%s|%s|%s\n' "$canonical" "$rdev" "$fs" "$vg" "$uuid" "$subvol"
}
rootpxe_linux_select_unique_root_for_targets() {
    local disk work candidate identity identity_device identity_rdev identity_rest key rc device fs vg uuid subvol extra owned index result=0 selected="" selected_candidate="" count=0
    local -A candidates_seen=()
    local -a selected_vg_names=() selected_vg_uuids=()
    local rootpxe_cloud_init_allowed_disks="$*" rootpxe_cloud_init_probe_disk=""
    [[ $# -gt 0 && ${taskType:-} == deploy && ${osid:-} == 50 ]] || return 1
    for disk in "$@"; do rootpxe_verify_disk_permit_binding "$disk" deploy_write || { rootpxe_cloud_init_error=cloud_init_disk_permit_invalid; return 1; }; done
    for disk in "$@"; do
        work=$(mktemp -d /tmp/rootpxe-cloud-mount.XXXXXX) || { rootpxe_cloud_init_error=cloud_init_root_probe_failed; result=1; break; }
        rootpxe_cloud_init_probe_disk="$disk"
        if candidate=$(rootpxe_find_linux_root_filesystem "$disk" "$work/probe"); then rc=0; else rc=$?; fi
        rootpxe_ci_workspace_remove "$work" || { rootpxe_cloud_init_error=cloud_init_probe_cleanup_failed; result=1; break; }
        case $rc in
            0)
                IFS='|' read -r device fs vg uuid subvol extra <<<"$candidate"
                [[ $device == /dev/* && -z $subvol && -z $extra ]] || { rootpxe_cloud_init_error=cloud_init_root_identity_unverified; result=1; break; }
                case $fs in ext2|ext3|ext4|xfs) ;; *) rootpxe_cloud_init_error=cloud_init_root_identity_unverified; result=1; break;; esac
                if [[ -n $vg ]]; then
                    owned=$(rootpxe_linux_activate_vg_if_needed "$disk" "$vg" "$uuid") || { rootpxe_cloud_init_error=cloud_init_root_probe_failed; result=1; break; }
                    if [[ $owned == yes ]]; then selected_vg_names+=("$vg"); selected_vg_uuids+=("$uuid"); fi
                fi
                identity=$(rootpxe_ci_candidate_identity "$candidate") || { rootpxe_cloud_init_error=cloud_init_root_identity_unverified; result=1; break; }
                IFS='|' read -r identity_device identity_rdev identity_rest <<<"$identity"
                key="$identity_device|$identity_rdev"
                # 同一LV可从多个已许可PV发现；完整候选必须一致。
                if [[ -n ${candidates_seen[$key]:-} ]]; then
                    [[ ${candidates_seen[$key]} == "$identity" ]] || { rootpxe_cloud_init_error=cloud_init_root_identity_conflict; result=1; break; }
                else candidates_seen[$key]="$identity"; count=$((count + 1)); selected="$disk"; selected_candidate="$candidate"; fi
                ;;
            20) ;;
            *) rootpxe_cloud_init_error=cloud_init_root_probe_failed; result=1; break;;
        esac
    done
    if [[ $result -eq 0 && $count -ne 1 ]]; then rootpxe_cloud_init_error=cloud_init_roots_not_unique; result=1; fi
    # 在整个目标循环保留自有 VG，避免同一 LV 的设备号随 PV 探测反复变化。
    # 只清理本次重新激活的 VG；任一清理失败仍继续释放其他自有 VG。
    for ((index=${#selected_vg_names[@]}-1; index>=0; index--)); do
        rootpxe_linux_cleanup_selected_vg "${selected_vg_names[$index]}" "${selected_vg_uuids[$index]}" yes || { rootpxe_cloud_init_error=cloud_init_mount_cleanup_failed; result=1; }
    done
    [[ $result -eq 0 ]] || return 1
    rootpxe_linux_selected_disk="$selected"
    rootpxe_linux_selected_candidate="$selected_candidate"
}
rootpxe_cloud_init_install_for_targets() {
    local rootpxe_cloud_init_allowed_disks="$*" rootpxe_cloud_init_probe_disk='' rootpxe_linux_selected_disk='' rootpxe_linux_selected_candidate='' disk
    rootpxe_linux_select_unique_root_for_targets "$@" || return 1
    rootpxe_cloud_init_process_root "$rootpxe_linux_selected_disk" "$rootpxe_linux_selected_candidate" ro || { [[ -n ${rootpxe_cloud_init_error:-} ]] || rootpxe_cloud_init_error=cloud_init_readonly_preflight_failed; return 1; }
    for disk in "$@"; do rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1; done
    rootpxe_cloud_init_process_root "$rootpxe_linux_selected_disk" "$rootpxe_linux_selected_candidate" rw
}
rootpxe_apply_cloud_init() {
    rootpxe_deployment_identity_cloud_init_result=false
    if ! rootpxe_cloud_init_configured; then
        if rootpxe_cloud_init_policy_enabled; then rootpxe_deployment_identity_hostname_result=false; return 1; fi
        return 0
    fi
    if [[ ${osid:-} == 50 ]]; then rootpxe_deployment_identity_hostname_result=false; fi
    [[ ${taskType:-} == deploy && ${osid:-} == 50 ]] && rootpxe_cloud_init_private_valid || return 1
    rootpxe_stage cloud_init 'installing native NoCloud seed'
    rootpxe_cloud_init_install_for_targets ${disks:-${hd:-}} || return 1
    rootpxe_cloud_init_cleanup_private || return 1
    rootpxe_deployment_identity_cloud_init_result=true
    rootpxe_stage cloud_init 'Cloud-init configuration installed' || true
    return 0
}
rootpxe_cloud_init_install_at_root() {
    local root="$1" result
    rootpxe_cloud_init_error=""
    if (
        umask 077
        local seed="$root/var/lib/cloud/seed/nocloud" file source path
        rootpxe_ci_is_root || exit 43
        rootpxe_ci_readonly_preflight "$root" || exit $?
        rootpxe_ci_safe_write_directory "$root" /var/lib/cloud/seed/nocloud yes || exit 1
        chmod 700 "$seed" && chown 0:0 "$seed" || exit 1
        for file in user-data meta-data network-config vendor-data; do
            case $file in
                user-data) source="$cloudInitUserDataFile";;
                meta-data) source="$cloudInitMetaDataFile";;
                network-config) source="${cloudInitNetworkConfigFile:-}";;
                vendor-data) source="${cloudInitVendorDataFile:-}";;
            esac
            path="$seed/$file"
            if [[ -n $source ]]; then
                cp -- "$source" "$path" && chmod 600 "$path" && chown 0:0 "$path" || exit 1
            else rm -f -- "$path" || exit 1; fi
        done
        rootpxe_ci_safe_write_directory "$root" /etc/cloud/cloud.cfg.d yes || exit 1
        path="$root/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg"
        printf 'datasource_list: [NoCloud]\n' >"$path" && chmod 644 "$path" && chown 0:0 "$path" || exit 1
    ); then result=0; else
        result=$?
        case $result in
            41) rootpxe_cloud_init_error=cloud_init_not_installed;;
            42) rootpxe_cloud_init_error=cloud_init_explicitly_disabled;;
            43) rootpxe_cloud_init_error=cloud_init_target_path_unsafe;;
            *) rootpxe_cloud_init_error=cloud_init_seed_io_failed;;
        esac
    fi
    return "$result"
}
