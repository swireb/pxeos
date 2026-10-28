#!/usr/bin/env bash
# Offline or local process/HTTP fixtures only; no initramfs or real disk/NAS.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
IFS=: read -r hierarchy controllers command_cgroup </proc/self/cgroup
[[ $hierarchy == 0 && -z $controllers && $command_cgroup == */codexbuildtest.slice/* ]] || { printf 'FAIL: run through codex-build-test\n' >&2; exit 125; }
slice_cgroup="${command_cgroup%%/codexbuildtest.slice/*}/codexbuildtest.slice"
IFS= read -r memory_limit <"/sys/fs/cgroup$slice_cgroup/memory.max"
[[ $memory_limit == 8589934592 ]] || { printf 'FAIL: 8 GiB slice limit unavailable\n' >&2; exit 125; }
memory_events="/sys/fs/cgroup$slice_cgroup/memory.events"
logs=$(mktemp -d /tmp/rootpxe-lifecycle-audit.XXXXXX)
printf 'Audit logs: %s\n' "$logs"
passed=0 failed=0
run_case() {
    local name=$1 before after status=0
    shift
    before=$(awk '$1=="max" || $1=="oom" || $1=="oom_kill" { print }' "$memory_events")
    timeout 300 "$@" >"$logs/$name.log" 2>&1 || status=$?
    after=$(awk '$1=="max" || $1=="oom" || $1=="oom_kill" { print }' "$memory_events")
    if [[ $before != "$after" ]]; then
        printf 'STOP: memory-limit event changed during %s\n%s\n%s\n' "$name" "$before" "$after" >&2
        exit 125
    fi
    if [[ $status == 0 ]] && grep -Eq 'line [0-9]+: .*: command not found' "$logs/$name.log"; then status=1; fi
    if [[ $status == 0 ]]; then
        printf 'PASS: %s\n' "$name"; passed=$((passed + 1))
    else
        printf 'FAIL: %s (exit=%s)\n' "$name" "$status" >&2
        tail -n 35 "$logs/$name.log" >&2
        failed=$((failed + 1))
    fi
}
for test in \
    pxeos_task_http_regression pxeos_error_cleanup_regression pxeos_retry_environment_regression \
    pxeos_api_business_regression pxeos_script_io_regression \
    pxeos_capture_regression pxeos_capture_resume_regression pxeos_restore_preflight_regression \
    pxeos_mpa_permit_regression pxeos_partition_progress_regression pxeos_partclone_progress_regression \
    pxeos_timeline_order_regression pxeos_task_log_regression pxeos_log_pin_regression \
    pxeos_cloud_init_protocol_regression pxeos_cloud_init_permit_regression pxeos_template_injection_regression \
    multicast-number-identity-regression multicast-protocol-regression multicast-deadline-regression \
    multicast-callback-session-regression multicast-monitor-http-cancel-regression multicast-writeimage-regression; do
    run_case "$test" bash "tests/$test.sh"
done
run_case pxeos_storage_controller python3 -B tests/pxeos_storage_controller_test.py
run_case pxeos_storage_helper python3 -B tests/pxeos_storage_helper_test.py
printf 'RESULT: pass=%s fail=%s\n' "$passed" "$failed"
[[ $failed == 0 ]]
