#!/bin/bash
# 仅用于带任务凭据的控制面请求；健康探测保留自己的调用方式。
rootpxe_task_curl() {
    (
        local request_dir argument value file native_status=0 request_http_status index=0 native_pid='' native_pending=no owned_pid_file=''
        local -a request_args=()
        umask 077
        request_dir=$(mktemp -d /tmp/rootpxe-http.XXXXXX) || return 73
        trap 'if [[ $native_pending == yes ]]; then kill -TERM "$native_pid" 2>/dev/null || :; wait "$native_pid" 2>/dev/null || :; fi; if [[ -n $owned_pid_file && ! -L $owned_pid_file && $(cat "$owned_pid_file" 2>/dev/null) == "$native_pid" ]]; then rm -f -- "$owned_pid_file"; fi; rm -rf -- "$request_dir"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        while (( $# )); do
            argument=$1; shift
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
        # header 文件与请求 body 同属此次调用，既不碰 stdin 也不落任务日志。
        : >"$request_dir/headers" || return 73
        if [[ -n ${rootpxe_task_curl_pid_file:-} ]]; then
            [[ $rootpxe_task_curl_pid_file == /tmp/rootpxe-multicast-monitor.*/curl.pid && -d ${rootpxe_task_curl_pid_file%/*} && -O ${rootpxe_task_curl_pid_file%/*} && ! -L ${rootpxe_task_curl_pid_file%/*} && ! -e $rootpxe_task_curl_pid_file && ! -L $rootpxe_task_curl_pid_file ]] || return 73
        fi
        ( trap - EXIT INT TERM; curl -q --no-location --dump-header "$request_dir/headers" "${request_args[@]}" ) <&0 &
        native_pid=$!; native_pending=yes
        if [[ -n ${rootpxe_task_curl_pid_file:-} ]]; then
            ( set -o noclobber; printf '%s\n' "$native_pid" >"$rootpxe_task_curl_pid_file" ) || return 73
            owned_pid_file=$rootpxe_task_curl_pid_file
        fi
        wait "$native_pid" || native_status=$?
        native_pending=no
        (( native_status == 0 )) || return "$native_status"
        request_http_status=$(awk '$1 ~ /^HTTP\// && $2 ~ /^[0-9][0-9][0-9]$/ { status=$2 } END { print status }' "$request_dir/headers" 2>/dev/null) || return 73
        [[ $request_http_status =~ ^[1-5][0-9]{2}$ ]] || return 73
        [[ $request_http_status != 3[0-9][0-9] ]] || return 22
        return 0
    )
}

# 会话编号始终作为十进制文本处理，不能经 shell 整数或 jq 数值转换。
rootpxe_task_multicast_number_valid() {
    local value=${1:-} LC_ALL=C
    [[ $value =~ ^[1-9][0-9]*$ && ${#value} -le 19 ]] || return 1
    [[ ${#value} -lt 19 || $value < 9223372036854775807 || $value == 9223372036854775807 ]]
}

rootpxe_task_multicast_identity_valid() {
    [[ ${mc:-no} == yes && ${multicastSessionKey:-} =~ ^mc-[0-9a-f]{48}$ && ${progress_attempt:-} =~ ^[1-9][0-9]*$ ]] &&
        rootpxe_task_multicast_number_valid "${multicastSessionId:-}"
}

rootpxe_task_multicast_form_args() {
    rootpxe_task_multicast_args=()
    [[ ${mc:-no} == yes ]] || return 0
    rootpxe_task_multicast_identity_valid || return 1
    rootpxe_task_multicast_args=(--data-urlencode "progressAttempt=$progress_attempt" --data-urlencode "sessionId=$multicastSessionId" --data-urlencode "sessionKey=$multicastSessionKey")
}

rootpxe_task_multicast_json() {
    local document=$1
    if [[ ${mc:-no} != yes ]]; then printf '%s' "$document"; return 0; fi
    rootpxe_task_multicast_identity_valid || return 1
    jq -c --arg sessionId "$multicastSessionId" --arg sessionKey "$multicastSessionKey" --argjson progressAttempt "$progress_attempt" \
        '. + {sessionId:$sessionId,sessionKey:$sessionKey,progressAttempt:$progressAttempt}' <<<"$document"
}
