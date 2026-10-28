#!/usr/bin/env bash
# Real task-log append and HTTP wrapper; local files/curl substitute only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-storage-diagnostic.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$lib/funcs.sh"
. "$root/tests/task-http-test-support.sh"
. "${ROOTPXE_STORAGE_DIAGNOSTIC_LIBRARY:-$lib/storage-io.sh}"
rootpxe_task_log_initialize
log=$(rootpxe_task_log_path)
taskid=41 task_token=diagnostic-private-token mac=aabbccddeeff progress_attempt=2
rootpxe_storage_nonce=diagnostic-private-nonce rootpxe_storage_worker_nonce=diagnostic-private-worker
pxeapi=http://fixture/ web=''
TASK_HTTP_TEST_STATUS=200
MOCK_RESPONSE='{"success":true,"sequence":"0"}'
MOCK_EXIT=0
curl() {
    local write_out=no argument
    task_http_test_decode_curl_args "$@"
    for argument in "$@"; do
        [[ $argument != --write-out && $argument != -w ]] || write_out=yes
    done
    printf '%s' "$MOCK_RESPONSE"
    [[ $write_out != yes ]] || printf '\n%s' "$TASK_HTTP_TEST_STATUS"
    return "$MOCK_EXIT"
}
output=$(rootpxe_storage_call preflight 2>"$tmp/console") || fail 'valid success rejected'
[[ $output == "$MOCK_RESPONSE" && ! -s $tmp/console && ! -s $log ]] || fail 'success polluted stdout or wrote rejection'

TASK_HTTP_TEST_STATUS=409
MOCK_RESPONSE='{"success":false,"error":"远端文件或目录已改变","reasonCode":"STORAGE_CHECKPOINT_RESULT_FILE_ID_MISMATCH","token":"response-private-token","owner":"response-private-owner","SQL":"SELECT private_sql"}'
event='{"event":"result","operation":"mkdir-owned","sequence":"9","path":"private-path","execution":{"nonce":"event-private-nonce"}}'
status=0
output=$(rootpxe_storage_call publish-checkpoint --data-urlencode "event=$event" 2>"$tmp/console") || status=$?
[[ $status == 1 && -z $output ]] || fail '409 accepted or emitted response on stdout'
grep -Fq 'HTTP 409' "$log" || fail 'command substitution lost HTTP status task log'
grep -Fq 'reasonCode=STORAGE_CHECKPOINT_RESULT_FILE_ID_MISMATCH' "$log" || fail 'controlled reason code missing'
grep -Fq 'error=远端文件或目录已改变' "$log" || fail 'controlled Chinese error missing'
grep -Fq 'sequence=9 phase=result operation=mkdir-owned' "$log" || fail 'actual checkpoint context missing'
[[ $(cat "$tmp/console") == 'Storage request failed (HTTP 409). Check task log.' ]] || fail 'console exposed detailed or non-English diagnostic'

# Callers frequently discard stdout. Failure details must still reach the
# existing task log and stderr without changing the nonzero return.
MOCK_RESPONSE='{"error":"存储执行绑定已失效"}'
status=0
rootpxe_storage_call release >/dev/null 2>"$tmp/discard-console" || status=$?
[[ $status == 1 ]] || fail 'legacy rejection changed return'
grep -Fq 'endpoint=release HTTP 409 reasonCode=STORAGE_REJECTED error=存储执行绑定已失效' "$log" || fail 'legacy server reason missing from task log'
grep -Fq 'HTTP 409' "$tmp/discard-console" || fail 'discarded stdout suppressed console diagnostic'

for MOCK_RESPONSE in \
    '<html>html-private-token</html>' \
    '{"error":"json-private-token","reasonCode":"STORAGE_PRIVATE_SECRET","password":"response-private-password"}' \
    '{"error":"malformed-private-token"' \
    '{"success":true}' \
    '{"success":true}{"success":true}'; do
    status=0
    output=$(rootpxe_storage_call preflight 2>>"$tmp/unsafe-console") || status=$?
    [[ $status == 1 && -z $output ]] || fail 'unsafe/error response accepted'
done
TASK_HTTP_TEST_STATUS=200
MOCK_RESPONSE='{"success":true}{"success":true}'
status=0
output=$(rootpxe_storage_call preflight 2>>"$tmp/unsafe-console") || status=$?
[[ $status == 1 && -z $output ]] || fail 'multiple successful JSON documents accepted'

TASK_HTTP_TEST_STATUS=409
MOCK_RESPONSE='{"error":"unknown-private-error","reasonCode":"STORAGE_REJECTED\u001b"}'
event='{"event":"result\nprivate-phase","operation":"private-operation","sequence":"9\nprivate-sequence","path":"private-path"}'
status=0
rootpxe_storage_call publish-checkpoint --data-urlencode "event=$event" >/dev/null 2>>"$tmp/unsafe-console" || status=$?
[[ $status == 1 ]] || fail 'unsafe checkpoint diagnostic changed failure'
! grep -Eq 'response-private|event-private|diagnostic-private|private_sql|private-path|html-private|json-private|malformed-private|PRIVATE_SECRET|unknown-private|private-phase|private-operation|private-sequence' "$log" "$tmp/console" "$tmp/discard-console" "$tmp/unsafe-console" || fail 'uncontrolled diagnostic leaked'
! LC_ALL=C grep -q $'\033' "$log" "$tmp/unsafe-console" || fail 'control character leaked'

TASK_LOG_TEST_LOCK_BUSY=yes
status=0
rootpxe_storage_call release >/dev/null 2>"$tmp/busy-console" || status=$?
[[ $status == 1 ]] || fail 'task-log failure replaced original request failure'
printf 'PASS: controlled storage rejection reaches real task log without stdout or secret leakage\n'
