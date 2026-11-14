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

# Control status is accepted only after a successful, authenticated response.
# Mock replies and workers use no real endpoints, disks, or power management.
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
! rootpxe_deploy_control_request
[[ ! -e $rootpxe_deploy_control_dir/stop ]]
for reply in 'deleted 403' 'superseded 404' 'aborting 200' 'completed 200'; do
    read -r reply_state reply_code <<<"$reply"
    rootpxe_task_curl() { printf '{"status":"%s"}\n%s\n' "$reply_state" "$reply_code"; }
    ! rootpxe_deploy_control_request
    [[ ! -e $rootpxe_deploy_control_dir/stop ]]
done

mv "$temp/supervisor" "$temp/pxeos-deploy-worker"
export PATH="$temp:$PATH"
export control_lib="$lib/deploy-control.sh" test_dir="$temp"
cat >"$temp/control-worker" <<'WORKER'
#!/bin/bash
. "$control_lib"
execution_token=fixture progress_attempt=2 rootpxe_storage_boot_id=boot rootpxe_storage_sysuuid=
rootpxe_publish_deploy_control || exit 1
echo "$$" >"$test_dir/control-worker-pid"
exec sleep 20
WORKER
chmod 700 "$temp/control-worker"
unset rootpxe_deploy_control_dir
rootpxe_task_curl() {
    [[ -s $temp/control-worker-pid ]] || return 1
    local arg advertised=no
    for arg; do
        if [[ $arg == abortStopped=* ]]; then
            touch "$temp/acknowledged"
        elif [[ $arg == deployControl=true ]]; then
            advertised=yes
        fi
    done
    [[ $advertised == yes ]] || return 1
    printf '{"status":"%s"}\n200\n' "$reply_state"
}
for reply_state in superseded deleted; do
    rm -f "$temp/control-worker-pid"
    rc=0
    rootpxe_run_deployment "$temp/control-worker" "$temp" || rc=$?
    [[ $rc -eq 75 && ! -e $temp/acknowledged && ! -e $temp/pxeos.deploy-control ]]
    read -r worker <"$temp/control-worker-pid"
    ! kill -0 "$worker" 2>/dev/null
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
