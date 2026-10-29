#!/bin/bash
# Capture alone writes its authenticated MAC staging directory directly.
rootpxe_capture_direct_prepare() {
    rootpxe_require_task_context || return 1
    [[ ${macWinSafe:-} =~ ^[0-9a-f]{12}$ && -d /storage && ! -L /storage && ! -L /storage/dev ]] || return 1
    mkdir -p /storage/dev || return 1
    imagePath="/storage/dev/$macWinSafe"
    [[ ! -L $imagePath && ( ! -e $imagePath || -d $imagePath ) ]] || return 1
    mkdir -p "$imagePath" || return 1
    find "$imagePath" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
    chmod 775 "$imagePath" || return 1
    printf '%s\n%s\n' "$taskid" "$progress_attempt" >"$imagePath/.rootpxe-capture-taskid" || return 1
    export imagePath
}

rootpxe_capture_begin_publish() {
    local response
    response=$(rootpxe_task_curl -ks --connect-timeout 5 --max-time 15 \
      --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" --data-urlencode "mac=$mac" \
      --data-urlencode stage=finalizing --data-urlencode status=running \
      --data-urlencode 'message=Capture writers finished; publishing current capture' "${pxeapi:-$web}stage") || return 1
    jq -e '.success == true' >/dev/null <<<"$response"
}

rootpxe_capture_direct_finalize() {
    local source="/storage/dev/$macWinSafe" relative target target_parent source_device target_device
    [[ $imagePath == "$source" && -d $source && ! -L $source ]] || return 1
    rootpxe_wait_for_writers || return 1
    rootpxe_capture_publish_metadata "$source" "$imgType" || return 1
    relative=$(rootpxe_safe_relative_path "$img") || return 1
    target="/storage/$relative"; target_parent=${target%/*}
    case "$target/" in "$source/"*|/storage/dev/*) return 1;; esac
    [[ ! -L $target && ( ! -e $target || -d $target ) ]] || return 1
    # Validate every target parent before creating it; never traverse a link.
    local parent=/storage segment
    local -a segments=(); IFS=/ read -r -a segments <<<"${relative%/*}"
    if [[ $relative == */* ]]; then
        for segment in "${segments[@]}"; do
            parent+="/$segment"
            [[ ! -L $parent && ( ! -e $parent || -d $parent ) ]] || return 1
            mkdir -p "$parent" || return 1
        done
    fi
    source_device=$(stat -c %d -- "$source") || return 1
    target_device=$(stat -c %d -- "$target_parent") || return 1
    [[ $source_device == "$target_device" ]] || return 1
    [[ ! -e $target || $(stat -c %d -- "$target") == "$source_device" ]] || return 1
    # This authenticated transaction fences administrator cancellation before
    # the first old-target mutation. No old tree is read or snapshotted.
    rootpxe_capture_begin_publish || return 1
    capture_size_bytes=$(rootpxe_directory_size_bytes "$source") || return 1
    [[ $capture_size_bytes =~ ^[1-9][0-9]*$ ]] || return 1
    [[ ! -d $target ]] || rm -rf -- "$target" || return 1
    mv -T -- "$source" "$target" || return 1
    rootpxe_final_capture_path=$target
    rootpxe_capture_published_attempt=$progress_attempt
    rootpxe_storage_published=yes
    imagePath=$target
    export capture_size_bytes rootpxe_final_capture_path rootpxe_capture_published_attempt rootpxe_storage_published imagePath
}

rootpxe_capture_run_producer() {
    if [[ ${rootpxe_capture_direct:-no} != yes ]]; then "$@"; return $?; fi
    local status=0
    setsid "$@" & rootpxe_capture_producer_pid=$!
    wait "$rootpxe_capture_producer_pid" || status=$?
    unset rootpxe_capture_producer_pid
    return "$status"
}

rootpxe_capture_direct_quiesce() {
    local pid mount_status
    rootpxe_capture_stopped=no
    local -a processes=()
    [[ -z ${rootpxe_capture_producer_pid:-} ]] || processes+=("$rootpxe_capture_producer_pid")
    processes+=("${writer_pids[@]}")
    for pid in "${processes[@]}"; do
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${processes[@]}"; do wait "$pid" 2>/dev/null || true; done
    unset rootpxe_capture_producer_pid
    writer_pids=()
    if [[ -n ${rootpxe_capture_xfs_mountpoint:-} ]]; then
        [[ -d $rootpxe_capture_xfs_mountpoint && ! -L $rootpxe_capture_xfs_mountpoint ]] || return 1
        mount_status=0
        mountpoint -q "$rootpxe_capture_xfs_mountpoint" || mount_status=$?
        case $mount_status in
            0) umount "$rootpxe_capture_xfs_mountpoint" || return 1;;
            1|32) ;;
            *) return 1;;
        esac
        rmdir "$rootpxe_capture_xfs_mountpoint" || return 1
        unset rootpxe_capture_xfs_mountpoint
    fi
    rootpxe_capture_stopped=yes
    export rootpxe_capture_stopped
}

rootpxe_capture_direct_stop_ack() {
    [[ ${rootpxe_capture_direct:-no} == yes && ${rootpxe_capture_released:-no} != yes ]] || return 0
    rootpxe_capture_direct_quiesce || return 1
    local response
    response=$(rootpxe_task_curl -ks --connect-timeout 5 --max-time 15 \
      --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" --data-urlencode "mac=$mac" \
      --data-urlencode workerStopped=true --data-urlencode errorCode=CAPTURE_STOPPED \
      --data-urlencode 'message=Capture writer processes stopped' "${pxeapi:-$web}error") || return 1
    jq -e '.accepted == true' >/dev/null <<<"$response" || return 1
    rootpxe_capture_released=yes
}
