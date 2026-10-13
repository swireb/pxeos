#!/usr/bin/env bash
# Synthetic lifecycle checks only; real Linux inode reuse is not exercised.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-log-pin-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$lib/funcs.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rootpxe_task_log_initialize
pin=${rootpxe_task_log_state[pin]:-}
[[ $pin =~ ^[1-9][0-9]+$ ]] || fail missing-attempt-pin
old_identity=${rootpxe_task_log_state[pin_identity]}
rootpxe_log_pin_valid "$pin" "$old_identity" || fail invalid-initial-pin
if { printf 'must-not-write' >&"$pin"; } 2>"$tmp/readonly-error"; then fail pin-not-readonly; fi
mkfifo "$tmp/ready" "$tmp/release"
(
    printf 'ready\n' >"$tmp/ready"
    read -r release <"$tmp/release"
    rootpxe_log_pin_valid "$pin" "$old_identity" || exit 90
    rootpxe_task_log_append STALE_CHILD && exit 91
    printf 'OLD_PIN_HELD\n' >"$tmp/child-result"
) & child=$!
read -r ready <"$tmp/ready"
rootpxe_task_log_initialize
rootpxe_log_pin_valid "$pin" "$old_identity" && fail parent-kept-old-pin
printf 'release\n' >"$tmp/release"
wait "$child"
grep -q OLD_PIN_HELD "$tmp/child-result" || fail child-pin-not-inherited
! grep -q STALE_CHILD "$tmp/log/pxeos-task.log" || fail old-child-wrote-new
pin=${rootpxe_task_log_state[pin]}
exec {pin}<&-
rootpxe_task_log_valid && fail closed-pin-is-ready
native_called=no
native(){ native_called=yes; printf 'diagnosis\n'; return 7; }
rc=0; rootpxe_run_logged_typed_native linux-mount.log /dev/mock native >"$tmp/out" 2>"$tmp/err" || rc=$?
[[ $native_called == yes && $rc == 7 && ! -s $tmp/out ]] || fail invalid-pin-changed-native
grep -q unavailable "$tmp/err" || fail invalid-pin-reference
rootpxe_task_log_initialize
exec {foreign}<"$tmp/child-result"
rootpxe_task_log_state[pin]=$foreign
rootpxe_task_log_release_pin && fail released-unowned-object
[[ -r /proc/self/fd/$foreign ]] || fail closed-unowned-fd
exec {foreign}<&-
unset rootpxe_task_log_state
rootpxe_task_log_initialize
rootpxe_task_log_release_pin
rootpxe_task_log_valid && fail released-pin-still-ready
reset_line=$(grep -nF 'rootpxe_reset_disk_permit_retry_state || return 1' "$lib/funcs.sh" | cut -d: -f1)
release_line=$(grep -nF 'rootpxe_task_log_release_pin || true' "$lib/funcs.sh" | cut -d: -f1)
exec_line=$(grep -nF 'exec /bin/pxeos' "$lib/funcs.sh" | cut -d: -f1)
[[ $reset_line -lt $release_line && $release_line -lt $exec_line ]] || fail retry-release-order
# Run the complete current queued branch. Only the terminal exec boundary is
# replaced, so the real pin release and original permit-reset ordering run.
eval "$(sed -n '/^rootpxe_error_wait_for_retry() {/,/^}/p' "$lib/funcs.sh" | sed -e "s|/tmp/pxeos.failure_action|$tmp/failure_action|g" -e 's|exec /bin/pxeos|rootpxe_pin_test_exec /bin/pxeos|')"
for release_failure in no yes; do
    (
        rootpxe_task_log_initialize
        owned_pin=${rootpxe_task_log_state[pin]}; owned_identity=${rootpxe_task_log_state[pin_identity]}
        exec {foreign}<"$tmp/child-result"
        pxeapi=https://example.invalid/; web=$pxeapi; taskid=1; task_token=FAKE_PIN_TOKEN; mac=00:00:00:00:00:00; mc=no
        rootpxe_require_task_context(){ return 0; }
        rootpxe_console_message(){ :; }
        rootpxe_reset_disk_permit_retry_state(){ printf RESET >"$tmp/retry-order"; }
        curl(){ case "${*: -1}" in *task-status) printf '%s' '{"status":"queued"}' ;; *error) printf '%s\n200' '{"accepted":true,"waitSec":60}' ;; *) return 90 ;; esac; }
        if [[ $release_failure == yes ]]; then rootpxe_task_log_release_pin(){ return 1; }; fi
        rootpxe_pin_test_exec(){
            [[ $* == /bin/pxeos && $(cat "$tmp/retry-order") == RESET && -r /proc/self/fd/$foreign ]] || exit 94
            if [[ $release_failure == no ]]; then rootpxe_log_pin_valid "$owned_pin" "$owned_identity" && exit 95; fi
            printf 'QUEUED_EXEC:%s\n' "$release_failure" >>"$tmp/retry-exec"
            exit 0
        }
        rootpxe_error_wait_for_retry DIAGNOSTIC FAKE_CODE console_shown
        exit 96
    )
done
[[ $(wc -l <"$tmp/retry-exec") == 2 ]] || fail queued-release-blocked-retry
printf 'Log pin: PASS\n'
