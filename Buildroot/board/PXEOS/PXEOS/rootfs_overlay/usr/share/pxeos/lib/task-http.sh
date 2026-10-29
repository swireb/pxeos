#!/bin/bash
# 仅用于带任务凭据的控制面请求；健康探测保留自己的调用方式。
rootpxe_task_curl() {
    (
        local request_dir argument value file native_status=0 request_http_status index=0 native_pid='' native_pending=no
        local -a request_args=()
        local has_form=no has_binary=no
        umask 077
        request_dir=$(mktemp -d /tmp/rootpxe-http.XXXXXX) || return 73
        trap 'if [[ $native_pending == yes ]]; then kill -TERM "$native_pid" 2>/dev/null || :; wait "$native_pid" 2>/dev/null || :; fi; rm -rf -- "$request_dir"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        while (( $# )); do
            argument=$1; shift
            [[ $argument != --data-urlencode ]] || has_form=yes
            [[ $argument != --data-binary ]] || has_binary=yes
            case $argument in
                -L|--location|--location-trusted) continue ;;
                --data-urlencode|--data-binary)
                    (( $# )) || return 2
                    value=$1; shift
                    if [[ $argument == --data-urlencode && $value == token=* ]]; then
                        index=$((index + 1)); file="$request_dir/token-$index"
                        printf '%s' "${value#token=}" >"$file" || return 73
                        value="token@$file"
                    elif [[ $argument == --data-binary && $value != @* ]]; then
                        index=$((index + 1)); file="$request_dir/body-$index"
                        printf '%s' "$value" >"$file" || return 73
                        value="@$file"
                    fi
                    request_args+=("$argument" "$value")
                    continue ;;
                -[A-Za-z]*)
                    argument=${argument//L/}
                    [[ $argument != - ]] || continue ;;
            esac
            request_args+=("$argument")
        done
        if [[ $has_form == yes && $has_binary == no && ${rootpxe_capture_direct:-no} == yes ]]; then
            request_args+=(--data-urlencode "captureProtocol=mac-direct-v1" --data-urlencode "attempt=$progress_attempt" --data-urlencode "storageNonce=$rootpxe_storage_nonce")
            [[ ${rootpxe_capture_stopped:-no} != yes ]] || request_args+=(--data-urlencode workerStopped=true)
        elif [[ $has_form == yes && $has_binary == no && -n ${rootpxe_storage_nonce:-} ]]; then
            request_args+=(--data-urlencode "storageNonce=$rootpxe_storage_nonce" --data-urlencode "workerNonce=$rootpxe_storage_worker_nonce" --data-urlencode "attempt=$progress_attempt" --data-urlencode "storageBootId=${rootpxe_storage_boot_id:-}" --data-urlencode "sysuuid=${rootpxe_storage_sysuuid:-}")
        fi
        # header 文件与请求 body 同属此次调用，既不碰 stdin 也不落任务日志。
        : >"$request_dir/headers" || return 73
        ( trap - EXIT INT TERM; curl -q --no-location --dump-header "$request_dir/headers" "${request_args[@]}" ) <&0 &
        native_pid=$!; native_pending=yes
        wait "$native_pid" || native_status=$?
        native_pending=no
        (( native_status == 0 )) || return "$native_status"
        request_http_status=$(awk '$1 ~ /^HTTP\// && $2 ~ /^[0-9][0-9][0-9]$/ { status=$2 } END { print status }' "$request_dir/headers" 2>/dev/null) || return 73
        [[ $request_http_status =~ ^[1-5][0-9]{2}$ ]] || return 73
        [[ $request_http_status != 3[0-9][0-9] ]] || return 22
        return 0
    )
}

rootpxe_task_identity_json() {
    local document=$1
    if [[ ${rootpxe_capture_direct:-no} == yes ]]; then
        document=$(jq -c --arg protocol mac-direct-v1 --arg nonce "$rootpxe_storage_nonce" --argjson attempt "$progress_attempt" '. + {captureProtocol:$protocol,storageNonce:$nonce,attempt:$attempt}' <<<"$document") || return 1
    elif [[ -n ${rootpxe_storage_nonce:-} ]]; then
        [[ ${progress_attempt:-} =~ ^[1-9][0-9]*$ && ${rootpxe_storage_worker_nonce:-} =~ ^[a-f0-9]{32}$ ]] || return 1
        document=$(jq -c --arg storageNonce "$rootpxe_storage_nonce" --arg workerNonce "$rootpxe_storage_worker_nonce" \
          --argjson attempt "$progress_attempt" --arg storageBootId "${rootpxe_storage_boot_id:-}" --arg sysuuid "${rootpxe_storage_sysuuid:-}" \
          '. + {storageNonce:$storageNonce,workerNonce:$workerNonce,attempt:$attempt,storageBootId:$storageBootId,sysuuid:$sysuuid}' <<<"$document") || return 1
    fi
    printf '%s' "$document"
}
