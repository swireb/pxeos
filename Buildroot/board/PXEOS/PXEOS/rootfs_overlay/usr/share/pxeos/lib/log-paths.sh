#!/bin/bash
# Definitions only. Never trust a directory or file name from the environment.
rootpxe_log_pin_valid() {
    [[ ${1:-} =~ ^[1-9][0-9]+$ && ${2:-} == *:600 && -f /proc/self/fd/$1 ]] || return 1
    [[ $(LC_ALL=C stat -L -c '%d:%i:%a' -- "/proc/self/fd/$1" 2>/dev/null) == "$2" ]]
}

rootpxe_log_pin_release() {
    # Only callers holding their non-exported ownership state may use this.
    local rootpxe_log_owned_pin="${1:-}"
    rootpxe_log_pin_valid "$rootpxe_log_owned_pin" "${2:-}" || return 1
    exec {rootpxe_log_owned_pin}<&- || return 1
    if [[ $(declare -p rootpxe_log_owned_pin_state 2>/dev/null) == 'declare -A '* && ${rootpxe_log_owned_pin_state[$rootpxe_log_owned_pin]:-} == "${2:-}" ]]; then
        unset 'rootpxe_log_owned_pin_state[$rootpxe_log_owned_pin]'
    fi
}

rootpxe_log_pin_readonly() {
    local rootpxe_pin_key rootpxe_pin_value rootpxe_pin_extra rootpxe_pin_flags='' rootpxe_pin_seen=0
    rootpxe_log_pin_valid "${1:-}" "${2:-}" && [[ -O /proc/self/fd/$1 && -r /proc/self/fdinfo/$1 ]] || return 1
    while read -r rootpxe_pin_key rootpxe_pin_value rootpxe_pin_extra; do
        if [[ $rootpxe_pin_key == flags: ]]; then rootpxe_pin_flags=$rootpxe_pin_value; rootpxe_pin_seen=$((rootpxe_pin_seen+1)); fi
    done <"/proc/self/fdinfo/$1"
    [[ $rootpxe_pin_seen == 1 && $rootpxe_pin_flags =~ ^[0-7]{1,15}$ ]] || return 1
    (( (8#$rootpxe_pin_flags & 3) == 0 ))
}

rootpxe_log_pin_register() {
    rootpxe_log_pin_readonly "${1:-}" "${2:-}" || return 1
    # An associative ownership record cannot be supplied by environment scalars.
    if [[ $(declare -p rootpxe_log_owned_pin_state 2>/dev/null) != 'declare -A '* ]]; then
        unset rootpxe_log_owned_pin_state
        declare -gA rootpxe_log_owned_pin_state=()
    fi
    export -n rootpxe_log_owned_pin_state
    rootpxe_log_owned_pin_state[$1]=$2
}

rootpxe_lvm_command_valid() {
    case "${1:-}" in
        pvs|vgs|lvs|pvdisplay|vgdisplay|lvdisplay|pvcreate|pvresize|vgcfgrestore|vgcfgbackup|vgchange|lvchange|lvextend) return 0 ;;
        *) return 1 ;;
    esac
}

rootpxe_lvm_native() {
    rootpxe_lvm_command_valid "${1:-}" || return 127
    (
        local rootpxe_lvm_pin rootpxe_lvm_pin_identity
        if [[ $(declare -p rootpxe_log_owned_pin_state 2>/dev/null) == 'declare -A '* ]]; then
            for rootpxe_lvm_pin in "${!rootpxe_log_owned_pin_state[@]}"; do
                rootpxe_lvm_pin_identity=${rootpxe_log_owned_pin_state[$rootpxe_lvm_pin]}
                # Close only this child's verified logger descriptors. Foreign
                # descriptors and real native stderr remain visible to LVM.
                if rootpxe_log_pin_readonly "$rootpxe_lvm_pin" "$rootpxe_lvm_pin_identity"; then
                    rootpxe_log_pin_release "$rootpxe_lvm_pin" "$rootpxe_lvm_pin_identity" || true
                fi
            done
        fi
        "$@"
    )
}

rootpxe_run_logged_typed_native() {
    # Only approved native text calls use this wrapper. Dedicated local names
    # avoid Bash dynamic-scope collisions with the caller's native shell mock.
    local rootpxe_typed_native_type="$1" rootpxe_typed_native_target="$2" rootpxe_typed_native_raw='' rootpxe_typed_native_identity='' rootpxe_typed_native_status=0 rootpxe_typed_native_reference=unavailable
    shift 2
    if rootpxe_lvm_command_valid "${1:-}"; then set -- rootpxe_lvm_native "$@"; fi
    [[ $rootpxe_typed_native_target =~ ^[A-Za-z0-9_./:+-]+$ && ${#rootpxe_typed_native_target} -le 200 ]] || rootpxe_typed_native_target=unknown
    if declare -F rootpxe_task_log_ensure >/dev/null; then
        rootpxe_task_log_ensure || printf '[WARN]  Task log: unavailable.\n' >&2
    fi
    if rootpxe_log_raw_file; then
        rootpxe_typed_native_raw=$rootpxe_log_raw_path
        rootpxe_typed_native_identity=$(LC_ALL=C stat -c '%d:%i:%a' -- "$rootpxe_typed_native_raw") || rootpxe_typed_native_identity=''
        if "$@" >"$rootpxe_typed_native_raw" 2>&1; then rootpxe_typed_native_status=0; else rootpxe_typed_native_status=$?; fi
        if rootpxe_log_publish "$rootpxe_typed_native_type" "$rootpxe_typed_native_raw" "target=$rootpxe_typed_native_target:exit=$rootpxe_typed_native_status"; then
            rootpxe_typed_native_reference="/tmp/log/$rootpxe_typed_native_type"
        fi
        if [[ -n $rootpxe_typed_native_identity && -f $rootpxe_typed_native_raw && ! -L $rootpxe_typed_native_raw && -O $rootpxe_typed_native_raw && $(LC_ALL=C stat -c '%d:%i:%a' -- "$rootpxe_typed_native_raw") == "$rootpxe_typed_native_identity" ]]; then rm -f -- "$rootpxe_typed_native_raw"; fi
    else
        # This output is pure diagnosis, not a parser buffer. Sink failure
        # must not prevent mount/activation or substitute a logger exit code.
        if "$@" >/dev/null 2>&1; then rootpxe_typed_native_status=0; else rootpxe_typed_native_status=$?; fi
    fi
    [[ $rootpxe_typed_native_reference != unavailable ]] || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
    if declare -F rootpxe_task_log_append >/dev/null; then
        rootpxe_task_log_append "OP=$rootpxe_typed_native_type TARGET=$rootpxe_typed_native_target EXIT=$rootpxe_typed_native_status DIAGNOSTIC=$rootpxe_typed_native_reference" || printf '[WARN]  Task log: unavailable.\n' >&2
    fi
    return "$rootpxe_typed_native_status"
}

rootpxe_log_directory() {
    local dir=/tmp/log identity
    if [[ ! -e $dir && ! -L $dir ]]; then
        ( umask 077; mkdir -- "$dir" ) 2>/dev/null || return 1
    fi
    [[ -d $dir && ! -L $dir && -O $dir ]] || return 1
    identity=$(LC_ALL=C stat -c '%d:%i:%a' -- "$dir" 2>/dev/null) || return 1
    [[ $identity == *:700 ]] || return 1
    printf '%s\n' "$dir"
}

rootpxe_log_type_valid() {
    case "$1" in
        pxeos-task.log|ntfsresize.log|e2fsck.log|resize2fs.log|btrfs.log|f2fs-resize.log|fat-fsck.log|fat-grow.log|xfs-grow.log|sfdisk-write.log|partition-reread.log|sfdisk-dump.log|sgdisk-restore.log|dhcp.log|cron.log|ssh-keygen.log|ssh-service.log|clamav.log|partclone.log|linux-lvm.log|linux-mount.log|storage-mount.log|ntfs-mount.log|linux-probe.log|metadata-discovery.log) return 0 ;;
        *) return 1 ;;
    esac
}

rootpxe_log_new_file() {
    local name="$1" dir file staging identity before
    rootpxe_log_type_valid "$name" || return 1
    dir=$(rootpxe_log_directory) || return 1
    before=$(LC_ALL=C stat -c '%d:%i:%a' -- "$dir") || return 1
    file="$dir/$name"
    if [[ -e $file || -L $file ]]; then
        [[ -f $file && ! -L $file && -O $file ]] || return 1
        [[ $(LC_ALL=C stat -c %a -- "$file") == 600 ]] || return 1
    fi
    staging=$(umask 077; mktemp "$dir/.new.XXXXXX") || return 1
    chmod 600 "$staging" || { rm -f -- "$staging"; return 1; }
    [[ $(LC_ALL=C stat -c '%d:%i:%a' -- "$dir") == "$before" && ! -L $dir ]] || { rm -f -- "$staging"; return 1; }
    identity=$(LC_ALL=C stat -c '%d:%i:%a' -- "$staging") || { rm -f -- "$staging"; return 1; }
    (
        flock -n -x 8 2>/dev/null || exit 1
        [[ $(stat -L -c '%d:%i:%a' /proc/self/fd/8) == "$before" ]] || exit 1
        [[ $(LC_ALL=C stat -c '%d:%i:%a' -- "$dir") == "$before" && ! -L $dir ]] || exit 1
        if [[ $name != pxeos-task.log ]] && declare -F rootpxe_task_log_valid >/dev/null && declare -p rootpxe_task_log_state >/dev/null 2>&1; then
            rootpxe_task_log_valid || exit 1
        fi
        if [[ -e $file || -L $file ]]; then
            [[ -f $file && ! -L $file && -O $file && $(stat -c %a -- "$file") == 600 ]] || exit 1
        fi
        # Bind both rename operands to the verified directory inode.
        mv -f -T -- "/proc/self/fd/8/${staging##*/}" "/proc/self/fd/8/$name"
    ) 8<"$dir" || { rm -f -- "$staging"; return 1; }
    rootpxe_log_created_file="$file"
    rootpxe_log_created_identity="$identity"
    rootpxe_log_created_directory_identity="$before"
}

rootpxe_log_raw_file() {
    local dir file
    dir=$(rootpxe_log_directory) || dir=''
    if [[ -n $dir ]]; then file=$(umask 077; mktemp "$dir/.raw.XXXXXX") || file=''; fi
    [[ -n ${file:-} ]] || file=$(umask 077; mktemp /tmp/rootpxe-diagnostic.XXXXXX) || return 1
    chmod 600 "$file" || { rm -f -- "$file"; return 1; }
    [[ -f $file && ! -L $file && -O $file && $(LC_ALL=C stat -c %a -- "$file") == 600 ]] || { rm -f -- "$file"; return 1; }
    rootpxe_log_raw_path="$file"
}

rootpxe_log_snapshot() {
    local -x LC_ALL=C
    local rootpxe_snapshot_raw="$1" rootpxe_snapshot_fd='' rootpxe_snapshot_identity rootpxe_snapshot_size rootpxe_snapshot_count rootpxe_snapshot_skip rootpxe_snapshot_text rootpxe_snapshot_marker=''
    [[ -f $rootpxe_snapshot_raw && ! -L $rootpxe_snapshot_raw && -O $rootpxe_snapshot_raw ]] || return 1
    rootpxe_snapshot_identity=$(stat -c '%d:%i:%a' -- "$rootpxe_snapshot_raw") || return 1
    [[ $rootpxe_snapshot_identity == *:600 ]] || return 1
    exec {rootpxe_snapshot_fd}<"$rootpxe_snapshot_raw" || return 1
    if ! rootpxe_log_pin_valid "$rootpxe_snapshot_fd" "$rootpxe_snapshot_identity"; then exec {rootpxe_snapshot_fd}<&-; return 1; fi
    rootpxe_snapshot_size=$(stat -L -c %s -- "/proc/self/fd/$rootpxe_snapshot_fd") || { exec {rootpxe_snapshot_fd}<&-; return 1; }
    [[ $rootpxe_snapshot_size =~ ^[0-9]+$ && ${#rootpxe_snapshot_size} -le 15 ]] || { exec {rootpxe_snapshot_fd}<&-; return 1; }
    rootpxe_snapshot_count=$rootpxe_snapshot_size
    (( rootpxe_snapshot_count <= 131072 )) || rootpxe_snapshot_count=131072
    rootpxe_snapshot_skip=$((rootpxe_snapshot_size-rootpxe_snapshot_count))
    # Freeze the opened inode's byte count; no growing EOF or per-line fork.
    if rootpxe_snapshot_text=$(set -o pipefail; dd if="/proc/self/fd/$rootpxe_snapshot_fd" iflag=skip_bytes,count_bytes skip="$rootpxe_snapshot_skip" count="$rootpxe_snapshot_count" status=none | tr -d '\000' || exit 1; printf '\001'); then
        exec {rootpxe_snapshot_fd}<&- || return 1
    else exec {rootpxe_snapshot_fd}<&-; return 1; fi
    rootpxe_snapshot_text=${rootpxe_snapshot_text%$'\001'}
    if (( rootpxe_snapshot_skip > 0 )); then
        rootpxe_snapshot_marker='[TRUNCATED: earlier snapshot and incomplete first line omitted]'
        if [[ $rootpxe_snapshot_text == *$'\n'* ]]; then rootpxe_snapshot_text=${rootpxe_snapshot_text#*$'\n'}; else rootpxe_snapshot_text=''; fi
    fi
    rootpxe_snapshot_text=$(printf '%s' "$rootpxe_snapshot_text" | awk 'length($0)>65000 {print "[TRUNCATED: overlong diagnostic omitted]"; next} {print}') || return 1
    rootpxe_snapshot_text=$(rootpxe_log_redact "$rootpxe_snapshot_text") || return 1
    if (( ${#rootpxe_snapshot_text} > 63000 )); then
        rootpxe_snapshot_marker='[TRUNCATED: earlier snapshot diagnostics omitted]'
        if declare -F rootpxe_utf8_safe_tail >/dev/null; then rootpxe_snapshot_text=$(rootpxe_utf8_safe_tail "$rootpxe_snapshot_text" 63000) || return 1
        else
            rootpxe_snapshot_text=${rootpxe_snapshot_text: -63000}
            while [[ -n $rootpxe_snapshot_text && $(printf '%d' "'${rootpxe_snapshot_text:0:1}") -ge 128 && $(printf '%d' "'${rootpxe_snapshot_text:0:1}") -lt 192 ]]; do rootpxe_snapshot_text=${rootpxe_snapshot_text:1}; done
        fi
    fi
    [[ -z $rootpxe_snapshot_marker ]] || printf '%s\n' "$rootpxe_snapshot_marker"
    printf '%s' "$rootpxe_snapshot_text"
}

rootpxe_log_raw_cleanup() {
    [[ -n ${2:-} && -f $1 && ! -L $1 && -O $1 ]] || return 1
    [[ $(LC_ALL=C stat -c '%d:%i:%a' -- "$1") == "$2" ]] || return 1
    rm -f -- "$1"
}

rootpxe_log_redact() {
    local rootpxe_redaction_text
    # A snapshot may end mid-field while a daemon continues writing.
    rootpxe_redaction_text=$(LC_ALL=C printf '%s' "$1" | sed -E \
      -e "s/((['\"]?)[[:alnum:]_.-]*(token|password|credential|secret|cloudInitVendorData|cloud_init_vendor_data)[[:alnum:]_.-]*\\2[[:space:]]*[:=][[:space:]]*)\"([^\"\\\\]|\\\\.)*(\\\\)?$/\\1\"[REDACTED: incomplete quoted field]\"/Ig" \
      -e "s/((['\"]?)[[:alnum:]_.-]*(token|password|credential|secret|cloudInitVendorData|cloud_init_vendor_data)[[:alnum:]_.-]*\\2[[:space:]]*[:=][[:space:]]*)'[^']*$/\\1'[REDACTED: incomplete quoted field]'/Ig") || return 1
    set -- "$rootpxe_redaction_text"
    if declare -F rootpxe_redact_diagnostic >/dev/null; then rootpxe_redact_diagnostic "$1"; return $?; fi
    # Boot has no task payload: redact common fields without loading funcs.
    LC_ALL=C printf '%s' "$1" | sed -E \
      -e 's/("(token|password|credential|secret|executionToken|cloudInitVendorData|cloud_init_vendor_data)(Sha256|_sha256|File|_file)?"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/\1"[REDACTED]"/Ig' \
      -e "s/((token|password|credential|secret|cloudInitVendorData|cloud_init_vendor_data)(Sha256|_sha256|File|_file)?[[:space:]]*=[[:space:]]*)'[^']*'/\\1[REDACTED]/Ig" \
      -e 's/((token|password|credential|secret|cloudInitVendorData|cloud_init_vendor_data)(Sha256|_sha256|File|_file)?[[:space:]]*=[[:space:]]*)"([^"\\]|\\.)*"/\1[REDACTED]/Ig' \
      -e 's/((token|password|credential|secret|cloudInitVendorData|cloud_init_vendor_data)(Sha256|_sha256|File|_file)?[[:space:]]*=[[:space:]]*)[^&[:space:]]+/\1[REDACTED]/Ig' \
      -e 's@/tmp/rootpxe-cloud-vendor\.[[:alnum:]]{6}@[REDACTED]@g'
}

rootpxe_log_diagnostic_stream() {
    local -x LC_ALL=C
    local chunk='' pending='' line='' retained='' overlong=no truncated=no failed=no
    while IFS= read -r -N 4096 chunk || [[ -n $chunk ]]; do
        pending+=$chunk; chunk=''
        while [[ $pending == *$'\n'* ]]; do
            line=${pending%%$'\n'*}; pending=${pending#*$'\n'}
            if [[ $overlong == yes || ${#line} -gt 65000 ]]; then
                line='[TRUNCATED: overlong diagnostic omitted]'; truncated=yes
            else line=$(rootpxe_log_redact "$line") || { line=''; failed=yes; }; fi
            overlong=no
            retained+="$line"$'\n'
            if (( ${#retained} > 64000 )); then retained=${retained: -64000}; truncated=yes; fi
        done
        if (( ${#pending} > 65000 )); then pending=''; overlong=yes; truncated=yes; fi
    done
    if [[ $overlong == yes ]]; then pending='[TRUNCATED: overlong diagnostic omitted]';
    else pending=$(rootpxe_log_redact "$pending") || { pending=''; failed=yes; }; fi
    retained+=$pending
    if (( ${#retained} > 64000 )); then retained=${retained: -64000}; truncated=yes; fi
    [[ $truncated != yes ]] || printf '[TRUNCATED: earlier diagnostics omitted]\n'
    printf '%s' "$retained"
    [[ $failed != yes ]]
}

rootpxe_log_publish() {
    local -x LC_ALL=C
    local name="$1" raw="$2" operation="${3:-diagnostic}" append="${4:-no}" expected="${5:-}" dir directory_identity file identity text size marker='[TRUNCATED: earlier diagnostics omitted]'
    rootpxe_log_type_valid "$name" || return 1
    [[ -f $raw && ! -L $raw && -O $raw && $(stat -c %a -- "$raw") == 600 ]] || return 1
    dir=$(rootpxe_log_directory) || return 1
    directory_identity=$(stat -c '%d:%i:%a' -- "$dir") || return 1
    file="$dir/$name"
    if [[ $append != yes || ! -e $file ]]; then rootpxe_log_new_file "$name" || return 1; fi
    [[ -f $file && ! -L $file && -O $file ]] || return 1
    identity=$(stat -c '%d:%i:%a' -- "$file") || return 1
    [[ $identity == *:600 ]] || return 1
    [[ -z $expected || $identity == "$expected" ]] || return 1
    [[ $operation =~ ^[A-Za-z0-9_./:+=-]+$ && ${#operation} -le 256 ]] || operation=diagnostic
    # Keep the tail of native text; the raw parser always saw the full file.
    text=$(rootpxe_log_snapshot "$raw") || return 1
    (
        flock -n -x 8 2>/dev/null || exit 1
        [[ $(stat -L -c '%d:%i:%a' /proc/self/fd/8) == "$directory_identity" && $(stat -c '%d:%i:%a' -- "$dir") == "$directory_identity" && ! -L $dir ]] || exit 1
        if declare -F rootpxe_task_log_valid >/dev/null && declare -p rootpxe_task_log_state >/dev/null 2>&1; then rootpxe_task_log_valid || exit 1; fi
        [[ -f /proc/self/fd/8/$name && ! -L /proc/self/fd/8/$name && -O /proc/self/fd/8/$name ]] || exit 1
        exec 9>>"/proc/self/fd/8/$name" || exit 1
        flock -n -x 9 2>/dev/null || exit 1
        [[ $(stat -L -c '%d:%i:%a' /proc/self/fd/9) == "$identity" ]] || exit 1
        size=$(wc -c </proc/self/fd/9) || exit 1
        if (( size + ${#text} + ${#operation} + 6 > 4194304 )); then
            truncate -s 0 -- /proc/self/fd/9 || exit 1
            printf '%s\n' "$marker" >&9 || exit 1
        fi
        printf 'OP=%s\n%s\n' "$operation" "$text" >&9
    ) 8<"$dir" 2>/dev/null
}



rootpxe_log_boot_run() {
    local rootpxe_boot_name="$1" rootpxe_boot_operation="$2" rootpxe_boot_lifecycle="$3" rootpxe_boot_status=0 rootpxe_boot_log_status=0 rootpxe_boot_pin='' rootpxe_boot_identity='' rootpxe_boot_dir='' rootpxe_boot_ready=no rootpxe_boot_declaration rootpxe_boot_raw='' rootpxe_boot_raw_identity=''
    shift 3
    rootpxe_boot_declaration=$(declare -p rootpxe_boot_log_notice_state 2>/dev/null) || rootpxe_boot_declaration=''
    if [[ $rootpxe_boot_declaration != 'declare -A '* ]]; then unset rootpxe_boot_log_notice_state; declare -gA rootpxe_boot_log_notice_state=(); fi
    if rootpxe_log_type_valid "$rootpxe_boot_name"; then unset 'rootpxe_boot_log_notice_state[$rootpxe_boot_name]'; fi
    if rootpxe_log_type_valid "$rootpxe_boot_name" && [[ $rootpxe_boot_lifecycle == foreground-append ]] && rootpxe_boot_dir=$(rootpxe_log_directory) && [[ -f $rootpxe_boot_dir/$rootpxe_boot_name && ! -L $rootpxe_boot_dir/$rootpxe_boot_name && -O $rootpxe_boot_dir/$rootpxe_boot_name ]]; then
        rootpxe_boot_identity=$(stat -c '%d:%i:%a' -- "$rootpxe_boot_dir/$rootpxe_boot_name") || rootpxe_boot_identity=''
        [[ $rootpxe_boot_identity != *:600 ]] || rootpxe_boot_ready=yes
    elif rootpxe_log_new_file "$rootpxe_boot_name"; then rootpxe_boot_identity=$rootpxe_log_created_identity; rootpxe_boot_ready=yes; fi
    if [[ $rootpxe_boot_ready == yes ]]; then
        rootpxe_boot_dir=$(rootpxe_log_directory) || rootpxe_boot_ready=no
        if [[ $rootpxe_boot_ready == yes ]] && exec {rootpxe_boot_pin}<"$rootpxe_boot_dir/$rootpxe_boot_name"; then
            rootpxe_log_pin_valid "$rootpxe_boot_pin" "$rootpxe_boot_identity" && rootpxe_log_pin_register "$rootpxe_boot_pin" "$rootpxe_boot_identity" || { exec {rootpxe_boot_pin}<&-; rootpxe_boot_pin=''; rootpxe_boot_ready=no; }
        else rootpxe_boot_ready=no; fi
    fi
    if rootpxe_log_raw_file; then
        rootpxe_boot_raw=$rootpxe_log_raw_path
        rootpxe_boot_raw_identity=$(stat -c '%d:%i:%a' -- "$rootpxe_boot_raw") || rootpxe_boot_raw_identity=''
    fi
    if [[ -n $rootpxe_boot_raw_identity ]]; then
        # Only native stdio points to a regular file. No pipe writer FD, child
        # collector or logger EOF wait is added to startup/daemon lifetimes.
        if "$@" >"$rootpxe_boot_raw" 2>&1; then rootpxe_boot_status=0; else rootpxe_boot_status=$?; fi
        if [[ $rootpxe_boot_ready == yes ]] && rootpxe_log_pin_valid "$rootpxe_boot_pin" "$rootpxe_boot_identity"; then
            # Empty successful ssh-keygen output stays empty: an OP header
            # must not pretend that new keys were generated.
            if [[ $rootpxe_boot_status == 0 && ! -s $rootpxe_boot_raw ]]; then :
            elif ! rootpxe_log_publish "$rootpxe_boot_name" "$rootpxe_boot_raw" "$rootpxe_boot_operation:exit=$rootpxe_boot_status" yes "$rootpxe_boot_identity"; then rootpxe_boot_log_status=1; fi
        else rootpxe_boot_log_status=1; fi
        rootpxe_log_raw_cleanup "$rootpxe_boot_raw" "$rootpxe_boot_raw_identity" || rootpxe_boot_log_status=1
    else
        rootpxe_boot_log_status=1
        if "$@" >/dev/null 2>&1; then rootpxe_boot_status=0; else rootpxe_boot_status=$?; fi
    fi
    if [[ -n $rootpxe_boot_pin ]]; then rootpxe_log_pin_release "$rootpxe_boot_pin" "$rootpxe_boot_identity" || rootpxe_boot_log_status=1; fi
    if [[ $rootpxe_boot_ready == yes && $rootpxe_boot_log_status == 0 ]]; then rootpxe_boot_log_notice_state[$rootpxe_boot_name]=$rootpxe_boot_identity; fi
    [[ $rootpxe_boot_log_status == 0 ]] || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
    return "$rootpxe_boot_status"
}

rootpxe_log_notice() {
    local name="$1" dir declaration
    declaration=$(declare -p rootpxe_boot_log_notice_state 2>/dev/null) || declaration=''
    if rootpxe_log_type_valid "$name" && [[ $declaration == 'declare -A '* && -n ${rootpxe_boot_log_notice_state[$name]:-} ]] && dir=$(rootpxe_log_directory) && [[ -s $dir/$name && -f $dir/$name && ! -L $dir/$name && -O $dir/$name ]] && [[ $(stat -c '%d:%i:%a' -- "$dir/$name") == "${rootpxe_boot_log_notice_state[$name]}" && ${rootpxe_boot_log_notice_state[$name]} == *:600 ]]; then
        printf '[INFO]  Details: %s/%s\n' "$dir" "$name"
    else printf '[WARN]  Diagnostic log: unavailable.\n'; fi
}
