#!/bin/bash
# Adapts Partclone 0.3.50's official ncurses VT screen when a bound Linux VT
# is usable, and its official text-mode stderr otherwise.  It deliberately
# stores one bounded, task-local record only.

: "${ROOTPXE_PROGRESS_STATUS_FILE:=/tmp/status.pxeos}"

# A decoder's initialized=0 is not a copy-start fact. Bind the explicit start
# marker to this task, retry and decoder run, including LVM child shells.
rootpxe_progress_data_phase_identity() {
    local stage=capture digest
    [[ ${type:-} =~ ^([Dd][Oo][Ww][Nn]|down)$ ]] && stage=restore
    [[ -n ${taskid:-} && -n ${rootpxe_partclone_progress_run_id:-${progress_run_id:-}} && -n ${task_token:-${execution_token:-}} ]] || return 1
    digest=$(printf '%s' "${task_token:-${execution_token:-}}" | sha256sum 2>/dev/null) || return 1
    digest=${digest%% *}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s|%s|%s|%s|%s' "$taskid" "${progress_attempt:-0}" "${rootpxe_partclone_progress_run_id:-${progress_run_id:-}}" "$stage" "$digest"
}

rootpxe_progress_data_phase_active() {
    local recorded expected
    expected=$(rootpxe_progress_data_phase_identity) || return 1
    [[ -r /tmp/pxeos.data-phase ]] || return 1
    IFS= read -r recorded </tmp/pxeos.data-phase || return 1
    [[ $recorded == "$expected" ]]
}

rootpxe_progress_data_phase_begin() {
    local stage=capture marker tmp
    rootpxe_progress_data_phase_active && return 0
    [[ ${type:-} =~ ^([Dd][Oo][Ww][Nn]|down)$ ]] && stage=restore
    [[ -n ${taskid:-} && -n ${rootpxe_partclone_progress_run_id:-} ]] || return 0
    marker=$(rootpxe_progress_data_phase_identity) || return 0
    # Keep the first real 0% visible even when a small partition finishes
    # between two three-second sampling cycles. Telemetry remains best effort.
    rootpxe_stage "$stage" 'progress=0' || true
    tmp=$(mktemp /tmp/pxeos.data-phase.XXXXXX 2>/dev/null) || return 0
    if printf '%s\n' "$marker" >"$tmp" 2>/dev/null; then
        mv "$tmp" /tmp/pxeos.data-phase >/dev/null 2>&1 || rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
    fi
    return 0
}

rootpxe_partclone_progress_write() {
    local pct="$1" message="${2:-partclone_progress}"
    [[ ${rootpxe_partclone_progress_run_id:-} =~ ^[A-Za-z0-9._-]{8,128}$ ]] || return 1
    [[ ${rootpxe_partclone_progress_generation:-} =~ ^[0-9]+$ ]] || return 1
    [[ $pct =~ ^[0-9]{1,3}$ && $pct -le 100 ]] || return 1
    # Progress persistence is telemetry.  A full /tmp or transient status
    # file failure must not turn a successful reader/producer/writer pipeline
    # into a failed imaging task.
    printf 'PXEOS_PROGRESS_V1|%s|%s|%s|%s\n' \
        "$rootpxe_partclone_progress_run_id" "$rootpxe_partclone_progress_generation" "$pct" "$message" \
        >"$ROOTPXE_PROGRESS_STATUS_FILE" 2>/dev/null || true
    return 0
}

rootpxe_partclone_progress_initialize() {
    local now
    now=$(date +%s 2>/dev/null) || return 1
    rootpxe_partclone_progress_run_id="${now}-${$}-${RANDOM}"
    rootpxe_partclone_progress_generation=0
    rootpxe_partclone_progress_write 0 initialized
}

rootpxe_partclone_progress_next_pct() {
    local status_file="$1" expected_run="$2" last_pct="$3" record prefix run generation pct message
    [[ $last_pct =~ ^[0-9]{1,3}$ && $last_pct -le 100 ]] || return 1
    [[ -r $status_file ]] || { printf '%s\n' "$last_pct"; return 0; }
    IFS= read -r record <"$status_file" || { printf '%s\n' "$last_pct"; return 0; }
    IFS='|' read -r prefix run generation pct message <<<"$record"
    [[ $prefix == PXEOS_PROGRESS_V1 && $run == "$expected_run" && $generation =~ ^[0-9]+$ && $pct =~ ^[0-9]{1,3}$ && $pct -le 100 && -n $message ]] \
        || { printf '%s\n' "$last_pct"; return 0; }
    printf '%s\n' "$pct"
}

rootpxe_partimage_progress_next_pct() {
    local status_file="$1" last_pct="$2" record pct
    [[ $last_pct =~ ^[0-9]{1,3}$ && $last_pct -le 100 ]] || return 1
    record=$(rootpxe_partimage_progress_status_line "$status_file")
    pct=$(LC_ALL=C printf '%s\n' "$record" | grep -oE '[0-9]+([.][0-9]+)?%' | head -n 1 | tr -d '%')
    pct=${pct%%.*}
    [[ $pct =~ ^[0-9]{1,3}$ && $pct -le 100 ]] || { printf '%s\n' "$last_pct"; return 0; }
    printf '%s\n' "$pct"
}

rootpxe_partimage_progress_status_line() {
    local status_file="$1"
    [[ -r $status_file ]] || return 0
    # This is a legacy Partimage stderr sink, potentially a single giant
    # CR-only line.  Bound bytes before any line-oriented reader runs.
    tail -c 8192 "$status_file" 2>/dev/null | tr '\r' '\n' | tail -n 2 | head -n 1 | cut -c1-4096
}

rootpxe_partclone_progress_sample_pct() {
    local line="$1" clean pct
    clean=$(LC_ALL=C printf '%s' "$line" | sed -E $'s/\033\\[[0-9;?]*[A-Za-z]//g') || return 1
    # progress.c writes this full form for IO/NO_BLOCK_DETAIL.  Bitmap also
    # prints "Completed" but has no data-speed field, so it is not a copy
    # sample.  Its `Current block ... Complete` line is likewise ignored.
    [[ $clean == *'Elapsed:'* && $clean == *'Remaining:'* && $clean == *'Completed:'* ]] || return 1
    pct=$(LC_ALL=C printf '%s\n' "$clean" | sed -nE 's/.*Completed:[[:space:]]*([0-9]{1,3})([.][0-9]+)?%.*/\1/p')
    [[ $pct =~ ^[0-9]{1,3}$ ]] || return 1
    if [[ $clean =~ Rate:[[:space:]]*[0-9]+([.][0-9]+)?[A-Za-z]+/[A-Za-z]+ ]] \
       || [[ $clean =~ ,[[:space:]]*[0-9]+([.][0-9]+)?[A-Za-z]+/[A-Za-z]+, ]]; then
        [[ $pct -le 100 ]] || return 1
        printf '%s\n' "$pct"
    else
        return 1
    fi
}

rootpxe_partclone_progress_decode() {
    local -x LC_ALL=C
    local fifo="$1" line='' char pct console_unavailable=no last_console_pct=-1 last_console_time=-1 now detail='' overflow=no line_overflow=no
    # Read one byte at a time so a pipe-buffered text transformer cannot defer
    # status until Partclone exits.  The retained parser buffer is capped;
    # image stdout is untouched.  Native diagnostic text is private, while
    # the console gets only throttled copy percentages.
    # Console rendering is telemetry too: if it disappears, keep draining the
    # FIFO so it cannot back-pressure Partclone or change writer semantics.
    while IFS= read -r -d '' -n 1 char; do
        if [[ $char == $'\r' || $char == $'\n' ]]; then
            [[ $line_overflow != yes ]] || line='[TRUNCATED: overlong Partclone diagnostic omitted]'
            if pct=$(rootpxe_partclone_progress_sample_pct "$line"); then
                rootpxe_partclone_progress_write "$pct" partclone_progress || return 1
                now=${SECONDS:-0}
                if [[ $console_unavailable != yes && $pct != "$last_console_pct" ]] && (( now > last_console_time || pct == 100 )); then
                    printf '[INFO]  Copy progress: %s%%\n' "$pct" >&2 || console_unavailable=yes
                    last_console_pct=$pct; last_console_time=$now
                fi
            elif [[ $line != *'Current block:'* && $line != *'Elapsed:'* && -n $line ]]; then
                line=$(rootpxe_log_redact "$line") || line='[Diagnostic unavailable]'
                detail+="$line"$'\n'
                if (( ${#detail} > 64000 )); then overflow=yes; detail=${detail: -64000}; fi
            fi
            line=''; line_overflow=no
        else
            if [[ $line_overflow != yes ]]; then
                line+="$char"
                if (( ${#line} > 4096 )); then overflow=yes; line=''; line_overflow=yes; fi
            fi
        fi
    done <"$fifo"
    [[ $line_overflow != yes ]] || line='[TRUNCATED: overlong Partclone diagnostic omitted]'
    if [[ -n $line ]] && pct=$(rootpxe_partclone_progress_sample_pct "$line"); then
        rootpxe_partclone_progress_write "$pct" partclone_progress || return 1
    elif [[ -n $line ]]; then
        line=$(rootpxe_log_redact "$line") || line='[Diagnostic unavailable]'
        detail+="$line"
        if (( ${#detail} > 64000 )); then overflow=yes; detail=${detail: -64000}; fi
    fi
    if [[ -n $detail ]] && declare -F rootpxe_task_log_append >/dev/null 2>&1; then
        detail=$(rootpxe_redact_diagnostic "$detail") || detail='[Diagnostic unavailable]'
        detail=$(rootpxe_utf8_safe_tail "$detail" 63000) || detail='[Diagnostic unavailable]'
        [[ $overflow != yes ]] || detail='[TRUNCATED: earlier Partclone diagnostic omitted]'$'\n'"$detail"
        rootpxe_task_log_append "OP=partclone_text"$'\n'"$detail" || {
            printf '[WARN]  Task log: unavailable.\n' >&2 || true
        }
    fi
    return 0
}

rootpxe_partclone_vt_device_is_usable() {
    local path="$1" access="$2"
    [[ -c $path || ( ${ROOTPXE_PARTCLONE_VT_TEST_ALLOW_REGULAR:-} == yes && -f $path ) ]] || return 1
    case "$access" in
        read) [[ -r $path ]] ;;
        write) [[ -w $path ]] ;;
        *) return 1 ;;
    esac
}

rootpxe_partclone_vt_device_path() {
    local name="$1" root="${ROOTPXE_PARTCLONE_VT_DEV_ROOT:-/dev}"
    printf '%s/%s\n' "${root%/}" "$name"
}

rootpxe_partclone_vt_number_from_stderr() {
    local target caller_pid proc_root tty0_active_file console_active_file tty0_active console_active
    target="${ROOTPXE_PARTCLONE_FD2_TARGET:-}"
    if [[ -z $target ]]; then
        # readlink itself redirects stderr, so /proc/self/fd/2 would name the
        # readlink child.  Preserve the caller shell PID before spawning it.
        caller_pid=$BASHPID
        proc_root="${ROOTPXE_PARTCLONE_PROC_ROOT:-/proc}"
        target=$(readlink "$proc_root/$caller_pid/fd/2" 2>/dev/null) || return 1
    fi
    if [[ $target =~ ^/dev/tty([1-9][0-9]*)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    # /dev/console has no fixed VT by itself.  Use it only when the kernel
    # reports one numeric active VT; serial and ambiguous consoles fall back.
    [[ $target == /dev/console ]] || return 1
    tty0_active_file="${ROOTPXE_PARTCLONE_VT_ACTIVE_FILE:-/sys/class/tty/tty0/active}"
    console_active_file="${ROOTPXE_PARTCLONE_VT_CONSOLE_ACTIVE_FILE:-/sys/class/tty/console/active}"
    IFS= read -r tty0_active <"$tty0_active_file" || return 1
    IFS= read -r console_active <"$console_active_file" || return 1
    [[ $tty0_active =~ ^tty([1-9][0-9]*)$ && $console_active == "$tty0_active" ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

rootpxe_partclone_vt_dimensions() {
    local vcsa="$1" rows cols cursor_x cursor_y
    rootpxe_partclone_vt_device_is_usable "$vcsa" read || return 1
    read -r rows cols cursor_x cursor_y < <(dd if="$vcsa" bs=1 count=4 2>/dev/null | od -An -tu1 2>/dev/null) || return 1
    [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || return 1
    (( rows >= 23 && cols >= 62 && rows <= 200 && cols <= 500 )) || return 1
    printf '%s %s\n' "$rows" "$cols"
}

rootpxe_partclone_vt_linux_terminfo_available() {
    local root
    for root in ${ROOTPXE_PARTCLONE_VT_TERMINFO_ROOTS:-/usr/share/terminfo /usr/lib/terminfo /lib/terminfo /etc/terminfo}; do
        [[ -r "$root/l/linux" || -r "$root/6c/linux" ]] && return 0
    done
    return 1
}

rootpxe_partclone_vt_clear_target() {
    local tty="$1"
    # This exact target was resolved from fd2; never clear the active console
    # by name after it may have changed focus.
    printf '\033[2J\033[H' >"$tty"
}

rootpxe_partclone_vt_snapshot() {
    local LC_ALL=C vcs="$1" vcsa="$2" dimensions dimensions_after rows cols rows_after cols_after byte_count screen
    rootpxe_partclone_vt_device_is_usable "$vcs" read || return 2
    rootpxe_partclone_vt_device_is_usable "$vcsa" read || return 2
    dimensions=$(rootpxe_partclone_vt_dimensions "$vcsa") || return 1
    read -r rows cols <<<"$dimensions"
    byte_count=$((rows * cols))
    screen=$(dd if="$vcs" bs="$byte_count" count=1 2>/dev/null) || return 2
    [[ ${#screen} -eq $byte_count ]] || return 1
    dimensions_after=$(rootpxe_partclone_vt_dimensions "$vcsa") || return 1
    read -r rows_after cols_after <<<"$dimensions_after"
    [[ $rows == "$rows_after" && $cols == "$cols_after" ]] || return 1
    rootpxe_partclone_progress_vt_snapshot_rows="$rows"
    rootpxe_partclone_progress_vt_snapshot_cols="$cols"
    rootpxe_partclone_progress_vt_snapshot="$screen"
}

rootpxe_partclone_progress_is_current() {
    local run="$1" generation="$2" record prefix actual_run actual_generation pct message
    [[ -r $ROOTPXE_PROGRESS_STATUS_FILE ]] || return 1
    IFS= read -r record <"$ROOTPXE_PROGRESS_STATUS_FILE" || return 1
    IFS='|' read -r prefix actual_run actual_generation pct message <<<"$record"
    [[ $prefix == PXEOS_PROGRESS_V1 && $actual_run == "$run" && $actual_generation == "$generation" ]]
}

rootpxe_partclone_vt_sample_pct() {
    local LC_ALL=C vcs="$1" vcsa="$2" row rows cols marker sample pct snapshot
    rootpxe_partclone_vt_snapshot "$vcs" "$vcsa" || return $?
    rows="$rootpxe_partclone_progress_vt_snapshot_rows"
    cols="$rootpxe_partclone_progress_vt_snapshot_cols"
    snapshot="$rootpxe_partclone_progress_vt_snapshot"
    for ((row = 0; row < rows - 1; row++)); do
        marker="${snapshot:row * cols:cols}"
        [[ $marker == *'Data Block Process:'* ]] || continue
        sample="${snapshot:(row + 1) * cols:cols}"
        # The official ncurses row includes box-drawing characters around the
        # percent.  Accept one standalone percentage only; never use a suffix
        # of 1000%/142% and never accept a row containing two percentages.
        if [[ $sample =~ ^[^0-9%]*([0-9]{1,3})([.][0-9]+)?%[^0-9%]*$ ]]; then
            pct="${BASH_REMATCH[1]}"
        else
            continue
        fi
        if [[ $pct =~ ^[0-9]{1,3}$ ]]; then
            [[ $pct -le 100 ]] || return 1
            printf '%s\n' "$pct"
            return 0
        fi
        return 1
    done
    return 1
}

rootpxe_partclone_progress_pause() {
    if command -v usleep >/dev/null 2>&1; then
        usleep 250000
    else
        sleep 0.25
    fi
}

rootpxe_partclone_vt_observe() {
    local run="$1" generation="$2" vcs="$3" vcsa="$4" pct status
    while rootpxe_partclone_progress_is_current "$run" "$generation"; do
        if pct=$(rootpxe_partclone_vt_sample_pct "$vcs" "$vcsa"); then
            rootpxe_partclone_progress_is_current "$run" "$generation" || return 0
            rootpxe_partclone_progress_write "$pct" partclone_progress || return 1
        else
            status=$?
            (( status == 1 )) || return "$status"
        fi
        rootpxe_partclone_progress_pause || return 0
    done
}

rootpxe_partclone_progress_prepare() {
    local fifo="${1:-/tmp/pxeos-partclone-progress.$$.${RANDOM}.fifo}"
    local vt rows cols vcsa vcs tty dimensions
    [[ -n ${rootpxe_partclone_progress_run_id:-} ]] || rootpxe_partclone_progress_initialize || return 1
    rootpxe_partclone_progress_generation=$((rootpxe_partclone_progress_generation + 1))
    rootpxe_partclone_progress_write 0 partclone_started || return 1
    rootpxe_partclone_log_finish
    # Native -L is diagnostic-only. Never prevent cloning when its private
    # output cannot be prepared; /dev/null is an explicit safe native fallback.
    rootpxe_partclone_native_log=/dev/null
    export -n rootpxe_partclone_native_log
    unset rootpxe_partclone_native_log_state
    declare -gA rootpxe_partclone_native_log_state=()
    if rootpxe_log_raw_file && [[ -f $rootpxe_log_raw_path && ! -L $rootpxe_log_raw_path && -O $rootpxe_log_raw_path ]] \
        && rootpxe_partclone_native_log_state[identity]=$(LC_ALL=C stat -c '%d:%i:%a' -- "$rootpxe_log_raw_path") \
        && [[ ${rootpxe_partclone_native_log_state[identity]} == *:600 ]]; then
        rootpxe_partclone_native_log=$rootpxe_log_raw_path
        rootpxe_partclone_native_log_state[raw]=$rootpxe_partclone_native_log
        rootpxe_log_new_file partclone.log || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
    else
        unset rootpxe_partclone_native_log_state
        printf '[WARN]  Diagnostic log: unavailable; Partclone uses /dev/null.\n' >&2
    fi
    rootpxe_partclone_progress_args=(-L "$rootpxe_partclone_native_log")
    rootpxe_partclone_progress_mode=text
    rootpxe_partclone_progress_term="${TERM:-dumb}"
    rootpxe_partclone_progress_stderr_target="$fifo"
    if vt=$(rootpxe_partclone_vt_number_from_stderr); then
        tty=$(rootpxe_partclone_vt_device_path "tty$vt")
        vcs=$(rootpxe_partclone_vt_device_path "vcs$vt")
        vcsa=$(rootpxe_partclone_vt_device_path "vcsa$vt")
        if rootpxe_partclone_vt_device_is_usable "$tty" write \
            && rootpxe_partclone_vt_device_is_usable "$vcs" read \
            && rootpxe_partclone_vt_linux_terminfo_available \
            && dimensions=$(rootpxe_partclone_vt_dimensions "$vcsa"); then
            read -r rows cols <<<"$dimensions"
            if rootpxe_partclone_vt_clear_target "$tty"; then
                rootpxe_partclone_progress_mode=gui
                rootpxe_partclone_progress_args=(-N -L "$rootpxe_partclone_native_log")
                rootpxe_partclone_progress_stderr_target="$tty"
                rootpxe_partclone_progress_term=linux
                rootpxe_partclone_progress_vt="$vt"
                rootpxe_partclone_progress_vcs="$vcs"
                rootpxe_partclone_progress_vcsa="$vcsa"
                rootpxe_partclone_progress_rows="$rows"
                rootpxe_partclone_progress_cols="$cols"
                rootpxe_partclone_progress_fifo=
                rootpxe_partclone_progress_prepared=yes
                return 0
            fi
        fi
    fi
    rm -f -- "$fifo" || { rootpxe_partclone_log_finish; return 1; }
    mkfifo "$fifo" || { rootpxe_partclone_log_finish; return 1; }
    rootpxe_partclone_progress_fifo="$fifo"
    rootpxe_partclone_progress_prepared=yes
}

rootpxe_partclone_log_finish() {
    local raw identity
    [[ $(declare -p rootpxe_partclone_native_log_state 2>/dev/null) == 'declare -A '* ]] || return 0
    raw=${rootpxe_partclone_native_log_state[raw]:-}
    [[ -n $raw && -f $raw && ! -L $raw && -O $raw ]] || { unset rootpxe_partclone_native_log_state rootpxe_partclone_native_log; return 0; }
    identity=$(LC_ALL=C stat -c '%d:%i:%a' -- "$raw") || return 0
    if [[ $identity != "${rootpxe_partclone_native_log_state[identity]:-}" || $identity != *:600 ]]; then
        unset rootpxe_partclone_native_log_state rootpxe_partclone_native_log
        printf '[WARN]  Diagnostic log: unavailable.\n' >&2
        return 0
    fi
    rootpxe_log_publish partclone.log "$raw" partclone yes || printf '[WARN]  Diagnostic log: unavailable.\n' >&2
    rm -f -- "$raw"
    unset rootpxe_partclone_native_log_state rootpxe_partclone_native_log
}

rootpxe_partclone_progress_start_collector() {
    [[ ${rootpxe_partclone_progress_prepared:-} == yes ]] || return 1
    if [[ ${rootpxe_partclone_progress_mode:-} == gui ]]; then
        rootpxe_partclone_vt_observe "$rootpxe_partclone_progress_run_id" "$rootpxe_partclone_progress_generation" \
            "$rootpxe_partclone_progress_vcs" "$rootpxe_partclone_progress_vcsa" &
    else
        [[ -p ${rootpxe_partclone_progress_fifo:-} ]] || return 1
        rootpxe_partclone_progress_decode "$rootpxe_partclone_progress_fifo" &
    fi
    rootpxe_partclone_progress_decoder_pid=$!
    unset rootpxe_partclone_progress_prepared
}

rootpxe_partclone_progress_start() {
    rootpxe_partclone_progress_prepare "${1:-}" || return 1
    rootpxe_partclone_progress_start_collector
}

rootpxe_partclone_progress_wait() {
    local status=0 fifo="${rootpxe_partclone_progress_fifo:-}"
    [[ ${rootpxe_partclone_progress_decoder_pid:-} =~ ^[0-9]+$ ]] || { rootpxe_partclone_log_finish; return 1; }
    if [[ ${rootpxe_partclone_progress_mode:-} == gui ]]; then
        if kill -0 "$rootpxe_partclone_progress_decoder_pid" >/dev/null 2>&1; then
            kill "$rootpxe_partclone_progress_decoder_pid" >/dev/null 2>&1 || true
            wait "$rootpxe_partclone_progress_decoder_pid" >/dev/null 2>&1 || status=$?
            (( status == 143 )) && status=0
        else
            wait "$rootpxe_partclone_progress_decoder_pid" || status=$?
        fi
    else
        wait "$rootpxe_partclone_progress_decoder_pid" || status=$?
    fi
    [[ -z $fifo ]] || rm -f -- "$fifo" || status=1
    unset rootpxe_partclone_progress_decoder_pid rootpxe_partclone_progress_fifo rootpxe_partclone_progress_prepared
    rootpxe_partclone_log_finish
    return "$status"
}

rootpxe_partclone_progress_abort() {
    local pid="${rootpxe_partclone_progress_decoder_pid:-}" fifo="${rootpxe_partclone_progress_fifo:-}" status=0
    if [[ $pid =~ ^[0-9]+$ ]]; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    fi
    [[ -z $fifo ]] || rm -f -- "$fifo" || status=1
    unset rootpxe_partclone_progress_decoder_pid rootpxe_partclone_progress_fifo rootpxe_partclone_progress_prepared
    rootpxe_partclone_log_finish
    return "$status"
}
