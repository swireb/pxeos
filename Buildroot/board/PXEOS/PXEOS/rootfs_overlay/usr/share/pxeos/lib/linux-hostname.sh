#!/bin/bash
# 仅处理 Cloud-init 关闭时的 Linux 主机名；不访问 Cloud-init 包、缓存或seed。

rootpxe_validate_linux_hostname() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
rootpxe_linux_hostname_task_valid() {
    [[ ${taskType:-} == deploy && ${osid:-} == 50 && ${changeHostname:-false} == true && -r ${deploymentIdentityPolicyFile:-} ]] &&
        rootpxe_validate_linux_hostname "${hostName:-}" &&
        jq -e --arg name "$hostName" '.version == 1 and .taskHostname == $name and .systemIdentity.sysprep == false and (.cloudInit|type == "boolean")' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}
rootpxe_lh_reject() { rootpxe_initialization_failure_reason="$1"; return 1; }
# 状态与值同时验证后才发布proof，禁止空值或工具失败的stdout参与身份/内容比较。
rootpxe_lh_hash() {
    local value
    value=$(rootpxe_ci_hash "$1") || return 1
    [[ $value =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$value"
}
rootpxe_lh_inode() {
    local value
    value=$(rootpxe_ci_inode "$1") || return 1
    [[ $value =~ ^[0-9]{1,20}:[1-9][0-9]{0,19}$ ]] || return 1
    printf '%s\n' "$value"
}
rootpxe_lh_verify_label() {
    local expected actual
    [[ -n ${rootpxe_ci_selinux_contexts:-} ]] || return 0
    expected=$(rootpxe_ci_expected_label "$2") || return 1
    [[ $expected =~ ^[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(:[A-Za-z0-9_,.-]+)?$ ]] || return 1
    actual=$(set -o pipefail; rootpxe_ci_read_label "$1") || return 1
    [[ $actual =~ ^[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(:[A-Za-z0-9_,.-]+)?$ && $actual == "$expected" ]]
}
rootpxe_lh_label_path() {
    rootpxe_ci_label_path "$1" "$2" && rootpxe_lh_verify_label "$1" "$2"
}
rootpxe_lh_file_safe() {
    local info uid gid mode links
    rootpxe_ci_metadata_safe "$1" file || return 1
    info=$(rootpxe_ci_stat "$1") || return 1
    IFS=: read -r uid gid mode links <<<"$info"
    (( (8#$mode & 07133) == 0 ))
}
rootpxe_lh_old_hostname() {
    local root="$1" old=''
    if [[ -f $root/etc/hostname ]]; then IFS= read -r old <"$root/etc/hostname" || :; fi
    old=${old%$'\r'}
    [[ ${#old} -le 253 && $old =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || old=''
    case ${old,,} in localhost|localhost.localdomain) old='';; esac
    printf '%s' "$old"
}
rootpxe_lh_render_hosts() {
    local root="$1" old="$2" name="$3" last='' newline=0
    if [[ ! -e $root/etc/hosts ]]; then printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$name"; return; fi
    if [[ -s $root/etc/hosts ]]; then
        last=$(tail -c 1 -- "$root/etc/hosts" | od -An -tx1) || return 1
        [[ ${last//[[:space:]]/} != 0a ]] || newline=1
    fi
    # 无关行、空白、注释和CRLF逐字保留；仅完整token参与替换，不推断FQDN后缀。
    LC_ALL=C awk -v BINMODE=3 -v old="$old" -v name="$name" -v trailing="$newline" '
      function loopback(ip, a,n,i) {
        if (ip == "::1") return 1
        n=split(ip,a,"."); if (n != 4 || a[1] != "127") return 0
        for (i=1;i<=4;i++) if (a[i] !~ /^[0-9]+$/ || length(a[i])>3 || a[i]+0>255) return 0
        return 1
      }
      function token_value(token) {
        column++
        if (column == 1) return token
        if (self && token == name) found=1
        if (self && !already && old != "" && token == old && tolower(token) != "localhost" && tolower(token) != "localhost.localdomain") { found=1; return name }
        return token
      }
      function render(prefix, out,token,ch,i) {
        out=""; token=""; column=0
        for(i=1;i<=length(prefix);i++) {
          ch=substr(prefix,i,1)
          if(ch ~ /[[:space:]]/) { if(token!="") {out=out token_value(token);token=""};out=out ch }
          else token=token ch
        }
        if(token!="") out=out token_value(token)
        return out
      }
      {
        hash=index($0,"#"); prefix=(hash ? substr($0,1,hash-1) : $0); comment=(hash ? substr($0,hash) : "")
        data=prefix; sub(/^[[:space:]]+/,"",data); n=split(data,fields,/[[:space:]]+/)
        self=loopback(fields[1]); already=0
        if(self) for(i=2;i<=n;i++) if(fields[i]==name) {already=1;found=1}
        if(NR>1) printf "\n"
        printf "%s%s",render(prefix),comment
      }
      END {
        if(trailing) printf "\n"
        if(!found) {if(NR && !trailing) printf "\n";printf "127.0.1.1 %s\n",name}
      }' "$root/etc/hosts"
}
rootpxe_linux_hostname_preflight() {
    local root="$1" path source mount_target rest actual expected old evidence
    rootpxe_linux_hostname_verified=no
    rootpxe_ci_is_root && rootpxe_ci_safe_write_directory "$root" /etc || { rootpxe_lh_reject linux_hostname_path_unsafe; return 1; }
    rootpxe_validate_linux_hostname "${hostName:-}" || { rootpxe_lh_reject linux_hostname_invalid; return 1; }
    for path in /etc /etc/hostname /etc/hosts; do
        ! mountpoint -q "$root$path" 2>/dev/null || { rootpxe_lh_reject linux_hostname_unsupported_mount; return 1; }
    done
    if [[ -e $root/etc/fstab || -L $root/etc/fstab ]]; then
        rootpxe_ci_metadata_safe "$root/etc/fstab" file || { rootpxe_lh_reject linux_hostname_path_unsafe; return 1; }
        while read -r source mount_target rest; do
            [[ -n $source && $source != \#* ]] || continue
            case $mount_target in /etc|/etc/*|*\\*) rootpxe_lh_reject linux_hostname_unsupported_mount; return 1;; esac
        done <"$root/etc/fstab"
    fi
    evidence=$(find "$root/etc" -mindepth 1 -maxdepth 1 -name '.rootpxe-hostname.*' -print -quit) || { rootpxe_lh_reject linux_hostname_path_unsafe; return 1; }
    [[ -z $evidence ]] || { rootpxe_lh_reject linux_hostname_transaction_evidence_present; return 1; }
    for path in /etc/hostname /etc/hosts; do
        [[ ! -e $root$path && ! -L $root$path ]] || rootpxe_lh_file_safe "$root$path" || { rootpxe_lh_reject linux_hostname_path_unsafe; return 1; }
        [[ ! -e $root$path ]] || rootpxe_lh_inode "$root$path" >/dev/null || { rootpxe_lh_reject linux_hostname_readback_failed; return 1; }
    done
    rootpxe_ci_target_selinux "$root" || { rootpxe_lh_reject linux_hostname_label_unverified; return 1; }
    if [[ -n ${rootpxe_ci_selinux_contexts:-} ]]; then
        rootpxe_ci_label_tools_ready || { rootpxe_lh_reject linux_hostname_label_tools_missing; return 1; }
        for path in /etc/hostname /etc/hosts; do
            [[ ! -e $root$path ]] || rootpxe_lh_verify_label "$root$path" "$path" || { rootpxe_lh_reject linux_hostname_label_unverified; return 1; }
        done
    fi
    [[ -f $root/etc/hostname && -f $root/etc/hosts ]] || return 0
    expected=$(set -o pipefail; printf '%s\n' "$hostName" | rootpxe_lh_hash -) && actual=$(rootpxe_lh_hash "$root/etc/hostname") || { rootpxe_lh_reject linux_hostname_readback_failed; return 1; }
    [[ $actual == "$expected" ]] || return 0
    old=$(rootpxe_lh_old_hostname "$root") || return 1
    expected=$(set -o pipefail; rootpxe_lh_render_hosts "$root" "$old" "$hostName" | rootpxe_lh_hash -) && actual=$(rootpxe_lh_hash "$root/etc/hosts") || { rootpxe_lh_reject linux_hostname_readback_failed; return 1; }
    [[ $actual != "$expected" ]] || rootpxe_linux_hostname_verified=yes
    return 0
}
rootpxe_lh_write_bytes() { cp -- "$1" "$2" 2>/dev/null; }
rootpxe_lh_owned_file_valid() {
    local path="$1" index actual
    rootpxe_ci_metadata_safe "$lh_stage" directory 700 && [[ -n $lh_stage_inode ]] && actual=$(rootpxe_lh_inode "$lh_stage") && [[ $actual == "$lh_stage_inode" ]] || return 1
    rootpxe_ci_metadata_safe "$path" file 600 || return 1
    for index in "${!lh_owned_paths[@]}"; do
        if [[ ${lh_owned_paths[$index]} == "$path" ]]; then
            actual=$(rootpxe_lh_inode "$path") && [[ -n ${lh_owned_inodes[$index]} && $actual == "${lh_owned_inodes[$index]}" ]]
            return $?
        fi
    done
    return 1
}
rootpxe_lh_transaction_cleanup() {
    local status="$1" index path actual_inode actual_hash actual_metadata result=0
    if [[ $status -ne 0 ]]; then
        for ((index=${#lh_paths[@]}-1; index>=0; index--)); do
            [[ ${lh_changed[$index]} == yes ]] || continue
            path=${lh_paths[$index]}
            if rootpxe_ci_safe_write_directory "$lh_root" /etc && [[ -f $path && ! -L $path && -n ${lh_final_inodes[$index]} ]] && actual_inode=$(rootpxe_lh_inode "$path") && [[ $actual_inode == "${lh_final_inodes[$index]}" ]]; then
                if [[ ${lh_existed[$index]} == yes ]]; then
                    rootpxe_lh_file_safe "$path" && actual_metadata=$(rootpxe_ci_stat "$path") && [[ $actual_metadata == "${lh_metadata[$index]}" ]] &&
                        rootpxe_lh_owned_file_valid "${lh_backups[$index]}" && actual_hash=$(rootpxe_lh_hash "${lh_backups[$index]}") && [[ $actual_hash == "${lh_old_hashes[$index]}" ]] &&
                        rootpxe_lh_write_bytes "${lh_backups[$index]}" "$path" && touch -r "${lh_backups[$index]}" -- "$path" &&
                        actual_hash=$(rootpxe_lh_hash "$path") && actual_metadata=$(rootpxe_ci_stat "$path") && [[ $actual_hash == "${lh_old_hashes[$index]}" && $actual_metadata == "${lh_metadata[$index]}" ]] &&
                        rootpxe_lh_verify_label "$path" "/etc/${path##*/}" || result=1
                else rootpxe_ci_metadata_safe "$path" file && rm -- "$path" || result=1; fi
            else result=1; fi
        done
        [[ $result -eq 0 ]] || return 67
    fi
    for ((index=${#lh_owned_paths[@]}-1; index>=0; index--)); do
        path=${lh_owned_paths[$index]}
        [[ ! -e $path && ! -L $path ]] && continue
        if rootpxe_lh_owned_file_valid "$path"; then rm -- "$path" || result=1; else result=1; fi
    done
    if [[ -n $lh_stage ]]; then
        if [[ -d $lh_stage && ! -L $lh_stage && -n $lh_stage_inode ]] && actual_inode=$(rootpxe_lh_inode "$lh_stage") && [[ $actual_inode == "$lh_stage_inode" ]]; then rmdir -- "$lh_stage" || result=1; else result=1; fi
    fi
    [[ $result -eq 0 ]] || return 68
}
rootpxe_lh_owned_file() {
    local path="$1" inode
    (set -o noclobber; : >"$path") || return 1
    inode=$(rootpxe_lh_inode "$path") || return 1
    lh_owned_paths+=("$path"); lh_owned_inodes+=("$inode")
    chmod 600 "$path" && chown 0:0 "$path" && rootpxe_ci_metadata_safe "$path" file 600
}
rootpxe_linux_hostname_write_at_root() {
    local root="$1" result=0
    rootpxe_initialization_failure_reason=''
    if (
        set -o pipefail
        local lh_root="$root" lh_stage='' lh_stage_inode='' file path staged backup index old status cleanup_result actual_inode actual_hash actual_metadata parent_inode
        local -a lh_paths=() lh_final_inodes=() lh_existed=() lh_metadata=() lh_old_hashes=() lh_backups=() lh_changed=() lh_new_hashes=() lh_owned_paths=() lh_owned_inodes=()
        trap 'status=$?; if rootpxe_lh_transaction_cleanup "$status"; then exit "$status"; else cleanup_result=$?; exit "$cleanup_result"; fi' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        umask 077
        rootpxe_linux_hostname_preflight "$root" || exit 61
        [[ $rootpxe_linux_hostname_verified != yes ]] || exit 0
        old=$(rootpxe_lh_old_hostname "$root") || exit 65
        lh_stage=$(mktemp -d "$root/etc/.rootpxe-hostname.XXXXXX") || exit 66
        lh_stage_inode=$(rootpxe_lh_inode "$lh_stage") || exit 66
        rootpxe_ci_metadata_safe "$lh_stage" directory 700 && parent_inode=$(rootpxe_lh_inode "$root/etc") && [[ ${lh_stage_inode%%:*} == "${parent_inode%%:*}" ]] || exit 61
        rootpxe_lh_label_path "$lh_stage" /etc || exit 64
        for file in hostname hosts; do
            path="$root/etc/$file"; staged="$lh_stage/$file.new"; backup="$lh_stage/$file.old"
            lh_paths+=("$path"); lh_changed+=(no); lh_backups+=("$backup")
            if [[ -e $path ]]; then
                rootpxe_lh_file_safe "$path" || exit 61
                actual_inode=$(rootpxe_lh_inode "$path") && actual_metadata=$(rootpxe_ci_stat "$path") && actual_hash=$(rootpxe_lh_hash "$path") || exit 65
                lh_existed+=(yes); lh_final_inodes+=("$actual_inode"); lh_metadata+=("$actual_metadata"); lh_old_hashes+=("$actual_hash")
                rootpxe_lh_owned_file "$backup" && cp -- "$path" "$backup" && touch -r "$path" -- "$backup" || exit 66
                actual_hash=$(rootpxe_lh_hash "$backup") && [[ $actual_hash == "${lh_old_hashes[${#lh_old_hashes[@]}-1]}" ]] || exit 65
            else lh_existed+=(no); lh_final_inodes+=(''); lh_metadata+=('0:0:644:1'); lh_old_hashes+=(''); fi
            rootpxe_lh_owned_file "$staged" || exit 66
            if [[ $file == hostname ]]; then printf '%s\n' "$hostName" >"$staged" || exit 66
            else rootpxe_lh_render_hosts "$root" "$old" "$hostName" >"$staged" || exit 66; fi
            rootpxe_lh_label_path "$staged" "/etc/$file" && rootpxe_ci_metadata_safe "$staged" file 600 || exit 64
            actual_hash=$(rootpxe_lh_hash "$staged") || exit 65
            lh_new_hashes+=("$actual_hash")
        done
        for index in "${!lh_paths[@]}"; do
            path=${lh_paths[$index]}; file=${path##*/}; staged="$lh_stage/$file.new"
            rootpxe_ci_safe_write_directory "$root" /etc || exit 61
            rootpxe_lh_owned_file_valid "$staged" && actual_hash=$(rootpxe_lh_hash "$staged") && [[ $actual_hash == "${lh_new_hashes[$index]}" ]] || exit 65
            if [[ ${lh_existed[$index]} == yes ]]; then
                rootpxe_lh_file_safe "$path" && actual_inode=$(rootpxe_lh_inode "$path") && actual_metadata=$(rootpxe_ci_stat "$path") && actual_hash=$(rootpxe_lh_hash "$path") && [[ $actual_inode == "${lh_final_inodes[$index]}" && $actual_metadata == "${lh_metadata[$index]}" && $actual_hash == "${lh_old_hashes[$index]}" ]] || exit 61
            else
                (set -o noclobber; : >"$path") || exit 61
                lh_changed[$index]=yes
                actual_inode=$(rootpxe_lh_inode "$path") || exit 66
                lh_final_inodes[$index]=$actual_inode
                chmod 644 "$path" && chown 0:0 "$path" && rootpxe_lh_label_path "$path" "/etc/$file" || exit 64
            fi
            lh_changed[$index]=yes
            rootpxe_lh_write_bytes "$staged" "$path" || exit 66
            if [[ ${lh_existed[$index]} == yes ]]; then touch -r "${lh_backups[$index]}" -- "$path" || exit 66; fi
            rootpxe_lh_file_safe "$path" && actual_inode=$(rootpxe_lh_inode "$path") && actual_metadata=$(rootpxe_ci_stat "$path") && actual_hash=$(rootpxe_lh_hash "$path") && [[ $actual_inode == "${lh_final_inodes[$index]}" && $actual_metadata == "${lh_metadata[$index]}" && $actual_hash == "${lh_new_hashes[$index]}" ]] && rootpxe_lh_verify_label "$path" "/etc/$file" || exit 65
        done
    ); then result=0; else
        result=$?
        case $result in
            61) rootpxe_initialization_failure_reason=linux_hostname_preflight_or_path_rejected;;
            64) rootpxe_initialization_failure_reason=linux_hostname_label_unverified;;
            65) rootpxe_initialization_failure_reason=linux_hostname_readback_failed;;
            67) rootpxe_initialization_failure_reason=linux_hostname_rollback_failed;;
            68) rootpxe_initialization_failure_reason=linux_hostname_cleanup_failed;;
            *) rootpxe_initialization_failure_reason=linux_hostname_write_failed;;
        esac
    fi
    return "$result"
}
rootpxe_linux_hostname_process_root() {
    local disk="$1" candidate="$2" mode="$3" device fs vg uuid subvol extra work owned=no result=0 ci_mounted_root=''
    local -a ci_owned_mounts=() ci_vg_names=() ci_vg_uuids=() ci_vg_owned=()
    IFS='|' read -r device fs vg uuid subvol extra <<<"$candidate"
    [[ $device == /dev/* && -z $subvol && -z $extra ]] || return 1
    case $fs in ext2|ext3|ext4|xfs) ;; *) return 1;; esac
    rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1
    work=$(mktemp -d /tmp/rootpxe-cloud-mount.XXXXXX) || return 1
    if [[ -n $vg ]]; then
        owned=$(rootpxe_linux_activate_vg_if_needed "$disk" "$vg" "$uuid") || result=1
        if [[ $owned == yes ]]; then ci_vg_names+=("$vg"); ci_vg_uuids+=("$uuid"); ci_vg_owned+=(yes); fi
    fi
    if [[ $result -eq 0 ]]; then rootpxe_ci_mount_root "$device" "$fs" "$work" "$mode" || result=1; fi
    if [[ $result -eq 0 ]]; then
        if [[ $mode == ro ]]; then rootpxe_linux_hostname_preflight "$ci_mounted_root" || result=1
        else rootpxe_linux_hostname_write_at_root "$ci_mounted_root" || result=1; fi
    fi
    rootpxe_ci_cleanup_mounts || { result=1; rootpxe_initialization_failure_reason=linux_hostname_mount_cleanup_failed; }
    rootpxe_ci_workspace_remove "$work" || { result=1; rootpxe_initialization_failure_reason=linux_hostname_probe_cleanup_failed; }
    return "$result"
}
rootpxe_apply_linux_hostname_for_targets() {
    local rootpxe_cloud_init_allowed_disks="$*" rootpxe_cloud_init_probe_disk='' rootpxe_linux_selected_disk='' rootpxe_linux_selected_candidate='' disk
    rootpxe_deployment_identity_hostname_result=false
    rootpxe_linux_hostname_task_valid || { rootpxe_lh_reject linux_hostname_policy_invalid; return 1; }
    rootpxe_cloud_init_policy_enabled && return 1
    rootpxe_validate_linux_hostname "${hostName:-}" || { rootpxe_lh_reject linux_hostname_invalid; return 1; }
    rootpxe_linux_select_unique_root_for_targets "$@" || { rootpxe_lh_reject linux_hostname_unique_permitted_root_required; return 1; }
    rootpxe_stage customizing_hostname 'configuring offline Linux hostname'
    rootpxe_linux_hostname_process_root "$rootpxe_linux_selected_disk" "$rootpxe_linux_selected_candidate" ro || return 1
    if [[ $rootpxe_linux_hostname_verified != yes ]]; then
        for disk in "$@"; do rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1; done
        rootpxe_linux_hostname_process_root "$rootpxe_linux_selected_disk" "$rootpxe_linux_selected_candidate" rw || return 1
    fi
    rootpxe_deployment_identity_hostname_result=true
}
