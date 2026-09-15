#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
multicast="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
imgcomplete="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.imgcomplete"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

awk '/^rootpxe_request_disk_permit_for_target\(\)/ { copy = 1 } /^rootpxe_record_disk_permit_binding\(\)/ { exit } copy' "$funcs" >"$tmp/permit.sh"
awk '/^rootpxe_error_response_reason\(\)/ { copy = 1 } /^rootpxe_directory_size_bytes\(\)/ { exit } copy' "$funcs" >"$tmp/error.sh"
. "$tmp/permit.sh"
. "$tmp/error.sh"
. "$multicast"
taskid=71
task_token=session-test-token
mac=aa:bb:cc:dd:ee:ff
pxeapi=http://controller/
web=$pxeapi
mc=yes
multicastSessionId=manual-session-callback
progress_attempt=4
rootpxe_require_task_context() { :; }
rootpxe_clear_disk_permit() { :; }
rootpxe_set_disk_permit_protocol_error() { return 1; }
rootpxe_set_disk_permit_reason() { return 1; }
rootpxe_task_status_confirms_disk_permit_cancellation() { return 1; }

permit_args="$tmp/permit.args"
curl() {
    printf '%s\n' "$@" >"$permit_args"
    case " $* " in
        *' targets='*) printf '{"granted":true,"targets":[{"targetId":"disk-id","operation":"deploy_write"}]}\n200' ;;
        *) printf '{"granted":true,"targetId":"disk-id","operation":"deploy_write"}\n200' ;;
    esac
}
rootpxe_request_disk_permit_for_target disk-id deploy_write
grep -Fqx 'sessionId=manual-session-callback' "$permit_args"
grep -Fqx 'progressAttempt=4' "$permit_args"
rootpxe_request_disk_permit_batch disk-id deploy_write
grep -Fqx 'sessionId=manual-session-callback' "$permit_args"
grep -Fqx 'progressAttempt=4' "$permit_args"

error_log="$tmp/error.args"
rootpxe_bound_callback_message() { printf '%s\n' "$1"; }
rootpxe_console_message() { :; }
curl() {
    printf '%s\n' "$@" >>"$error_log"
    case " $* " in
        *'/error'*) printf '{"accepted":true,"waitSec":60,"failureAction":"reboot"}\n200' ;;
        *'/task-status'*) printf '{"status":"cancelled"}' ;;
        *) return 1 ;;
    esac
}
set +e
rootpxe_error_wait_for_retry 'local multicast receiver failed' PXEOS_ERROR
error_rc=$?
set -e
[[ $error_rc == 2 ]]
grep -Fqx 'sessionId=manual-session-callback' "$error_log"
grep -Fqx 'progressAttempt=4' "$error_log"

finish_log="$tmp/finish.args"
dmidecode() { printf '11111111-2222-3333-4444-555555555555\n'; }
curl() {
    printf '%s\n' "$@" >"$finish_log"
    printf '{"success":true}\n'
}
rootpxe_deployment_identity_policy_enabled() { return 1; }
rootpxe_stage() { :; }
rootpxe_clear_capture_marker() { :; }
rootpxe_cleanup_task_json() { :; }
rootpxe_capture_resume_cleanup() { :; }
dots() { :; }
debugPause() { :; }
type=down
rootpxe_api=$pxeapi
. "$imgcomplete"
grep -Fqx -- 'sessionId=manual-session-callback' "$finish_log"
grep -Fqx -- 'progressAttempt=4' "$finish_log"

mc=no
multicastSessionId=''
curl() {
    printf '%s\n' "$@" >"$permit_args"
    printf '{"granted":true,"targetId":"disk-id","operation":"deploy_write"}\n200'
}
rootpxe_request_disk_permit_for_target disk-id deploy_write
! grep -Fq 'sessionId=' "$permit_args"
echo 'PASS: multicast callback session regression'
