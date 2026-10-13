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
    exec {rootpxe_log_owned_pin}<&-
}

rootpxe_run_logged_typed_native() {
    # Only approved native text calls use this wrapper. Dedicated local names
    # avoid Bash dynamic-scope collisions with the caller's native shell mock.
    local rootpxe_typed_native_type="$1" rootpxe_typed_native_target="$2" rootpxe_typed_native_raw='' rootpxe_typed_native_identity='' rootpxe_typed_native_status=0 rootpxe_typed_native_reference=unavailable
    shift 2
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

rootpxe_log_redact() {
    if declare -F rootpxe_redact_diagnostic >/dev/null; then rootpxe_redact_diagnostic "$1"; return $?; fi
    # Boot has no task payload: redact common fields without loading funcs.
    LC_ALL=C printf '%s' "$1" | sed -E \
      -e 's/("(token|password|credential|secret|executionToken)"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/\1"[REDACTED]"/Ig' \
      -e "s/((token|password|credential|secret)[[:space:]]*=[[:space:]]*)'[^']*'/\\1[REDACTED]/Ig" \
      -e 's/((token|password|credential|secret)[[:space:]]*=[[:space:]]*)"([^"\\]|\\.)*"/\1[REDACTED]/Ig' \
      -e 's/((token|password|credential|secret)[[:space:]]*=[[:space:]]*)[^&[:space:]]+/\1[REDACTED]/Ig'
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
    text=$(set -o pipefail; cat -- "$raw" | rootpxe_log_diagnostic_stream) || return 1
    if declare -F rootpxe_utf8_safe_tail >/dev/null; then
        text=$(rootpxe_utf8_safe_tail "$text" 63000) || return 1
    elif (( ${#text} > 63000 )); then
        text=${text: -63000}
        # Drop UTF-8 continuation bytes at the start of a tail window.
        while [[ -n $text && $(printf '%d' "'${text:0:1}") -ge 128 && $(printf '%d' "'${text:0:1}") -lt 192 ]]; do text=${text:1}; done
    fi
    [[ $(wc -c <"$raw") -le 64000 ]] || text="$marker"$'\n'"$text"
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

rootpxe_log_boot_line() {
    local name="$1" identity="$2" operation="$3" raw="$4" line="$5" dir current
    dir=$(rootpxe_log_directory) || return 1
    current=$(stat -c '%d:%i:%a' -- "$dir/$name" 2>/dev/null) || return 1
    # A newer lifecycle owns this name. Drain, but do not publish old data.
    [[ $current == "$identity" ]] || return 0
    printf '%s\n' "$line" >"$raw" || return 1
    if rootpxe_log_publish "$name" "$raw" "$operation" yes "$identity"; then return 0; fi
    # Replacement can occur between the first identity check and publishing.
    # A superseded stream is not a failure of the current service's sink.
    current=$(stat -c '%d:%i:%a' -- "$dir/$name" 2>/dev/null) || return 1
    [[ $current != "$identity" ]]
}

rootpxe_log_boot_stream() {
    local -x LC_ALL=C
    local name="$1" identity="$2" operation="$3" rootpxe_boot_collector_pin="${4:-}" char line='' overflow=no raw='' failed=no current dir
    if rootpxe_log_pin_valid "$rootpxe_boot_collector_pin" "$identity" && rootpxe_log_raw_file; then raw=$rootpxe_log_raw_path; else
        failed=yes; printf '[WARN]  Diagnostic log: unavailable.\n' >&2
    fi
    # Complete lines are redacted together: secret fields may cross reads.
    # Overlong lines are omitted rather than exposing a fragment of a field.
    while IFS= read -r -N 1 char; do
        if [[ $char == $'\n' ]]; then
            [[ $overflow != yes ]] || line='[TRUNCATED: overlong daemon diagnostic omitted]'
            if [[ -n $raw ]]; then
                if ! rootpxe_log_pin_valid "$rootpxe_boot_collector_pin" "$identity" || ! rootpxe_log_boot_line "$name" "$identity" "$operation" "$raw" "$line"; then
                    [[ $failed == yes ]] || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
                    failed=yes
                fi
            fi
            line=''; overflow=no
        elif [[ $overflow != yes ]]; then
            line+=$char
            if (( ${#line} > 64000 )); then line=''; overflow=yes; fi
        fi
    done
    [[ $overflow != yes ]] || line='[TRUNCATED: overlong daemon diagnostic omitted]'
    if [[ -n $raw ]]; then
        if [[ -n $line ]]; then
            if ! rootpxe_log_pin_valid "$rootpxe_boot_collector_pin" "$identity" || ! rootpxe_log_boot_line "$name" "$identity" "$operation" "$raw" "$line"; then
                [[ $failed == yes ]] || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
                failed=yes
            fi
        fi
        rm -f -- "$raw"
    fi
    if ! rootpxe_log_pin_release "$rootpxe_boot_collector_pin" "$identity"; then
        [[ $failed == yes ]] || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
        failed=yes
    fi
    [[ $failed != yes ]]
}

rootpxe_log_boot_run() {
    local name="$1" operation="$2" lifecycle="$3" status=0 collector='' log_status=0 rootpxe_boot_log_fd rootpxe_boot_log_pin='' identity dir ready=no collector_warned=no rootpxe_boot_notice_declaration
    shift 3
    rootpxe_boot_notice_declaration=$(declare -p rootpxe_boot_log_notice_state 2>/dev/null) || rootpxe_boot_notice_declaration=''
    if [[ $rootpxe_boot_notice_declaration != 'declare -A '* ]]; then
        unset rootpxe_boot_log_notice_state
        declare -gA rootpxe_boot_log_notice_state=()
    fi
    if rootpxe_log_type_valid "$name"; then unset 'rootpxe_boot_log_notice_state[$name]'; fi
    if rootpxe_log_type_valid "$name" && [[ $lifecycle == foreground-append ]] && dir=$(rootpxe_log_directory) && [[ -f $dir/$name && ! -L $dir/$name && -O $dir/$name ]]; then
        identity=$(LC_ALL=C stat -c '%d:%i:%a' -- "$dir/$name") || identity=''
        [[ $identity != *:600 ]] || ready=yes
    elif rootpxe_log_new_file "$name"; then identity=$rootpxe_log_created_identity; ready=yes; fi
    if [[ $ready == yes ]]; then
        dir=$(rootpxe_log_directory) || ready=no
        if [[ $ready == yes ]] && exec {rootpxe_boot_log_pin}<"$dir/$name"; then
            if ! rootpxe_log_pin_valid "$rootpxe_boot_log_pin" "$identity"; then
                # The pathname changed before opening. Close only this FD,
                # acquired in this scope, not an environment-supplied number.
                exec {rootpxe_boot_log_pin}<&- || true
                rootpxe_boot_log_pin=''; ready=no
            fi
        else ready=no; fi
    fi
    if [[ $ready == yes ]]; then
        if exec {rootpxe_boot_log_fd}> >(rootpxe_log_boot_stream "$name" "$identity" "$operation" "$rootpxe_boot_log_pin"); then
            collector=$!
            rootpxe_log_pin_release "$rootpxe_boot_log_pin" "$identity" || log_status=1
            rootpxe_boot_log_pin=''
            if "$@" >&"$rootpxe_boot_log_fd" 2>&1; then status=0; else status=$?; fi
            if exec {rootpxe_boot_log_fd}>&-; then
                if [[ $lifecycle != background ]]; then wait "$collector" || { log_status=1; collector_warned=yes; }; fi
            else log_status=1; fi
        else
            log_status=1
            rootpxe_log_pin_release "$rootpxe_boot_log_pin" "$identity" || true
            rootpxe_boot_log_pin=''
            if "$@" >/dev/null 2>&1; then status=0; else status=$?; fi
        fi
    else
        log_status=1
        if "$@" >/dev/null 2>&1; then status=0; else status=$?; fi
    fi
    if [[ $ready == yes && $log_status == 0 ]]; then rootpxe_boot_log_notice_state[$name]=$identity; fi
    [[ $log_status == 0 || $collector_warned == yes ]] || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
    return "$status"
}

rootpxe_log_notice() {
    local name="$1" dir declaration
    declaration=$(declare -p rootpxe_boot_log_notice_state 2>/dev/null) || declaration=''
    if rootpxe_log_type_valid "$name" && [[ $declaration == 'declare -A '* && -n ${rootpxe_boot_log_notice_state[$name]:-} ]] && dir=$(rootpxe_log_directory) && [[ -s $dir/$name && -f $dir/$name && ! -L $dir/$name && -O $dir/$name ]] && [[ $(stat -c '%d:%i:%a' -- "$dir/$name") == "${rootpxe_boot_log_notice_state[$name]}" && ${rootpxe_boot_log_notice_state[$name]} == *:600 ]]; then
        printf '[INFO]  Details: %s/%s\n' "$dir" "$name"
    else printf '[WARN]  Diagnostic log: unavailable.\n'; fi
}
