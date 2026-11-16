#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$root/tests/task-http-test-support.sh"
for fn in rootpxe_error_report; do eval "$(sed -n "/^$fn() {/,/^}/p" "$lib/funcs.sh")"; done
rootpxe_require_task_context() { :; }
rootpxe_failure_begin() { :; }
rootpxe_failure_remaining() { printf '60\n'; }
rootpxe_bound_callback_message() { printf '%s' "$1"; }
rootpxe_send_hardware_inventory() { printf 'inventory:%s\n' "$taskType" >>"$tmp/events"; return "${collector_status:-0}"; }
taskid=41 task_token=fixture mac=aabbccddeeff pxeapi=http://fixture/ web=''
curl() { task_http_test_decode_curl_args "$@"; printf 'error\n' >>"$tmp/events"; printf '{"accepted":true}\n200'; }
taskType=deploy collector_status=1
rootpxe_error_report original FAILURE || fail 'collector failure prevented the error'
rootpxe_error_report original FAILURE || fail 'second error report failed'
[[ $(cat "$tmp/events") == $'inventory:deploy\nerror\nerror' ]] || fail 'fresh inventory not sent once before retries'
unset rootpxe_failure_inventory_sent
taskType=capture collector_status=0
rootpxe_error_report original FAILURE || fail 'new attempt failed'
[[ $(tail -n 2 "$tmp/events") == $'inventory:capture\nerror' ]] || fail 'new attempt did not collect again'
printf 'PASS: failure inventory before error and once per attempt\n'
