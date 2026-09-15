#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
. "$lib"
multicastSessionId=manual-session-test
parent_response="$tmp/foreground-response"
printf '{}' >"$parent_response"
rootpxe_multicast_response_file=$parent_response
rootpxe_multicast_monitor_dir=$(mktemp -d /tmp/rootpxe-multicast-monitor.XXXXXX)
chmod 700 "$rootpxe_multicast_monitor_dir"
rootpxe_multicast_monitor_failure_file="$rootpxe_multicast_monitor_dir/failure"
monitor_dir=$rootpxe_multicast_monitor_dir
rootpxe_multicast_status() { return 1; }
( while :; do sleep 1; done ) &
rootpxe_multicast_receiver_pid=$!
receiver_pid=$rootpxe_multicast_receiver_pid
rootpxe_multicast_watchdog &
rootpxe_multicast_monitor_pid=$!
monitor_pid=$rootpxe_multicast_monitor_pid
for ((i=0; i<50; i++)); do [[ -s $rootpxe_multicast_monitor_failure_file ]] && break; sleep 0.1; done
[[ -s $rootpxe_multicast_monitor_failure_file ]] || { echo FAIL:watchdog_did_not_record_failure; exit 1; }
[[ -r $parent_response ]] || { echo FAIL:watchdog_removed_foreground_response; exit 1; }
rootpxe_multicast_stop_runtime
! kill -0 "$receiver_pid" >/dev/null 2>&1 || { echo FAIL:receiver_alive; exit 1; }
! kill -0 "$monitor_pid" >/dev/null 2>&1 || { echo FAIL:monitor_alive; exit 1; }
[[ ! -e $monitor_dir ]] || { echo FAIL:monitor_directory_remains; exit 1; }
rootpxe_multicast_monitor_failure_file="$tmp/daemon-failure"
rootpxe_multicast_monitor_pid=999999
if rootpxe_multicast_session_guard; then echo FAIL:dead_watchdog_was_accepted; exit 1; fi
grep -Fxq watchdog_exited "$rootpxe_multicast_monitor_failure_file"
echo 'PASS: multicast watchdog cleanup regression'
