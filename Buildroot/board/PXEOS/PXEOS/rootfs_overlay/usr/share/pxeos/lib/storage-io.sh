#!/bin/bash
# The root controller owns local disks and private metadata. Every NAS open is
# performed by the fixed helper after establishing the configured identity.
rootpxe_storage_helper=/usr/sbin/rootpxe-storage-io

rootpxe_storage_capabilities() {
    [[ -x $rootpxe_storage_helper ]] || return 1
    "$rootpxe_storage_helper" --capabilities | jq -ce '.version == 1 and .helper and .numericIdentity and .durablePublish' >/dev/null
}

rootpxe_storage_apply_context() {
    local document=$1 direction=read previous
    rootpxe_storage_capabilities || return 1
    [[ ${taskType:-} == capture ]] && direction=write
    jq -e --arg id "$taskid" --arg kind "$taskType" --argjson attempt "$progress_attempt" '
      .storageAccess as $s | $s.version == 1 and
      $s.execution.taskId == $id and $s.execution.taskType == $kind and
      $s.execution.executionAttempt == $attempt and
      ($s.execution.domainId|test("^[a-f0-9]{32}$")) and
      ($s.execution.nonce|test("^[a-f0-9]{32}$")) and
      ($s.execution.targetKey|test("^[a-f0-9]{64}$")) and
      ($s.execution.configRevision|test("^[a-f0-9]{64}$")) and
      ($s.protocol == "nfs" or $s.protocol == "smb") and
      ($s.server|type == "string" and length > 0) and
      ($s.exportPath|type == "string" and length > 0) and
      ($s.imagePath|type == "string" and length > 0) and
      (if $s.protocol == "nfs" then
        ($s.nfsVersion|IN("auto","3","4.0","4.1","4.2")) and
        all([$s.nfsUid,$s.nfsGid][]; type == "number" and . == floor and . >= 0 and . <= 4294967294)
       else ($s.smbVersion|IN("auto","2.1","3.0","3.0.2","3.1.1")) end)' >/dev/null <<<"$document" || return 1
    if [[ -n ${rootpxe_storage_workspace:-} ]]; then
        [[ -f $rootpxe_storage_workspace/context.json && ! -L $rootpxe_storage_workspace/context.json ]] || return 1
        previous=$(jq -c '.execution' "$rootpxe_storage_workspace/context.json") || return 1
        [[ $previous == "$(jq -c '.storageAccess.execution' <<<"$document")" ]] || return 1
        return 0
    fi
    umask 077
    rootpxe_storage_workspace=$(mktemp -d /tmp/rootpxe-storage.XXXXXX) || return 1
    mkdir "$rootpxe_storage_workspace/image" || return 1
    jq -c --arg direction "$direction" '.storageAccess + {direction:$direction} |
      if .pxeosConnection.actualVersion then
        if .protocol == "nfs" then .nfsVersion=.pxeosConnection.actualVersion
        else .smbVersion=.pxeosConnection.actualVersion end
      else . end' <<<"$document" >"$rootpxe_storage_workspace/context.json" || return 1
    rootpxe_storage_nonce=$(jq -r '.execution.nonce' "$rootpxe_storage_workspace/context.json") || return 1
    rootpxe_storage_worker_nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
    [[ $rootpxe_storage_worker_nonce =~ ^[a-f0-9]{32}$ ]] || return 1
    rootpxe_storage_stage="dev/$taskid/$progress_attempt"
    rootpxe_storage_lock=".locks/$(jq -r '.execution.targetKey' "$rootpxe_storage_workspace/context.json")"
    : >"$rootpxe_storage_workspace/payloads.ndjson"
    : >"$rootpxe_storage_workspace/command.lock"
    export rootpxe_storage_workspace rootpxe_storage_nonce rootpxe_storage_worker_nonce rootpxe_storage_stage rootpxe_storage_lock
}

rootpxe_storage_call() {
    local endpoint=$1 response; shift
    response=$(rootpxe_task_curl -ks --connect-timeout 10 --max-time 30 --max-filesize 8388608 \
      --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" --data-urlencode "mac=$mac" \
      --data-urlencode "attempt=$progress_attempt" --data-urlencode "storageNonce=$rootpxe_storage_nonce" \
      --data-urlencode "workerNonce=$rootpxe_storage_worker_nonce" "$@" "${pxeapi:-$web}storage/$endpoint") || return 1
    jq -e '.success == true' >/dev/null <<<"$response" || return 1
    printf '%s\n' "$response"
}

rootpxe_storage_native() {
    local mode=$1 native_result
    [[ $mode == resolve || $mode == mount-nfs ]] || return 1
    # FD6 is a real local pipe even when this function's caller discards stdout.
    # The fixed helper emits one bounded JSON event and its own exit is waited;
    # a downstream parser's success never substitutes for the native status.
    native_result=$(
        native_pid='' watchdog='' status=0
        "$rootpxe_storage_helper" "--$mode" --context-fd 3 --result-fd 6 \
          3<"$rootpxe_storage_workspace/context.json" 6>&1 2>/dev/null & native_pid=$!
        (sleep 30 & timer=$!; trap 'kill -TERM "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true' EXIT TERM INT; wait "$timer"; kill -TERM "$native_pid" 2>/dev/null || true) >/dev/null 2>&1 & watchdog=$!
        wait "$native_pid" || status=$?
        kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
        exit "$status"
    ) || return 1
    (( ${#native_result} <= 65536 )) || return 1
    if [[ $mode == mount-nfs ]]; then jq -e '.event == "mount" and .mounted == true and .errno == 0' >/dev/null <<<"$native_result" || return 1
    else jq -e '(.numericAddress|type == "string") and (.mountServer|type == "string") and (.port|type == "number")' >/dev/null <<<"$native_result" || return 1; fi
    printf '%s\n' "$native_result"
}

rootpxe_storage_stop() {
    local status=0 helper_pid=${rootpxe_storage_pid:-}
    [[ ${rootpxe_storage_request_fd:-} =~ ^[0-9]+$ ]] && exec {rootpxe_storage_request_fd}>&-
    unset rootpxe_storage_request_fd
    [[ ${rootpxe_storage_data_fd:-} =~ ^[0-9]+$ ]] && exec {rootpxe_storage_data_fd}>&-
    unset rootpxe_storage_data_fd
    if [[ $helper_pid =~ ^[0-9]+$ ]]; then
        while :; do
            status=0; wait "$helper_pid" || status=$?
            kill -0 "$helper_pid" 2>/dev/null || break
        done
    fi
    [[ ${rootpxe_storage_result_fd:-} =~ ^[0-9]+$ ]] && exec {rootpxe_storage_result_fd}<&-
    unset rootpxe_storage_pid rootpxe_storage_result_fd
    rootpxe_storage_stopped=yes
    return "$status"
}

# mount.cifs is a local child with a bounded cancellation supervisor. Reaping
# the actual child is required even after TERM/KILL; signalling is no receipt.
rootpxe_storage_mount_smb() (
    local mount_pid='' watchdog='' status=0 cancelled=0
    stop_mount() {
        [[ -z $mount_pid ]] || kill -TERM "$mount_pid" 2>/dev/null || true
    }
    trap 'cancelled=1; stop_mount' TERM INT HUP
    mount.cifs "$@" >/dev/null 2>&1 & mount_pid=$!
    (
        timer=''
        stop_timer() {
            [[ -n $timer ]] || return 0
            kill -TERM "$timer" 2>/dev/null || true
            while :; do
                wait "$timer" 2>/dev/null || true
                kill -0 "$timer" 2>/dev/null || break
            done
            timer=''
        }
        trap 'stop_timer; exit' TERM INT HUP
        sleep 30 & timer=$!; wait "$timer" || exit; timer=''
        kill -TERM "$mount_pid" 2>/dev/null || true
        sleep 5 & timer=$!; wait "$timer" || exit; timer=''
        kill -KILL "$mount_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 & watchdog=$!
    # A signal may interrupt wait before the child exits. Keep the supervisor
    # alive and perform a real second wait before any cleanup/release path.
    while :; do
        status=0; wait "$mount_pid" || status=$?
        kill -0 "$mount_pid" 2>/dev/null || break
    done
    kill -TERM "$watchdog" 2>/dev/null || true
    while :; do
        wait "$watchdog" 2>/dev/null || true
        kill -0 "$watchdog" 2>/dev/null || break
    done
    [[ $cancelled -eq 0 ]] || status=1
    exit "$status"
)

rootpxe_storage_start() {
    local direction ready initial_data anchor_request anchor_result previous_sequence response_sequence context="$rootpxe_storage_workspace/context.json"
    [[ -z ${rootpxe_storage_pid:-} ]] || return 1
    direction=$(jq -r '.direction' "$context") || return 1
    # These FIFOs belong to this private controller instance. Remove only its
    # previous local IPC endpoints after the original child has been waited.
    rm -f -- "$rootpxe_storage_workspace/request" "$rootpxe_storage_workspace/result" "$rootpxe_storage_workspace/data"
    mkfifo -m 600 "$rootpxe_storage_workspace/request" "$rootpxe_storage_workspace/result" "$rootpxe_storage_workspace/data" || return 1
    exec {anchor_request}<>"$rootpxe_storage_workspace/request"
    exec {anchor_result}<>"$rootpxe_storage_workspace/result"
    if [[ $direction == write ]]; then
        "$rootpxe_storage_helper" --context-fd 3 --request-fd 4 --data-fd 5 --result-fd 6 \
          3<"$context" 4<"$rootpxe_storage_workspace/request" 5<"$rootpxe_storage_workspace/data" 6>"$rootpxe_storage_workspace/result" &
        rootpxe_storage_pid=$!
        exec {initial_data}>"$rootpxe_storage_workspace/data"
    else
        "$rootpxe_storage_helper" --context-fd 3 --request-fd 4 --data-fd 5 --result-fd 6 \
          3<"$context" 4<"$rootpxe_storage_workspace/request" 5>"$rootpxe_storage_workspace/data" 6>"$rootpxe_storage_workspace/result" &
        rootpxe_storage_pid=$!
        exec {rootpxe_storage_data_fd}<"$rootpxe_storage_workspace/data"
    fi
    exec {rootpxe_storage_request_fd}>"$rootpxe_storage_workspace/request"
    exec {rootpxe_storage_result_fd}<"$rootpxe_storage_workspace/result"
    exec {anchor_request}>&-; exec {anchor_result}>&-
    if ! IFS= read -r -t 30 -u "$rootpxe_storage_result_fd" ready; then
        kill -TERM "$rootpxe_storage_pid" 2>/dev/null || true
        [[ -z ${initial_data:-} ]] || exec {initial_data}>&-
        rootpxe_storage_stop || true; return 1
    fi
    [[ -z ${initial_data:-} ]] || exec {initial_data}>&-
    jq -e '.event == "connection-info" and (.node.fileId|test("^[a-f0-9]+$"))' >/dev/null <<<"$ready" || return 1
    printf '%s\n' "$ready" >"$rootpxe_storage_workspace/ready.json"
    rootpxe_storage_actual_version=$(jq -r '.connection.actualVersion' <<<"$ready") || return 1
    rootpxe_storage_root_file_id=$(jq -r '.node.fileId' <<<"$ready") || return 1
    local -a reconcile_args=()
    [[ ${rootpxe_storage_reconcile:-no} != yes ]] || reconcile_args=(--data-urlencode previousWorkerStopped=true)
    if ! rootpxe_storage_call preflight --data-urlencode "actualVersion=$rootpxe_storage_actual_version" \
      --data-urlencode "rootFileId=$rootpxe_storage_root_file_id" "${reconcile_args[@]}" >"$rootpxe_storage_workspace/preflight.json"; then
        kill -TERM "$rootpxe_storage_pid" 2>/dev/null || true; rootpxe_storage_stop || true; return 1
    fi
    rootpxe_storage_reconcile=no
    previous_sequence=$(jq -r '.sequence' "$context") || return 1
    response_sequence=$(jq -er '.sequence | strings' "$rootpxe_storage_workspace/preflight.json") || return 1
    if [[ $previous_sequence != "$response_sequence" ]]; then
        # A joined old worker/new authenticated boot was reconciled before any
        # command. Start the helper at the newly persisted sequence, never ACK
        # a stale event just to keep an old process running.
        rootpxe_storage_stop || return 1
        rootpxe_storage_update_context "$direction" "$response_sequence" || return 1
        rootpxe_storage_start
        return
    fi
    jq -er '.nextSequence | strings' "$rootpxe_storage_workspace/preflight.json" >"$rootpxe_storage_workspace/next-sequence" || return 1
    rootpxe_storage_stopped=no
}

rootpxe_storage_local_payload() {
    local event=$1 relative file size inode
    relative=$(jq -r '.path' <<<"$event") || return 1
    [[ $relative == "$rootpxe_storage_stage/payload/"* ]] || return 0
    relative=${relative#"$rootpxe_storage_stage/payload/"}
    rootpxe_safe_relative_path "$relative" >/dev/null || return 1
    file="$rootpxe_storage_workspace/image/$relative"
    if [[ $(jq -r '.operation' <<<"$event") == remove-owned ]]; then
        rm -f -- "$file" || return 1
        jq -cs --arg path "$relative" '.[]|select(.path != $path)' "$rootpxe_storage_workspace/payloads.ndjson" >"$rootpxe_storage_workspace/payloads.next" || return 1
        mv -- "$rootpxe_storage_workspace/payloads.next" "$rootpxe_storage_workspace/payloads.ndjson"
        return
    fi
    size=$(jq -r '.node.size' <<<"$event") || return 1
    [[ $size =~ ^[0-9]+$ && ! -e $file && ! -L $file ]] || return 1
    mkdir -p -- "${file%/*}" || return 1
    truncate -s "$size" -- "$file" || return 1
    inode=$(stat -c %i -- "$file") || return 1
    jq -cn --arg path "$relative" --arg inode "$inode" --arg size "$size" --arg digest "$(jq -r '.node.sha256' <<<"$event")" \
      '{path:$path,inode:$inode,size:$size,sha256:$digest}' >>"$rootpxe_storage_workspace/payloads.ndjson"
}

# One command at a time, including all split-file receipts and data transfer.
# The data writer is connected before the command; no helper holds a write end
# of its own read FIFO. Every fixed write must reach EOF at its declared size.
rootpxe_storage_exec() (
    local operation=$1 path=$2 argument=${3:-} mode=${4:-} sequence command event phase response data_pid='' data_status=0 write_fd='' expected key
    trap 'if [[ -n $data_pid ]]; then kill -TERM "$data_pid" 2>/dev/null || true; while :; do wait "$data_pid" 2>/dev/null || true; kill -0 "$data_pid" 2>/dev/null || break; done; fi; [[ -z $write_fd ]] || exec {write_fd}>&-' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    exec {command_lock}>"$rootpxe_storage_workspace/command.lock"; flock -x "$command_lock" || return 1
    sequence=$(cat "$rootpxe_storage_workspace/next-sequence") || return 1
    [[ $sequence =~ ^[1-9][0-9]*$ && ${#sequence} -le 20 ]] || return 1
    command=$(jq -cn --arg operation "$operation" --arg path "$path" --arg sequence "$sequence" \
      --slurpfile context "$rootpxe_storage_workspace/context.json" '{operation:$operation,path:$path,sequence:$sequence,execution:$context[0].execution}') || return 1
    if [[ $operation == rename-owned ]]; then command=$(jq -c --arg to "$argument" '.+{to:$to}' <<<"$command") || return 1; fi
    if [[ $operation == write || $operation == write-split ]]; then
        exec {write_fd}>"$rootpxe_storage_workspace/data" || return 1
        if [[ $operation == write ]]; then
            [[ -f $argument && ! -L $argument ]] || return 1
            expected=$(stat -c %s -- "$argument") || return 1
            command=$(jq -c --arg expectedSize "$expected" '.+{lengthMode:"fixed",expectedSize:$expectedSize}' <<<"$command") || return 1
            cat -- "$argument" >&"$write_fd" & data_pid=$!
        else
            [[ $mode == 0 || $mode == 209715200 ]] || return 1
            command=$(jq -c --argjson bytes "$mode" '.+{splitBytes:$bytes}' <<<"$command") || return 1
            cat <&0 >&"$write_fd" & data_pid=$!
        fi
        exec {write_fd}>&-; write_fd=''
    fi
    printf '%s\n' "$command" >&"$rootpxe_storage_request_fd" || return 1
    while IFS= read -r -t 30 -u "$rootpxe_storage_result_fd" event; do
        phase=$(jq -r '.event' <<<"$event") || break
        if [[ $phase == progress ]]; then
            jq -e '.stage|IN("read","write","readback")' >/dev/null <<<"$event" || break
            [[ $(jq -r '.bytes' <<<"$event") =~ ^[0-9]+$ ]] || break
            continue
        fi
        [[ $phase != done ]] || { [[ -z $data_pid ]] || wait "$data_pid" || data_status=$?; data_pid=''; return "$data_status"; }
        [[ $phase == intent || $phase == created || $phase == result ]] || break
        response=$(rootpxe_storage_call publish-checkpoint --data-urlencode "event=$event") || break
        if [[ $operation == read && $phase == intent ]]; then
            key=$(printf '%s' "$path" | sha256sum | cut -d ' ' -f1) || break
            expected=$(jq -er --arg key "$key" '.ack.proof[$key].size | strings' <<<"$response") || break
            [[ $expected =~ ^[0-9]+$ ]] || break
            if [[ $argument == - ]]; then head -c "$expected" <&"$rootpxe_storage_data_fd" &
            else [[ $argument == "$rootpxe_storage_workspace/"* && ! -L $argument ]] || break; head -c "$expected" <&"$rootpxe_storage_data_fd" >"$argument" & fi
            data_pid=$!
        fi
        if [[ $operation == write-split && $phase == result ]]; then rootpxe_storage_local_payload "$event" || break; fi
        jq -er '.nextSequence | strings' <<<"$response" >"$rootpxe_storage_workspace/next-sequence" || break
        jq -c '.ack' <<<"$response" >&"$rootpxe_storage_request_fd" || break
    done
    kill -TERM "$rootpxe_storage_pid" 2>/dev/null || true
    return 1
)

rootpxe_storage_ensure_parents() {
    local path=$1 parent current='' segment
    parent=${path%/*}; [[ $parent != "$path" ]] || return 0
    local -a segments=(); IFS=/ read -r -a segments <<<"$parent"
    for segment in "${segments[@]}"; do current=${current:+$current/}$segment; rootpxe_storage_exec mkdir-owned "$current" || return 1; done
}

rootpxe_storage_prepare_capture() {
    local owner_file="$rootpxe_storage_workspace/owner.json"
    rootpxe_storage_exec mkdir-owned .locks || return 1
    rootpxe_storage_exec mkdir-owned "$rootpxe_storage_lock" || return 1
    jq -j '.ownerContent' "$rootpxe_storage_workspace/preflight.json" >"$owner_file" || return 1
    rootpxe_storage_exec write "$rootpxe_storage_lock/owner" "$owner_file" || return 1
    rootpxe_storage_ensure_parents "$rootpxe_storage_stage/payload/file" || return 1
}

rootpxe_storage_is_payload() {
    local name=${1##*/}
    [[ $name == *.img || $name =~ \.img\.[0-9]{3}$ || $name == sys.img.* || ( ${imgType:-} == dd && $1 == "$img"* ) ]]
}

rootpxe_storage_load_shadow() {
    local offset=0 response next total path kind size destination count=0 bytes=0
    : >"$rootpxe_storage_workspace/manifest.ndjson"
    while :; do
        response=$(rootpxe_storage_call preflight --data-urlencode "actualVersion=$rootpxe_storage_actual_version" --data-urlencode "rootFileId=$rootpxe_storage_root_file_id" --data-urlencode "offset=$offset") || return 1
        jq -c '.files[]' <<<"$response" >>"$rootpxe_storage_workspace/manifest.ndjson" || return 1
        next=$(jq -r '.nextOffset' <<<"$response"); total=$(jq -r '.totalFiles' <<<"$response")
        [[ $next =~ ^[0-9]+$ && $total =~ ^[0-9]+$ && $total -le 10000 ]] || return 1
        (( next < total )) || break
        (( next > offset )) || return 1; offset=$next
    done
    while IFS= read -r node; do
        path=$(jq -r '.path' <<<"$node"); kind=$(jq -r '.kind' <<<"$node"); size=$(jq -r '.size' <<<"$node")
        [[ $path != . ]] || continue
        rootpxe_safe_relative_path "$path" >/dev/null || return 1
        destination="$rootpxe_storage_workspace/image/$path"
        [[ $kind != dir ]] || { mkdir -p -- "$destination" || return 1; continue; }
        [[ $kind == file && $size =~ ^[0-9]+$ ]] || return 1
        mkdir -p -- "${destination%/*}" || return 1
        if rootpxe_storage_is_payload "$path"; then truncate -s "$size" -- "$destination" || return 1
        else
            (( size <= 8388608 && count < 4096 && bytes + size <= 67108864 )) || return 1
            rootpxe_storage_exec read "$img/$path" "$destination" || return 1
            count=$((count+1)); bytes=$((bytes+size))
        fi
    done <"$rootpxe_storage_workspace/manifest.ndjson"
}

rootpxe_storage_read_files() {
    local file relative
    for file in "$@"; do
        [[ $file == "$rootpxe_storage_workspace/image/"* ]] || return 1
        relative=${file#"$rootpxe_storage_workspace/image/"}; rootpxe_safe_relative_path "$relative" >/dev/null || return 1
        rootpxe_storage_exec read "$img/$relative" - || return 1
    done
}

rootpxe_storage_write_payload() {
    local local_file=$1 split_bytes=$2 relative
    [[ $local_file == "$rootpxe_storage_workspace/image/"* ]] || return 1
    relative=${local_file#"$rootpxe_storage_workspace/image/"}; rootpxe_safe_relative_path "$relative" >/dev/null || return 1
    rootpxe_storage_ensure_parents "$rootpxe_storage_stage/payload/$relative" || return 1
    rootpxe_storage_exec write-split "$rootpxe_storage_stage/payload/$relative" - "$split_bytes"
}

rootpxe_storage_path() {
    [[ -n ${rootpxe_storage_workspace:-} && $1 == "${img:-}" ]] || return 1
    printf '%s\n' "$rootpxe_storage_workspace/image"
}
prepareUploadLocation() { [[ ${1:-} == "$rootpxe_storage_workspace/image" && -d $1 && ! -L $1 ]]; }
rootpxe_prepare_storage_layout() { [[ -n ${rootpxe_storage_workspace:-} && -d $rootpxe_storage_workspace/image ]]; }

rootpxe_storage_sync_payload_names() {
    local entry inode original current relative names
    : >"$rootpxe_storage_workspace/payloads.next"
    while IFS= read -r entry; do
        inode=$(jq -r '.inode' <<<"$entry"); original=$(jq -r '.path' <<<"$entry")
        [[ $inode =~ ^[0-9]+$ ]] || return 1
        names=$(find "$rootpxe_storage_workspace/image" -xdev -type f -inum "$inode" -print) || return 1
        [[ -n $names && $names != *$'\n'* && $names == "$rootpxe_storage_workspace/image/"* ]] || return 1
        current=$names; relative=${current#"$rootpxe_storage_workspace/image/"}
        rootpxe_safe_relative_path "$relative" >/dev/null || return 1
        if [[ $relative != "$original" ]]; then
            rootpxe_storage_ensure_parents "$rootpxe_storage_stage/payload/$relative" || return 1
            rootpxe_storage_exec rename-owned "$rootpxe_storage_stage/payload/$original" "$rootpxe_storage_stage/payload/$relative" || return 1
        fi
        jq -c --arg path "$relative" '.path=$path' <<<"$entry" >>"$rootpxe_storage_workspace/payloads.next" || return 1
    done <"$rootpxe_storage_workspace/payloads.ndjson"
    mv -- "$rootpxe_storage_workspace/payloads.next" "$rootpxe_storage_workspace/payloads.ndjson"
}

rootpxe_storage_owned() {
    rootpxe_storage_call preflight --data-urlencode "actualVersion=$rootpxe_storage_actual_version" \
      --data-urlencode "rootFileId=$rootpxe_storage_root_file_id" --data-urlencode includeOwned=true
}

rootpxe_storage_sync_metadata() {
    local file relative inode size total=0 response path kind listing="$rootpxe_storage_workspace/metadata-files"
    rootpxe_storage_sync_payload_names || return 1
    find "$rootpxe_storage_workspace/image" -xdev -type f -print0 >"$listing" || return 1
    while IFS= read -r -d '' file; do
        relative=${file#"$rootpxe_storage_workspace/image/"}
        [[ $relative != .rootpxe-capture-taskid ]] || continue
        inode=$(stat -c %i -- "$file") || return 1
        if jq -se --arg inode "$inode" 'any(.[]; .inode == $inode)' "$rootpxe_storage_workspace/payloads.ndjson" >/dev/null; then continue; fi
        size=$(stat -c %s -- "$file") || return 1
        [[ $size =~ ^[0-9]+$ ]] && (( size <= 8388608 && total + size <= 67108864 )) || return 1
        total=$((total+size)); rootpxe_safe_relative_path "$relative" >/dev/null || return 1
        rootpxe_storage_ensure_parents "$rootpxe_storage_stage/payload/$relative" || return 1
        rootpxe_storage_exec write "$rootpxe_storage_stage/payload/$relative" "$file" || return 1
    done <"$listing"
    # Local LVM staging can rename payloads out of temporary subdirectories.
    # Remove only our recorded, now-empty remote directories which are absent
    # from the final local metadata tree. Unknown NAS children make rmdir fail.
    response=$(rootpxe_storage_owned) || return 1
    while IFS= read -r path; do
        [[ $path == "$rootpxe_storage_stage/payload/"* ]] || continue
        relative=${path#"$rootpxe_storage_stage/payload/"}
        [[ ! -e $rootpxe_storage_workspace/image/$relative ]] || continue
        rootpxe_storage_exec remove-owned "$path" || return 1
    done < <(jq -r '.owned|sort_by(.path|split("/")|length)|reverse|.[]|select(.kind == "dir")|.path' <<<"$response")
}

rootpxe_finalize_capture() {
    [[ ${type:-} == up && -n ${rootpxe_storage_workspace:-} ]] || return 1
    rootpxe_wait_for_writers || return 1
    rootpxe_storage_sync_metadata || return 1
    rootpxe_storage_exec seal "$rootpxe_storage_stage/payload" || return 1
    capture_size_bytes=$(rootpxe_directory_size_bytes "$rootpxe_storage_workspace/image") || return 1
    [[ $capture_size_bytes =~ ^[1-9][0-9]*$ && -r ${rootpxe_partition_inventory_file:-} ]] || return 1
    local -a facts=(--data-urlencode producerSucceeded=true --data-urlencode "sizeBytes=$capture_size_bytes" --data-urlencode "partitionInventory@$rootpxe_partition_inventory_file")
    [[ -z ${rootpxe_original_schema_file:-} ]] || facts+=(--data-urlencode "originalSchema@$rootpxe_original_schema_file")
    rootpxe_storage_call publish-begin "${facts[@]}" >/dev/null || return 1
    if jq -e '.targetExists == true' "$rootpxe_storage_workspace/preflight.json" >/dev/null; then
        rootpxe_storage_exec rename-owned "$img" "$rootpxe_storage_stage/previous" || return 1
    fi
    rootpxe_storage_exec rename-owned "$rootpxe_storage_stage/payload" "$img" || return 1
    rootpxe_storage_call publish-complete >/dev/null || return 1
    rootpxe_final_capture_path="$rootpxe_storage_workspace/image"
    rootpxe_storage_published=yes
    export capture_size_bytes rootpxe_final_capture_path rootpxe_storage_published
}

rootpxe_storage_cleanup_owned() {
    local response path
    response=$(rootpxe_storage_owned) || return 1
    while IFS= read -r path; do
        [[ $path == "$rootpxe_storage_stage" || $path == "$rootpxe_storage_stage/"* ]] || continue
        rootpxe_storage_exec remove-owned "$path" || return 1
    done < <(jq -r '.owned|sort_by(.path|split("/")|length)|reverse|.[].path' <<<"$response")
    if jq -e --arg path "$rootpxe_storage_lock/owner" 'any(.owned[]; .path == $path)' <<<"$response" >/dev/null; then rootpxe_storage_exec remove-owned "$rootpxe_storage_lock/owner" || return 1; fi
    if jq -e --arg path "$rootpxe_storage_lock" 'any(.owned[]; .path == $path)' <<<"$response" >/dev/null; then rootpxe_storage_exec remove-owned "$rootpxe_storage_lock" || return 1; fi
}

rootpxe_clear_capture_marker() {
    if [[ ${type:-} == up ]]; then rootpxe_storage_cleanup_owned || return 1; fi
    rootpxe_storage_stop || return 1
    rootpxe_storage_call release --data-urlencode workerStopped=true >/dev/null || return 1
    rootpxe_storage_released=yes
    rm -f -- "$rootpxe_storage_workspace/image/.rootpxe-capture-taskid"
}

rootpxe_storage_update_context() {
    local direction=$1 sequence=$2
    [[ $direction == read || $direction == write ]] || return 1
    [[ $sequence =~ ^(0|[1-9][0-9]*)$ && ${#sequence} -le 20 ]] || return 1
    jq -c --arg direction "$direction" --arg sequence "$sequence" '.direction=$direction | .sequence=$sequence' \
      "$rootpxe_storage_workspace/context.json" >"$rootpxe_storage_workspace/context.next" || return 1
    mv -- "$rootpxe_storage_workspace/context.next" "$rootpxe_storage_workspace/context.json"
}

rootpxe_storage_change_direction() {
    local direction=$1 response sequence
    response=$(rootpxe_storage_owned) || return 1
    sequence=$(jq -er '.sequence | strings' <<<"$response") || return 1
    rootpxe_storage_stop || return 1
    rootpxe_storage_update_context "$direction" "$sequence" || return 1
    rootpxe_storage_start
}

rootpxe_storage_finish_original() {
    local response size
    jq -e '.finish.digest|test("^[a-f0-9]{64}$")' "$rootpxe_storage_workspace/preflight.json" >/dev/null || return 1
    size=$(jq -er '.finish.sizeBytes | strings' "$rootpxe_storage_workspace/preflight.json") || return 1
    jq -c '.finish.partitionInventory' "$rootpxe_storage_workspace/preflight.json" >"$rootpxe_storage_workspace/frozen-inventory.json" || return 1
    local -a facts=(--data-urlencode "sizeBytes=$size" --data-urlencode "partitionInventory@$rootpxe_storage_workspace/frozen-inventory.json")
    if jq -e '.finish.originalSchema != null' "$rootpxe_storage_workspace/preflight.json" >/dev/null; then
        jq -c '.finish.originalSchema' "$rootpxe_storage_workspace/preflight.json" >"$rootpxe_storage_workspace/frozen-schema.json" || return 1
        facts+=(--data-urlencode "originalSchema@$rootpxe_storage_workspace/frozen-schema.json")
    fi
    response=$(rootpxe_task_curl -ks --connect-timeout 10 --max-time 30 \
      --data-urlencode "taskid=$taskid" --data-urlencode "token=$task_token" --data-urlencode "mac=$mac" \
      --data-urlencode result=success "${facts[@]}" "${pxeapi:-$web}finish") || return 1
    jq -e '.success == true' >/dev/null <<<"$response"
}

rootpxe_storage_recover_once() {
    local response disposition path stage_owned target_owned previous_owned published
    response=$(rootpxe_storage_owned) || return 1
    printf '%s\n' "$response" >"$rootpxe_storage_workspace/preflight.json" || return 1
    disposition=$(jq -er '.recoveryDisposition | strings' <<<"$response") || return 1
    if [[ $disposition == publish ]]; then
        # A new kernel must re-read every original sealed file through the
        # numeric-identity helper. Go re-observes the original protocol IDs;
        # each full-read digest must equal the original write/readback receipt.
        rootpxe_storage_change_direction read || return 1
        response=$(rootpxe_storage_owned) || return 1
        while IFS= read -r path; do
            [[ $path == "$rootpxe_storage_stage/payload/"* || $path == "$img/"* ]] || return 1
            rootpxe_storage_exec read "$path" - >/dev/null || return 1
        done < <(jq -r --arg stage "$rootpxe_storage_stage/payload/" --arg image "$img/" \
          '.owned[] | select(.kind == "file" and (.path|startswith($stage) or startswith($image))) | .path' <<<"$response")
        rootpxe_storage_change_direction write || return 1
        response=$(rootpxe_storage_owned) || return 1
        stage_owned=$(jq -r --arg path "$rootpxe_storage_stage/payload" 'any(.owned[];.path==$path)' <<<"$response")
        target_owned=$(jq -r --arg path "$img" 'any(.owned[];.path==$path)' <<<"$response")
        previous_owned=$(jq -r --arg path "$rootpxe_storage_stage/previous" 'any(.owned[];.path==$path)' <<<"$response")
        if [[ $stage_owned == true ]]; then
            if [[ $(jq -r '.targetExists' <<<"$response") == true && $previous_owned != true ]]; then
                rootpxe_storage_exec rename-owned "$img" "$rootpxe_storage_stage/previous" || return 1
            fi
            rootpxe_storage_exec rename-owned "$rootpxe_storage_stage/payload" "$img" || return 1
        elif [[ $target_owned != true ]]; then return 1; fi
        rootpxe_storage_call publish-complete >/dev/null || return 1
        # The frozen finish payload is the only source of capture facts/time.
        # Never invoke inventory, shrink, partclone or a disk permit here.
        rootpxe_storage_finish_original || return 1
        rootpxe_storage_recovery_completed=yes
        (umask 077; : >/tmp/pxeos.storage-recovery-only) || return 1
    elif [[ $disposition == rollback ]]; then
        if [[ $(jq -r '.direction' "$rootpxe_storage_workspace/context.json") != write ]]; then rootpxe_storage_change_direction write || return 1; fi
        response=$(rootpxe_storage_owned) || return 1
        target_owned=$(jq -r --arg path "$img" 'any(.owned[];.path==$path)' <<<"$response")
        previous_owned=$(jq -r --arg path "$rootpxe_storage_stage/previous" 'any(.owned[];.path==$path)' <<<"$response")
        if [[ $target_owned == true ]]; then rootpxe_storage_exec rename-owned "$img" "$rootpxe_storage_stage/payload" || return 1; fi
        if [[ $previous_owned == true ]]; then rootpxe_storage_exec rename-owned "$rootpxe_storage_stage/previous" "$img" || return 1; fi
    elif [[ $disposition != completed && $disposition != read ]]; then return 1; fi
    [[ ${taskType:-} != capture ]] || rootpxe_storage_cleanup_owned || return 1
    rootpxe_storage_stop || return 1
    rootpxe_storage_call release --data-urlencode workerStopped=true >/dev/null || return 1
    rootpxe_storage_released=yes
}

rootpxe_storage_recover_until_clean() {
    local worker
    [[ ${rootpxe_storage_released:-no} != yes ]] || return 0
    # Do not signal only the last pipeline command and call it stopped. Closing
    # the helper causes FIFO errors to reach every bounded writer pipeline;
    # wait for each parent pipeline, which waits for its own producer/compressor.
    [[ -z ${rootpxe_storage_pid:-} ]] || kill -TERM "$rootpxe_storage_pid" 2>/dev/null || true
    rootpxe_storage_stop || true
    for worker in "${writer_pids[@]:-}"; do
        [[ $worker =~ ^[0-9]+$ ]] || continue
        while :; do wait "$worker" 2>/dev/null || true; kill -0 "$worker" 2>/dev/null || break; done
    done
    writer_pids=()
    rootpxe_storage_reconcile=yes
    while :; do
        # A prior release may already have committed while its reply was
        # lost. Ask for its strictly authenticated acknowledgement before
        # reopening a helper against an operation that no longer exists.
        if rootpxe_storage_call release --data-urlencode workerStopped=true >/dev/null; then
            rootpxe_storage_released=yes
            return 0
        fi
        if rootpxe_storage_start && rootpxe_storage_recover_once; then return 0; fi
        [[ -z ${rootpxe_storage_pid:-} ]] || kill -TERM "$rootpxe_storage_pid" 2>/dev/null || true
        rootpxe_storage_stop || true
        rootpxe_storage_reconcile=yes
        rootpxe_console_message WARN 'Storage recovery is not confirmed. Retrying in 5s.'
        sleep 5
    done
}

# Only an administrator-requested new attempt crosses this boundary. Same
# attempt storage recovery must retain its exact execution identity.
rootpxe_storage_reset_retry_state() {
    if [[ -n ${rootpxe_storage_workspace:-} ]]; then
        [[ ${rootpxe_storage_released:-no} == yes && ${rootpxe_storage_stopped:-no} == yes && -z ${rootpxe_storage_pid:-} ]] || return 1
    fi
    rootpxe_cleanup_task_json || return 1
    rootpxe_deployment_identity_cleanup_private || return 1
    unset rootpxe_storage_workspace rootpxe_storage_nonce rootpxe_storage_worker_nonce rootpxe_storage_stage rootpxe_storage_lock
    unset rootpxe_storage_published capture_size_bytes rootpxe_final_capture_path
}

rootpxe_capture_resume_published() {
    # Existing executions enter the explicit storage-only branch before this
    # function. A fresh capture never discovers/adopts a generation by name.
    [[ ${rootpxe_storage_published:-no} == yes ]]
}

rootpxe_storage_quiesce() {
    local worker
    [[ -z ${rootpxe_storage_pid:-} ]] || kill -TERM "$rootpxe_storage_pid" 2>/dev/null || true
    rootpxe_storage_stop || true
    for worker in "${writer_pids[@]:-}"; do
        [[ $worker =~ ^[0-9]+$ ]] || continue
        while :; do wait "$worker" 2>/dev/null || true; kill -0 "$worker" 2>/dev/null || break; done
    done
    writer_pids=()
}

rootpxe_storage_failure_cleanup() {
    rootpxe_storage_failure_response=''
    [[ -n ${rootpxe_storage_workspace:-} && ${rootpxe_storage_released:-no} != yes ]] || return 0
    local response='' report_status=0
    # Join the old worker before waiting for the service to acknowledge this
    # exact failure. Network/5xx uncertainty must not release its owner first.
    rootpxe_storage_quiesce
    if rootpxe_error_report "${1:-存储执行已停止，正在安全收尾}" PXEOS_STORAGE_INTERRUPTED; then
        response=$rootpxe_error_report_response
    else
        report_status=$?
    fi
    # Rejection is not acknowledgement. Still perform the original verified
    # cleanup so a failed member never retains a live local writer.
    if rootpxe_storage_call release --data-urlencode workerStopped=true >/dev/null; then
        rootpxe_storage_released=yes
    else
        [[ -f $rootpxe_storage_workspace/ready.json ]] || return 1
        rootpxe_storage_recover_until_clean || return 1
    fi
    [[ ${rootpxe_storage_recovery_completed:-no} != yes ]] || return 0
    (( report_status == 0 )) || return "$report_status"
    rootpxe_storage_failure_response=$response
}
