#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
. "$lib"
TEST_JQ=${TEST_JQ:-jq}
TEST_JQ=$(command -v "$TEST_JQ") || { echo 'FAIL: TEST_JQ unavailable' >&2; exit 1; }
jq(){ command "$TEST_JQ" "$@"; }
taskid=1
task_token=token
mac=00:11:22:33:44:55
progress_attempt=1
rootpxe_api=http://mock/
rootpxe_multicast_group_id=0123456789abcdef0123456789abcdef-0123456789abcdef0123456789abcdef
rootpxe_multicast_sequence=1
rootpxe_multicast_context_file="$tmp/context"
printf '{}' >"$rootpxe_multicast_context_file"
rootpxe_multicast_runtime_active=yes
rootpxe_multicast_monitor_dir=$(mktemp -d /tmp/rootpxe-multicast-monitor.XXXXXX)
chmod 700 "$rootpxe_multicast_monitor_dir"
mkfifo "$tmp/source"
( while :; do sleep 1; done ) >"$tmp/source" &
rootpxe_multicast_receiver_pid=$!
curl() {
  echo "$BASHPID" >"$rootpxe_multicast_monitor_dir/mock-curl.pid"
  while :; do sleep 1; done
}
rootpxe_multicast_status_monitor "$rootpxe_multicast_receiver_pid" &
rootpxe_multicast_monitor_pid=$!
for ((i=0; i<50; i++)); do [[ -s "$rootpxe_multicast_monitor_dir/curl.pid" && -s "$rootpxe_multicast_monitor_dir/mock-curl.pid" ]] && break; sleep 0.1; done
[[ -s "$rootpxe_multicast_monitor_dir/curl.pid" && -s "$rootpxe_multicast_monitor_dir/mock-curl.pid" ]] || { echo FAIL:curl_not_started; exit 1; }
read -r curl_pid <"$rootpxe_multicast_monitor_dir/curl.pid"
read -r mock_pid <"$rootpxe_multicast_monitor_dir/mock-curl.pid"
monitor_dir=$rootpxe_multicast_monitor_dir
monitor_pid=$rootpxe_multicast_monitor_pid
rootpxe_multicast_stop_runtime
! kill -0 "$curl_pid" >/dev/null 2>&1 || { echo FAIL:curl_alive; exit 1; }
! kill -0 "$mock_pid" >/dev/null 2>&1 || { echo FAIL:mock_curl_alive; exit 1; }
! kill -0 "$monitor_pid" >/dev/null 2>&1 || { echo FAIL:monitor_alive; exit 1; }
[[ ! -e $monitor_dir ]] || { echo FAIL:monitor_directory_remains; exit 1; }
echo 'PASS: multicast monitor HTTP cancellation regression'
