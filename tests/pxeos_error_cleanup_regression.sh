#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$root/tests/task-http-test-support.sh"
for function in rootpxe_redact_diagnostic rootpxe_utf8_safe_prefix rootpxe_error_response_reason rootpxe_failure_begin rootpxe_failure_remaining rootpxe_error_report rootpxe_error_wait_for_retry handleError; do
    eval "$(sed -n "/^$function() {/,/^}/p" "$lib/funcs.sh" | sed "s|/tmp/pxeos.failure_action|$tmp/failure_action|g")"
done
. "$lib/storage-io.sh"
rootpxe_cleanup_task_json() { :; }; rootpxe_deployment_identity_cleanup_private() { :; }
rootpxe_task_console_failure() { :; }
rootpxe_diagnostic_cleanup() { :; }; rootpxe_console_message() { printf '%s\n' "$*"; }
rootpxe_require_task_context() { :; }; rootpxe_bound_callback_message() { printf '%s' "$1"; }
killStatusReporter() { :; }; rootpxe_storage_quiesce() { printf 'quiesce\n' >>"$tmp/events"; }
rootpxe_storage_call() { printf '%s\n' "$1" >>"$tmp/events"; : >"$tmp/released"; }
rootpxe_storage_recover_until_clean() { fail 'unexpected storage recovery'; }
taskid=41 task_token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa mac=aabbccddeeff
pxeapi=http://fixture/ web='' rootpxe_storage_workspace="$tmp/workspace"
rootpxe_storage_nonce=nonce rootpxe_storage_worker_nonce=worker progress_attempt=2
clock=100
date() { printf '%s\n' "$clock"; }
sleep() { : >"$tmp/unexpected-sleep"; fail 'unexpected retry sleep'; }
curl() {
    task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
    if [[ $* == *'/error'* ]]; then
        printf 'error\n' >>"$tmp/events"
        if [[ -e $tmp/released ]]; then printf '{"accepted":false,"error":"released owner"}\n409';
        else printf '{"accepted":true,"waitSec":60,"failureAction":"shutdown"}\n200'; fi
    else
        printf 'status\n' >>"$tmp/events"
        printf '{"status":"cancelled"}'
    fi
}
status=0
( handleError 'inventory failed' ) >"$tmp/console" 2>&1 || status=$?
[[ $status == 2 ]] || { cat "$tmp/console"; fail "confirmed cleanup must enter status wait: $status"; }
[[ $(cat "$tmp/events") == $'quiesce\nerror\nrelease\nstatus' ]] || fail 'worker was not stopped before confirmation, or error was resent after release'
[[ $(cat "$tmp/failure_action") == shutdown ]] || fail 'confirmed cleanup policy not preserved'

# With the same confirmed response, a queued status requests a fresh PXEOS
# execution instead of attempting to use the released storage owner.
sed -n '/^rootpxe_error_wait_for_retry() {/,/^}/p' "$lib/funcs.sh" |
    sed -e "s|/tmp/pxeos.failure_action|$tmp/failure_action|g" -e 's|exec /bin/pxeos|rootpxe_test_exec /bin/pxeos|' >"$tmp/retry.sh"
. "$tmp/retry.sh"
rootpxe_reset_disk_permit_retry_state() { printf 'reset\n' >>"$tmp/retry-events"; }
rootpxe_task_log_release_pin() { printf 'unpin\n' >>"$tmp/retry-events"; }
rootpxe_test_exec() { printf 'exec\n' >>"$tmp/retry-events"; exit 88; }
rootpxe_storage_released=yes rootpxe_storage_stopped=yes
curl() {
    task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
    [[ $* == *'/task-status'* ]] || fail 'confirmed response was reported again'
    printf '{"status":"queued"}'
}
status=0
( rootpxe_error_wait_for_retry failure CODE console_shown '{"accepted":true,"waitSec":60}' ) >"$tmp/retry-console" 2>&1 || status=$?
[[ $status == 88 && $(cat "$tmp/retry-events") == $'reset\nunpin\nexec' ]] || fail 'UI retry did not start a fresh PXEOS execution'

# A permanent identity rejection is not resent or polled. The first failure's
# checkin policy still provides a finite wait before the failure power action.
rm -f "$tmp/failure_action" "$tmp/events"
curl() {
    task_http_test_decode_curl_args "$@"
    printf 'error\n' >>"$tmp/events"
    printf '{"accepted":false,"error":"存储执行绑定已失效 token=%s\\u001b\\n","token":"hidden-secret","detail":"private-detail"}\n409' "$task_token"
}
sleep() { clock=$((clock + $1)); }
rootpxe_failure_wait_sec=60
status=0
( rootpxe_error_wait_for_retry failure CODE console_shown ) >"$tmp/conflict" 2>&1 || status=$?
[[ $status == 2 && $(cat "$tmp/failure_action") == reboot && $(cat "$tmp/events") == error ]] || fail '409 was retried, accepted or skipped the failure wait'
grep -Fq 'HTTP 409' "$tmp/conflict" && grep -Fq '存储执行绑定已失效' "$tmp/conflict" || fail '409 Chinese reason missing'
! grep -Eq "hidden-secret|private-detail|$task_token" "$tmp/conflict" || fail '409 response leaked uncontrolled fields or credentials'
for rejected_status in 403 404; do
    rm -f "$tmp/events" "$tmp/failure_action" "$tmp/unexpected-sleep"
    curl() { task_http_test_decode_curl_args "$@"; printf 'error\n' >>"$tmp/events"; printf '{"error":"task no longer belongs to this client"}\n%s' "$rejected_status"; }
    status=0
    ( rootpxe_error_wait_for_retry failure CODE console_shown ) >"$tmp/permanent-rejection" 2>&1 || status=$?
    [[ $status == 2 && $(cat "$tmp/events") == error && $(cat "$tmp/failure_action") == reboot && ! -e $tmp/unexpected-sleep ]] || fail "permanent HTTP $rejected_status was retried, accepted or skipped the failure wait"
done
reason=$(LC_ALL=C rootpxe_error_response_reason '{"error":"存储执行绑定已失效 token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u001b"}')
[[ $reason == *'存储执行绑定已失效'* && $reason != *$'\033'* && $reason != *"$task_token"* ]] || fail 'C locale reason lost Chinese or leaked controls/credentials'
long_reason=$(printf '中%.0s' {1..100})
reason=$(LC_ALL=C rootpxe_error_response_reason "{\"error\":\"$long_reason\"}")
printf '%s' "$reason" | python3 -c 'import sys; raw=sys.stdin.buffer.read(); assert len(raw) <= 160; raw.decode("utf-8", "strict")' || fail 'reason limit split UTF-8'

# A rejected cleanup report must clear any earlier success response.
rootpxe_storage_failure_response='{"accepted":true,"waitSec":60}'
rootpxe_storage_released=no
status=0
rootpxe_storage_failure_cleanup failure || status=$?
[[ $status == 1 && -z ${rootpxe_storage_failure_response:-} ]] || fail 'stale accepted response survived cleanup rejection'

# Even an accepted reply cannot escape a cleanup that fails to release.
rootpxe_storage_released=no
rootpxe_storage_call() { return 1; }
curl() { task_http_test_decode_curl_args "$@"; printf '{"accepted":true,"waitSec":60}\n200'; }
status=0
rootpxe_storage_failure_cleanup failure || status=$?
[[ $status == 1 && -z ${rootpxe_storage_failure_response:-} ]] || fail 'failed cleanup published an acknowledgement'

# Network and 5xx retry only inside the original failure window.
rm -f "$tmp/events" "$tmp/failure_action"
unset rootpxe_failure_started_at rootpxe_failure_deadline rootpxe_failure_policy_confirmed rootpxe_failure_report_rejected
sleep() { clock=$((clock + $1)); printf 'sleep\n' >>"$tmp/events"; }
curl() {
    task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
    if [[ $* == *'/task-status'* ]]; then printf '{"status":"deleted"}'; return; fi
    local count=0
    [[ ! -e $tmp/transient-calls ]] || count=$(cat "$tmp/transient-calls")
    count=$((count + 1)); printf '%s' "$count" >"$tmp/transient-calls"
    case $count in
        1) return 7 ;;
        2) printf '{"accepted":false}\n503' ;;
        3) printf '{"accepted":false}\n408' ;;
        4) printf '{"accepted":false}\n429' ;;
        *) printf '{"accepted":true,"waitSec":60}\n200' ;;
    esac
}
status=0
( rootpxe_error_wait_for_retry failure CODE console_shown ) >"$tmp/transient-console" 2>&1 || status=$?
[[ $status == 2 && $(cat "$tmp/transient-calls") == 5 && $(cat "$tmp/events") == $'sleep\nsleep\nsleep\nsleep' ]] || fail 'transient failures did not retry until a genuine acknowledgement'

# The production console wraps by bytes in the C locale. A long Chinese
# rejection must reach it as complete UTF-8 lines.
eval "$(sed -n '/^rootpxe_console_message() {/,/^}/p' "$lib/funcs.sh")"
curl() { task_http_test_decode_curl_args "$@"; printf '{"error":"%s"}\n409' "$long_reason"; }
status=0
( LC_ALL=C rootpxe_error_wait_for_retry failure CODE console_shown ) >"$tmp/chinese-console" 2>&1 || status=$?
[[ $status == 2 ]] || fail 'Chinese identity conflict did not reach the failure deadline'
python3 -c 'import pathlib,sys; data=pathlib.Path(sys.argv[1]).read_bytes(); data.decode("utf-8", "strict")' "$tmp/chinese-console" || fail 'console split Chinese UTF-8'
printf 'PASS: error cleanup acknowledgement reuse, released status wait, genuine 409 and stale acknowledgement\n'
