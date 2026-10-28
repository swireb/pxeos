#!/usr/bin/env bash
# 只用临时普通文件与请求替身核对阶段顺序，不操作真实磁盘或网络。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d /tmp/rootpxe-timeline-order.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq(){ [[ $1 == "$2" ]] || fail "$3 (got=$1 expected=$2)"; }
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
reporter="$overlay/bin/pxeos.statusreporter"
phase_file="$tmp/data-phase"
sed "s#/tmp/pxeos.data-phase#$phase_file#g" "$overlay/usr/share/pxeos/lib/partclone-progress.sh" >"$tmp/adapter.sh"
. "$tmp/adapter.sh"
awk '/^rootpxe_partition_progress_initialize_runtime\(\)/ {copy=1} /^REG_LOCAL_MACHINE_XP=/ {exit} copy' "$funcs" |
  sed -e "s#/tmp/pxeos.partition-progress.json#$tmp/snapshot.json#g" -e "s#/tmp/pxeos.partition-progress.events#$tmp/events#g" -e "s#/tmp/pxeos.data-phase#$phase_file#g" >"$tmp/helpers.sh"
. "$tmp/helpers.sh"
trace="$tmp/trace"; : >"$trace"
rootpxe_stage(){ printf 'stage:%s:%s\n' "$1" "$2" >>"$trace"; }
rootpxe_task_multicast_form_args(){ rootpxe_task_multicast_args=(); }
rootpxe_task_curl(){ printf 'request:%s\n' "$*" >>"$trace"; }
type=up taskid=71 progress_attempt=1 task_token=0123456789abcdef mac=aa:bb:cc:dd:ee:ff pxeapi=http://fixture/
rootpxe_partition_progress_enabled=yes
rootpxe_partclone_progress_run_id=fixture-run-1
rootpxe_partition_progress_initialize_runtime
[[ ! -e $phase_file ]] || fail initialization_retained_old_phase
declare -F rootpxe_progress_data_phase_begin >/dev/null || fail missing_real_copy_start_gate
! rootpxe_progress_data_phase_active || fail initialized_status_started_copy
rootpxe_partition_progress_current_item d1:p1
rootpxe_progress_data_phase_active || fail real_zero_did_not_open_copy
grep -qx 'stage:capture:progress=0' "$trace" || fail real_zero_start_missing
rootpxe_partition_progress_current_item d1:p2
assert_eq "$(grep -c '^stage:capture:' "$trace")" 1 copy_start_not_idempotent
progress_attempt=2
! rootpxe_progress_data_phase_active || fail old_attempt_opened_copy
progress_attempt=1 rootpxe_partclone_progress_run_id=fixture-run-2
! rootpxe_progress_data_phase_active || fail old_run_opened_copy
rootpxe_partclone_progress_run_id=fixture-run-1 task_token=another-execution-token
! rootpxe_progress_data_phase_active || fail reused_taskid_attempt_partimage_token_opened_copy
task_token=0123456789abcdef rootpxe_partclone_progress_run_id=fixture-run-2
rootpxe_partition_progress_initialize_runtime
type=down
rootpxe_partition_progress_current_item d1:disk
grep -qx 'stage:restore:progress=0' "$trace" || fail raw_or_partimage_zero_start_missing

# A full pending plan is sent separately before any queued item can be applied.
rootpxe_partition_progress_initialize_runtime
getPartitions(){ parts='/dev/fixture1'; }
getPartitionNumber(){ part_number=1; }
rootpxe_partition_progress_source_metadata(){ printf '1024|ext4|partition\n'; }
rootpxe_lvm_is_pv_partition(){ return 1; }
rootpxe_partition_progress_send_snapshot(){ printf 'plan:%s\n' "$(jq -r '.items[0].status' "$1")" >>"$trace"; }
: >"$trace"
rootpxe_partition_progress_plan_disk /dev/fixture 1
assert_eq "$(cat "$trace")" plan:pending full_plan_not_sent_before_copy
rootpxe_partition_progress_current_item d1:p1
assert_eq "$(head -n 1 "$trace")" plan:pending copy_started_before_full_plan

# Extract the actual reporter functions, not a duplicate implementation.
awk '/^rootpxe_progress_sleep\(\)/ {copy=1} /^rootpxe_progress_sleep$/ {exit} copy' "$reporter" |
  sed -e "s#/tmp/pxeos.partition-progress.json#$tmp/snapshot.json#g" -e "s#/tmp/pxeos.partition-progress.events#$tmp/events#g" >"$tmp/reporter-functions.sh"
. "$tmp/reporter-functions.sh"
declare -F rootpxe_progress_report_once >/dev/null || fail reporter_cycle_not_testable
rootpxe_partition_progress_initialize_runtime
prog_stage=restore progress_run_id=fixture-run-2 progress_mode=partclone api_base=http://fixture/ sysuuid=fixture
last_pct=0 last_snapshot_hash='' last_snapshot_sent=0 last_heartbeat_sent=0 active_key='' active_generation=''
: >"$trace"
rootpxe_progress_report_once
grep -q 'heartbeat=true' "$trace" || fail prepare_heartbeat_missing
grep -q 'progressAttempt=1' "$trace" || fail heartbeat_attempt_missing
! grep -q 'stage=restore\|stage=capture\|progress=' "$trace" || fail prepare_created_fake_copy_progress
rootpxe_partition_progress_plan_disk /dev/fixture 1
rootpxe_partition_progress_item d1:p1 preparing 0 '准备写入'
: >"$trace"
rootpxe_progress_report_once
! grep -q 'stage=restore\|stage=capture' "$trace" || fail pending_plan_started_copy
assert_eq "$(find "$tmp/events" -name 'event-*.json' | wc -l | tr -d ' ')" 1 prepare_queue_consumed_before_real_start
rootpxe_task_multicast_form_args(){ return 1; }
rootpxe_partition_progress_current_item d1:p1
rm -f -- "$tmp/snapshot.json"
: >"$trace"
rootpxe_progress_report_once
[[ ! -s $trace ]] || fail invalid_multicast_identity_sent_a_request
rootpxe_task_multicast_form_args(){ rootpxe_task_multicast_args=(); }

# Use the production multicast form builder: never duplicate the retry field.
. <(sed -n '/^rootpxe_task_multicast_number_valid()/,$p' "$overlay/usr/share/pxeos/lib/task-http.sh")
mc=yes multicastSessionId=1 multicastSessionKey=mc-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
last_heartbeat_sent=0
: >"$trace"
rootpxe_progress_send_heartbeat "$(date +%s)"
assert_eq "$(grep -o 'progressAttempt=1' "$trace" | wc -l | tr -d ' ')" 1 multicast_heartbeat_duplicated_attempt
grep -q 'sessionId=1' "$trace" || fail multicast_heartbeat_lost_session_identity
multicastSessionKey=invalid last_heartbeat_sent=0
: >"$trace"
rootpxe_progress_send_heartbeat "$(date +%s)"
[[ ! -s $trace ]] || fail invalid_multicast_heartbeat_sent_request
mc=no
for progress_mode in partclone partimage; do
    : >"$trace"
    rootpxe_progress_report_once
    grep -q 'progress=0.*stage=restore' "$trace" || fail actual_copy_zero_was_removed
done

# No-copy work keeps its registered plan but never creates copy start/end.
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_item d1:p1 skipped - '没有可写入的分区镜像'
! rootpxe_progress_data_phase_active || fail skipped_item_started_copy

# The actual completion function drains the reporter before its end event.
mkdir "$tmp/image"
printf 'printf "finish\\n" >>"$trace"\n' >"$tmp/finish.sh"
sed -n '/^completeTasking() {/,/^}/p' "$funcs" | sed "s#/bin/pxeos.imgcomplete#$tmp/finish.sh#g" >"$tmp/complete.sh"
. "$tmp/complete.sh"
killStatusReporter(){ printf 'stopped\n' >>"$trace"; }
rootpxe_partition_progress_flush(){ printf 'flushed\n' >>"$trace"; }
rootpxe_deployment_identity_policy_enabled(){ return 1; }
rootpxe_deployment_identity_private_enabled(){ return 1; }
rootpxe_deployment_identity_windows_policy_enabled(){ return 1; }
rootpxe_cloud_init_policy_enabled(){ return 1; }
rootpxe_apply_cloud_init(){ printf 'initialization\n' >>"$trace"; }
rootpxe_deployment_identity_cleanup_private(){ :; }
rootpxe_partition_progress_enabled=no imagePath="$tmp/image" capone=0 changeHostname=false
for type in up down; do
    rootpxe_partition_progress_initialize_runtime
    rootpxe_partition_progress_current_item d1:p1
    : >"$trace"
    completeTasking
    assert_eq "$(head -n 2 "$trace" | tr '\n' ' ')" 'stopped flushed ' end_preceded_reporter_flush
    [[ $(grep -n '^stage:' "$trace" | cut -d: -f1) == 3 ]] || fail end_missing_or_before_flush
    rootpxe_partition_progress_initialize_runtime
    : >"$trace"
    completeTasking
    ! grep -q '^stage:.*write finished' "$trace" || fail no_copy_work_created_copy_end
done

# Drive the real deployment entry body with safe leaves for the physical
# operations. Its permit/layout/plan branches must precede the shared copy hook.
download="$overlay/bin/pxeos.download"
sed -n '/^rootpxe_stage "${resumeStage:-init}"/p' "$download" >"$tmp/download-body.sh"
awk '/^findHDDInfo$/ {copy=1} copy' "$download" | sed "s#/bin/pxeos.imgcomplete#$tmp/finish.sh#g" >>"$tmp/download-body.sh"
findHDDInfo(){ hd=/dev/fixture; disks=/dev/fixture; }
rootpxe_require_unused_target_disks(){ printf 'target-check\n' >>"$trace"; }
rootpxe_require_single_disk_layout_metadata(){ :; }
rootpxe_validate_deployment_layout(){ printf 'layout-check\n' >>"$trace"; }
rootpxe_validate_growth_capability(){ :; }
rootpxe_validate_restore_artifacts(){ :; }
rootpxe_multicast_build_manifest(){ printf 'manifest\n' >>"$trace"; }
rootpxe_multicast_join(){ printf 'join\n' >>"$trace"; }
rootpxe_multicast_wait_for_selection(){ printf 'selection\n' >>"$trace"; }
rootpxe_multicast_watchdog_start(){ :; }
rootpxe_multicast_session_guard(){ :; }
rootpxe_multicast_end(){ printf 'data-barrier\n' >>"$trace"; }
rootpxe_plan_mpa_disk_permits(){ rootpxe_mpa_permit_is_batch=yes; rootpxe_mpa_permit_args=(fixture deploy_write); }
rootpxe_plan_deploy_disk_operation(){ rootpxe_planned_target_id=fixture; rootpxe_planned_disk_operation=deploy_write; }
rootpxe_wait_for_disk_permit(){ printf 'permit\n' >>"$trace"; }
rootpxe_wait_for_disk_permit_batch(){ printf 'permit\n' >>"$trace"; }
rootpxe_bind_granted_deploy_targets(){ :; }
enableWriteCache(){ printf 'cache\n' >>"$trace"; }
preparePartitions(){ printf 'layout\n' >>"$trace"; }
validateImageSectorSize(){ :; }
rootpxe_apply_deployment_layout(){ printf 'layout-write\n' >>"$trace"; }
rootpxe_restore_deployment_boot_code(){ :; }
rootpxe_console_message(){ :; }
rootpxe_lvm_preflight_restore_groups(){ :; }
putDataBack(){ rootpxe_partition_progress_current_item d1:p1; printf 'copy\n' >>"$trace"; }
rootpxe_restore_lvm_volumes(){ rootpxe_partition_progress_current_item 'd1:p1:lv:fixture'; printf 'lv-copy\n' >>"$trace"; }
blockdev(){ printf '1024\n'; }
handleError(){ printf 'failed\n' >>"$trace"; exit 77; }
before(){ local a b; a=$(grep -nF "$1" "$trace" | head -n1 | cut -d: -f1); b=$(grep -nF "$2" "$trace" | head -n1 | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]; }
for mc in no yes; do
    for imgType in n mps mpa dd; do
        (
            rootpxe_partition_progress_enabled=yes type=down imgPartitionType=all nombr=0
            originalSchemaFile="$tmp/schema" deploymentLayoutFile="$tmp/layout" rootpxe_resolved_layout_file="$tmp/resolved" rootpxe_resolved_lvm_layout_file='' resumeStage=''
            rootpxe_partition_progress_initialize_runtime
            : >"$trace"
            . "$tmp/download-body.sh"
            before 'storage mounted' permit || fail deployment_storage_after_permit
            before permit plan:pending || fail deployment_plan_before_permit
            before plan:pending stage:restore:progress=0 || fail deployment_copy_before_plan
            before stage:restore:progress=0 copy || fail deployment_missing_real_zero
            before stopped 'deploy write finished' || fail deployment_end_before_stop
            [[ $mc != yes ]] || before selection permit || fail multicast_permit_before_selection
        )
    done
done
(
    mc=no imgType=n type=down imgPartitionType=mbr nombr=0 resumeStage='' rootpxe_partition_progress_enabled=yes
    originalSchemaFile="$tmp/schema" deploymentLayoutFile="$tmp/layout" rootpxe_resolved_layout_file="$tmp/resolved" rootpxe_resolved_lvm_layout_file=''
    rootpxe_partition_progress_initialize_runtime
    : >"$trace"
    . "$tmp/download-body.sh"
    ! grep -q 'stage:restore:\|^copy$' "$trace" || fail mbr_only_created_copy_lifecycle
)
for resumeStage in cloud_init customizing_hostname; do
    (
        mc=no imgType=n type=down changeHostname=true rootpxe_partition_progress_enabled=yes
        rootpxe_clear_disk_permit(){ :; }
        rootpxe_disk_stable_identity(){ printf fixture; }
        rootpxe_record_disk_permit_binding(){ :; }
        rootpxe_verify_disk_permit_binding(){ :; }
        rootpxe_activate_disk_permit_binding(){ :; }
        rootpxe_apply_hostname_for_disk(){ printf 'hostname\n' >>"$trace"; }
        rootpxe_partition_progress_initialize_runtime
        : >"$trace"
        . "$tmp/download-body.sh"
    )
    grep -q "stage:$resumeStage:.*storage mounted" "$trace" || fail resume_stage_was_overwritten
    ! grep -q 'stage:restore:\|stage:init:\|layout-write\|^copy$' "$trace" || fail initialization_resume_reentered_disk_or_copy
done

# A foreground HTTP child must be gone when the reporter has been reaped.
sed -e "s#^\. /usr/share/pxeos/lib/partclone-progress.sh.*#. '$tmp/adapter.sh'#" \
    -e "s#^\. /usr/share/pxeos/lib/task-http.sh.*#. '$overlay/usr/share/pxeos/lib/task-http.sh'#" \
    -e 's/^sysuuid=.*/sysuuid=fixture/' \
    -e 's/{16,512}/{16,255}/' \
    -e 's/^rootpxe_progress_sleep() .*/rootpxe_progress_sleep() { sleep 0.01; }/' \
    -e "s#/tmp/pxeos.partition-progress.json#$tmp/snapshot.json#g" \
    -e "s#/tmp/pxeos.partition-progress.events#$tmp/events#g" "$reporter" >"$tmp/reporter.sh"
curl(){
    local header=''
    printf 'request-started\n' >>"$trace"
    while (( $# )); do
        case $1 in --dump-header) header=$2; shift 2;; *) shift;; esac
    done
    sleep 0.25
    printf 'HTTP/1.1 200 OK\r\n\r\n' >"$header"
    printf 'request-finished\n' >>"$trace"
}
export -f curl
export trace type task_token progress_attempt
for entry in "$overlay/bin/pxeos.upload" "$overlay/bin/pxeos.download"; do
    ! grep -E '^pxeos\.statusreporter .*disown' "$entry" || fail reporter_launch_cannot_be_reaped
done
sed -n '/^killStatusReporter() {/,/^}/p' "$funcs" >"$tmp/stop.sh"
. "$tmp/stop.sh"
debugPause(){ :; }
: >"$trace"
bash "$tmp/reporter.sh" "$mac" "$pxeapi" "$taskid" fixture-run-2 partclone &
statusReporter=$!
for _ in {1..100}; do grep -q '^request-started$' "$trace" && break; sleep 0.02; done
grep -q '^request-started$' "$trace" || fail reporter_request_never_started
killStatusReporter
[[ -z $statusReporter ]] || fail reporter_pid_was_not_cleared
grep -q '^request-finished$' "$trace" || fail reporter_handoff_left_request_running

# The real error->queued->exec branch must stop an owned reporter first;
# exec itself does not invoke the entry's EXIT cleanup trap.
for name in rootpxe_failure_begin rootpxe_failure_remaining rootpxe_error_report; do
    eval "$(sed -n "/^$name() {/,/^}/p" "$funcs" | sed "s|/tmp/pxeos.failure_action|$tmp/failure_action|g")"
done
sed -n '/^rootpxe_error_wait_for_retry() {/,/^}/p' "$funcs" |
    sed -e "s#/tmp/pxeos.failure_action#$tmp/failure_action#g" \
        -e 's#exec /bin/pxeos#printf "exec\\n" >>"$trace"; return 77#' >"$tmp/error-wait.sh"
. "$tmp/error-wait.sh"
rootpxe_require_task_context(){ return 0; }
rootpxe_bound_callback_message(){ printf '%s' "$1"; }
rootpxe_storage_reset_retry_state(){ printf 'storage-reset\n' >>"$trace"; }
rootpxe_reset_disk_permit_retry_state(){ printf 'permit-reset\n' >>"$trace"; }
rootpxe_task_log_release_pin(){ :; }
rootpxe_task_curl(){
    printf 'callback\n' >>"$trace"
    case "${*: -1}" in
        *error) printf '{"accepted":true,"waitSec":60,"failureAction":"reboot"}\n200';;
        *task-status) printf '{"status":"queued"}';;
        *) return 1;;
    esac
}
mc=no
for owned in yes no; do
    : >"$trace"
    statusReporter=''
    if [[ $owned == yes ]]; then
        bash -c 'trap '\''printf "reporter-stopped\\n" >>"$trace"; exit 0'\'' TERM; printf "reporter-ready\\n" >>"$trace"; while :; do sleep 0.01; done' &
        statusReporter=$!
        for _ in {1..100}; do grep -q '^reporter-ready$' "$trace" && break; sleep 0.01; done
        grep -q '^reporter-ready$' "$trace" || fail error_reporter_not_ready
    fi
    result=0
    rootpxe_error_wait_for_retry 'fixture failure' PXEOS_ERROR console_shown || result=$?
    [[ $result == 77 ]] || { printf 'error-wait result=%s\n' "$result" >&2; cat "$trace" >&2; fail error_retry_did_not_reach_exec; }
    if [[ $owned == yes ]]; then before reporter-stopped callback || fail error_callback_preceded_reporter_stop; fi
    before callback permit-reset || fail error_retry_reordered_status_check
    before storage-reset permit-reset || fail old_storage_context_survived_new_attempt
    before permit-reset exec || fail error_retry_reordered_permit_reset
    [[ -z $statusReporter ]] || fail error_retry_retained_reporter_pid
done
printf 'PASS: timeline gate, pending plan, prepare heartbeat, real zero, retry/run isolation and no-copy cases\n'
