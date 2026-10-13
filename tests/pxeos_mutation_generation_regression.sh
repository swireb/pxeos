#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-mutation-generation.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
failures=0
bad(){ printf 'FAIL: %s\n' "$*" >&2; failures=$((failures+1)); }
rootpxe_task_log_initialize
native(){ rootpxe_task_log_initialize; native_parent_changed=yes; printf 'OLD_ATTEMPT_DIAGNOSTIC\n'; return 0; }
native_parent_changed=no
rootpxe_run_logged_mutation fake /dev/mock native >"$tmp/out" 2>"$tmp/err"
[[ $native_parent_changed == yes ]] || bad native-parent-state
! grep -q OLD_ATTEMPT_DIAGNOSTIC "$tmp/log/pxeos-task.log" || bad old-diagnostic-in-new-attempt
[[ ${rootpxe_task_log_state[unavailable]:-no} != yes ]] || bad new-attempt-marked-unavailable
rootpxe_task_log_initialize
saved_snapshot=$(declare -f rootpxe_log_snapshot)
rootpxe_log_snapshot(){ return 1; }
native(){ printf 'native error\n'; return 7; }
rc=0; rootpxe_run_logged_mutation fake /dev/mock native >"$tmp/fault.out" 2>"$tmp/fault.err" || rc=$?
[[ $rc == 7 ]] || bad snapshot-changed-native-rc
[[ ${rootpxe_task_log_state[unavailable]:-no} == yes ]] || bad failed-diagnostic-reported-complete
grep -q unavailable "$tmp/fault.err" || bad snapshot-no-warning
eval "$saved_snapshot"
rootpxe_task_log_initialize
eval "$(declare -f rootpxe_log_pin_valid | sed '1s/rootpxe_log_pin_valid/rootpxe_generation_real_pin_valid/')"
acquired_fd=''
rootpxe_log_pin_valid(){
    if [[ -n ${rootpxe_mutation_owner_pin:-} && $1 == "$rootpxe_mutation_owner_pin" ]]; then acquired_fd=$1; return 1; fi
    rootpxe_generation_real_pin_valid "$@"
}
rc=0; rootpxe_run_logged_mutation fake /dev/mock native >"$tmp/acquire.out" 2>"$tmp/acquire.err" || rc=$?
[[ $rc == 7 && -n $acquired_fd && ! -e /proc/self/fd/$acquired_fd ]] || bad invalid-acquire-leaked-fd
printf 'Mutation generation: %s failures\n' "$failures"
[[ $failures == 0 ]]
