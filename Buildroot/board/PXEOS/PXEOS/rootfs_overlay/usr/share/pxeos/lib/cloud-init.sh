#!/bin/bash
# 仅离线安装原生 NoCloud seed；不执行目标程序或 user-data。

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

rootpxe_ci_target_selinux() {
    local root="$1" config mode policy line path
    config="$root/etc/selinux/config"
    rootpxe_ci_selinux_contexts=""
    [[ -e $root/etc/selinux || -L $root/etc/selinux ]] || return 0
    rootpxe_ci_safe_write_directory "$root" /etc/selinux || return 1
    rootpxe_ci_metadata_safe "$config" file || return 1
    mode=$(awk -F= '/^[[:space:]]*SELINUX=/{gsub(/[[:space:]]/,"",$2); print $2}' "$config")
    [[ $mode == disabled ]] && return 0
    [[ $mode == enforcing || $mode == permissive ]] || return 1
    policy=$(awk -F= '/^[[:space:]]*SELINUXTYPE=/{gsub(/[[:space:]]/,"",$2); print $2}' "$config")
    [[ $policy =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    path="/etc/selinux/$policy/contexts/files"
    rootpxe_ci_safe_write_directory "$root" "$path" || return 1
    rootpxe_ci_selinux_contexts="$root$path/file_contexts"
    rootpxe_ci_metadata_safe "$rootpxe_ci_selinux_contexts" file || return 1
    for line in .bin .local .local.bin .subs .subs_dist .homedirs .homedirs.bin; do
        path="$rootpxe_ci_selinux_contexts$line"
        [[ ! -e $path && ! -L $path ]] || rootpxe_ci_metadata_safe "$path" file || return 1
    done
}
rootpxe_ci_label_tools_ready() {
    command -v matchpathcon >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1 &&
        command -v getfattr >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1
}
rootpxe_ci_expected_label() {
    timeout 10 matchpathcon -n -f "$rootpxe_ci_selinux_contexts" "$1" 2>/dev/null
}
rootpxe_ci_write_label() { setfattr -h -n security.selinux -v "$2" -- "$1" 2>/dev/null; }
rootpxe_ci_read_label() { getfattr -h --only-values -n security.selinux -- "$1" 2>/dev/null | tr -d '\000'; }
rootpxe_ci_label_path() {
    local physical="$1" target="$2" label actual
    [[ -n ${rootpxe_ci_selinux_contexts:-} ]] || return 0
    label=$(rootpxe_ci_expected_label "$target") || return 1
    [[ $label =~ ^[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(:[A-Za-z0-9_,.-]+)?$ ]] || return 1
    rootpxe_ci_write_label "$physical" "$label" || return 1
    actual=$(rootpxe_ci_read_label "$physical") || return 1
    [[ $actual == "$label" ]]
}

rootpxe_ci_inode() { stat -c '%d:%i' -- "$1"; }
rootpxe_ci_move() { mv -n -- "$1" "$2"; }
rootpxe_cloud_init_configured() { [[ -n ${cloudInitUserDataFile:-} || -n ${cloudInitNetworkConfigFile:-} ]]; }
rootpxe_ci_private_file_valid() {
    local file="$1" hash="$2" inode="$3" pid="$4" kind="$5" info owner group mode links
    case $kind in
        user-data) [[ $file =~ ^/tmp/rootpxe-cloud-init\.[A-Za-z0-9]{6}$ ]];;
        network-config) [[ $file =~ ^/tmp/rootpxe-cloud-network\.[A-Za-z0-9]{6}$ ]];;
        *) return 1;;
    esac || return 1
    [[ -f $file && ! -L $file && -O $file ]] || return 1
    info=$(rootpxe_ci_stat "$file") || return 1
    IFS=: read -r owner group mode links <<<"$info"
    [[ $owner == "$EUID" && $mode == 600 && $links == 1 && $pid == "$BASHPID" && $(rootpxe_ci_inode "$file") == "$inode" ]] || return 1
    [[ $hash =~ ^[0-9a-f]{64}$ && $(rootpxe_ci_hash "$file") == "$hash" && $(wc -c <"$file") -gt 0 && $(wc -c <"$file") -le 65536 ]]
}
rootpxe_cloud_init_private_valid() {
    [[ ${cloudInitInstanceId:-} =~ ^rootpxe-[0-9a-f]{32}$ ]] && rootpxe_ci_hostname_valid "${cloudInitHostname:-}" || return 1
    rootpxe_ci_private_file_valid "${cloudInitUserDataFile:-}" "${cloudInitUserDataSha256:-}" "${rootpxe_cloud_init_private_inode:-}" "${rootpxe_cloud_init_private_pid:-}" user-data || return 1
    if [[ -n ${cloudInitNetworkConfigFile:-} || -n ${cloudInitNetworkConfigSha256:-} ]]; then
        rootpxe_ci_private_file_valid "${cloudInitNetworkConfigFile:-}" "${cloudInitNetworkConfigSha256:-}" "${rootpxe_cloud_init_network_private_inode:-}" "${rootpxe_cloud_init_network_private_pid:-}" network-config || return 1
    fi
    return 0
}
rootpxe_cloud_init_cleanup_private() {
    local result=0
    # 清理一开始即失效整份任务配置；部分unlink失败仍保留逐文件proof供重试。
    unset cloudInitInstanceId cloudInitHostname
    if [[ -n ${cloudInitUserDataFile:-} ]]; then
        if rootpxe_ci_private_file_valid "$cloudInitUserDataFile" "${cloudInitUserDataSha256:-}" "${rootpxe_cloud_init_private_inode:-}" "${rootpxe_cloud_init_private_pid:-}" user-data && rm -f -- "$cloudInitUserDataFile"; then
            unset cloudInitUserDataFile cloudInitUserDataSha256 rootpxe_cloud_init_private_inode rootpxe_cloud_init_private_pid
        else result=1; fi
    fi
    if [[ -n ${cloudInitNetworkConfigFile:-} ]]; then
        if rootpxe_ci_private_file_valid "$cloudInitNetworkConfigFile" "${cloudInitNetworkConfigSha256:-}" "${rootpxe_cloud_init_network_private_inode:-}" "${rootpxe_cloud_init_network_private_pid:-}" network-config && rm -f -- "$cloudInitNetworkConfigFile"; then
            unset cloudInitNetworkConfigFile cloudInitNetworkConfigSha256 rootpxe_cloud_init_network_private_inode rootpxe_cloud_init_network_private_pid
        else result=1; fi
    fi
    if [[ -z ${cloudInitUserDataFile:-} && -z ${cloudInitNetworkConfigFile:-} ]]; then
        unset cloudInitUserDataFile cloudInitUserDataSha256 cloudInitInstanceId cloudInitHostname cloudInitNetworkConfigFile cloudInitNetworkConfigSha256 rootpxe_cloud_init_private_inode rootpxe_cloud_init_private_pid rootpxe_cloud_init_network_private_inode rootpxe_cloud_init_network_private_pid
    fi
    return "$result"
}
rootpxe_ci_hostname_valid() {
    local hostname="$1" label
    [[ ${#hostname} -le 253 && $hostname =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && $hostname != *..* && $hostname != *. ]] || return 1
    for label in ${hostname//./ }; do
        [[ ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}
rootpxe_apply_json_cloud_init() {
    local document="$1" file network_file='' hash network_hash instance hostname inode network_inode=''
    rootpxe_cloud_init_cleanup_private || return 1
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$document" || return 1
    jq -e 'has("cloudInitUserData") or has("cloudInitUserDataSha256") or has("cloudInitInstanceId") or has("cloudInitHostname") or has("cloudInitNetworkConfig") or has("cloudInitNetworkConfigSha256")' >/dev/null 2>&1 <<<"$document" || return 0
    [[ ${taskType:-} == deploy && ${osid:-} == 50 ]] || return 1
    jq -e '.type == "deploy" and (.osid | type == "number") and .osid == 50 and
      (.cloudInitUserData | type == "string" and utf8bytelength > 0 and utf8bytelength <= 65536 and (contains("\u0000") | not) and test("^#cloud-config\\r?\\n")) and
      (.cloudInitUserDataSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.cloudInitInstanceId | type == "string" and test("^rootpxe-[0-9a-f]{32}$")) and
      (.cloudInitHostname | type == "string") and
      (.cloudInitNetworkConfig | type == "string" and utf8bytelength <= 65536 and (contains("\u0000") | not)) and
      (.cloudInitNetworkConfigSha256 | type == "string") and
      (if .cloudInitNetworkConfig == "" then .cloudInitNetworkConfigSha256 == "" else (.cloudInitNetworkConfigSha256 | test("^[0-9a-f]{64}$")) end)' >/dev/null 2>&1 <<<"$document" || return 1
    hash=$(jq -r '.cloudInitUserDataSha256' <<<"$document") || return 1
    network_hash=$(jq -r '.cloudInitNetworkConfigSha256' <<<"$document") || return 1
    instance=$(jq -r '.cloudInitInstanceId' <<<"$document") || return 1
    hostname=$(jq -r '.cloudInitHostname' <<<"$document") || return 1
    rootpxe_ci_hostname_valid "$hostname" || return 1
    file=$(mktemp /tmp/rootpxe-cloud-init.XXXXXX) || return 1
    if ! chmod 600 "$file" || ! jq -j '.cloudInitUserData' <<<"$document" >"$file" || [[ $(rootpxe_ci_hash "$file") != "$hash" ]]; then
        rm -f -- "$file" || return 1
        return 1
    fi
    inode=$(rootpxe_ci_inode "$file") || { rm -f -- "$file"; return 1; }
    if [[ -n $network_hash ]]; then
        network_file=$(mktemp /tmp/rootpxe-cloud-network.XXXXXX) || { rm -f -- "$file"; return 1; }
        if ! chmod 600 "$network_file" || ! jq -j '.cloudInitNetworkConfig' <<<"$document" >"$network_file" || [[ $(rootpxe_ci_hash "$network_file") != "$network_hash" ]]; then
            rm -f -- "$file" "$network_file" || return 1
            return 1
        fi
        network_inode=$(rootpxe_ci_inode "$network_file") || { rm -f -- "$file" "$network_file"; return 1; }
    fi
    cloudInitUserDataFile="$file"; cloudInitUserDataSha256="$hash"
    cloudInitInstanceId="$instance"; cloudInitHostname="$hostname"
    cloudInitNetworkConfigFile="$network_file"; cloudInitNetworkConfigSha256="$network_hash"
    rootpxe_cloud_init_private_inode="$inode"
    rootpxe_cloud_init_private_pid=$BASHPID
    rootpxe_cloud_init_network_private_inode="$network_inode"
    rootpxe_cloud_init_network_private_pid=$BASHPID
    export -n rootpxe_cloud_init_private_inode rootpxe_cloud_init_private_pid rootpxe_cloud_init_network_private_inode rootpxe_cloud_init_network_private_pid
    export cloudInitUserDataFile cloudInitUserDataSha256 cloudInitInstanceId cloudInitHostname cloudInitNetworkConfigFile cloudInitNetworkConfigSha256
    rootpxe_cloud_init_private_valid
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
    # 原生 YAML 合并、NoCloud 可用性和启动启用状态由镜像管理员验证。
    return 0
}
rootpxe_ci_validate_cloud_state() {
    local root="$1" path entry
    rootpxe_ci_safe_write_directory "$root" /var || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    for path in /var/lib /var/lib/cloud /var/lib/cloud/seed /var/lib/cloud/seed/nocloud; do
        [[ -e $root$path || -L $root$path ]] || break
        rootpxe_ci_safe_write_directory "$root" "$path" || { rootpxe_ci_reject 43 cloud_init_target_path_unsafe; return $?; }
    done
    if [[ -d $root/var/lib/cloud ]]; then
        while IFS= read -r -d '' entry; do [[ ${entry##*/} == seed ]] || { rootpxe_ci_reject 44 cloud_init_cache_not_clean; return $?; }; done < <(find "$root/var/lib/cloud" -mindepth 1 -maxdepth 1 -print0)
    fi
    if [[ -d $root/var/lib/cloud/seed ]]; then
        while IFS= read -r -d '' entry; do [[ ${entry##*/} == nocloud ]] || { rootpxe_ci_reject 45 cloud_init_foreign_seed; return $?; }; done < <(find "$root/var/lib/cloud/seed" -mindepth 1 -maxdepth 1 -print0)
    fi
    return 0
}
rootpxe_ci_metadata_bytes() {
    local instance="$1" hostname="$2" quoted_instance quoted_hostname
    [[ $instance =~ ^rootpxe-[0-9a-f]{32}$ ]] && rootpxe_ci_hostname_valid "$hostname" || return 1
    quoted_instance=$(jq -cn --arg value "$instance" '$value') || return 1
    quoted_hostname=$(jq -cn --arg value "$hostname" '$value') || return 1
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$quoted_instance" "$quoted_hostname"
}
rootpxe_ci_verify_seed() {
    local seed="$1" data_hash="$2" metadata_hash="$3" network_hash="${4:-}" entry count=0 expected_count=2
    if [[ -n $network_hash ]]; then [[ $network_hash =~ ^[0-9a-f]{64}$ ]] || return 1; expected_count=3; fi
    rootpxe_ci_metadata_safe "$seed" directory || return 1
    while IFS= read -r -d '' entry; do
        case ${entry##*/} in user-data|meta-data) ;; network-config) [[ -n $network_hash ]] || return 1;; *) return 1;; esac
        rootpxe_ci_metadata_safe "$entry" file 600 || return 1
        count=$((count + 1))
    done < <(find "$seed" -mindepth 1 -maxdepth 1 -print0)
    [[ $count -eq $expected_count && $(rootpxe_ci_hash "$seed/user-data") == "$data_hash" && $(rootpxe_ci_hash "$seed/meta-data") == "$metadata_hash" ]] || return 1
    [[ -z $network_hash || $(rootpxe_ci_hash "$seed/network-config") == "$network_hash" ]]
}
rootpxe_ci_verify_label() {
    local physical="$1" target="$2" expected
    [[ -n ${rootpxe_ci_selinux_contexts:-} ]] || return 0
    expected=$(rootpxe_ci_expected_label "$target") || return 1
    [[ $(rootpxe_ci_read_label "$physical") == "$expected" ]]
}
rootpxe_ci_verify_seed_labels() {
    local seed="$1" file
    local -a files=(user-data meta-data)
    [[ -z ${cloudInitNetworkConfigSha256:-} ]] || files+=(network-config)
    rootpxe_ci_verify_label "$seed" /var/lib/cloud/seed/nocloud || return 1
    for file in "${files[@]}"; do rootpxe_ci_verify_label "$seed/$file" "/var/lib/cloud/seed/nocloud/$file" || return 1; done
}
rootpxe_ci_readonly_preflight() {
    local root="$1" metadata_hash seed="$1/var/lib/cloud/seed/nocloud"
    rootpxe_cloud_init_seed_verified=no
    rootpxe_ci_check_prerequisites "$root" || return $?
    rootpxe_ci_validate_cloud_state "$root" || return $?
    rootpxe_ci_target_selinux "$root" || { rootpxe_ci_reject 48 cloud_init_label_unverified; return $?; }
    if [[ -n ${rootpxe_ci_selinux_contexts:-} ]]; then rootpxe_ci_label_tools_ready || { rootpxe_ci_reject 47 cloud_init_label_tools_missing; return $?; }; fi
    metadata_hash=$(set -o pipefail; rootpxe_ci_metadata_bytes "$cloudInitInstanceId" "$cloudInitHostname" | sha256sum) || { rootpxe_ci_reject 46 cloud_init_seed_hash_mismatch; return $?; }
    metadata_hash=${metadata_hash%%[[:space:]]*}
    if [[ -d $seed ]]; then
        if [[ -n $(find "$seed" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            rootpxe_ci_verify_seed "$seed" "$cloudInitUserDataSha256" "$metadata_hash" "${cloudInitNetworkConfigSha256:-}" || { rootpxe_ci_reject 45 cloud_init_foreign_seed; return $?; }
            rootpxe_ci_verify_seed_labels "$seed" || { rootpxe_ci_reject 48 cloud_init_label_unverified; return $?; }
            rootpxe_cloud_init_seed_verified=yes
        else rootpxe_ci_verify_label "$seed" /var/lib/cloud/seed/nocloud || { rootpxe_ci_reject 48 cloud_init_label_unverified; return $?; }; fi
    fi
    return 0
}
# 动态局部数组只登记本次创建对象的 inode；不删除未知内容或递归删除目录。
rootpxe_ci_transaction_cleanup() {
    local index path result=0
    for ((index=${#ci_owned_files[@]}-1; index>=0; index--)); do
        path=${ci_owned_files[$index]}
        [[ -e $path || -L $path ]] || continue
        if [[ -f $path && ! -L $path && $(rootpxe_ci_inode "$path") == "${ci_owned_file_inodes[$index]}" ]]; then rm -- "$path" || result=1; else result=1; fi
    done
    for ((index=${#ci_created_dirs[@]}-1; index>=0; index--)); do
        path=${ci_created_dirs[$index]}
        [[ -e $path || -L $path ]] || continue
        if [[ -d $path && ! -L $path && $(rootpxe_ci_inode "$path") == "${ci_created_dir_inodes[$index]}" ]]; then rmdir -- "$path" || result=1; else result=1; fi
    done
    return "$result"
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
    actual=$(stat -c %d -- "$path") && expected=$(stat -c %r -- "$device") || return 1
    [[ $actual == "$expected" ]] || return 1
    options=$(findmnt -rn --mountpoint "$path" -o OPTIONS) || return 1
    [[ ,$options, == *",$mode,"* ]]
}
rootpxe_ci_mount_fstab() {
    local root="$1" requested="$2" mode="$3" source target declared options rest count=0 selected_source="" selected_fs="" device fs mount_options path
    [[ $requested == /var || $requested == /usr ]] || return 1
    rootpxe_ci_safe_write_directory "$root" "$requested" || return 1
    for path in /var/lib /var/lib/cloud /var/lib/cloud/seed /var/lib/cloud/seed/nocloud; do
        mountpoint -q "$root$path" 2>/dev/null && return 1
    done
    if [[ -e $root/etc/fstab || -L $root/etc/fstab ]]; then
        rootpxe_ci_safe_write_directory "$root" /etc && rootpxe_ci_metadata_safe "$root/etc/fstab" file || return 1
        while read -r source target declared options rest; do
            [[ -n $source && $source != \#* ]] || continue
            case $target in /var/*|/usr/*|/etc/cloud|/etc/cloud/*) return 1;; esac
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
    local index result=0
    for ((index=${#ci_owned_mounts[@]}-1; index>=0; index--)); do
        if umount "${ci_owned_mounts[$index]}"; then unset 'ci_owned_mounts[index]'; else result=1; break; fi
    done
    # 任一卸载失败时不撤销它依赖的 VG，也不丢弃本次 ownership 证据。
    [[ $result -eq 0 ]] || return 1
    for ((index=${#ci_vg_names[@]}-1; index>=0; index--)); do
        if rootpxe_linux_cleanup_selected_vg "${ci_vg_names[$index]}" "${ci_vg_uuids[$index]}" "${ci_vg_owned[$index]}"; then unset 'ci_vg_names[index]' 'ci_vg_uuids[index]' 'ci_vg_owned[index]'; else result=1; break; fi
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
rootpxe_cloud_init_install_for_targets() {
    local disk work candidate identity identity_device identity_rdev identity_rest key rc selected="" selected_candidate="" count=0
    local -A candidates_seen=()
    local rootpxe_cloud_init_allowed_disks="$*" rootpxe_cloud_init_probe_disk=""
    [[ $# -gt 0 && ${taskType:-} == deploy && ${osid:-} == 50 ]] || return 1
    for disk in "$@"; do rootpxe_verify_disk_permit_binding "$disk" deploy_write || { rootpxe_cloud_init_error=cloud_init_disk_permit_invalid; return 1; }; done
    for disk in "$@"; do
        work=$(mktemp -d /tmp/rootpxe-cloud-mount.XXXXXX) || return 1
        rootpxe_cloud_init_probe_disk="$disk"
        if candidate=$(rootpxe_find_linux_root_filesystem "$disk" "$work/probe"); then rc=0; else rc=$?; fi
        rootpxe_ci_workspace_remove "$work" || { rootpxe_cloud_init_error=cloud_init_probe_cleanup_failed; return 1; }
        case $rc in
            0)
                identity=$(rootpxe_ci_candidate_identity "$candidate") || { rootpxe_cloud_init_error=cloud_init_root_identity_unverified; return 1; }
                IFS='|' read -r identity_device identity_rdev identity_rest <<<"$identity"
                key="$identity_device|$identity_rdev"
                # 同一LV可从多个已许可PV发现；完整候选必须一致。
                if [[ -n ${candidates_seen[$key]:-} ]]; then
                    [[ ${candidates_seen[$key]} == "$identity" ]] || { rootpxe_cloud_init_error=cloud_init_root_identity_conflict; return 1; }
                else candidates_seen[$key]="$identity"; count=$((count + 1)); selected="$disk"; selected_candidate="$candidate"; fi
                ;;
            20) ;;
            *) rootpxe_cloud_init_error=cloud_init_root_probe_failed; return 1;;
        esac
    done
    [[ $count -eq 1 ]] || { rootpxe_cloud_init_error=cloud_init_roots_not_unique; return 1; }
    rootpxe_cloud_init_process_root "$selected" "$selected_candidate" ro || { [[ -n ${rootpxe_cloud_init_error:-} ]] || rootpxe_cloud_init_error=cloud_init_readonly_preflight_failed; return 1; }
    [[ ${rootpxe_cloud_init_seed_verified:-no} != yes ]] || return 0
    for disk in "$@"; do rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1; done
    rootpxe_cloud_init_process_root "$selected" "$selected_candidate" rw
}
rootpxe_apply_cloud_init() {
    rootpxe_deployment_identity_cloud_init_result=false
    rootpxe_cloud_init_configured || return 0
    [[ ${taskType:-} == deploy && ${osid:-} == 50 ]] && rootpxe_cloud_init_private_valid || return 1
    rootpxe_stage cloud_init 'installing native NoCloud seed'
    rootpxe_cloud_init_install_for_targets ${disks:-${hd:-}} || return 1
    rootpxe_deployment_identity_cloud_init_result=true
    rootpxe_cloud_init_cleanup_private
}
rootpxe_ci_create_directory() {
    local path="$1" target="$2" inode
    if [[ -e $path || -L $path ]]; then rootpxe_ci_metadata_safe "$path" directory || return 43; return 0; fi
    mkdir -m 700 -- "$path" || return 51
    inode=$(rootpxe_ci_inode "$path") || return 51
    ci_created_dirs+=("$path"); ci_created_dir_inodes+=("$inode")
    chown 0:0 -- "$path" && rootpxe_ci_metadata_safe "$path" directory 700 || return 43
    rootpxe_ci_label_path "$path" "$target" || return 48
}
rootpxe_cloud_init_install_at_root() {
    local root="$1" result
    rootpxe_cloud_init_error=""
    if (
        set -o pipefail
        local seed="$root/var/lib/cloud/seed/nocloud" stage="" file path final index metadata_hash root_device
        local -a ci_owned_files=() ci_owned_file_inodes=() ci_created_dirs=() ci_created_dir_inodes=() ci_seed_files=(user-data meta-data)
        trap 'ci_exit_status=$?; rootpxe_ci_transaction_cleanup || exit 50; exit "$ci_exit_status"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        umask 077
        rootpxe_ci_is_root && rootpxe_ci_metadata_safe "$root" directory || exit 43
        [[ -f ${cloudInitUserDataFile:-} && ! -L $cloudInitUserDataFile && ${cloudInitUserDataSha256:-} =~ ^[0-9a-f]{64}$ && $(rootpxe_ci_hash "$cloudInitUserDataFile") == "$cloudInitUserDataSha256" && $(wc -c <"$cloudInitUserDataFile") -le 65536 ]] || exit 46
        if [[ -n ${cloudInitNetworkConfigFile:-} || -n ${cloudInitNetworkConfigSha256:-} ]]; then
            [[ -f ${cloudInitNetworkConfigFile:-} && ! -L $cloudInitNetworkConfigFile && ${cloudInitNetworkConfigSha256:-} =~ ^[0-9a-f]{64}$ && $(rootpxe_ci_hash "$cloudInitNetworkConfigFile") == "$cloudInitNetworkConfigSha256" && $(wc -c <"$cloudInitNetworkConfigFile") -gt 0 && $(wc -c <"$cloudInitNetworkConfigFile") -le 65536 ]] || exit 46
            ci_seed_files+=(network-config)
        fi
        rootpxe_ci_readonly_preflight "$root" || exit $?
        [[ $rootpxe_cloud_init_seed_verified != yes ]] || exit 0
        metadata_hash=$(rootpxe_ci_metadata_bytes "$cloudInitInstanceId" "$cloudInitHostname" | sha256sum) || exit 1
        metadata_hash=${metadata_hash%%[[:space:]]*}
        if [[ -d $seed && -n $(find "$seed" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            rootpxe_ci_verify_seed "$seed" "$cloudInitUserDataSha256" "$metadata_hash" "${cloudInitNetworkConfigSha256:-}" || exit 45
            rootpxe_ci_verify_seed_labels "$seed" || exit 48
            exit 0
        fi
        for path in /var/lib /var/lib/cloud /var/lib/cloud/seed; do rootpxe_ci_create_directory "$root$path" "$path" || exit $?; done
        stage=$(mktemp -d "$root/var/lib/cloud/seed/.nocloud.new.XXXXXX") || exit 1
        ci_created_dirs+=("$stage"); ci_created_dir_inodes+=("$(rootpxe_ci_inode "$stage")")
        chmod 700 "$stage" && chown 0:0 "$stage" && rootpxe_ci_metadata_safe "$stage" directory 700 && rootpxe_ci_label_path "$stage" /var/lib/cloud/seed/nocloud || exit 48
        root_device=$(stat -c %d "$root/var/lib/cloud/seed") || exit 1
        [[ $(stat -c %d "$stage") == "$root_device" ]] || exit 1
        for file in "${ci_seed_files[@]}"; do
            path="$stage/$file"
            (set -o noclobber; : >"$path") || exit 1
            ci_owned_files+=("$path"); ci_owned_file_inodes+=("$(rootpxe_ci_inode "$path")")
            chmod 600 "$path" && chown 0:0 "$path" || exit 1
            case $file in
                user-data) cp -- "$cloudInitUserDataFile" "$path" || exit 1;;
                meta-data) rootpxe_ci_metadata_bytes "$cloudInitInstanceId" "$cloudInitHostname" >"$path" || exit 1;;
                network-config) cp -- "$cloudInitNetworkConfigFile" "$path" || exit 1;;
            esac
            rootpxe_ci_label_path "$path" "/var/lib/cloud/seed/nocloud/$file" || exit 48
        done
        rootpxe_ci_verify_seed "$stage" "$cloudInitUserDataSha256" "$metadata_hash" "${cloudInitNetworkConfigSha256:-}" || exit 46
        if [[ -d $seed ]]; then
            [[ -z $(find "$seed" -mindepth 1 -maxdepth 1 -print -quit) ]] || exit 45
            rootpxe_ci_verify_label "$seed" /var/lib/cloud/seed/nocloud || exit 48
            # 保留镜像原空目录的 inode/xattr；只发布本次期望文件集合。
            for index in "${!ci_owned_files[@]}"; do
                path=${ci_owned_files[$index]}; final="$seed/${path##*/}"
                rootpxe_ci_move "$path" "$final" || exit 49
                [[ ! -e $path && ! -L $path && $(rootpxe_ci_inode "$final") == "${ci_owned_file_inodes[$index]}" ]] || exit 1
                ci_owned_files[$index]="$final"
            done
            rmdir -- "$stage" || exit 1
        else
            rootpxe_ci_move "$stage" "$seed" || exit 49
            [[ ! -e $stage && ! -L $stage && $(rootpxe_ci_inode "$seed") == "${ci_created_dir_inodes[${#ci_created_dir_inodes[@]}-1]}" ]] || exit 1
            ci_created_dirs[${#ci_created_dirs[@]}-1]="$seed"
            for index in "${!ci_owned_files[@]}"; do ci_owned_files[$index]="$seed/${ci_owned_files[$index]##*/}"; done
        fi
        rootpxe_ci_verify_seed "$seed" "$cloudInitUserDataSha256" "$metadata_hash" "${cloudInitNetworkConfigSha256:-}" || exit 46
        rootpxe_ci_verify_seed_labels "$seed" || exit 48
        ci_owned_files=(); ci_owned_file_inodes=(); ci_created_dirs=(); ci_created_dir_inodes=()
    ); then result=0; else
        result=$?
        case $result in
            41) rootpxe_cloud_init_error=cloud_init_not_installed;;
            42) rootpxe_cloud_init_error=cloud_init_explicitly_disabled;;
            43) rootpxe_cloud_init_error=cloud_init_target_path_unsafe;;
            44) rootpxe_cloud_init_error=cloud_init_cache_not_clean;;
            45) rootpxe_cloud_init_error=cloud_init_foreign_seed;;
            46) rootpxe_cloud_init_error=cloud_init_seed_hash_mismatch;;
            47) rootpxe_cloud_init_error=cloud_init_label_tools_missing;;
            48) rootpxe_cloud_init_error=cloud_init_label_unverified;;
            49) rootpxe_cloud_init_error=cloud_init_seed_publish_failed;;
            50) rootpxe_cloud_init_error=cloud_init_seed_rollback_failed;;
            *) rootpxe_cloud_init_error=cloud_init_seed_io_failed;;
        esac
    fi
    return "$result"
}
