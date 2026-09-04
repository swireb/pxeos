#!/bin/bash
export initversion=19800101
. /usr/share/pxeos/lib/partition-funcs.sh
. /usr/share/pxeos/lib/restore-preflight.sh
. /usr/share/pxeos/lib/capture-recovery.sh
rootpxe_progress_lib=/usr/share/pxeos/lib/partclone-progress.sh
[[ -r $rootpxe_progress_lib ]] || rootpxe_progress_lib="$(dirname "${BASH_SOURCE[0]}")/partclone-progress.sh"
. "$rootpxe_progress_lib"
REG_LOCAL_MACHINE_XP="/ntfs/WINDOWS/system32/config/system"
REG_LOCAL_MACHINE_7="/ntfs/Windows/System32/config/SYSTEM"
# 1 to turn on massive debugging of partition table restoration
[[ -z $ismajordebug ]] && ismajordebug=0
rootpxe_kernel_key_allowed() {
    case "$1" in
        web|pxeapi|taskid|task_token|token|mac|type|img|imgpath|osid|imgType|imgPartitionType|imgFormat|PIGZ_COMP|storage|storageip|storage_server|storage_export|export_path|protocol|hostName|changeHostname|shutdown|mc|pct|capone|nombr|fdrive|mode|boottype|deployed|isdebug|ismajordebug|chkdsk|keymap) return 0 ;;
        *) return 1 ;;
    esac
}
rootpxe_import_kernel_args() {
    local item key value
    while IFS= read -r item; do
        [[ $item == *=* ]] || continue
        key=${item%%=*}; value=${item#*=}; value=${value//+_+/ }; value=${value//+__+/ }
        rootpxe_kernel_key_allowed "$key" || continue
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || continue
        printf -v "$key" '%s' "$value"
        export "$key"
    done < <(tr ' ' '\n' </proc/cmdline)
    [[ -z ${task_token:-} && -n ${token:-} ]] && task_token=$token
    export task_token
}
rootpxe_import_kernel_args
rootpxe_import_usb_hinfo() {
    local line key value
    [[ ${boottype:-} == usb && -f /tmp/hinfo.txt ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line#export }; line=${line#declare -x }
        [[ $line == *=* ]] || continue
        key=${line%%=*}; value=${line#*=}
        rootpxe_kernel_key_allowed "$key" || continue
        if [[ $value == \"*\" || $value == \'*\' ]]; then
            quote=${value:0:1}; [[ ${value: -1} == "$quote" ]] || continue
            value=${value:1:${#value}-2}
        fi
        [[ $value != *\"* && $value != *\'* && $value != *'`'* && $value != *'$('* ]] || continue
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || continue
        printf -v "$key" '%s' "$value"; export "$key"
    done </tmp/hinfo.txt
}
rootpxe_import_usb_hinfo

rootpxe_normalize_mac() {
    local value=${1//:/}; value=${value,,}
    [[ $value =~ ^[0-9a-f]{12}$ ]] || return 1
    printf '%s\n' "$value"
}
rootpxe_require_identity() {
    [[ ${taskid:-} =~ ^[1-9][0-9]*$ ]] || return 1
    macWinSafe=$(rootpxe_normalize_mac "${mac:-}") || return 1
    mac=$macWinSafe; export mac macWinSafe
}
rootpxe_require_task_context() {
    rootpxe_require_identity || return 1
    [[ ${task_token:-} =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]
}

# Keep type/scope/format decisions identical to the management API.  Format 1
# is a deployment-only compatibility reader: PXEOS must never create it.
rootpxe_validate_image_contract() {
    case "${imgType:-}" in n|N|dd|mps|mpa) ;; *) return 1 ;; esac
    case "${imgPartitionType:-}" in all|mbr|[1-9]|10) ;; *) return 1 ;; esac
    case "${imgType:-}" in n|N|dd) [[ ${imgPartitionType:-} == all ]] || return 1 ;; esac
    if [[ ${type:-} == up && ${imgFormat:-} == 1 ]]; then return 1; fi
    return 0
}

# The checkin payload is untrusted.  Keep image-format acceptance in one
# runtime helper so restore code rejects an invalid value before allocating a
# FIFO or starting an image reader.
rootpxe_validate_runtime_img_format() {
    local format="${imgLegacy:-${imgFormat:-}}"
    [[ $format =~ ^[0-6]$ ]] || return 1
    [[ ${type:-} != up || $format != 1 ]]
}

# Diagnostics may contain values from a task response or a helper's stderr.
# Replace values before anything reaches the console or callback transport.
rootpxe_redact_diagnostic() {
    local text="$*" name value
    for name in task_token token execution_token smb_password smb_username smb_domain storage_password password credential; do
        value="${!name:-}"
        [[ -n $value ]] && text="${text//"$value"/[REDACTED]}"
    done
    text=$(printf '%s' "$text" | sed -E 's/(^|[[:space:]])([[:alnum:]_.-]*(token|password|credential|secret)[[:alnum:]_.-]*[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/Ig')
    printf '%s\n' "$text"
}

# Return at most $2 bytes of a valid UTF-8 input without ending inside a code
# point.  PXEOS can run with LC_ALL=C (for example dosfstools diagnostics), so
# use byte indexing and inspect the terminal UTF-8 sequence directly instead
# of relying on a UTF-8 locale or an optional converter.
rootpxe_utf8_safe_prefix() {
    local LC_ALL=C text="$1" maximum="$2" prefix byte lead continuation=0 index need=0
    [[ $maximum =~ ^[0-9]+$ ]] || return 1
    prefix=${text:0:maximum}
    index=$((${#prefix} - 1))
    while (( index >= 0 )); do
        byte=$(printf '%d' "'${prefix:index:1}")
        [[ $byte -ge 128 && $byte -le 191 ]] || break
        continuation=$((continuation + 1)); index=$((index - 1))
    done
    (( index >= 0 )) || { printf '%s' ''; return 0; }
    lead=$(printf '%d' "'${prefix:index:1}")
    case $lead in
        [0-9]|[1-9][0-9]|1[01][0-9]|12[0-7]) need=0 ;;
        19[2-9]|2[0-1][0-9]|22[0-3]) need=1 ;;
        22[4-9]|23[0-9]) need=2 ;;
        24[0-4]) need=3 ;;
        *) prefix=${prefix:0:index}; printf '%s' "$prefix"; return 0 ;;
    esac
    if (( continuation != need )); then prefix=${prefix:0:index}; fi
    printf '%s' "$prefix"
}

# The service accepts at most 256 KiB of UTF-8 message text.  Keep the full
# redacted diagnostic locally (root-only) and append an explicit marker when
# the callback payload is shortened.
rootpxe_bound_callback_message() {
    local message marker=' [TRUNCATED: full diagnostic retained locally]' bytes limit=262144 keep
    message=$(rootpxe_redact_diagnostic "$*")
    bytes=$(LC_ALL=C printf '%s' "$message" | wc -c) || return 1
    if [[ $bytes -le $limit ]]; then
        printf '%s\n' "$message"
        return 0
    fi
    umask 077
    rootpxe_last_diagnostic_file="/tmp/pxeos.diagnostic.$$.log"
    printf '%s\n' "$message" >"$rootpxe_last_diagnostic_file" || return 1
    chmod 600 "$rootpxe_last_diagnostic_file" || return 1
    keep=$((limit - $(LC_ALL=C printf '%s' "$marker" | wc -c) - 1))
    message=$(rootpxe_utf8_safe_prefix "$message" "$keep") || return 1
    while :; do
        bytes=$(LC_ALL=C printf '%s%s' "$message" "$marker" | wc -c) || return 1
        [[ $bytes -le $limit ]] && break
        keep=$(( $(LC_ALL=C printf '%s' "$message" | wc -c) - 1024 ))
        (( keep > 0 )) || { message=""; break; }
        message=$(rootpxe_utf8_safe_prefix "$message" "$keep") || return 1
    done
    printf '%s%s\n' "$message" "$marker"
}

rootpxe_disk_has_lvm_pv() {
    local disk="$1" candidate
    getPartitions "$disk"
    for candidate in ${parts:-}; do
        [[ $(blkid -s TYPE -o value "$candidate" 2>/dev/null) == LVM2_member ]] && return 0
    done
    return 1
}

# Fixed partition images cannot encode a safe per-LV restore plan.  Their
# capture inventory is therefore a required, immutable negative proof.  A
# missing historical sidecar fails before disk permit/write; dd remains the
# explicit raw whole-disk exception and never calls this helper.
rootpxe_safe_relative_path() {
    local value=${1#/} segment
    [[ -n $value && $value != */ && $value != *\\* && $value != *//* ]] || return 1
    IFS=/ read -r -a _rootpxe_parts <<< "$value"
    for segment in "${_rootpxe_parts[@]}"; do
        [[ -n $segment && $segment != . && $segment != .. && $segment != *$'\n'* && $segment != *$'\r'* ]] || return 1
    done
    printf '%s\n' "$value"
}
rootpxe_validate_smb_export() {
    local export_path="$1" segment
    # SMB exportPath is a relative share[/subdir...] path. Keep it intact so
    # mount.cifs can append the intended subdirectory directly to the UNC.
    [[ -n $export_path && $export_path != /* && $export_path != */ && $export_path != *//* ]] || return 1
    [[ $export_path != *[[:space:]]* && $export_path != *[[:cntrl:]]* ]] || return 1
    [[ $export_path != *\\* && $export_path != *:* && $export_path != *'"'* && $export_path != *"'"* && $export_path != *'`'* && $export_path != *'$'* && $export_path != *';'* && $export_path != *'&'* && $export_path != *'|'* && $export_path != *'<'* && $export_path != *'>'* && $export_path != *'('* && $export_path != *')'* && $export_path != *'{'* && $export_path != *'}'* && $export_path != *'['* && $export_path != *']'* && $export_path != *'*'* && $export_path != *'?'* && $export_path != *'!'* ]] || return 1
    IFS=/ read -r -a _rootpxe_smb_segments <<< "$export_path"
    for segment in "${_rootpxe_smb_segments[@]}"; do
        [[ -n $segment && $segment != . && $segment != .. ]] || return 1
    done
    printf '%s\n' "$export_path"
}
rootpxe_storage_path() {
    local relative candidate=/storage segment
    relative=$(rootpxe_safe_relative_path "$1") || return 1
    IFS=/ read -r -a _rootpxe_parts <<< "$relative"
    for segment in "${_rootpxe_parts[@]}"; do
        candidate="$candidate/$segment"
        [[ ! -L $candidate ]] || return 1
    done
    printf '%s\n' "$candidate"
}
rootpxe_prepare_storage_layout() {
    local path probe
    [[ -d /storage && ! -L /storage ]] || return 1
    for path in /storage/dev /storage/backup; do
        [[ ! -e $path || ( -d $path && ! -L $path ) ]] || return 1
        mkdir -p "$path" || return 1
    done
    probe=/storage/.rootpxe-write-probe.$$
    : > "$probe" && rm -f "$probe"
}

rootpxe_run_deploy_script() {
    local stage="$1" file_var="$2" hash_var="$3" label="$4" script expected_hash actual_hash script_rc=0
    script="${!file_var:-}"
    expected_hash="${!hash_var:-}"
    rootpxe_deploy_script_error=""
    [[ -z $script && -z $expected_hash ]] && return 0
    if [[ -z $script || -z $expected_hash || ! -f $script || -L $script ]]; then
        rootpxe_deploy_script_error=script_file_invalid
        rm -f -- "$script"
        unset "$file_var" "$hash_var"
        return 1
    fi
    actual_hash=$(sha256sum "$script" 2>/dev/null) || actual_hash=""
    actual_hash=${actual_hash%%[[:space:]]*}
    if [[ ! $expected_hash =~ ^[0-9a-f]{64}$ || $actual_hash != "$expected_hash" ]]; then
        rootpxe_deploy_script_error=script_hash_mismatch
        rm -f -- "$script"
        unset "$file_var" "$hash_var"
        return 1
    fi
    rootpxe_stage "$stage" "running $label" || true
    rootpxe_console_message INFO "Running $label."
    env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        ROOTPXE_TASK_ID="$taskid" \
        ROOTPXE_IMAGE_PATH="${imagePath:-}" \
        ROOTPXE_TARGET_DISK="${hd:-}" \
        ROOTPXE_HOSTNAME="${hostName:-}" \
        ROOTPXE_OS_ID="${osid:-}" \
        /bin/bash "$script" || script_rc=$?
    rm -f -- "$script"
    unset "$file_var" "$hash_var"
    if [[ $script_rc -ne 0 ]]; then
        rootpxe_deploy_script_error=script_execution_failed
        rootpxe_console_message ERROR "$label failed."
        return 1
    fi
    rootpxe_console_message INFO "$label completed."
}

rootpxe_run_pre_deploy_script() {
    rootpxe_run_deploy_script pre_deploy_script preDeployScriptFile preDeployScriptSha256 'pre-deploy script'
}

rootpxe_run_post_deploy_script() {
    rootpxe_run_deploy_script post_deploy_script postDeployScriptFile postDeployScriptSha256 'post-deploy script'
}

# LVM is deliberately narrow.  It is not a fallback for arbitrary device
# mapper stacks: only one target-disk PV, one VG and linear LVs can be made
# reproducible from a per-LV image.  Keep the facts in root-only temporary
# files so an unsupported topology fails before the caller asks for a write
# permit or starts capture.
rootpxe_lvm_trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$1"; }
rootpxe_lvm_safe_identifier() { [[ $1 =~ ^[A-Za-z0-9._:+-]{1,160}$ ]]; }
rootpxe_lvm_storage_identifier() { [[ $1 =~ ^[A-Za-z0-9._+-]{1,160}$ ]]; }
rootpxe_lvm_storage_filename() { [[ $1 =~ ^[A-Za-z0-9._+-]{1,255}$ ]]; }
# Keep the LVM report parser bound to the packaged jq executable.  Tests may
# replace this helper after sourcing the library, but an inherited shell
# function or an environment-provided executable name must not change the
# production parser.
rootpxe_lvm_json_jq() { command jq "$@"; }
rootpxe_lvm_partition_path() {
    local disk="$1" number="$2"
    [[ $number =~ ^[1-9][0-9]*$ ]] || return 1
    [[ $disk == *[0-9] ]] && printf '%sp%s\n' "$disk" "$number" || printf '%s%s\n' "$disk" "$number"
}
rootpxe_lvm_is_pv_partition() {
    local part="$1" number
    [[ ${rootpxe_lvm_active:-no} == yes ]] || return 1
    getPartitionNumber "$part"; number=$part_number
    [[ $number == "${rootpxe_lvm_pv_number:-}" ]]
}
rootpxe_lvm_reset_capture_facts() {
    rm -f -- "${rootpxe_lvm_facts_file:-}" "${rootpxe_lvm_lv_facts_file:-}"
    unset rootpxe_lvm_active rootpxe_lvm_captured rootpxe_lvm_facts_file rootpxe_lvm_lv_facts_file rootpxe_lvm_pv_path rootpxe_lvm_pv_number rootpxe_lvm_pv_uuid rootpxe_lvm_vg_name rootpxe_lvm_vg_uuid rootpxe_lvm_pv_bytes rootpxe_lvm_pe_start_bytes rootpxe_lvm_vg_extent_bytes rootpxe_lvm_vg_free_bytes
}
rootpxe_lvm_remove_probe_files() { rm -f -- "$@"; }
# Return 0 for no LVM or for the only supported topology; return non-zero for
# any LVM that cannot be captured safely.  The caller distinguishes this from
# ordinary non-LVM images via rootpxe_lvm_active.
rootpxe_lvm_capture_preflight() {
    local disk="$1" image_path="$2" target_parts="" pv_path pv_uuid vg_name vg_uuid pe_start count=0 all_count=0 pvs_json vgs_json lvs_json pvs_rows vgs_rows lvs_rows vg_row="" vg_count=0
    local -A seen_lv_names=()
    rootpxe_lvm_reset_capture_facts
    command -v pvs >/dev/null 2>&1 || return 1
    command -v vgs >/dev/null 2>&1 || return 1
    command -v lvs >/dev/null 2>&1 || return 1
    getPartitions "$disk"
    for pv_path in $parts; do
        case "$(blkid -s TYPE -o value "$pv_path" 2>/dev/null | tr -d '\r\n')" in crypto_LUKS|linux_raid_member) rootpxe_lvm_reset_capture_facts; return 1;; esac
        target_parts+="|$pv_path|"
    done
    [[ -n $target_parts ]] || return 1
    rootpxe_lvm_facts_file=$(mktemp /tmp/rootpxe-lvm-pv.XXXXXX) || return 1
    rootpxe_lvm_lv_facts_file=$(mktemp /tmp/rootpxe-lvm-lv.XXXXXX) || { rm -f "$rootpxe_lvm_facts_file"; return 1; }
    pvs_json=$(mktemp /tmp/rootpxe-lvm-pvs.XXXXXX) || { rootpxe_lvm_reset_capture_facts; return 1; }
    vgs_json=$(mktemp /tmp/rootpxe-lvm-vgs.XXXXXX) || { rootpxe_lvm_remove_probe_files "$pvs_json"; rootpxe_lvm_reset_capture_facts; return 1; }
    lvs_json=$(mktemp /tmp/rootpxe-lvm-lvs.XXXXXX) || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json"; rootpxe_lvm_reset_capture_facts; return 1; }
    pvs_rows=$(mktemp /tmp/rootpxe-lvm-pvrows.XXXXXX) || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json"; rootpxe_lvm_reset_capture_facts; return 1; }
    vgs_rows=$(mktemp /tmp/rootpxe-lvm-vgrows.XXXXXX) || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    lvs_rows=$(mktemp /tmp/rootpxe-lvm-lvrows.XXXXXX) || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    chmod 600 "$rootpxe_lvm_facts_file" "$rootpxe_lvm_lv_facts_file" "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows" || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    # `pvs` exits successfully with no rows on an ordinary non-LVM disk.  It
    # is not a topology failure: let the target-PV count below record the
    # explicit non-LVM state instead of pausing every normal n capture.
    if ! pvs --reportformat json --units b --nosuffix -o pv_name,pv_uuid,vg_name,vg_uuid,pv_size,pe_start >"$pvs_json" 2>/dev/null || ! rootpxe_lvm_json_jq -e '
      (.report|type == "array" and length == 1 and (.[0]|type == "object") and ((.[0].pv? // [])|type == "array") and all((.[0].pv? // [])[]; type == "object" and (.pv_name|type == "string") and (.pv_uuid|type == "string") and (.vg_name|type == "string") and (.vg_uuid|type == "string") and (.pv_size|type == "string") and (.pe_start|type == "string" and test("^[0-9]+$"))))' "$pvs_json" >/dev/null; then
        rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1
    fi
    rootpxe_lvm_json_jq -r '.report[0].pv[] | [.pv_name,.pv_uuid,.vg_name,.vg_uuid,.pv_size,.pe_start] | @tsv' "$pvs_json" >"$pvs_rows" || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    while IFS=$'\t' read -r pv_path pv_uuid vg_name vg_uuid pv_size pe_start; do
        pv_path=$(rootpxe_lvm_trim "$pv_path"); pv_uuid=$(rootpxe_lvm_trim "$pv_uuid"); vg_name=$(rootpxe_lvm_trim "$vg_name"); vg_uuid=$(rootpxe_lvm_trim "$vg_uuid"); pv_size=$(rootpxe_lvm_trim "$pv_size"); pe_start=$(rootpxe_lvm_trim "$pe_start")
        [[ -n $pv_path ]] || continue
        if [[ $target_parts == *"|$pv_path|"* ]]; then
            count=$((count + 1)); printf '%s|%s|%s|%s|%s|%s\n' "$pv_path" "$pv_uuid" "$vg_name" "$vg_uuid" "$pv_size" "$pe_start" >>"$rootpxe_lvm_facts_file"
        fi
    done <"$pvs_rows"
    # No target PV is a normal image.  Do not create an empty LVM extension.
    if [[ $count -eq 0 ]]; then rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; rootpxe_lvm_active=no; export rootpxe_lvm_active; return 0; fi
    [[ $count -eq 1 ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    IFS='|' read -r rootpxe_lvm_pv_path rootpxe_lvm_pv_uuid rootpxe_lvm_vg_name rootpxe_lvm_vg_uuid pv_size pe_start <"$rootpxe_lvm_facts_file"
    rootpxe_lvm_pv_path=$(rootpxe_lvm_trim "$rootpxe_lvm_pv_path"); rootpxe_lvm_pv_uuid=$(rootpxe_lvm_trim "$rootpxe_lvm_pv_uuid"); rootpxe_lvm_vg_name=$(rootpxe_lvm_trim "$rootpxe_lvm_vg_name"); rootpxe_lvm_vg_uuid=$(rootpxe_lvm_trim "$rootpxe_lvm_vg_uuid"); pe_start=$(rootpxe_lvm_trim "$pe_start")
    rootpxe_lvm_safe_identifier "$rootpxe_lvm_pv_uuid" && rootpxe_lvm_storage_identifier "$rootpxe_lvm_vg_name" && rootpxe_lvm_safe_identifier "$rootpxe_lvm_vg_uuid" || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    getPartitionNumber "$rootpxe_lvm_pv_path"; rootpxe_lvm_pv_number=$part_number
    rootpxe_lvm_pv_bytes=$(blockdev --getsize64 "$rootpxe_lvm_pv_path" 2>/dev/null) || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    [[ $rootpxe_lvm_pv_bytes =~ ^[1-9][0-9]*$ && $pe_start =~ ^[0-9]+$ ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    rootpxe_lvm_pe_start_bytes=$pe_start
    while IFS=$'\t' read -r pv_path pv_uuid vg_name vg_uuid pv_size pe_start; do
        pv_path=$(rootpxe_lvm_trim "$pv_path"); vg_uuid=$(rootpxe_lvm_trim "$vg_uuid")
        [[ $vg_uuid == "$rootpxe_lvm_vg_uuid" ]] && all_count=$((all_count + 1)) && [[ $pv_path == "$rootpxe_lvm_pv_path" ]] || true
    done <"$pvs_rows"
    [[ $all_count -eq 1 ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    if ! vgs --reportformat json --units b --nosuffix -o vg_name,vg_uuid,vg_extent_size,vg_free >"$vgs_json" 2>/dev/null || ! rootpxe_lvm_json_jq -e '(.report|type == "array" and length == 1 and ((.[0].vg? // [])|type == "array") and all((.[0].vg? // [])[]; (.vg_name|type == "string") and (.vg_uuid|type == "string") and (.vg_extent_size|type == "string" and test("^[1-9][0-9]*$")) and (.vg_free|type == "string" and test("^[0-9]+$"))))' "$vgs_json" >/dev/null; then rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; fi
    rootpxe_lvm_json_jq -r --arg uuid "$rootpxe_lvm_vg_uuid" '.report[0].vg[] | select(.vg_uuid == $uuid) | [.vg_name,.vg_uuid,.vg_extent_size,.vg_free] | @tsv' "$vgs_json" >"$vgs_rows" || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    while IFS=$'\t' read -r vg_name vg_uuid extent free; do
        vg_name=$(rootpxe_lvm_trim "$vg_name"); vg_uuid=$(rootpxe_lvm_trim "$vg_uuid"); extent=$(rootpxe_lvm_trim "$extent"); free=$(rootpxe_lvm_trim "$free")
        [[ $vg_uuid == "$rootpxe_lvm_vg_uuid" ]] || continue
        vg_count=$((vg_count + 1)); vg_row="$vg_name|$vg_uuid|$extent|$free"
    done <"$vgs_rows"
    [[ $vg_count -eq 1 ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    IFS='|' read -r vg_name vg_uuid rootpxe_lvm_vg_extent_bytes rootpxe_lvm_vg_free_bytes <<<"$vg_row"
    [[ $vg_name == "$rootpxe_lvm_vg_name" ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    [[ $rootpxe_lvm_vg_extent_bytes =~ ^[1-9][0-9]*$ && $rootpxe_lvm_vg_free_bytes =~ ^[0-9]+$ && $((rootpxe_lvm_pe_start_bytes)) -lt $((rootpxe_lvm_pv_bytes)) ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    local lv_name lv_uuid lv_path lv_size lv_attr segtype origin pool data metadata
    if ! lvs --reportformat json --units b --nosuffix -o vg_name,vg_uuid,lv_name,lv_uuid,lv_path,lv_size,lv_attr,segtype,origin,pool_lv,data_lv,metadata_lv --select "vg_uuid=$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name" >"$lvs_json" 2>/dev/null || ! rootpxe_lvm_json_jq -e --arg name "$rootpxe_lvm_vg_name" --arg uuid "$rootpxe_lvm_vg_uuid" '(.report|type == "array" and length == 1 and ((.[0].lv? // [])|type == "array") and all((.[0].lv? // [])[]; (.vg_name == $name) and (.vg_uuid == $uuid) and (.lv_name|type == "string") and (.lv_uuid|type == "string") and (.lv_path|type == "string") and (.lv_size|type == "string" and test("^[1-9][0-9]*$")) and (.segtype|type == "string") and ((.origin == null or (.origin|type == "string")) and (.pool_lv == null or (.pool_lv|type == "string")) and (.data_lv == null or (.data_lv|type == "string")) and (.metadata_lv == null or (.metadata_lv|type == "string")))) )' "$lvs_json" >/dev/null; then rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; fi
    rootpxe_lvm_json_jq -r --arg name "$rootpxe_lvm_vg_name" --arg uuid "$rootpxe_lvm_vg_uuid" '.report[0].lv[] | select(.vg_name == $name and .vg_uuid == $uuid) | [.lv_name,.lv_uuid,.lv_path,.lv_size,.lv_attr,.segtype,(.origin // ""),(.pool_lv // ""),(.data_lv // ""),(.metadata_lv // "")] | @tsv' "$lvs_json" >"$lvs_rows" || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    while IFS=$'\t' read -r lv_name lv_uuid lv_path lv_size lv_attr segtype origin pool data metadata; do
        lv_name=$(rootpxe_lvm_trim "$lv_name"); lv_uuid=$(rootpxe_lvm_trim "$lv_uuid"); lv_path=$(rootpxe_lvm_trim "$lv_path"); lv_size=$(rootpxe_lvm_trim "$lv_size"); segtype=$(rootpxe_lvm_trim "$segtype"); origin=$(rootpxe_lvm_trim "$origin"); pool=$(rootpxe_lvm_trim "$pool"); data=$(rootpxe_lvm_trim "$data"); metadata=$(rootpxe_lvm_trim "$metadata")
        [[ -n $lv_name ]] || continue
        rootpxe_lvm_storage_identifier "$lv_name" && rootpxe_lvm_safe_identifier "$lv_uuid" && [[ $lv_path == /dev/* && $lv_size =~ ^[1-9][0-9]*$ && $segtype == linear && -z $origin && -z $pool && -z $data && -z $metadata && ${seen_lv_names[${lv_name,,}]:-0} -eq 0 ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
        seen_lv_names[${lv_name,,}]=1
        printf '%s|%s|%s|%s\n' "$lv_name" "$lv_uuid" "$lv_path" "$lv_size" >>"$rootpxe_lvm_lv_facts_file"
    done <"$lvs_rows"
    [[ -s $rootpxe_lvm_lv_facts_file ]] || { rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"; rootpxe_lvm_reset_capture_facts; return 1; }
    rootpxe_lvm_remove_probe_files "$pvs_json" "$vgs_json" "$lvs_json" "$pvs_rows" "$vgs_rows" "$lvs_rows"
    rootpxe_lvm_active=yes
    export rootpxe_lvm_active rootpxe_lvm_facts_file rootpxe_lvm_lv_facts_file rootpxe_lvm_pv_path rootpxe_lvm_pv_number rootpxe_lvm_pv_uuid rootpxe_lvm_vg_name rootpxe_lvm_vg_uuid rootpxe_lvm_pv_bytes rootpxe_lvm_pe_start_bytes rootpxe_lvm_vg_extent_bytes rootpxe_lvm_vg_free_bytes
}
rootpxe_xfs_capture_preflight() {
    local device="$1" mount_point="" primary_error=""
    rootpxe_xfs_capture_error=""
    [[ -n $device ]] || { rootpxe_xfs_capture_error=invalid_device; return 1; }
    findmnt -rn -S "$device" >/dev/null 2>&1
    case $? in
        0) rootpxe_xfs_capture_error=source_mounted; return 1 ;;
        1) ;;
        *) rootpxe_xfs_capture_error=mount_state_check_failed; return 1 ;;
    esac
    mount_point=$(mktemp -d /tmp/rootpxe-xfs-capture.XXXXXX) || { rootpxe_xfs_capture_error=temp_mountpoint_failed; return 1; }
    if ! mount -t xfs -o rw,nouuid "$device" "$mount_point"; then
        primary_error=log_replay_mount_failed
    elif ! umount "$mount_point"; then
        primary_error=log_replay_unmount_failed
        umount "$mount_point" >/dev/null 2>&1 || true
    elif ! xfs_repair -n "$device"; then
        primary_error=post_replay_check_failed
    fi
    if [[ -n $mount_point ]] && ! rmdir "$mount_point" >/dev/null 2>&1 && [[ -z $primary_error ]]; then
        primary_error=temp_cleanup_failed
    fi
    [[ -z $primary_error ]] || { rootpxe_xfs_capture_error=$primary_error; return 1; }
}

# An XFS image captured by an older PXEOS environment can retain an
# un-replayed journal. xfs_repair -n rejects it by design, so replay only the
# exact diagnostic observed in production; every other failure stays closed.
rootpxe_xfs_restore_postcheck() {
    local device="$1" mount_point="" primary_error="" repair_output repair_rc mount_state
    rootpxe_xfs_restore_error=""
    [[ -n $device ]] || { rootpxe_xfs_restore_error=invalid_device; return 1; }
    repair_output=$(xfs_repair -n "$device" 2>&1)
    repair_rc=$?
    [[ -z $repair_output ]] || printf '%s\n' "$repair_output" >&2
    [[ $repair_rc -eq 0 ]] && return 0
    [[ $repair_output == *'valuable metadata changes in a log'* ]] || {
        rootpxe_xfs_restore_error=post_restore_inconsistent
        return 1
    }
    findmnt -rn -S "$device" >/dev/null 2>&1
    mount_state=$?
    case $mount_state in
        0) rootpxe_xfs_restore_error=device_mounted; return 1 ;;
        1) ;;
        *) rootpxe_xfs_restore_error=mount_state_query_failed; return 1 ;;
    esac
    mount_point=$(mktemp -d /tmp/rootpxe-xfs-restore.XXXXXX) || {
        rootpxe_xfs_restore_error=temp_create_failed
        return 1
    }
    if ! mount -t xfs -o rw,nouuid "$device" "$mount_point"; then
        primary_error=dirty_log_replay_mount_failed
    elif ! umount "$mount_point"; then
        primary_error=dirty_log_replay_unmount_failed
        umount "$mount_point" >/dev/null 2>&1 || true
    else
        repair_output=$(xfs_repair -n "$device" 2>&1)
        repair_rc=$?
        [[ -z $repair_output ]] || printf '%s\n' "$repair_output" >&2
        [[ $repair_rc -eq 0 ]] || primary_error=post_replay_check_failed
    fi
    if [[ -n $mount_point ]] && ! rmdir "$mount_point" >/dev/null 2>&1 && [[ -z $primary_error ]]; then
        primary_error=temp_cleanup_failed
    fi
    [[ -z $primary_error ]] || { rootpxe_xfs_restore_error=$primary_error; return 1; }
}

rootpxe_capture_lvm_volumes() {
    local image_path="$1" pv_artifact vg_artifact lv_name lv_uuid lv_path lv_size fs swap_uuid artifact fifo=/tmp/pigz1 producer writer progress_decoder min_bytes pv_min_bytes stage vg_active=no rootpxe_lvm_capture_status_file rootpxe_lvm_capture_status_rc
    rootpxe_lvm_capture_error_code=LVM_CAPTURE_FAILED
    rootpxe_lvm_capture_error_reason=unknown
    [[ ${rootpxe_lvm_active:-no} == yes && ${rootpxe_lvm_captured:-no} != yes ]] || return 0
    rootpxe_lvm_is_pv_partition "$rootpxe_lvm_pv_path" || return 1
    rootpxe_lvm_capture_status_file=$(mktemp /tmp/rootpxe-lvm-capture-status.XXXXXX) || return 1
    stage=$(mktemp -d "$image_path/.rootpxe-lvm.XXXXXX") || { rm -f -- "$rootpxe_lvm_capture_status_file"; return 1; }
    (
    trap 'rm -f -- "$fifo"; [[ $vg_active == yes ]] && vgchange -an --select "vg_uuid=$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name" >/dev/null 2>&1 || true; rm -rf -- "$stage"' EXIT
    pv_artifact="d1p${rootpxe_lvm_pv_number}.lvm.pv.meta"; vg_artifact="d1p${rootpxe_lvm_pv_number}.lvm.vg.cfg"
    rootpxe_safe_relative_path "$pv_artifact" >/dev/null && rootpxe_safe_relative_path "$vg_artifact" >/dev/null || return 1
    if ! vgchange -ay --select "vg_uuid=$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name"; then
        vgchange -an --select "vg_uuid=$rootpxe_lvm_vg_uuid" "$rootpxe_lvm_vg_name" >/dev/null 2>&1 || true
        return 1
    fi
    vg_active=yes
    pvdisplay -m --units b "$rootpxe_lvm_pv_path" >"$stage/$pv_artifact" 2>/dev/null || return 1
    vgcfgbackup -f "$stage/$vg_artifact" "$rootpxe_lvm_vg_name" >/dev/null 2>&1 || return 1
    : >"$stage/d1.lvm.capture.tsv" || return 1
    while IFS='|' read -r lv_name lv_uuid lv_path lv_size; do
        artifact=""; swap_uuid=""
        fs=$(blkid -s TYPE -o value "$lv_path" 2>/dev/null | tr -d '\r\n'); swap_uuid=$(blkid -s UUID -o value "$lv_path" 2>/dev/null | tr -d '\r\n')
        case $fs in ext2|ext3|ext4|xfs|swap) ;; *) return 1;; esac
        # n images preserve the source layout while capturing.  The original
        # logical-volume size is therefore also its minimum deployment size.
        min_bytes="$lv_size"; producer=0; writer=0
        if [[ $fs != swap ]]; then
            artifact="d1p${rootpxe_lvm_pv_number}.lvm.lv.${lv_name}.img"; rootpxe_safe_relative_path "$artifact" >/dev/null || return 1
            if [[ $fs == xfs ]] && ! rootpxe_xfs_capture_preflight "$lv_path"; then
                printf '%s|%s\n' XFS_CAPTURE_PREFLIGHT_FAILED "lv_${lv_name}_${rootpxe_xfs_capture_error:-unknown}" >"$rootpxe_lvm_capture_status_file"
                return 1
            fi
            rm -f "$fifo" || return 1
            if ! rootpxe_partclone_progress_prepare; then
                rm -f "$fifo"
                return 1
            fi
            if ! uploadFormat "$fifo" "$stage/$artifact"; then
                rootpxe_partclone_progress_abort || true
                rm -f "$fifo"
                return 1
            fi
            rootpxe_partclone_progress_start_collector
            if [[ $fs == xfs ]]; then LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.xfs "${rootpxe_partclone_progress_args[@]}" -cs "$lv_path" -O "$fifo" -f 1 -a0 2>"$rootpxe_partclone_progress_stderr_target"; else LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.extfs "${rootpxe_partclone_progress_args[@]}" -cs "$lv_path" -O "$fifo" -f 1 -a0 2>"$rootpxe_partclone_progress_stderr_target"; fi
            producer=$?; rootpxe_partclone_progress_wait; progress_decoder=$?; rootpxe_wait_for_writer "$rootpxe_last_writer_pid"; writer=$?
            [[ $producer -eq 0 ]] || { printf '%s|%s\n' LVM_LV_PARTCLONE_FAILED "lv_${lv_name}_${fs}" >"$rootpxe_lvm_capture_status_file"; rm -f "$fifo"; return 1; }
            [[ $progress_decoder -eq 0 ]] || { printf '%s|%s\n' LVM_LV_PARTCLONE_FAILED "lv_${lv_name}_${fs}_progress" >"$rootpxe_lvm_capture_status_file"; rm -f "$fifo"; return 1; }
            [[ $writer -eq 0 ]] || { printf '%s|%s\n' LVM_LV_WRITER_FAILED "lv_${lv_name}_${fs}" >"$rootpxe_lvm_capture_status_file"; rm -f "$fifo"; return 1; }
            mv "$stage/$artifact.000" "$stage/$artifact" >/dev/null 2>&1 || return 1
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$lv_name" "$lv_uuid" "$lv_size" "$min_bytes" "$fs" "$artifact" "$swap_uuid" >>"$stage/d1.lvm.capture.tsv" || return 1
    done <"$rootpxe_lvm_lv_facts_file"
    pv_min_bytes="$rootpxe_lvm_pv_bytes"
    jq -n --arg pv_uuid "$rootpxe_lvm_pv_uuid" --arg vg_uuid "$rootpxe_lvm_vg_uuid" --arg vg_name "$rootpxe_lvm_vg_name" --arg pv_artifact "$pv_artifact" --arg vg_artifact "$vg_artifact" --argjson part "$rootpxe_lvm_pv_number" --argjson pv_bytes "$rootpxe_lvm_pv_bytes" --argjson pv_min "$pv_min_bytes" --argjson pe_start "$rootpxe_lvm_pe_start_bytes" --argjson extent "$rootpxe_lvm_vg_extent_bytes" --argjson free "$rootpxe_lvm_vg_free_bytes" --rawfile lvs "$stage/d1.lvm.capture.tsv" '
      {version:1,captureMode:"per_lv",resizePolicy:"grow_only",pvs:[{partitionNumber:$part,uuid:$pv_uuid,vgUuid:$vg_uuid,originalBytes:$pv_bytes,minBytes:$pv_min,peStartBytes:$pe_start,artifact:$pv_artifact,vgConfigArtifact:$vg_artifact}],vgs:[{name:$vg_name,uuid:$vg_uuid,extentBytes:$extent,pvPartitionNumbers:[$part],originalFreeBytes:$free,lvs:($lvs|split("\n")|map(select(length>0)|split("|")|{name:.[0],uuid:.[1],layout:"linear",originalBytes:(.[2]|tonumber),minBytes:(.[3]|tonumber),fs:.[4],role:(if .[4]=="swap" then "swap" else "data" end),resizable:(.[4] != "swap"),artifact:.[5],swapUuid:(if .[4]=="swap" then .[6] else "" end)}))}]} ' >"$stage/d1.lvm.schema.json" || return 1
    jq -e '.version == 1 and .captureMode == "per_lv" and .resizePolicy == "grow_only" and (.pvs|length) == 1 and (.vgs|length) == 1' "$stage/d1.lvm.schema.json" >/dev/null || return 1
    rm -f -- "$stage/d1.lvm.capture.tsv" || return 1
    [[ ! -e "$image_path/d1.lvm.schema.json" && ! -e "$image_path/$pv_artifact" && ! -e "$image_path/$vg_artifact" && ! -e "$image_path/d1p${rootpxe_lvm_pv_number}.img" && ! -e "$image_path/d1p${rootpxe_lvm_pv_number}.img.000" ]] || return 1
    while IFS='|' read -r lv_name lv_uuid lv_path lv_size; do
        fs=$(blkid -s TYPE -o value "$lv_path" 2>/dev/null | tr -d '\r\n')
        [[ $fs == swap ]] && continue
        artifact="d1p${rootpxe_lvm_pv_number}.lvm.lv.${lv_name}.img"
        mv "$stage/$artifact" "$image_path/$artifact" || return 1
    done <"$rootpxe_lvm_lv_facts_file"
    mv "$stage/$pv_artifact" "$image_path/$pv_artifact" || return 1
    mv "$stage/$vg_artifact" "$image_path/$vg_artifact" || return 1
    # The schema is the commit marker.  Never publish it before every sidecar
    # and LV payload has reached its final location.
    mv "$stage/d1.lvm.schema.json" "$image_path/d1.lvm.schema.json" || return 1
    )
    rootpxe_lvm_capture_status_rc=$?
    if [[ $rootpxe_lvm_capture_status_rc -ne 0 && -r $rootpxe_lvm_capture_status_file ]]; then
        IFS='|' read -r rootpxe_lvm_capture_error_code rootpxe_lvm_capture_error_reason <"$rootpxe_lvm_capture_status_file" || true
    fi
    rm -f -- "$rootpxe_lvm_capture_status_file"
    [[ $rootpxe_lvm_capture_status_rc -eq 0 ]] || return 1
    rootpxe_lvm_captured=yes
    export rootpxe_lvm_captured
}

# Captured n-type images carry a compact, canonical partition fact record.
# It is generated only after all image writers and finalization succeeded.
rootpxe_build_original_schema() {
    local disk="$1" capture_path="$2" original lvm_fragment=""
    original="$capture_path/d1.partitions"
    local logical physical disk_bytes parts_file facts_file schema_table
    local -a lvm_jq_args=()
    [[ -r $original ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    [[ -r "$capture_path/d1.lvm.schema.json" ]] && lvm_fragment="$capture_path/d1.lvm.schema.json"
    [[ -n $lvm_fragment ]] && lvm_jq_args=(--rawfile lvm "$lvm_fragment")
    logical=$(blockdev --getss "$disk" 2>/dev/null) || return 1
    physical=$(blockdev --getpbsz "$disk" 2>/dev/null || printf '%s' "$logical")
    disk_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || return 1
    [[ $logical =~ ^[0-9]+$ && $physical =~ ^[0-9]+$ && $disk_bytes =~ ^[0-9]+$ ]] || return 1
    schema_table=$(awk '/^label:/{print tolower($2); exit}' "$original")
    [[ $schema_table == dos ]] && schema_table=mbr
    parts_file=$(mktemp /tmp/rootpxe-schema-parts.XXXXXX) || return 1
    facts_file=$(mktemp /tmp/rootpxe-schema-facts.XXXXXX) || { rm -f "$parts_file"; return 1; }
    chmod 600 "$parts_file" "$facts_file"
    awk -v image="$capture_path" -v disk="$disk" '
        function is_extended(value, normalized) {
          normalized=tolower(value); sub(/^0x/,"",normalized)
          return normalized=="5" || normalized=="f" || normalized=="85"
        }
        /^label:/{label=$2} /^sector-size:/{sector=$2}
        /start=/ {
          dev=$1; n=dev; sub(/^.*[^0-9]/,"",n)
          split($0,a,","); start=a[1]; sub(/.*start=[[:space:]]*/,"",start)
          size=a[2]; sub(/.*size=[[:space:]]*/,"",size)
          type=a[3]; sub(/.*(type|Id)=[[:space:]]*/,"",type)
          numbers[n]=1; starts[n]=start; sizes[n]=size; types[n]=type
          flags[n]=(index($0,"bootable") ? "boot" : "-")
          if (tolower(label)=="dos" && is_extended(type)) { extended_count++; extended_number=n }
        }
        END {
          if (tolower(label)=="dos") {
            if (extended_count > 1) exit 40
            if (extended_count == 1) {
              ext_start=starts[extended_number]; ext_end=ext_start+sizes[extended_number]
            }
            for (n in numbers) if ((n+0) >= 5) {
              if (extended_count != 1) exit 41
              if (starts[n] < ext_start+2 || starts[n]+sizes[n] > ext_end) exit 42
              for (m in numbers) if ((m+0) >= 5 && (m+0)!=(n+0) && starts[m] < starts[n]) {
                if (starts[n] < starts[m]+sizes[m]+2) exit 43
              }
            }
          }
          for (n in numbers) {
            kind="primary"; parent="-"; artifact=image "/d1p" n ".img"
            if (tolower(label)=="dos" && is_extended(types[n])) { kind="extended"; artifact="-" }
            else if (tolower(label)=="dos" && (n+0) >= 5) { kind="logical"; parent=extended_number }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n,starts[n],sizes[n],types[n],label,artifact,flags[n],kind,parent
          }
        }' "$original" >"$parts_file" || { rm -f "$parts_file"; return 1; }
    local schema_version=1 sorted_parts=""
    if [[ $schema_table == mbr ]] && awk -F'\t' '$8 == "extended" || $8 == "logical" { found=1 } END { exit(found ? 0 : 1) }' "$parts_file"; then
        # v2 explicitly promises numeric order because sfdisk must see an
        # extended container before p5+; leave v1 row order/hash untouched.
        sorted_parts=$(mktemp /tmp/rootpxe-schema-parts-sorted.XXXXXX) || { rm -f "$parts_file" "$facts_file"; return 1; }
        sort -n -k1,1 "$parts_file" >"$sorted_parts" || { rm -f "$parts_file" "$facts_file" "$sorted_parts"; return 1; }
        mv "$sorted_parts" "$parts_file" || { rm -f "$parts_file" "$facts_file" "$sorted_parts"; return 1; }
        schema_version=2
    fi
    # LVM layout metadata is carried by the outer Schema v2 even on GPT/ordinary MBR.
    # The v1 decoder intentionally treats extensions as opaque, so emitting
    # it as v1 would lose the LVM contract at task snapshot creation.
    [[ -n $lvm_fragment ]] && schema_version=2
    while IFS=$'\t' read -r part_number part_start part_size part_type part_label artifact flags part_kind parent_number; do
        local part_path fs uuid partuuid
        [[ $artifact == - ]] && artifact=""
        [[ $flags == - ]] && flags=""
        [[ $parent_number == - ]] && parent_number=""
        if [[ $part_kind == extended ]]; then
            printf '%s\t\t\t\t%s\t%s\t%s\n' "$part_number" "$flags" "$part_kind" "$parent_number" >>"$facts_file"
            continue
        fi
        if [[ $disk == *[0-9] ]]; then part_path="${disk}p${part_number}"; else part_path="${disk}${part_number}"; fi
        fs=$(blkid -s TYPE -o value "$part_path" 2>/dev/null | tr -d '\r\n')
        uuid=$(blkid -s UUID -o value "$part_path" 2>/dev/null | tr -d '\r\n')
        partuuid=$(blkid -s PARTUUID -o value "$part_path" 2>/dev/null | tr -d '\r\n')
        [[ $fs != *$'\t'* && $uuid != *$'\t'* && $partuuid != *$'\t'* ]] || { rm -f "$parts_file" "$facts_file"; return 1; }
        local is_lvm_pv=no
        if [[ -n $lvm_fragment ]] && jq -e --argjson number "$part_number" '.pvs[]? | select(.partitionNumber == $number)' "$lvm_fragment" >/dev/null 2>&1; then
            is_lvm_pv=yes
        fi
        # FOG/PXEOS preserves swap UUID data separately in d1.original.swapuuids
        # and does not create d1pN.img. It is a protected fact, not a missing
        # payload error.
        [[ $is_lvm_pv == yes || $fs == swap || -f $artifact || -f "${artifact}.000" ]] || { rm -f "$parts_file" "$facts_file"; return 1; }
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$part_number" "$fs" "$uuid" "$partuuid" "$flags" "$part_kind" "$parent_number" >>"$facts_file"
    done <"$parts_file"
    rootpxe_original_schema_file=$(mktemp /tmp/rootpxe-original-schema.XXXXXX) || { rm -f "$parts_file" "$facts_file"; return 1; }
    chmod 600 "$rootpxe_original_schema_file"
    jq -n --arg table "$schema_table" \
        --argjson version "$schema_version" --argjson disk "$disk_bytes" --argjson logical "$logical" --argjson physical "$physical" \
        --rawfile rows "$parts_file" --rawfile facts "$facts_file" "${lvm_jq_args[@]}" '
          def factmap: ($facts | split("\n") | map(select(length>0)|split("\t")|{key:.[0],value:{fs:.[1],uuid:.[2],partuuid:.[3],flags:(.[4]|split(",")|map(select(length>0)))}}) | from_entries);
          def mbrtype($type): ($type|ascii_downcase|sub("^0x";"") | "0x" + .);
          def role($type;$flags;$fs): if $fs == "swap" then "swap"
             elif (($type|ascii_downcase) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" or ($type|ascii_downcase) == "ef" or ($type|ascii_downcase) == "0xef") then "efi"
             elif ($type|ascii_downcase) == "e3c9e316-0b5c-4db8-817d-f92df00215ae" then "msr"
             elif (($type|ascii_downcase) == "de94bba4-06d1-4d40-a16a-bfd50179d6ac" or ($type|ascii_downcase) == "27" or ($type|ascii_downcase) == "0x27") then "recovery"
             elif ($type|ascii_downcase) == "21686148-6449-6e6f-744e-656564454649" or ($flags|index("boot")) then "boot"
             elif (($type|ascii_downcase) == "e6d6d379-f507-44c2-a23c-238f2a3df928" or ($type|ascii_downcase) == "8e" or ($type|ascii_downcase) == "0x8e") then "lvm_pv"
             else "data" end;
          # `$ARGS.named` keeps the non-LVM case valid without declaring a
          # jq variable that was never supplied by --rawfile.
          (if ($ARGS.named.lvm // "")|length > 0 then ($ARGS.named.lvm|fromjson) else null end) as $lvmdata |
          (factmap) as $facts |
          ($rows|split("\n")|map(select(length>0)|split("\t")|
            . as $row | ($facts[$row[0]] // {fs:"",uuid:"",partuuid:"",flags:[]}) as $fact |
            (($row[0]|tonumber)) as $number |
            (if $row[7] == "extended" then "extended_container" elif ($lvmdata != null and ([$lvmdata.pvs[]|select(.partitionNumber == $number)]|length) == 1) then "lvm_pv" else role($row[3];$fact.flags;$fact.fs) end) as $role |
            {number:$number,startSectors:($row[1]|tonumber),originalSectors:($row[2]|tonumber),minSectors:($row[2]|tonumber),typeGuid:(if $version == 2 and $table == "mbr" then mbrtype($row[3]) else $row[3] end),flags:$fact.flags,role:$role,resizable:(($role == "data" and ($fact.fs|length) > 0) or $role == "lvm_pv"),fs:$fact.fs,uuid:$fact.uuid,partuuid:$fact.partuuid,artifact:(if $role == "swap" or $role == "lvm_pv" or $row[7] == "extended" then "" else ($row[5]|split("/")|last) end),_kind:(if $version == 2 and $row[7] == "" then "primary" else $row[7] end),_parent:($row[8] // "")})) as $base |
          (if $version == 2 then
            $base as $all | $base | map(. as $part | . + {
              kind:$part._kind
            } + (if $part._kind == "logical" then {parentNumber:($part._parent|tonumber)}
                 elif $part._kind == "extended" then
                   {logicalNumbers:[$all[] | select(._kind == "logical" and ._parent == ($part.number|tostring)) | .number],ebrReservedSectors:2}
                 else {} end) | del(._kind,._parent))
          else $base | map(del(._kind,._parent)) end) as $parts |
          ({version:$version,partitionTable:$table,originalDiskBytes:$disk,logicalSectorBytes:$logical,physicalSectorBytes:$physical,minDeployBytes:$disk,partitions:$parts} + (if $lvmdata == null then {} else {lvm:$lvmdata} end))' >"$rootpxe_original_schema_file" || { rm -f "$parts_file" "$facts_file" "$rootpxe_original_schema_file"; return 1; }
    rm -f "$parts_file" "$facts_file"
    jq -e '
      def base:
        .logicalSectorBytes as $logicalSectorBytes |
        .originalDiskBytes as $originalDiskBytes |
        (($logicalSectorBytes|type) == "number" and $logicalSectorBytes > 0) and
        ((.partitions|type) == "array" and (.partitions|length) > 0) and
        ([.partitions[].number] as $numbers | ($numbers | unique | length) == ($numbers | length)) and
        ([.partitions[] | select(.startSectors < 0 or .originalSectors <= 0 or .minSectors != .originalSectors or (.startSectors + .originalSectors) * $logicalSectorBytes > $originalDiskBytes)] | length == 0);
      if .version == 1 then
        (.partitionTable == "gpt" or .partitionTable == "dos" or .partitionTable == "mbr") and base
      elif .version == 2 then
        base and
        (if .partitionTable == "gpt" then
           ([.partitions[] | select(.kind != "primary")] | length) == 0
         elif .partitionTable == "mbr" then
           (([.partitions[] | select(.kind == "extended")] | length) == 0) or
           (([.partitions[] | select(.kind == "extended")] | length) == 1 and
            ([.partitions[] | select(.kind == "extended" and (.number < 1 or .number > 4 or .role != "extended_container" or .artifact != "" or .resizable != false or .ebrReservedSectors != 2 or has("parentNumber")))] | length) == 0 and
            ([.partitions[] | select(.kind == "logical" and (.number < 5 or (.parentNumber|type) != "number" or has("ebrReservedSectors") or has("logicalNumbers")))] | length) == 0)
         else false end) and
        (if has("lvm") then (.lvm.version == 1 and .lvm.captureMode == "per_lv" and .lvm.resizePolicy == "grow_only" and (.lvm.pvs|length)==1 and (.lvm.vgs|length)==1) else true end)
      else false end' "$rootpxe_original_schema_file" >/dev/null || { rm -f "$rootpxe_original_schema_file"; return 1; }
    export rootpxe_original_schema_file
}

# Partition inventory is a read-only capture fact.  It intentionally does not
# reuse the n-type Schema/Layout contract: fixed images may contain several
# disks and must never acquire editable deployment semantics merely because
# their partition tables are displayed in RootPXE.
rootpxe_build_partition_inventory_disk() {
    local disk="$1" partitions_file="$2" disk_number="$3" rows enriched table logical physical bytes part_number part_start part_size part_type part_path fs uuid partuuid
    command -v jq >/dev/null 2>&1 || return 1
    logical=$(blockdev --getss "$disk" 2>/dev/null) || return 1
    physical=$(blockdev --getpbsz "$disk" 2>/dev/null || printf '%s' "$logical")
    bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || return 1
    [[ $disk_number =~ ^[1-9][0-9]*$ && $logical =~ ^[1-9][0-9]*$ && $physical =~ ^[1-9][0-9]*$ && $bytes =~ ^[1-9][0-9]*$ ]] || return 1
    table=none
    if [[ -r $partitions_file ]]; then
        table=$(awk '/^label:/{print tolower($2); exit}' "$partitions_file")
        [[ $table == dos ]] && table=mbr
        [[ $table == gpt || $table == mbr ]] || return 1
    fi
    rows=$(mktemp /tmp/rootpxe-inventory-rows.XXXXXX) || return 1
    chmod 600 "$rows" || { rm -f "$rows"; return 1; }
    if [[ $table != none ]]; then
        awk '
          /start=/ {
            dev=$1; n=dev; sub(/^.*[^0-9]/,"",n)
            split($0,a,","); start=a[1]; sub(/.*start=[[:space:]]*/,"",start)
            size=a[2]; sub(/.*size=[[:space:]]*/,"",size)
            type=a[3]; sub(/.*(type|Id)=[[:space:]]*/,"",type)
            if (n !~ /^[1-9][0-9]*$/ || start !~ /^[0-9]+$/ || size !~ /^[1-9][0-9]*$/) exit 1
            printf "%s\t%s\t%s\t%s\n", n,start,size,type
          }' "$partitions_file" >"$rows" || { rm -f "$rows"; return 1; }
    fi
    enriched=$(mktemp /tmp/rootpxe-inventory-facts.XXXXXX) || { rm -f "$rows"; return 1; }
    chmod 600 "$enriched" || { rm -f "$rows" "$enriched"; return 1; }
    while IFS=$'\t' read -r part_number part_start part_size part_type; do
        if [[ $disk == *[0-9] ]]; then part_path="${disk}p${part_number}"; else part_path="${disk}${part_number}"; fi
        fs=$(blkid -s TYPE -o value "$part_path" 2>/dev/null | tr -d '\r\n')
        uuid=$(blkid -s UUID -o value "$part_path" 2>/dev/null | tr -d '\r\n')
        partuuid=$(blkid -s PARTUUID -o value "$part_path" 2>/dev/null | tr -d '\r\n')
        [[ $fs != *$'\t'* && $uuid != *$'\t'* && $partuuid != *$'\t'* ]] || { rm -f "$rows" "$enriched"; return 1; }
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$part_number" "$part_start" "$part_size" "$part_type" "$fs" "$uuid" "$partuuid" >>"$enriched" || { rm -f "$rows" "$enriched"; return 1; }
    done <"$rows"
    mv "$enriched" "$rows" || { rm -f "$rows" "$enriched"; return 1; }
    jq -cn --argjson number "$disk_number" --arg device "$disk" --arg table "$table" \
        --argjson bytes "$bytes" --argjson logical "$logical" --argjson physical "$physical" --rawfile rows "$rows" '
          {number:$number,sourceDevice:$device,partitionTable:$table,originalDiskBytes:$bytes,logicalSectorBytes:$logical,physicalSectorBytes:$physical,
           partitions:($rows|split("\n")|map(select(length>0)|split("\t")|{number:(.[0]|tonumber),startSectors:(.[1]|tonumber),originalSectors:(.[2]|tonumber),typeGuid:.[3],fs:.[4],uuid:.[5],partuuid:.[6]}))}'
    local result=$?
    rm -f "$rows"
    return $result
}

# `$4` is the already permitted, fixed capture disk list used by mpa.  It is
# deliberately not re-filtered here: skipping a disk after payload and permit
# planning would shift dN numbering and make the saved inventory describe a
# different source set.
rootpxe_build_partition_inventory() {
    local capture_path="$1" image_type="$2" primary_disk="$3" all_disks="$4" inventory_rows disk disk_number=1 partitions_file
    command -v jq >/dev/null 2>&1 || return 1
    inventory_rows=$(mktemp /tmp/rootpxe-inventory-disks.XXXXXX) || return 1
    chmod 600 "$inventory_rows" || { rm -f "$inventory_rows"; return 1; }
    if [[ $image_type == mpa ]]; then
        for disk in $all_disks; do
            rootpxe_verify_disk_permit_binding "$disk" capture_read_write || { rm -f "$inventory_rows"; return 1; }
            getPartitions "$disk"
            [[ -n ${parts:-} ]] || { rm -f "$inventory_rows"; return 1; }
            partitions_file="$capture_path/d${disk_number}.partitions"
            rootpxe_build_partition_inventory_disk "$disk" "$partitions_file" "$disk_number" >>"$inventory_rows" || { rm -f "$inventory_rows"; return 1; }
            disk_number=$((disk_number + 1))
        done
    else
        # dd can image an intentionally unpartitioned disk.  A missing
        # d1.partitions is represented as table=none and an empty partition
        # list, while other image types require their captured table.
        partitions_file="$capture_path/d1.partitions"
        if [[ $image_type != dd && ! -r $partitions_file ]]; then rm -f "$inventory_rows"; return 1; fi
        rootpxe_build_partition_inventory_disk "$primary_disk" "$partitions_file" 1 >>"$inventory_rows" || { rm -f "$inventory_rows"; return 1; }
    fi
    [[ -s $inventory_rows ]] || { rm -f "$inventory_rows"; return 1; }
    rootpxe_partition_inventory_file=$(mktemp /tmp/rootpxe-partition-inventory.XXXXXX) || { rm -f "$inventory_rows"; return 1; }
    chmod 600 "$rootpxe_partition_inventory_file"
    jq -n --rawfile disks "$inventory_rows" '{version:1,disks:($disks|split("\n")|map(select(length>0)|fromjson))}' >"$rootpxe_partition_inventory_file" || { rm -f "$inventory_rows" "$rootpxe_partition_inventory_file"; unset rootpxe_partition_inventory_file; return 1; }
    rm -f "$inventory_rows"
    jq -e '.version == 1 and ((.disks|type) == "array" and (.disks|length) > 0) and ([.disks[] | select(.number < 1 or (.partitionTable != "gpt" and .partitionTable != "mbr" and .partitionTable != "none") or .originalDiskBytes <= 0 or .logicalSectorBytes <= 0 or .physicalSectorBytes < .logicalSectorBytes or (.partitionTable == "none" and (.partitions|length) != 0))] | length == 0)' "$rootpxe_partition_inventory_file" >/dev/null || { rm -f "$rootpxe_partition_inventory_file"; unset rootpxe_partition_inventory_file; return 1; }
    export rootpxe_partition_inventory_file
}

rootpxe_cleanup_deployment_partition_file() {
    local partition_file="${rootpxe_deployment_partition_file:-}" partition_dir=""
    case "$partition_file" in
        /tmp/rootpxe-deployment-layout.*/d1.deployment.partitions)
            partition_dir=$(dirname "$partition_file")
            rm -f -- "$partition_file"
            rmdir -- "$partition_dir" >/dev/null 2>&1 || true
            ;;
    esac
    unset rootpxe_deployment_partition_file
}

rootpxe_cleanup_task_json() {
    rootpxe_cleanup_deployment_partition_file
    rm -f -- "${deploymentLayoutFile:-}" "${originalSchemaFile:-}" "${preDeployScriptFile:-}" "${postDeployScriptFile:-}" "${rootpxe_original_schema_file:-}" "${rootpxe_partition_inventory_file:-}"
    unset deploymentLayoutFile originalSchemaFile preDeployScriptFile preDeployScriptSha256 postDeployScriptFile postDeployScriptSha256 rootpxe_original_schema_file rootpxe_partition_inventory_file
}

rootpxe_cleanup_session() {
    rootpxe_cleanup_smb_credentials
    rootpxe_cleanup_task_json
}

# Resolve a task snapshot only; editing an image default can never alter this
# file. Percentage and remaining space use the deployable data area after
# front/end reservations; remaining is rounded down to 256 KiB so it cannot
# grow beyond the verified target boundary.
rootpxe_canonical_json_hash() {
    local json_file="$1" canonical
    [[ -r $json_file ]] || return 1
    # Go canonicalJSON hashes exactly jq's compact sorted JSON bytes, without
    # jq's presentation newline. Command substitution removes that newline;
    # printf deliberately does not add one back.
    canonical=$(jq -cS . "$json_file") || return 1
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

rootpxe_validate_deployment_layout() {
    local disk="$1" schema_file="$2" layout_file="$3" schema_logical original_disk_bytes target_bytes target_sectors source_hash layout_hash
    [[ -r $schema_file && -r $layout_file ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    # MBR extended containers require EBR-chain reconstruction.  Do not turn
    # them into ordinary resizable partitions until a dedicated layout engine
    # exists; legacy no-snapshot deployment remains available.
    jq -e '([.partitions[] | select(.role == "other")] | length) == 0' "$schema_file" >/dev/null 2>&1 || return 1
    # Schema sectors are expressed in the source image's logical sector unit.
    # Target 4Kn/512e geometry must therefore be converted through bytes, not
    # by incorrectly substituting target --getss into source-sector fields.
    schema_logical=$(jq -er '.logicalSectorBytes' "$schema_file" 2>/dev/null) || return 1
    original_disk_bytes=$(jq -er '.originalDiskBytes' "$schema_file" 2>/dev/null) || return 1
    target_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || return 1
    [[ $schema_logical =~ ^[1-9][0-9]*$ && $original_disk_bytes =~ ^[1-9][0-9]*$ && $target_bytes =~ ^[1-9][0-9]*$ ]] || return 1
    # 单磁盘可调整镜像只允许扩容。这里发生在分区表应用和磁盘许可前，
    # 因此目标盘小于捕获原始容量不会触及目标磁盘。
    (( target_bytes >= original_disk_bytes )) || return 1
    (( target_bytes % schema_logical == 0 )) || return 1
    target_sectors=$(( target_bytes / schema_logical ))
    source_hash=$(rootpxe_canonical_json_hash "$schema_file") || return 1
    [[ -z ${schemaHash:-} || $schemaHash == "$source_hash" ]] || return 1
    [[ ${schemaRevision:-} =~ ^[1-9][0-9]*$ ]] || return 1
    layout_hash=$(jq -er '.schemaHash // empty' "$layout_file" 2>/dev/null) || return 1
    [[ $layout_hash == "$schemaHash" ]] || return 1
    rootpxe_resolved_layout_file=$(mktemp /tmp/rootpxe-resolved-layout.XXXXXX) || return 1
    chmod 600 "$rootpxe_resolved_layout_file"
    jq -n --slurpfile schema "$schema_file" --slurpfile layout "$layout_file" \
        --argjson target "$target_sectors" --argjson logical "$schema_logical" '
          def align_up($n;$a): ((($n + $a - 1) / $a)|floor) * $a;
          def align_down($n;$a): (($n / $a)|floor) * $a;
          ($schema[0]) as $s | ($layout[0]) as $l |
          ($s.partitions|sort_by(.number)) as $sp |
          ($l.partitions // $l) as $lp |
          if ($lp|type) != "array" then error("layout partitions missing") else . end |
          if ([ $lp[].number ]|unique|length) != ($lp|length) then error("duplicate layout number") else . end |
          if ([ $sp[].number ]|sort) != ([ $lp[].number ]|sort) then error("layout identity mismatch") else . end |
          ($s.version == 2 and $s.partitionTable == "mbr") as $mbrExtended |
          (if $mbrExtended then
             ([$sp[] | select(.kind == "extended")]) as $extendeds |
             if ($extendeds|length) != 1 then error("invalid extended container") else . end |
             ($extendeds[0]) as $extended |
             ([$lp[] | select(.number == $extended.number)]) as $extendedLayout |
             if ($extendedLayout|length) != 1 or $extendedLayout[0].mode != "derived" or ($extendedLayout[0]|has("fixedBytes") or has("percentage")) then error("extended container must be derived") else . end |
             ([$sp[] | select(.kind == "logical")]) as $logicals |
             if ($logicals|length) == 0 or ([ $logicals[] | select(.parentNumber != $extended.number)]|length) != 0 then error("invalid logical parent") else . end |
             ([$sp[] | select(.kind == "primary") | (.startSectors + .originalSectors)]) as $primaryEnds |
             if (($primaryEnds | max // 0) > $extended.startSectors) then error("primary after extended is not supported safely") else . end |
             $sp | map(select(.kind != "extended"))
           else $sp end) as $worksp |
          ($worksp|map(.startSectors)|min) as $front |
          (if $s.partitionTable == "gpt" then $front else 0 end) as $back |
          ($target - $front - $back) as $available |
          (262144 / $logical | floor | if . < 1 then 1 else . end) as $alignment |
          if $available <= 0 then error("target too small") else . end |
          [ $worksp[] as $p | ($lp[]|select(.number == $p.number)) as $o |
            ($o.mode // "original") as $mode |
            if (($mode|type) != "string" or ($mode|IN("original","fixed","percentage","remaining")|not)) then error("unknown mode") else . end |
            if $mode == "fixed" and ((($o.fixedBytes // null)|type) != "number" or ($o.fixedBytes <= 0) or ($o|has("percentage"))) then error("invalid fixed mode") else . end |
            if $mode == "percentage" and ((($o.percentage // null)|type) != "number" or ($o|has("fixedBytes"))) then error("invalid percentage mode") else . end |
            if ($mode == "original" or $mode == "remaining") and (($o|has("fixedBytes")) or ($o|has("percentage"))) then error("unexpected mode field") else . end |
            if $mode == "fixed" and $o.fixedBytes < ($p.originalSectors * $logical) then error("original size violated") else . end |
            {p:$p,o:$o,mode:$mode} ] as $items |
          ([ $items[]|select(.mode == "remaining") ]|length) as $remainingCount |
          if $remainingCount > 1 then error("multiple remaining") else . end |
          ([ $items[] | select(.mode == "percentage") | (.o.percentage // -1) ] | all(. >= 0 and . <= 100)) as $validPct |
          if $validPct|not then error("invalid percentage") else . end |
          ([ $items[] | select(.mode == "percentage") | .o.percentage] | add // 0) as $pctSum |
          if $pctSum > 100 then error("percentage exceeds 100") else . end |
          ($items | map(if .mode == "original" then .p.originalSectors elif .mode == "fixed" then align_up(((.o.fixedBytes // 0) / $logical|ceil);$alignment) elif .mode == "percentage" then align_down(($available * .o.percentage / 100|floor);$alignment) else 0 end)) as $pre |
          ($pre|add) as $used |
          if $used > $available then error("target too small") else . end |
          (if $remainingCount == 1 then align_down(($available-$used);$alignment) else 0 end) as $remaining |
          (reduce range(0;($items|length)) as $i ({cursor:$front,out:[]};
            ($items[$i]) as $item | ($pre[$i]) as $base |
            (if $item.mode == "remaining" then $remaining else $base end) as $size |
            if $size < $item.p.originalSectors then error("original size violated") else . end |
            .cursor = align_up(.cursor;$alignment) |
            .out += [$item.p + {startSectors:.cursor,resolvedSectors:$size}] |
            .cursor += $size) |
          if .cursor > ($target-$back) then error("layout exceeds target") else .out end) as $resolved |
          if $mbrExtended then
            ([$sp[] | select(.kind == "extended")][0]) as $extended |
            ($resolved | map(select(.kind == "logical"))) as $logicals |
            ($logicals | map(.startSectors) | min - $extended.ebrReservedSectors) as $extendedStart |
            ($logicals | map(.startSectors + .resolvedSectors) | max) as $extendedEnd |
            if $extendedStart < 0 or $extendedEnd <= $extendedStart then error("derived extended geometry invalid") else . end |
            ([$resolved[], $extended + {startSectors:$extendedStart,resolvedSectors:($extendedEnd-$extendedStart)}] | sort_by(.number))
          else $resolved end' >"$rootpxe_resolved_layout_file" || { rm -f "$rootpxe_resolved_layout_file"; return 1; }
    export rootpxe_resolved_layout_file
    rootpxe_validate_lvm_deployment_layout "$schema_file" "$layout_file" "$rootpxe_resolved_layout_file" || return 1
    # A layout that preserves every captured partition is not an adjusted
    # layout.  Keep d1.partitions as its only partition-table source; the
    # resolved JSON remains private runtime metadata for LVM restoration.
    if jq -e '((.partitions // []) | all(.mode == "original" or .mode == "derived")) and ((.lvm // []) | all((.freeSpacePolicy // "preserveOriginal") == "preserveOriginal" and ((.volumes // []) | all(.mode == "original"))))' "$layout_file" >/dev/null 2>&1; then
        rootpxe_deployment_layout_changed=no
    else
        rootpxe_deployment_layout_changed=yes
    fi
    export rootpxe_deployment_layout_changed
}

# Resolve only the LVM extension after the physical partition layout has been
# resolved.  The result is a root-only plan; it intentionally contains no
# command text and is safe to validate before a disk permit is requested.
rootpxe_validate_lvm_deployment_layout() {
    local schema_file="$1" layout_file="$2" partition_plan="$3"
    rm -f -- "${rootpxe_resolved_lvm_layout_file:-}"; unset rootpxe_resolved_lvm_layout_file
    command -v jq >/dev/null 2>&1 || return 1
    jq -e 'if has("lvm") then (.version == 2 and .lvm.version == 1 and .lvm.captureMode == "per_lv" and .lvm.resizePolicy == "grow_only") else true end' "$schema_file" >/dev/null 2>&1 || return 1
    if ! jq -e 'has("lvm")' "$schema_file" >/dev/null 2>&1; then
        jq -e '([.partitions[] | select(.fs == "LVM2_member" or .role == "lvm_pv" or ((.typeGuid // "") | ascii_downcase | IN("8e","0x8e","e6d6d379-f507-44c2-a23c-238f2a3df928")))] | length) == 0' "$schema_file" >/dev/null 2>&1 || return 1
        jq -e '((.lvm // [])|length) == 0' "$layout_file" >/dev/null 2>&1
        return
    fi
    rootpxe_resolved_lvm_layout_file=$(mktemp /tmp/rootpxe-resolved-lvm.XXXXXX) || return 1
    chmod 600 "$rootpxe_resolved_lvm_layout_file"
    jq -n --slurpfile schema "$schema_file" --slurpfile layout "$layout_file" --slurpfile partitions "$partition_plan" '
      def bynum($n): (.[] | select(.number == $n));
      def modebytes($v;$capacity;$extent):
        if $v.mode == "original" then $v.originalBytes
        elif $v.mode == "fixed" then $v.fixedBytes
        elif $v.mode == "percentage" then ((($capacity * $v.percentage / 100)|floor / $extent|floor) * $extent)
        else 0 end;
      ($schema[0]) as $s | ($layout[0]) as $l | ($partitions[0]) as $resolved |
      ($s.lvm) as $ls | ($l.lvm // []) as $ll |
      if ($ls.version != 1 or $ls.captureMode != "per_lv" or $ls.resizePolicy != "grow_only" or ($ls.pvs|length)!=1 or ($ls.vgs|length)!=1 or ($ll|length)!=1) then error("invalid lvm topology") else . end |
      ($ls.pvs[0]) as $pv | ($ls.vgs[0]) as $vg | ($ll[0]) as $plan |
      if ($pv.vgUuid != $vg.uuid or $pv.partitionNumber != $vg.pvPartitionNumbers[0] or $plan.pvPartitionNumber != $pv.partitionNumber or ($plan.freeSpacePolicy|IN("preserveOriginal","allocateToRemaining")|not) or ($plan.volumes|length) != ($vg.lvs|length)) then error("lvm identity mismatch") else . end |
      ([$resolved[] | select(.number == $pv.partitionNumber)]|if length==1 then .[0] else error("resolved pv missing") end) as $resolvedPV |
      ($resolvedPV.resolvedSectors * $s.logicalSectorBytes) as $pvBytes |
      if ($pvBytes < $pv.originalBytes or $pvBytes < $pv.minBytes or $pv.peStartBytes < 0 or $pv.peStartBytes >= $pvBytes) then error("invalid pv capacity") else . end |
      (((($pvBytes - $pv.peStartBytes - (if $plan.freeSpacePolicy == "preserveOriginal" then $vg.originalFreeBytes else 0 end)) / $vg.extentBytes)|floor) * $vg.extentBytes) as $capacity |
      if $capacity < 0 then error("pv capacity exhausted") else . end |
      [range(0;($vg.lvs|length)) as $i | ($vg.lvs[$i]) as $lv | ($plan.volumes[$i]) as $v |
        if ($v.uuid != $lv.uuid or ($v.mode|IN("original","fixed","percentage","remaining")|not)) then error("lvm volume identity") else . end |
        # Swap has no payload and is recreated after a possible lvextend.  It
        # remains resizable=false in capture metadata, so accept non-original
        # modes only for the exact typed swap schema contract.
        if ($lv.fs == "swap" and ($lv.role != "swap" or $lv.resizable != false or (($lv.artifact // "") != "") or (($lv.swapUuid|type) != "string") or ($lv.swapUuid|length) == 0)) then error("invalid recreated swap volume") else . end |
        if ((($lv.resizable != true) or ($lv.role == "swap")) and (($lv.fs != "swap") or ($lv.role != "swap") or ($lv.resizable != false) or (($lv.artifact // "") != "") or (($lv.swapUuid|type) != "string") or (($lv.swapUuid|length) == 0)) and $v.mode != "original") then error("protected lvm volume") else . end |
        if $v.mode == "fixed" and (($v.fixedBytes|type)!="number" or $v.fixedBytes < $lv.minBytes or ($v.fixedBytes % $vg.extentBytes)!=0 or ($v|has("percentage"))) then error("invalid fixed lvm volume") else . end |
        if $v.mode == "percentage" and (($v.percentage|type)!="number" or $v.percentage < 1 or $v.percentage > 100 or ($v|has("fixedBytes"))) then error("invalid percentage lvm volume") else . end |
        if ($v.mode == "original" or $v.mode == "remaining") and (($v|has("fixedBytes")) or ($v|has("percentage"))) then error("unexpected lvm fields") else . end |
        {schema:$lv,layout:$v}] as $items |
      if ([$items[].layout|select(.mode=="remaining")]|length)>1 or ([$items[].layout|select(.mode=="percentage")|.percentage]|add//0)>100 then error("lvm mode totals") else . end |
      ($items | map(. + {bytes:modebytes((.schema + .layout);$capacity;$vg.extentBytes)})) as $pre |
      ($pre|map(.bytes)|add) as $used |
      if $used > $capacity then error("lvm capacity exceeded") else . end |
      (reduce $pre[] as $item ({out:[]};
        ($item.schema + {resolvedBytes:(if $item.layout.mode == "remaining" then ((($capacity-$used)/$vg.extentBytes|floor)*$vg.extentBytes) else $item.bytes end)}) as $entry |
        if $entry.resolvedBytes < $entry.minBytes then error("lvm minimum") else .out += [$entry] end
       ) | .out) as $volumes |
      if ([$volumes[]|.resolvedBytes]|add) > $capacity then error("lvm resolved capacity") else {pv:$pv,vg:$vg,pvBytes:$pvBytes,freeSpacePolicy:$plan.freeSpacePolicy,volumes:$volumes} end' >"$rootpxe_resolved_lvm_layout_file" || { rm -f "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file; return 1; }
    export rootpxe_resolved_lvm_layout_file
}

# Restore metadata and per-LV payloads only after a matching deploy permit.
# The PV never has a raw payload: doing so would overwrite the layout just
# resolved from the immutable task snapshot.
rootpxe_restore_lvm_volumes() {
    local rootpxe_restore_status_file rootpxe_restore_status_rc
    rootpxe_restore_lvm_error_code=LVM_RESTORE_PREFLIGHT_FAILED
    rootpxe_restore_lvm_error_reason=preflight_or_validation
    rootpxe_restore_status_file=$(mktemp /tmp/rootpxe-lvm-restore-status.XXXXXX) || return 1
    # Keep a caller-visible default even when a preflight branch fails before
    # it can name a narrower cause inside the isolated restore subshell.
    printf '%s|%s\n' "$rootpxe_restore_lvm_error_code" "$rootpxe_restore_lvm_error_reason" >"$rootpxe_restore_status_file" || { rm -f -- "$rootpxe_restore_status_file"; return 1; }
    (
    rootpxe_restore_lvm_fail() {
        printf '%s|%s\n' "$1" "$2" >"$rootpxe_restore_status_file"
        return 1
    }
    local image_path="$1" target_disk="$2" plan="${rootpxe_resolved_lvm_layout_file:-}" pv vg pv_path pv_meta vg_cfg lv_name lv_uuid lv_fs lv_artifact lv_bytes swap_uuid target_id actual_size current_size pv_original pv_bytes vg_uuid extent lv_list expected_lvs prevalidated_lvs=0 restored_lvs=0 xfs_mount="" vg_active=no vgs_json pvs_json lvs_json
    local -A seen_lv_names=() seen_artifacts=()
    trap '[[ -n $xfs_mount ]] && umount "$xfs_mount" >/dev/null 2>&1 || true; [[ -n $xfs_mount ]] && rmdir "$xfs_mount" >/dev/null 2>&1 || true; [[ $vg_active == yes && -n $vg && -n $vg_uuid ]] && vgchange -an --select "vg_uuid=$vg_uuid" "$vg" >/dev/null 2>&1 || true; rm -f -- "${lv_list:-}"' EXIT
    [[ ${rootpxe_disk_permit_granted:-no} == yes && -r $plan ]] || { rootpxe_restore_lvm_fail LVM_RESTORE_PERMIT_FAILED permit_or_plan; return 1; }
    target_id=$(rootpxe_disk_stable_identity "$target_disk") || { rootpxe_restore_lvm_fail LVM_RESTORE_TARGET_IDENTITY_FAILED stable_identity; return 1; }
    [[ ${rootpxe_disk_permit_target_id:-} == "$target_id" && ${rootpxe_disk_permit_operation:-} =~ ^(deploy_write|nvme_format\+deploy_write)$ ]] || { rootpxe_restore_lvm_fail LVM_RESTORE_PERMIT_FAILED target_or_operation; return 1; }
    pv=$(jq -er '.pv.uuid' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED pv_uuid; return 1; }; vg=$(jq -er '.vg.name' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED vg_name; return 1; }
    pv_original=$(jq -er '.pv.originalBytes' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED pv_original_bytes; return 1; }; vg_uuid=$(jq -er '.vg.uuid' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED vg_uuid; return 1; }; extent=$(jq -er '.vg.extentBytes' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED vg_extent_bytes; return 1; }
    pv_path=$(rootpxe_lvm_partition_path "$target_disk" "$(jq -er '.pv.partitionNumber' "$plan")") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED pv_partition; return 1; }
    pv_meta=$(jq -er '.pv.artifact' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED pv_artifact; return 1; }; vg_cfg=$(jq -er '.pv.vgConfigArtifact' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED vg_config_artifact; return 1; }
    rootpxe_lvm_safe_identifier "$pv" && rootpxe_lvm_storage_identifier "$vg" && rootpxe_lvm_safe_identifier "$vg_uuid" || { rootpxe_restore_lvm_fail LVM_RESTORE_IDENTIFIER_INVALID pv_or_vg; return 1; }
    rootpxe_safe_relative_path "$pv_meta" >/dev/null && rootpxe_safe_relative_path "$vg_cfg" >/dev/null || { rootpxe_restore_lvm_fail LVM_RESTORE_ARTIFACT_PATH_INVALID pv_or_vg_config; return 1; }
    [[ -r "$image_path/$pv_meta" && -r "$image_path/$vg_cfg" ]] || { rootpxe_restore_lvm_fail LVM_RESTORE_METADATA_ARTIFACT_MISSING pv_or_vg_config; return 1; }
    # The PV sidecar is not a decorative artifact: it binds the restore file
    # to the captured PV UUID before any destructive LVM command is issued.
    grep -F -- "$pv" "$image_path/$pv_meta" >/dev/null 2>&1 || { rootpxe_restore_lvm_fail LVM_RESTORE_PV_METADATA_MISMATCH pv_uuid; return 1; }
    [[ $pv_original =~ ^[1-9][0-9]*$ && $extent =~ ^[1-9][0-9]*$ ]] || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_SIZE_INVALID pv_or_extent; return 1; }
    # Process substitution would hide jq's exit status from the while loop.
    # Materialise and validate the whole NUL-framed LV list before *any* LVM
    # metadata command: malformed/empty plans must fail loud without writes.
    lv_list=$(mktemp /tmp/rootpxe-lvm-restore.XXXXXX) || { rootpxe_restore_lvm_fail LVM_LV_LIST_CREATE_FAILED mktemp; return 1; }
    chmod 600 "$lv_list" || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_LIST_CREATE_FAILED chmod; return 1; }
    if ! jq -jr '.volumes[]|.name,"\u0000",.uuid,"\u0000",.fs,"\u0000",(.artifact // ""),"\u0000",(.resolvedBytes|tostring),"\u0000",(.swapUuid // ""),"\u0000"' "$plan" >"$lv_list"; then
        rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_LIST_BUILD_FAILED jq; return 1
    fi
    expected_lvs=$(jq -er '.volumes|length' "$plan") || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_LIST_COUNT_FAILED jq; return 1; }
    [[ $expected_lvs =~ ^[1-9][0-9]*$ ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_LIST_COUNT_FAILED invalid; return 1; }
    rootpxe_lvm_json_jq -e '
      (.volumes) as $volumes |
      ($volumes|type=="array" and length > 0 and
       all($volumes[]; (.name|type=="string" and test("^[A-Za-z0-9._+-]{1,160}$")) and
                         (.uuid|type=="string" and test("^[A-Za-z0-9._:+-]{1,160}$")) and
                         (.fs|IN("ext2","ext3","ext4","xfs","swap")) and
                         (.resolvedBytes|type=="number" and . > 0)) and
       ([$volumes[].name|ascii_downcase]|unique|length) == ($volumes|length))
    ' "$plan" >/dev/null || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_PLAN_INVALID schema; return 1; }
    # Validate every payload contract before metadata writes.  Artifact names
    # are deliberately restricted to one Windows-safe filename: schema paths
    # are never interpreted as directories and are not scanned for fallbacks.
    [[ -s $lv_list ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_LIST_EMPTY_FAILED empty; return 1; }
    while IFS= read -r -d '' lv_name && IFS= read -r -d '' lv_uuid && IFS= read -r -d '' lv_fs && IFS= read -r -d '' lv_artifact && IFS= read -r -d '' lv_bytes && IFS= read -r -d '' swap_uuid; do
        rootpxe_lvm_storage_identifier "$lv_name" && rootpxe_lvm_safe_identifier "$lv_uuid" && [[ $lv_bytes =~ ^[1-9][0-9]*$ ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_PLAN_INVALID "lv_${lv_name}_identity_or_size"; return 1; }
        [[ ${seen_lv_names[${lv_name,,}]:-0} -eq 0 ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_PLAN_INVALID "lv_${lv_name}_duplicate"; return 1; }
        seen_lv_names[${lv_name,,}]=1
        case $lv_fs in ext2|ext3|ext4|xfs)
            [[ -n $lv_artifact ]] && rootpxe_lvm_storage_filename "$lv_artifact" && rootpxe_safe_relative_path "$lv_artifact" >/dev/null && [[ -r "$image_path/$lv_artifact" && ${seen_artifacts[${lv_artifact,,}]:-0} -eq 0 ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_ARTIFACT_INVALID_OR_MISSING "lv_${lv_name}"; return 1; }
            seen_artifacts[${lv_artifact,,}]=1
            [[ -z $swap_uuid ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_PLAN_INVALID "lv_${lv_name}_swap_uuid"; return 1; }
            ;;
        swap)
            [[ -z $lv_artifact ]] && rootpxe_lvm_safe_identifier "$swap_uuid" || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_PLAN_INVALID "lv_${lv_name}_swap_artifact_or_uuid"; return 1; }
            ;;
        *) rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_PLAN_INVALID "lv_${lv_name}_filesystem"; return 1;;
        esac
        prevalidated_lvs=$((prevalidated_lvs + 1))
    done <"$lv_list"
    [[ $prevalidated_lvs -eq $expected_lvs ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_LIST_COUNT_FAILED parsed; return 1; }
    pv_bytes=$(jq -er '.pvBytes' "$plan") || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_FIELD_FAILED pv_bytes; return 1; }
    [[ $pv_bytes =~ ^[1-9][0-9]*$ && $pv_bytes -ge $pv_original ]] || { rootpxe_restore_lvm_fail LVM_RESTORE_PLAN_SIZE_INVALID pv_bytes; return 1; }
    pvcreate --uuid "$pv" --restorefile "$image_path/$vg_cfg" -ff -y "$pv_path" || { rootpxe_restore_lvm_fail LVM_PV_CREATE_FAILED pvcreate; return 1; }
    vgcfgrestore -f "$image_path/$vg_cfg" "$vg" || { rootpxe_restore_lvm_fail LVM_VG_CONFIG_RESTORE_FAILED vgcfgrestore; return 1; }
    if [[ $pv_bytes -gt $pv_original ]]; then
        pvresize --setphysicalvolumesize "${pv_bytes}B" "$pv_path" || { rootpxe_restore_lvm_fail LVM_PV_RESIZE_FAILED pvresize; return 1; }
    fi
    if ! vgchange -ay --select "vg_uuid=$vg_uuid" "$vg"; then
        vgchange -an --select "vg_uuid=$vg_uuid" "$vg" >/dev/null 2>&1 || true
        rootpxe_restore_lvm_fail LVM_VG_ACTIVATION_FAILED vgchange
        return 1
    fi
    vg_active=yes
    vgs_json=$(vgs --reportformat json -o vg_name,vg_uuid "$vg" 2>/dev/null) || return 1
    rootpxe_lvm_json_jq -e --arg name "$vg" --arg uuid "$vg_uuid" '(.report|type=="array" and length==1 and ((.[0].vg? // [])|type=="array") and ((.[0].vg? // [])|length==1) and .[0].vg[0].vg_name==$name and .[0].vg[0].vg_uuid==$uuid)' <<<"$vgs_json" >/dev/null || return 1
    pvs_json=$(pvs --reportformat json -o pv_name,pv_uuid,vg_name,vg_uuid "$pv_path" 2>/dev/null) || return 1
    rootpxe_lvm_json_jq -e --arg path "$pv_path" --arg pv "$pv" --arg vg "$vg" --arg vguuid "$vg_uuid" '
      (.report|type=="array" and length==1 and ((.[0].pv? // [])|type=="array") and ((.[0].pv? // [])|length==1) and
       .[0].pv[0].pv_name==$path and .[0].pv[0].pv_uuid==$pv and .[0].pv[0].vg_name==$vg and .[0].pv[0].vg_uuid==$vguuid)
    ' <<<"$pvs_json" >/dev/null || { rm -f "$lv_list"; return 1; }
    # The list was fully validated before pvcreate.  Re-read its NUL framing
    # here only to bind each verified schema entry to the restored LV.
    while IFS= read -r -d '' lv_name && IFS= read -r -d '' lv_uuid && IFS= read -r -d '' lv_fs && IFS= read -r -d '' lv_artifact && IFS= read -r -d '' lv_bytes && IFS= read -r -d '' swap_uuid; do
        lvs_json=$(lvs --reportformat json -o vg_name,vg_uuid,lv_name,lv_uuid,lv_path --select "vg_uuid=$vg_uuid" "$vg/$lv_name" 2>/dev/null) || { rootpxe_restore_lvm_fail LVM_LV_IDENTITY_QUERY_FAILED "lv_${lv_name}"; return 1; }
        rootpxe_lvm_json_jq -e --arg name "$vg" --arg uuid "$vg_uuid" --arg lv "$lv_name" --arg lvuuid "$lv_uuid" '(.report|type=="array" and length==1 and ((.[0].lv? // [])|type=="array") and ((.[0].lv? // [])|length==1) and .[0].lv[0].vg_name==$name and .[0].lv[0].vg_uuid==$uuid and .[0].lv[0].lv_name==$lv and .[0].lv[0].lv_uuid==$lvuuid and .[0].lv[0].lv_path==("/dev/"+$name+"/"+$lv))' <<<"$lvs_json" >/dev/null || { rootpxe_restore_lvm_fail LVM_LV_IDENTITY_FAILED "lv_${lv_name}"; return 1; }
        current_size=$(blockdev --getsize64 "/dev/$vg/$lv_name" 2>/dev/null) || { rootpxe_restore_lvm_fail LVM_LV_SIZE_READ_FAILED "lv_${lv_name}"; return 1; }
        [[ $current_size =~ ^[1-9][0-9]*$ && $lv_bytes -ge $current_size ]] || { rootpxe_restore_lvm_fail LVM_LV_SIZE_INVALID "lv_${lv_name}"; return 1; }
        if [[ $lv_bytes -gt $current_size ]]; then lvextend -y -L "${lv_bytes}B" "/dev/$vg/$lv_name" || { rootpxe_restore_lvm_fail LVM_LV_EXTEND_FAILED "lv_${lv_name}"; return 1; }; fi
        if [[ $lv_fs == swap ]]; then mkswap -U "$swap_uuid" "/dev/$vg/$lv_name" || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_SWAP_RECREATE_FAILED "lv_${lv_name}"; return 1; }; restored_lvs=$((restored_lvs + 1)); continue; fi
        writeImage "$image_path/$lv_artifact" "/dev/$vg/$lv_name" no || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_LV_IMAGE_RESTORE_FAILED "lv_${lv_name}_${lv_fs}"; return 1; }
        if [[ $lv_fs == xfs ]] && ! rootpxe_xfs_restore_postcheck "/dev/$vg/$lv_name"; then
            case ${rootpxe_xfs_restore_error:-post_restore_inconsistent} in
                dirty_log_replay_mount_failed) rootpxe_restore_lvm_fail LVM_XFS_DIRTY_LOG_REPLAY_MOUNT_FAILED "lv_${lv_name}" ;;
                dirty_log_replay_unmount_failed) rootpxe_restore_lvm_fail LVM_XFS_DIRTY_LOG_REPLAY_UNMOUNT_FAILED "lv_${lv_name}" ;;
                post_replay_check_failed) rootpxe_restore_lvm_fail LVM_XFS_POST_REPLAY_CHECK_FAILED "lv_${lv_name}" ;;
                post_restore_inconsistent) rootpxe_restore_lvm_fail LVM_XFS_POST_RESTORE_CHECK_FAILED "lv_${lv_name}" ;;
                device_mounted) rootpxe_restore_lvm_fail LVM_XFS_POST_RESTORE_DEVICE_MOUNTED "lv_${lv_name}" ;;
                mount_state_query_failed) rootpxe_restore_lvm_fail LVM_XFS_POST_RESTORE_MOUNT_STATE_FAILED "lv_${lv_name}" ;;
                temp_create_failed|temp_cleanup_failed) rootpxe_restore_lvm_fail LVM_XFS_POST_RESTORE_CLEANUP_FAILED "lv_${lv_name}" ;;
                *) rootpxe_restore_lvm_fail LVM_XFS_POST_RESTORE_CHECK_FAILED "lv_${lv_name}" ;;
            esac
            return 1
        fi
        if [[ $lv_fs == xfs && $lv_bytes -gt $current_size ]]; then
            xfs_mount=$(mktemp -d /tmp/rootpxe-xfs-grow.XXXXXX) || return 1
            mount -o nouuid "/dev/$vg/$lv_name" "$xfs_mount" || { rootpxe_restore_lvm_fail LVM_XFS_GROW_MOUNT_FAILED "lv_${lv_name}"; return 1; }
            xfs_growfs "$xfs_mount" || { rootpxe_restore_lvm_fail LVM_XFS_GROW_FAILED "lv_${lv_name}"; return 1; }
            umount "$xfs_mount" || { rootpxe_restore_lvm_fail LVM_XFS_GROW_UNMOUNT_FAILED "lv_${lv_name}"; return 1; }
            rmdir "$xfs_mount" || return 1
            xfs_mount=""
        elif [[ $lv_fs != xfs ]]; then
            e2fsck -pf "/dev/$vg/$lv_name"; actual_size=$?
            [[ $actual_size -eq 0 || $actual_size -eq 1 ]] || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_EXT_CHECK_FAILED "lv_${lv_name}_${actual_size}"; return 1; }
            resize2fs "/dev/$vg/$lv_name" || { rm -f "$lv_list"; rootpxe_restore_lvm_fail LVM_EXT_RESIZE_FAILED "lv_${lv_name}"; return 1; }
        fi
        actual_size=$(blockdev --getsize64 "/dev/$vg/$lv_name" 2>/dev/null) || { rootpxe_restore_lvm_fail LVM_LV_FINAL_SIZE_READ_FAILED "lv_${lv_name}"; return 1; }
        [[ $actual_size == "$lv_bytes" ]] || { rootpxe_restore_lvm_fail LVM_LV_FINAL_SIZE_MISMATCH "lv_${lv_name}"; return 1; }
        restored_lvs=$((restored_lvs + 1))
    done <"$lv_list"
    [[ $restored_lvs -eq $expected_lvs ]]
    )
    rootpxe_restore_status_rc=$?
    if [[ $rootpxe_restore_status_rc -ne 0 && -r $rootpxe_restore_status_file ]]; then
        IFS='|' read -r rootpxe_restore_lvm_error_code rootpxe_restore_lvm_error_reason <"$rootpxe_restore_status_file" || true
    fi
    rm -f -- "$rootpxe_restore_status_file"
    return "$rootpxe_restore_status_rc"
}

rootpxe_sfdisk_layout_fingerprint() {
    local table_file="$1"
    [[ -r $table_file ]] || return 1
    # sfdisk dumps may normalize GUID casing and reorder partition lines.  Keep
    # those presentation details out of the comparison, but retain every
    # partition identity and geometry field that PXEOS supplies to sfdisk.
    awk '
      function trim(value) { gsub(/\r/, "", value); sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
      function value_for(text, key,    pattern,value,end) {
        pattern = "(^|,)[[:space:]]*" key "="
        if (!match(text, pattern)) return "<absent>"
        value = substr(text, RSTART + RLENGTH)
        if (substr(value, 1, 1) == "\"") {
          value = substr(value, 2)
          end = index(value, "\"")
          if (end == 0) return "<invalid>"
          return "\"" substr(value, 1, end - 1) "\""
        }
        sub(/,.*/, "", value)
        return trim(value)
      }
      function flag_for(text, key,    pattern) {
        pattern = "(^|,)[[:space:]]*" key "([[:space:]]*,|[[:space:]]*$)"
        return match(text, pattern) ? "true" : "<absent>"
      }
      /^label:[[:space:]]*/ { value=trim($2); if (++labels != 1 || value !~ /^(gpt|dos)$/) bad=1; table=tolower(value); print "header\tlabel\t" table; next }
      /^label-id:[[:space:]]*/ { value=trim($2); if (++label_ids != 1 || (value !~ /^[0-9A-Fa-f-]+$/ && value !~ /^0x[0-9A-Fa-f]+$/)) bad=1; print "header\tlabel-id\t" tolower(value); next }
      /^device:[[:space:]]*/ { value=trim($2); if (++devices != 1 || index(value, "/dev/") != 1) bad=1; print "header\tdevice\t" value; next }
      /^unit:[[:space:]]*/ { value=trim($2); if (++units != 1 || value != "sectors") bad=1; print "header\tunit\t" value; next }
      /^first-lba:[[:space:]]*/ { value=trim($2); if (++firsts != 1 || value !~ /^[1-9][0-9]*$/) bad=1; print "header\tfirst-lba\t" value; next }
      /^last-lba:[[:space:]]*/ { value=trim($2); if (++lasts != 1 || value !~ /^[1-9][0-9]*$/) bad=1; print "header\tlast-lba\t" value; next }
      /^sector-size:[[:space:]]*/ { value=trim($2); if (++sectors != 1 || value !~ /^[1-9][0-9]*$/) bad=1; print "header\tsector-size\t" value; next }
      /start=/ {
        path=$1; number=path
        if (!sub(/^.*[^0-9]/, "", number) || number !~ /^[1-9][0-9]*$/ || seen[number]++) { bad=1; next }
        text=$0; sub(/^[^:]*:[[:space:]]*/, "", text)
        start=value_for(text, "start"); size=value_for(text, "size"); type=value_for(text, "type"); uuid=value_for(text, "uuid"); name=value_for(text, "name"); attrs=value_for(text, "attrs"); bootable=flag_for(text, "bootable")
        if (start !~ /^(0|[1-9][0-9]*)$/ || size !~ /^[1-9][0-9]*$/ || type == "<invalid>" || uuid == "<invalid>" || name == "<invalid>" || attrs == "<invalid>" || bootable == "<invalid>") { bad=1; next }
        print "partition\t" sprintf("%010d", number) "\tstart=" start "\tsize=" size "\ttype=" tolower(type) "\tuuid=" tolower(uuid) "\tname=" name "\tattrs=" attrs "\tbootable=" tolower(bootable)
        parts++
      }
      END {
        if (labels != 1 || devices != 1 || units != 1 || sectors != 1 || parts < 1) bad=1
        if (table == "gpt" && (label_ids != 1 || firsts != 1 || lasts != 1)) bad=1
        if (bad) exit 1
      }' "$table_file" | LC_ALL=C sort
    return "${PIPESTATUS[0]}"
}

rootpxe_layout_readback_failed() {
    local reason="$1"
    rootpxe_layout_readback_reason="$reason"
    rootpxe_layout_apply_code=LAYOUT_READBACK_FAILED
    rootpxe_layout_apply_reason="sfdisk_${reason}"
    rootpxe_cleanup_deployment_partition_file
    # Field names and the normalized mismatch class are safe to display; raw
    # partition data is deliberately kept out of task logs.
    rootpxe_console_message ERROR "Deployment layout readback mismatch: $reason"
    rootpxe_stage layout_apply "Deployment layout readback mismatch: $reason"
    return 1
}

rootpxe_layout_apply_failed() {
    local code="$1" reason="$2" diagnostics="${3:-}"
    rootpxe_layout_apply_code="$code"
    rootpxe_layout_apply_reason="$reason"
    rootpxe_layout_diagnostics_file="$diagnostics"
    rootpxe_cleanup_deployment_partition_file
    [[ -z $diagnostics ]] || chmod 600 "$diagnostics" 2>/dev/null
    # Do not print the partition table: sfdisk stderr is retained only in the
    # protected diagnostic file, while task logs receive a stable phase code.
    rootpxe_console_message ERROR "Deployment layout apply failed: $code ($reason)${diagnostics:+; diagnostics: $diagnostics}"
    rootpxe_stage layout_apply "Deployment layout apply failed: $code ($reason)${diagnostics:+; diagnostics: $diagnostics}"
    return 1
}

rootpxe_require_single_disk_layout_metadata() {
    local partition_file="$1" schema_file="$2" layout_file="$3"
    rootpxe_layout_metadata_reason=""
    [[ -r $partition_file ]] || { rootpxe_layout_metadata_reason=partition_table_missing; return 1; }
    [[ -r $schema_file ]] || { rootpxe_layout_metadata_reason=original_schema_missing; return 1; }
    [[ -r $layout_file ]] || { rootpxe_layout_metadata_reason=deployment_layout_missing; return 1; }
}

rootpxe_restore_deployment_boot_code() {
    local disk="$1" disk_number="$2" image_path="$3" schema_file="$4" table boot_file size logical first_start expected_sectors expected_bytes restore_embedding=no
    [[ -n $disk && $disk_number =~ ^[1-9][0-9]*$ && -d $image_path && -r $schema_file ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    table=$(jq -er '.partitionTable' "$schema_file" 2>/dev/null) || return 1
    [[ $table == gpt || $table == mbr ]] || return 1
    logical=$(jq -er '.logicalSectorBytes // 512 | if type == "number" and . > 0 and floor == . then . else error("invalid logical sector size") end' "$schema_file" 2>/dev/null) || return 1
    first_start=$(jq -er '[.partitions[]? | select((.startSectors | type) == "number" and .startSectors > 0 and (.startSectors | floor) == .startSectors) | .startSectors] | min // error("missing first partition")' "$schema_file" 2>/dev/null) || return 1
    [[ $logical =~ ^[1-9][0-9]*$ && $first_start =~ ^[1-9][0-9]*$ ]] || return 1
    expected_sectors=$first_start
    [[ $expected_sectors -gt 2048 ]] && expected_sectors=2048
    [[ $expected_sectors -eq 8 || $expected_sectors -eq 63 ]] && expected_sectors=1
    expected_bytes=$((expected_sectors * logical))
    case $table in
        gpt)
            # dN.mbr is an sgdisk GPT backup, not the raw boot sector.  The
            # separate GRUB capture is the only safe GPT source; its absence
            # is normal for UEFI Windows/Linux and must be a no-op.
            boot_file="$image_path/d${disk_number}.grub.mbr"
            [[ -e $boot_file ]] || return 0
            ;;
        mbr)
            boot_file="$image_path/d${disk_number}.mbr"
            [[ -e "$image_path/d${disk_number}.has_grub" ]] && restore_embedding=yes
            ;;
    esac
    [[ -r $boot_file ]] || return 1
    size=$(wc -c <"$boot_file" 2>/dev/null) || return 1
    [[ $size =~ ^[0-9]+$ && $size -eq $expected_bytes && $size -ge 512 ]] || return 1
    # sfdisk has already written the final MBR/GPT metadata.  Restore only the
    # boot-code region and never the MBR partition entries (446-511), so this
    # cannot reintroduce the source disk layout after it has been resolved for
    # the target disk.
    dd if="$boot_file" of="$disk" bs=1 count=440 conv=notrunc >/dev/null 2>&1 || return 1
    [[ $restore_embedding == yes && $expected_bytes -gt $logical ]] || return 0
    # saveGRUB captures only the pre-first-partition region.  Keep the final
    # MBR entries/signature at 440-511 intact, then restore only the captured
    # embedding area up to (never into) the first final partition.
    dd if="$boot_file" of="$disk" bs=1 skip="$logical" seek="$logical" count=$((expected_bytes - logical)) conv=notrunc >/dev/null 2>&1
}

rootpxe_apply_deployment_layout() {
    local disk="$1" template="$2" map output output_dir verify expected actual expected_numbers actual_numbers logical disk_bytes total_sectors table template_sector first_lba= last_lba= is_gpt=0 write_stderr partprobe_stderr dump_stderr reread_attempt reread_max=5 reread_ok=0
    rootpxe_layout_apply_code=""
    rootpxe_layout_apply_reason=""
    rootpxe_layout_diagnostics_file=""
    [[ -r ${rootpxe_resolved_layout_file:-} && -r $template ]] || { rootpxe_layout_apply_failed LAYOUT_METADATA_INVALID layout_or_partition_template_missing; return 1; }
    logical=$(blockdev --getss "$disk" 2>/dev/null) || { rootpxe_layout_apply_failed LAYOUT_TARGET_GEOMETRY_UNAVAILABLE logical_sector_size_unavailable; return 1; }
    disk_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || { rootpxe_layout_apply_failed LAYOUT_TARGET_GEOMETRY_UNAVAILABLE disk_size_unavailable; return 1; }
    [[ $logical =~ ^[1-9][0-9]*$ && $disk_bytes =~ ^[1-9][0-9]*$ ]] || { rootpxe_layout_apply_failed LAYOUT_TARGET_GEOMETRY_INVALID invalid_target_geometry; return 1; }
    (( logical <= 9223372036854775807 && disk_bytes <= 9223372036854775807 && disk_bytes % logical == 0 )) || { rootpxe_layout_apply_failed LAYOUT_TARGET_GEOMETRY_INVALID unaligned_target_geometry; return 1; }
    total_sectors=$((disk_bytes / logical))
    (( total_sectors > 0 )) || { rootpxe_layout_apply_failed LAYOUT_TARGET_GEOMETRY_INVALID zero_target_sectors; return 1; }
    table=$(awk '/^label:/{print tolower($2); count++} END{if(count != 1) exit 1}' "$template") || { rootpxe_layout_apply_failed LAYOUT_TEMPLATE_INVALID partition_table_type_missing; return 1; }
    [[ $table == gpt || $table == dos ]] || { rootpxe_layout_apply_failed LAYOUT_TEMPLATE_INVALID unsupported_partition_table_type; return 1; }
    template_sector=$(awk '/^sector-size:/{print $2; count++} END{if(count != 1) exit 1}' "$template") || { rootpxe_layout_apply_failed LAYOUT_TEMPLATE_INVALID sector_size_missing; return 1; }
    [[ $template_sector =~ ^[1-9][0-9]*$ && $template_sector == "$logical" ]] || { rootpxe_layout_apply_failed LAYOUT_TEMPLATE_INVALID sector_size_mismatch; return 1; }
    if [[ $table == gpt ]]; then
        is_gpt=1
        first_lba=$(awk '/^first-lba:/{print $2; count++} END{if(count != 1) exit 1}' "$template") || { rootpxe_layout_apply_failed LAYOUT_TEMPLATE_INVALID gpt_first_lba_missing; return 1; }
        [[ $first_lba =~ ^[1-9][0-9]*$ ]] || { rootpxe_layout_apply_failed LAYOUT_TEMPLATE_INVALID gpt_first_lba_invalid; return 1; }
        (( first_lba < total_sectors && total_sectors - first_lba >= first_lba )) || { rootpxe_layout_apply_failed LAYOUT_TARGET_GEOMETRY_INVALID gpt_usable_lba_unavailable; return 1; }
        last_lba=$((total_sectors - first_lba))
    fi
    map=$(mktemp /tmp/rootpxe-layout-map.XXXXXX) || { rootpxe_layout_apply_failed LAYOUT_PLAN_FAILED map_file_create_failed; return 1; }
    rootpxe_cleanup_deployment_partition_file
    if [[ ${rootpxe_deployment_layout_changed:-yes} == yes ]]; then
        output_dir=$(umask 077; mktemp -d /tmp/rootpxe-deployment-layout.XXXXXX) || { rm -f "$map"; rootpxe_layout_apply_failed LAYOUT_TEMPLATE_REWRITE_FAILED output_file_create_failed; return 1; }
        output="$output_dir/d1.deployment.partitions"
        : >"$output" || { rm -rf "$output_dir" "$map"; rootpxe_layout_apply_failed LAYOUT_TEMPLATE_REWRITE_FAILED output_file_create_failed; return 1; }
        rootpxe_deployment_partition_file="$output"
    else
        output=$(mktemp /tmp/rootpxe-layout-sfdisk.XXXXXX) || { rm -f "$map"; rootpxe_layout_apply_failed LAYOUT_TEMPLATE_REWRITE_FAILED output_file_create_failed; return 1; }
    fi
    export rootpxe_deployment_partition_file
    chmod 600 "$map" "$output"
    jq -r '.[] | [.number,.startSectors,.resolvedSectors] | @tsv' "$rootpxe_resolved_layout_file" >"$map" || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_PLAN_INVALID layout_map_parse_failed; return 1; }
    while IFS=$'\t' read -r number start size extra; do
        size=${size%$'\r'}
        extra=${extra%$'\r'}
        [[ -n $number && -z ${extra:-} && $number =~ ^[1-9][0-9]*$ && $start =~ ^(0|[1-9][0-9]*)$ && $size =~ ^[1-9][0-9]*$ ]] || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_PLAN_INVALID invalid_partition_plan_entry; return 1; }
        (( number <= 2147483647 && start < total_sectors && size <= total_sectors - start )) || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_PLAN_INVALID partition_plan_exceeds_target; return 1; }
        (( is_gpt == 0 || start + size - 1 <= last_lba )) || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_PLAN_INVALID partition_plan_exceeds_gpt_usable_range; return 1; }
    done <"$map"
    awk -F'\t' 'NF != 3 || seen[$1]++ {exit 1} END {exit (NR > 0 ? 0 : 1)}' "$map" || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_PLAN_INVALID partition_plan_numbers_invalid; return 1; }
    expected_numbers=$(awk -F'\t' '{print $1}' "$map" | sort -n | tr '\n' ' ')
    actual_numbers=$(awk '/start=/ {n=$1; sub(/^.*[^0-9]/,"",n); print n}' "$template" | sort -n | tr '\n' ' ')
    [[ $expected_numbers == "$actual_numbers" ]] || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_PLAN_INVALID partition_plan_numbers_mismatch; return 1; }
    awk -v map="$map" -v disk="$disk" -v logical="$logical" -v is_gpt="$is_gpt" -v last_lba="$last_lba" '
      function partition_path(number) { return disk ((disk ~ /[0-9]$/) ? "p" number : number) }
      BEGIN { while ((getline < map) > 0) { split($0,a,"\t"); starts[a[1]]=a[2]; sizes[a[1]]=a[3]; expected++ } close(map) }
      /^device:[[:space:]]*/ { devices++; print "device: " disk; next }
      /^sector-size:[[:space:]]*/ { sectors++; print "sector-size: " logical; next }
      /^first-lba:[[:space:]]*/ { firsts++; print; next }
      /^last-lba:[[:space:]]*/ { lasts++; if (is_gpt) { print "last-lba: " last_lba; next } print; next }
      /start=/ { line=$0; dev=$1; n=dev; sub(/^.*[^0-9]/,"",n); if (!(n in starts) || seen[n]++) exit 20;
        sub(/^[^[:space:]]+/, partition_path(n), line);
        sub(/start=[[:space:]]*[0-9]+/, "start=" sprintf("%12d", starts[n]), line);
        sub(/size=[[:space:]]*[0-9]+/, "size=" sprintf("%12d", sizes[n]), line); print line; parts++; next }
      { print }
      END { if (devices != 1 || sectors != 1 || parts != expected || (is_gpt && (firsts != 1 || lasts != 1))) exit 21 }' "$template" >"$output" || { rm -f "$map" "$output"; rootpxe_layout_apply_failed LAYOUT_TEMPLATE_REWRITE_FAILED sfdisk_template_rewrite_failed; return 1; }
    write_stderr=$(mktemp /tmp/rootpxe-layout-sfdisk-write.XXXXXX.err) || { rm -f "$map" "$output"; rootpxe_layout_apply_failed SFDISK_WRITE_FAILED write_diagnostic_create_failed; return 1; }
    chmod 600 "$write_stderr"
    # Let this n-layout path own the kernel reread.  util-linux otherwise
    # requests BLKRRPART as part of sfdisk, where transient device busy races
    # lose the original error context before the bounded retry below can run.
    flock "$disk" sfdisk --no-reread --no-tell-kernel "$disk" <"$output" >/dev/null 2>"$write_stderr" || { rm -f "$map" "$output"; rootpxe_layout_apply_failed SFDISK_WRITE_FAILED sfdisk_write_failed "$write_stderr"; return 1; }
    rm -f "$write_stderr"
    partprobe_stderr=$(mktemp /tmp/rootpxe-layout-partprobe.XXXXXX.err) || { rm -f "$map" "$output"; rootpxe_layout_apply_failed PARTPROBE_FAILED diagnostic_create_failed; return 1; }
    chmod 600 "$partprobe_stderr"
    # Kernel partition-table reread is the synchronization point after the
    # no-reread sfdisk write.  It can transiently fail while udev observes the
    # new GPT; retry a short, fixed number of times without weakening the
    # later dump and semantic readback checks.
    for ((reread_attempt = 1; reread_attempt <= reread_max; reread_attempt++)); do
        udevadm settle >/dev/null 2>>"$partprobe_stderr" || :
        if blockdev --rereadpt "$disk" >/dev/null 2>>"$partprobe_stderr"; then
            reread_ok=1
            break
        fi
        (( reread_attempt < reread_max )) && sleep 1
    done
    [[ $reread_ok -eq 1 ]] || { rm -f "$map" "$output"; rootpxe_layout_apply_failed PARTPROBE_FAILED partition_table_reread_failed "$partprobe_stderr"; return 1; }
    rm -f "$partprobe_stderr"
    verify=$(mktemp /tmp/rootpxe-layout-verify.XXXXXX) || { rm -f "$map" "$output"; rootpxe_layout_apply_failed SFDISK_DUMP_FAILED verify_file_create_failed; return 1; }
    expected=$(mktemp /tmp/rootpxe-layout-expected.XXXXXX) || { rm -f "$map" "$output" "$verify"; rootpxe_layout_apply_failed LAYOUT_READBACK_FAILED expected_file_create_failed; return 1; }
    actual=$(mktemp /tmp/rootpxe-layout-actual.XXXXXX) || { rm -f "$map" "$output" "$verify" "$expected"; rootpxe_layout_apply_failed LAYOUT_READBACK_FAILED actual_file_create_failed; return 1; }
    chmod 600 "$expected" "$actual"
    dump_stderr=$(mktemp /tmp/rootpxe-layout-sfdisk-dump.XXXXXX.err) || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_apply_failed SFDISK_DUMP_FAILED dump_diagnostic_create_failed; return 1; }
    chmod 600 "$dump_stderr"
    flock "$disk" sfdisk -d "$disk" >"$verify" 2>"$dump_stderr" || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_apply_failed SFDISK_DUMP_FAILED sfdisk_dump_failed "$dump_stderr"; return 1; }
    rm -f "$dump_stderr"
    awk -v disk="$disk" -v logical="$logical" -v is_gpt="$is_gpt" -v last_lba="$last_lba" '
      /^device:[[:space:]]*/ { devices++; if ($2 != disk) exit 1 }
      /^sector-size:[[:space:]]*/ { sectors++; if ($2 != logical) exit 1 }
      /^last-lba:[[:space:]]*/ { lasts++; if (is_gpt && $2 != last_lba) exit 1 }
      END { if (devices != 1 || sectors != 1 || (is_gpt && lasts != 1)) exit 1 }' "$verify" || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_readback_failed header_geometry; return 1; }
    actual_numbers=$(awk '/start=/ {n=$1; sub(/^.*[^0-9]/,"",n); print n}' "$verify" | sort -n | tr '\n' ' ')
    [[ $expected_numbers == "$actual_numbers" ]] || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_readback_failed partition_numbers; return 1; }
    awk -v map="$map" '
      BEGIN { ok=1; while ((getline < map) > 0) { split($0,a,"\t"); starts[a[1]]=a[2]; sizes[a[1]]=a[3] } close(map) }
      /start=/ { dev=$1; n=dev; sub(/^.*[^0-9]/,"",n); split($0,a,","); st=a[1]; sub(/.*start=[[:space:]]*/,"",st); sz=a[2]; sub(/.*size=[[:space:]]*/,"",sz); if ((n in starts) && (st != starts[n] || sz != sizes[n])) ok=0 }
      END { exit(ok ? 0 : 1) }' "$verify" || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_readback_failed partition_geometry; return 1; }
    rootpxe_sfdisk_layout_fingerprint "$output" >"$expected" || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_readback_failed expected_format; return 1; }
    rootpxe_sfdisk_layout_fingerprint "$verify" >"$actual" || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_readback_failed actual_format; return 1; }
    cmp -s "$expected" "$actual" || { rm -f "$map" "$output" "$verify" "$expected" "$actual"; rootpxe_layout_readback_failed semantic_identity; return 1; }
    rm -f "$map" "$verify" "$expected" "$actual"
    # The immutable default has no adjusted partition file.  The generated
    # d1.deployment.partitions is retained only for a changed task and removed
    # by rootpxe_cleanup_task_json when the PXEOS session completes.
    [[ ${rootpxe_deployment_layout_changed:-yes} == yes ]] || rm -f "$output"
}
rootpxe_clear_smb_plaintext() { unset smb_username smb_password smb_domain; }
rootpxe_cleanup_smb_credentials() { [[ -n ${smb_credentials_file:-} ]] && rm -f -- "$smb_credentials_file"; smb_credentials_file=""; rootpxe_clear_smb_plaintext; }

# SMB credentials are decoded by the fixed checkin parser and never enter the
# kernel command line. The temporary file is removed by pxeos.mount.
rootpxe_prepare_smb_credentials() {
    smb_credentials_file=""
    if [[ ${protocol:-nfs} != "smb" ]]; then rootpxe_clear_smb_plaintext; return 0; fi
    [[ -n ${smb_username:-} && -n ${smb_password:-} ]] || { rootpxe_clear_smb_plaintext; return 1; }
    local file="/tmp/pxeos.smb.credentials.$$"
    local username="$smb_username" password="$smb_password" domain="${smb_domain:-}"
    [[ $username != *$'\n'* && $username != *$'\r'* && $password != *$'\n'* && $password != *$'\r'* && $domain != *$'\n'* && $domain != *$'\r'* ]] || { rootpxe_clear_smb_plaintext; return 1; }
    umask 077
    if ! {
        printf 'username=%s\npassword=%s\n' "$username" "$password"
        [[ -z $domain ]] || printf 'domain=%s\n' "$domain"
    } > "$file"; then
        rm -f "$file"
        rootpxe_clear_smb_plaintext; return 1
    fi
    chmod 600 "$file" || { rm -f "$file"; rootpxe_clear_smb_plaintext; return 1; }
    smb_credentials_file="$file"
    export smb_credentials_file
    rootpxe_clear_smb_plaintext
    trap rootpxe_cleanup_smb_credentials EXIT INT TERM
}

# The server owns the cancellation fence. This must run before any image
# operation because an authorized task may write a local disk.
rootpxe_request_disk_permit() {
    rootpxe_request_disk_permit_for_target "${1:-}" "${2:-capture_read_write}"
}

rootpxe_clear_disk_permit() {
    [[ -z ${rootpxe_disk_permit_bindings_file:-} ]] || rm -f -- "$rootpxe_disk_permit_bindings_file"
    unset rootpxe_disk_permit_granted rootpxe_disk_permit_target_id rootpxe_disk_permit_operation
    unset rootpxe_disk_permit_bindings_file
    rootpxe_disk_permit_http_status=""
    rootpxe_disk_permit_code=""
    rootpxe_disk_permit_console_reason=""
    rootpxe_disk_permit_report_message=""
}

# Only recognized server codes are rendered.  Unknown codes and response
# bodies remain private because either can contain unsafe remote text.
rootpxe_set_disk_permit_reason() {
    local body="$1" http_code="$2" code=""
    rootpxe_disk_permit_http_status="$http_code"
    if command -v jq >/dev/null 2>&1; then
        code=$(jq -er '.code | strings' <<<"$body" 2>/dev/null || :)
    fi
    rootpxe_disk_permit_console_reason="Disk permission was denied."
    rootpxe_disk_permit_report_message="Disk permission was denied. Confirm the task, target disk, and operation binding."
    case "$code" in
        DISK_PERMIT_INVALID_REQUEST)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Disk permit request is invalid."
            rootpxe_disk_permit_report_message="Disk permit request is invalid. Check the task context and operation."
            ;;
        DISK_PERMIT_UNSUPPORTED_OPERATION)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Disk operation is not supported."
            rootpxe_disk_permit_report_message="Disk operation is not supported. Check the task type."
            ;;
        DISK_PERMIT_INVALID_TARGET)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Disk target identifier is invalid."
            rootpxe_disk_permit_report_message="Disk target identifier is invalid. Check the stable disk identifier."
            ;;
        DISK_PERMIT_TASK_TYPE_MISMATCH)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Task type does not allow this disk operation."
            rootpxe_disk_permit_report_message="Task type does not allow this disk operation. Check the task configuration."
            ;;
        DISK_PERMIT_BINDING_CONFLICT)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Disk permit binding does not match the task."
            rootpxe_disk_permit_report_message="Disk permit binding does not match the task. Confirm the target disk and operation."
            ;;
        DISK_PERMIT_TASK_NOT_FOUND)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Task is not available for disk permission."
            rootpxe_disk_permit_report_message="Task is unavailable for disk permission. Confirm the task status."
            ;;
        DISK_PERMIT_TASK_REJECTED)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Task or disk binding was rejected."
            rootpxe_disk_permit_report_message="Task or disk binding was rejected. Confirm the task status."
            ;;
        DISK_PERMIT_TASK_NOT_RUNNING)
            rootpxe_disk_permit_code="$code"
            rootpxe_disk_permit_console_reason="Task is not running for disk permission."
            rootpxe_disk_permit_report_message="Task is not running for disk permission. Confirm the task status."
            ;;
    esac
}

rootpxe_set_disk_permit_protocol_error() {
    rootpxe_disk_permit_http_status="$1"
    rootpxe_disk_permit_code=""
    rootpxe_disk_permit_console_reason="Disk permit response is invalid."
    rootpxe_disk_permit_report_message="Disk permit response is invalid. Check the server protocol and task binding."
}

# A permit denial alone never proves that a task was cancelled.  Ask the
# status endpoint and accept only explicit JSON terminal states.
rootpxe_task_status_confirms_disk_permit_cancellation() {
    local api="${pxeapi:-${web:-}}" response body http_code status
    [[ -n $api ]] || return 1
    response=$(curl -Lks --connect-timeout 10 --max-time 30 \
        --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" \
        --data-urlencode "mac=$mac" -w $'\n%{http_code}' "${api}task-status" 2>/dev/null) || return 1
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    command -v jq >/dev/null 2>&1 || return 1
    status=$(jq -er '.status | strings' <<<"$body" 2>/dev/null) || return 1
    case "$http_code:$status" in
        2[0-9][0-9]:cancelled|2[0-9][0-9]:superseded|2[0-9][0-9]:deleted|404:deleted) return 0 ;;
        *) return 1 ;;
    esac
}

# Permit is bound to a stable target disk identity and the planned destructive
# operation.  A successful HTTP response alone is never sufficient.
rootpxe_request_disk_permit_for_target() {
    local target_id="$1" operation="$2" api response body http_code granted echoed_target echoed_operation
    # Return values: 0 granted; 10 confirmed cancellation; 11 retry; 12 deny/protocol.
    rootpxe_clear_disk_permit
    rootpxe_require_task_context || return 11
    api="${pxeapi:-${web:-}}"
    [[ -n $api ]] || return 11
    response=$(curl -Lks --connect-timeout 10 --max-time 30 \
        --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" \
        --data-urlencode "mac=$mac" --data-urlencode "targetId=$target_id" \
        --data-urlencode "operation=$operation" -w $'\n%{http_code}' "${api}disk-permit" 2>/dev/null) || return 11
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    [[ $http_code =~ ^[0-9]{3}$ ]] || { rootpxe_set_disk_permit_protocol_error unknown; return 12; }
    [[ $http_code =~ ^5[0-9][0-9]$ ]] && return 11

    if [[ $http_code =~ ^2[0-9][0-9]$ ]]; then
        command -v jq >/dev/null 2>&1 || { rootpxe_set_disk_permit_protocol_error "$http_code"; return 12; }
        granted=$(jq -r 'if (.granted | type) == "boolean" then .granted else error("granted must be boolean") end' <<<"$body" 2>/dev/null) || {
            rootpxe_set_disk_permit_protocol_error "$http_code"; return 12
        }
        if [[ $granted == true ]]; then
            echoed_target=$(jq -er '.targetId | strings' <<<"$body" 2>/dev/null) || {
                rootpxe_set_disk_permit_protocol_error "$http_code"; return 12
            }
            echoed_operation=$(jq -er '.operation | strings' <<<"$body" 2>/dev/null) || {
                rootpxe_set_disk_permit_protocol_error "$http_code"; return 12
            }
            if [[ $echoed_target == "$target_id" && $echoed_operation == "$operation" ]]; then
                rootpxe_disk_permit_granted=yes
                rootpxe_disk_permit_target_id="$echoed_target"
                rootpxe_disk_permit_operation="$echoed_operation"
                export rootpxe_disk_permit_granted rootpxe_disk_permit_target_id rootpxe_disk_permit_operation
                return 0
            fi
            rootpxe_set_disk_permit_protocol_error "$http_code"
            return 12
        fi
        rootpxe_set_disk_permit_reason "$body" "$http_code"
        rootpxe_task_status_confirms_disk_permit_cancellation && return 10
        return 12
    fi

    if [[ $http_code =~ ^4[0-9][0-9]$ ]]; then
        rootpxe_set_disk_permit_reason "$body" "$http_code"
        rootpxe_task_status_confirms_disk_permit_cancellation && return 10
        return 12
    fi

    rootpxe_set_disk_permit_protocol_error "$http_code"
    return 12
}

# This path intentionally avoids handleError: its diagnostics include the
# kernel command line, which can carry task credentials in legacy boots.
rootpxe_report_disk_permit_denial() {
    local result report_message status="${rootpxe_disk_permit_http_status:-unknown}"
    printf '\n'
    rootpxe_console_message ERROR "Disk permission denied (HTTP $status)."
    [[ -z ${rootpxe_disk_permit_code:-} ]] || rootpxe_console_message INFO "Server code: $rootpxe_disk_permit_code."
    rootpxe_console_message INFO "Reason: ${rootpxe_disk_permit_console_reason:-Disk permit response is invalid.}"
    if ! rootpxe_require_task_context || [[ -z ${pxeapi:-${web:-}} ]]; then
        rootpxe_console_message WARN 'Cannot report disk permit failure. Retrying in 5s.'
        sleep 5
        return 1
    fi
    report_message="${rootpxe_disk_permit_report_message:-Disk permit response is invalid. Check the server protocol and task binding.} (HTTP ${status}"
    [[ -z ${rootpxe_disk_permit_code:-} ]] || report_message+=", ${rootpxe_disk_permit_code}"
    report_message+=')'
    if rootpxe_error_wait_for_retry "$report_message" PXEOS_DISK_PERMIT_DENIED; then
        result=0
    else
        result=$?
    fi
    [[ $result -eq 2 ]] && return 20
    rootpxe_console_message WARN 'Disk permit failure reporting did not complete. Retrying in 5s.'
    sleep 5
    return 1
}

rootpxe_wait_for_disk_permit() {
    local target_id="${1:-}" operation="${2:-capture_read_write}" result
    while :; do
        if rootpxe_request_disk_permit_for_target "$target_id" "$operation"; then
            result=0
        else
            result=$?
        fi
        case $result in
            0) return 0 ;;
            10) return 10 ;;
            12)
                if rootpxe_report_disk_permit_denial; then
                    result=0
                else
                    result=$?
                fi
                [[ $result -eq 20 ]] && return 20
                ;;
            *)
                printf '%s\n' \
                    '[WARN]  Disk permission not confirmed. Retrying in 5s.' \
                    '[INFO]  SSH is available for troubleshooting.'
                sleep 5
                ;;
        esac
    done
}

# Atomically bind every disk in a multi-disk capture before any path is allowed
# to replay an XFS journal or write capture metadata.  Arguments are alternating
# stable target id and operation; the server response must be the same set.
rootpxe_request_disk_permit_batch() {
    local api response body http_code request granted expected actual binding_file
    local -a items=() ids=() ops=()
    (( $# >= 2 && $# % 2 == 0 && $# <= 128 )) || return 12
    rootpxe_require_task_context || return 11
    command -v jq >/dev/null 2>&1 || return 12
    api="${pxeapi:-${web:-}}"; [[ -n $api ]] || return 11
    while (( $# )); do
        [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ && $2 =~ ^(capture_read_write|deploy_write|nvme_format\+deploy_write)$ ]] || return 12
        ids+=("$1"); ops+=("$2"); items+=("$(jq -cn --arg targetId "$1" --arg operation "$2" '{targetId:$targetId,operation:$operation}')")
        shift 2
    done
    [[ $(printf '%s\n' "${ids[@]}" | sort -u | wc -l) -eq ${#ids[@]} ]] || return 12
    request=$(printf '%s\n' "${items[@]}" | jq -cs .) || return 12
    response=$(curl -Lks --connect-timeout 10 --max-time 30 --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" --data-urlencode "mac=$mac" --data-urlencode "targets=$request" -w $'\n%{http_code}' "${api}disk-permit" 2>/dev/null) || return 11
    http_code=${response##*$'\n'}; body=${response%$'\n'*}
    [[ $http_code =~ ^[0-9]{3}$ ]] || { rootpxe_set_disk_permit_protocol_error unknown; return 12; }
    [[ $http_code =~ ^5[0-9][0-9]$ ]] && return 11
    if [[ $http_code =~ ^2[0-9][0-9]$ ]]; then
        granted=$(jq -er 'if (.granted | type) == "boolean" then .granted else error("granted must be boolean") end' <<<"$body" 2>/dev/null) || { rootpxe_set_disk_permit_protocol_error "$http_code"; return 12; }
        if [[ $granted != true ]]; then
            rootpxe_set_disk_permit_reason "$body" "$http_code"
            rootpxe_task_status_confirms_disk_permit_cancellation && return 10
            return 12
        fi
    elif [[ $http_code =~ ^4[0-9][0-9]$ ]]; then
        rootpxe_set_disk_permit_reason "$body" "$http_code"
        rootpxe_task_status_confirms_disk_permit_cancellation && return 10
        return 12
    else
        rootpxe_set_disk_permit_protocol_error "$http_code"
        return 12
    fi
    expected=$(jq -cS 'sort_by(.targetId,.operation)' <<<"$request") || { rootpxe_set_disk_permit_protocol_error "$http_code"; return 12; }
    actual=$(jq -ceS '[.targets[] | if ((.targetId|type)=="string" and (.operation|type)=="string") then {targetId,operation} else error("target type") end] | sort_by(.targetId,.operation)' <<<"$body" 2>/dev/null) || { rootpxe_set_disk_permit_protocol_error "$http_code"; return 12; }
    [[ $actual == "$expected" ]] || { rootpxe_set_disk_permit_protocol_error "$http_code"; return 12; }
    binding_file=$(mktemp /tmp/rootpxe-disk-permits.XXXXXX) || return 12
    chmod 600 "$binding_file" || { rm -f "$binding_file"; return 12; }
    printf '%s\n' "$actual" >"$binding_file" || { rm -f "$binding_file"; return 12; }
    [[ -z ${rootpxe_disk_permit_bindings_file:-} ]] || rm -f -- "$rootpxe_disk_permit_bindings_file"
    rootpxe_disk_permit_bindings_file="$binding_file"; export rootpxe_disk_permit_bindings_file
    return 0
}

rootpxe_wait_for_disk_permit_batch() {
    local result
    while :; do
        if rootpxe_request_disk_permit_batch "$@"; then
            return 0
        else
            result=$?
        fi
        [[ $result -eq 10 ]] && return 10
        if [[ $result -eq 11 ]]; then
            printf '%s\n' '[WARN]  Disk permission not confirmed. Retrying in 5s.' '[INFO]  SSH is available for troubleshooting.'
            sleep 5
            continue
        fi
        # Batch replies intentionally disclose no per-disk detail.  Reuse the
        # existing bounded error reporter, then retry only after the service
        # has accepted the attention state.
        rootpxe_set_disk_permit_protocol_error batch
        if rootpxe_report_disk_permit_denial; then
            result=0
        else
            result=$?
        fi
        [[ $result -eq 20 ]] && return 20
    done
}

rootpxe_record_disk_permit_binding() {
    local disk="$1" target_id="$2" operation="$3" map_file
    [[ $disk == /dev/* && $target_id =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ && $operation =~ ^(capture_read_write|deploy_write|nvme_format\+deploy_write)$ ]] || return 1
    if [[ -z ${rootpxe_disk_permit_disk_map_file:-} ]]; then
        map_file=$(mktemp /tmp/rootpxe-disk-permit-map.XXXXXX) || return 1
        chmod 600 "$map_file" || { rm -f "$map_file"; return 1; }
        rootpxe_disk_permit_disk_map_file="$map_file"; export rootpxe_disk_permit_disk_map_file
    fi
    [[ -r $rootpxe_disk_permit_disk_map_file ]] || return 1
    awk -F '\t' -v disk="$disk" -v target="$target_id" '($1 == disk || $2 == target) { bad=1 } END { exit bad }' "$rootpxe_disk_permit_disk_map_file" || return 1
    printf '%s\t%s\t%s\n' "$disk" "$target_id" "$operation" >>"$rootpxe_disk_permit_disk_map_file"
}

rootpxe_verify_disk_permit_binding() {
    local disk="$1" operation="$2" target_id map_disk mapped_id mapped_operation
    [[ -r ${rootpxe_disk_permit_disk_map_file:-} ]] || return 1
    IFS=$'\t' read -r map_disk mapped_id mapped_operation < <(awk -F '\t' -v disk="$disk" '$1 == disk { print; exit }' "$rootpxe_disk_permit_disk_map_file") || return 1
    [[ $map_disk == "$disk" && $mapped_id =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || return 1
    target_id=$(rootpxe_disk_stable_identity "$disk") || return 1
    [[ $target_id == "$mapped_id" ]] || return 1
    case "$mapped_operation:$operation" in
        "$operation:$operation"|nvme_format+deploy_write:deploy_write) ;;
        *) return 1 ;;
    esac
    if [[ -r ${rootpxe_disk_permit_bindings_file:-} ]]; then
        jq -e --arg targetId "$mapped_id" --arg operation "$mapped_operation" \
            'any(.[]; .targetId == $targetId and .operation == $operation)' \
            "$rootpxe_disk_permit_bindings_file" >/dev/null 2>&1
    else
        [[ ${rootpxe_disk_permit_granted:-} == yes && ${rootpxe_disk_permit_target_id:-} == "$mapped_id" && ${rootpxe_disk_permit_operation:-} == "$mapped_operation" ]]
    fi
}

rootpxe_activate_disk_permit_binding() {
    local disk="$1" operation="$2" map_disk mapped_id mapped_operation
    rootpxe_verify_disk_permit_binding "$disk" "$operation" || return 1
    IFS=$'\t' read -r map_disk mapped_id mapped_operation < <(awk -F '\t' -v disk="$disk" '$1 == disk { print; exit }' "$rootpxe_disk_permit_disk_map_file") || return 1
    [[ $map_disk == "$disk" ]] || return 1
    rootpxe_disk_permit_granted=yes
    rootpxe_disk_permit_target_id="$mapped_id"
    rootpxe_disk_permit_operation="$mapped_operation"
    export rootpxe_disk_permit_granted rootpxe_disk_permit_target_id rootpxe_disk_permit_operation
}

rootpxe_e2fsck_preflight() {
    local part="$1" output_file="$2" status
    [[ -n $part && -n $output_file ]] || return 16
    e2fsck -fp "$part" >"$output_file" 2>&1
    status=$?
    case $status in
        0)
            return 0
            ;;
        1)
            # A journal replay can legitimately return 1.  Re-run the safe
            # preen check and continue only when the filesystem is clean.
            e2fsck -fp "$part" >>"$output_file" 2>&1
            return $?
            ;;
        *)
            return "$status"
            ;;
    esac
}

# Capture overrides this no-op after the original partition table is saved.
# Keeping the hook here lets shrinkPartition record filesystems that were
# reduced and need expansion without coupling it to the upload entry point.
rootpxe_capture_note_partition_shrunk() {
    :
}

rootpxe_error_response_reason() {
    local response="$1" reason
    reason=$(printf '%s' "$response" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    reason=$(printf '%s' "$reason" | tr -cd '[:print:] ' | cut -c1-160)
    printf '%s' "$reason"
}

rootpxe_error_wait_for_retry() {
    local message code="${2:-PXEOS_ERROR}" api="${pxeapi:-$web}" response raw_response http_status response_reason wait action deadline now status stage="" stage_count=0 stage_invalid=0 stage_match stage_remainder stage_value
    local -a error_args
    rootpxe_require_task_context || return 1
    [[ -n $api ]] || return 1
    message=$(rootpxe_bound_callback_message "$1") || return 1
    # Only resume-safe stages may be persisted independently of the diagnostic
    # message. A malformed, repeated, or arbitrary marker is intentionally not
    # sent, so the service cannot resume a disk-writing phase by inference.
    stage_remainder="$message"
    while [[ $stage_remainder =~ (^|[[:space:]])PXEOS_STAGE=([^[:space:]]+) ]]; do
        stage_match="${BASH_REMATCH[0]}"
        stage_value="${BASH_REMATCH[2]}"
        case $stage_value in
            customizing_hostname|post_deploy_script)
                stage_count=$((stage_count + 1))
                stage="$stage_value"
                ;;
            *) stage_invalid=1 ;;
        esac
        stage_remainder=${stage_remainder#*"$stage_match"}
    done
    error_args=(
        --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token"
        --data-urlencode "mac=$mac" --data-urlencode "errorCode=$code"
        --data-urlencode "message=$message"
    )
    [[ $stage_count -eq 1 && $stage_invalid -eq 0 ]] && error_args+=(--data-urlencode "stage=$stage")
    # Do not arm the local timeout until the service confirms persistence.
    while :; do
        raw_response=$(curl -Lks --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
            "${error_args[@]}" "${api}error" 2>/dev/null) || {
                printf '%s\n' \
                    "[WARN]  Error report failed. Retrying in 5s." \
                    "[INFO]  SSH is available for troubleshooting."
                sleep 5
                continue
            }
        http_status=${raw_response##*$'\n'}
        response=${raw_response%$'\n'*}
        [[ $http_status =~ ^[0-9]{3}$ ]] || { http_status=000; response=$raw_response; }
        [[ $http_status =~ ^2 && $response == *'"accepted":true'* ]] && break
        response_reason=$(rootpxe_error_response_reason "$response")
        if [[ -n $response_reason ]]; then
            printf '%s\n' \
                "[WARN]  Error report rejected (HTTP $http_status): $response_reason. Retrying in 5s." \
                "[INFO]  SSH is available for troubleshooting."
        else
            printf '%s\n' \
                "[WARN]  Error report not confirmed (HTTP $http_status). Retrying in 5s." \
                "[INFO]  SSH is available for troubleshooting."
        fi
        sleep 5
    done
    wait=$(printf '%s' "$response" | sed -n 's/.*"waitSec":\([0-9][0-9]*\).*/\1/p')
    action=$(printf '%s' "$response" | sed -n 's/.*"failureAction":"\([a-z]*\)".*/\1/p')
    [[ $wait =~ ^[0-9]+$ && $wait -ge 60 && $wait -le 3600 ]] || wait=600
    [[ $action == shutdown ]] || action=reboot
    printf '%s\n' "$action" > /tmp/pxeos.failure_action
    deadline=$(( $(date +%s) + wait ))
    rootpxe_console_message ERROR 'Task paused. Error reported to RootPXE.'
    rootpxe_console_message INFO 'SSH is available for troubleshooting.'
    rootpxe_console_message INFO 'Select Retry in the web UI to resume.'
    rootpxe_console_message INFO "Timeout: ${wait}s. Timeout action: $action."
    while :; do
        now=$(date +%s)
        if [[ $now -ge $deadline ]]; then
            rootpxe_console_message WARN "Wait timed out. Timeout action: $action."
            return 2
        fi
        status=$(curl -Lks --connect-timeout 10 --max-time 20 \
            --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" \
            --data-urlencode "mac=$mac" "${api}task-status" 2>/dev/null)
        if [[ $status == *'"status":"queued"'* ]]; then
            rootpxe_console_message INFO 'Retry requested. Resuming task.'
            exec /bin/pxeos
        fi
        if [[ $status == *'"status":"deleted"'* || $status == *'"status":"cancelled"'* || $status == *'"status":"superseded"'* ]]; then
            rootpxe_console_message INFO 'Task deleted or aborted. Stopping PXEOS.'
            return 2
        fi
        sleep 5
    done
}

rootpxe_directory_size_bytes() {
    local root="$1"
    local total=0 bytes sizes
    sizes=$(find "$root" -type f ! -name '.rootpxe-capture-taskid' -exec stat -c %s {} +) || return 1
    [[ -z $sizes ]] && { echo 0; return 0; }
    while IFS= read -r bytes; do
        [[ $bytes =~ ^[0-9]+$ ]] || return 1
        total=$((total + bytes))
    done <<< "$sizes"
    echo "$total"
}

rootpxe_capture_finalize_fail() {
    rootpxe_finalize_capture_error_code=CAPTURE_FINALIZE_FAILED
    rootpxe_finalize_capture_error_reason="$1"
    return 1
}

rootpxe_capture_marker_matches_task() {
    local marker="$1" expected_taskid="$2"
    [[ -f $marker && ! -L $marker && $(cat "$marker") == "$expected_taskid" ]]
}

rootpxe_capture_finalize_lock_path() {
    local target="$1" parent base
    parent=$(dirname "$target") || return 1
    base=$(basename "$target") || return 1
    [[ -n $parent && -n $base ]] || return 1
    printf '%s/.%s.rootpxe-finalize.lock\n' "$parent" "$base"
}

rootpxe_capture_paths_same_device() {
    local source="$1" target_parent="$2" target="$3" source_dev parent_dev target_dev
    source_dev=$(stat -c %d "$source" 2>/dev/null) || return 1
    parent_dev=$(stat -c %d "$target_parent" 2>/dev/null) || return 1
    [[ $source_dev =~ ^[0-9]+$ && $parent_dev =~ ^[0-9]+$ && $source_dev == "$parent_dev" ]] || return 1
    if [[ -e $target ]]; then
        target_dev=$(stat -c %d "$target" 2>/dev/null) || return 1
        [[ $target_dev =~ ^[0-9]+$ && $target_dev == "$source_dev" ]] || return 1
    fi
}

rootpxe_validate_capture_backup_name() {
    local name="$1" byte_count
    [[ -n $name && $name != . && $name != .. && $name != .* ]] || return 1
    [[ $name != */* && $name != *\\* && $name != *[[:cntrl:]]* ]] || return 1
    byte_count=$(LC_ALL=C printf '%s' "$name" | wc -c) || return 1
    [[ $byte_count =~ ^[1-9][0-9]*$ && $byte_count -le 255 ]]
}

rootpxe_capture_paths_overlap() {
    local first="$1" second="$2"
    [[ $first == "$second" || $first == "$second"/* || $second == "$first"/* ]]
}

rootpxe_capture_set_final_path() {
    local target="$1" marker size
    marker="$target/.rootpxe-capture-taskid"
    rootpxe_capture_marker_matches_task "$marker" "$taskid" || return 1
    size=$(rootpxe_directory_size_bytes "$target") || return 1
    [[ $size =~ ^[1-9][0-9]*$ ]] || return 1
    capture_size_bytes="$size"
    rootpxe_final_capture_path="$target"
    export capture_size_bytes rootpxe_final_capture_path
}



rootpxe_finalize_capture() {
    [[ ${type:-} == "up" ]] || return 0
    rootpxe_finalize_capture_error_code=CAPTURE_FINALIZE_FAILED
    rootpxe_finalize_capture_error_reason=unsafe_finalize_state
    rootpxe_require_task_context || { rootpxe_capture_finalize_fail invalid_task_context; return 1; }
    local storage_root="/storage" backup_root="/storage/backup" source="/storage/dev/$macWinSafe" relative target target_parent source_parent lock backup target_marker source_marker source_dev backup_dev
    relative=$(rootpxe_safe_relative_path "${img:-}") || { rootpxe_capture_finalize_fail unsafe_target_path; return 1; }
    target=$(rootpxe_storage_path "$relative") || { rootpxe_capture_finalize_fail unsafe_target_path; return 1; }
    target_parent=$(dirname "$target") || { rootpxe_capture_finalize_fail unsafe_target_path; return 1; }
    source_parent=$(dirname "$source") || { rootpxe_capture_finalize_fail unsafe_source_path; return 1; }
    [[ -d $storage_root && ! -L $storage_root && -d $backup_root && ! -L $backup_root && -d $source_parent && ! -L $source_parent && ! -L $source ]] || { rootpxe_capture_finalize_fail unsafe_source_path; return 1; }
    rootpxe_capture_paths_overlap "$source" "$target" && { rootpxe_capture_finalize_fail source_target_overlap; return 1; }
    [[ ! -e $target || -d $target ]] || { rootpxe_capture_finalize_fail target_not_directory; return 1; }
    mkdir -p "$target_parent" || { rootpxe_capture_finalize_fail target_parent_unavailable; return 1; }
    [[ -d $target_parent && ! -L $target_parent ]] || { rootpxe_capture_finalize_fail unsafe_target_path; return 1; }
    [[ $(rootpxe_storage_path "$relative") == "$target" && ! -L $target ]] || { rootpxe_capture_finalize_fail unsafe_target_path; return 1; }
    # An already-published retry has no source tree left to rename.  Device
    # identity is required only before a capture source can be moved.
    if [[ -d $source ]]; then
        rootpxe_capture_paths_same_device "$source" "$target_parent" "$target" || { rootpxe_capture_finalize_fail cross_device_capture_paths; return 1; }
        source_dev=$(stat -c %d "$source" 2>/dev/null) || { rootpxe_capture_finalize_fail cross_device_capture_paths; return 1; }
        backup_dev=$(stat -c %d "$backup_root" 2>/dev/null) || { rootpxe_capture_finalize_fail cross_device_capture_paths; return 1; }
        [[ $source_dev =~ ^[0-9]+$ && $backup_dev =~ ^[0-9]+$ && $source_dev == "$backup_dev" ]] || { rootpxe_capture_finalize_fail cross_device_capture_paths; return 1; }
    fi
    lock=$(rootpxe_capture_finalize_lock_path "$target") || { rootpxe_capture_finalize_fail unsafe_target_path; return 1; }
    mkdir "$lock" 2>/dev/null || { rootpxe_capture_finalize_fail finalize_lock_unavailable; return 1; }

    target_marker="$target/.rootpxe-capture-taskid"
    source_marker="$source/.rootpxe-capture-taskid"
    if [[ -d $source && -d $target ]]; then
        rootpxe_capture_marker_matches_task "$source_marker" "$taskid" || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail source_marker_invalid; return 1; }
        capture_size_bytes=$(rootpxe_directory_size_bytes "$source") || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail source_payload_invalid; return 1; }
        [[ $capture_size_bytes =~ ^[1-9][0-9]*$ ]] || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail source_payload_invalid; return 1; }
        [[ ! -e $target_marker && ! -L $target_marker ]] || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail target_marker_present; return 1; }
        rootpxe_validate_capture_backup_name "${captureBackupName:-}" || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail invalid_backup_name; return 1; }
        backup="$backup_root/$captureBackupName"
        [[ ! -e $backup && ! -L $backup ]] || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail backup_already_exists; return 1; }
        if ! mv -T "$target" "$backup"; then
            rmdir "$lock" >/dev/null 2>&1 || true
            rootpxe_capture_finalize_fail backup_move_failed
            return 1
        fi
        if ! mv -T "$source" "$target"; then
            if mv -T "$backup" "$target"; then
                rmdir "$lock" >/dev/null 2>&1 || true
                rootpxe_capture_finalize_fail publish_failed_rolled_back
            else
                rmdir "$lock" >/dev/null 2>&1 || true
                rootpxe_capture_finalize_fail publish_and_rollback_failed
            fi
            return 1
        fi
    elif [[ ! -e $source && ! -L $source && -d $target ]]; then
        rootpxe_capture_set_final_path "$target" || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail published_target_invalid; return 1; }
    elif [[ -d $source && ! -e $target && ! -L $target ]]; then
        rootpxe_capture_marker_matches_task "$source_marker" "$taskid" || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail source_marker_invalid; return 1; }
        capture_size_bytes=$(rootpxe_directory_size_bytes "$source") || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail source_payload_invalid; return 1; }
        [[ $capture_size_bytes =~ ^[1-9][0-9]*$ ]] || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail source_payload_invalid; return 1; }
        if [[ -n ${captureBackupName:-} ]]; then
            rootpxe_validate_capture_backup_name "$captureBackupName" || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail invalid_backup_name; return 1; }
            backup="$backup_root/$captureBackupName"
            [[ ! -e $backup && ! -L $backup ]] || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail backup_already_exists; return 1; }
        fi
        if ! mv -T "$source" "$target"; then
            rmdir "$lock" >/dev/null 2>&1 || true
            rootpxe_capture_finalize_fail publish_failed_source_retained
            return 1
        fi
    else
        rmdir "$lock" >/dev/null 2>&1 || true
        rootpxe_capture_finalize_fail capture_path_state_invalid
        return 1
    fi
    rootpxe_capture_set_final_path "$target" || { rmdir "$lock" >/dev/null 2>&1 || true; rootpxe_capture_finalize_fail published_target_invalid; return 1; }
    rmdir "$lock" 2>/dev/null || { rootpxe_capture_finalize_fail finalize_lock_release_failed; return 1; }
}

rootpxe_clear_capture_marker() {
    [[ ${type:-} == "up" && -n ${img:-} ]] || return 0
    rootpxe_capture_marker_clear_error_reason=invalid_task_context
    rootpxe_require_task_context || return 1
    local storage_root="/storage" relative target target_parent marker lock
    relative=$(rootpxe_safe_relative_path "$img") || { rootpxe_capture_marker_clear_error_reason=unsafe_target_path; return 1; }
    target=$(rootpxe_storage_path "$relative") || { rootpxe_capture_marker_clear_error_reason=unsafe_target_path; return 1; }
    target_parent=$(dirname "$target") || { rootpxe_capture_marker_clear_error_reason=unsafe_target_path; return 1; }
    [[ -d $storage_root && ! -L $storage_root && -d $target_parent && ! -L $target_parent && -d $target && ! -L $target ]] || { rootpxe_capture_marker_clear_error_reason=unsafe_target_path; return 1; }
    lock=$(rootpxe_capture_finalize_lock_path "$target") || { rootpxe_capture_marker_clear_error_reason=unsafe_target_path; return 1; }
    mkdir "$lock" 2>/dev/null || { rootpxe_capture_marker_clear_error_reason=finalize_lock_unavailable; return 1; }
    marker="$target/.rootpxe-capture-taskid"
    if ! rootpxe_capture_marker_matches_task "$marker" "$taskid"; then
        rmdir "$lock" >/dev/null 2>&1 || true
        rootpxe_capture_marker_clear_error_reason=marker_not_owned
        return 1
    fi
    if ! rm -f -- "$marker"; then
        rmdir "$lock" >/dev/null 2>&1 || true
        rootpxe_capture_marker_clear_error_reason=marker_remove_failed
        return 1
    fi
    rmdir "$lock" 2>/dev/null || { rootpxe_capture_marker_clear_error_reason=finalize_lock_release_failed; return 1; }
}
# RootPXE 任务阶段上报（无 taskid 或未设置 web/pxeapi 时静默跳过）
rootpxe_stage() {
    local st="$1"
    local msg="${2:-}"
    rootpxe_require_task_context || return 1
    local api="${pxeapi:-$web}"
    [[ -z $api ]] && return 0
    curl -Lks --max-time 20 \
        --data-urlencode "taskid=$taskid" \
        --data-urlencode "token=$task_token" \
        --data-urlencode "mac=$mac" \
        --data-urlencode "stage=$st" \
        --data-urlencode "status=running" \
        --data-urlencode "message=$msg" \
        "${api}stage" >/dev/null 2>&1 || true
}

# NVMe sector-size alignment is deliberately fail-closed.  The server must
# inject these values only after its disk-permit decision; they must never be
# logged or accepted from an unauthenticated source:
#   rootpxe_disk_permit_granted=yes
#   rootpxe_disk_permit_target_id=<ID_WWN or ID_SERIAL>
#   rootpxe_disk_permit_operation=nvme_format+deploy_write
rootpxe_disk_stable_identity() {
    local LC_ALL=C
    local disk="$1" properties line="" property hash
    property=$(udevadm info --query=property --name="$disk" 2>/dev/null) || return 1
    properties="$property"
    property=""
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            ID_WWN=*|ID_SERIAL=*)
                property="${line#*=}"
                [[ $property == *[^[:space:]]* ]] && break
                property=""
                ;;
        esac
    done <<<"$properties"
    [[ -n $property ]] || return 1
    if [[ $property =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ && $property != sha256:* ]]; then
        printf '%s\n' "$property"
        return 0
    fi
    hash=$(printf '%s' "$property" | sha256sum 2>/dev/null) || return 1
    hash=${hash%%[[:space:]]*}
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'sha256:%s\n' "$hash"
}

rootpxe_nvme_permit_matches() {
    local stable_id="$1"
    [[ ${rootpxe_disk_permit_granted:-} == yes ]] || return 1
    [[ ${rootpxe_disk_permit_target_id:-} == "$stable_id" ]] || return 1
    [[ ${rootpxe_disk_permit_operation:-} == nvme_format+deploy_write ]] || return 1
}

rootpxe_nvme_find_metadata_free_lbaf() {
    local disk="$1" wanted_sector_size="$2"
    nvme id-ns "$disk" 2>/dev/null | awk -v wanted="$wanted_sector_size" '
        match($0, /lbaf[[:space:]]+([0-9]+)[[:space:]]*:[[:space:]]*ms:([0-9]+)[[:space:]]+lbads:([0-9]+)/, fields) {
            bytes = 1
            for (i = 0; i < fields[3]; i++) bytes *= 2
            if (fields[2] == 0 && bytes == wanted) { print fields[1]; exit }
        }'
}

rootpxe_nvme_wait_for_cancel() {
    local seconds="${PXEOS_NVME_FORMAT_COUNTDOWN_SEC:-60}" reply="" remaining
    [[ $seconds =~ ^[0-9]+$ && $seconds -le 60 ]] || seconds=60
    rootpxe_console_message WARN "NVMe logical-sector alignment will erase the namespace in ${seconds}s; press c to cancel."
    for ((remaining=seconds; remaining>0; remaining--)); do
        if read -r -t 1 -n 1 reply; then
            case $reply in
                [Cc]) rootpxe_stage nvme_format_cancelled 'code=NVME_FORMAT_CANCELLED reason=operator_cancelled' || true ; return 1 ;;
            esac
        fi
    done
    return 0
}

rootpxe_nvme_wait_for_reenumeration() {
    local expected_id="$1" wanted_sector_size="$2" disk candidate actual_id actual_sector
    local timeout="${PXEOS_NVME_REENUM_TIMEOUT_SEC:-30}" elapsed=0
    [[ $timeout =~ ^[0-9]+$ && $timeout -le 120 ]] || timeout=30
    udevadm settle --timeout="$timeout" >/dev/null 2>&1 || true
    while (( elapsed <= timeout )); do
        for candidate in ${PXEOS_NVME_REENUM_DEVICE:-/dev/nvme*n*}; do
            [[ -b $candidate || -n ${PXEOS_NVME_REENUM_DEVICE:-} ]] || continue
            actual_id=$(rootpxe_disk_stable_identity "$candidate") || continue
            [[ $actual_id == "$expected_id" ]] || continue
            actual_sector=$(blockdev --getss "$candidate" 2>/dev/null) || continue
            [[ $actual_sector == "$wanted_sector_size" ]] || return 2
            rootpxe_nvme_reformatted_disk="$candidate"
            return 0
        done
        if (( elapsed == timeout )); then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

rootpxe_nvme_reformat_to_sector_size() {
    local disk="$1" wanted_sector_size="$2" expected_id="$3" stable_id lbaf wait_result source_sector
    [[ $(basename "$disk") =~ ^nvme[0-9]+n[0-9]+$ ]] || return 1
    [[ $wanted_sector_size =~ ^[0-9]+$ && $wanted_sector_size -gt 0 ]] || return 1
    stable_id=$(rootpxe_disk_stable_identity "$disk") || return 1
    [[ $stable_id == "$expected_id" ]] || return 1
    rootpxe_nvme_permit_matches "$stable_id" || return 1
    lbaf=$(rootpxe_nvme_find_metadata_free_lbaf "$disk" "$wanted_sector_size")
    [[ $lbaf =~ ^[0-9]+$ ]] || return 1
    rootpxe_nvme_wait_for_cancel || return 1
    source_sector=$(blockdev --getss "$disk" 2>/dev/null) || return 1
    rootpxe_stage nvme_formatting "code=NVME_FORMAT_STARTED source_sector=$source_sector target_sector=$wanted_sector_size target_id=$stable_id lbaf=$lbaf" || true
    # From this command onward a disk operation has started and safe abort is no longer possible.
    nvme format "$disk" --lbaf="$lbaf" --force >/dev/null 2>&1 || {
        rootpxe_stage nvme_format_failed "code=NVME_FORMAT_FAILED reason=format_command_failed source_sector=$source_sector target_sector=$wanted_sector_size target_id=$stable_id lbaf=$lbaf" || true
        return 1
    }
    rootpxe_nvme_wait_for_reenumeration "$stable_id" "$wanted_sector_size"
    wait_result=$?
    case $wait_result in
        0) rootpxe_stage nvme_format_complete "code=NVME_FORMAT_COMPLETE source_sector=$source_sector target_sector=$wanted_sector_size target_id=$stable_id lbaf=$lbaf" || true ; return 0 ;;
        2) rootpxe_stage nvme_format_failed "code=NVME_FORMAT_VERIFY_FAILED reason=logical_sector_mismatch source_sector=$source_sector target_sector=$wanted_sector_size target_id=$stable_id lbaf=$lbaf" || true ; return 1 ;;
        *) rootpxe_stage nvme_format_failed "code=NVME_FORMAT_REENUM_FAILED reason=device_not_reidentified source_sector=$source_sector target_sector=$wanted_sector_size target_id=$stable_id lbaf=$lbaf" || true ; return 1 ;;
    esac
}

rootpxe_plan_deploy_disk_operation() {
    local disk="$1" partition_file="$2" image_sector target_sector target_id candidate_lbaf
    target_id=$(rootpxe_disk_stable_identity "$disk") || return 1
    rootpxe_planned_disk_operation=deploy_write
    if [[ -r $partition_file ]]; then
        image_sector=$(awk '/^sector-size:/{print $2; exit}' "$partition_file")
        target_sector=$(blockdev --getss "$disk" 2>/dev/null) || return 1
        if [[ -n $image_sector && $image_sector != "$target_sector" ]]; then
            # Never wait for permit while a sector mismatch is already known
            # to be impossible to resolve.  NVMe must expose a matching
            # metadata-free LBAF before its destructive permit is requested.
            [[ $(basename "$disk") =~ ^nvme[0-9]+n[0-9]+$ ]] || return 1
            candidate_lbaf=$(rootpxe_nvme_find_metadata_free_lbaf "$disk" "$image_sector")
            [[ $candidate_lbaf =~ ^[0-9]+$ ]] || return 1
            rootpxe_planned_disk_operation=nvme_format+deploy_write
        fi
    fi
    rootpxe_planned_target_id="$target_id"
    export rootpxe_planned_disk_operation rootpxe_planned_target_id
}

# Build the exact ordered permit set for an mpa deployment.  The image facts
# are authoritative for disk number and bytes; getHardDisk has already used
# those bytes to choose $disks in the same order.  This function performs no
# write and may therefore run before the atomic permit request.
rootpxe_plan_mpa_disk_permits() {
    local image_path="$1" facts number bytes disk index=0 planned_id planned_operation
    local -a image_numbers=() image_bytes=() target_disks=() target_ids=() target_operations=()
    [[ ${imgType:-} == mpa && ${type:-} == down && -n ${disks:-} ]] || return 1
    facts=$(rootpxe_fixed_restore_disk_facts "$image_path") || return 1
    while IFS='|' read -r number bytes; do
        [[ $number =~ ^[1-9][0-9]*$ && $bytes =~ ^[1-9][0-9]*$ && -s $image_path/d${number}.partitions && -s $image_path/d${number}.mbr ]] || return 1
        image_numbers+=("$number"); image_bytes+=("$bytes")
    done <<<"$facts"
    for disk in $disks; do target_disks+=("$disk"); done
    (( ${#image_numbers[@]} == ${#target_disks[@]} && ${#image_numbers[@]} > 0 )) || return 1
    for index in "${!target_disks[@]}"; do
        disk=${target_disks[$index]}
        [[ $(blockdev --getsize64 "$disk" 2>/dev/null) == "${image_bytes[$index]}" ]] || return 1
        rootpxe_plan_deploy_disk_operation "$disk" "$image_path/d${image_numbers[$index]}.partitions" || return 1
        planned_id=$rootpxe_planned_target_id; planned_operation=$rootpxe_planned_disk_operation
        target_ids+=("$planned_id"); target_operations+=("$planned_operation")
    done
    rootpxe_mpa_permit_args=()
    if (( ${#target_disks[@]} == 1 )); then
        rootpxe_mpa_permit_is_batch=no
        rootpxe_planned_target_id=${target_ids[0]}
        rootpxe_planned_disk_operation=${target_operations[0]}
        export rootpxe_mpa_permit_is_batch rootpxe_planned_target_id rootpxe_planned_disk_operation
        return 0
    fi
    [[ -z ${rootpxe_disk_permit_disk_map_file:-} ]] || rm -f -- "$rootpxe_disk_permit_disk_map_file"
    unset rootpxe_disk_permit_disk_map_file
    rootpxe_clear_disk_permit
    for index in "${!target_disks[@]}"; do
        rootpxe_record_disk_permit_binding "${target_disks[$index]}" "${target_ids[$index]}" "${target_operations[$index]}" || return 1
        rootpxe_mpa_permit_args+=("${target_ids[$index]}" "${target_operations[$index]}")
    done
    rootpxe_mpa_permit_is_batch=yes
    export rootpxe_mpa_permit_is_batch
    return 0
}

# Validate before clearPartitionTables or any other write.  On a matching NVMe
# LBA format, the externally authorised reformat path may make the disk safe.
validateImageSectorSize() {
    local disk="$1" partition_file="$2" image_sector target_sector
    [[ -r $partition_file ]] || return 0
    image_sector=$(awk '/^sector-size:/{print $2; exit}' "$partition_file")
    [[ -z $image_sector ]] && return 0
    target_sector=$(blockdev --getss "$disk" 2>/dev/null) || handleError "PXEOS_STAGE=sector_validation CODE=TARGET_SECTOR_QUERY_FAILED REASON=unable_to_read_target_sector"
    [[ $image_sector == "$target_sector" ]] && return 0
    rootpxe_nvme_reformat_to_sector_size "$disk" "$image_sector" "${rootpxe_disk_permit_target_id:-}" && return 0
    handleError "PXEOS_STAGE=sector_validation CODE=LOGICAL_SECTOR_MISMATCH REASON=image_${image_sector}_target_${target_sector}"
}
# Below Are non parameterized functions
# These functions will run without any arguments
#
# Clears thes creen unless its a debug task
clearScreen() {
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            clear
            ;;
    esac
}
# Displays the nice banner along with the running version
displayBanner() {
    # 动态获取版本号（RootPXE: /service/pxeos/health）
    version=$(curl -Lks "${pxeapi:-$web}health" 2>/dev/null | sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p')
    [[ -z $version ]] && version=$(curl -Lks "${pxeapi:-$web}health" 2>/dev/null)

    cat << 'EOF'
   ========================================================
   ===                                                  ===
   ===  ██████╗  ██╗  ██╗ ███████╗  ██████╗  ███████╗   ===
   ===  ██╔══██╗ ╚██╗██╔╝ ██╔════╝ ██╔═══██╗ ██╔════╝   ===
   ===  ██████╔╝  ╚███╔╝  █████╗   ██║   ██║ ███████╗   ===
   ===  ██╔═══╝   ██╔██╗  ██╔══╝   ██║   ██║ ╚════██║   ===
   ===  ██║      ██╔╝ ██╗ ███████╗ ╚██████╔╝ ███████║   ===
   ===  ╚═╝      ╚═╝  ╚═╝ ╚══════╝  ╚═════╝  ╚══════╝   ===
   ===                                                  ===
   ==================== PXEOS Runtime =====================
   ========================================================
EOF

    rootpxe_console_message INFO "Version: $version"
    rootpxe_console_message INFO "Init version: $initversion"
    printf '\n'
}
# Gets all system mac addresses except for loopback
#getMACAddresses() {
#    read ifaces <<< $(/usr/sbin/lshw -c network -json | jq -s '.[] | .logicalname' | tr -d '"' | tr '[:space:]' '|' | sed 's/[|]$//g')
#    read mac_addresses <<< $(/usr/sbin/lshw -c network -json | jq -s '.[] | .serial' | tr -d '"' | tr '[:space:]' '|' | sed 's/[|]$//g')
#    echo $mac_addresses
#}
# Gets all system mac addresses except for loopback
getMACAddresses() {
    read ifaces <<< $(/sbin/ip -4 -o addr | awk -F'([ /])+' '/global/ {print $2}' | tr '[:space:]' '|' | sed -e 's/^[|]//g' -e 's/[|]$//g')
    read mac_addresses <<< $(/sbin/ip -0 addr | awk 'ORS=NR%2?FS:RS' | awk "/$ifaces/ {print \$11}" | tr '[:space:]' '|' | sed -e 's/^[|]//g' -e 's/[|]$//g')
    echo $mac_addresses
}
# Gets all macs and types.
getMACTypes() {
    read macandtypes <<< $(/usr/sbin/lshw -c network -json | jq -s '.[] | .serial + " " + .handle' | tr -d '"' | tr '\n' '|' | sed 's/[|]$//g')
    echo $macandtypes
}
# Verifies that there is a network interface
verifyNetworkConnection() {
    dots "Verifying network interface configuration"
    local count=$(/sbin/ip addr | awk -F'[ /]+' '/global/{print $3}' | wc -l)
    if [[ -z $count || $count -lt 1 ]]; then
        echo "Failed"
        debugPause
        handleError "No network interfaces found (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
    echo "Done"
    debugPause
}
# Verifies that the OS is valid for resizing
validResizeOS() {
    [[ $osid != @([1-2]|4|[5-7]|9|10|11|50|51) ]] && handleError "Invalid operating system ID: $osname ($osid) (${FUNCNAME[0]})\n   Args Passed: $*"
}
# Gets the graphics information from the system
getGraphics() {
    local graphics_info=$(lshw -json -C display | jq -r '.[] | select(.vendor != null) | "\(.vendor),\(.product)"')

    graphics_vendors_array=()
    graphics_products_array=()
    while IFS=',' read -r vendor product; do
        graphics_vendors_array+=("$vendor")
        graphics_products_array+=("$product")
    done <<< "$graphics_info"

    inventory_graphics_vendor=$(IFS=,; echo "${graphics_vendors_array[*]}")
    inventory_graphics_product=$(IFS=,; echo "${graphics_products_array[*]}")

    inventory_graphics_vendor64=$(echo "$inventory_graphics_vendor" | base64)
    inventory_graphics_product64=$(echo "$inventory_graphics_product" | base64)
}
# Gets the information from the system for inventory
doInventory() {
    getGraphics
    sysman=$(dmidecode -s system-manufacturer)
    sysproduct=$(dmidecode -s system-product-name)
    sysversion=$(dmidecode -s system-version)
    sysserial=$(dmidecode -s system-serial-number)
    sysuuid=$(dmidecode -s system-uuid)
    sysuuid=${sysuuid,,}
    systype=$(dmidecode -t 3 | grep Type:)
    biosversion=$(dmidecode -s bios-version)
    biosvendor=$(dmidecode -s bios-vendor)
    biosdate=$(dmidecode -s bios-release-date)
    mbman=$(dmidecode -s baseboard-manufacturer)
    mbproductname=$(dmidecode -s baseboard-product-name)
    mbversion=$(dmidecode -s baseboard-version)
    mbserial=$(dmidecode -s baseboard-serial-number)
    mbasset=$(dmidecode -s baseboard-asset-tag)
    cpuman=$(dmidecode -s processor-manufacturer)
    cpuversion=$(dmidecode -s processor-version)
    cpucurrent=$(dmidecode -t 4 | grep 'Current Speed:' | head -n1)
    cpumax=$(dmidecode -t 4 | grep 'Max Speed:' | head -n1)
    mem=$(cat /proc/meminfo | grep MemTotal | tr -d \\0)
    hdinfo=$(hdparm -i $hd 2>/dev/null | grep Model= || smartctl -i $hd | grep -A2 "Model Number" | awk -F ":" '/Model Number:/{gsub(/ /,""); modelno=$NF};/Serial Number:/{gsub(/ /,""); serialno=$NF};/Firmware Version:/{gsub(/ /,""); fwrev=$NF; print "model="modelno", fwrev="fwrev", serialno="serialno}')
    caseman=$(dmidecode -s chassis-manufacturer)
    casever=$(dmidecode -s chassis-version)
    caseserial=$(dmidecode -s chassis-serial-number)
    caseasset=$(dmidecode -s chassis-asset-tag)
    sysman64=$(echo $sysman | base64)
    sysproduct64=$(echo $sysproduct | base64)
    sysversion64=$(echo $sysversion | base64)
    sysserial64=$(echo $sysserial | base64)
    sysuuid64=$(echo $sysuuid | base64)
    systype64=$(echo $systype | base64)
    biosversion64=$(echo $biosversion | base64)
    biosvendor64=$(echo $biosvendor | base64)
    biosdate64=$(echo $biosdate | base64)
    mbman64=$(echo $mbman | base64)
    mbproductname64=$(echo $mbproductname | base64)
    mbversion64=$(echo $mbversion | base64)
    mbserial64=$(echo $mbserial | base64)
    mbasset64=$(echo $mbasset | base64)
    cpuman64=$(echo $cpuman | base64)
    cpuversion64=$(echo $cpuversion | base64)
    cpucurrent64=$(echo $cpucurrent | base64)
    cpumax64=$(echo $cpumax | base64)
    mem64=$(echo $mem | base64)
    hdinfo64=$(echo $hdinfo | base64)
    caseman64=$(echo $caseman | base64)
    casever64=$(echo $casever | base64)
    caseserial64=$(echo $caseserial | base64)
    caseasset64=$(echo $caseasset | base64)
}
# Gets the location of the SAM registry if found
getSAMLoc() {
    local path=""
    local paths="/ntfs/WINDOWS/system32/config/SAM /ntfs/Windows/System32/config/SAM"
    for path in $paths; do
        [[ ! -f $path ]] && continue
        sam="$path" && break
    done
}
# Prints a completed task-console line with a fixed level/body boundary.
# Messages are wrapped before 80 columns.  Only callers decide which values
# are safe to render.
rootpxe_console_message() {
    local level="$1" message="${2-}" line chunk
    case $level in
        INFO|WARN|ERROR) ;;
        *) return 1 ;;
    esac
    while IFS= read -r line || [[ -n $line ]]; do
        while (( ${#line} > 72 )); do
            chunk=${line:0:72}
            printf '%-7s %s\n' "[$level]" "$chunk"
            line=${line:72}
        done
        printf '%-7s %s\n' "[$level]" "$line"
    done <<<"$message"
}

# Prints a levelled interactive prompt without a trailing newline so callers
# can immediately read user input while keeping the console column aligned.
rootpxe_console_prompt() {
    local level="$1" message="${2-}"
    case $level in
        INFO|WARN|ERROR) ;;
        *) return 1 ;;
    esac
    printf '%-7s %s' "[$level]" "$message"
}

# Appends dots to a progress message while preserving its caller's inline
# result contract (for example, `dots ...; echo Done`).  The last segment uses
# a shorter fixed body width so the usual result text remains within 80 columns.
#
# $1 Progress message
dots() {
    local str="$*" chunk pad body_width=64
    [[ -z $str ]] && handleError "No string passed (${FUNCNAME[0]})\n   Args Passed: $*"
    while (( ${#str} > body_width )); do
        chunk=${str:0:body_width}
        printf '%-7s %s\n' '[INFO]' "$chunk"
        str=${str:body_width}
    done
    pad=$(printf '%0.1s' "."{1..64})
    printf '%-7s %s%*.*s' '[INFO]' "$str" 0 "$((body_width-${#str}))" "$pad"
}
# Enables write caching on the disk passed
# If the disk does not support write caching this does nothing
#
# $1 is the drive
enableWriteCache()  {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    wcache=$(hdparm -W $disk 2>/dev/null | tr -d '[[:space:]]' | awk -F= '/.*write-caching=/{print $2}')
    if [[ -z $wcache || $wcache == notsupported ]]; then
        rootpxe_console_message WARN 'Write caching is not supported.'
        debugPause
        return
    fi
    dots "Enabling write cache"
    hdparm -W1 $disk >/dev/null 2>&1
    case $? in
        0)
            echo "Enabled"
            ;;
        *)
            echo "Failed"
            debugPause
            handleWarning "Could not set caching status (${FUNCNAME[0]})"
            return
            ;;
    esac
    debugPause
}
# Accept only the exact dosfstools 4.2 dirty-bit-only diagnostic observed on
# PXEOS.  Exit status 1 alone is not sufficient: it also represents other
# recoverable errors and internal inconsistencies.  LC_ALL=C makes this
# parser stable; the optional three-line CP850 fallback is emitted by builds
# whose iconv cannot convert to ANSI_X3.4-1968 in that locale.
rootpxe_fat_dirty_only_diagnostic() {
    local output_file="$1"
    [[ -r $output_file ]] || return 1
    LC_ALL=C awk '
        BEGIN { version=dirty=remove=unchanged=stats=0; cp_to=cp_from=cp_internal=0; invalid=0 }
        /^fsck\.fat 4\.2 \(2021-01-31\)$/ { version++; next }
        /^Dirty bit is set\. Fs was not properly unmounted and some data may be corrupt\.$/ { dirty++; next }
        /^ Automatically removing dirty bit\.$/ { remove++; next }
        /^Leaving filesystem unchanged\.$/ { unchanged++; next }
        /^Cannot initialize conversion from codepage 850 to ANSI_X3\.4-1968: Invalid argument$/ { cp_to++; next }
        /^Cannot initialize conversion from ANSI_X3\.4-1968 to codepage 850: Invalid argument$/ { cp_from++; next }
        /^Using internal CP850 conversion table$/ { cp_internal++; next }
        /^[^:[:cntrl:]]+: [0-9]+ files, [0-9]+\/[0-9]+ clusters$/ { stats++; next }
        /^[[:space:]]*$/ { next }
        { invalid=1 }
        END { exit !(invalid == 0 && version == 1 && dirty == 1 && remove == 1 && unchanged == 1 && stats == 1 && ((cp_to == 0 && cp_from == 0 && cp_internal == 0) || (cp_to == 1 && cp_from == 1 && cp_internal == 1))) }
    ' "$output_file"
}

rootpxe_fat_growth_preflight() {
    local part="$1" output_file="$2" status mount_state repair_status
    [[ -n $part && -n $output_file ]] || return 16
    LC_ALL=C fsck.fat -n "$part" >"$output_file" 2>&1
    status=$?
    [[ $status -eq 0 ]] && return 0
    [[ $status -eq 1 ]] && rootpxe_fat_dirty_only_diagnostic "$output_file" || return "$status"
    command -v findmnt >/dev/null 2>&1 || return 16
    findmnt -rn -S "$part" >/dev/null 2>&1
    mount_state=$?
    [[ $mount_state -eq 1 ]] || return 16
    printf '\nPXEOS accepted the exact dirty-bit-only diagnostic; running fsck.fat -a.\n' >>"$output_file"
    if LC_ALL=C fsck.fat -a "$part" >>"$output_file" 2>&1; then
        repair_status=0
    else
        repair_status=$?
    fi
    [[ $repair_status -eq 0 || $repair_status -eq 1 ]] || return "$repair_status"
    printf '\nPXEOS verifying FAT after automatic repair.\n' >>"$output_file"
    LC_ALL=C fsck.fat -n "$part" >>"$output_file" 2>&1
}

# Expands partitions, as needed/capable
#
# $1 is the partition
# $2 is the fixed size partitions (can be empty)
expandPartition() {
    local part="$1"
    local fixed="$2"
    local required_growth="${3:-}"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk=""
    local part_number=0
    local e2fsck_status=0
    getDiskFromPartition "$part"
    getPartitionNumber "$part"
    local is_fixed=$(echo $fixed | awk "/(^$part_number:|:$part_number:|:$part_number$|^$part_number$)/{print 1}")
    if [[ $is_fixed -eq 1 ]]; then
        rootpxe_console_message INFO "Not expanding $part: fixed size."
        debugPause
        return
    fi
    local fstype=""
    fsTypeSetting $part
    case $fstype in
        ntfs)
            dots "Resizing $fstype volume ($part)"
            yes | ntfsresize $part -fbP >/tmp/tmpoutput.txt 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    echo "Failed"
                    debugPause
                    handleError "Could not resize $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/tmpoutput.txt)\n   Args Passed: $*"
                    ;;
            esac
            debugPause
            resetFlag "$part"
            ;;
        extfs)
            dots "Resizing $fstype volume ($part)"
            rootpxe_e2fsck_preflight "$part" /tmp/e2fsck.txt
            e2fsck_status=$?
            if [[ $e2fsck_status -ne 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not check before resize (${FUNCNAME[0]})\n   Exit code: $e2fsck_status\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
            fi
            resize2fs "$part" >/tmp/resize2fs.txt 2>&1
            case $? in
                0)
                    ;;
                *)
                    echo "Failed"
                    debugPause
                    handleError "Could not resize $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize2fs.txt)\n   Args Passed: $*"
                    ;;
            esac
            rootpxe_e2fsck_preflight "$part" /tmp/e2fsck.txt
            e2fsck_status=$?
            if [[ $e2fsck_status -ne 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not check after resize (${FUNCNAME[0]})\n   Exit code: $e2fsck_status\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
            fi
            echo "Done"
            ;;
        btrfs)
            # Based on community discussion from @mstabrin
            dots "Resizing $fstype volume ($part)"
            if [[ ! -d /tmp/btrfs ]]; then
                mkdir /tmp/btrfs >>/tmp/btfrslog.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not create /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
                fi
            fi
            mount -t btrfs $part /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not mount $part to /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            btrfs filesystem resize max /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not resize btrfs partition (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            umount /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not unmount $part from /tmp/btrfs (${FUNCNAME[0]}\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*)"
            fi
            echo "Done"
            ;;
        f2fs)
            if [[ $type == "down" ]]; then
                dots "Resizing $fstype volume ($part)"
                resize.f2fs $part >>/tmp/resize.f2fs.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not expand f2fs partition (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize.f2fs.txt)\n  Args Passed: $*"
                fi
                echo "Done"
            fi
            ;;
        fat)
            # The resolved deployment layout is the sole source of partition
            # geometry.  pxeosfatgrow only expands the FAT filesystem inside
            # the already-expanded partition and never edits its table entry.
            if [[ $type == "down" ]]; then
                dots "Resizing $fstype volume ($part)"
                command -v fsck.fat >/dev/null 2>&1 || { echo "Failed"; debugPause; handleError "FAT filesystem check tool is unavailable for $part (${FUNCNAME[0]})"; }
                command -v pxeosfatgrow >/dev/null 2>&1 || { echo "Failed"; debugPause; handleError "FAT grow tool is unavailable for $part (${FUNCNAME[0]})"; }
                rootpxe_fat_growth_preflight "$part" /tmp/pxeosfatgrow-fsck.txt || { echo "Failed"; debugPause; handleError "FAT filesystem check failed before growth for $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/pxeosfatgrow-fsck.txt)\n   Args Passed: $*"; }
                pxeosfatgrow "$part" >/tmp/pxeosfatgrow.txt 2>&1 || { echo "Failed"; debugPause; handleError "Could not grow FAT filesystem on $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/pxeosfatgrow.txt)\n   Args Passed: $*"; }
                LC_ALL=C fsck.fat -n "$part" >/tmp/pxeosfatgrow-fsck.txt 2>&1 || { echo "Failed"; debugPause; handleError "FAT filesystem check failed after growth for $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/pxeosfatgrow-fsck.txt)\n   Args Passed: $*"; }
                echo "Done"
            fi
            ;;
        xfs)
            if [[ $type == "down" ]]; then
                local xfs_mount=""
                dots "Attempting to resize $fstype volume ($part)"

                # The resolved deployment layout already owns partition
                # geometry.  Do not overwrite it with a later 100% end or
                # infer free space from a second partition-table scan.
                    xfs_mount=$(mktemp -d /tmp/rootpxe-xfs-grow.XXXXXX) || {
                        echo "Failed"
                        debugPause
                        handleError "Could not create XFS grow mountpoint (${FUNCNAME[0]})\n   Args Passed: $*"
                    }
                    mount -t xfs -o rw,nouuid "$part" "$xfs_mount" >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        rmdir "$xfs_mount" >/dev/null 2>&1 || true
                        echo "Failed"
                        debugPause
                        handleError "Could not mount $part for XFS growth (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    xfs_growfs "$xfs_mount" >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        umount "$xfs_mount" >>/tmp/xfslog.txt 2>&1 || true
                        rmdir "$xfs_mount" >/dev/null 2>&1 || true
                        echo "Failed"
                        debugPause
                        handleError "Could not grow XFS partition $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    umount "$xfs_mount" >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        umount "$xfs_mount" >>/tmp/xfslog.txt 2>&1 || true
                        echo Failed
                        debugPause
                        handleError "Could not unmount $part from $xfs_mount (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    rmdir "$xfs_mount" >/dev/null 2>&1 || { echo Failed; debugPause; handleError "Could not clean XFS grow mountpoint (${FUNCNAME[0]})\n   Args Passed: $*"; }
                    echo "Done"
            fi
            ;;
        *)
            if [[ $required_growth == required ]]; then
                echo "Failed"
                debugPause
                handleError "Could not expand $part: $fstype is not supported for a required filesystem growth (${FUNCNAME[0]})\n   Args Passed: $*"
            else
                rootpxe_console_message INFO "Not expanding $part: $fstype is not supported."
                debugPause
            fi
            ;;
    esac
    debugPause
    runPartprobe "$disk"
}
# Check if partition is bitlocked
#
# Bitlocker To Go GUIDs (we probably never need those but as I spend time
# to understand those are in RAW mode I'll leave them in the code for now):
# 3bd66749292ed84a8399f6a339e3d001 - INFORMATION_OFFSET_GUID
# 3b4da89280dd0e4d9e4eb1e3284eaed8 - EOW_INFORMATION_OFFSET_GUID
#
# $1 is the partition
isBitlockedPartition() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local is_bitlocked=$(dd if=$part bs=512 count=1 2>&1 | grep -ie '-FVE-FS-')
    if [[ -n $is_bitlocked ]]; then
        handleError "Found bitlocker signature in partition $part header. Please disable BITLOCKER before capturing an image. (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
}
# Gets the filesystem type of the partition passed
#
# $1 is the partition
fsTypeSetting() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local blk_fs=$(blkid -po udev $part | awk -F= '/FS_TYPE=/{print $2}')
    case $blk_fs in
        apfs)
            fstype="apfs"
            ;;
        btrfs)
            fstype="btrfs"
            ;;
        ext[2-4])
            fstype="extfs"
            ;;
        f2fs)
            fstype="f2fs"
            ;;
        hfsplus)
            fstype="hfsp"
            ;;
        LVM2_member)
            fstype="lvm"
            ;;
        ntfs)
            fstype="ntfs"
            ;;
        swap)
            fstype="swap"
            ;;
        vfat)
            fstype="fat"
            ;;
        xfs)
            fstype="xfs"
            ;;
        *)
            fstype="imager"
            ;;
    esac
}
# Gets the partition entry name
#
# $1 is the partition
getPartName() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    partname=$(blkid -po udev $part | awk -F= '/PART_ENTRY_NAME=/{print $2}')
}
# Gets the partition entry type
#
# $1 is the partition
getPartType() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    parttype=$(blkid -po udev $part | awk -F= '/PART_ENTRY_TYPE=/{print $2}')
}
# Gets the entry schemed (dos, gpt, etc...)
#
# $1 is the partition
getPartitionEntryScheme() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    scheme=$(blkid -po udev $part | awk -F= '/PART_ENTRY_SCHEME=/{print $2}')
}
# Checks if the partition is dos extended (mbr with logical parts)
#
# $1 is the partition
partitionIsDosExtended() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local scheme=""
    getPartitionEntryScheme "$part"
    debugEcho "scheme = $scheme" 1>&2
    case $scheme in
        dos)
            echo "no"
            ;;
        *)
            local parttype=""
            getPartType "$part"
            debugEcho "parttype = $parttype" 1>&2
            [[ ${parttype,,} == +(5|f|85|0x5|0xf|0x85) ]] && echo "yes" || echo "no"
            ;;
    esac
    debugPause
}
# Returns the block size of a partition
#
# $1 is the partition
# $2 is the variable to set
getPartBlockSize() {
    local part="$1"
    local varVar="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $varVar ]] && handleError "No variable to set passed (${FUNCNAME[0]})\n   Args Passed: $*"
    printf -v "$varVar" $(blockdev --getpbsz $part)
}
# Retrieve available space from NFS share
# Should only be used when the share is mounted to `/storage`
getServerDiskSpaceSvailable() {
    local space=$(df -h | grep "/storage" | sed -n '/dev/{s/  */ /gp}' | cut -d ' ' -f4)
    [[ $space == "0" ]] && local space="0M"
    echo $space
}
# Prepares location info for uploads
#
# $1 is the image path
prepareUploadLocation() {
    local imagePath="$1"
    rootpxe_require_task_context || handleError "Invalid task context (${FUNCNAME[0]})"
    [[ $imagePath == "/storage/dev/$macWinSafe" ]] || handleError "Unsafe capture path (${FUNCNAME[0]})"
    [[ ! -L $imagePath ]] || handleError "Unsafe capture path (${FUNCNAME[0]})"
    dots "Preparing backup location"
    if [[ -d $imagePath ]]; then
        find "$imagePath" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || handleError "Failed to clear capture path (${FUNCNAME[0]})"
    else
        mkdir -p $imagePath >/dev/null 2>&1
        case $? in
            0)
                ;;
            *)
                echo "Failed"
                debugPause
                local spaceAvailable=$(getServerDiskSpaceSvailable)
                handleError "Failed to create image capture path (${FUNCNAME[0]})\nServer Disk Space Available: $spaceAvailable\n   Args Passed: $*"
                ;;
        esac
    fi
    echo "Done"
    debugPause
    dots "Setting permission on $imagePath"
    chmod -R 775 $imagePath >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Failed to set permissions (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    debugPause
    dots "Removing any pre-existing files"
    rm -Rf $imagePath/* >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not clean files (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    debugPause
}
# Moves partitions if possible for upload (resizable images only)
#
# $1 is the partition
# $2 is the previous partition
movePartition() {
    local part="$1"
    local prevPart="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    # Skip if we don't know about the previous partition, e.g. call on the very first partition
    [[ -z $prevPart ]] && return
    local disk=""
    getDiskFromPartition "$part"
    local tmp_file1="/tmp/move1.$$"
    local tmp_file2="/tmp/move2.$$"
    rm -f /tmp/move{1,2}.*
    saveSfdiskPartitions "$disk" "$tmp_file1"
    prevPartStart=$(grep "$prevPart" $tmp_file1 | cut -d',' -f1 | awk -F'=' '{print $2}' | tr -d ' ')
    prevPartSize=$(grep "$prevPart" $tmp_file1 | cut -d',' -f2 | awk -F'=' '{print $2}' | tr -d ' ')
    newStart=$(calculate "${prevPartStart}+${prevPartSize}")
    currPartStart=$(grep "$part" $tmp_file1 | cut -d',' -f1 | awk -F'=' '{print $2}' | tr -d ' ')
    if [[ $currPartStart -gt $newStart ]]; then
        rootpxe_console_message INFO "Moving $part to close the gap after $prevPart."
        debugPause
        processSfdisk "$tmp_file1" move "$part" "$newStart" > "$tmp_file2"
        if [[ $ismajordebug -gt 0 ]]; then
            majorDebugEcho "Partition table *before* moving $part:"
            cat $tmp_file1
            majorDebugPause
            majorDebugEcho "Partition table *after* moving $part - will be applied when you hit ENTER:"
            cat $tmp_file2
            majorDebugPause
        fi
        applySfdiskPartitions "$disk" "$tmp_file2"
    fi
}
# Shrinks partitions for upload (resizable images only)
#
# $1 is the partition
# $2 is the fstypes file location
# $3 is the fixed partition numbers empty ok
shrinkPartition() {
    local part="$1"
    local fstypefile="$2"
    local fixed="$3"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $fstypefile ]] && handleError "No type file passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk=""
    local part_number=0
    getDiskFromPartition "$part"
    getPartitionNumber "$part"
    local is_fixed=$(echo $fixed | awk "/(^$part_number:|:$part_number:|:$part_number$|^$part_number$)/{print 1}")
    if [[ $is_fixed -eq 1 ]]; then
        rootpxe_console_message INFO "Not shrinking $part: fixed size."
        debugPause
        return
    fi
    local fstype=""
    fsTypeSetting "$part"
    echo "$part $fstype" >> $fstypefile
    local size=0
    local tmpoutput=""
    local sizentfsresize=0
    local sizeextresize=0
    local tmp_success=""
    local test_string=""
    local do_resizefs=0
    local do_resizepart=0
    local extminsize=0
    local block_size=0
    local sizeextresize=0
    local adjustedfdsize=0
    local part_block_size=0
    local e2fsck_status=0
    case $fstype in
        ntfs)
            ntfsresize -fivP $part >/tmp/tmpoutput.txt 2>&1
            if [[ ! $? -eq 0 ]]; then
                rootpxe_console_message INFO "Not shrinking $part: trying fixed size."
                debugPause
                echo "$(cat "$imagePath/d1.fixed_size_partitions" | tr -d \\0):${part_number}" > "$imagePath/d1.fixed_size_partitions"
                return
                #handleError " * (${FUNCNAME[0]})\n    Args Passed: $*\n\nFatal Error, unable to find size data out on $part. Cmd: ntfsresize -f -i -v -P $part"
            fi
            tmpoutput=$(cat /tmp/tmpoutput.txt | tr -d \\0)
            size=$(cat /tmp/tmpoutput.txt | tr -d \\0 | sed -n 's/.*you might resize at\s\+\([0-9]\+\).*$/\1/pi')
[[ -z $size ]] && handleError "${FUNCNAME[0]}\n   Args Passed: $*\n\nFatal error: unable to determine possible NTFS size.\nRunning ntfsresize again with full output; please wait.\n$(cat /tmp/tmpoutput.txt | tr -d \\0)"
            local min_slack_bytes=$((500 * 1024 * 1024))

            # percent-based slack, in bytes (integer math)
            # NOTE: relies on your calculate() handling basic math; if calculate uses bc, this is fine too.
            local sizeadd_bytes
            sizeadd_bytes=$(calculate "${percent}/100*${size}")
            [[ -z $sizeadd_bytes ]] && sizeadd_bytes=0

            # ensure at least 500MB slack
            local slack_bytes="$sizeadd_bytes"
            if [[ $slack_bytes -lt $min_slack_bytes ]]; then
                slack_bytes=$min_slack_bytes
            fi

            # target size in KiB for ntfsresize
            # (bytes -> KiB), and add slack (also bytes -> KiB)
            rm /tmp/tmpoutput.txt >/dev/null 2>&1
            sizentfsresize=$(calculate "(${size}+${slack_bytes})/1024")
[[ -z $sizentfsresize || $sizentfsresize -lt 1 ]] && handleError "${FUNCNAME[0]}\n   Args Passed: $*\n\nFatal error: unable to determine NTFS target size with 500MB minimum slack."

            rootpxe_console_message INFO "Possible resize partition size with slack: ${sizentfsresize}k."
            rootpxe_console_message INFO "Possible resize partition size: ${sizentfsresize}k."
            dots "Running resize test $part"
            yes | ntfsresize -fns ${sizentfsresize}k ${part} >/tmp/tmpoutput.txt 2>&1
            local ntfsstatus="$?"
            tmpoutput=$(cat /tmp/tmpoutput.txt | tr -d \\0)
            test_string=$(cat /tmp/tmpoutput.txt | egrep -io "(ended successfully|bigger than the device size|volume size is already OK)" | tr -d '[[:space:]]' | tr -d \\0)
            echo "Done"
            debugPause
            rm /tmp/tmpoutput.txt >/dev/null 2>&1
            case $test_string in
                endedsuccessfully)
                    rootpxe_console_message INFO 'Resize test completed successfully.'
                    do_resizefs=1
                    do_resizepart=1
                    ntfsstatus=0
                    ;;
                biggerthanthedevicesize)
                    rootpxe_console_message INFO "Not resizing filesystem $part: partition is too small."
                    echo "$(cat ${imagePath}/d1.fixed_size_partitions | tr -d \\0):${part_number}" > "$imagePath/d1.fixed_size_partitions"
                    ntfsstatus=0
                    ;;
                volumesizeisalreadyOK)
                    rootpxe_console_message INFO "Not resizing filesystem $part: already sized correctly."
                    do_resizepart=1
                    ntfsstatus=0
                    ;;
            esac
            [[ ! $ntfsstatus -eq 0 ]] && handleError "Resize test failed!\n    Info: $tmpoutput\n    (${FUNCNAME[0]})\n    Args Passed: $*"
            if [[ $do_resizefs -eq 1 ]]; then
                debugPause
                dots "Resizing filesystem"
                yes | ntfsresize -fs ${sizentfsresize}k ${part} >/tmp/output.txt 2>&1
                case $? in
                    0)
                        echo "Done"
                        rootpxe_capture_note_partition_shrunk "$part" "$fstype"
                        ;;
                    *)
                        echo "Failed"
                        debugPause
                        handleError "Could not resize disk (${FUNCNAME[0]})\n   Info: $(cat /tmp/output.txt)\n   Args Passed: $*"
                        ;;
                esac
            fi
            if [[ $do_resizepart -eq 1 ]]; then
                debugPause
                dots "Resizing partition $part"
                getPartBlockSize "$part" "part_block_size"
                case $osid in
                    [1-2]|4)
                        resizePartition "$part" "$(calculate "$sizentfsresize*1024")" "$imagePath"
                        rootpxe_capture_note_partition_shrunk "$part" "$fstype"
                        [[ $osid -eq 2 ]] && correctVistaMBR "$disk"
                        ;;
                    [5-7]|9|10|11)
                        [[ $part_number -eq $win7partcnt ]] && part_start=$(blkid -po udev $part 2>/dev/null | awk -F= '/PART_ENTRY_OFFSET=/{printf("%.0f\n",$2*'$part_block_size'/1000)}') || part_start=1048576
                        if [[ -z $part_start || $part_start -lt 1 ]]; then
                            echo "Failed"
                            debugPause
                            handleError "Unable to determine disk start location (${FUNCNAME[0]})\n   Args Passed: $*"
                        fi
                        adjustedfdsize=$(calculate "${sizentfsresize}*1024")
                        resizePartition "$part" "$adjustedfdsize" "$imagePath"
                        rootpxe_capture_note_partition_shrunk "$part" "$fstype"
                        ;;
                esac
                echo "Done"
            fi
            resetFlag "$part"
            ;;
        extfs)
            dots "Checking $fstype volume ($part)"
            rootpxe_e2fsck_preflight "$part" /tmp/e2fsck.txt
            e2fsck_status=$?
            if [[ $e2fsck_status -ne 0 ]]; then
                echo "Failed"
                debugPause
                handleError "e2fsck failed to check $part (${FUNCNAME[0]})\n   Exit code: $e2fsck_status\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
            fi
            echo "Done"
            debugPause
            extminsize=$(resize2fs -P $part 2>/dev/null | awk -F': ' '{print $2}')
            block_size=$(dumpe2fs -h $part 2>/dev/null | awk '/^Block[ ]size:/{print $3}')
            size=$(calculate "${extminsize}*${block_size}")
            local sizeadd=$(calculate "${percent}/100*${size}")
            sizeextresize=$(calculate "${size}+${sizeadd}")
            [[ -z $sizeextresize || $sizeextresize -lt 1 ]] && handleError "Error calculating the new size of extfs ($part) (${FUNCNAME[0]})\n   Args Passed: $*"
            dots "Shrinking $fstype volume ($part)"
            resize2fs "$part" -M >/tmp/resize2fs.txt 2>&1
            case $? in
                0)
                    echo "Done"
                    rootpxe_capture_note_partition_shrunk "$part" "$fstype"
                    ;;
                *)
                    echo "Failed"
                    debugPause
                    handleError "Could not shrink $fstype volume ($part) (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize2fs.txt)\n   Args Passed: $*"
                    ;;
            esac
            debugPause
            dots "Shrinking $part partition"
            resizePartition "$part" "$sizeextresize" "$imagePath"
            rootpxe_capture_note_partition_shrunk "$part" "$fstype"
            echo "Done"
            debugPause
            dots "Checking $fstype volume ($part)"
            rootpxe_e2fsck_preflight "$part" /tmp/e2fsck.txt
            e2fsck_status=$?
            if [[ $e2fsck_status -ne 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not check expanded volume ($part) (${FUNCNAME[0]})\n   Exit code: $e2fsck_status\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
            fi
            echo "Done"
            ;;
        btrfs)
            # Based on community discussion from @mstabrin
            # btrfs deployment completion script notes
            dots "Shrinking $part partition"
            if [[ ! -d /tmp/btrfs ]]; then
                mkdir /tmp/btrfs >>/tmp/btfrslog.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not create /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
                fi
            fi
            mount -t btrfs $part /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not mount $part to /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            local free_size_original=$(btrfs filesystem usage -b /tmp/btrfs | grep unallocated | grep -Eo '[0-9]+')
            local fsize_pct=$(calculate_float "${percent}/100")
            local mult_val=$(calculate_float "1-${fsize_pct}")
            local free_size=$(calculate "${mult_val}*${free_size_original}")
            local btrfs_resize_status=1
            while :; do
                if btrfs filesystem resize -${free_size} /tmp/btrfs >>/tmp/btrfslog.txt 2>&1; then
                    btrfs_resize_status=0
                    break
                fi
                if [[ $(echo "${mult_val} <= 0" | bc -l) -gt 0 ]]; then
                    break
                fi
                mult_val=$(calculate_float "${mult_val} - 0.05")
                free_size=$(calculate "${mult_val}*${free_size_original}")
            done
            if [[ $btrfs_resize_status -ne 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not shrink btrfs volume ($part) (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            rootpxe_capture_note_partition_shrunk "$part" "$fstype"
            umount /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not unmount $part from /tmp/btrfs (${FUNCNAME[0]}\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*)"
            fi
            echo "Done"
            ;;
        f2fs)
            rootpxe_console_message WARN 'F2FS partitions cannot be shrunk.'
            ;;
        xfs)
            rootpxe_console_message WARN 'XFS partitions cannot be shrunk.'
            ;;
        *)
            rootpxe_console_message INFO "Not shrinking $part: $fstype is not supported."
            ;;
    esac
    debugPause
}
# Resets the dirty bits on a partition
#
# $1 is the part
resetFlag() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local fstype=""
    fsTypeSetting "$part"
    case $fstype in
        ntfs)
            dots "Clearing ntfs flag"
            ntfsfix -b -d $part >/dev/null 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    echo "Failed"
                    ;;
            esac
            ;;
    esac
}
# Counts the partitions containing the fs type as passed
#
# $1 is the disk
# $2 is the part type to look for
# $3 is the variable to store the count into. This is
#    a variable variable
countPartTypes() {
    local disk="$1"
    local parttype="$2"
    local varVar="$3"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $parttype ]] && handleError "No partition type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $varVar ]] && handleError "No variable to set passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local count=0
    local fstype=""
    local parts=""
    local part=""
    getPartitions "$disk"
    for part in $parts; do
        fsTypeSetting "$part"
        case $fstype in
            $parttype)
                let count+=1
                ;;
        esac
    done
    printf -v "$varVar" "$count"
}
# Writes the image to the disk
#
# $1 = Source File
# $2 = Target
# $3 = mc task or not (not required)
writeImage()  {
    local file="$1"
    local target="$2"
    local mc="$3"
    local source_pid=""
    local source_exitcode=0
    local source_file=""
    local source_files=()
    [[ -z $target ]] && handleError "No target to place image passed (${FUNCNAME[0]})"
    rootpxe_validate_runtime_img_format || handleError "PXEOS_STAGE=restore CODE=IMAGE_FORMAT_INVALID REASON=unsupported_or_missing_format"
    local format=$imgLegacy
    [[ -z $format ]] && format=$imgFormat
    local exitcode=0 progress_decoder=0 progress_enabled=no
    mkfifo /tmp/pigz1 || handleError "PXEOS_STAGE=restore CODE=RESTORE_PIPELINE_SETUP_FAILED REASON=unable_to_create_restore_fifo"
    if [[ $mc != yes ]]; then
        [[ -n $file ]] || handleError "No source file passed (${FUNCNAME[0]})\n   Args Passed: $*"
        # Validate every split source before the progress decoder or reader is
        # started, so an early failure cannot leave either FIFO endpoint open.
        mapfile -t source_files < <(compgen -G "$file")
        [[ ${#source_files[@]} -gt 0 ]] || handleError "PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE REASON=image_source_glob_has_no_regular_files"
        for source_file in "${source_files[@]}"; do
            [[ -f $source_file && -r $source_file ]] || handleError "PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE REASON=image_source_is_not_readable"
        done
    fi
    case $format in
        0|2|3|4|5|6)
            if ! rootpxe_partclone_progress_start; then
                rm -f /tmp/pigz1 >/dev/null 2>&1 || true
                handleError "PXEOS_STAGE=restore CODE=RESTORE_PROGRESS_SETUP_FAILED REASON=unable_to_start_partclone_stderr_decoder"
            fi
            progress_enabled=yes
            ;;
    esac
    case $mc in
        yes)
            if [[ -z $mcastrdv ]]; then
                udp-receiver --nokbd --portbase "$port" --ttl 32 --mcast-rdv-address "$storageip" 2>/dev/null >/tmp/pigz1 &
            else
                udp-receiver --nokbd --portbase "$port" --ttl 32 --mcast-rdv-address "$mcastrdv" 2>/dev/null >/tmp/pigz1 &
            fi
            source_pid="$!"
            ;;
        *)
            cat -- "${source_files[@]}" >/tmp/pigz1 &
            source_pid="$!"
            ;;
    esac
    case $format in
        5|6)
            # ZSTD Compressed image.
            rootpxe_console_message INFO 'Imaging with Partclone (zstd).'
            if ( set -o pipefail; zstdmt -dc </tmp/pigz1 | LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.restore "${rootpxe_partclone_progress_args[@]}" -n "Storage Location $storage, Image name $img" -O "${target}" -f 1 2>"$rootpxe_partclone_progress_stderr_target" ); then
                exitcode=0
            else
                exitcode=$?
            fi
            ;;
        3|4)
            # Uncompressed partclone
            rootpxe_console_message INFO 'Imaging with Partclone (uncompressed).'
            if ( set -o pipefail; cat </tmp/pigz1 | LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.restore "${rootpxe_partclone_progress_args[@]}" -n "Storage Location $storage, Image name $img" -O "${target}" -f 1 2>"$rootpxe_partclone_progress_stderr_target" ); then
                exitcode=0
            else
                exitcode=$?
            fi
            ;;
        1)
            # Partimage
            rootpxe_console_message INFO 'Imaging with Partimage (gzip).'
            #zstdmt -dc </tmp/pigz1 | partimage restore ${target} stdin -f3 -b 2>/tmp/status.pxeos
            if ( set -o pipefail; pigz -dc </tmp/pigz1 | partimage restore "${target}" stdin -f3 -b 2>/tmp/status.pxeos ); then
                exitcode=0
            else
                exitcode=$?
            fi
            ;;
        0|2)
            # GZIP Compressed partclone
            rootpxe_console_message INFO 'Imaging with Partclone (gzip).'
            if ( set -o pipefail; pigz -dc </tmp/pigz1 | LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.restore "${rootpxe_partclone_progress_args[@]}" -n "Storage Location $storage, Image name $img" -O "${target}" -f 1 2>"$rootpxe_partclone_progress_stderr_target" ); then
                exitcode=0
            else
                exitcode=$?
            fi
            ;;
    esac
    if [[ $progress_enabled == yes ]]; then
        rootpxe_partclone_progress_wait || progress_decoder=$?
    fi
    if wait "$source_pid"; then
        source_exitcode=0
    else
        source_exitcode=$?
    fi
    if [[ $exitcode -ne 0 ]]; then
        rm -rf /tmp/pigz1 >/dev/null 2>&1
        handleError "PXEOS_STAGE=restore CODE=RESTORE_PIPELINE_FAILED REASON=image_decoder_or_writer_failed"
    fi
    if [[ $progress_decoder -ne 0 ]]; then
        rm -rf /tmp/pigz1 >/dev/null 2>&1
        handleError "PXEOS_STAGE=restore CODE=RESTORE_PROGRESS_FAILED REASON=partclone_stderr_decoder_failed"
    fi
    if [[ $source_exitcode -ne 0 ]]; then
        rm -rf /tmp/pigz1 >/dev/null 2>&1
        handleError "PXEOS_STAGE=restore CODE=RESTORE_SOURCE_FAILED REASON=image_transport_or_storage_reader_failed"
    fi
    rm -rf /tmp/pigz1 >/dev/null 2>&1
}
# Gets the valid restore parts. They're only
#    valid if the partition data exists for
#    the partitions on the server
#
# $1 = Disk  (e.g. /dev/sdb)
# $2 = Disk number  (e.g. 1)
# $3 = ImagePath  (e.g. /net/foo)
getValidRestorePartitions() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local setrestoreparts="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local valid_parts=""
    local parts=""
    local part=""
    local imgpart=""
    local part_number=0
    local split=''
    if [[ $imgFormat -eq 6 || $imgFormat -eq 4 || $imgFormat -eq 2 ]]; then
        split='*'
    fi
    getPartitions "$disk"
    for part in $parts; do
        getPartitionNumber "$part"
        [[ $imgPartitionType != all && $imgPartitionType != $part_number ]] && continue
        case $osid in
            [1-2])
                [[ ! -f $imagePath ]] && imgpart="$imagePath/d${disk_number}p${part_number}.img${split}" || imgpart="$imagePath"
                ;;
            4|[5-7]|9|10|11)
                [[ ! -f $imagePath/sys.img.000 ]] && imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                if [[ -z $imgpart ]]; then
                    case $win7partcnt in
                        1)
                            [[ $part_number -eq 1 ]] && imgpart="$imagePath/sys.img.*"
                            ;;
                        2)
                            [[ $part_number -eq 1 ]] && imgpart="$imagePath/rec.img.000"
                            [[ $part_number -eq 2 ]] && imgpart="$imagePath/sys.img.*"
                            ;;
                        3)
                            [[ $part_number -eq 1 ]] && imgpart="$imagePath/rec.img.000"
                            [[ $part_number -eq 2 ]] && imgpart="$imagePath/rec.img.001"
                            [[ $part_number -eq 3 ]] && imgpart="$imagePath/sys.img.*"
                            ;;
                    esac
                fi
                ;;
            *)
                imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                ;;
        esac
        ls $imgpart >/dev/null 2>&1
        [[ $? -eq 0 ]] && valid_parts="$valid_parts $part"
    done
    [[ -z $setrestoreparts ]] && restoreparts=$(echo $valid_parts | uniq | sort -V) || restoreparts="$(echo $setrestoreparts | uniq | sort -V)"
}
# Makes all swap partitions and sets uuid's in linux setups
#
# $1 = Disk  (e.g. /dev/sdb)
# $2 = Disk number  (e.g. 1)
# $3 = ImagePath  (e.g. /net/foo)
# $4 = ImagePartitionType  (e.g. all, mbr, 1, 2, 3, etc.)
makeAllSwapSystems() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local imgPartitionType="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No image partition type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local swapuuidfilename=""
    swapUUIDFileName "$imagePath" "$disk_number"
    [[ -r "$swapuuidfilename" ]] || return
    local parts=""
    local part=""
    local part_number=0
    getPartitions "$disk"
    for part in $parts; do
        getPartitionNumber "$part"
        [[ $imgPartitionType == all || $imgPartitionType -eq $part_number ]] && makeSwapSystem "$swapuuidfilename" "$part"
    done
    runPartprobe "$disk"
}
# Find the one deployed Windows system volume before making any hostname
# change.  Recovery partitions can also be NTFS, so filesystem type alone is
# unsafe.  The fixed SYSTEM hive is proof of a Windows installation; this does
# not search for arbitrary unattend files.  Return 10 for no candidate and 11
# for ambiguity so callers report a stable attention reason.
rootpxe_find_windows_system_partition() {
    local disk="$1" part candidate="" candidate_count=0
    [[ -n $disk ]] || return 10
    mkdir -p /ntfs || return 10
    getPartitions "$disk"
    for part in $parts; do
        fsTypeSetting "$part"
        [[ $fstype == ntfs ]] || continue
        umount /ntfs >/dev/null 2>&1 || true
        ntfs-3g -o ro "$part" /ntfs >/tmp/ntfs-probe-output 2>&1 || continue
        if [[ -f /ntfs/Windows/System32/config/SYSTEM ]]; then
            candidate="$part"
            ((candidate_count++))
        fi
        umount /ntfs >/dev/null 2>&1 || true
    done
    case $candidate_count in
        1) printf '%s\n' "$candidate"; return 0 ;;
        0) return 10 ;;
        *) return 11 ;;
    esac
}

# Returns whether a filesystem type can safely be probed as a Linux root.
# Probe only known local Linux filesystem types; never fall back to mount -t
# auto, which could make an arbitrary target partition look like a root.
rootpxe_linux_root_fstype_supported() {
    case $1 in
        ext2|ext3|ext4|xfs|btrfs|f2fs) return 0 ;;
        *) return 1 ;;
    esac
}

rootpxe_linux_btrfs_subvolid_valid() {
    [[ $1 =~ ^[1-9][0-9]*$ ]]
}

rootpxe_linux_btrfs_default_subvolid() {
    local mountpoint="$1" output subvolid
    output=$(btrfs subvolume get-default "$mountpoint" 2>/dev/null) || return 1
    subvolid=$(awk '$1 == "ID" && $2 ~ /^[1-9][0-9]*$/ { print $2; exit }' <<<"$output")
    rootpxe_linux_btrfs_subvolid_valid "$subvolid" || return 1
    printf '%s\n' "$subvolid"
}

rootpxe_linux_btrfs_subvolume_ids() {
    local device="$1" mountpoint=/linuxroot options rows parsed subvolids
    mkdir -p "$mountpoint" || return 3
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" >/dev/null 2>&1 || return 2
    fi
    options=$(rootpxe_linux_mount_options ro btrfs) || return 3
    mount -t btrfs -o "$options" "$device" "$mountpoint" >/tmp/rootpxe-linux-btrfs-list-output 2>&1 || return 3
    rows=$(mktemp /tmp/rootpxe-linux-btrfs-subvolumes.XXXXXX) || { umount "$mountpoint" >/dev/null 2>&1 || return 2; return 3; }
    btrfs subvolume list "$mountpoint" >"$rows" 2>/dev/null || { rm -f -- "$rows"; umount "$mountpoint" >/dev/null 2>&1 || return 2; return 3; }
    parsed=$(mktemp /tmp/rootpxe-linux-btrfs-subvolumes-parsed.XXXXXX) || { rm -f -- "$rows"; umount "$mountpoint" >/dev/null 2>&1 || return 2; return 3; }
    awk '
        NF == 0 { next }
        $1 == "ID" && $2 ~ /^[1-9][0-9]*$/ { print $2; next }
        { exit 1 }
    ' "$rows" >"$parsed" || { rm -f -- "$rows" "$parsed"; umount "$mountpoint" >/dev/null 2>&1 || return 2; return 3; }
    subvolids=$(sort -un "$parsed") || { rm -f -- "$rows" "$parsed"; umount "$mountpoint" >/dev/null 2>&1 || return 2; return 3; }
    rm -f -- "$rows" "$parsed"
    umount "$mountpoint" >/dev/null 2>&1 || return 2
    [[ -n $subvolids ]] || return 1
    printf '%s\n' "$subvolids"
}

rootpxe_linux_mount_options() {
    local mode="$1" fstype="$2" subvolid="${3:-}" options
    case $fstype in
        xfs) printf '%s,nouuid' "$mode" ;;
        btrfs)
            [[ -z $subvolid ]] || rootpxe_linux_btrfs_subvolid_valid "$subvolid" || return 1
            if [[ $mode == ro ]]; then options=ro,nologreplay; else options=rw; fi
            [[ -z $subvolid ]] || options="$options,subvolid=$subvolid"
            printf '%s' "$options"
            ;;
        *) printf '%s' "$mode" ;;
    esac
}

# An image may contain symlinks.  Do not let a regular read of os-release
# follow an absolute or escaping link outside the mounted target root.  Relative
# /etc/os-release -> ../usr/lib/os-release remains valid when it resolves
# inside that target root.
rootpxe_linux_has_safe_os_release() {
    local mountpoint="$1" path resolved target
    for path in "$mountpoint/etc/os-release" "$mountpoint/usr/lib/os-release"; do
        [[ -e $path || -L $path ]] || continue
        if [[ -L $path ]]; then
            target=$(readlink "$path" 2>/dev/null) || continue
            [[ $target != /* ]] || continue
            resolved=$(readlink -f "$path" 2>/dev/null) || continue
            case $resolved in
                "$mountpoint"/*) [[ -f $resolved ]] && return 0 ;;
            esac
        elif [[ -f $path ]]; then
            return 0
        fi
    done
    return 1
}

rootpxe_linux_paths_safe_for_write() {
    local mountpoint="$1" path
    [[ -d "$mountpoint/etc" && ! -L "$mountpoint/etc" ]] || return 1
    for path in "$mountpoint/etc/hostname" "$mountpoint/etc/hosts"; do
        [[ ! -L $path ]] || return 1
        [[ ! -e $path || -f $path ]] || return 1
    done
    return 0
}

rootpxe_linux_probe_root_candidate() {
    local device="$1" fstype="$2" vg_name="${3:-}" vg_uuid="${4:-}" subvolid="${5:-}" mountpoint=/linuxroot options candidate=""
    rootpxe_linux_root_fstype_supported "$fstype" || return 1
    mkdir -p "$mountpoint" || return 1
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" >/dev/null 2>&1 || return 2
    fi
    options=$(rootpxe_linux_mount_options ro "$fstype" "$subvolid") || { [[ $fstype == btrfs ]] && return 3; return 1; }
    mount -t "$fstype" -o "$options" "$device" "$mountpoint" >/tmp/rootpxe-linux-probe-output 2>&1 || { [[ $fstype == btrfs ]] && return 3; return 1; }
    if [[ -d "$mountpoint/etc" && ! -L "$mountpoint/etc" ]] && rootpxe_linux_has_safe_os_release "$mountpoint"; then
        if [[ $fstype == btrfs && -z $subvolid ]]; then
            subvolid=$(rootpxe_linux_btrfs_default_subvolid "$mountpoint") || { umount "$mountpoint" >/dev/null 2>&1 || return 2; return 3; }
        fi
        candidate="$device|$fstype|$vg_name|$vg_uuid|$subvolid"
    fi
    umount "$mountpoint" >/dev/null 2>&1 || return 2
    [[ -n $candidate ]] || return 1
    printf '%s\n' "$candidate"
}

rootpxe_linux_validate_vg_target_pvs() {
    local disk="$1" vg_uuid="$2" pv pvs_json all_pvs target_part pv_on_target
    getPartitions "$disk"
    [[ -n ${parts:-} ]] || return 1
    rootpxe_lvm_safe_identifier "$vg_uuid" || return 1
    pvs_json=$(pvs --reportformat json -o pv_name,vg_uuid 2>/dev/null) || return 1
    rootpxe_lvm_json_jq -e '(.report|type == "array" and length == 1 and ((.[0].pv? // [])|type == "array") and all((.[0].pv? // [])[]; (.pv_name|type == "string") and (.vg_uuid|type == "string")))' <<<"$pvs_json" >/dev/null || return 1
    all_pvs=$(rootpxe_lvm_json_jq -r --arg uuid "$vg_uuid" '.report[0].pv[] | select(.vg_uuid == $uuid) | .pv_name' <<<"$pvs_json") || return 1
    [[ -n $all_pvs ]] || return 1
    for pv in $all_pvs; do
        pv=$(rootpxe_lvm_trim "$pv")
        pv_on_target=no
        while IFS= read -r target_part; do
            [[ -n $target_part && $pv == "$target_part" ]] || continue
            pv_on_target=yes
            break
        done <<<"${parts:-}"
        [[ $pv_on_target == yes ]] || return 1
    done
    return 0
}

rootpxe_linux_lvm_path_readable() { [[ -b $1 && -r $1 ]]; }
rootpxe_linux_lvs_for_vg_json() {
    local vg_name="$1" vg_uuid="$2" output="$3" lvs_json
    rootpxe_lvm_storage_identifier "$vg_name" && rootpxe_lvm_safe_identifier "$vg_uuid" || return 1
    lvs_json=$(lvs --reportformat json -o vg_name,vg_uuid,lv_name,lv_path,lv_active --select "vg_uuid=$vg_uuid" "$vg_name" 2>/dev/null) || return 1
    rootpxe_lvm_json_jq -e --arg name "$vg_name" --arg uuid "$vg_uuid" '(.report|type == "array" and length == 1 and ((.[0].lv? // [])|type == "array") and ((.[0].lv? // [])|length > 0) and all((.[0].lv? // [])[]; (.vg_name == $name) and (.vg_uuid == $uuid) and (.lv_name|type == "string") and (.lv_path|type == "string") and (.lv_active|type == "string")))' <<<"$lvs_json" >/dev/null || return 1
    rootpxe_lvm_json_jq -r '.report[0].lv[] | [.lv_name,.lv_path,.lv_active] | @tsv' <<<"$lvs_json" >"$output"
}

# Emits yes only when this function activated the UUID-selected VG.  An
# unknown or mixed LV activation state is rejected instead of guessing whether
# it is safe to deactivate later.
rootpxe_linux_activate_vg_if_needed() {
    local disk="$1" vg_name="$2" vg_uuid="$3" rows state count=0 inactive=0 active=0 lv_name lv_path
    rootpxe_linux_validate_vg_target_pvs "$disk" "$vg_uuid" || return 2
    rows=$(mktemp /tmp/rootpxe-linux-lvs.XXXXXX) || return 1
    rootpxe_linux_lvs_for_vg_json "$vg_name" "$vg_uuid" "$rows" || { rm -f -- "$rows"; return 1; }
    while IFS=$'\t' read -r lv_name lv_path state; do
        lv_name=$(rootpxe_lvm_trim "$lv_name"); lv_path=$(rootpxe_lvm_trim "$lv_path"); state=$(rootpxe_lvm_trim "$state")
        [[ -n $lv_name && -n $lv_path ]] || { rm -f -- "$rows"; return 1; }
        count=$((count + 1))
        case $state in ''|inactive) inactive=$((inactive + 1));; active) active=$((active + 1));; *) rm -f -- "$rows"; return 1;; esac
    done <"$rows"
    [[ $count -gt 0 ]] || { rm -f -- "$rows"; return 1; }
    if [[ $inactive -eq $count ]]; then
        if ! vgchange -ay --select "vg_uuid=$vg_uuid" "$vg_name" >/tmp/rootpxe-linux-vgchange-output 2>&1; then
            vgchange -an --select "vg_uuid=$vg_uuid" "$vg_name" >/dev/null 2>&1 || true
            rm -f -- "$rows"
            return 1
        fi
        : >"$rows"
        rootpxe_linux_lvs_for_vg_json "$vg_name" "$vg_uuid" "$rows" || { vgchange -an --select "vg_uuid=$vg_uuid" "$vg_name" >/dev/null 2>&1 || true; rm -f -- "$rows"; return 1; }
        count=0
        while IFS=$'\t' read -r lv_name lv_path state; do
            lv_name=$(rootpxe_lvm_trim "$lv_name"); lv_path=$(rootpxe_lvm_trim "$lv_path"); state=$(rootpxe_lvm_trim "$state")
            [[ $state == active ]] && rootpxe_linux_lvm_path_readable "$lv_path" || { vgchange -an --select "vg_uuid=$vg_uuid" "$vg_name" >/dev/null 2>&1 || true; rm -f -- "$rows"; return 1; }
            count=$((count + 1))
        done <"$rows"
        [[ $count -gt 0 ]] || { vgchange -an --select "vg_uuid=$vg_uuid" "$vg_name" >/dev/null 2>&1 || true; rm -f -- "$rows"; return 1; }
        rm -f -- "$rows"
        printf '%s\n' yes
    elif [[ $active -eq $count ]]; then
        rm -f -- "$rows"
        printf '%s\n' no
    else
        rm -f -- "$rows"
        return 1
    fi
}

rootpxe_linux_cleanup_selected_vg() {
    local vg_name="$1" vg_uuid="$2" activated="$3"
    [[ $activated == yes && -n $vg_name && -n $vg_uuid ]] || return 0
    vgchange -an --select "vg_uuid=$vg_uuid" "$vg_name" >/dev/null 2>&1 || true
}

# Finds exactly one Linux root filesystem belonging to the target disk.  For
# LVM, all PVs of a VG must be target-disk partitions and the VG UUID is used
# for selection, so a same-name or cross-disk VG cannot be activated blindly.
# Return 20=no root, 21=ambiguous root, 22=only cross-disk LVM candidates,
# 23=LVM activation/state failure, 24=filesystem probe failure.  Do not
# report an activation failure as a cross-disk topology violation.
rootpxe_find_linux_root_filesystem() {
    local disk="$1" part fs candidate pv vg_name vg_uuid activation lvs_output lv pvs_json lvs_rows pv_rows subvolid probe_rc enum_rc subvolids
    local target_parts="" lvm_parts="" seen_vgs="" activated_vgs="" candidates="" cross_disk_lvm=0 lvm_activation_failed=0 probe_failed=0 rc=20
    [[ -n $disk ]] || return 20
    getPartitions "$disk"
    [[ -n ${parts:-} ]] || return 20
    for part in $parts; do
        target_parts="$target_parts $part"
        # fsTypeSetting returns PXEOS/Partclone handler names (for example,
        # ext2/3/4 become extfs), which are not mount filesystem types.  Root
        # discovery must retain blkid's physical type and only inspect PVs.
        fs=$(blkid -p -o value -s TYPE "$part" 2>/dev/null) || continue
        case $fs in
            LVM2_member)
                lvm_parts="$lvm_parts $part"
                ;;
            btrfs)
                candidate=$(rootpxe_linux_probe_root_candidate "$part" "$fs")
                probe_rc=$?
                if [[ $probe_rc -eq 0 ]]; then
                    candidates="$candidates $candidate"
                    continue
                fi
                if [[ $probe_rc -ne 1 ]]; then probe_failed=1; continue; fi
                subvolids=$(rootpxe_linux_btrfs_subvolume_ids "$part")
                enum_rc=$?
                if [[ $enum_rc -eq 2 || $enum_rc -eq 3 ]]; then probe_failed=1; continue; fi
                [[ $enum_rc -eq 0 ]] || continue
                while IFS= read -r subvolid; do
                    rootpxe_linux_btrfs_subvolid_valid "$subvolid" || continue
                    candidate=$(rootpxe_linux_probe_root_candidate "$part" "$fs" "" "" "$subvolid")
                    probe_rc=$?
                    if [[ $probe_rc -ne 0 && $probe_rc -ne 1 ]]; then probe_failed=1; continue; fi
                    [[ $probe_rc -eq 0 ]] || continue
                    candidates="$candidates $candidate"
                done <<<"$subvolids"
                ;;
            *)
                candidate=$(rootpxe_linux_probe_root_candidate "$part" "$fs")
                probe_rc=$?
                if [[ $probe_rc -ne 0 && $probe_rc -ne 1 ]]; then probe_failed=1; continue; fi
                [[ $probe_rc -eq 0 ]] || continue
                candidates="$candidates $candidate"
                ;;
        esac
    done
    for part in $lvm_parts; do
        pvs_json=$(pvs --reportformat json -o pv_name,vg_name,vg_uuid "$part" 2>/dev/null) || { lvm_activation_failed=1; continue; }
        rootpxe_lvm_json_jq -e '(.report|type == "array" and length == 1 and ((.[0].pv? // [])|type == "array") and all((.[0].pv? // [])[]; (.pv_name|type == "string") and (.vg_name|type == "string") and (.vg_uuid|type == "string")))' <<<"$pvs_json" >/dev/null || { lvm_activation_failed=1; continue; }
        pv_rows=$(mktemp /tmp/rootpxe-linux-pvs.XXXXXX) || { lvm_activation_failed=1; continue; }
        if ! rootpxe_lvm_json_jq -r --arg part "$part" '.report[0].pv[] | select(.pv_name == $part) | [.pv_name,.vg_name,.vg_uuid] | @tsv' <<<"$pvs_json" >"$pv_rows"; then
            rm -f -- "$pv_rows"; lvm_activation_failed=1; continue
        fi
        while IFS=$'\t' read -r pv vg_name vg_uuid; do
            pv=$(rootpxe_lvm_trim "$pv"); vg_name=$(rootpxe_lvm_trim "$vg_name"); vg_uuid=$(rootpxe_lvm_trim "$vg_uuid")
            [[ -n $pv && -n $vg_name && -n $vg_uuid ]] || continue
            [[ $pv == "$part" ]] || continue
            case " $seen_vgs " in *" $vg_uuid "*) continue ;; esac
            seen_vgs="$seen_vgs $vg_uuid"
            activation=$(rootpxe_linux_activate_vg_if_needed "$disk" "$vg_name" "$vg_uuid")
            case $? in
                0) ;;
                2) cross_disk_lvm=1; continue ;;
                *) lvm_activation_failed=1; continue ;;
            esac
            [[ $activation == yes ]] && activated_vgs="$activated_vgs $vg_name|$vg_uuid"
            lvs_rows=$(mktemp /tmp/rootpxe-linux-rootlvs.XXXXXX) || { lvm_activation_failed=1; continue; }
            rootpxe_linux_lvs_for_vg_json "$vg_name" "$vg_uuid" "$lvs_rows" || { rm -f -- "$lvs_rows"; lvm_activation_failed=1; continue; }
            while IFS=$'\t' read -r _lv_name lv _lv_active; do
                lv=$(rootpxe_lvm_trim "$lv")
                [[ -n $lv ]] || { lvm_activation_failed=1; continue; }
                fs=$(blkid -p -o value -s TYPE "$lv" 2>/dev/null) || continue
                if [[ $fs == btrfs ]]; then
                    candidate=$(rootpxe_linux_probe_root_candidate "$lv" "$fs" "$vg_name" "$vg_uuid")
                    probe_rc=$?
                    if [[ $probe_rc -eq 0 ]]; then
                        candidates="$candidates $candidate"
                        continue
                    fi
                    if [[ $probe_rc -ne 1 ]]; then probe_failed=1; continue; fi
                    subvolids=$(rootpxe_linux_btrfs_subvolume_ids "$lv")
                    enum_rc=$?
                    if [[ $enum_rc -eq 2 || $enum_rc -eq 3 ]]; then probe_failed=1; continue; fi
                    [[ $enum_rc -eq 0 ]] || continue
                    while IFS= read -r subvolid; do
                        rootpxe_linux_btrfs_subvolid_valid "$subvolid" || continue
                        candidate=$(rootpxe_linux_probe_root_candidate "$lv" "$fs" "$vg_name" "$vg_uuid" "$subvolid")
                        probe_rc=$?
                        if [[ $probe_rc -ne 0 && $probe_rc -ne 1 ]]; then probe_failed=1; continue; fi
                        [[ $probe_rc -eq 0 ]] || continue
                        candidates="$candidates $candidate"
                    done <<<"$subvolids"
                else
                    candidate=$(rootpxe_linux_probe_root_candidate "$lv" "$fs" "$vg_name" "$vg_uuid")
                    probe_rc=$?
                    if [[ $probe_rc -ne 0 && $probe_rc -ne 1 ]]; then probe_failed=1; continue; fi
                    [[ $probe_rc -eq 0 ]] || continue
                    candidates="$candidates $candidate"
                fi
            done <"$lvs_rows"
            rm -f -- "$lvs_rows"
        done <"$pv_rows"
        rm -f -- "$pv_rows"
    done
    local candidate_count=0 final_candidate="" activation
    for candidate in $candidates; do
        candidate_count=$((candidate_count + 1))
        final_candidate="$candidate"
    done
    if [[ $probe_failed -eq 1 ]]; then
        rc=24
    else
        case $candidate_count in
            1) rc=0 ;;
            0)
                if [[ $cross_disk_lvm -eq 1 ]]; then rc=22
                elif [[ $lvm_activation_failed -eq 1 ]]; then rc=23
                else rc=20
                fi
                ;;
            *) rc=21 ;;
        esac
    fi
    for activation in $activated_vgs; do
        vg_name=${activation%%|*}
        vg_uuid=${activation#*|}
        vgchange -an --select "vg_uuid=$vg_uuid" "$vg_name" >/dev/null 2>&1 || true
    done
    [[ $rc -eq 0 ]] && printf '%s\n' "$final_candidate"
    return $rc
}

rootpxe_validate_linux_hostname() {
    local name="$1"
    [[ $name =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

rootpxe_apply_linux_hostname_for_disk() {
    local disk="$1" root_spec root_device root_fs root_lvm_name root_lvm_uuid root_subvolid root_lvm_activated=no rc mountpoint=/linuxroot options
    local hostname_path hosts_path old_hostname actual_hostname hosts_tmp expected_hash actual_hash hostname_exists=0
    [[ ${changeHostname:-false} == true ]] || return 0
    rootpxe_validate_linux_hostname "${hostName:-}" || handleError "PXEOS_STAGE=customizing_hostname CODE=INVALID_LINUX_HOSTNAME REASON=linux_name_policy"
    root_spec=$(rootpxe_find_linux_root_filesystem "$disk")
    rc=$?
    case $rc in
        0) ;;
        20) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_NOT_FOUND" ;;
        21) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_AMBIGUOUS" ;;
        22) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_CROSS_DISK_LVM" ;;
        23) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_LVM_ACTIVATION_FAILED" ;;
        24) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED" ;;
        *) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED" ;;
    esac
    root_device=${root_spec%%|*}
    root_spec=${root_spec#*|}
    root_fs=${root_spec%%|*}
    root_spec=${root_spec#*|}
    root_lvm_name=${root_spec%%|*}
    root_spec=${root_spec#*|}
    root_lvm_uuid=${root_spec%%|*}
    root_subvolid=${root_spec#*|}
    [[ -n $root_device && -n $root_fs && $root_spec == *"|"* ]] || handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED"
    [[ $root_fs != btrfs || $root_subvolid =~ ^[1-9][0-9]*$ ]] || handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED"
    if [[ -n $root_lvm_name || -n $root_lvm_uuid ]]; then
        [[ -n $root_lvm_name && -n $root_lvm_uuid ]] || handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED"
        root_lvm_activated=$(rootpxe_linux_activate_vg_if_needed "$disk" "$root_lvm_name" "$root_lvm_uuid")
        case $? in
            0) ;;
            2) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_CROSS_DISK_LVM" ;;
            *) handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_LVM_ACTIVATION_FAILED" ;;
        esac
    fi
    rootpxe_stage customizing_hostname "code=HOSTNAME_STARTED method=linux"
    mkdir -p "$mountpoint" || handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_MOUNTPOINT_FAILED"
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" >/dev/null 2>&1 || { rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED"; }
    fi
    options=$(rootpxe_linux_mount_options rw "$root_fs" "$root_subvolid") || handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED"
    mount -t "$root_fs" -o "$options" "$root_device" "$mountpoint" >/tmp/rootpxe-linux-mount-output 2>&1 || { rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_MOUNT_FAILED"; }
    rootpxe_linux_paths_safe_for_write "$mountpoint" || { umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_PATH_UNSAFE"; }
    hostname_path="$mountpoint/etc/hostname"
    hosts_path="$mountpoint/etc/hosts"
    old_hostname=""
    if [[ -f $hostname_path ]]; then
        hostname_exists=1
        old_hostname=$(head -n 1 "$hostname_path" 2>/dev/null | tr -d '\r\n')
    fi
    printf '%s\n' "$hostName" >"$hostname_path" || { umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTNAME_WRITE_FAILED"; }
    if [[ $hostname_exists -eq 0 ]]; then
        chmod 0644 "$hostname_path" && chown root:root "$hostname_path" || { umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTNAME_MODE_FAILED"; }
    fi
    actual_hostname=$(cat "$hostname_path" 2>/dev/null | tr -d '\r\n')
    [[ $actual_hostname == "$hostName" ]] || { umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTNAME_READBACK_FAILED"; }
    if [[ -n $old_hostname && -f $hosts_path ]]; then
        hosts_tmp=$(mktemp "$mountpoint/etc/.hosts.rootpxe.XXXXXX") || { umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTS_TEMP_FAILED"; }
        awk -v old="$old_hostname" -v new="$hostName" '
            function replace_tokens(prefix, out, token, ch, in_token, i) {
                out=""; token=""; in_token=0
                for (i=1; i<=length(prefix); i++) {
                    ch=substr(prefix, i, 1)
                    if (ch ~ /[[:space:]]/) {
                        if (in_token) { out=out ((token == old) ? new : token); token=""; in_token=0 }
                        out=out ch
                    } else { token=token ch; in_token=1 }
                }
                if (in_token) out=out ((token == old) ? new : token)
                return out
            }
            /^[[:space:]]*#/ { print; next }
            {
                hash=index($0, "#")
                if (hash > 0) { prefix=substr($0, 1, hash - 1); comment=substr($0, hash) }
                else { prefix=$0; comment="" }
                print replace_tokens(prefix) comment
            }
        ' "$hosts_path" >"$hosts_tmp" || { rm -f "$hosts_tmp"; umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTS_RENDER_FAILED"; }
        expected_hash=$(sha256sum "$hosts_tmp" | awk '{print $1}')
        cat "$hosts_tmp" >"$hosts_path" || { rm -f "$hosts_tmp"; umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTS_WRITE_FAILED"; }
        actual_hash=$(sha256sum "$hosts_path" | awk '{print $1}')
        rm -f "$hosts_tmp"
        [[ -n $expected_hash && $expected_hash == "$actual_hash" ]] || { umount "$mountpoint" >/dev/null 2>&1 || true; rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_HOSTS_READBACK_FAILED"; }
    fi
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" >/dev/null 2>&1 || { rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"; handleError "PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_PROBE_FAILED"; }
    fi
    rootpxe_linux_cleanup_selected_vg "$root_lvm_name" "$root_lvm_uuid" "$root_lvm_activated"
    rootpxe_stage customizing_hostname "code=HOSTNAME_COMPLETE method=linux"
}

# Common deploy-time hostname dispatcher.  The task always supplies the latest
# hostName/changeHostname on each checkin, including a hostname-only retry.
rootpxe_apply_hostname_for_disk() {
    case ${osid:-} in
        50) rootpxe_apply_linux_hostname_for_disk "$1" ;;
        [1-2]|4|[5-7]|9|10|11) rootpxe_apply_windows_hostname_for_disk "$1" ;;
        *) return 0 ;;
    esac
}

rootpxe_apply_windows_hostname_for_disk() {
    local disk="$1" system_part rc
    system_part=$(rootpxe_find_windows_system_partition "$disk")
    rc=$?
    case $rc in
        0) rootpxe_apply_windows_hostname "$system_part" ;;
        10) handleError "PXEOS_STAGE=customizing_hostname CODE=WINDOWS_SYSTEM_PARTITION_NOT_FOUND" ;;
        11) handleError "PXEOS_STAGE=customizing_hostname CODE=WINDOWS_SYSTEM_PARTITION_AMBIGUOUS" ;;
        *) handleError "PXEOS_STAGE=customizing_hostname CODE=WINDOWS_SYSTEM_PARTITION_PROBE_FAILED" ;;
    esac
}

# Changes Windows hostname after restore and before the post-deploy script. The fixed
# Sysprep path is authoritative; registry fallback is allowed only if it does
# not exist, never after malformed/ambiguous XML.
rootpxe_apply_windows_hostname() {
    local part="$1" unattend count component_count xml_path
    [[ ${changeHostname:-false} == true ]] || return 0
    [[ -n ${hostName:-} && $hostName =~ ^[A-Za-z0-9-]{1,15}$ && ! $hostName =~ ^[0-9]+$ ]] || handleError "PXEOS_STAGE=customizing_hostname CODE=INVALID_HOSTNAME REASON=windows_name_policy"
    rootpxe_stage customizing_hostname "code=HOSTNAME_STARTED"
    mkdir -p /ntfs || handleError "PXEOS_STAGE=customizing_hostname CODE=NTFS_MOUNTPOINT_FAILED"
    umount /ntfs >/dev/null 2>&1 || true
    ntfs-3g -o remove_hiberfile,rw "$part" /ntfs >/tmp/ntfs-mount-output 2>&1 || handleError "PXEOS_STAGE=customizing_hostname CODE=NTFS_MOUNT_FAILED REASON=unable_to_mount_windows"
    # Fixed logical Windows path only.  Do not search arbitrary unattend files.
    xml_path=/ntfs/Windows/System32/Sysprep/unattend.xml
    [[ -f $xml_path ]] || xml_path=""
    if [[ -z $xml_path ]]; then
        umount /ntfs >/dev/null 2>&1 || true
        rootpxe_change_hostname_registry "$part" || handleError "PXEOS_STAGE=customizing_hostname CODE=REGISTRY_WRITE_FAILED"
        rootpxe_stage customizing_hostname "code=HOSTNAME_COMPLETE method=registry"
        return 0
    fi
    command -v xmlstarlet >/dev/null 2>&1 || handleError "PXEOS_STAGE=customizing_hostname CODE=XMLSTARLET_UNAVAILABLE"
    count=$(xmlstarlet sel -t -v "count(/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName'])" "$xml_path" 2>/dev/null) || handleError "PXEOS_STAGE=customizing_hostname CODE=UNATTEND_XML_INVALID"
    component_count=$(xmlstarlet sel -t -v "count(/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup'])" "$xml_path" 2>/dev/null) || handleError "PXEOS_STAGE=customizing_hostname CODE=UNATTEND_XML_INVALID"
    [[ $count =~ ^[0-9]+$ && $component_count =~ ^[0-9]+$ && $component_count -eq 1 && $count -le 1 ]] || handleError "PXEOS_STAGE=customizing_hostname CODE=UNATTEND_COMPONENT_AMBIGUOUS"
    if [[ $count -eq 1 ]]; then
        xmlstarlet ed -L -u "/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName']" -v "$hostName" "$xml_path" >/dev/null 2>&1 || handleError "PXEOS_STAGE=customizing_hostname CODE=UNATTEND_WRITE_FAILED"
    else
        xmlstarlet ed -L -N u='urn:schemas-microsoft-com:unattend' -s "/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']" -t elem -n u:ComputerName -v "$hostName" "$xml_path" >/dev/null 2>&1 || handleError "PXEOS_STAGE=customizing_hostname CODE=UNATTEND_WRITE_FAILED"
    fi
    [[ $(xmlstarlet sel -t -v "string(/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName'])" "$xml_path" 2>/dev/null) == "$hostName" ]] || handleError "PXEOS_STAGE=customizing_hostname CODE=UNATTEND_READBACK_FAILED"
    umount /ntfs >/dev/null 2>&1 || true
    rootpxe_stage customizing_hostname "code=HOSTNAME_COMPLETE method=unattend"
}

# Registry fallback used only when the fixed Sysprep unattend file is absent.
rootpxe_change_hostname_registry() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ ${changeHostname:-false} != true || -z ${hostName:-} ]] && return
    local hostname="$hostName"
    REG_HOSTNAME_KEY1="\ControlSet001\Services\Tcpip\Parameters\NV Hostname"
    REG_HOSTNAME_KEY2="\ControlSet001\Services\Tcpip\Parameters\Hostname"
    REG_HOSTNAME_KEY3="\ControlSet001\Services\Tcpip\Parameters\NV HostName"
    REG_HOSTNAME_KEY4="\ControlSet001\Services\Tcpip\Parameters\HostName"
    REG_HOSTNAME_KEY5="\ControlSet001\Control\ComputerName\ActiveComputerName\ComputerName"
    REG_HOSTNAME_KEY6="\ControlSet001\Control\ComputerName\ComputerName\ComputerName"
    REG_HOSTNAME_KEY7="\ControlSet001\services\Tcpip\Parameters\NV Hostname"
    REG_HOSTNAME_KEY8="\ControlSet001\services\Tcpip\Parameters\Hostname"
    REG_HOSTNAME_KEY9="\ControlSet001\services\Tcpip\Parameters\NV HostName"
    REG_HOSTNAME_KEY10="\ControlSet001\services\Tcpip\Parameters\HostName"
    REG_HOSTNAME_KEY11="\CurrentControlSet\Services\Tcpip\Parameters\NV Hostname"
    REG_HOSTNAME_KEY12="\CurrentControlSet\Services\Tcpip\Parameters\Hostname"
    REG_HOSTNAME_KEY13="\CurrentControlSet\Services\Tcpip\Parameters\NV HostName"
    REG_HOSTNAME_KEY14="\CurrentControlSet\Services\Tcpip\Parameters\HostName"
    REG_HOSTNAME_KEY15="\CurrentControlSet\Control\ComputerName\ActiveComputerName\ComputerName"
    REG_HOSTNAME_KEY16="\CurrentControlSet\Control\ComputerName\ComputerName\ComputerName"
    REG_HOSTNAME_KEY17="\CurrentControlSet\services\Tcpip\Parameters\NV Hostname"
    REG_HOSTNAME_KEY18="\CurrentControlSet\services\Tcpip\Parameters\Hostname"
    REG_HOSTNAME_KEY19="\CurrentControlSet\services\Tcpip\Parameters\NV HostName"
    REG_HOSTNAME_KEY20="\CurrentControlSet\services\Tcpip\Parameters\HostName"
    dots "Mounting directory"
    if [[ ! -d /ntfs ]]; then
        mkdir -p /ntfs >/dev/null 2>&1
        if [[ ! $? -eq 0 ]]; then
            echo "Failed"
            debugPause
                    handleError "Could not create mount location (${FUNCNAME[0]})\n    Args Passed: $*"
        fi
    fi
    umount /ntfs >/dev/null 2>&1
    ntfs-3g -o remove_hiberfile,rw $part /ntfs >/tmp/ntfs-mount-output 2>&1
    case $? in
        0)
            echo "Done"
            debugPause
            ;;
        *)
            echo "Failed"
            debugPause
                    handleError "Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
            ;;
    esac
    if [[ ! -f /usr/share/pxeos/lib/EOFREG ]]; then
        key1="$REG_HOSTNAME_KEY1"
        key2="$REG_HOSTNAME_KEY2"
        key3="$REG_HOSTNAME_KEY3"
        key4="$REG_HOSTNAME_KEY4"
        key5="$REG_HOSTNAME_KEY5"
        key6="$REG_HOSTNAME_KEY6"
        key7="$REG_HOSTNAME_KEY7"
        key8="$REG_HOSTNAME_KEY8"
        key9="$REG_HOSTNAME_KEY9"
        key10="$REG_HOSTNAME_KEY10"
        key11="$REG_HOSTNAME_KEY11"
        key12="$REG_HOSTNAME_KEY12"
        key13="$REG_HOSTNAME_KEY13"
        key14="$REG_HOSTNAME_KEY14"
        key15="$REG_HOSTNAME_KEY15"
        key16="$REG_HOSTNAME_KEY16"
        key17="$REG_HOSTNAME_KEY17"
        key18="$REG_HOSTNAME_KEY18"
        key19="$REG_HOSTNAME_KEY19"
        key20="$REG_HOSTNAME_KEY20"
        case $osid in
            1)
                regfile="$REG_LOCAL_MACHINE_XP"
                ;;
            2|4|[5-7]|9|10|11)
                regfile="$REG_LOCAL_MACHINE_7"
                ;;
        esac
        echo "ed $key1" >/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key2" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key3" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key4" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key5" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key6" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key7" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key8" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key9" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key10" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key11" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key12" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key13" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key14" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key15" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key16" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key17" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key18" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key19" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "ed $key20" >>/usr/share/pxeos/lib/EOFREG
        echo "$hostname" >>/usr/share/pxeos/lib/EOFREG
        echo "q" >> /usr/share/pxeos/lib/EOFREG
        echo "y" >> /usr/share/pxeos/lib/EOFREG
        echo >> /usr/share/pxeos/lib/EOFREG
    fi
    if [[ -e $regfile ]]; then
        dots "Changing hostname"
        reged -e $regfile < /usr/share/pxeos/lib/EOFREG >/dev/null 2>&1
        case $? in
            [0-2])
                echo "Done"
                debugPause
                ;;
            *)
                echo "Failed"
                debugPause
                umount /ntfs >/dev/null 2>&1
                rootpxe_console_message WARN 'Failed to change hostname.'
                return
                ;;
        esac
    fi
    rm -rf /usr/share/pxeos/lib/EOFREG
    umount /ntfs >/dev/null 2>&1
}
# Fixes windows 7/8 boot, though may need
#    to be updated to only impact windows 7
#    in which case we need a more dynamic method
#
# $1 is the partition
fixWin7boot() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ $osid != [5-7] ]] && return
    local fstype=""
    fsTypeSetting "$part"
    [[ $fstype != ntfs ]] && return
    dots "Mounting partition"
    if [[ ! -d /bcdstore ]]; then
        mkdir -p /bcdstore >/dev/null 2>&1
        case $? in
            0)
                ;;
            *)
                echo "Failed"
                debugPause
                    handleError "Could not create mount location (${FUNCNAME[0]})\n    Args Passed: $*"
                ;;
        esac
    fi
    ntfs-3g -o remove_hiberfile,rw $part /bcdstore >/tmp/ntfs-mount-output 2>&1
    case $? in
        0)
            echo "Done"
            debugPause
            ;;
        *)
            echo "Failed"
            debugPause
                    handleError "Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
            ;;
    esac
    if [[ ! -f /bcdstore/Boot/BCD ]]; then
        umount /bcdstore >/dev/null 2>&1
        return
    fi
    dots "Backing up and replacing BCD"
    mv /bcdstore/Boot/BCD{,.bak} >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            umount /bcdstore >/dev/null 2>&1
            rootpxe_console_message WARN 'Could not create backup.'
            return
            ;;
    esac
    cp /usr/share/pxeos/BCD /bcdstore/Boot/BCD >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            debugPause
            umount /bcdstore >/dev/null 2>&1
            ;;
        *)
            echo "Failed"
            debugPause
            umount /bcdstore >/dev/null 2>&1
            rootpxe_console_message WARN 'Could not copy the BCD file.'
            return
            ;;
    esac
    umount /bcdstore >/dev/null 2>&1
}
# Clears out windows hiber and page files
#
# $1 is the partition
clearMountedDevices() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ ! -d /ntfs ]]; then
        mkdir -p /ntfs >/dev/null 2>&1
        case $? in
            0)
                umount /ntfs >/dev/null 2>&1
                ;;
            *)
                handleError "Could not create mount point /ntfs (${FUNCNAME[0]})\n   Args Passed: $*"
                ;;
        esac
    fi
    case $osid in
        4|[5-7]|9|10|11)
            local fstype=""
            fsTypeSetting "$part"
            REG_HOSTNAME_MOUNTED_DEVICES_7="\MountedDevices"
            if [[ ! -f /usr/share/pxeos/lib/EOFMOUNT ]]; then
                echo "cd $REG_HOSTNAME_MOUNTED_DEVICES_7" >/usr/share/pxeos/lib/EOFMOUNT
                echo "dellallv" >>/usr/share/pxeos/lib/EOFMOUNT
                echo "q" >>/usr/share/pxeos/lib/EOFMOUNT
                echo "y" >>/usr/share/pxeos/lib/EOFMOUNT
                echo >> /usr/share/pxeos/lib/EOFMOUNT
            fi
            case $fstype in
                ntfs)
                    dots "Clearing part ($part)"
                    ntfs-3g -o remove_hiberfile,rw $part /ntfs >/tmp/ntfs-mount-output 2>&1
                    case $? in
                        0)
                            ;;
                        *)
                            echo "Failed"
                            debugPause
                            handleError "Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
                            ;;
                    esac
                    if [[ ! -f $REG_LOCAL_MACHINE_7 ]]; then
                        echo "Skipped"
                        rootpxe_console_message WARN 'Registry file was not found.'
                        debugPause
                        umount /ntfs >/dev/null 2>&1
                        return
                    fi
                    reged -e $REG_LOCAL_MACHINE_7 </usr/share/pxeos/lib/EOFMOUNT >/dev/null 2>&1
                    case $? in
                        [0-2])
                            echo "Done"
                            debugPause
                            umount /ntfs >/dev/null 2>&1
                            ;;
                        *)
                            echo "Failed"
                            debugPause
                            /umount /ntfs >/dev/null 2>&1
                            rootpxe_console_message WARN "Could not clear partition $part."
                            return
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
}
# Only removes the page file
#
# $1 is the device name of the windows system partition
removePageFile() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local fstype=""
    fsTypeSetting "$part"
    [[ ! $ignorepg -eq 1 ]] && return
    case $osid in
        [1-2]|4|[5-7]|9|10|11|50|51)
            case $fstype in
                ntfs)
                    dots "Mounting partition ($part)"
                    if [[ ! -d /ntfs ]]; then
                        mkdir -p /ntfs >/dev/null 2>&1
                        case $? in
                            0)
                                ;;
                            *)
                                echo "Failed"
                                debugPause
                                handleError "Could not create mount location (${FUNCNAME[0]})\n    Args Passed: $*"
                                ;;
                        esac
                    fi
                    umount /ntfs >/dev/null 2>&1
                    ntfs-3g -o remove_hiberfile,rw $part /ntfs >/tmp/ntfs-mount-output 2>&1
                    case $? in
                        0)
                            echo "Done"
                            debugPause
                            ;;
                        *)
                            echo "Failed"
                            debugPause
                                handleError "Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
                            ;;
                    esac
                    if [[ -f /ntfs/pagefile.sys ]]; then
                        dots "Removing page file"
                        rm -rf /ntfs/pagefile.sys >/dev/null 2>&1
                        case $? in
                            0)
                                echo "Done"
                                debugPause
                                ;;
                            *)
                                echo "Failed"
                                debugPause
                                rootpxe_console_message WARN 'Could not delete the page file.'
                                ;;
                        esac
                    fi
                    if [[ -f /ntfs/hiberfil.sys ]]; then
                        dots "Removing hibernate file"
                        rm -rf /ntfs/hiberfil.sys >/dev/null 2>&1
                        case $? in
                            0)
                                echo "Done"
                                debugPause
                                ;;
                            *)
                                echo "Failed"
                                debugPause
                                umount /ntfs >/dev/null 2>&1
                                rootpxe_console_message WARN 'Could not delete the hibernation file.'
                                ;;
                        esac
                    fi
                    umount /ntfs >/dev/null 2>&1
                    ;;
            esac
            ;;
    esac
}
# Sets OS mbr, as needed, and returns the Name
#    based on the OS id passed.
#
# $1 the osid to determine the os and mbr
determineOS() {
    local osid="$1"
    [[ -z $osid ]] && handleError "No os id passed (${FUNCNAME[0]})\n   Args Passed: $*"
    case $osid in
        1)
            osname="Windows XP"
            mbrfile="/usr/share/pxeos/mbr/xp.mbr"
            ;;
        2)
            osname="Windows Vista"
            mbrfile="/usr/share/pxeos/mbr/vista.mbr"
            ;;
        3)
            osname="Windows 98"
            mbrfile=""
            ;;
        4)
            osname="Windows (Other)"
            mbrfile=""
            ;;
        5)
            osname="Windows 7"
            mbrfile="/usr/share/pxeos/mbr/win7.mbr"
            defaultpart2start="206848s"
            ;;
        6)
            osname="Windows 8"
            mbrfile="/usr/share/pxeos/mbr/win8.mbr"
            defaultpart2start="718848s"
            ;;
        7)
            osname="Windows 8.1"
            mbrfile="/usr/share/pxeos/mbr/win8.mbr"
            defaultpart2start="718848s"
            ;;
        8)
            osname="Apple Mac OS"
            mbrfile=""
            ;;
        9)
            osname="Windows 10"
            mbrfile=""
            ;;
        10)
            osname="Windows 11"
            mbrfile=""
            ;;
        11)
            osname="Windows Server"
            mbrfile=""
            ;;
        50)
            osname="Linux"
            mbrfile=""
            ;;
        51)
            osname="Chromium OS"
            mbrfile=""
            ;;
        99)
            osname="Other OS"
            mbrfile=""
            ;;
        *)
            handleError "Invalid OS ID: $osid (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
}
# Converts the string (seconds) passed to human understanding
#
# $1 the seconds to convert
sec2string() {
    local T="$1"
    [[ -z $T ]] && handleError "No string passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local d=$((T/60/60/24))
    local H=$((T/60/60%24))
    local i=$((T/60%60))
    local s=$((T%60))
    local dayspace=''
    local hourspace=''
    local minspace=''
    [[ $H > 0 ]] && dayspace=' '
    [[ $i > 0 ]] && hourspace=':'
    [[ $s > 0 ]] && minspace=':'
    (($d > 0)) && printf '%d day%s' "$d" "$dayspace"
    (($H > 0)) && printf '%d%s' "$H" "$hourspace"
    (($i > 0)) && printf '%d%s' "$i" "$minspace"
    (($s > 0)) && printf '%d' "$s"
}
# Returns the disk based off the partition passed
#
# $1 is the partition to grab the disk from
getDiskFromPartition() {
    local part="$1"
    local israw="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $israw -eq 1 ]]; then
        disk=$part
        return
    fi
    part=${part#/dev/}
    disk=$(readlink /sys/class/block/$part)
    disk=${disk%/*}
    disk=/dev/${disk##*/}
}
# Returns the number of the partition passed
#
# $1 is the partition to get the partition number for
getPartitionNumber() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    part_number=$(echo $part | grep -o '[0-9]*$')
}
# $1 is the partition to search for.
getPartitions() {
    local disk="$1"
    [[ -z $disk ]] && disk="$hd"
    [[ -z $disk ]] && handleError "No disk found (${FUNCNAME[0]})\n   Args Passed: $*"
    parts=$(lsblk -I 3,8,9,179,202,253,259 -lpno KNAME,TYPE $disk | awk '{if ($2 ~ /part/ || $2 ~ /md/) print $1}' | sort -V | uniq)
}
normalize() {
    local input="$*"

    # If no arguments, read from stdin
    if [[ $# -eq 0 ]]; then
        input=$(cat)
    fi

    echo $(trim "$input" | xargs | tr '[:upper:]' '[:lower:]')
}
resolve_path() {
    local input="$*"

    # If no arguments, read from stdin
    if [[ $# -eq 0 ]]; then
        input=$(cat)
    fi

    echo $(readlink -f "$input" 2>/dev/null || echo "$input")
}
# Gets the hard drive on the host
# Note: This function makes a best guess
getHardDisk() {
    hd=""
    disks=""

    # Get valid devices (filter out 0B disks) once, keeping lsblk enumeration order
    local devs
    devs=$(lsblk -dpno KNAME,SIZE -I 3,8,9,179,202,253,259 | awk '$2 != "0B" && !seen[$1]++ { print $1 }')

    if [[ -n ${fdrive:-} && ( ${imgType:-} != mpa || ${type:-} != down ) ]]; then
        local found_match=0
        for spec in ${fdrive//,/ }; do
            local spec_resolved spec_norm spec_normalized matched
            spec_resolved=$(resolve_path "$spec")
            spec_normalized=$(normalize "$spec")
            matched=0

            for dev in $devs; do
                local size uuid serial wwn
                size=$(blockdev --getsize64 "$dev" | normalize)
                uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null | normalize)
                # Grab SERIAL and WWN safely (handles blanks and spacing)
                local kv serial_raw wwn_raw
                kv="$(lsblk -pdPno SERIAL,WWN "$dev" 2>/dev/null)" || kv=""
                serial_raw="$(sed -n 's/.*SERIAL="\([^"]*\)".*/\1/p' <<<"$kv")"
                wwn_raw="$(sed -n 's/.*WWN="\([^"]*\)".*/\1/p' <<<"$kv")"

                serial="$(normalize "$serial_raw")"
                wwn="$(normalize "$wwn_raw")"

                [[ -n $isdebug ]] && {
                    debugEcho "Comparing spec=$spec (resolved: $spec_resolved) with dev=$dev."
                    debugEcho "size=$size serial=$serial wwn=$wwn uuid=$uuid"
                }
                if [[ "x$spec_resolved" == "x$dev" || \
                      "x$spec_normalized" == "x$size" || \
                      "x$spec_normalized" == "x$wwn" || \
                      "x$spec_normalized" == "x$serial" || \
                      "x$spec_normalized" == "x$uuid" ]]; then
                    [[ -n $isdebug ]] && debugEcho "Matched spec $spec to device $dev (size=$size, serial=$serial, wwn=$wwn, uuid=$uuid)."
                    matched=1
                    found_match=1
                    disks="$disks $dev"
                    # remove matched dev from the pool
                    devs="$(echo " $devs " | sed "s# $dev # #g; s/^ *//; s/ *$//")"
                    break
                fi
            done

            [[ $matched -eq 0 ]] && rootpxe_console_message WARN "Drive spec $spec does not match any available device." >&2
        done

        [[ $found_match -eq 0 ]] && handleError "Fatal: No valid drives found for 'Host Primary Disk'='$fdrive'."

        disks=$(echo "$disks $devs" | xargs)   # add unmatched devices for completeness

    elif [[ "x$imgType" == "xmpa" && "x$type" == "xdown" ]]; then
        # mpa target selection is a positional image-to-device binding, never
        # a best-effort inventory enumeration.  Every captured disk requires
        # a continuous size fact and its own partition-table inputs before a
        # permit can be requested.
        local -a expected_sizes=() actual_disks=() mapped=()
        local facts number exp expected_number=1 d match candidates used=" " spec spec_resolved requested=0 selected_index candidate_index candidate_size candidate_uuid candidate_kv candidate_serial candidate_wwn selector_matches
        facts=$(rootpxe_fixed_restore_disk_facts "$imagePath") || { handleError 'MPA deployment has missing, invalid, or ambiguous disk inventory metadata.'; return 1; }
        while IFS='|' read -r number exp; do
            [[ $number == "$expected_number" && $exp =~ ^[1-9][0-9]*$ && -s ${imagePath}/d${number}.mbr ]] || { handleError "MPA deployment is missing complete partition-table metadata for disk ${expected_number}."; return 1; }
            expected_sizes+=("$exp")
            expected_number=$((expected_number + 1))
        done <<<"$facts"
        (( ${#expected_sizes[@]} > 0 )) || { handleError 'MPA deployment has no target disk facts.'; return 1; }
        for d in $devs; do actual_disks+=("$d"); done
        for exp in "${expected_sizes[@]}"; do
            match=""; candidates=0
            for d in "${actual_disks[@]}"; do
                [[ $used == *" $d "* ]] && continue
                if [[ $(blockdev --getsize64 "$d" 2>/dev/null) == "$exp" ]]; then
                    match="$d"; candidates=$((candidates + 1))
                fi
            done
            [[ $candidates -eq 1 ]] || { handleError "Could not uniquely match disk for expected size $exp (mpa deployment requires one exact target per captured disk)."; return 1; }
            mapped+=("$match"); used+=" $match "
        done
        disks="${mapped[*]}"
        hd="${mapped[0]}"
        # fdrive may narrow the leading positions of the already-proven mpa
        # mapping.  It cannot append a device, reorder an image position, or
        # turn an unproven size/identity into a target selection.
        if [[ -n ${fdrive:-} ]]; then
            for spec in ${fdrive//,/ }; do
                spec_resolved=$(resolve_path "$spec")
                selector_matches=0; selected_index=-1
                for candidate_index in "${!mapped[@]}"; do
                    d=${mapped[$candidate_index]}
                    candidate_size=$(normalize "$(blockdev --getsize64 "$d" 2>/dev/null)")
                    candidate_uuid=$(normalize "$(blkid -s UUID -o value "$d" 2>/dev/null)")
                    candidate_kv=$(lsblk -pdPno SERIAL,WWN "$d" 2>/dev/null || :)
                    candidate_serial=$(normalize "$(sed -n 's/.*SERIAL="\([^"]*\)".*/\1/p' <<<"$candidate_kv")")
                    candidate_wwn=$(normalize "$(sed -n 's/.*WWN="\([^"]*\)".*/\1/p' <<<"$candidate_kv")")
                    if [[ $spec_resolved == "$d" || $(normalize "$spec") == "$candidate_size" || $(normalize "$spec") == "$candidate_uuid" || $(normalize "$spec") == "$candidate_serial" || $(normalize "$spec") == "$candidate_wwn" ]]; then
                        selector_matches=$((selector_matches + 1)); selected_index=$candidate_index
                    fi
                done
                [[ $selector_matches -eq 1 && $selected_index -eq $requested ]] || { handleError "MPA Host Primary Disk selector does not match the mapped disk order: $spec."; return 1; }
                requested=$((requested + 1))
            done
            [[ $requested -le ${#mapped[@]} ]] || { handleError 'MPA Host Primary Disk selector has too many mapped targets.'; return 1; }
        fi
        return 0
    else
        if [[ -n $largesize ]]; then
            # Auto-select largest available drive
            hd=$(
                for d in $devs; do
                    echo "$(blockdev --getsize64 "$d") $d"
                done | sort -k1,1nr -k2,2 | head -1 | cut -d' ' -f2
            )
        else
            for d in $devs; do
                hd="$d"
                break
            done
        fi
        [[ -z $hd ]] && handleError "Could not determine a suitable disk automatically."
        disks="$hd"
    fi

    # Set primary hard disk
    hd=$(awk '{print $1}' <<< "$disks")
}

# Finds the hard drive info and set's up the type
findHDDInfo() {
    dots "Looking for disk device(s)"
    getHardDisk
    if [[ -z $hd || -z $disks ]]; then
        echo "Failed"
        debugPause
        handleError "Could not find hard disk ($0)\n   Args Passed: $*"
    fi
    echo "Done"
    debugPause
    case $imgType in
        [Nn]|mps|dd)
            case $type in
                down)
                    diskSize=$(lsblk --bytes -dplno SIZE -I 3,8,9,179,259 $hd)
                    [[ $diskSize -gt 2199023255552 ]] && layPartSize="2tB"
                    rootpxe_console_message INFO "Using disk device: $hd."
                    [[ $imgType == +([nN]) ]] && validResizeOS
                    enableWriteCache "$hd"
                    ;;
                up)
                    dots "Reading Partition Tables"
                    if [[ $imgType == "dd" ]]; then
                        echo "Skipped"
                    else
                        runPartprobe "$hd"
                        getPartitions "$hd"
                        if [[ -z $parts ]]; then
                            echo "Failed"
                            debugPause
                            handleError "Could not find partitions ($0)\n    Args Passed: $*"
                        fi
                        echo "Done"
                    fi
                    debugPause
                    ;;
            esac
            rootpxe_console_message INFO "Using disk device: $hd."
            ;;
        mpa)
            case $type in
                up)
                    for disk in $disks; do
                        dots "Reading partition tables on disk device $disk"
                        getPartitions "$disk"
                        if [[ -z $parts ]]; then
                            echo "Failed"
                            debugPause
                            rootpxe_console_message WARN "No partitions found for disk device: $disk."
                            debugPause
                            continue
                        fi
                        echo "Done"
                        debugPause
                    done
                    ;;
            esac
            rootpxe_console_message INFO "Using disk devices: $disks."
            ;;
    esac
}

# Imaging complete
completeTasking() {
    case $type in
        up)
            rootpxe_stage upload_complete "capture write finished, notifying server"
            chmod -R 775 "$imagePath" >/dev/null 2>&1 || handleError "PXEOS_STAGE=capture_finalize CODE=CAPTURE_ARTIFACT_PERMISSION_FAILED REASON=unable_to_finalize_storage_artifacts"
            killStatusReporter
            . /bin/pxeos.imgcomplete
            ;;
        down)
            rootpxe_stage restore "deploy write finished, running completion"
            killStatusReporter
            [[ $capone -eq 1 ]] && exit 0
            [[ ${changeHostname:-false} == true ]] && rootpxe_apply_hostname_for_disk "$hd"
            rootpxe_run_post_deploy_script || handleError "PXEOS_STAGE=post_deploy_script CODE=POST_DEPLOY_SCRIPT_FAILED REASON=${rootpxe_deploy_script_error:-unknown}"
            . /bin/pxeos.imgcomplete
            ;;
    esac
}
# Corrects mbr layout for Vista OS
#
# $1 is the disk to correct for
correctVistaMBR() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    dots "Correcting Vista MBR"
    dd if=$disk of=/tmp.mbr count=1 bs=512 >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not create backup (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    xxd /tmp.mbr /tmp.mbr.txt >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "xxd command failed (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    rm /tmp.mbr >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Couldn't remove /tmp.mbr file (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    fogmbrfix /tmp.mbr.txt /tmp.mbr.fix.txt >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "fogmbrfix failed to operate (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    rm /tmp.mbr.txt >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not remove the text file (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    xxd -r /tmp.mbr.fix.txt /mbr.mbr >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not run second xxd command (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    rm /tmp.mbr.fix.txt >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not remove the fix file (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    dd if=/mbr.mbr of="$disk" count=1 bs=512 >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not apply fixed MBR (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    debugPause
}
# Prints an error with visible information
#
# $1 is the string to inform what went wrong
handleError() {
    local str="$1" safe_str
    local parts=""
    local part=""
    printf '\n[ERROR] Operation failed.\n'
    printf '[INFO]  Init version: %s\n' "$initversion"
    printf '\n[INFO]  Error details:\n'
    safe_str=$(rootpxe_redact_diagnostic "$str")
    printf '%b\n' "$safe_str" | sed 's/^/        /'
    printf '\n[INFO]  Kernel variables and settings:\n'
    rootpxe_redact_diagnostic "$*" | sed 's/^/        /'
    printf '\n'
    #
    # expand the file systems in the restored partitions
    #
    # Windows 7, 8, 8.1:
    # Windows 2000/XP, Vista:
    # Linux:
    if [[ -n $2 ]]; then
        case $osid in
            [1-2]|4|[5-7]|9|10|11|50|51)
                if [[ -n "$hd" ]]; then
                    getPartitions "$hd"
                    for part in $parts; do
                        expandPartition "$part"
                    done
                fi
                ;;
        esac
    fi
    if rootpxe_require_task_context; then
        rootpxe_error_wait_for_retry "$safe_str" "PXEOS_ERROR"
        return_code=$?
        exit "$return_code"
    fi
    if [[ -z $isdebug ]]; then
        printf '[WARN]  System will reboot in 60s.\n'
        usleep 60000000
    else
        debugPause
    fi
    exit 1
}
# Prints a visible banner describing an issue but not breaking
#
# $1 The string to inform the user what the problem is
handleWarning() {
    local str="$1"
    printf '\n[WARN]  Operation warning.\n'
    printf '[INFO]  Warning details:\n'
    printf '%b\n' "$str" | sed 's/^/        /'
    printf '\n[INFO]  Continuing in 60s.\n'
    usleep 60000000
    debugPause
}
# Re-reads the partition table of the disk passed
#
# $1 is the disk
runPartprobe() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    umount /ntfs /bcdstore >/dev/null 2>&1
    udevadm settle
    blockdev --rereadpt $disk >/dev/null 2>&1
    [[ ! $? -eq 0 ]] && handleError "Failed to read back partitions (${FUNCNAME[0]})\n   Args Passed: $*"
}
# Sends a command list to a file for use when debugging
#
# $1 The string of the command needed to run.
debugCommand() {
    local str="$1"
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            echo -e "$str" >> /tmp/cmdlist
            ;;
    esac
}
# Escapes the passed item where needed
#
# $1 the item that needs to be escaped
escapeItem() {
    local item="$1"
    echo $item | sed -r 's%/%\\/%g'
}
# uploadFormat
# Description:
# Tells the system what format to upload in, whether split or not.
# Expects first argument to be the fifo to send to.
# Expects part of the filename in the case of resizable
#    will append 000 001 002 automatically
#
# $1 The fifo name (file in file out)
# $2 The file to upload into on the server
uploadFormat() {
    local fifo="$1"
    local file="$2"
    [[ -z $fifo ]] && handleError "Missing file in file out (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $file ]] && handleError "Missing file name to store (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ ! -e $fifo ]]; then
        mkfifo "$fifo" >/dev/null 2>&1 || handleError "PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_SETUP_FAILED REASON=unable_to_create_capture_fifo"
    fi
    local cores=$(nproc)
    cores=$((cores - 1))
    [[ $cores -lt 1 ]] && cores=1
    [[ ${writer_pids+x} ]] || writer_pids=()
    case $imgFormat in
        6)
            # ZSTD Split files compressed.
            ( set -o pipefail; zstdmt --rsyncable --ultra "$PIGZ_COMP" < "$fifo" | split -a 3 -d -b 200m - "${file}." ) &
            ;;
        5)
            # ZSTD compressed.
            zstdmt --rsyncable --ultra "$PIGZ_COMP" < "$fifo" > "${file}.000" &
            ;;
        4)
            # Split files uncompressed.
            ( set -o pipefail; cat "$fifo" | split -a 3 -d -b 200m - "${file}." ) &
            ;;
        3)
            # Uncompressed.
            cat "$fifo" > "${file}.000" &
            ;;
        2)
            # GZip/piGZ Split file compressed.
            ( set -o pipefail; pigz "$PIGZ_COMP" < "$fifo" | split -a 3 -d -b 200m - "${file}." ) &
            ;;
        *)
            # GZip/piGZ Compressed.
            pigz "$PIGZ_COMP" < "$fifo" > "${file}.000" &
        ;;
    esac
    rootpxe_last_writer_pid="$!"
    writer_pids+=("$rootpxe_last_writer_pid")
}

# 等待指定 capture writer 并从待等待集合移除。调用方必须在宣告分区
# 捕获成功或移动分片前调用它，避免后端存储失败被延迟或掩盖。
rootpxe_wait_for_writer() {
    local pid="$1"
    local writer_pid status=0
    local remaining=()
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    if wait "$pid"; then
        status=0
    else
        status=$?
    fi
    for writer_pid in "${writer_pids[@]:-}"; do
        [[ $writer_pid == "$pid" ]] || remaining+=("$writer_pid")
    done
    writer_pids=("${remaining[@]}")
    return "$status"
}
rootpxe_wait_for_writers() {
    [[ ${#writer_pids[@]} -gt 0 ]] || return 0
    local pid writer_status=0
    for pid in "${writer_pids[@]}"; do
        if rootpxe_wait_for_writer "$pid"; then
            :
        else
            writer_status=$?
        fi
    done
    writer_pids=()
    [[ $writer_status -eq 0 ]] || handleError "PXEOS_STAGE=capture_write CODE=CAPTURE_WRITER_FAILED REASON=storage_writer_or_compressor_failed"
}
# Thank you, fractal13 Code Base
#
# Save enough MBR and embedding area to capture all of GRUB
# Strategy is to capture EVERYTHING before the first partition.
# Then, leave a marker that this is a GRUB MBR for restoration.
# We could get away with less storage, but more details are required
# to parse the information correctly.  It would make the process
# more complicated.
#
# See the discussion about the diskboot.img and the sector list
# here: http://banane-krumm.de/bootloader/grub2.html
#
# Expects:
# the device name (e.g. /dev/sda) as the first parameter,
# the disk number (e.g. 1) as the second parameter
# the directory to store images in (e.g. /image/dev/xyz) as the third parameter
#
# $1 is the disk
# $2 is the disk number
# $3 is the image path to save the file to.
# $4 is the determinator of sgdisk use or not
saveGRUB() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local sgdisk="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    # Determine the number of sectors to copy
    # Hack Note: print $4+0 causes the column to be interpretted as a number
    #            so the comma is tossed
    local count=$(flock $disk sfdisk -d $disk 2>/dev/null | awk '/start=[ ]*[1-9]/{print $4+0}' | sort -n | head -n1)
    local has_grub=$(dd if=$disk bs=512 count=1 2>&1 | grep -i 'grub')
    local hasgrubfilename=""
    if [[ -n $has_grub ]]; then
        hasGrubFileName "$imagePath" "$disk_number" "$sgdisk"
        touch $hasgrubfilename
    fi
    # Ensure that no more than 1MiB of data is copied (already have this size used elsewhere)
    [[ $count -gt 2048 ]] && count=2048
    [[ $count -eq 8 || $count -eq 63 ]] && count=1
    local mbrfilename=""
    MBRFileName "$imagePath" "$disk_number" "mbrfilename" "$sgdisk"
    dd if=$disk of=$mbrfilename count=$count bs=512 >/dev/null 2>&1
}
# Checks for the existence of the grub embedding area in the image directory.
# Echos 1 for true, and 0 for false.
#
# Expects:
# the device name (e.g. /dev/sda) as the first parameter,
# the disk number (e.g. 1) as the second parameter
# the directory images stored in (e.g. /image/xyz) as the third parameter
# $1 is the disk
# $2 is the disk number
# $3 is the image path
# $4 is the sgdisk determinator
hasGRUB() {
    local disk_number="$1"
    local imagePath="$2"
    local sgdisk="$3"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local hasgrubfilename=""
    hasGrubFileName "$imagePath" "$disk_number" "$sgdisk"
    hasGRUB=0
    [[ -e $hasgrubfilename ]] && hasGRUB=1
}
# Restore the grub boot record and all of the embedding area data
# necessary for grub2.
#
# Expects:
# the device name (e.g. /dev/sda) as the first parameter,
# the disk number (e.g. 1) as the second parameter
# the directory images stored in (e.g. /image/xyz) as the third parameter
# $1 is the disk
# $2 is the disk number
# $3 is the image path
# $4 is the sgdisk determinator
restoreGRUB() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local sgdisk="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local tmpMBR=""
    MBRFileName "$imagePath" "$disk_number" "tmpMBR" "$sgdisk"
    local count=$(du -B 512 $tmpMBR | awk '{print $1}')
    [[ $count -eq 8 || $count -eq 63 ]] && count=1
    dd if=$tmpMBR of=$disk bs=512 count=$count >/dev/null 2>&1
    runPartprobe "$disk"
}
# Waits for enter if system is debug type
debugPause() {
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            rootpxe_console_prompt INFO "${*:-Press Enter to continue.}"
            read -r
            ;;
        *)
            return
            ;;
    esac
}
debugEcho() {
    local str="$*"
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            rootpxe_console_message INFO "$str"
            ;;
        *)
            return
            ;;
    esac
}
majorDebugEcho() {
    [[ $ismajordebug -ge 1 ]] && rootpxe_console_message INFO "$*"
}
majorDebugPause() {
    [[ ! $ismajordebug -gt 0 ]] && return
    rootpxe_console_prompt INFO "${*:-Press Enter to continue.}"
    read -r
}
swapUUIDFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    swapuuidfilename="$imagePath/d${disk_number}.original.swapuuids"
}
sfdiskPartitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sfdiskoriginalpartitionfilename="$imagePath/d${disk_number}.partitions"
}
sfdiskLegacyOriginalPartitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sfdisklegacyoriginalpartitionfilename="$imagePath/d${disk_number}.original.partitions"
}
sfdiskMinimumPartitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sfdiskminimumpartitionfilename="$imagePath/d${disk_number}.minimum.partitions"
}
sfdiskOriginalPartitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sfdiskPartitionFileName "$imagePath" "$disk_number"
}
sgdiskOriginalPartitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sgdiskoriginalpartitionfilename="$imagePath/d${disk_number}.sgdisk.original.partitions"
}
fixedSizePartitionsFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    fixed_size_file="$imagePath/d${disk_number}.fixed_size_partitions"
}
hasGrubFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local sgdisk="$3"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    hasgrubfilename="$imagePath/d${disk_number}.has_grub"
    [[ -n $sgdisk ]] && hasgrubfilename="$imagePath/d${disk_number}.grub.mbr"
}
MBRFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local varVar="$3"
    local sgdisk="$4"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $varVar ]] && handleError "No variable to set passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local mbr=""
    local hasGRUB=0
    hasGRUB "$disk_number" "$imagePath" "$sgdisk"
    [[ -n $sgdisk && $hasGRUB -eq 1 ]] && mbr="$imagePath/d${disk_number}.grub.mbr" || mbr="$imagePath/d${disk_number}.mbr"
    case $type in
        down)
            [[ ! -f $mbr && -n $mbrfile ]] && mbr="$mbrfile"
            printf -v "$varVar" "$mbr"
            [[ -z $mbr ]] && handleError "Image store corrupt, unable to locate MBR, no default file specified (${FUNCNAME[0]})\n    Args Passed: $*\n    $varVar Variable set to: ${!varVar}"
            [[ ! -f $mbr ]] && handleError "Image store corrupt, unable to locate MBR, no file found (${FUNCNAME[0]})\n    Args Passed: $*\n    Variable set to: ${!varVar}\n    $varVar Variable set to: ${!varVar}"
            ;;
        up)
            printf -v "$varVar" "$mbr"
            ;;
    esac
}
EBRFileName() {
    local path="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local part_number="$3"    # e.g. 5
    [[ -z $path ]] && handleError "No path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $part_number ]] && ebrfilename="" || ebrfilename="$path/d${disk_number}p${part_number}.ebr"
}
tmpEBRFileName() {
    local disk_number="$1"
    local part_number="$2"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $part_number ]] && handleError "No partition number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local ebrfilename=""
    EBRFileName "/tmp" "$disk_number" "$part_number"
    tmpebrfilename="$ebrfilename"
}
#
# Works for MBR/DOS or GPT style partition tables
# Only saves PT information if the type is "all" or "mbr"
#
# For MBR/DOS style PT
#   Saves the MBR as everything before the start of the first partition (512+ bytes)
#      This includes the DOS MBR or GRUB.  Don't know about other bootloaders
#      This includes the 4 primary partitions
#   The EBR of extended and logical partitions is actually the first 512 bytes of
#      the partition, so we don't need to save/restore them here.
#
#
savePartitionTablesAndBootLoaders() {
    local disk="$1"                    # e.g. /dev/sda
    local disk_number="$2"                 # e.g. 1
    local imagePath="$3"               # e.g. /net/dev/foo
    local osid="$4"                    # e.g. 50
    local imgPartitionType="$5"
    local sfdiskfilename="$6"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $osid ]] && handleError "No osid passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No img part type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ -z $sfdiskfilename ]]; then
        sfdiskPartitionFileName "$imagePath" "$disk_number"
        sfdiskfilename="$sfdiskoriginalpartitionfilename"
    fi
    local hasgpt=0
    hasGPT "$disk"
    local have_extended_partition=0  # e.g. 0 or 1-n (extended partition count)
    local strdots=""
    [[ $hasgpt -eq 0 ]] && have_extended_partition=$(flock $disk sfdisk -l $disk 2>/dev/null | egrep "^${disk}.* (Extended|W95 Ext'd \(LBA\))$" | wc -l)
    runPartprobe "$disk"
    case $hasgpt in
        0)
            strdots="Saving Partition Tables (MBR)"
            case $osid in
                4|50|51)
                    [[ $disk_number -eq 1 ]] && strdots="Saving Partition Tables and GRUB (MBR)"
                    ;;
            esac
            dots "$strdots"
            saveGRUB "$disk" "$disk_number" "$imagePath"
            flock $disk sfdisk -d $disk 2>/dev/null > $sfdiskfilename
            echo "Done"
            debugPause
            [[ $have_extended_partition -ge 1 ]] && saveAllEBRs "$disk" "$disk_number" "$imagePath"
            echo "Done"
            ;;
        1)
            dots "Saving Partition Tables (GPT)"
            saveGRUB "$disk" "$disk_number" "$imagePath" "true"
            sgdisk -b "$imagePath/d${disk_number}.mbr" $disk >/dev/null 2>&1
            if [[ ! $? -eq 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Error trying to save GPT partition tables (${FUNCNAME[0]})\n   Args Passed: $*"
            fi
            flock $disk sfdisk -d $disk 2>/dev/null > $sfdiskfilename
            echo "Done"
            ;;
    esac
    runPartprobe "$disk"
    debugPause
}
clearPartitionTables() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ $nombr -eq 1 ]] && return
    dots "Erasing current MBR/GPT Tables"
    sgdisk -Z $disk >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        2)
            echo "Done"
            rootpxe_console_message WARN 'Cleared a corrupted partition table.'
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Error trying to erase partition tables (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    runPartprobe "$disk"
    debugPause
}
# Restores the partition tables and boot loaders
#
# $1 is the disk
# $2 is the disk number
# $3 is the image path
# $4 is the osid
# $5 is the image partition type
restorePartitionTablesAndBootLoaders() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local osid="$4"
    local imgPartitionType="$5"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $osid ]] && handleError "No osid passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No image part type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local tmpMBR=""
    local strdots=""
    if [[ $nombr -eq 1 ]]; then
        rootpxe_console_message INFO 'Skipping partition tables and MBR.'
        debugPause
        return
    fi
    # Sector validation has to happen before the first destructive operation.
    # The sfdisk capture metadata is present for both MBR and GPT resizable
    # images; absent legacy metadata keeps its established compatibility path.
    local sector_partition_file=""
    sfdiskPartitionFileName "$imagePath" "$disk_number"
    sector_partition_file="$sfdiskoriginalpartitionfilename"
    # Resolve and validate the actual selected boot/table artifact before a
    # sector-size reformat or table clear.  The top-level preflight protects
    # ordinary downloads, but this function is also called by compatibility
    # paths and must never clear a target first and discover a missing MBR.
    MBRFileName "$imagePath" "$disk_number" "tmpMBR"
    [[ -r $tmpMBR && -s $tmpMBR ]] || handleError "Image Store Corrupt: Unable to locate readable MBR (${FUNCNAME[0]})\n   Args Passed: $*"
    validateImageSectorSize "$disk" "$sector_partition_file"
    clearPartitionTables "$disk"
    majorDebugEcho "Partition table should be empty now."
    majorDebugShowCurrentPartitionTable "$disk" "$disk_number"
    majorDebugPause
    local table_type=""
    getDesiredPartitionTableType "$imagePath" "$disk_number"
    majorDebugEcho "Trying to restore to $table_type partition table."
    if [[ $table_type == GPT ]]; then
        dots "Restoring Partition Tables (GPT)"
        restoreGRUB "$disk" "$disk_number" "$imagePath" "true"
        sgdisk -z $disk >/dev/null 2>&1
        sgdisk -gl $tmpMBR $disk >/tmp/sgdisk-gl.err 2>&1
        sgdiskexit="$?"
        if [[ ! $sgdiskexit -eq 0 ]]; then
            echo "Failed"
            debugPause
            [[ -r /tmp/sgdisk-gl.err ]] && cat /tmp/sgdisk-gl.err
            rootpxe_console_message INFO 'Review the detailed error above. Use Shift-PageUp to scroll.'
            handleError "Error trying to restore GPT partition tables (${FUNCNAME[0]})\n   Args Passed: $*\n    CMD Tried: sgdisk -gl $tmpMBR $disk\n    Exit returned code: $sgdiskexit"
        fi
        rm -f /tmp/sgdisk-gl.err
        global_gptcheck="yes"
        echo "Done"
    else
        case $osid in
            50|51)
                strdots="Restoring Partition Tables and GRUB (MBR)"
                ;;
            *)
                strdots="Restoring Partition Tables (MBR)"
                ;;
        esac
        dots "$strdots"
        restoreGRUB "$disk" "$disk_number" "$imagePath"
        echo "Done"
        debugPause
        majorDebugShowCurrentPartitionTable "$disk" "$disk_number"
        majorDebugPause
        ebrcount=$(ls -1 $imagePath/*.ebr 2>/dev/null | wc -l)
        [[ $ebrcount -gt 0 ]] && restoreAllEBRs "$disk" "$disk_number" "$imagePath" "$imgPartitionType"
        local sfdiskoriginalpartitionfilename=""
        local sfdisklegacyoriginalpartitionfilename=""
        sfdiskPartitionFileName "$imagePath" "$disk_number"
        sfdiskLegacyOriginalPartitionFileName "$imagePath" "$disk_number"
        if [[ -r $sfdiskoriginalpartitionfilename ]]; then
            dots "Inserting Extended partitions (Original)"
            applySfdiskPartitions "$disk" "$sfdiskoriginalpartitionfilename"
            echo "Done"
        elif [[ -e $sfdisklegacyoriginalpartitionfilename ]]; then
            dots "Inserting Extended partitions (Legacy)"
            applySfdiskPartitions "$disk" "$sfdisklegacyoriginalpartitionfilename"
            echo "Done"
        else
            rootpxe_console_message INFO 'No extended partitions found.'
        fi
    fi
    debugPause
    runPartprobe "$disk"
    majorDebugShowCurrentPartitionTable "$disk" "$disk_number"
    majorDebugPause
}
savePartition() {
    local part="$1"
    local disk_number="$2"
    local imagePath="$3"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local part_number=0
    local exitcode=0
    local writer_exitcode=0
    local progress_decoder=0
    getPartitionNumber "$part"
    local fstype=""
    local parttype=""
    local imgpart=""
    local fifoname="/tmp/pigz1"
    if [[ $imgPartitionType != all && $imgPartitionType != $part_number ]]; then
        rootpxe_console_message INFO "Skipping partition $part ($part_number)."
        debugPause
        return
    fi
    rootpxe_console_message INFO "Processing partition: $part ($part_number)."
    debugPause
    fsTypeSetting "$part"
    getPartType "$part"
    local ebrfilename=""
    local swapuuidfilename=""
    # An extended partition is an EBR container, never an image payload.
    case $parttype in
        5|f|85|0x5|0xf|0x85)
            rootpxe_console_message INFO 'Not capturing extended partition content.'
            debugPause
            EBRFileName "$imagePath" "$disk_number" "$part_number"
            touch "$ebrfilename"
            rm -rf "$fifoname" >/dev/null 2>&1
            return
            ;;
    esac
    case $fstype in
        lvm)
            # A LVM PV is captured exclusively through its supported linear
            # LVs.  Never let the generic imager create a raw PV payload.
            rootpxe_lvm_is_pv_partition "$part" || handleError "Unsupported LVM PV topology. (${FUNCNAME[0]})"
            rootpxe_capture_lvm_volumes "$imagePath" || handleError "PXEOS_STAGE=capture CODE=${rootpxe_lvm_capture_error_code:-LVM_CAPTURE_FAILED} REASON=${rootpxe_lvm_capture_error_reason:-unknown}"
            ;;
        swap)
            rootpxe_console_message INFO 'Saving swap partition UUID.'
            swapUUIDFileName "$imagePath" "$disk_number"
            saveSwapUUID "$swapuuidfilename" "$part"
            ;;
        imager)
            rootpxe_console_message INFO "Using partclone.$fstype."
            debugPause
            imgpart="$imagePath/d${disk_number}p${part_number}.img"
            if ! rootpxe_partclone_progress_prepare; then
                rm -f "$fifoname" >/dev/null 2>&1 || true
                handleError "PXEOS_STAGE=capture CODE=CAPTURE_PROGRESS_SETUP_FAILED REASON=unable_to_start_partclone_stderr_decoder"
            fi
            if ! uploadFormat "$fifoname" "$imgpart"; then
                rootpxe_partclone_progress_abort || true
                rm -f "$fifoname" >/dev/null 2>&1 || true
                handleError "PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_SETUP_FAILED REASON=unable_to_start_capture_writer"
            fi
            rootpxe_partclone_progress_start_collector
            if LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.$fstype "${rootpxe_partclone_progress_args[@]}" -n "Storage Location $storage, Image name $img" -cs "$part" -O "$fifoname" -f 1 2>"$rootpxe_partclone_progress_stderr_target"; then
                exitcode=0
            else
                exitcode=$?
            fi
            rootpxe_partclone_progress_wait || progress_decoder=$?
            if rootpxe_wait_for_writer "$rootpxe_last_writer_pid"; then
                writer_exitcode=0
            else
                writer_exitcode=$?
            fi
            if [[ $exitcode -ne 0 ]]; then
                rm -f "$fifoname" >/dev/null 2>&1 || true
                handleError "PXEOS_STAGE=capture CODE=CAPTURE_PARTCLONE_FAILED REASON=partition_${part_number}_${fstype}"
            fi
            if [[ $progress_decoder -ne 0 ]]; then
                rm -f "$fifoname" >/dev/null 2>&1 || true
                handleError "PXEOS_STAGE=capture CODE=CAPTURE_PROGRESS_FAILED REASON=partclone_stderr_decoder_failed"
            fi
            if [[ $writer_exitcode -ne 0 ]]; then
                rm -f "$fifoname" >/dev/null 2>&1 || true
                handleError "PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_FAILED REASON=storage_writer_or_compressor_failed"
            fi
            mv "${imgpart}.000" "$imgpart" >/dev/null 2>&1 || handleError "PXEOS_STAGE=capture CODE=CAPTURE_ARTIFACT_FINALIZE_FAILED REASON=unable_to_finalize_image_artifact"
            rootpxe_console_message INFO 'Image captured.'
            debugPause
            ;;
        *)
            case $parttype in
                5|f|85|0x5|0xf|0x85)
                    rootpxe_console_message INFO 'Not capturing extended partition content.'
                    debugPause
                    EBRFileName "$imagePath" "$disk_number" "$part_number"
                    touch "$ebrfilename"
                    ;;
                *)
                    rootpxe_console_message INFO "Using partclone.$fstype."
                    debugPause
                    imgpart="$imagePath/d${disk_number}p${part_number}.img"
                    if [[ $fstype == xfs ]] && ! rootpxe_xfs_capture_preflight "$part"; then
                        handleError "PXEOS_STAGE=capture CODE=XFS_CAPTURE_PREFLIGHT_FAILED REASON=partition_${part_number}_${rootpxe_xfs_capture_error:-unknown}"
                        return 1
                    fi
                    if ! rootpxe_partclone_progress_prepare; then
                        rm -f "$fifoname" >/dev/null 2>&1 || true
                        handleError "PXEOS_STAGE=capture CODE=CAPTURE_PROGRESS_SETUP_FAILED REASON=unable_to_start_partclone_stderr_decoder"
                    fi
                    if ! uploadFormat "$fifoname" "$imgpart"; then
                        rootpxe_partclone_progress_abort || true
                        rm -f "$fifoname" >/dev/null 2>&1 || true
                        handleError "PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_SETUP_FAILED REASON=unable_to_start_capture_writer"
                    fi
                    rootpxe_partclone_progress_start_collector
                    if LC_ALL=C TERM="$rootpxe_partclone_progress_term" partclone.$fstype "${rootpxe_partclone_progress_args[@]}" -n "Storage Location $storage, Image name $img" -cs "$part" -O "$fifoname" -f 1 -a0 2>"$rootpxe_partclone_progress_stderr_target"; then
                        exitcode=0
                    else
                        exitcode=$?
                    fi
                    rootpxe_partclone_progress_wait || progress_decoder=$?
                    if rootpxe_wait_for_writer "$rootpxe_last_writer_pid"; then
                        writer_exitcode=0
                    else
                        writer_exitcode=$?
                    fi
                    if [[ $exitcode -ne 0 ]]; then
                        rm -f "$fifoname" >/dev/null 2>&1 || true
                        handleError "PXEOS_STAGE=capture CODE=CAPTURE_PARTCLONE_FAILED REASON=partition_${part_number}_${fstype}"
                    fi
                    if [[ $progress_decoder -ne 0 ]]; then
                        rm -f "$fifoname" >/dev/null 2>&1 || true
                        handleError "PXEOS_STAGE=capture CODE=CAPTURE_PROGRESS_FAILED REASON=partclone_stderr_decoder_failed"
                    fi
                    if [[ $writer_exitcode -ne 0 ]]; then
                        rm -f "$fifoname" >/dev/null 2>&1 || true
                        handleError "PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_FAILED REASON=storage_writer_or_compressor_failed"
                    fi
                    mv "${imgpart}.000" "$imgpart" >/dev/null 2>&1 || handleError "PXEOS_STAGE=capture CODE=CAPTURE_ARTIFACT_FINALIZE_FAILED REASON=unable_to_finalize_image_artifact"
                    rootpxe_console_message INFO 'Image captured.'
                    debugPause
                    ;;
            esac
            ;;
    esac
    rm -rf $fifoname >/dev/null 2>&1
}
restorePartition() {
    local part="$1"
    local disk_number="$2"
    local imagePath="$3"
    local mc="$4"
    local split=''
    if [[ $imgFormat -eq 6 || $imgFormat -eq 4 || $imgFormat -eq 2 ]]; then
        split='*'
    fi
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $imgPartitionType != all && $imgPartitionType != $part_number ]]; then
        rootpxe_console_message INFO "Skipping partition: $part ($part_number)."
        debugPause
        return
    fi
    local imgpart=""
    local ebrfilename=""
    local disk=""
    local part_number=0
    local parttype=""
    local israw=0
    if [[ $imgType == "dd" ]]; then
        israw=1
    fi
    getDiskFromPartition "$part" "$israw"
    getPartitionNumber "$part"
    getPartType "$part"
    case $parttype in
        5|f|85|0x5|0xf|0x85)
            rootpxe_console_message INFO 'Not deploying extended partition content.'
            runPartprobe "$disk"
            return
            ;;
    esac
    rootpxe_console_message INFO "Processing partition: $part ($part_number)."
    debugPause
    case $imgType in
        dd)
            imgpart="$imagePath"
            ;;
        n|mps|mpa)
            case $osid in
                [1-2])
                    [[ -f $imagePath ]] && imgpart="$imagePath" || imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                    ;;
                4|8|50|51|99)
                    imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                    ;;
                [5-7]|9|10|11)
                    [[ ! -f $imagePath/sys.img.000 ]] && imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                    if [[ -z $imgpart ]] ;then
                        [[ -r $imagePath/sys.img.000 ]] && win7partcnt=1
                        [[ -r $imagePath/rec.img.000 ]] && win7partcnt=2
                        [[ -r $imagePath/rec.img.001 ]] && win7partcnt=3
                        case $win7partcnt in
                            1)
                                imgpart="$imagePath/sys.img.*"
                                ;;
                            2)
                                case $part_number in
                                    1)
                                        imgpart="$imagePath/rec.img.000"
                                        ;;
                                    2)
                                        imgpart="$imagePath/sys.img.*"
                                        ;;
                                esac
                                ;;
                            3)
                                case $part_number in
                                    1)
                                        imgpart="$imagePath/rec.img.000"
                                        ;;
                                    2)
                                        imgpart="$imagePath/rec.img.001"
                                        ;;
                                    3)
                                        imgpart="$imagePath/sys.img.*"
                                        ;;
                                esac
                                ;;
                        esac
                    fi
                    ;;
            esac
            ;;
        *)
            handleError "Invalid Image Type $imgType (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    ls $imgpart >/dev/null 2>&1
    if [[ ! $? -eq 0 ]]; then
        EBRFileName "$imagePath" "$disk_number" "$part_number"
        if [[ -e $ebrfilename ]]; then
            rootpxe_console_message INFO 'Not deploying extended partition content.'
        else
            rootpxe_console_message WARN "Partition file is missing: $imgpart."
        fi
        runPartprobe "$disk"
        return
    fi
    writeImage "$imgpart" "$part" "$mc"
    runPartprobe "$disk"
    resetFlag "$part"
}
runFixparts() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    echo
    dots "Attempting fixparts"
    fixparts $disk </usr/share/pxeos/lib/EOFFIXPARTS >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Could not fix partition layout (${FUNCNAME[0]})\n   Args Passed: $*" "yes"
            ;;
    esac
    debugPause
    runPartprobe "$disk"
}
killStatusReporter() {
    [[ -z ${statusReporter:-} ]] && return
    dots "Stopping RootPXE status reporter"
    kill -9 "$statusReporter" >/dev/null 2>&1 || true
    echo "Done"
    debugPause
}
prepareResizeDownloadPartitions() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local osid="$4"
    local imgPartitionType="$5"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $osid ]] && handleError "No osid passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No image partition type  passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $nombr -eq 1 ]]; then
        rootpxe_console_message INFO 'Skipping partition preparation.'
        debugPause
        return
    fi
    restorePartitionTablesAndBootLoaders "$disk" "$disk_number" "$imagePath" "$osid" "$imgPartitionType"
    local do_fill=0
    fillDiskWithPartitionsIsOK "$disk" "$imagePath" "$disk_number"
    majorDebugEcho "Filling disk = $do_fill"
    dots "Attempting to expand/fill partitions"
    if [[ $do_fill -eq 0 ]]; then
        echo "Failed"
        debugPause
        handleError "Fatal Error: Could not resize partitions (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
    fillDiskWithPartitions "$disk" "$imagePath" "$disk_number"
    echo "Done"
    debugPause
    runPartprobe "$disk"
}
# $1 is the disks
# $2 is the image path
# $3 is the image partition type (either all or partition number)
# $4 is the flag to say whether this is multicast or not
rootpxe_expansion_fixed_partitions() {
    local fixed_partitions="$1" schema_file="${originalSchemaFile:-}" resolved_file="${rootpxe_resolved_layout_file:-}"
    local expanded_partitions candidate filtered=""
    [[ -n $fixed_partitions && -r $schema_file && -r $resolved_file ]] || { printf '%s' "$fixed_partitions"; return 0; }
    command -v jq >/dev/null 2>&1 || { printf '%s' "$fixed_partitions"; return 0; }

    # 仅从已验证的布局中找出实际扩大过的叶子物理分区。MBR extended
    # 容器是由逻辑分区派生的边界，不是可恢复的分区内容，不能借此解除
    # fixed 抑制。解析异常时保守地维持捕获期的 fixed 行为。
    expanded_partitions=$(jq -ner --slurpfile schema "$schema_file" --slurpfile resolved "$resolved_file" '
        ($schema[0].partitions // []) as $captured |
        ([$captured[] | select(.kind != "extended") |
          {key:(.number|tostring), value:(.originalSectors // 0)}] | from_entries) as $originals |
        [$resolved[0][]? |
          .number as $number |
          ($originals[($number|tostring)] // null) as $original |
          select((($original|type) == "number") and ((.resolvedSectors|type) == "number") and (.resolvedSectors > $original)) |
          $number] | join(":")
    ' 2>/dev/null) || { printf '%s' "$fixed_partitions"; return 0; }
    [[ -n $expanded_partitions ]] || { printf '%s' "$fixed_partitions"; return 0; }

    for candidate in ${fixed_partitions//:/ }; do
        [[ $candidate =~ ^[1-9][0-9]*$ ]] || { printf '%s' "$fixed_partitions"; return 0; }
        case ":$expanded_partitions:" in
            *":$candidate:"*) ;;
            *) filtered+="${filtered:+:}$candidate" ;;
        esac
    done
    printf '%s' "$filtered"
}

# An authenticated deployment layout has already resolved the final physical
# geometry before any target-disk write.  Internal filesystem growth must use
# that result, rather than the capture-time fixed list: a fixed mode can grow,
# while an original-mode partition can move after an earlier partition grows.
# Return 2 when no deployment layout is active so the legacy restore path can
# retain its capture-time fixed-list behavior.  Any incomplete or malformed
# active layout fails closed.
rootpxe_expansion_active_partitions() {
    local schema_file="${originalSchemaFile:-}" resolved_file="${rootpxe_resolved_layout_file:-}"
    [[ -z $schema_file && -z $resolved_file ]] && return 2
    [[ -r $schema_file && -r $resolved_file ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    jq -ner --slurpfile schema "$schema_file" --slurpfile resolved "$resolved_file" '
        ($schema[0].partitions // null) as $captured |
        if ($captured|type) != "array" or ($captured|length) == 0 then error("captured partitions missing") else . end |
        if ([ $captured[] | .number ] | all(type == "number" and . >= 1 and floor == .) | not) then error("captured partition number invalid") else . end |
        if ([ $captured[].number ] | unique | length) != ($captured|length) then error("captured partition number duplicate") else . end |
        ([$captured[] | {key:(.number|tostring), value:.}] | from_entries) as $captured_by_number |
        ($resolved[0] // null) as $resolved |
        if ($resolved|type) != "array" then error("resolved partitions missing") else . end |
        if ([ $resolved[] | .number ] | all(type == "number" and . >= 1 and floor == .) | not) then error("resolved partition number invalid") else . end |
        if ([ $resolved[].number ] | unique | length) != ($resolved|length) then error("resolved partition number duplicate") else . end |
        if ([ $captured[].number ] | sort) != ([ $resolved[].number ] | sort) then error("resolved partition identity mismatch") else . end |
        [ $resolved[] |
          .number as $number |
          ($captured_by_number[($number|tostring)] // error("resolved partition absent from schema")) as $source |
          if $source.kind == "extended" then empty
          elif (($source.originalSectors|type) != "number" or $source.originalSectors <= 0 or $source.originalSectors != ($source.originalSectors|floor)
                or (.resolvedSectors|type) != "number" or .resolvedSectors <= 0 or .resolvedSectors != (.resolvedSectors|floor)) then
              error("resolved leaf geometry invalid")
          elif .resolvedSectors < $source.originalSectors then error("resolved leaf shrinks")
          elif $source.role == "swap" or $source.fs == "swap" or $source.role == "lvm_pv" or $source.fs == "LVM2_member"
             or ((($source.fs // "") == "") and ((($source.typeGuid // "")|ascii_downcase) == "e3c9e316-0b5c-4db8-817d-f92df00215ae" or (($source.typeGuid // "")|ascii_downcase) == "21686148-6449-6e6f-744e-656564454649")) then empty
          elif .resolvedSectors > $source.originalSectors then $number
          else empty
          end
        ] | join(":")
    ' 2>/dev/null
}

rootpxe_expansion_partition_is_listed() {
    local part_number="$1" partition_list="$2"
    [[ $part_number =~ ^[1-9][0-9]*$ ]] || return 1
    case ":$partition_list:" in
        *":$part_number:"*) return 0 ;;
        *) return 1 ;;
    esac
}

# A larger partition is safe only when PXEOS can also grow the filesystem
# after imaging it.  Run this from the authenticated resolved layout before
# requesting a destructive disk permit.
rootpxe_validate_growth_capability() {
    local schema_file="$1" resolved_file="$2" rows row number fs role type_guid logical_sector
    [[ -r $schema_file && -r $resolved_file ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    rows=$(jq -r --slurpfile resolved "$resolved_file" '
        . as $schema |
        ($resolved[0] // []) as $resolved |
        .partitions[] as $source |
        ($resolved[] | select(.number == $source.number)) as $actual |
        select($actual.resolvedSectors > $source.originalSectors) |
        {number:$source.number,fs:($source.fs // ""),role:($source.role // ""),typeGuid:(($source.typeGuid // "")|ascii_downcase),logicalSectorBytes:($schema.logicalSectorBytes // null)} | @json
    ' "$schema_file") || return 1
    while IFS= read -r row; do
        [[ -n $row ]] || continue
        number=$(jq -er '.number | if type == "number" and . >= 1 and floor == . then tostring else error("number") end' <<<"$row") || return 1
        fs=$(jq -er '.fs | strings' <<<"$row") || return 1
        role=$(jq -er '.role | strings' <<<"$row") || return 1
        type_guid=$(jq -er '.typeGuid | strings' <<<"$row") || return 1
        logical_sector=$(jq -r '.logicalSectorBytes | if type == "number" and floor == . and . > 0 then tostring else "" end' <<<"$row") || return 1
        [[ -n $number ]] || continue
        case "$fs:$role:$type_guid" in
            ext2:*|ext3:*|ext4:*) command -v resize2fs >/dev/null 2>&1 && command -v e2fsck >/dev/null 2>&1 || return 1 ;;
            ntfs:*) command -v ntfsresize >/dev/null 2>&1 || return 1 ;;
            btrfs:*) command -v btrfs >/dev/null 2>&1 || return 1 ;;
            f2fs:*) command -v resize.f2fs >/dev/null 2>&1 || return 1 ;;
            # pxeosfatgrow validates and edits FAT BPB fields in 512-byte
            # sectors.  This is a source-schema capability gate before the
            # permit; the post-restore FAT diagnostic remains authoritative
            # for BPB and filesystem consistency.
            vfat:*|fat:*) [[ $logical_sector == 512 ]] && command -v fsck.fat >/dev/null 2>&1 && command -v pxeosfatgrow >/dev/null 2>&1 || return 1 ;;
            xfs:*) command -v xfs_growfs >/dev/null 2>&1 || return 1 ;;
            swap:*|*:swap:*|LVM2_member:*|*:lvm_pv:*) : ;;
            :msr:e3c9e316-0b5c-4db8-817d-f92df00215ae|:boot:21686148-6449-6e6f-744e-656564454649) : ;;
            *) return 1 ;;
        esac
    done <<<"$rows"
    return 0
}

# Validate payload availability before any target-table write.  A missing
# partition image must never be converted into the historical silent skip.


performRestore() {
    local disks="$1"
    local disk=""
    local imagePath="$2"
    local imgPartitionType="$3"
    local mc="$4"
    [[ -z $disks ]] && handleError "No disks passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No partition type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk_number=1
    local part_number=0
    local restoreparts=""
    local sfdiskoriginalpartitionfilename=""
    local expansion_fixed_size_partitions expansion_partitions="" expansion_plan_active=no expansion_plan_status
    expansion_fixed_size_partitions=$(rootpxe_expansion_fixed_partitions "$fixed_size_partitions")
    if [[ $imgType =~ [Nn] ]]; then
        if expansion_partitions=$(rootpxe_expansion_active_partitions); then
            expansion_plan_status=0
        else
            expansion_plan_status=$?
        fi
        case $expansion_plan_status in
            0) expansion_plan_active=yes ;;
            2) ;;
            *) handleError "Could not determine internal filesystem growth from the validated deployment layout (${FUNCNAME[0]})"; return 1 ;;
        esac
    fi
    [[ $imgType =~ [Nn] ]] && local tmpebrfilename=""
    for disk in $disks; do
        if [[ ${imgType:-} == mpa && ${rootpxe_mpa_permit_is_batch:-no} == yes ]]; then
            rootpxe_activate_disk_permit_binding "$disk" deploy_write || handleError "Disk permit binding changed before restore (${FUNCNAME[0]})"
        fi
        sfdiskoriginalpartitionfilename=""
        sfdiskOriginalPartitionFileName "$imagePath" "$disk_number"
        getValidRestorePartitions "$disk" "$disk_number" "$imagePath" "$restoreparts"
        [[ -z $restoreparts ]] && handleError "No image file(s) found that would match the partition(s) to be restored (${FUNCNAME[0]})\n   Args Passed: $*"
        for restorepart in $restoreparts; do
            getPartitionNumber "$restorepart"
            [[ $imgType =~ [Nn] ]] && tmpEBRFileName "$disk_number" "$part_number"
            restorePartition "$restorepart" "$disk_number" "$imagePath" "$mc"
            [[ $imgType =~ [Nn] ]] && restoreEBR "$restorepart" "$tmpebrfilename"
            if [[ $imgType =~ [Nn] ]]; then
                if [[ $expansion_plan_active == yes ]]; then
                    rootpxe_expansion_partition_is_listed "$part_number" "$expansion_partitions" && expandPartition "$restorepart" "" required
                else
                    expandPartition "$restorepart" "$expansion_fixed_size_partitions"
                fi
            fi
            [[ $osid == +([5-7]) && $imgType =~ [Nn] ]] && fixWin7boot "$restorepart"
        done
        restoreparts=""
        rootpxe_console_message INFO "Resetting UUIDs for $disk."
        debugPause
        restoreUUIDInformation "$disk" "$sfdiskoriginalpartitionfilename" "$disk_number" "$imagePath"
        rootpxe_console_message INFO 'Resetting swap systems.'
        debugPause
        makeAllSwapSystems "$disk" "$disk_number" "$imagePath" "$imgPartitionType"
        let disk_number+=1
    done
}
# Gets the file system identifier.
# $1 is the partition to get.
getFSID() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk
    getDiskFromPartition "$part"
    fsid="$(flock $disk sfdisk -d "$disk" |  grep "$part" | sed -n 's/.*Id=\([0-9]\+\).*\(,\|\).*/\1/p')"
}
# Trims character from string
# $1 The variable to trim
trim() {
    local var="$1"
    var="${var#${var%%[![:space:]]*}}"
    var="${var%${var##*[![:space:]]}}"
    echo -n "$var"
}
# Calculates information
calculate() {
    echo $(awk 'BEGIN{printf "%.0f\n", '$*'}')
}
# Calculates information and returns full float
calculate_float() {
    echo $(awk 'BEGIN{printf "%f\n", '$*'}');
}
