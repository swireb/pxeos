#!/bin/bash
# Server-owned manual multicast sessions. PXEOS never creates a replacement
# session and never falls back to unicast after accepting multicast mode.

rootpxe_multicast_receiver_capable() {
    local help_output rc
    command -v udp-receiver >/dev/null 2>&1 || return 1
    if help_output=$(udp-receiver --help 2>&1); then rc=0; else rc=$?; fi
    [[ $rc == 0 || $rc == 1 ]] || return 1
    [[ $help_output == *--nokbd* && $help_output == *--portbase* && $help_output == *--ttl* && $help_output == *--mcast-rdv-address* && $help_output == *--start-timeout* && $help_output == *--receive-timeout* ]]
}

rootpxe_multicast_runtime_ready() {
    command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && rootpxe_multicast_receiver_capable
}

rootpxe_multicast_reset() {
    unset multicastTransportMode multicastSessionId multicastWaitTimeoutSec
    mc=no
}

rootpxe_multicast_valid_session_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; }

rootpxe_multicast_apply_transport_mode() {
    local document=$1 mode session timeout
    rootpxe_multicast_reset
    mode=$(jq -r 'if has("transportMode") then .transportMode else "unicast" end' <<<"$document") || return 1
    [[ $mode == unicast || $mode == multicast ]] || return 1
    if [[ $mode == unicast ]]; then
        multicastTransportMode=unicast
        export multicastTransportMode mc
        return 0
    fi
    [[ ${taskType:-} == deploy ]] && rootpxe_multicast_runtime_ready || return 1
    session=$(jq -r 'if (.multicastSessionId|type)=="string" then .multicastSessionId else "" end' <<<"$document") || return 1
    timeout=$(jq -r 'if (.waitTimeoutSec|type)=="number" then .waitTimeoutSec else empty end' <<<"$document") || return 1
    rootpxe_multicast_valid_session_id "$session" && [[ $timeout =~ ^[1-9][0-9]*$ ]] && (( timeout <= 86400 )) || return 1
    multicastTransportMode=multicast
    multicastSessionId=$session
    multicastWaitTimeoutSec=$timeout
    mc=yes
    export multicastTransportMode multicastSessionId multicastWaitTimeoutSec mc
}

rootpxe_multicast_safe_relative_path() {
    local path=$1 segment
    [[ -n $path && ${#path} -le 1024 && $path != /* && $path != */ && $path != *\\* && $path != *$'\n'* && $path != *$'\r'* && $path != *[[:cntrl:]]* && $path != *//* ]] || return 1
    IFS=/ read -r -a _mc_segments <<<"$path"
    for segment in "${_mc_segments[@]}"; do [[ -n $segment && $segment != . && $segment != .. ]] || return 1; done
    printf '%s\n' "$path"
}

rootpxe_multicast_artifact_key() {
    local path
    path=$(rootpxe_multicast_safe_relative_path "$1") || return 1
    printf '%s\n' "${path%.000}"
}

rootpxe_multicast_key_from_restore_source() {
    local source=${1%\*} root=$2
    [[ $source == "$root/"* ]] || return 1
    rootpxe_multicast_artifact_key "${source#"$root/"}"
}

rootpxe_multicast_artifact_paths() {
    local root=$1 relative full parent segment item suffix expected=0 found=no
    relative=$(rootpxe_multicast_artifact_key "$2") || return 1
    [[ -d $root && ! -L $root ]] || return 1
    parent=$root
    IFS=/ read -r -a _mc_segments <<<"$relative"
    for segment in "${_mc_segments[@]:0:${#_mc_segments[@]}-1}"; do
        parent=$parent/$segment
        [[ -d $parent && ! -L $parent ]] || return 1
    done
    full=$root/$relative
    if [[ -e $full || -L $full ]]; then
        [[ -f $full && ! -L $full && -r $full ]] || return 1
        compgen -G "$full.*" >/dev/null && return 1
        printf '%s\n' "$relative"
        return 0
    fi
    for item in "$full".*; do
        [[ -e $item || -L $item ]] || continue
        suffix=${item##*.}
        [[ $suffix =~ ^[0-9]{3}$ && -f $item && ! -L $item && -r $item && $suffix == $(printf '%03d' "$expected") ]] || return 1
        printf '%s\n' "${item#"$root/"}"
        expected=$((expected + 1)); found=yes
    done
    [[ $found == yes ]]
}

rootpxe_multicast_manifest_begin() {
    umask 077
    rootpxe_multicast_manifest_file=$(mktemp /tmp/rootpxe-multicast-manifest.XXXXXX) || return 1
    printf '[]\n' >"$rootpxe_multicast_manifest_file" && chmod 600 "$rootpxe_multicast_manifest_file"
}

rootpxe_multicast_manifest_add() {
    local manifest=$1 key=$2 root=$3 relative=$4 paths temp
    key=$(rootpxe_multicast_artifact_key "$key") || return 1
    paths=$(rootpxe_multicast_artifact_paths "$root" "$relative") || return 1
    temp=$manifest.tmp
    jq -c --arg key "$key" --argjson paths "$(printf '%s\n' "$paths" | jq -R . | jq -s .)" '. + [{artifactKey:$key,paths:$paths}]' "$manifest" >"$temp" || return 1
    chmod 600 "$temp" && mv "$temp" "$manifest"
}

rootpxe_multicast_non_data_partition() {
    local type=${1,,} filesystem=${2,,}
    type=${type#0x}; type=${type#0}
    [[ $filesystem == swap || $type == 5 || $type == f || $type == 85 || $type == 82 || $type == 8200 || $type == 657fd6d-a4ab-43c4-84e5-0933c84b4f4f ]]
}

rootpxe_multicast_build_manifest() {
    local root=$1 artifact relative disk partition type filesystem
    rootpxe_multicast_manifest_begin || return 1
    case ${imgType:-} in
        n|N)
            [[ -r ${originalSchemaFile:-} && ! -L ${originalSchemaFile:-} ]] || return 1
            while IFS= read -r artifact; do
                artifact=${artifact//$'\r'/}
                [[ -n $artifact ]] || continue
                relative=$(rootpxe_multicast_artifact_key "$artifact") || return 1
                rootpxe_multicast_manifest_add "$rootpxe_multicast_manifest_file" "$relative" "$root" "$relative" || return 1
            done < <(jq -er '(.partitions[]? | select((.fs? // "") != "swap" and (.role? // "") != "swap" and (.role? // "") != "lvm_pv") | .artifact // empty),(.lvm.vgs[]?.lvs[]? | select((.fs? // "") != "swap" and (.role? // "") != "swap") | .artifact // empty)' "$originalSchemaFile")
            ;;
        dd)
            relative=$(rootpxe_multicast_artifact_key "${img:-}") || return 1
            rootpxe_multicast_manifest_add "$rootpxe_multicast_manifest_file" "$relative" "$root" "$relative" || return 1
            ;;
        mps|mpa)
            [[ -r ${partitionInventoryFile:-} && ! -L ${partitionInventoryFile:-} ]] || return 1
            while IFS=$'\t' read -r disk partition type filesystem; do
                filesystem=${filesystem//$'\r'/}
                [[ $disk =~ ^[1-9][0-9]*$ && $partition =~ ^[1-9][0-9]*$ ]] || return 1
                [[ ${imgPartitionType:-all} == all || ${imgPartitionType:-all} == "$partition" ]] || continue
                rootpxe_multicast_non_data_partition "$type" "$filesystem" && continue
                relative=d${disk}p${partition}.img
                rootpxe_multicast_manifest_add "$rootpxe_multicast_manifest_file" "$relative" "$root" "$relative" || return 1
            done < <(jq -er '.disks[] | .number as $disk | .partitions[] | [$disk,.number,.typeGuid,.fs] | @tsv' "$partitionInventoryFile")
            ;;
        *) return 1 ;;
    esac
    jq -e 'length > 0 and ([.[].artifactKey] | unique | length) == length and ([.[].paths[]] | unique | length) == ([.[].paths[]] | length)' "$rootpxe_multicast_manifest_file" >/dev/null && (( $(wc -c <"$rootpxe_multicast_manifest_file") <= 65536 ))
}

rootpxe_multicast_context_begin() {
    local token=${task_token:-${execution_token:-}}
    [[ ${taskid:-} =~ ^[1-9][0-9]*$ && -n $token && -n ${mac:-} && ${progress_attempt:-1} =~ ^[0-9]+$ ]] || return 1
    rm -f -- "${rootpxe_multicast_context_file:-}" "${rootpxe_multicast_secret_file:-}"
    umask 077
    rootpxe_multicast_secret_file=$(mktemp /tmp/rootpxe-multicast-token.XXXXXX) || return 1
    printf %s "$token" >"$rootpxe_multicast_secret_file" && chmod 600 "$rootpxe_multicast_secret_file" || return 1
    rootpxe_multicast_context_file=$(mktemp /tmp/rootpxe-multicast-context.XXXXXX) || return 1
    jq -cn --argjson taskId "$taskid" --rawfile token "$rootpxe_multicast_secret_file" --arg mac "$mac" --argjson progressAttempt "${progress_attempt:-1}" '{taskId:$taskId,executionToken:$token,mac:$mac,progressAttempt:$progressAttempt}' >"$rootpxe_multicast_context_file" && chmod 600 "$rootpxe_multicast_context_file"
}

rootpxe_multicast_error_summary() {
    local response=$1 code error
    [[ -r $response && ! -L $response ]] || { printf 'redacted\tredacted\n'; return; }
    code=$(jq -r 'if type == "object" and (.code|type) == "string" then .code else "" end' "$response" 2>/dev/null) || code=""
    error=$(jq -r 'if type == "object" and (.error|type) == "string" then .error else "" end' "$response" 2>/dev/null) || error=""
    case "$code" in
        multicast_unavailable) printf '%s\t%s\n' "$code" 'multicast sender unavailable' ;;
        multicast_session_lost) printf '%s\t%s\n' "$code" 'manual multicast session lost; create a new manual multicast deployment session' ;;
        multicast_failed) printf '%s\t%s\n' "$code" 'multicast operation failed' ;;
        invalid_request) printf '%s\t%s\n' "$code" 'multicast request rejected' ;;
        *) printf 'redacted\tredacted\n' ;;
    esac
}

rootpxe_multicast_http_failure() {
    local op=$1 status=$2 curl_rc=$3 response=$4 kind=${5:-http} code error
    [[ $op =~ ^(join|prepare|ready|report|status|end|cancel)$ ]] || op=unknown
    [[ $status =~ ^[0-9]{3}$ ]] || status=none
    [[ $curl_rc =~ ^[0-9]+$ ]] || curl_rc=none
    IFS=$'\t' read -r code error < <(rootpxe_multicast_error_summary "$response")
    rootpxe_multicast_last_failure=$kind; rootpxe_multicast_last_http_op=$op; rootpxe_multicast_last_http_status=$status; rootpxe_multicast_last_curl_exit=$curl_rc; rootpxe_multicast_last_error_code=$code; rootpxe_multicast_last_error_summary=$error
    declare -F rootpxe_console_message >/dev/null 2>&1 && rootpxe_console_message WARN "Multicast request failed: op=$op http=$status curl=$curl_rc code=$code error=$error"
}

rootpxe_multicast_join_local_failure() {
    rootpxe_multicast_last_failure=join_local; rootpxe_multicast_last_join_stage=$1
    declare -F rootpxe_console_message >/dev/null 2>&1 && rootpxe_console_message WARN "Multicast join failed locally: stage=$1"
}

rootpxe_multicast_request_timeout() {
    local limit=${rootpxe_multicast_request_deadline:-30} remaining
    [[ $limit =~ ^[1-9][0-9]*$ ]] || limit=30
    if [[ ${rootpxe_multicast_operation_deadline:-} =~ ^[0-9]+$ ]]; then
        remaining=$((rootpxe_multicast_operation_deadline - SECONDS))
        (( remaining > 0 )) || return 1
        (( remaining < limit )) && limit=$remaining
    fi
    printf '%s\n' "$limit"
}

rootpxe_multicast_http_post() {
    local op=$1 request=$2 status curl_rc=0 limit connect_timeout response pid_file
    limit=$(rootpxe_multicast_request_timeout) || { rootpxe_multicast_last_failure=http_timeout; return 1; }
    [[ $op == cancel ]] && limit=5
    [[ $op == status && $limit -gt 10 ]] && limit=10
    connect_timeout=$limit; (( connect_timeout > 10 )) && connect_timeout=10
    [[ $op =~ ^(join|prepare|ready|report|status|end|cancel)$ && -r $request && ! -L $request && $limit =~ ^[1-9][0-9]*$ && $(wc -c <"$request") -le 65536 ]] || { rootpxe_multicast_last_failure=http_precondition; return 1; }
    umask 077
    if [[ ${rootpxe_multicast_http_dir:-} == /tmp/rootpxe-multicast-monitor.* ]]; then
        response=$(mktemp "$rootpxe_multicast_http_dir/response.XXXXXX") || return 1
        pid_file=$rootpxe_multicast_http_dir/curl.pid
    else
        response=$(mktemp /tmp/rootpxe-multicast-response.XXXXXX) || return 1
    fi
    chmod 600 "$response" || { rm -f -- "$response"; return 1; }
    if [[ -n ${pid_file:-} ]]; then
        curl -sS --connect-timeout "$connect_timeout" --max-time "$limit" -H 'Content-Type: application/json' --data-binary @"$request" -o "$response" -w '%{http_code}' "${rootpxe_api}multicast/$op" >"$response.status" 2>/dev/null &
        rootpxe_multicast_http_pid=$!; printf '%s\n' "$rootpxe_multicast_http_pid" >"$pid_file"
        wait "$rootpxe_multicast_http_pid" || curl_rc=$?
        status=$(cat "$response.status" 2>/dev/null); rm -f -- "$pid_file" "$response.status"
    else
        status=$(curl -sS --connect-timeout "$connect_timeout" --max-time "$limit" -H 'Content-Type: application/json' --data-binary @"$request" -o "$response" -w '%{http_code}' "${rootpxe_api}multicast/$op" 2>/dev/null) || curl_rc=$?
    fi
    if [[ $curl_rc != 0 || ! $status =~ ^2[0-9][0-9]$ ]] || ! jq -e 'type == "object"' "$response" >/dev/null 2>&1; then
        local kind=rejected
        [[ $curl_rc != 0 ]] && kind=network
        [[ $curl_rc == 0 && $status =~ ^2[0-9][0-9]$ ]] && kind=response_invalid
        rootpxe_multicast_http_failure "$op" "$status" "$curl_rc" "$response" "$kind"; rm -f -- "$response"; return 1
    fi
    rm -f -- "${rootpxe_multicast_response_file:-}"
    rootpxe_multicast_response_file=$response
}

rootpxe_multicast_request() {
    local op=$1 filter=$2 body rc
    shift 2
    [[ -r ${rootpxe_multicast_context_file:-} && ! -L ${rootpxe_multicast_context_file:-} ]] || return 1
    umask 077
    body=$(mktemp /tmp/rootpxe-multicast-body.XXXXXX) || return 1
    rootpxe_multicast_request_body_file=$body
    if ! jq -cn --slurpfile common "$rootpxe_multicast_context_file" "$@" "$filter" >"$body" || ! chmod 600 "$body"; then
        rm -f -- "$body"; unset rootpxe_multicast_request_body_file; return 1
    fi
    rootpxe_multicast_http_post "$op" "$body"; rc=$?
    rm -f -- "$body"; unset rootpxe_multicast_request_body_file
    return "$rc"
}

rootpxe_multicast_member_terminal() { [[ $1 == COMPLETED || $1 == FAILED || $1 == CANCELLED || $1 == MISSED ]]; }
rootpxe_multicast_session_terminal() { [[ $1 == COMPLETED || $1 == PARTIAL || $1 == FAILED || $1 == CANCELLED ]]; }

rootpxe_multicast_read_session_response() {
    local data
    data=$(jq -r '[.sessionId,.state,.member.state,(.member.selected|tostring),(.deadlineAt//""),(.remainingWaitSec//""),(.heartbeatLeaseSec//"")]|@tsv' "$rootpxe_multicast_response_file") || return 1
    IFS=$'\t' read -r rootpxe_multicast_response_session_id rootpxe_multicast_state rootpxe_multicast_member_state rootpxe_multicast_member_selected rootpxe_multicast_deadline_at rootpxe_multicast_remaining_wait_sec rootpxe_multicast_heartbeat_lease_sec <<<"$data"
    [[ $rootpxe_multicast_response_session_id == "$multicastSessionId" && $rootpxe_multicast_state =~ ^(WAITING|RUNNING|COMPLETED|PARTIAL|FAILED|CANCELLED)$ && $rootpxe_multicast_member_state =~ ^(PENDING|READY|RUNNING|COMPLETED|FAILED|CANCELLED|MISSED)$ && $rootpxe_multicast_member_selected =~ ^(true|false)$ && ( -z $rootpxe_multicast_remaining_wait_sec || $rootpxe_multicast_remaining_wait_sec =~ ^[0-9]+$ ) && ( -z $rootpxe_multicast_heartbeat_lease_sec || $rootpxe_multicast_heartbeat_lease_sec =~ ^[1-9][0-9]*$ ) ]]
}

rootpxe_multicast_join() {
    [[ ${multicastTransportMode:-} == multicast && ${taskType:-} == deploy && -r ${rootpxe_multicast_manifest_file:-} ]] || { rootpxe_multicast_join_local_failure precondition; return 1; }
    rootpxe_multicast_context_begin || { rootpxe_multicast_join_local_failure context; return 1; }
    rootpxe_multicast_request join '($common[0] + {sessionId:$sessionId,manifest:$manifest[0]})' --arg sessionId "$multicastSessionId" --slurpfile manifest "$rootpxe_multicast_manifest_file" || return 1
    rootpxe_multicast_read_session_response || { rootpxe_multicast_join_local_failure response_validation; return 1; }
    rootpxe_multicast_sequence=0
}

rootpxe_multicast_status() {
    rootpxe_multicast_request status '($common[0] + {sessionId:$sessionId})' --arg sessionId "$multicastSessionId" || return 1
    rootpxe_multicast_read_session_response || { rootpxe_multicast_last_failure=response_invalid; return 1; }
}

rootpxe_multicast_update_wait_deadline() {
    local deadline=$1 remaining=${rootpxe_multicast_remaining_wait_sec:-}
    [[ $remaining =~ ^[0-9]+$ ]] || { printf '%s\n' "$deadline"; return; }
    (( remaining < deadline - SECONDS )) && deadline=$((SECONDS + remaining))
    printf '%s\n' "$deadline"
}

rootpxe_multicast_wait_for_selection() {
    local deadline=$((SECONDS + ${multicastWaitTimeoutSec:-300})) grace_deadline
    while (( SECONDS < deadline )); do
        if ! rootpxe_multicast_status; then
            # Only a transport failure is retryable. HTTP/authentication
            # rejection and malformed server data are terminal for this
            # client attempt.
            [[ ${rootpxe_multicast_last_failure:-} == network ]] || return 1
            sleep 1
            continue
        fi
        deadline=$(rootpxe_multicast_update_wait_deadline "$deadline")
        [[ $rootpxe_multicast_state == RUNNING && $rootpxe_multicast_member_selected == true && $rootpxe_multicast_member_state == RUNNING ]] && return 0
        rootpxe_multicast_member_terminal "$rootpxe_multicast_member_state" && return 1
        rootpxe_multicast_session_terminal "$rootpxe_multicast_state" && return 1
        if [[ $rootpxe_multicast_state == WAITING && $rootpxe_multicast_member_state == PENDING ]]; then
            if ! rootpxe_multicast_join; then
                [[ ${rootpxe_multicast_last_failure:-} == network ]] || return 1
                sleep 1
                continue
            fi
            [[ $rootpxe_multicast_state == RUNNING && $rootpxe_multicast_member_selected == true && $rootpxe_multicast_member_state == RUNNING ]] && return 0
            [[ $rootpxe_multicast_state == WAITING && ( $rootpxe_multicast_member_state == READY || $rootpxe_multicast_member_state == PENDING ) ]] || return 1
        fi
        sleep 1
    done

    # The controller sweeps at one-second granularity.  Observe for at most
    # three seconds after the local budget reaches zero, without join, disk
    # receiving, or any action that could extend candidate selection.
    grace_deadline=$((SECONDS + 3))
    while (( SECONDS <= grace_deadline )); do
        if rootpxe_multicast_status; then
            [[ $rootpxe_multicast_state == RUNNING && $rootpxe_multicast_member_selected == true && $rootpxe_multicast_member_state == RUNNING ]] && return 0
            rootpxe_multicast_member_terminal "$rootpxe_multicast_member_state" && return 1
            rootpxe_multicast_session_terminal "$rootpxe_multicast_state" && return 1
        elif [[ ${rootpxe_multicast_last_failure:-} != network ]]; then
            return 1
        fi
        sleep 1
    done
    return 1
}

rootpxe_multicast_stream_wait_timeout() {
    local timeout=${rootpxe_multicast_receiver_timeout_sec:-}
    [[ $timeout =~ ^[0-9]+$ ]] && (( timeout >= 2 )) || return 1
    printf '%s\n' "$timeout"
}

rootpxe_multicast_ipv4() {
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    [[ $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] && (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

rootpxe_multicast_prepare_stream() {
    local key=$1 next=$((rootpxe_multicast_sequence + 1)) data session_id sequence
    key=$(rootpxe_multicast_artifact_key "$key") || return 1
    jq -e --arg key "$key" 'any(.[]; .artifactKey == $key)' "$rootpxe_multicast_manifest_file" >/dev/null || return 1
    rootpxe_multicast_request prepare '($common[0] + {sessionId:$sessionId,sequence:$sequence,artifactKey:$artifactKey})' --arg sessionId "$multicastSessionId" --argjson sequence "$next" --arg artifactKey "$key" || return 1
    data=$(jq -r '[.sessionId,.streamId,.sequence,.portBase,.multicastAddress,.ttl,.senderAddress,.receiverTimeoutSec]|@tsv' "$rootpxe_multicast_response_file") || return 1
    IFS=$'\t' read -r session_id rootpxe_multicast_stream_id sequence rootpxe_multicast_port_base rootpxe_multicast_address rootpxe_multicast_ttl rootpxe_multicast_sender_address rootpxe_multicast_receiver_timeout_sec <<<"$data"
    [[ $session_id == "$multicastSessionId" && $sequence == "$next" && $rootpxe_multicast_stream_id =~ ^[A-Za-z0-9._:-]{1,128}$ && $rootpxe_multicast_port_base =~ ^[0-9]+$ && $rootpxe_multicast_ttl =~ ^[0-9]+$ && $rootpxe_multicast_receiver_timeout_sec =~ ^[0-9]+$ ]] || return 1
    (( rootpxe_multicast_port_base >= 1 && rootpxe_multicast_port_base <= 65534 && rootpxe_multicast_port_base % 2 == 0 && rootpxe_multicast_ttl >= 1 && rootpxe_multicast_ttl <= 255 && rootpxe_multicast_receiver_timeout_sec >= 2 )) || return 1
    rootpxe_multicast_ipv4 "$rootpxe_multicast_address" && rootpxe_multicast_ipv4 "$rootpxe_multicast_sender_address" || return 1
    local first_octet=${rootpxe_multicast_address%%.*}
    (( first_octet >= 224 && first_octet <= 239 )) || return 1
    rootpxe_multicast_sequence=$next
}

rootpxe_multicast_ready() {
    rootpxe_multicast_request ready '($common[0] + {sessionId:$sessionId,streamId:$streamId,sequence:$sequence})' --arg sessionId "$multicastSessionId" --arg streamId "$rootpxe_multicast_stream_id" --argjson sequence "$rootpxe_multicast_sequence" || return 1
    jq -e --arg session_id "$multicastSessionId" '.sessionId == $session_id' "$rootpxe_multicast_response_file" >/dev/null
}

rootpxe_multicast_report() {
    [[ $1 == true || $1 == false ]] || return 1
    rootpxe_multicast_request report '($common[0] + {sessionId:$sessionId,streamId:$streamId,sequence:$sequence,success:$success})' --arg sessionId "$multicastSessionId" --arg streamId "$rootpxe_multicast_stream_id" --argjson sequence "$rootpxe_multicast_sequence" --argjson success "$1" || return 1
    jq -e --arg session_id "$multicastSessionId" '.sessionId == $session_id' "$rootpxe_multicast_response_file" >/dev/null
}

rootpxe_multicast_wait_sequence() {
    local timeout current
    timeout=$(rootpxe_multicast_stream_wait_timeout) || return 1
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        rootpxe_multicast_status || return 1
        [[ $rootpxe_multicast_state == RUNNING && $rootpxe_multicast_member_selected == true && $rootpxe_multicast_member_state == RUNNING ]] || return 1
        current=$(jq -r '.currentSequence // 0' "$rootpxe_multicast_response_file") || return 1
        [[ $current =~ ^[0-9]+$ ]] && (( current > rootpxe_multicast_sequence )) && return 0
        sleep 1
    done
    return 1
}

rootpxe_multicast_pid_alive() { [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }

rootpxe_multicast_stop_receiver_pid() {
    local pid=$1 grace=${rootpxe_multicast_shutdown_grace_sec:-5} attempt
    [[ $grace =~ ^[0-9]+$ && $grace -le 30 ]] || grace=5
    rootpxe_multicast_pid_alive "$pid" || return 0
    kill -INT "$pid" 2>/dev/null || true
    for ((attempt=0; attempt<grace; attempt++)); do rootpxe_multicast_pid_alive "$pid" || return 0; sleep 1; done
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt=0; attempt<grace; attempt++)); do rootpxe_multicast_pid_alive "$pid" || return 0; sleep 1; done
    rootpxe_multicast_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
}

rootpxe_multicast_watchdog_stop_children() {
    local pid
    [[ -r ${rootpxe_multicast_receiver_pid_file:-} ]] || return 0
    read -r pid <"$rootpxe_multicast_receiver_pid_file"
    rootpxe_multicast_stop_receiver_pid "$pid"
}

rootpxe_multicast_watchdog_cleanup() {
    rootpxe_multicast_pid_alive "${rootpxe_multicast_http_pid:-}" && kill -TERM "$rootpxe_multicast_http_pid" 2>/dev/null || true
    rm -f -- "${rootpxe_multicast_response_file:-}"
}

rootpxe_multicast_watchdog() {
    # Locals shadow parent state: watchdog status must not delete foreground responses.
    local rootpxe_multicast_response_file="" rootpxe_multicast_http_pid=""
    rootpxe_multicast_http_dir=$rootpxe_multicast_monitor_dir
    trap 'rootpxe_multicast_watchdog_cleanup' EXIT
    trap 'rootpxe_multicast_watchdog_cleanup; exit 143' INT TERM
    while :; do
        if ! rootpxe_multicast_status; then
            printf '%s\n' status_failed >"$rootpxe_multicast_monitor_failure_file"
            rootpxe_multicast_watchdog_stop_children
            return 1
        fi
        if [[ $rootpxe_multicast_state != RUNNING || $rootpxe_multicast_member_selected != true || $rootpxe_multicast_member_state != RUNNING ]]; then
            printf '%s\n' session_not_running >"$rootpxe_multicast_monitor_failure_file"
            rootpxe_multicast_watchdog_stop_children
            return 1
        fi
        sleep 1
    done
}

rootpxe_multicast_watchdog_start() {
    rootpxe_multicast_pid_alive "${rootpxe_multicast_monitor_pid:-}" && return 0
    umask 077
    rootpxe_multicast_monitor_dir=$(mktemp -d /tmp/rootpxe-multicast-monitor.XXXXXX) || return 1
    chmod 700 "$rootpxe_multicast_monitor_dir" || return 1
    rootpxe_multicast_monitor_failure_file=$rootpxe_multicast_monitor_dir/failure
    rootpxe_multicast_receiver_pid_file=$rootpxe_multicast_monitor_dir/receiver.pid
    rootpxe_multicast_watchdog &
    rootpxe_multicast_monitor_pid=$!
}

rootpxe_multicast_session_guard() {
    [[ ! -s ${rootpxe_multicast_monitor_failure_file:-} ]] || return 1
    rootpxe_multicast_pid_alive "${rootpxe_multicast_monitor_pid:-}" && return 0
    [[ -n ${rootpxe_multicast_monitor_failure_file:-} ]] && printf '%s\n' watchdog_exited >"$rootpxe_multicast_monitor_failure_file"
    return 1
}

rootpxe_multicast_stop_stream() {
    local pid attempt grace=${rootpxe_multicast_shutdown_grace_sec:-5}
    [[ $grace =~ ^[0-9]+$ && $grace -le 30 ]] || grace=5
    rootpxe_multicast_stop_receiver_pid "${rootpxe_multicast_receiver_pid:-}"
    for pid in "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do rootpxe_multicast_pid_alive "$pid" && kill -TERM "$pid" 2>/dev/null || true; done
    for ((attempt=0; attempt<grace; attempt++)); do
        for pid in "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do rootpxe_multicast_pid_alive "$pid" && { sleep 1; break; }; done
    done
    for pid in "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do rootpxe_multicast_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true; [[ $pid =~ ^[0-9]+$ ]] && wait "$pid" 2>/dev/null || true; done
    rm -f -- "${rootpxe_multicast_receiver_pid_file:-}"
    unset rootpxe_multicast_receiver_pid rootpxe_multicast_decoder_pid rootpxe_multicast_decompressor_pid
}

rootpxe_multicast_end() {
    rootpxe_multicast_request end '($common[0] + {sessionId:$sessionId})' --arg sessionId "$multicastSessionId" || return 1
    jq -e --arg session_id "$multicastSessionId" '.sessionId == $session_id and .completed == true' "$rootpxe_multicast_response_file" >/dev/null || return 1
    rootpxe_multicast_data_complete=yes
}

rootpxe_multicast_cancel() {
    [[ -n ${multicastSessionId:-} && -r ${rootpxe_multicast_context_file:-} ]] || return 0
    rootpxe_multicast_request cancel '($common[0] + {sessionId:$sessionId})' --arg sessionId "$multicastSessionId" || return 1
    jq -e --arg session_id "$multicastSessionId" '.sessionId == $session_id' "$rootpxe_multicast_response_file" >/dev/null
}

rootpxe_multicast_stop_runtime() {
    local pid attempt grace=${rootpxe_multicast_shutdown_grace_sec:-5}
    [[ $grace =~ ^[0-9]+$ && $grace -le 30 ]] || grace=5
    rootpxe_multicast_stop_stream
    rootpxe_multicast_pid_alive "${rootpxe_multicast_monitor_pid:-}" && kill -TERM "$rootpxe_multicast_monitor_pid" 2>/dev/null || true
    [[ -r ${rootpxe_multicast_monitor_dir:-}/curl.pid ]] && { read -r pid <"$rootpxe_multicast_monitor_dir/curl.pid"; rootpxe_multicast_pid_alive "$pid" && kill -TERM "$pid" 2>/dev/null || true; }
    for ((attempt=0; attempt<grace; attempt++)); do rootpxe_multicast_pid_alive "${rootpxe_multicast_monitor_pid:-}" || break; sleep 1; done
    rootpxe_multicast_pid_alive "${rootpxe_multicast_monitor_pid:-}" && kill -KILL "$rootpxe_multicast_monitor_pid" 2>/dev/null || true
    [[ ${rootpxe_multicast_monitor_pid:-} =~ ^[0-9]+$ ]] && wait "$rootpxe_multicast_monitor_pid" 2>/dev/null || true
    [[ ${rootpxe_multicast_monitor_dir:-} == /tmp/rootpxe-multicast-monitor.* ]] && rm -rf -- "$rootpxe_multicast_monitor_dir"
    [[ ${rootpxe_multicast_fifo:-} == /tmp/pigz1 && -p ${rootpxe_multicast_fifo:-} ]] && rm -f -- "$rootpxe_multicast_fifo"
    [[ ${rootpxe_multicast_decoder_fifo:-} == /tmp/rootpxe-multicast-decode.* && -p ${rootpxe_multicast_decoder_fifo:-} ]] && rm -f -- "$rootpxe_multicast_decoder_fifo"
    unset rootpxe_multicast_runtime_active rootpxe_multicast_fifo rootpxe_multicast_monitor_pid rootpxe_multicast_receiver_pid_file rootpxe_multicast_decoder_fifo rootpxe_multicast_monitor_failure_file rootpxe_multicast_monitor_dir
}

rootpxe_multicast_runtime_begin() {
    [[ $1 == /tmp/pigz1 && -p $1 ]] || return 1
    rootpxe_multicast_runtime_active=yes; rootpxe_multicast_fifo=$1
}

rootpxe_multicast_reset_attempt() {
    rootpxe_multicast_stop_runtime
    rm -f -- "${rootpxe_multicast_manifest_file:-}" "${rootpxe_multicast_context_file:-}" "${rootpxe_multicast_secret_file:-}" "${rootpxe_multicast_response_file:-}" "${rootpxe_multicast_request_body_file:-}"
    unset rootpxe_multicast_manifest_file rootpxe_multicast_context_file rootpxe_multicast_secret_file rootpxe_multicast_response_file rootpxe_multicast_request_body_file rootpxe_multicast_sequence rootpxe_multicast_data_complete rootpxe_multicast_local_failure
}

rootpxe_multicast_cleanup() {
    rootpxe_multicast_stop_runtime
    if [[ ${rootpxe_multicast_data_complete:-no} != yes && ${rootpxe_multicast_local_failure:-no} != yes ]] && ! rootpxe_multicast_member_terminal "${rootpxe_multicast_member_state:-}" && ! rootpxe_multicast_session_terminal "${rootpxe_multicast_state:-}"; then rootpxe_multicast_cancel >/dev/null 2>&1 || true; fi
    rootpxe_multicast_reset_attempt
}
