#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
reporter="$overlay/bin/pxeos-hardware-reporter"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/lib" "$tmp/state" "$tmp/bin"
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
    if [[ ${REPORTER_MODE:-} == deny ]]; then printf '{"error":"revoked"}\n403'
    elif [[ ${REPORTER_MODE:-} == retry && $count == 1 ]]; then printf '{"error":"temporary"}\n503'
    else printf '{"success":true}\n200'; fi
}
MOCK
printf ':\n' >"$tmp/lib/disk-health.sh"
cat >"$tmp/lib/hardware-inventory.sh" <<'MOCK'
rootpxe_collect_hardware_inventory() {
    printf 'collect\n' >>"$FIXTURE/collections"
    [[ ${REPORTER_MODE:-} != failed ]] || return 1
    cat "$FIXTURE/snapshot"
}
MOCK
sed -e "s|lib=/usr/share/pxeos/lib|lib=$tmp/lib|" \
    -e "s|state=/run/pxeos-hardware|state=$tmp/state|" \
    -e "s|/proc/cmdline|$tmp/cmdline|" \
    -e "s|/proc/sys/kernel/random/boot_id|$tmp/boot|" \
    -e "s|/usr/share/pxeos/lib/|$tmp/lib/|g" "$reporter" >"$tmp/reporter"
cat >"$tmp/bin/sleep" <<'MOCK'
#!/bin/bash
count=0; [[ ! -f $FIXTURE/cycles ]] || count=$(cat "$FIXTURE/cycles")
count=$((count+1)); printf '%s' "$count" >"$FIXTURE/cycles"
if [[ ${REPORTER_MODE:-} == late ]]; then cp "$FIXTURE/context" "$FIXTURE/state/context"; fi
printf '%s\n' '{"version":1,"devices":[{"kind":"cpu","model":"changed"}]}' >"$FIXTURE/snapshot"
if (( count > 5 )); then read -r pid <"$FIXTURE/state/pid"; kill -TERM "$pid"; fi
exit 0
MOCK
chmod +x "$tmp/bin/sleep"
export FIXTURE="$tmp" PATH="$tmp/bin:$PATH"
reset_case() { rm -f "$tmp/calls" "$tmp/cycles" "$tmp/collections" "$tmp/requests" "$tmp/state/context" "$tmp/state/sampled"; printf '%s\n' '{"version":1,"devices":[{"kind":"disk","model":"old"},{"kind":"cpu","model":"CPU"}]}' >"$tmp/snapshot"; }
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
REPORTER_MODE=failed timeout 5 bash "$tmp/reporter" || fail 'failed collection did not stop cleanly'
[[ $(wc -l <"$tmp/collections") == 1 && ! -e $tmp/calls ]] || fail 'collection failure uploaded or retried'
reset_case; cp "$tmp/context" "$tmp/state/context"
REPORTER_MODE=deny timeout 5 bash "$tmp/reporter" || fail 'revoked credential did not stop cleanly'
[[ $(wc -l <"$tmp/collections") == 1 && $(cat "$tmp/calls") == 1 ]] || fail 'revoked credential retried'

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
