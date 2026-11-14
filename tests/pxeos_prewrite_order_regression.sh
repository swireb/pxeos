#!/usr/bin/env bash
# 捕获/部署入口及原始写盘函数的预写顺序；仅提取源码片段。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
download="$overlay/bin/pxeos.download"
upload="$overlay/bin/pxeos.upload"
tmp="$(mktemp -d /tmp/pxeos-prewrite-order.XXXXXX)"
case "$tmp" in /tmp/pxeos-prewrite-order.*) ;; *) exit 2 ;; esac
trap 'rm -rf -- "$tmp"' EXIT
failures=0
checks=0
assert() { checks=$((checks + 1)); if "$@"; then return; fi; printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
before() { local a b; a=$(grep -nF "$2" "$1" | head -n 1 | cut -d: -f1 || true); b=$(grep -nF "$3" "$1" | head -n 1 | cut -d: -f1 || true); [[ -n $a && -n $b && $a -lt $b ]]; }
absent() { ! grep -Fq "$2" "$1"; }
sed -n '/^findHDDInfo() {/,/^}/p' "$funcs" >"$tmp/discovery"
assert absent "$tmp/discovery" 'enableWriteCache'
awk '/^rootpxe_bind_granted_deploy_targets / {emit=1} emit' "$download" >"$tmp/write-preparation"
assert before "$tmp/write-preparation" 'rootpxe_bind_granted_deploy_targets' 'rootpxe_require_unused_target_disks'
assert before "$tmp/write-preparation" 'rootpxe_require_unused_target_disks' 'enableWriteCache'
assert before "$tmp/write-preparation" 'enableWriteCache' 'preparePartitions'
assert before "$tmp/write-preparation" 'validateImageSectorSize "$hd" "$sector_metadata"' 'rootpxe_validate_deployment_layout'
assert before "$tmp/write-preparation" 'rootpxe_validate_deployment_layout' 'rootpxe_apply_deployment_layout'
assert before "$upload" 'rootpxe_require_unused_target_disks' '# Do not clear staging'
assert before "$download" 'rootpxe_require_unused_target_disks' 'rootpxe_plan_deploy_disk_operation'
awk '/^if \[\[ \$\{resumeStage/ {emit=1} emit {print} emit && /^fi$/ {exit}' "$download" >"$tmp/resume"
assert absent "$tmp/resume" 'validateImageSectorSize'
assert absent "$tmp/resume" 'enableWriteCache'
assert absent "$tmp/resume" 'rootpxe_require_unused_target_disks'
for function_name in rootpxe_apply_deployment_layout clearPartitionTables rootpxe_nvme_reformat_to_sector_size rootpxe_restore_deployment_boot_code restoreGRUB; do
    sed -n "/^$function_name() {/,/^}/p" "$funcs" >"$tmp/$function_name"
    assert grep -Fq 'rootpxe_require_unused_target_disks' "$tmp/$function_name"
done
sed -n '/^writeImage() /,/^}/p' "$funcs" >"$tmp/writeImage"
assert before "$tmp/writeImage" 'rootpxe_require_unused_target_disks' 'mkfifo /tmp/pigz1'
for function_name in applySfdiskPartitions restoreEBR; do
    sed -n "/^$function_name() {/,/^}/p" "$overlay/usr/share/pxeos/lib/partition-funcs.sh" >"$tmp/$function_name"
    assert grep -Fq 'rootpxe_require_unused_target_disks' "$tmp/$function_name"
done
awk '/^rootpxe_bind_granted_deploy_targets / {emit=1} /^# Build one immutable/ {exit} emit {print}' "$download" >"$tmp/normal-write-snippet"
sed -n '/^preparePartitions() {/,/^}/p' "$download" >"$tmp/preparePartitions"
for scenario in matching format_allowed format_failed skip_fixed fixed multi raw; do
    trace="$tmp/n-$scenario.trace"; : >"$trace"; status=0
    (
        rootpxe_bind_granted_deploy_targets() { printf 'binding\n' >>"$trace"; }
        rootpxe_require_unused_target_disks() { printf 'guard\n' >>"$trace"; }
        enableWriteCache() { printf 'cache\n' >>"$trace"; }
        rootpxe_stage() { printf "%s\n" "$1" >>"$trace"; }
        rootpxe_deployment_identity_policy_enabled(){ return 1; }
        . "$tmp/preparePartitions"
        restorePartitionTablesAndBootLoaders() { printf 'table-write\n' >>"$trace"; }
        runPartprobe() { printf 'readback\n' >>"$trace"; }
        # All paths and tools below are inert fixture values.
        osid=50; imgPartitionType=all; global_gptcheck=0
        rootpxe_mpa_permit_is_batch=no
        handleError() { printf 'error\n' >>"$trace"; exit 91; }
        validateImageSectorSize() {
            printf 'sector-check\n' >>"$trace"
            [[ $scenario == format_failed ]] && handleError format-failed
            [[ $scenario == format_allowed ]] && printf 'format\n' >>"$trace"
            return 0
        }
        rootpxe_validate_deployment_layout() { printf 'resolve\n' >>"$trace"; }
        rootpxe_apply_deployment_layout() { printf 'table-write\n' >>"$trace"; }
        rootpxe_restore_deployment_boot_code() { printf 'boot-write\n' >>"$trace"; }
        rootpxe_console_message() { :; }
        type=down; imgType=n; nombr=0; hd=/dev/mock0; disks=/dev/mock0
        sector_metadata=mock.partitions; originalSchemaFile=mock.schema; deploymentLayoutFile=mock.layout
        imagePath="$tmp/image"
        mkdir -p "$imagePath"
        case $scenario in
            raw) imgType=dd ;;
            skip_fixed) imgType=mps; nombr=1 ;;
            fixed) imgType=mps ;;
            multi) imgType=mpa; disks="/dev/mock0 /dev/mock1" ;;
        esac
        . "$tmp/normal-write-snippet"
        printf 'snapshot:%s\n' "${rootpxe_deploy_plan_stage:-init}" >>"$trace"
    ) || status=$?
    if [[ $scenario == format_failed ]]; then
        assert test "$status" -eq 91
        assert absent "$trace" 'table-write'
        assert absent "$trace" 'boot-write'
        assert absent "$trace" 'prepare_partitions'
    elif [[ $scenario == raw || $scenario == skip_fixed ]]; then
        assert test "$status" -eq 0
        assert absent "$trace" 'partitioning'
        assert grep -Fxq 'snapshot:init' "$trace"
    else
        assert test "$status" -eq 0
        assert before "$trace" 'partitioning' 'table-write'
        assert before "$trace" 'table-write' 'prepare_partitions'
        assert test "$(grep -cFx partitioning "$trace")" -eq 1
        assert grep -Fxq 'snapshot:prepare_partitions' "$trace"
        if [[ $scenario == matching || $scenario == format_allowed ]]; then
            assert before "$trace" 'sector-check' 'resolve'
            assert before "$trace" 'resolve' 'partitioning'
            [[ $scenario != matching ]] || assert absent "$trace" 'format'
            [[ $scenario != format_allowed ]] || assert before "$trace" 'format' 'table-write'
        fi
    fi
done
sed -n '/^rootpxe_partition_progress_send_snapshot() {/,/^}/p' "$funcs" >"$tmp/send-snapshot"
(
    . "$tmp/send-snapshot"
    taskid=41; task_token=abcdef0123456789; mac=001122334455; web=https://invalid.invalid/
    type=down; rootpxe_deploy_plan_stage=prepare_partitions
    printf '{}' >"$tmp/plan.json"
    rootpxe_progress_data_phase_active() { [[ ${active:-no} == yes ]]; }
    rootpxe_task_curl() { printf '%s\n' "$@" >>"$tmp/phase-args"; }
    rootpxe_partition_progress_send_snapshot "$tmp/plan.json"
    active=yes rootpxe_partition_progress_send_snapshot "$tmp/plan.json"
    type=up rootpxe_partition_progress_send_snapshot "$tmp/plan.json"
    grep '^stage=' "$tmp/phase-args" >"$tmp/phases"
    printf 'stage=prepare_partitions\nstage=restore\nstage=init\n' >"$tmp/expected"
)
assert cmp "$tmp/phases" "$tmp/expected"
reporter="$overlay/bin/pxeos.statusreporter"
sed -n '/^rootpxe_progress_report_once() {/,/^}/p' "$reporter" >"$tmp/report-once"
(
    . "$tmp/report-once"
    rootpxe_capture_poll_cancel() { :; }
    rootpxe_progress_data_phase_active() { return 1; }
    rootpxe_progress_send_heartbeat() { printf 'heartbeat\n' >>"$tmp/report"; }
    rootpxe_progress_send_snapshot() { printf 'snapshot\n' >>"$tmp/report"; }
    rootpxe_progress_report_once
)
assert test "$(cat "$tmp/report")" = heartbeat
printf 'Prewrite order: %s checks, %s failures\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
