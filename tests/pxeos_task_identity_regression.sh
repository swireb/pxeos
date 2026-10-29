#!/usr/bin/env bash
# 离线验证普通部署和捕获请求的存储身份，不访问网络或设备。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d /tmp/rootpxe-task-identity.XXXXXX)
trap 'rootpxe_deployment_identity_cleanup_private; rm -f -- "${rootpxe_deployment_identity_plan_file:-}"; rm -rf -- "$tmp"' EXIT
. "$root/tests/task-http-test-support.sh"
. "$overlay/usr/share/pxeos/lib/deployment-identity.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rootpxe_storage_nonce=11111111111111111111111111111111
rootpxe_storage_worker_nonce=22222222222222222222222222222222
rootpxe_storage_boot_id=11111111-1111-1111-1111-111111111111
rootpxe_storage_sysuuid=33333333-3333-3333-3333-333333333333
progress_attempt=4 taskid=71 task_token=0123456789abcdef0123456789abcdef mac=00:11:22:33:44:55
pxeapi=http://fixture/ rootpxe_api=$pxeapi taskType=deploy
assert_storage_json(){
    jq -e --arg storageNonce "$rootpxe_storage_nonce" --arg workerNonce "$rootpxe_storage_worker_nonce" \
        --arg boot "$rootpxe_storage_boot_id" --arg uuid "$rootpxe_storage_sysuuid" \
        '.storageNonce == $storageNonce and .workerNonce == $workerNonce and .attempt == 4 and .storageBootId == $boot and .sysuuid == $uuid' >/dev/null
}
rootpxe_task_identity_json '{"taskId":71}' | assert_storage_json || fail json_storage_identity_lost
old_worker=$rootpxe_storage_worker_nonce
rootpxe_storage_worker_nonce=invalid
if rootpxe_task_identity_json '{}' >/dev/null; then fail invalid_worker_accepted; fi
rootpxe_storage_worker_nonce=$old_worker
rootpxe_capture_direct=yes
rootpxe_task_identity_json '{}' | jq -e --arg nonce "$rootpxe_storage_nonce" '.captureProtocol == "mac-direct-v1" and .storageNonce == $nonce and .attempt == 4 and (has("workerNonce")|not)' >/dev/null || fail capture_identity_lost
rootpxe_capture_direct=no
: >"$tmp/callbacks"
curl(){
    task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
    local argument value body='' url='' with_code=no
    local -a form=()
    while (( $# )); do
        argument=$1; shift
        case $argument in
            --data-urlencode) form+=("$1"); shift;;
            --data-binary) body=$(cat "${1#@}"); shift;;
            -w) with_code=yes; shift;;
            *) url=$argument;;
        esac
    done
    if [[ -n $body ]]; then
        assert_storage_json <<<"$body" || return 91
        jq -e --arg token "$task_token" --arg mac "$mac" '.taskId == 71 and .token == $token and .mac == $mac' <<<"$body" >/dev/null || return 91
    else
        for value in "storageNonce=$rootpxe_storage_nonce" "workerNonce=$rootpxe_storage_worker_nonce" 'attempt=4' "storageBootId=$rootpxe_storage_boot_id" "sysuuid=$rootpxe_storage_sysuuid"; do
            printf '%s\n' "${form[@]}" | grep -Fxq "$value" || return 91
        done
    fi
    printf '%s\n' "${url##*/}" >>"$tmp/callbacks"
    case $url in
        *deployment-initialization) printf '{"version":1,"unattendXml":"fixture XML"}';;
        *deployment-identity-plan) printf '{"plan":{"version":1,"planId":"fixture-plan"},"planHash":"%064d","attempt":4}' 0;;
        *) printf '{"success":true}';;
    esac
    [[ $with_code != yes ]] || printf '\n200'
}
rootpxe_deployment_identity_private_enabled(){ return 0; }
rootpxe_deployment_identity_policy_enabled(){ return 0; }
rootpxe_deployment_identity_request_private || fail initialization_request_identity
rootpxe_deployment_identity_request_plan || fail plan_request_identity
rootpxe_deployment_identity_report_result true false false || fail result_request_identity
rootpxe_task_curl --data-urlencode "token=$task_token" "${pxeapi}stage" >/dev/null || fail form_identity_lost
[[ $(cat "$tmp/callbacks") == $'deployment-initialization\ndeployment-identity-plan\ndeployment-identity-result\nstage' ]] || fail callback_sequence
. "$overlay/usr/share/pxeos/lib/disk-health.sh"
rootpxe_require_task_context(){ return 0; }
rootpxe_console_message(){ :; }
rootpxe_collect_disk_health(){ printf '{"version":1,"disks":[]}'; }
status=0; rootpxe_send_disk_health || status=$?
[[ $status == 2 ]] || fail confirmed_empty_disk_result_lost
printf 'PASS: ordinary form/JSON storage identity, capture protocol, initialization callbacks and empty disk result\n'
