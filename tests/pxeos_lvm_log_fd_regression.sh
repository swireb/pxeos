#!/usr/bin/env bash
# Native LVM is mocked. No block device, image, VG or network is touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-lvm-log-fd.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
task_log_test_load_helpers "$funcs"
eval "$(sed -n '/^rootpxe_lvm_capture_report() {/,/^}/p' "$funcs")"
if ! declare -F rootpxe_lvm_native >/dev/null; then rootpxe_lvm_native(){ "$@"; }; fi
failures=0
bad(){ printf 'FAIL: %s\n' "$*" >&2; failures=$((failures+1)); }
rootpxe_task_log_initialize
task_pin=${rootpxe_task_log_state[pin]}; task_identity=${rootpxe_task_log_state[identity]}
foreign=''
pvs(){
    printf '%s\n' "$*" >"$tmp/argv"
    for descriptor in "$task_pin" "${rootpxe_mutation_owner_pin:-}" "${rootpxe_boot_pin:-}" "${rootpxe_storage_request_fd:-}" "${rootpxe_storage_result_fd:-}" "${rootpxe_storage_data_fd:-}" "$foreign"; do
        [[ -z $descriptor || ! -e /proc/self/fd/$descriptor ]] || printf 'File descriptor %s leaked on pvs invocation.\n' "$descriptor" >&2
    done
    [[ ${real_warning:-no} != yes ]] || printf 'REAL_LVM_WARNING\n' >&2
    [[ ${read_input:-no} != yes ]] || { IFS= read -r input; printf '%s\n' "$input" >"$tmp/stdin"; }
    printf '{"report":[{"pv":[]}]}\n'
    return "${native_rc:-0}"
}
rc=0; rootpxe_lvm_capture_report "$tmp/query.json" pvs --reportformat json -o pv_name || rc=$?
[[ $rc == 0 ]] || bad logger-pin-causes-strict-query-rejection
grep -Fqx '{"report":[{"pv":[]}]}' "$tmp/query.json" || bad query-json-changed
rootpxe_log_pin_valid "$task_pin" "$task_identity" || bad parent-pin-closed
[[ ${rootpxe_task_log_state[pin]} == "$task_pin" ]] || bad parent-state-changed
# The storage controller keeps only its three private IPC endpoints. LVM
# must lose those child copies while the parent keeps exchanging FIFO data.
rootpxe_storage_workspace="$tmp/storage"
mkdir -m 700 "$rootpxe_storage_workspace"
mkfifo -m 600 "$rootpxe_storage_workspace/"{request,result,data}
exec {request_anchor}<>"$rootpxe_storage_workspace/request"
exec {result_anchor}<>"$rootpxe_storage_workspace/result"
exec {data_anchor}<>"$rootpxe_storage_workspace/data"
exec {rootpxe_storage_request_fd}>"$rootpxe_storage_workspace/request"
exec {rootpxe_storage_result_fd}<"$rootpxe_storage_workspace/result"
exec {rootpxe_storage_data_fd}<"$rootpxe_storage_workspace/data"
rc=0; rootpxe_lvm_capture_report "$tmp/storage-query.json" pvs || rc=$?
[[ $rc == 0 ]] || bad storage-ipc-causes-strict-query-rejection
printf 'REQUEST\n' >&"$rootpxe_storage_request_fd"
IFS= read -r -t 1 -u "$request_anchor" fifo_value || bad parent-request-fd-closed
[[ ${fifo_value:-} == REQUEST ]] || bad parent-request-data-changed
printf 'RESULT\n' >&"$result_anchor"
IFS= read -r -t 1 -u "$rootpxe_storage_result_fd" fifo_value || bad parent-result-fd-closed
[[ ${fifo_value:-} == RESULT ]] || bad parent-result-data-changed
printf 'DATA\n' >&"$data_anchor"
IFS= read -r -t 1 -u "$rootpxe_storage_data_fd" fifo_value || bad parent-data-fd-closed
[[ ${fifo_value:-} == DATA ]] || bad parent-read-data-changed
# A different descriptor for the exact same FIFO is not controller-owned.
exec {foreign}<"$rootpxe_storage_workspace/request"
rc=0; rootpxe_lvm_capture_report "$tmp/storage-foreign.json" pvs || rc=$?
[[ $rc != 0 && -e /proc/self/fd/$foreign ]] || bad same-fifo-foreign-closed-or-hidden
exec {foreign}<&-; foreign=''
# A known numeric slot reused for a regular file must also remain visible.
saved_request_fd=$rootpxe_storage_request_fd
exec {rootpxe_storage_request_fd}>&-
printf REUSED >"$tmp/storage-reused"
exec {rootpxe_storage_request_fd}<"$tmp/storage-reused"
[[ $rootpxe_storage_request_fd == "$saved_request_fd" ]] || bad storage-reuse-fixture-not-exercised
rootpxe_lvm_native pvs >"$tmp/storage-reused.json" 2>"$tmp/storage-reused.err"
grep -q "descriptor $rootpxe_storage_request_fd leaked" "$tmp/storage-reused.err" || bad reused-storage-fd-closed
[[ -e /proc/self/fd/$rootpxe_storage_request_fd ]] || bad reused-storage-parent-fd-closed
# FIFO type alone is insufficient when the slot now names another pipe.
mkfifo -m 600 "$tmp/storage-other-fifo"
exec {other_anchor}<>"$tmp/storage-other-fifo"
exec {rootpxe_storage_request_fd}<&-
exec {rootpxe_storage_request_fd}<"$tmp/storage-other-fifo"
[[ $rootpxe_storage_request_fd == "$saved_request_fd" ]] || bad other-fifo-reuse-fixture-not-exercised
rootpxe_lvm_native pvs >"$tmp/storage-other.json" 2>"$tmp/storage-other.err"
grep -q "descriptor $rootpxe_storage_request_fd leaked" "$tmp/storage-other.err" || bad other-fifo-storage-fd-closed
[[ -e /proc/self/fd/$rootpxe_storage_request_fd ]] || bad other-fifo-parent-fd-closed
exec {other_anchor}>&-
exec {rootpxe_storage_request_fd}<&-
exec {rootpxe_storage_result_fd}<&-
exec {rootpxe_storage_data_fd}<&-
exec {request_anchor}>&-
exec {result_anchor}>&-
exec {data_anchor}>&-
unset rootpxe_storage_workspace rootpxe_storage_request_fd rootpxe_storage_result_fd rootpxe_storage_data_fd
real_warning=yes; rc=0; rootpxe_lvm_capture_report "$tmp/warning.json" pvs || rc=$?
[[ $rc != 0 ]] || bad real-stderr-ignored
real_warning=no
printf FOREIGN >"$tmp/foreign"
exec {foreign}<"$tmp/foreign"
rc=0; rootpxe_lvm_capture_report "$tmp/foreign.json" pvs || rc=$?
[[ $rc != 0 && -e /proc/self/fd/$foreign ]] || bad foreign-fd-closed-or-warning-hidden
exec {foreign}<&-; foreign=''
# A foreign readonly descriptor to the very same inode is still not owned.
exec {foreign}<"$tmp/log/pxeos-task.log"
rc=0; rootpxe_lvm_capture_report "$tmp/same-inode.json" pvs || rc=$?
[[ $rc != 0 && -e /proc/self/fd/$foreign ]] || bad same-inode-foreign-closed
exec {foreign}<&-; foreign=''
# A stale registration must never close a reused descriptor to another inode.
exec {foreign}<"$tmp/log/pxeos-task.log"
rootpxe_log_pin_register "$foreign" "$task_identity"
old_foreign=$foreign
exec {foreign}<&-
exec {foreign}<"$tmp/foreign"
[[ $foreign == "$old_foreign" ]] || bad reuse-fixture-not-exercised
rootpxe_lvm_native pvs >"$tmp/reused.json" 2>"$tmp/reused.err"
grep -q "descriptor $foreign leaked" "$tmp/reused.err" || bad reused-fd-closed
[[ -e /proc/self/fd/$foreign ]] || bad reused-parent-fd-closed
unset 'rootpxe_log_owned_pin_state[$foreign]'
exec {foreign}<&-; foreign=''
# Read/write descriptors are not eligible for registration or child closure.
exec {foreign}<>"$tmp/log/pxeos-task.log"
TASK_LOG_TEST_NONREADONLY_FD=$foreign
rc=0; rootpxe_log_pin_register "$foreign" "$task_identity" || rc=$?
[[ $rc != 0 ]] || bad writable-pin-registered
rootpxe_log_owned_pin_state[$foreign]=$task_identity
rootpxe_lvm_native pvs >"$tmp/writable.json" 2>"$tmp/writable.err"
grep -q "descriptor $foreign leaked" "$tmp/writable.err" || bad writable-fd-closed
unset 'rootpxe_log_owned_pin_state[$foreign]'
exec {foreign}>&-; foreign=''; unset TASK_LOG_TEST_NONREADONLY_FD
# Missing descriptors are harmless and cannot cause unrelated FD closure.
rootpxe_log_owned_pin_state[9999]=$task_identity
rootpxe_lvm_native pvs >"$tmp/missing.json" 2>"$tmp/missing.err"
[[ ! -s $tmp/missing.err ]] || bad missing-pin-native-warning
unset 'rootpxe_log_owned_pin_state[9999]'
native_rc=7; read_input=yes
rc=0; rootpxe_lvm_native pvs --reportformat json < <(printf 'INPUT_SENTINEL\n') >"$tmp/native.json" 2>"$tmp/native.err" || rc=$?
[[ $rc == 7 && $(cat "$tmp/stdin") == INPUT_SENTINEL && $(cat "$tmp/argv") == '--reportformat json' ]] || bad native-argv-stdin-rc-changed
[[ ! -s $tmp/native.err ]] || bad owned-task-pin-inherited
read_input=no; native_rc=0
saved_release=$(declare -f rootpxe_log_pin_release)
rootpxe_log_pin_release(){ return 1; }
native_rc=7; read_input=yes
rm -f "$tmp/stdin" "$tmp/argv"
rc=0; rootpxe_lvm_native pvs --release-fault < <(printf 'RELEASE_INPUT\n') >"$tmp/release-fault.json" 2>"$tmp/release-fault.err" || rc=$?
[[ $rc == 7 && -f $tmp/stdin && $(cat "$tmp/stdin") == RELEASE_INPUT && -f $tmp/argv && $(cat "$tmp/argv") == --release-fault ]] || bad release-failure-skipped-native
grep -q "descriptor $task_pin leaked" "$tmp/release-fault.err" || bad release-failure-hidden-native-warning
rootpxe_log_pin_valid "$task_pin" "$task_identity" || bad release-failure-closed-parent
eval "$saved_release"
read_input=no; native_rc=0
rootpxe_run_logged_mutation pvs /dev/mock pvs >"$tmp/mutation.out" 2>"$tmp/mutation.err"
! grep -q leaked "$tmp/log/pxeos-task.log" || bad mutation-owned-pin-inherited
rootpxe_log_pin_valid "$task_pin" "$task_identity" || bad mutation-closed-parent-pin
boot_native(){ rootpxe_lvm_native pvs; }
rootpxe_log_boot_run linux-lvm.log lvm_boot foreground boot_native >"$tmp/boot.out" 2>"$tmp/boot.err"
! grep -q leaked "$tmp/log/linux-lvm.log" || bad boot-owned-pin-inherited
rootpxe_log_pin_valid "$task_pin" "$task_identity" || bad boot-closed-parent-pin
# Other approved native/mock commands retain the generic same-shell contract.
native_parent=no
other_native(){ native_parent=yes; return 7; }
rc=0; rootpxe_run_logged_mutation fake /dev/mock other_native || rc=$?
[[ $rc == 7 && $native_parent == yes ]] || bad generic-native-moved-to-subshell
printf 'LVM log FD: %s failures\n' "$failures"
[[ $failures == 0 ]]
