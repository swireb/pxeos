#!/bin/bash
# Adapts Partclone 0.3.48's official text-mode stderr to PXEOS's existing
# status file.  It deliberately stores one bounded, task-local record only.

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

rootpxe_partclone_progress_prepare() {
    local fifo="${1:-/tmp/pxeos-partclone-progress.$$.${RANDOM}.fifo}"
    [[ -n ${rootpxe_partclone_progress_run_id:-} ]] || rootpxe_partclone_progress_initialize || return 1
    rootpxe_partclone_progress_generation=$((rootpxe_partclone_progress_generation + 1))
    rootpxe_partclone_progress_write 0 partclone_started || return 1
    rm -f -- "$fifo" || return 1
    mkfifo "$fifo" || return 1
    rootpxe_partclone_progress_fifo="$fifo"
    rootpxe_partclone_progress_prepared=yes
}

rootpxe_partclone_progress_start_collector() {
    [[ ${rootpxe_partclone_progress_prepared:-} == yes && -p ${rootpxe_partclone_progress_fifo:-} ]] || return 1
    rootpxe_partclone_progress_decode "$rootpxe_partclone_progress_fifo" &
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
    wait "$rootpxe_partclone_progress_decoder_pid" || status=$?
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
