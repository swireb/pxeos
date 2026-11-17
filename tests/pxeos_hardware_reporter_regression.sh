#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
reporter="$overlay/bin/pxeos-hardware-reporter"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/lib" "$tmp/state" "$tmp/bin" "$tmp/probe"
printf 'pxeapi=http://fixture/\n' >"$tmp/cmdline"
printf '11111111-1111-1111-1111-111111111111\n' >"$tmp/boot"
printf '3\n%s\naa:bb:cc:dd:ee:ff\n\n' "$(printf 'a%.0s' {1..64})" >"$tmp/context"
printf '%s\n' '{"version":1,"devices":[{"kind":"disk","model":"old"},{"kind":"cpu","model":"CPU"}]}' >"$tmp/snapshot"
cat >"$tmp/lib/task-http.sh" <<'MOCK'
rootpxe_task_curl() {
    local arg seq='' body='' count=0
    for arg in "$@"; do case $arg in sequence=*) seq=${arg#*=};; hardwareInventory=*) body=${arg#*=};; esac; done
    [[ ! -f $FIXTURE/calls ]] || count=$(cat "$FIXTURE/calls")
    count=$((count+1)); printf '%s' "$count" >"$FIXTURE/calls"
    printf '%s %s\n' "$seq" "$body" >>"$FIXTURE/requests"
    if [[ ${REPORTER_MODE:-} == lost ]]; then printf '{"error":"temporary"}\n503'
    elif [[ ${REPORTER_MODE:-} == deny ]]; then printf '{"error":"revoked"}\n403'
    elif [[ ${REPORTER_MODE:-} == retry && $count == 1 ]]; then printf '{"error":"temporary"}\n503'
    else printf '{"success":true}\n200'; fi
}
MOCK
printf ':\n' >"$tmp/lib/disk-health.sh"
cat >"$tmp/lib/hardware-inventory.sh" <<'MOCK'
rootpxe_collect_hardware_inventory() {
    printf 'collect\n' >>"$FIXTURE/collections"
    [[ ${REPORTER_MODE:-} != failed ]] || return 1
    if [[ ${REPORTER_MODE:-} == recover ]]; then
        count=$(wc -l <"$FIXTURE/collections")
        case $count in 1) /bin/sleep 2; return 124;; 2) return 0;; 3) printf 'not-json'; return 0;; 4) printf '{"version":1,"devices":[{}]}'; return 0;; esac
    fi
    cat "$FIXTURE/snapshot"
}
MOCK
sed -e "s|lib=/usr/share/pxeos/lib|lib=$tmp/lib|" \
    -e "s|state=/run/pxeos-hardware|state=$tmp/state|" \
    -e "s|probe_state=/run/pxeos-storage|probe_state=$tmp/probe|" \
    -e "s|wait_log_after=30|wait_log_after=0|" \
    -e "s|timeout -k 1 20 bash|timeout -k 1 0.2 bash|" \
    -e "s|/tmp/pxeos.hardware-inventory.log|$tmp/wait.log|" \
    -e "s|/proc/cmdline|$tmp/cmdline|" \
    -e "s|/proc/sys/kernel/random/boot_id|$tmp/boot|" \
    -e "s|/usr/share/pxeos/lib/|$tmp/lib/|g" "$reporter" >"$tmp/reporter"
cat >"$tmp/bin/sleep" <<'MOCK'
#!/bin/bash
count=0; [[ ! -f $FIXTURE/cycles ]] || count=$(cat "$FIXTURE/cycles")
count=$((count+1)); printf '%s' "$count" >"$FIXTURE/cycles"
if [[ ${REPORTER_MODE:-} == recover && ( -e $FIXTURE/state/sampled || -e $FIXTURE/calls ) ]]; then : >"$FIXTURE/early"; fi
if [[ ${REPORTER_MODE:-} == late ]]; then cp "$FIXTURE/context" "$FIXTURE/state/context"; fi
if [[ ${REPORTER_MODE:-} != recover && ${REPORTER_MODE:-} != probe_late && ${REPORTER_MODE:-} != probe_pending ]]; then
    printf '%s\n' '{"version":1,"devices":[{"kind":"cpu","model":"changed"}]}' >"$FIXTURE/snapshot"
fi
if [[ ${REPORTER_MODE:-} == probe_late || ${REPORTER_MODE:-} == probe_pending ]]; then /bin/sleep 0.03; exit 0; fi
if (( count > 5 )); then read -r pid <"$FIXTURE/state/pid"; kill -TERM "$pid"; fi
exit 0
MOCK
chmod +x "$tmp/bin/sleep"
export FIXTURE="$tmp" PATH="$tmp/bin:$PATH"
reset_case() { rm -f "$tmp/calls" "$tmp/cycles" "$tmp/collections" "$tmp/requests" "$tmp/state/context" "$tmp/state/sampled" "$tmp/state/finished" "$tmp/probe/result" "$tmp/wait.log" "$tmp/early"; printf 'ready\n' >"$tmp/probe/result"; printf '%s\n' '{"version":1,"devices":[{"kind":"disk","model":"old"},{"kind":"cpu","model":"CPU"}]}' >"$tmp/snapshot"; }
reset_case; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=retry timeout 5 bash "$tmp/reporter" || fail 'reporter did not exit after successful retry'
[[ $(wc -l <"$tmp/collections") == 1 && $(cat "$tmp/calls") == 2 ]] || fail 'retry resampled or failed to stop after acknowledgement'
mapfile -t requests <"$tmp/requests"
[[ ${requests[0]%% *} == 1 && ${requests[0]} == "${requests[1]}" ]] || fail 'retry changed the sequence or snapshot'
REPORTER_MODE=retry timeout 5 bash "$tmp/reporter" || fail 'duplicate start failed'
[[ $(wc -l <"$tmp/collections") == 1 && $(cat "$tmp/calls") == 2 ]] || fail 'duplicate start collected or uploaded again'
reset_case
REPORTER_MODE=late timeout 5 bash "$tmp/reporter" || fail 'late credential did not finish'
[[ $(wc -l <"$tmp/collections") == 1 && $(cat "$tmp/calls") == 1 ]] || fail 'late credential triggered resampling or multiple uploads'
grep -Fq '"model":"old"' "$tmp/requests" || fail 'late credential did not upload original snapshot'
reset_case; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=failed timeout 5 bash "$tmp/reporter" || true
[[ $(wc -l <"$tmp/collections") -gt 1 && ! -e $tmp/calls && ! -e $tmp/state/sampled ]] || fail 'collection failure uploaded or marked complete'
reset_case; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=recover timeout 5 bash "$tmp/reporter" || fail 'transient collection failures did not recover'
[[ $(wc -l <"$tmp/collections") == 5 && $(cat "$tmp/calls") == 1 && ! -e $tmp/early ]] || fail 'collector failure, empty or invalid JSON was not retried'
reset_case; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=lost timeout 5 bash "$tmp/reporter" || true
[[ -s $tmp/state/sampled && ! -e $tmp/state/finished && $(wc -l <"$tmp/collections") == 1 ]] || fail 'unconfirmed snapshot was not retained'
REPORTER_MODE=resume timeout 5 bash "$tmp/reporter" || fail 'reporter restart did not resume saved snapshot'
[[ $(wc -l <"$tmp/collections") == 1 ]] || fail 'reporter restart collected a second snapshot'
[[ $(head -n 1 "$tmp/requests") == "$(tail -n 1 "$tmp/requests")" ]] || fail 'reporter restart did not reuse the same request'
reset_case; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=deny timeout 5 bash "$tmp/reporter" || fail 'revoked credential did not stop cleanly'
[[ $(wc -l <"$tmp/collections") == 1 && $(cat "$tmp/calls") == 1 ]] || fail 'revoked credential retried'

# Real S45 then S55 scripts are copied with only private paths substituted.
# S55 resolves a fixture executable that never calls modprobe or touches devices.
reset_case; rm -f "$tmp/probe/result"; cp "$tmp/context" "$tmp/state/context"
cat >"$tmp/bin/pxeos-storage-probe" <<'MOCK'
#!/bin/bash
[[ ${1:-} == start ]] || exit 9
printf 'start\n' >"$FIXTURE/probe-started"
( /bin/sleep 0.25; printf '%s\n' '{"version":1,"devices":[{"kind":"disk","model":"late disk"}]}' >"$FIXTURE/snapshot"; printf 'ready\n' >"$FIXTURE/probe/result" ) </dev/null >/dev/null 2>&1 &
MOCK
chmod +x "$tmp/bin/pxeos-storage-probe"
sed -e "s|state=/run/pxeos-hardware|state=$tmp/state|" -e "s|/proc/cmdline|$tmp/cmdline|" -e "s|/bin/pxeos-hardware-reporter|$tmp/reporter|" "$overlay/etc/init.d/S45hardware-inventory" >"$tmp/S45"
cp "$overlay/etc/init.d/S55storage" "$tmp/S55"
chmod +x "$tmp/reporter"
REPORTER_MODE=probe_late bash "$tmp/S45" start
/bin/sleep 0.15
[[ ! -e $tmp/collections && ! -e $tmp/calls ]] || fail 'S45 sampled before S55 probe completed'
[[ -s $tmp/wait.log ]] || fail 'pending probe did not produce a timeout warning'
timeout 2 bash "$tmp/S55" start || fail 'S55 fixture blocked startup'
for _ in {1..100}; do [[ -e $tmp/requests ]] && break; /bin/sleep 0.03; done
[[ -f $tmp/probe-started && -f $tmp/requests ]] || fail 'probe completion did not lead to reporting'
grep -Fq '"model":"late disk"' "$tmp/requests" || fail 'late disk missing from snapshot'

# An absent result, including beyond a bounded observer wait, must not report.
reset_case; rm -f "$tmp/probe/result"; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=probe_pending bash "$tmp/reporter" & pending_pid=$!
/bin/sleep 0.25
[[ ! -e $tmp/collections && ! -e $tmp/calls && ! -e $tmp/state/sampled ]] || fail 'pending probe produced authoritative snapshot'
REPORTER_MODE=probe_pending timeout 2 bash "$tmp/reporter" || fail 'duplicate reporter start failed'
[[ ! -e $tmp/collections && ! -e $tmp/calls ]] || fail 'concurrent reporter sampled during pending probe'
printf '%s\n' '{"version":1,"devices":[{"kind":"disk","model":"late disk after warning"}]}' >"$tmp/snapshot"
printf 'ready\n' >"$tmp/probe/result"
wait "$pending_pid" || fail 'reporter did not finish after pending probe completed'
grep -Fq '"model":"late disk after warning"' "$tmp/requests" || fail 'disk appearing after pending warning was not reported'

# Atomic terminal failure remains a terminal result, not a pending probe.
reset_case; printf 'probe failed\n' >"$tmp/probe/result"; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=terminal timeout 5 bash "$tmp/reporter" || fail 'terminal probe failure blocked other hardware'
[[ $(wc -l <"$tmp/collections") == 1 && $(cat "$tmp/calls") == 1 ]] || fail 'terminal failure did not report once'

# Valid empty inventory is still reported, not mistaken for collector failure.
reset_case; printf '%s\n' '{"version":1,"devices":[]}' >"$tmp/snapshot"; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=empty timeout 5 bash "$tmp/reporter" || fail 'valid empty inventory did not report'
grep -Fq '"devices":[]' "$tmp/requests" || fail 'empty inventory was not uploaded'

# A completed reporter must not cause the task callback to collect again.
sed "s|/run/pxeos-hardware|$tmp/state|g" "$overlay/usr/share/pxeos/lib/hardware-inventory.sh" >"$tmp/task-library"
. "$tmp/task-library"
rootpxe_require_task_context() { :; }
rootpxe_collect_hardware_inventory() { printf 'task-collect\n' >>"$tmp/task-calls"; printf '{}'; }
rootpxe_task_curl() { printf 'task-upload\n' >>"$tmp/task-calls"; }
rootpxe_console_message() { :; }
taskType=deploy taskid=7 task_token=fixture mac=fixture rootpxe_api=http://fixture/
rootpxe_send_hardware_inventory
[[ ! -e $tmp/task-calls ]] || fail 'completed boot reporter fell back to task collection'
rm -f "$tmp/state/context"
rootpxe_send_hardware_inventory
[[ $(cat "$tmp/task-calls") == $'task-collect\ntask-upload' ]] || fail 'legacy task reporting unavailable'

# The init fixture launches only a private blocking shim, never real startup.
cat >"$tmp/blocking-reporter" <<'MOCK'
#!/bin/bash
printf '%s\n' "$$" >"$FIXTURE/startup-pid"
exec /bin/sleep 10
MOCK
chmod +x "$tmp/blocking-reporter"
init="$overlay/etc/init.d/S45hardware-inventory"
sed -e "s|state=/run/pxeos-hardware|state=$tmp/startup-state|" -e "s|/proc/cmdline|$tmp/cmdline|" -e "s|/bin/pxeos-hardware-reporter|$tmp/blocking-reporter|" "$init" >"$tmp/init"
timeout 2 bash "$tmp/init" start || fail 'startup waited for reporter'
for _ in {1..100}; do [[ -f $tmp/startup-pid ]] && break; /bin/sleep 0.01; done
[[ -f $tmp/startup-pid ]] || fail 'startup did not launch reporter'
read -r startup_pid <"$tmp/startup-pid"
kill "$startup_pid" 2>/dev/null || true
printf 'PASS: single startup sample, retry, late credential, failure and legacy reporting\n'
