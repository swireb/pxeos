#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib="${MULTICAST_LIB:-$repo_root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh}"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
messages=()
rootpxe_console_message() { messages+=("$2"); }
curl() {
    local output='' argument
    while (( $# )); do
        case $1 in
            -o) output=$2; shift 2 ;;
            --data-binary) argument=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ $argument == @* ]] || return 90
    printf '%s' "${MOCK_RESPONSE:-}" >"$output"
    printf '%s' "${MOCK_HTTP-409}"
    return "${MOCK_CURL_EXIT:-0}"
}
. "$lib"
rootpxe_api=http://controller/
request="$tmp/request.json"
printf '{}' >"$request"

MOCK_HTTP=409 MOCK_CURL_EXIT=0 MOCK_RESPONSE='{"code":"multicast_unavailable","error":"多播发送组件不可用"}'
if rootpxe_multicast_http_post join "$request"; then exit 1; fi
[[ $rootpxe_multicast_last_failure == rejected && $rootpxe_multicast_last_http_op == join ]]
[[ $rootpxe_multicast_last_http_status == 409 && $rootpxe_multicast_last_curl_exit == 0 ]]
[[ $rootpxe_multicast_last_error_code == multicast_unavailable && $rootpxe_multicast_last_error_summary == 'multicast sender unavailable' ]]
[[ ${messages[-1]} == *'op=join http=409 curl=0 code=multicast_unavailable error=multicast sender unavailable'* ]]

MOCK_HTTP=500 MOCK_CURL_EXIT=0 MOCK_RESPONSE='{"code":"secret_token","error":"token=secret"}'
if rootpxe_multicast_http_post join "$request"; then exit 1; fi
[[ $rootpxe_multicast_last_error_code == redacted && $rootpxe_multicast_last_error_summary == redacted ]]
[[ ${messages[-1]} != *secret* && ${messages[-1]} == *'code=redacted error=redacted'* ]]

MOCK_HTTP=409 MOCK_CURL_EXIT=0 MOCK_RESPONSE='{"code":"multicast_session_lost","error":"多播会话已丢失，请重新手动创建多播部署会话"}'
if rootpxe_multicast_http_post join "$request"; then exit 1; fi
[[ $rootpxe_multicast_last_error_code == multicast_session_lost ]]
[[ $rootpxe_multicast_last_error_summary == 'manual multicast session lost; create a new manual multicast deployment session' ]]
[[ ${messages[-1]} != *legacy* ]]

MOCK_HTTP=200 MOCK_CURL_EXIT=0 MOCK_RESPONSE='{not-json'
if rootpxe_multicast_http_post join "$request"; then exit 1; fi
[[ $rootpxe_multicast_last_failure == response_invalid && $rootpxe_multicast_last_error_code == redacted && $rootpxe_multicast_last_error_summary == redacted ]]

MOCK_HTTP='' MOCK_CURL_EXIT=7 MOCK_RESPONSE=''
if rootpxe_multicast_http_post join "$request"; then exit 1; fi
[[ $rootpxe_multicast_last_http_status == none && $rootpxe_multicast_last_curl_exit == 7 ]]
[[ $rootpxe_multicast_last_failure == network ]]
[[ ${messages[-1]} == *'http=none curl=7 code=redacted error=redacted'* ]]

message_count=${#messages[@]}
MOCK_HTTP=200 MOCK_CURL_EXIT=0 MOCK_RESPONSE='{}'
rootpxe_multicast_http_post join "$request"
[[ ${#messages[@]} == "$message_count" && -r $rootpxe_multicast_response_file ]]
rm -f -- "$rootpxe_multicast_response_file"
unset rootpxe_multicast_response_file

multicastTransportMode=unicast taskType=deploy rootpxe_multicast_manifest_file="$request"
if rootpxe_multicast_join; then exit 1; fi
[[ $rootpxe_multicast_last_failure == join_local && $rootpxe_multicast_last_join_stage == precondition ]]
echo 'multicast error diagnostics regression passed'
