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
! rootpxe_deploy_poll
[[ ! -e $rootpxe_deploy_control_dir/stop ]]
for reply in 'deleted 403' 'superseded 404' 'aborting 200' 'completed 200'; do
    read -r reply_state reply_code <<<"$reply"
    rootpxe_task_curl() { printf '{"status":"%s"}\n%s\n' "$reply_state" "$reply_code"; }
    ! rootpxe_deploy_poll
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
        elif [[ $arg == deployRetryClaim=true ]]; then
            printf '{"status":"superseded"}\n200\n'
            return
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

# Record safely simulated mount state. The helper must never remove the
# preexisting or unrelated entries and must stop if an owned mount is busy.
cat >"$temp/baseline" <<'MOUNTS'
1 0 0:1 / /storage rw - tmpfs tmpfs rw
MOUNTS
cat >"$temp/mountinfo" <<'MOUNTS'
1 0 0:1 / /storage rw - tmpfs tmpfs rw
2 1 0:2 / /tmp/rootpxe-uefi.abcdef/esp rw - tmpfs tmpfs rw
3 1 0:3 / /tmp/rootpxe-cloud-mount.abcdef/root rw - tmpfs tmpfs rw
4 3 0:4 / /tmp/rootpxe-cloud-mount.abcdef/root/boot rw - tmpfs tmpfs rw
5 1 0:5 / /tmp/unrelated rw - tmpfs tmpfs rw
MOUNTS
umount() {
    local target=${*: -1}
    [[ $target != "${busy_mount:-}" ]] || return 1
    printf '%s\n' "$target" >>"$temp/unmounted"
    awk -v mount="$target" '$5!=mount' "$temp/mountinfo" >"$temp/mountinfo.new"
    mv "$temp/mountinfo.new" "$temp/mountinfo"
}
busy_mount=/tmp/rootpxe-cloud-mount.abcdef/root
! rootpxe_deploy_retry_cleanup "$temp/baseline" "$temp/mountinfo"
[[ -z $(grep -E '^/(storage|tmp/unrelated)$' "$temp/unmounted" || true) ]]
[[ $(head -n1 "$temp/unmounted") == /tmp/rootpxe-cloud-mount.abcdef/root/boot ]]
busy_mount=
rootpxe_deploy_retry_cleanup "$temp/baseline" "$temp/mountinfo"
[[ $(wc -l <"$temp/mountinfo") == 2 ]]
unset -f umount

# A deployed worker can exit on an image error before the administrator
# requests retry. The launcher must keep control alive after ECHILD and can
# claim at most the next server-provided attempt before starting another worker.
cat >"$temp/retry-worker" <<'WORKER'
#!/bin/bash
. "$control_lib"
case ${rootpxe_deploy_retry_attempt:-2} in
    2) execution_token=fixture progress_attempt=2 ;;
    3) [[ $task_token == 0123456789abcdef0123456789abcdef && -f $test_dir/claim-2 ]] || exit 1
       execution_token=$task_token progress_attempt=3 ;;
    4) [[ $task_token == 1123456789abcdef0123456789abcdef && -f $test_dir/claim-3 ]] || exit 1
       touch "$test_dir/restarted"
       exit 0 ;;
    *) exit 1 ;;
esac
rootpxe_storage_boot_id=boot rootpxe_storage_sysuuid=
rootpxe_publish_deploy_control || exit 1
echo "$$" >"$test_dir/retry-worker-pid-$progress_attempt"
exit 1
WORKER
chmod 700 "$temp/retry-worker"
rootpxe_deploy_retry_cleanup() { touch "$temp/cleanup"; }
rootpxe_task_curl() {
    local arg claim=no worker attempt=0 token
    for arg; do
        case "$arg" in
            deployRetryClaim=true) claim=yes ;;
            attempt=*) attempt=${arg#attempt=} ;;
        esac
    done
    [[ -s $temp/retry-worker-pid-$attempt ]] || return 1
    read -r worker <"$temp/retry-worker-pid-$attempt"
    if [[ $claim == yes ]]; then
        [[ -f $temp/cleanup ]] || return 1
        ! kill -0 "$worker" 2>/dev/null || return 1
        touch "$temp/claim-$attempt"
        case $attempt in
            2) token=0123456789abcdef0123456789abcdef ;;
            3) token=1123456789abcdef0123456789abcdef ;;
            *) return 1 ;;
        esac
        printf '{"status":"retry","executionToken":"%s","progressAttempt":%s}\n200\n' "$token" "$((attempt + 1))"
    else
        [[ ! -f $temp/claim-$attempt ]] || return 1
        [[ -f $temp/retry-clicked-$attempt ]] || return 1
        printf '{"status":"superseded"}\n200\n'
    fi
}
(
    for attempt in 2 3; do
        while [[ ! -s $temp/retry-worker-pid-$attempt ]]; do sleep .025; done
        sleep 1
        touch "$temp/retry-clicked-$attempt"
    done
) &
click=$!
rc=0
rootpxe_run_deployment "$temp/retry-worker" "$temp" || rc=$?
wait "$click"
[[ $rc -eq 0 && -f $temp/restarted && ! -e $temp/pxeos.deploy-control ]]

# Exercise only the failure helper with a mocked reporter. The deployment
# branch must report before delegating the indefinite wait to the supervisor.
eval "$(sed -n '/^rootpxe_error_wait_for_retry() {$/,/^}$/p' "$lib/funcs.sh")"
rootpxe_failure_begin() { rootpxe_failure_action=reboot; }
killStatusReporter() { :; }
rootpxe_task_console_failure() { :; }
rootpxe_console_message() { :; }
rootpxe_require_task_context() { :; }
rootpxe_error_report() {
    [[ $1 == 'fixture failure' && $2 == PXEOS_ERROR ]] || return 1
    touch "$temp/error-reported"
    rootpxe_error_report_response='{"accepted":true}'
}
rootpxe_deploy_control_dir="$temp/control"
rc=0
rootpxe_error_wait_for_retry 'fixture failure' || rc=$?
[[ $rc -eq 2 && -f $temp/error-reported ]]
unset rootpxe_deploy_control_dir

# Kernel import is extracted without sourcing funcs.sh or reading host boot
# parameters. Its repeated calls must preserve the current task credential.
kernel_import=$(sed -n '/^rootpxe_kernel_key_allowed() {$/,/^rootpxe_import_kernel_args$/{s|done < <(tr .* </proc/cmdline)|done < "$temp/kernel-args"|;p;}' "$lib/funcs.sh")
[[ $kernel_import == *'done < "$temp/kernel-args"'* && $kernel_import != *'/proc/cmdline'* ]]
printf '%s\n' 'task_token=old-kernel-token' 'type=down' >"$temp/kernel-args"
rootpxe_deploy_retry_token=0123456789abcdef0123456789abcdef
task_token=$rootpxe_deploy_retry_token
eval "$kernel_import"
[[ $task_token == "$rootpxe_deploy_retry_token" ]]
task_token=rotated-checkin-token
rootpxe_import_kernel_args
[[ $task_token == rotated-checkin-token ]]
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
