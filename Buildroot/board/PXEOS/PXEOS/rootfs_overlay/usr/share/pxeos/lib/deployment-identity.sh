#!/bin/bash
# Deployment identity v1.  This library deliberately consumes only the
# server-frozen plan; it never generates disk IDs, filesystem UUIDs or keys.

rootpxe_deployment_identity_policy_enabled() {
    [[ -r ${deploymentIdentityPolicyFile:-} ]] || return 1
    [[ ${changeHostname:-false} == true ]] || jq -e '.version == 1 and ((.systemIdentity.machineId == true) or (.systemIdentity.sshHostKeys == true) or (.systemIdentity.sshLoginPublicKeys == true) or (.systemIdentity.rootPassword == true) or (.systemIdentity.sysprep == true))' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
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
    for tool in jq; do
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

rootpxe_deployment_identity_request_plan() {
    local api="${pxeapi:-${web:-}}" request response body code file
    rootpxe_deployment_identity_policy_enabled || return 0
    [[ -n $api && ${taskid:-} =~ ^[1-9][0-9]*$ && -n ${task_token:-} && -n ${mac:-} && ${progress_attempt:-} =~ ^[1-9][0-9]*$ ]] || return 1
    api="${api%/}/"
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --argjson attempt "$progress_attempt" '{taskId:$taskId,token:$token,mac:$mac,attempt:$attempt}') || return 1
    response=$(curl -Lks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-identity-plan" 2>/dev/null) || return 1
    code=${response##*$'\n'}; body=${response%$'\n'*}
    [[ $code == 200 ]] || return 1
    file=$(mktemp /tmp/rootpxe-deployment-identity-plan.XXXXXX) || return 1
    chmod 0600 "$file" || { rm -f -- "$file"; return 1; }
    printf '%s' "$body" >"$file" || { rm -f -- "$file"; return 1; }
    jq -e --argjson attempt "$progress_attempt" '.plan.version == 1 and (.plan.planId|type == "string" and length > 0) and (.planHash|type == "string" and length == 64) and .attempt == $attempt' "$file" >/dev/null || { rm -f -- "$file"; return 1; }
    rootpxe_deployment_identity_plan_file="$file"; export rootpxe_deployment_identity_plan_file
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

rootpxe_deployment_identity_target_device_is_block() {
    [[ $1 == /dev/* && -b $1 ]]
}

rootpxe_deployment_identity_mount_matches_device() {
    local mountpoint="$1" device="$2" actual_dev expected_dev
    actual_dev=$(/usr/bin/stat -c '%d' "$mountpoint" 2>/dev/null | tr -d '\r\n') || return 1
    expected_dev=$(/usr/bin/stat -c '%r' "$device" 2>/dev/null | tr -d '\r\n') || return 1
    [[ -n $actual_dev && $actual_dev == "$expected_dev" ]]
}

rootpxe_deployment_identity_linux_fstab_source_device() {
    local source="$1" identifier device=""
    case "$source" in
        UUID=*)
            identifier=$(rootpxe_deployment_identity_fstab_identifier "${source#UUID=}") || return 1
            device=$(blkid -U "$identifier" 2>/dev/null || true)
            ;;
        PARTUUID=*)
            identifier=$(rootpxe_deployment_identity_fstab_identifier "${source#PARTUUID=}") || return 1
            device=$(blkid -t "PARTUUID=$identifier" -o device 2>/dev/null || true)
            ;;
        /dev/*) device="$source" ;;
        *) return 1 ;;
    esac
    device=${device//$'\r'/}; device=${device//$'\n'/}
    [[ -n $device ]] || return 1
    [[ $device == /dev/* ]] || return 1
    printf '%s\n' "$device"
}

# /var can be a separate target filesystem.  Mount it only when its fstab
# source resolves to a device present in the immutable deployment plan; retain
# ownership so cleanup never unmounts a borrowed mount.
rootpxe_deployment_identity_mount_linux_var_filesystem() {
    local root="$1" source="" target="" declared_fs="" device fs options count=0
    rootpxe_deployment_identity_var_mount=""
    [[ -e $root/etc/fstab ]] || return 0
    rootpxe_deployment_identity_safe_target_file "$root" "$root/etc/fstab" || return 1
    while IFS=$'\t' read -r source target declared_fs; do
        [[ $target == /var ]] || continue
        count=$((count + 1))
        [[ $count -eq 1 && -n $source && -n $declared_fs ]] || return 1
        rootpxe_deployment_identity_var_source="$source"
        rootpxe_deployment_identity_var_fs="${declared_fs,,}"
    done < <(awk '!/^[[:space:]]*#/ && NF >= 3 {print $1 "\t" $2 "\t" $3}' "$root/etc/fstab")
    [[ $count -eq 0 ]] && return 0
    source=${rootpxe_deployment_identity_var_source:-}; declared_fs=${rootpxe_deployment_identity_var_fs:-}
    unset rootpxe_deployment_identity_var_source rootpxe_deployment_identity_var_fs
    device=$(rootpxe_deployment_identity_linux_fstab_source_device "$source") || return 1
    [[ -d $root/var && ! -L $root/var ]] && rootpxe_deployment_identity_target_device_is_block "$device" || return 1
    fs=$(blkid -s TYPE -o value "$device" 2>/dev/null | tr -d '\r\n' | tr '[:upper:]' '[:lower:]') || return 1
    [[ $declared_fs == "$fs" || ( $declared_fs == fat* && $fs == vfat ) ]] || return 1
    case $fs in vfat|ext2|ext3|ext4|xfs) ;; *) return 1 ;; esac
    if mountpoint -q "$root/var" 2>/dev/null; then
        rootpxe_deployment_identity_mount_matches_device "$root/var" "$device"
        return $?
    fi
    options=$(rootpxe_linux_mount_options rw "$fs") || return 1
    mount -t "$fs" -o "$options" "$device" "$root/var" || return 1
    rootpxe_deployment_identity_mount_matches_device "$root/var" "$device" || { umount "$root/var" >/dev/null 2>&1 || true; return 1; }
    rootpxe_deployment_identity_var_mount="$root/var"
}

rootpxe_deployment_identity_unmount_linux_var_filesystem() {
    local mountpoint="${rootpxe_deployment_identity_var_mount:-}"
    rootpxe_deployment_identity_var_mount=""
    [[ -n $mountpoint ]] || return 0
    umount "$mountpoint" >/dev/null 2>&1
}

rootpxe_deployment_identity_report_result() {
    local hostname="$1" machine_id="$2" ssh_host_keys="$3" ssh_login_public_keys="$4" root_password="$5" sysprep="$6" api request response http_code
    rootpxe_deployment_identity_policy_enabled || return 0
    [[ -r ${rootpxe_deployment_identity_plan_file:-} ]] || return 1
    api="${pxeapi:-${web:-}}"; [[ -n $api ]] || return 1
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --arg planId "$(jq -r '.plan.planId' "$rootpxe_deployment_identity_plan_file")" --arg planHash "$(jq -r '.planHash' "$rootpxe_deployment_identity_plan_file")" --argjson attempt "$progress_attempt" --argjson hostname "$hostname" --argjson machineId "$machine_id" --argjson sshHostKeys "$ssh_host_keys" --argjson sshLoginPublicKeys "$ssh_login_public_keys" --argjson rootPassword "$root_password" --argjson sysprep "$sysprep" '{taskId:$taskId,token:$token,mac:$mac,planId:$planId,planHash:$planHash,attempt:$attempt,result:{hostname:$hostname,machineId:$machineId,sshHostKeys:$sshHostKeys,sshLoginPublicKeys:$sshLoginPublicKeys,rootPassword:$rootPassword,sysprep:$sysprep}}') || return 1
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

rootpxe_deployment_identity_ssh_normalize_target_path() {
    local path="$1" segment
    local -a raw parts=()
    [[ $path == /* ]] || return 1
    IFS=/ read -r -a raw <<<"${path#/}"
    for segment in "${raw[@]}"; do
        case $segment in
            ''|.) ;;
            ..) (( ${#parts[@]} > 0 )) || return 1; unset 'parts[${#parts[@]}-1]' ;;
            *) parts+=("$segment") ;;
        esac
    done
    printf '/%s\n' "$(IFS=/; printf '%s' "${parts[*]}")"
}

# Resolve target-root paths without interpreting absolute links in PXEOS.
rootpxe_deployment_identity_ssh_resolve_target_path() {
    local root="$1" requested="$2" path pending cursor target remainder segment candidate hops=0 i j
    local -a parts
    [[ $root == /* && -d $root && ! -L $root && $requested == /* ]] || return 1
    path="$requested"
    while :; do
        (( hops++ < 16 )) || return 1
        pending=${path#/}; cursor=''
        IFS=/ read -r -a parts <<<"$pending"
        for ((i=0; i<${#parts[@]}; i++)); do
            segment=${parts[$i]}
            case $segment in
                ''|.) continue ;;
                ..) [[ -n $cursor ]] || return 1; cursor=${cursor%/*}; continue ;;
            esac
            candidate="$root$cursor/$segment"
            if [[ -L $candidate ]]; then
                target=$(readlink "$candidate") || return 1; remainder=''
                for ((j=i+1; j<${#parts[@]}; j++)); do remainder="$remainder/${parts[$j]}"; done
                if [[ $target == /* ]]; then path="$target$remainder"; else path="$cursor/$target$remainder"; fi
                continue 2
            fi
            [[ -e $candidate ]] || return 1
            cursor="$cursor/$segment"
        done
        [[ -n $cursor && -e "$root$cursor" && ! -L "$root$cursor" ]] || return 1
        printf '%s\n' "$root$cursor"; return 0
    done
}

rootpxe_deployment_identity_ssh_split_line() {
    local line="$1" char quote='' token='' escaped=0 i
    rootpxe_deployment_identity_ssh_fields=()
    for ((i=0; i<${#line}; i++)); do
        char=${line:i:1}
        if (( escaped )); then token+="$char"; escaped=0; continue; fi
        if [[ -n $quote ]]; then if [[ $char == "$quote" ]]; then quote=''; else token+="$char"; fi; continue; fi
        case $char in
            "'"|'"') quote=$char ;;
            \\) escaped=1 ;;
            '#') break ;;
            $' '|$'\t'|$'\r') if [[ -n $token ]]; then rootpxe_deployment_identity_ssh_fields+=("$token"); token=''; fi ;;
            *) token+="$char" ;;
        esac
    done
    [[ -z $quote && $escaped == 0 ]] || return 1
    [[ -z $token ]] || rootpxe_deployment_identity_ssh_fields+=("$token")
}

rootpxe_deployment_identity_ssh_include_allowed() {
    case $1 in /etc/ssh/*|/usr/etc/ssh/*|/etc/crypto-policies/back-ends/*|/usr/share/crypto-policies/*) return 0;; *) return 1;; esac
}

# Missing Include patterns are allowed by OpenSSH, but a dangling or escaping
# symlink is not an empty pattern.  Stop at the first missing ordinary path.
rootpxe_deployment_identity_ssh_path_is_plain_missing() {
    local root="$1" requested="$2" pending cursor='' segment candidate
    local -a parts
    [[ $requested == /* ]] || return 1
    pending=${requested#/}; IFS=/ read -r -a parts <<<"$pending"
    for segment in "${parts[@]}"; do
        case $segment in ''|.) continue;; ..) [[ -n $cursor ]] || return 1; cursor=${cursor%/*}; continue;; esac
        candidate="$root$cursor/$segment"
        [[ -L $candidate ]] && return 1
        [[ -e $candidate ]] || return 0
        cursor="$cursor/$segment"
    done
    return 1
}

rootpxe_deployment_identity_ssh_include_matches() {
    local root="$1" pattern="$2" target policy_target parent base resolved_parent match resolved
    local -a matches=()
    if [[ $pattern == /* ]]; then target="$pattern"; else target="/etc/ssh/$pattern"; fi
    # Policy validation is lexical only; resolution below remains component by
    # component so `link/../x` observes the link target's parent as OpenSSH does.
    policy_target=$(rootpxe_deployment_identity_ssh_normalize_target_path "$target") || return 1
    rootpxe_deployment_identity_ssh_include_allowed "$policy_target" || return 1
    if [[ $target == *'*'* || $target == *'?'* || $target == *'['* ]]; then
        parent=${target%/*}; base=${target##*/}
        if ! resolved_parent=$(rootpxe_deployment_identity_ssh_resolve_target_path "$root" "$parent"); then
            rootpxe_deployment_identity_ssh_path_is_plain_missing "$root" "$parent" && return 0
            return 1
        fi
        while IFS= read -r match; do matches+=("$match"); done < <(compgen -G "$resolved_parent/$base" | LC_ALL=C sort || true)
        for match in "${matches[@]}"; do rootpxe_deployment_identity_ssh_resolve_target_path "$root" "${match#"$root"}" || return 1; done
    else
        if ! resolved=$(rootpxe_deployment_identity_ssh_resolve_target_path "$root" "$target"); then
            rootpxe_deployment_identity_ssh_path_is_plain_missing "$root" "$target" && return 0
            return 1
        fi
        printf '%s\n' "$resolved"
    fi
}

# Print directives after bounded Include expansion at the Include source point.
rootpxe_deployment_identity_ssh_config_stream() {
    local root="$1" requested="$2" depth="${3:-0}" file line directive include include_output
    local -a includes
    (( depth < 12 )) || return 1
    file=$(rootpxe_deployment_identity_ssh_resolve_target_path "$root" "$requested") || return 1
    for include in "${rootpxe_deployment_identity_ssh_config_stack[@]:-}"; do [[ $include != "$file" ]] || return 1; done
    rootpxe_deployment_identity_ssh_config_stack+=("$file")
    while IFS= read -r line || [[ -n $line ]]; do
        rootpxe_deployment_identity_ssh_split_line "$line" || return 1
        (( ${#rootpxe_deployment_identity_ssh_fields[@]} > 0 )) || continue
        directive=${rootpxe_deployment_identity_ssh_fields[0],,}
        case $directive in
            match)
                printf 'match'; for include in "${rootpxe_deployment_identity_ssh_fields[@]:1}"; do printf '%s' "$include"; done; printf '
'
                ;;
            include)
                (( ${#rootpxe_deployment_identity_ssh_fields[@]} > 1 )) || return 1
                includes=("${rootpxe_deployment_identity_ssh_fields[@]:1}")
                for include in "${includes[@]}"; do
                    include_output=$(rootpxe_deployment_identity_ssh_include_matches "$root" "$include") || return 1
                    while IFS= read -r file || [[ -n $file ]]; do
                        [[ -n $file ]] || continue
                        rootpxe_deployment_identity_ssh_config_stream "$root" "${file#"$root"}" "$((depth + 1))" || return 1
                    done <<<"$include_output"
                done ;;
            *)
                printf '%s' "$directive"; for include in "${rootpxe_deployment_identity_ssh_fields[@]:1}"; do printf '\037%s' "$include"; done; printf '\n' ;;
        esac
    done <"$file"
    unset 'rootpxe_deployment_identity_ssh_config_stack[${#rootpxe_deployment_identity_ssh_config_stack[@]}-1]'
}

rootpxe_deployment_identity_ssh_directive_stream() {
    local root="$1" config="$root/etc/ssh/sshd_config"
    rootpxe_deployment_identity_ssh_config_stack=()
    [[ ! -e $config && ! -L $config ]] && return 0
    rootpxe_deployment_identity_ssh_config_stream "$root" /etc/ssh/sshd_config
}

# Root public keys are fixed at /root/.ssh/authorized_keys.  We proceed only
# when the effective sshd configuration selects that exact path.
rootpxe_deployment_identity_root_authorized_keys_relative() {
    local root="$1" stream record directive value extra result=''
    [[ -d $root/etc/ssh && ! -L $root/etc/ssh ]] || return 1
    stream=$(rootpxe_deployment_identity_ssh_directive_stream "$root") || return 1
    while IFS= read -r record || [[ -n $record ]]; do
        IFS=$'\037' read -r directive value extra <<<"$record"
        [[ $directive == match ]] && return 1
        [[ $directive == authorizedkeysfile ]] || continue
        [[ -n $result ]] && continue
        [[ -n $value && -z $extra ]] || return 1
        case $value in .ssh/authorized_keys|/root/.ssh/authorized_keys) result=.ssh/authorized_keys;; *) return 1;; esac
    done <<<"$stream"
    printf '%s\n' "${result:-.ssh/authorized_keys}"
}

rootpxe_deployment_identity_ssh_host_key_paths() {
    local root="$1" ssh_dir path
    ssh_dir="$root/etc/ssh"
    [[ -d $ssh_dir && ! -L $ssh_dir ]] || return 1
    shopt -s nullglob
    for path in "$ssh_dir"/ssh_host_*_key "$ssh_dir"/ssh_host_*_key.pub; do
        [[ -e $path || -L $path ]] || continue
        [[ -f $path && ! -L $path ]] || { shopt -u nullglob; return 1; }
        printf '%s\0' "$path"
    done
    shopt -u nullglob
}

# Process substitution hides the producer's exit status.  Capture the
# NUL-delimited list in /tmp first so a symlink or other unsafe key file never
# turns into an empty, apparently-successful list in a caller.
rootpxe_deployment_identity_collect_ssh_host_key_paths() {
    local root="$1" list path
    rootpxe_deployment_identity_ssh_host_key_paths_result=()
    list=$(mktemp /tmp/rootpxe-ssh-host-keys.XXXXXX) || return 1
    if ! rootpxe_deployment_identity_ssh_host_key_paths "$root" >"$list"; then
        rm -f -- "$list"
        return 1
    fi
    while IFS= read -r -d '' path; do
        [[ $path == "$root"/etc/ssh/ssh_host_*_key || $path == "$root"/etc/ssh/ssh_host_*_key.pub ]] || { rm -f -- "$list"; return 1; }
        [[ -f $path && ! -L $path ]] || { rm -f -- "$list"; return 1; }
        rootpxe_deployment_identity_ssh_host_key_paths_result+=("$path")
    done <"$list"
    rm -f -- "$list"
}

rootpxe_deployment_identity_linux_reset_state_valid() {
    local root="$1" marker="$2" plan="$3" dbus_path path
    [[ -f $marker && ! -L $marker ]] || return 1
    jq -e --arg planHash "$(jq -r '.planHash' "$plan")" '.version == 1 and .planHash == $planHash' "$marker" >/dev/null 2>&1 || return 1
    if jq -e '.systemIdentity.machineId == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        dbus_path=$(rootpxe_deployment_identity_machine_id_etc_path "$root") || return 1
        [[ -n $dbus_path && ! -s $dbus_path ]] || return 1
        dbus_path="$root/var/lib/dbus/machine-id"
        rootpxe_deployment_identity_machine_id_dbus_path "$root" || return 1
        [[ ! -f $dbus_path || ! -s $dbus_path ]] || return 1
        rootpxe_deployment_identity_machine_id_result=true
    fi
    if jq -e '.systemIdentity.sshHostKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        rootpxe_deployment_identity_collect_ssh_host_key_paths "$root" || return 1
        (( ${#rootpxe_deployment_identity_ssh_host_key_paths_result[@]} == 0 )) || return 1
        rootpxe_deployment_identity_ssh_host_keys_result=true
    fi
}

rootpxe_deployment_identity_machine_id_dbus_link_target_safe() {
    [[ $1 == /etc/machine-id || $1 == ../../../etc/machine-id ]]
}

rootpxe_deployment_identity_machine_id_etc_path() {
    local root="$1" path target
    path="$root/etc/machine-id"
    [[ -d $root/etc && ! -L $root/etc ]] || return 1
    [[ -e $path || -L $path ]] || return 0
    if [[ -L $path ]]; then
        target=$(readlink "$path") || return 1
        # Never follow an arbitrary link through the PXEOS namespace.
        [[ $target == ../var/lib/dbus/machine-id ]] || return 1
        [[ -f $root/var/lib/dbus/machine-id && ! -L $root/var/lib/dbus/machine-id ]] || return 1
        printf '%s\n' "$root/var/lib/dbus/machine-id"
        return 0
    fi
    [[ -f $path && ! -L $path ]] || return 1
    printf '%s\n' "$path"
}

rootpxe_deployment_identity_clear_machine_id() {
    local root="$1" path tmp
    path=$(rootpxe_deployment_identity_machine_id_etc_path "$root") || return 1
    if [[ -z $path ]]; then
        tmp=$(mktemp "$root/etc/.machine-id.rootpxe.XXXXXX") || return 1
        : >"$tmp" && chmod 0444 "$tmp" && mv -f -- "$tmp" "$root/etc/machine-id" || { rm -f -- "$tmp"; return 1; }
        return 0
    fi
    : >"$path" || return 1
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

# Validate relabel prerequisites without creating .autorelabel.  All selected
# identity changes use this before their first target-side write.
rootpxe_deployment_identity_selinux_relabel_preflight() {
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
    service="$root/usr/lib/systemd/system/selinux-autorelabel-mark.service"
    [[ -f $service && ! -L $service ]] || return 1
    [[ ( ! -e $marker && ! -L $marker ) || ( -f $marker && ! -L $marker ) ]]
}

rootpxe_deployment_identity_linux_login_preflight() {
    local root="$1" private="${rootpxe_deployment_initialization_private_file:-}" line key_blob hash home authorized
    [[ -r $private && ! -L $private ]] || { rootpxe_deployment_identity_private_enabled || return 0; return 1; }
    if jq -e '.systemIdentity.sshLoginPublicKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        rootpxe_deployment_identity_safe_target_file "$root" "$root/etc/passwd" || return 1
        home=$(awk -F: '$1=="root" && $3=="0" {count++; value=$6} END {if(count==1) print value; else exit 1}' "$root/etc/passwd") || return 1
        [[ $home == /root ]] || return 1
        [[ $(rootpxe_deployment_identity_root_authorized_keys_relative "$root") == .ssh/authorized_keys ]] || return 1
        authorized="$root/root/.ssh/authorized_keys"
        [[ -d $root/root && ! -L $root/root && ( ( ! -e $root/root/.ssh && ! -L $root/root/.ssh ) || ( -d $root/root/.ssh && ! -L $root/root/.ssh ) ) ]] || return 1
        [[ ( ! -e $authorized && ! -L $authorized ) || ( -f $authorized && ! -L $authorized ) ]] || return 1
        jq -e '(.sshLoginPublicKeys | type == "array" and length > 0) and all(.sshLoginPublicKeys[]; type == "string" and length > 0 and length <= 16384)' "$private" >/dev/null 2>&1 || return 1
        while IFS= read -r line; do
            case "$line" in ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;; *) return 1;; esac
            key_blob=$(awk '{print $2; exit}' <<<"$line")
            [[ $key_blob =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
        done < <(jq -r '.sshLoginPublicKeys[]' "$private")
    fi
    if jq -e '.systemIdentity.rootPassword == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        hash=$(jq -r '.rootPasswordHash' "$private" 2>/dev/null) || return 1
        [[ $hash == '$6$'* && ${#hash} -le 512 ]] || return 1
        rootpxe_deployment_identity_safe_target_file "$root" "$root/etc/shadow" || return 1
        awk -F: '$1=="root" {count++} END {exit count==1?0:1}' "$root/etc/shadow" || return 1
    fi
}

rootpxe_deployment_identity_linux_system_preflight_mounted() {
    local root="$1" plan="${rootpxe_deployment_identity_plan_file:-}" ssh_dir path private_selected=false
    [[ -d $root/etc && ! -L $root/etc && -r $plan ]] || return 1
    [[ -d $root/var/lib && ! -L $root/var && ! -L $root/var/lib && ( ( ! -e $root/var/lib/rootpxe && ! -L $root/var/lib/rootpxe ) || ( -d $root/var/lib/rootpxe && ! -L $root/var/lib/rootpxe ) ) ]] || return 1
    [[ ( ! -e $root/var/lib/rootpxe/deployment-identity-v1 && ! -L $root/var/lib/rootpxe/deployment-identity-v1 ) || ( -f $root/var/lib/rootpxe/deployment-identity-v1 && ! -L $root/var/lib/rootpxe/deployment-identity-v1 ) ]] || return 1
    if jq -e '.systemIdentity.machineId == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        rootpxe_deployment_identity_machine_id_etc_path "$root" >/dev/null || return 1
        rootpxe_deployment_identity_machine_id_dbus_path "$root" || return 1
        private_selected=true
    fi
    if jq -e '.systemIdentity.sshHostKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        ssh_dir="$root/etc/ssh"; [[ -d $ssh_dir && ! -L $ssh_dir ]] || return 1
        rootpxe_deployment_identity_collect_ssh_host_key_paths "$root" || return 1
        private_selected=true
    fi
    if rootpxe_deployment_identity_private_enabled; then
        rootpxe_deployment_identity_linux_login_preflight "$root" || return 1
        if jq -e '.systemIdentity.sshLoginPublicKeys == true or .systemIdentity.rootPassword == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then private_selected=true; fi
    fi
    [[ $private_selected != true ]] || rootpxe_deployment_identity_selinux_relabel_preflight "$root"
}

rootpxe_deployment_identity_linux_system_preflight() {
    local root="$1" rc
    rootpxe_deployment_identity_mount_linux_var_filesystem "$root" || return 1
    rootpxe_deployment_identity_linux_system_preflight_mounted "$root"
    rc=$?
    rootpxe_deployment_identity_unmount_linux_var_filesystem || rc=1
    return "$rc"
}

rootpxe_deployment_identity_linux_system_in_root_mounted() {
    local root="$1" plan="${rootpxe_deployment_identity_plan_file:-}" marker ssh_dir path dbus_path marker_tmp
    rootpxe_deployment_identity_linux_policy_enabled || return 0
    if jq -e '.systemIdentity.machineId == true or .systemIdentity.sshHostKeys == true or .systemIdentity.sshLoginPublicKeys == true or .systemIdentity.rootPassword == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        rootpxe_deployment_identity_request_selinux_relabel "$root" || return 1
    fi
    rootpxe_deployment_identity_safe_target_dir "$root" var/lib/rootpxe || return 1
    marker="$root/var/lib/rootpxe/deployment-identity-v1"
    if rootpxe_deployment_identity_linux_reset_state_valid "$root" "$marker" "$plan"; then
        # Private login initialization is independently frozen.  A marker from
        # an earlier attempt only proves machine-id/host-key reset work; it must not
        # skip public-key or root-password application and result reporting.
        rootpxe_deployment_identity_linux_login_in_root "$root"
        return $?
    fi
    if jq -e '.systemIdentity.machineId == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        rootpxe_deployment_identity_clear_machine_id "$root" || return 1
        dbus_path="$root/var/lib/dbus/machine-id"
        rootpxe_deployment_identity_machine_id_dbus_path "$root" || return 1
        if [[ -e $dbus_path && ! -L $dbus_path ]]; then
            : >"$dbus_path" || return 1
        fi
        path=$(rootpxe_deployment_identity_machine_id_etc_path "$root") || return 1
        [[ -n $path && ! -s $path && ( ! -f $dbus_path || ! -s $dbus_path ) ]] || return 1
        rootpxe_deployment_identity_machine_id_result=true
    fi
    if jq -e '.systemIdentity.sshHostKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
        ssh_dir="$root/etc/ssh"; [[ -d $ssh_dir && ! -L $ssh_dir ]] || return 1
        rootpxe_deployment_identity_collect_ssh_host_key_paths "$root" || return 1
        for path in "${rootpxe_deployment_identity_ssh_host_key_paths_result[@]}"; do rm -f -- "$path" || return 1; done
        rootpxe_deployment_identity_collect_ssh_host_key_paths "$root" || return 1
        (( ${#rootpxe_deployment_identity_ssh_host_key_paths_result[@]} == 0 )) || return 1
        rootpxe_deployment_identity_ssh_host_keys_result=true
    fi
	rootpxe_deployment_identity_linux_login_in_root "$root" || return 1
    [[ ( ! -e $marker && ! -L $marker ) || ( -f $marker && ! -L $marker ) ]] || return 1
    marker_tmp=$(mktemp "$root/var/lib/rootpxe/.deployment-identity-v1.XXXXXX") || return 1
    jq -cn --arg planHash "$(jq -r '.planHash' "$plan")" --argjson machineId "${rootpxe_deployment_identity_machine_id_result:-false}" --argjson sshHostKeys "${rootpxe_deployment_identity_ssh_host_keys_result:-false}" '{version:1,planHash:$planHash,machineId:$machineId,sshHostKeys:$sshHostKeys}' >"$marker_tmp" || { rm -f -- "$marker_tmp"; return 1; }
    chmod 0600 "$marker_tmp" && mv -f -- "$marker_tmp" "$marker" || { rm -f -- "$marker_tmp"; return 1; }
}

rootpxe_deployment_identity_linux_system_in_root() {
    local root="$1" rc
    rootpxe_deployment_identity_linux_system_preflight "$root" || return 1
    rootpxe_deployment_identity_mount_linux_var_filesystem "$root" || return 1
    rootpxe_deployment_identity_linux_system_in_root_mounted "$root"
    rc=$?
    rootpxe_deployment_identity_unmount_linux_var_filesystem || rc=1
    return "$rc"
}

# PXEOS cannot apply the target SELinux policy to a file from its own mount
# namespace.  Preserve metadata for replacements and, for an enabled target
# policy, request the distribution's first-boot relabel for new files.
rootpxe_deployment_identity_request_selinux_relabel() {
    local root="$1" config="$1/etc/selinux/config" mode marker="$1/.autorelabel" service
    rootpxe_deployment_identity_selinux_relabel_preflight "$root" || return 1
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
    [[ -f $service && ! -L $service ]] || return 1
    if [[ -e $marker ]]; then
        [[ -f $marker && ! -L $marker ]] || return 1
        return 0
    fi
    : >"$marker" || return 1
    chmod 600 "$marker" || return 1
    [[ -f $marker && ! -L $marker ]]
}

rootpxe_deployment_identity_linux_login_in_root() {
	local root="$1" private="${rootpxe_deployment_initialization_private_file:-}" authorized parent keys_tmp line key_blob hash shadow shadow_tmp root_line root_hash today last_byte
	[[ -r $private && ! -L $private ]] || { rootpxe_deployment_identity_private_enabled || return 0; return 1; }
	rootpxe_deployment_identity_linux_login_preflight "$root" || return 1
	if jq -e '.systemIdentity.sshLoginPublicKeys == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1; then
		authorized="$root/root/.ssh/authorized_keys"
		parent=$(dirname "$authorized")
		rootpxe_deployment_identity_safe_target_dir "$root" root/.ssh || return 1
		[[ -d $parent && ! -L $parent && ( ( ! -e $authorized && ! -L $authorized ) || ( -f "$authorized" && ! -L $authorized ) ) ]] || return 1
		[[ ! -e $authorized ]] || rootpxe_deployment_identity_safe_target_file "$root" "$authorized" || return 1
		rootpxe_deployment_identity_request_selinux_relabel "$root" || return 1
		chown 0:0 "$parent" && chmod 0700 "$parent" || return 1
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
		chown 0:0 "$keys_tmp" && chmod 0600 "$keys_tmp" && mv -f -- "$keys_tmp" "$authorized" || { rm -f -- "$keys_tmp"; return 1; }
		chown 0:0 "$authorized" && chmod 0600 "$authorized" || return 1
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
