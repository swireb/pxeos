#!/usr/bin/env bash
# Run only temporary process fixtures. Do not source the PXEOS launcher.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
lib="$repo/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
cc -std=c99 -Wall -Wextra -Werror -o "$temp/supervisor" "$repo/Buildroot/package/pxeos/src/pxeos-deploy-worker.c"
if [[ ! -r /proc/$$/task/$$/children ]]; then
    echo 'This native test requires CONFIG_PROC_CHILDREN.'
    exit 1
fi

# An old private marker must fence execution before starting a worker.
touch "$temp/stop"
rc=0
"$temp/supervisor" "$temp/stop" touch "$temp/wrongly-ran" || rc=$?
[[ $rc -eq 75 && ! -e $temp/wrongly-ran ]]
rm -f "$temp/stop"
"$temp/supervisor" "$temp/stop" true

# A worker and its child (new session, ignored TERM) belong to the same
# subreaper. The unrelated sleep belongs to the test shell.
sleep 20 & unrelated=$!
trap 'kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true; rm -rf -- "$temp"' EXIT
cat >"$temp/worker" <<'WORKER'
#!/bin/bash
dir=$1
setsid bash -c 'trap "" TERM; echo "$$" >"$1/daemon"; exec sleep 20' _ "$dir" &
echo "$$" >"$dir/worker-pid"
while [[ ! -s $dir/daemon ]]; do sleep .02; done
[[ $2 == exit ]] && exit 0
exec sleep 20
WORKER
chmod 700 "$temp/worker"
for mode in stop exit; do
    rm -f "$temp/stop" "$temp/worker-pid" "$temp/daemon"
    timeout 10 "$temp/supervisor" "$temp/stop" "$temp/worker" "$temp" "$mode" &
    test_pid=$!
    for ((i=0; i<100; i++)); do
        [[ ! -s $temp/daemon ]] || break
        sleep .025
    done
    read -r daemon <"$temp/daemon"
    read -r worker <"$temp/worker-pid"
    [[ $mode != stop ]] || : >"$temp/stop"
    rc=0
    wait "$test_pid" || rc=$?
    if [[ $mode == stop ]]; then [[ $rc -eq 75 ]]; else [[ $rc -eq 0 ]]; fi
    ! kill -0 "$worker" 2>/dev/null
    ! kill -0 "$daemon" 2>/dev/null
    kill -0 "$unrelated"
done

# Control-plane transport failures and malformed replies never create a stop
# marker. Use a dummy transport and never reach a machine/network endpoint.
. "$lib/deploy-control.sh"
rootpxe_deploy_control_dir="$temp/control"
mkdir -m 700 "$rootpxe_deploy_control_dir"
execution_token=fixture
progress_attempt=2
rootpxe_storage_boot_id=11111111-1111-1111-1111-111111111111
rootpxe_storage_sysuuid=
web=https://invalid.invalid/
taskid=1
mac=001122334455
rootpxe_publish_deploy_control
[[ $(stat -c %a "$rootpxe_deploy_control_dir/context") == 600 ]]
rootpxe_task_curl() { return 1; }
! rootpxe_deploy_control_request poll
[[ ! -e $rootpxe_deploy_control_dir/stop ]]
rootpxe_task_curl() { printf '%s\n200\n' '{"status":"completed"}'; }
! rootpxe_deploy_control_request poll
[[ ! -e $rootpxe_deploy_control_dir/stop ]]
for code in 403 404; do
    rootpxe_task_curl() { printf '{"status":"deleted"}\n%d\n' "$code"; }
    ! rootpxe_deploy_control_request poll
    [[ ! -e $rootpxe_deploy_control_dir/stop ]]
done
rootpxe_task_curl() { printf '%s\n200\n' '{"status":"aborting"}'; }
rootpxe_deploy_control_request poll
[[ -e $rootpxe_deploy_control_dir/stop ]]
rootpxe_task_curl() { printf '%s\n200\n' '{"status":"cancelled"}'; }
rootpxe_deploy_control_request stopped

# Prove the real controller does not acknowledge until its supervisor has
# reaped the worker, including the final poll after natural completion.
mv "$temp/supervisor" "$temp/pxeos-deploy-worker"
export PATH="$temp:$PATH"
export control_lib="$lib/deploy-control.sh" test_dir="$temp"
cat >"$temp/control-worker" <<'WORKER'
#!/bin/bash
. "$control_lib"
execution_token=fixture progress_attempt=2 rootpxe_storage_boot_id=boot rootpxe_storage_sysuuid=
rootpxe_publish_deploy_control || exit 1
echo "$$" >"$test_dir/control-worker-pid"
[[ $(cat "$test_dir/mode") == direct ]] && exit 0
exec sleep 20
WORKER
chmod 700 "$temp/control-worker"
unset rootpxe_deploy_control_dir
rootpxe_task_curl() {
    local pid commit=0
    [[ -s $temp/control-worker-pid ]] || return 1
    read -r pid <"$temp/control-worker-pid"
    for arg; do [[ $arg != abortStopped=true ]] || commit=1; done
    if [[ $(cat "$temp/mode") == revoked ]]; then
        if ((commit)); then touch "$temp/acked-revoked"; fi
        printf '%s\n200\n' '{"status":"superseded"}'
        return
    fi
    if ((commit)); then
        if kill -0 "$pid" 2>/dev/null; then
            touch "$temp/acked-too-early"
            return 1
        fi
        touch "$temp/acked"
        printf '%s\n200\n' '{"status":"cancelled"}'
    else
        printf '%s\n200\n' '{"status":"aborting"}'
    fi
}
for mode in signal direct revoked; do
    rm -f "$temp/control-worker-pid" "$temp/acked"
    printf '%s\n' "$mode" >"$temp/mode"
    rc=0
    rootpxe_run_deployment "$temp/control-worker" "$temp" || rc=$?
    [[ $rc -eq 75 && ! -e $temp/acked-too-early && ! -e $temp/pxeos.deploy-control ]]
    if [[ $mode == revoked ]]; then
        [[ ! -e $temp/acked && ! -e $temp/acked-revoked ]]
    else
        [[ -e $temp/acked ]]
    fi
done
# Check the launcher guard as an isolated shell branch, with no launcher start.
guard=$(sed -n '/^if \[\[ \$rc -eq 75 || /,/^fi$/p' "$repo/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/etc/init.d/S99pxeos")
rc=0
(
    rc=75 type=
    pxeos_init_message() { :; }
    eval "$guard"
    exit 99
) || rc=$?
[[ $rc -eq 75 ]]

# Exercise the bounded 409 retry and the stop-only response, using only the
# source function definitions with all external actions replaced.
checkin="$repo/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
sed -n '/^checkin_rootpxe() {/,/^}/p' "$checkin" | sed "s|/tmp/rootpxe-checkin-request|$temp/request|g; s|/tmp/pxeos.failure_action|$temp/failure_action|g" >"$temp/checkin-function"
rootpxe_cloud_init_cleanup_private() { :; }
rootpxe_cleanup_session() { :; }
rootpxe_console_message() { :; }
rootpxe_require_identity() { :; }
dmidecode() { :; }
rootpxe_write_checkin_json_payload() { : >"$1"; }
rootpxe_json_assign_text() { local field; field=$(jq -r "$3" <<<"$1"); printf -v "$2" '%s' "$field"; }
rootpxe_json_assign() { rootpxe_json_assign_text "$@"; }
rootpxe_source_core_library() { :; }
rootpxe_apply_json_checkin() { touch "$temp/used-normal-checkin"; return 1; }
rootpxe_task_curl() {
    if [[ ! -e $temp/checkin-first ]]; then
        touch "$temp/checkin-first"
        printf '{}\n409\n'
    else
        printf '{"status":"aborting","executionToken":"%064d","progressAttempt":2}\n200\n' 0
    fi
}
(
    . "$temp/checkin-function"
    rootpxe_deploy_control_dir="$temp/checkin-control"
    mkdir -m 700 "$rootpxe_deploy_control_dir"
    rootpxe_api=https://invalid.invalid/
    mac=001122334455
    rootpxe_storage_boot_id=11111111-1111-1111-1111-111111111111
    rc=0
    checkin_rootpxe || rc=$?
    [[ $rc -eq 2 && -f $rootpxe_deploy_control_dir/context && -f $rootpxe_deploy_control_dir/stop && ! -e $temp/used-normal-checkin ]]
)
