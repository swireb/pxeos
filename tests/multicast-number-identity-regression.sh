#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
. "$root/tests/task-http-test-support.sh"
. "$overlay/usr/share/pxeos/lib/multicast.sh"
. "$overlay/usr/share/pxeos/lib/deployment-identity.sh"
command -v jq >/dev/null || { echo 'FAIL: real jq is required' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
number=9223372036854775807
key=mc-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
session_key_fixture=$key
other_key=mc-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
stream=cccccccccccccccccccccccccccccccc
failures=0
passes=0
rootpxe_multicast_runtime_ready() { return 0; }

run_case() {
    local name=$1 status
    shift
    set +e
    ( set -e; trap 'rootpxe_multicast_reset_attempt >/dev/null 2>&1 || :' EXIT; "$@" )
    status=$?
    set -e
    if [[ $status == 0 ]]; then echo "PASS: $name"; passes=$((passes + 1));
    else echo "FAIL: $name (exit=$status)" >&2; failures=$((failures + 1)); fi
}

accept_mode() {
    taskType=deploy
    rootpxe_multicast_apply_transport_mode "$(jq -cn --arg id "$number" --arg key "$key" '{transportMode:"multicast",multicastSessionId:$id,multicastSessionKey:$key,waitTimeoutSec:300}')"
    [[ $mc == yes && $multicastSessionId == "$number" && $multicastSessionKey == "$key" ]]
    [[ $(bash -c 'printf "%s/%s" "$multicastSessionId" "$multicastSessionKey"') == "$number/$key" ]]
}

strict_identifiers() {
    accept_mode
    local invalid document
    for invalid in '' 0 01 +1 -1 1e2 1.0 9223372036854775808 18446744073709551615 " $number" "$number " "$key"; do
        document=$(jq -cn --arg id "$invalid" --arg key "$key" '{transportMode:"multicast",multicastSessionId:$id,multicastSessionKey:$key,waitTimeoutSec:300}')
        if rootpxe_multicast_apply_transport_mode "$document"; then echo "accepted invalid number: $invalid" >&2; return 1; fi
        [[ $mc == no && -z ${multicastSessionId:-} && -z ${multicastSessionKey:-} ]]
    done
    for document in \
        '{"transportMode":"multicast","multicastSessionId":1,"waitTimeoutSec":300}' \
        "{\"transportMode\":\"multicast\",\"multicastSessionId\":$number,\"multicastSessionKey\":\"$key\",\"waitTimeoutSec\":300}" \
        "{\"transportMode\":\"multicast\",\"multicastSessionId\":\"1\",\"waitTimeoutSec\":300}" \
        "{\"transportMode\":\"multicast\",\"multicastSessionId\":\"1\",\"multicastSessionKey\":\"${key^^}\",\"waitTimeoutSec\":300}"; do
        if rootpxe_multicast_apply_transport_mode "$document"; then echo 'accepted missing, numeric, or invalid instance identity' >&2; return 1; fi
    done
}

capability_v2() {
    rootpxe_deployment_identity_linux_hostname_capability_installed() { return 1; }
    rootpxe_deployment_identity_windows_hostname_capability_installed() { return 1; }
    rootpxe_deployment_identity_windows_sysprep_capability_installed() { return 1; }
    rootpxe_deployment_identity_capabilities_json | jq -e 'index("manual-multicast-session-v2") != null and index("manual-multicast-session") == null' >/dev/null
}

setup_context() {
    accept_mode
    taskid=71 task_token=0123456789abcdef0123456789abcdef mac=aa:bb:cc:dd:ee:ff progress_attempt=4
    rootpxe_storage_nonce=11111111111111111111111111111111 rootpxe_storage_worker_nonce=22222222222222222222222222222222
    rootpxe_storage_boot_id=11111111-1111-1111-1111-111111111111 rootpxe_storage_sysuuid=33333333-3333-3333-3333-333333333333
    export rootpxe_storage_nonce rootpxe_storage_worker_nonce rootpxe_storage_boot_id rootpxe_storage_sysuuid

    rootpxe_api=http://controller/ pxeapi=http://controller/ web=http://controller/
    rootpxe_multicast_manifest_file=$(mktemp /tmp/rootpxe-multicast-manifest.XXXXXX)
    printf '%s' '[{"artifactKey":"disk.img","paths":["disk.img"]}]' >"$rootpxe_multicast_manifest_file"
    rootpxe_multicast_sequence=0
    request_log="$tmp/requests.$BASHPID"
    : >"$request_log"
    curl() {
        task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
        local out='' request='' url='' response_key=${mock_response_key:-$session_key_fixture} response_number=${mock_response_number:-$number}
        while (( $# )); do
            case $1 in -o) out=$2; shift 2;; --data-binary) request=${2#@}; shift 2;; *) url=$1; shift;; esac
        done
        jq -e --arg id "$number" --arg key "$session_key_fixture" '.taskId == 71 and .progressAttempt == 4 and .attempt == 4 and .storageNonce == "11111111111111111111111111111111" and .workerNonce == "22222222222222222222222222222222" and .storageBootId == "11111111-1111-1111-1111-111111111111" and .sysuuid == "33333333-3333-3333-3333-333333333333" and .sessionId == $id and (.sessionId|type) == "string" and .sessionKey == $key and .executionToken == "0123456789abcdef0123456789abcdef"' "$request" >/dev/null || { printf 'request identity assertion failed\n' >>"$request_log"; return 91; }
        printf '%s\n' "${url##*/}" >>"$request_log"
        case $url in
            *join|*status) jq -cn --arg id "$response_number" --arg key "$response_key" '{sessionId:$id,sessionKey:$key,state:"RUNNING",currentSequence:2,member:{state:"RUNNING",selected:true}}' >"$out";;
            *prepare) jq -cn --arg id "$response_number" --arg key "$response_key" --arg stream "$stream" '{sessionId:$id,sessionKey:$key,streamId:$stream,sequence:1,portBase:9000,multicastAddress:"239.1.2.3",ttl:32,senderAddress:"10.1.2.3",receiverTimeoutSec:300}' >"$out";;
            *end) jq -cn --arg id "$response_number" --arg key "$response_key" '{sessionId:$id,sessionKey:$key,completed:true}' >"$out";;
            *) jq -cn --arg id "$response_number" --arg key "$response_key" '{sessionId:$id,sessionKey:$key}' >"$out";;
        esac
        printf 200
    }
}

seven_requests() {
    setup_context
    rootpxe_multicast_join || { echo "join failed: ${rootpxe_multicast_last_failure:-local}/${rootpxe_multicast_last_join_stage:-}/${rootpxe_multicast_last_curl_exit:-}" >&2; return 1; }
    jq -e --arg id "$number" --arg key "$key" '.sessionId == $id and (.sessionId|type) == "string" and .sessionKey == $key' "$rootpxe_multicast_context_file" >/dev/null
    rootpxe_multicast_status
    rootpxe_multicast_prepare_stream disk.img
    rootpxe_multicast_ready
    rootpxe_multicast_report true
    rootpxe_multicast_end
    rootpxe_multicast_cancel
    [[ $(cat "$request_log") == $'join\nstatus\nprepare\nready\nreport\nend\ncancel' ]]
}

context_mismatch() {
    setup_context
    rootpxe_multicast_context_begin
    multicastSessionKey=$other_key
    if rootpxe_multicast_status; then echo 'mismatched context made a request' >&2; return 1; fi
    [[ ! -s $request_log ]]
    multicastSessionKey=$key
    progress_attempt=5
    if rootpxe_multicast_status; then echo 'old attempt context made a request' >&2; return 1; fi
    [[ ! -s $request_log ]]
    progress_attempt=4
    local original_worker=$rootpxe_storage_worker_nonce original_nonce=$rootpxe_storage_nonce original_boot=$rootpxe_storage_boot_id
    rootpxe_storage_worker_nonce=44444444444444444444444444444444
    if rootpxe_multicast_status; then echo 'old worker context made a request' >&2; return 1; fi
    [[ ! -s $request_log ]]
    rootpxe_storage_worker_nonce=$original_worker rootpxe_storage_nonce=44444444444444444444444444444444
    if rootpxe_multicast_status; then echo 'old reservation context made a request' >&2; return 1; fi
    [[ ! -s $request_log ]]
    rootpxe_storage_nonce=$original_nonce rootpxe_storage_boot_id=44444444-4444-4444-4444-444444444444
    if rootpxe_multicast_status; then echo 'old boot context made a request' >&2; return 1; fi
    [[ ! -s $request_log ]]
    rootpxe_storage_boot_id=$original_boot
    task_token=different-current-task-token
    if rootpxe_multicast_status; then echo 'old token context made a request' >&2; return 1; fi
    [[ ! -s $request_log ]]
}

wrong_response() {
    setup_context
    rootpxe_multicast_context_begin
    rootpxe_multicast_state=WAITING rootpxe_multicast_member_state=READY
    mock_response_key=$other_key
    if rootpxe_multicast_status; then echo 'accepted reused public number with wrong key' >&2; return 1; fi
    [[ $rootpxe_multicast_state == WAITING && $rootpxe_multicast_member_state == READY && -z ${rootpxe_multicast_response_file:-} ]]
    mock_response_key=$key mock_response_number=1
    if rootpxe_multicast_status; then echo 'accepted mismatched public number' >&2; return 1; fi
    [[ $rootpxe_multicast_state == WAITING && -z ${rootpxe_multicast_response_file:-} ]]
}

unicast_clears_context() {
    setup_context
    rootpxe_multicast_context_begin
    local old_context=$rootpxe_multicast_context_file old_secret=$rootpxe_multicast_secret_file
    rootpxe_multicast_apply_transport_mode '{"transportMode":"unicast"}'
    [[ $mc == no && -z ${multicastSessionId:-} && -z ${multicastSessionKey:-} && -z ${rootpxe_multicast_context_file:-} && -z ${rootpxe_multicast_secret_file:-} ]]
    [[ ! -e $old_context && ! -e $old_secret ]]
    rootpxe_task_multicast_form_args
    [[ ${#rootpxe_task_multicast_args[@]} == 0 ]]
    rootpxe_task_multicast_json '{"taskId":71}' | jq -e '.taskId == 71 and (has("sessionId")|not) and (has("sessionKey")|not) and .storageNonce == "11111111111111111111111111111111" and .workerNonce == "22222222222222222222222222222222" and .attempt == 4' >/dev/null
    if rootpxe_multicast_status; then echo 'old multicast context survived unicast switch' >&2; return 1; fi
    [[ ! -s $request_log ]]
}

load_function() {
    local source=$1 name=$2
    awk -v name="$name" '$0 ~ "^" name "\\(\\)" { copy=1 } copy { print } copy && /^}/ { exit }' "$source" >"$tmp/function-$name.sh"
    # Cygwin's regex engine can cap bounded repetitions at 255. Only this
    # extracted fixture narrows the existing token bound for our 32-byte
    # token; production validation and all wire assertions stay unchanged.
    if ! ( [[ 0123456789abcdef0123456789abcdef =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]] ) 2>/dev/null; then
        sed 's/{16,512}/{16,255}/g' "$tmp/function-$name.sh" >"$tmp/narrow-token.sh"
        mv "$tmp/narrow-token.sh" "$tmp/function-$name.sh"
    fi
    . "$tmp/function-$name.sh"
}

setup_callback_recorder() {
    setup_context
    callback_log="$tmp/callbacks.$BASHPID"
    : >"$callback_log"
    curl() {
        task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
        local argument value url='' body='' id='' instance='' attempt='' with_code=no
        while (( $# )); do
            argument=$1; shift
            case $argument in
                --data-urlencode)
                    value=$1; shift
                    case $value in sessionId=*) id=${value#*=};; sessionKey=*) instance=${value#*=};; progressAttempt=*) attempt=${value#*=};; esac;;
                --data-binary) body=$1; shift; [[ $body != @* ]] || body=$(cat "${body#@}");;
                -w) with_code=yes; shift;;
                *) url=$argument;;
            esac
        done
        if [[ -n $body ]]; then
            jq -e --arg id "$number" --arg key "$session_key_fixture" '.sessionId == $id and (.sessionId|type) == "string" and .sessionKey == $key and .progressAttempt == 4' <<<"$body" >/dev/null || { echo "bad ${url##*/}" >>"$callback_log"; return 91; }
        elif [[ $id != "$number" || $instance != "$session_key_fixture" || $attempt != 4 ]]; then
            echo "bad ${url##*/}" >>"$callback_log"; return 91
        fi
        echo "ok ${url##*/}" >>"$callback_log"
        case $url in
            *task-status) printf '{"status":"cancelled"}';;
            *deployment-initialization) printf '{"version":1,"unattendXml":"fixture XML"}';;
            *deployment-identity-plan) printf '{"plan":{"version":1,"planId":"fixture-plan"},"planHash":"%064d","attempt":4}' 0;;
            *) printf '{"success":true}';;
        esac
        [[ $with_code != yes ]] || printf '\n200'
    }
    rootpxe_require_task_context() { return 0; }
    rootpxe_console_message() { :; }
    dots() { :; }
    debugPause() { :; }
}

ordinary_form_callbacks() {
    setup_callback_recorder
    local funcs="$overlay/usr/share/pxeos/lib/funcs.sh" name
    for name in rootpxe_stage rootpxe_partition_progress_send_snapshot rootpxe_task_status_confirms_disk_permit_cancellation; do load_function "$funcs" "$name"; done
    rootpxe_stage restore 'fixture progress'
    printf '%s' '{"version":2,"items":[]}' >"$tmp/snapshot.json"
    type=down
    rootpxe_partition_progress_send_snapshot "$tmp/snapshot.json"
    rootpxe_task_status_confirms_disk_permit_cancellation
    . "$overlay/usr/share/pxeos/lib/disk-health.sh"
    rootpxe_collect_disk_health() { printf '%s' '{"version":1,"disks":[{"device":"fixture","status":"unknown"}]}'; }
    rootpxe_send_disk_health
    # The reporter fixture redirects only its fixed scratch path; no actual
    # partclone/status process or existing /tmp progress snapshot is touched.
    load_function "$overlay/bin/pxeos.statusreporter" rootpxe_progress_send_snapshot
    sed "s|/tmp/pxeos.partition-progress.json|$tmp/snapshot.json|g" "$tmp/function-rootpxe_progress_send_snapshot.sh" >"$tmp/reporter.sh"
    . "$tmp/reporter.sh"
    api_base=$rootpxe_api prog_stage=restore
    rootpxe_progress_send_snapshot
    pct=42 b64=Zml4dHVyZQ== sysuuid=fixture
    awk '/last_pct=\$pct; b64=/ { copy=1; next } copy { print } copy && /api_base.*progress/ { exit }' "$overlay/bin/pxeos.statusreporter" >"$tmp/reporter-fallback.sh"
    . "$tmp/reporter-fallback.sh"
    task_mode=1 poststring=fixture
    awk '/^count=0$/ { copy=1 } copy { print } copy && /^echo "Done"/ { exit }' "$overlay/bin/pxeos.inventory" >"$tmp/inventory.sh"
    . "$tmp/inventory.sh" >/dev/null
    rootpxe_deployment_identity_policy_enabled() { return 1; }
    rootpxe_clear_capture_marker() { return 0; }
    rootpxe_cleanup_task_json() { :; }
    rootpxe_capture_resume_cleanup() { :; }
    dmidecode() { printf 'fixture\n'; }
    . "$overlay/bin/pxeos.imgcomplete" >/dev/null
    [[ $(cat "$callback_log") == $'ok stage\nok progress\nok task-status\nok inventory\nok progress\nok progress\nok inventory\nok finish' ]]
    : >"$callback_log"
    multicastSessionKey=$other_key
    multicastSessionId=01
    if rootpxe_stage restore 'invalid identity'; then echo 'stage accepted invalid pair' >&2; return 1; fi
    [[ ! -s $callback_log ]]
}

identity_json_callbacks() {
    setup_callback_recorder
    rootpxe_deployment_identity_private_enabled() { return 0; }
    rootpxe_deployment_identity_policy_enabled() { return 0; }
    rootpxe_deployment_identity_request_private
    rootpxe_deployment_identity_request_plan
    rootpxe_deployment_identity_report_result true false false
    [[ $(cat "$callback_log") == $'ok deployment-initialization\nok deployment-identity-plan\nok deployment-identity-result' ]]
    rootpxe_deployment_identity_cleanup_private
    rm -f -- "$rootpxe_deployment_identity_plan_file"
}

reset_rejects_traversal() {
    local owned sentinel
    owned=$(mktemp -d /tmp/rootpxe-multicast-context.XXXXXX)
    sentinel=$owned/sentinel
    printf 'keep' >"$sentinel"
    rootpxe_multicast_context_file="$owned/../${owned##*/}/sentinel"
    rootpxe_multicast_reset
    if [[ ! -f $sentinel ]]; then rm -rf -- "$owned"; echo 'reset deleted a non-owned traversal path' >&2; return 1; fi
    [[ $(cat "$sentinel") == keep ]]
    rm -rf -- "$owned"
}

invalid_metadata_keeps_empty_disk_result() {
    setup_callback_recorder
    . "$overlay/usr/share/pxeos/lib/disk-health.sh"
    rootpxe_collect_disk_health() { printf '%s' '{"version":1,"disks":[]}'; }
    multicastSessionId=01
    local status=0
    rootpxe_send_disk_health || status=$?
    [[ $status == 2 && ! -s $callback_log ]]
}

run_case 'strict int64 decimal text / JSON types / environment exports' strict_identifiers
run_case 'v2 capability only' capability_v2
run_case 'checkin pair -> persisted context -> all seven dedicated requests' seven_requests
run_case 'inconsistent instance, attempt, or token makes no request' context_mismatch
run_case 'wrong response identity is not saved' wrong_response
run_case 'multicast to unicast clears environment and persisted context' unicast_clears_context
run_case 'stage, progress v1/v2, task-status, inventory, disk health and finish carry full pair' ordinary_form_callbacks
run_case 'identity plan, private configuration and result carry full pair' identity_json_callbacks
run_case 'reset rejects traversal beyond exact mktemp basename' reset_rejects_traversal
run_case 'invalid metadata cannot hide confirmed empty physical disk inventory' invalid_metadata_keeps_empty_disk_result
printf 'RESULT: pass=%s fail=%s\n' "$passes" "$failures"
[[ $failures == 0 ]]
