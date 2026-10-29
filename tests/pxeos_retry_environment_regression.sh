#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$root/tests/task-http-test-support.sh"
. "$root/tests/storage-test-support.sh"
ismajordebug=0
. "$lib/funcs.sh"
rootpxe_storage_capabilities() { :; }
taskid=41 task_token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa mac=aabbccddeeff
taskType=capture progress_attempt=2 pxeapi=http://fixture/
old_document=$(storage_test_context_json '{"taskId":41,"type":"capture","progressAttempt":2,"protocol":"nfs","storageip":"fixture","exportPath":"/images"}')
rootpxe_storage_apply_context "$old_document" || fail 'old context fixture invalid'
old_workspace=$rootpxe_storage_workspace
new_document=$(jq -c '.progressAttempt=3 | .storageAccess.execution.executionAttempt=3 | .storageAccess.execution.nonce="55555555555555555555555555555555"' <<<"$old_document")
printf '%s' "$new_document" >"$tmp/new-checkin.json"
export rootpxe_storage_published=yes capture_size_bytes=999 rootpxe_final_capture_path="$old_workspace/image"
rootpxe_storage_released=yes rootpxe_storage_stopped=yes
export PXEOS_STORAGE_LIB="$lib/storage-io.sh" PXEOS_NEW_CHECKIN="$tmp/new-checkin.json" PXEOS_OLD_WORKSPACE="$old_workspace" PXEOS_CHILD_RESULT="$tmp/child-result"
cat >"$tmp/new-attempt.sh" <<'CHILD'
set -euo pipefail
. "$PXEOS_STORAGE_LIB"
rootpxe_storage_capabilities() { :; }
taskid=41 taskType=capture progress_attempt=3
if ! rootpxe_storage_apply_context "$(cat "$PXEOS_NEW_CHECKIN")"; then
    printf 'new checkin refused inherited old execution\n' >&2
    exit 88
fi
[[ $rootpxe_storage_workspace != "$PXEOS_OLD_WORKSPACE" && $rootpxe_storage_nonce == 55555555555555555555555555555555 ]] || exit 89
[[ -z ${rootpxe_storage_published:-} && -z ${capture_size_bytes:-} && -z ${rootpxe_final_capture_path:-} ]] || exit 90
printf 'new-attempt-accepted\n' >"$PXEOS_CHILD_RESULT"
rm -rf -- "$rootpxe_storage_workspace"
CHILD
for name in rootpxe_failure_begin rootpxe_failure_remaining rootpxe_error_response_reason rootpxe_error_wait_for_retry rootpxe_reset_disk_permit_retry_state; do
    eval "$(sed -n "/^$name() {/,/^}/p" "$lib/funcs.sh" | sed -e "s|/tmp/pxeos.failure_action|$tmp/failure_action|g" -e "s|exec /bin/pxeos|exec bash '$tmp/new-attempt.sh'|")"
done
rootpxe_require_task_context() { :; }; rootpxe_bound_callback_message() { printf '%s' "$1"; }
rootpxe_console_message() { :; }; killStatusReporter() { :; }; rootpxe_task_log_release_pin() { :; }
rootpxe_clear_disk_permit() { :; }
clock=100
date() { printf '%s\n' "$clock"; }
sleep() { clock=$((clock + $1)); }
curl() { task_http_test_decode_curl_args "$@"; printf '{"status":"queued"}'; }
for blocked in unreleased unstopped helper-pid; do
    status=0
    (
        case $blocked in
            unreleased) rootpxe_storage_released=no ;;
            unstopped) rootpxe_storage_stopped=no ;;
            helper-pid) rootpxe_storage_pid=12345 ;;
        esac
        rootpxe_error_wait_for_retry failure CODE console_shown '{"accepted":true,"waitSec":60}'
    ) >"$tmp/blocked-console" 2>&1 || status=$?
    [[ $status == 2 && ! -e $tmp/child-result && -r $old_workspace/context.json ]] || fail "unsafe retry crossed exec or skipped failure wait: $blocked"
done
status=0
( rootpxe_error_wait_for_retry failure CODE console_shown '{"accepted":true,"waitSec":60}' ) >"$tmp/console" 2>&1 || status=$?
[[ $status == 0 && $(cat "$tmp/child-result" 2>/dev/null) == new-attempt-accepted ]] || { cat "$tmp/console"; fail "real retry process rejected fresh execution: $status"; }
rm -f "$tmp/child-result"
status=0
( unset rootpxe_storage_workspace; rootpxe_error_wait_for_retry failure CODE console_shown '{"accepted":true,"waitSec":60}' ) >"$tmp/early-console" 2>&1 || status=$?
[[ $status == 0 && -e $tmp/child-result ]] || fail 'error before storage context cannot retry'
printf 'PASS: released capture retry clears old execution and publication environment before real child checkin\n'
