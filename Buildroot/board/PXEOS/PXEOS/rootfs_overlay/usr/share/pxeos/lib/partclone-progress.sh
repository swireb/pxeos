#!/bin/bash
# Adapts Partclone 0.3.48's official ncurses VT screen when a bound Linux VT
# is usable, and its official text-mode stderr otherwise.  It deliberately
# stores one bounded, task-local record only.

: "${ROOTPXE_PROGRESS_STATUS_FILE:=/tmp/status.pxeos}"

rootpxe_partclone_progress_write() {
    local pct="$1" message="${2:-partclone_progress}"
    [[ ${rootpxe_partclone_progress_run_id:-} =~ ^[A-Za-z0-9._-]{8,128}$ ]] || return 1
    [[ ${rootpxe_partclone_progress_generation:-} =~ ^[0-9]+$ ]] || return 1
    [[ $pct =~ ^[0-9]{1,3}$ && $pct -le 100 ]] || return 1
    printf 'PXEOS_PROGRESS_V1|%s|%s|%s|%s\n' \
        "$rootpxe_partclone_progress_run_id" "$rootpxe_partclone_progress_generation" "$pct" "$message" \
        >"$ROOTPXE_PROGRESS_STATUS_FILE"
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
    local fifo="$1" line='' char pct
    # Read one byte at a time so a pipe-buffered text transformer cannot defer
    # status until Partclone exits.  The retained parser buffer is capped;
    # console stderr still receives every byte and image stdout is untouched.
    while IFS= read -r -d '' -n 1 char; do
        printf '%s' "$char" >&2 || return 1
        if [[ $char == $'\r' || $char == $'\n' ]]; then
            if pct=$(rootpxe_partclone_progress_sample_pct "$line"); then
                rootpxe_partclone_progress_write "$pct" partclone_progress || return 1
            fi
            line=''
        elif (( ${#line} < 4096 )); then
            line+="$char"
        fi
    done <"$fifo"
    if [[ -n $line ]] && pct=$(rootpxe_partclone_progress_sample_pct "$line"); then
        rootpxe_partclone_progress_write "$pct" partclone_progress || return 1
    fi
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
    rootpxe_partclone_progress_args=()
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
                rootpxe_partclone_progress_args=(-N)
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
    rm -f -- "$fifo" || return 1
    mkfifo "$fifo" || return 1
    rootpxe_partclone_progress_fifo="$fifo"
    rootpxe_partclone_progress_prepared=yes
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
    [[ ${rootpxe_partclone_progress_decoder_pid:-} =~ ^[0-9]+$ ]] || return 1
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
    return "$status"
}

rootpxe_partclone_progress_abort() {
    local pid="${rootpxe_partclone_progress_decoder_pid:-}" fifo="${rootpxe_partclone_progress_fifo:-}"
    if [[ $pid =~ ^[0-9]+$ ]]; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    fi
    [[ -z $fifo ]] || rm -f -- "$fifo" || return 1
    unset rootpxe_partclone_progress_decoder_pid rootpxe_partclone_progress_fifo rootpxe_partclone_progress_prepared
}
