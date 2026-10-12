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
awk '/^rootpxe_run_pre_deploy_script / {emit=1} emit' "$download" >"$tmp/write-preparation"
assert before "$tmp/write-preparation" 'rootpxe_run_pre_deploy_script' 'rootpxe_require_unused_target_disks'
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
awk '/^rootpxe_run_pre_deploy_script / {emit=1} emit {print} emit && /^\[\[ \$nombr -ne 1 \]\] && rootpxe_stage prepare_partitions / {exit}' "$download" >"$tmp/normal-write-snippet"
for scenario in matching format_allowed format_failed; do
    trace="$tmp/n-$scenario.trace"; : >"$trace"; status=0
    (
        rootpxe_run_pre_deploy_script() { printf 'prehook\n' >>"$trace"; }
        rootpxe_require_unused_target_disks() { printf 'guard\n' >>"$trace"; }
        enableWriteCache() { printf 'cache\n' >>"$trace"; }
        rootpxe_stage() { :; }
        preparePartitions() { :; }
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
        type=down; imgType=n; mc=no; nombr=0; hd=/dev/mock0; disks=/dev/mock0
        sector_metadata=mock.partitions; originalSchemaFile=mock.schema; deploymentLayoutFile=mock.layout; imagePath=mock.image
        . "$tmp/normal-write-snippet"
    ) || status=$?
    if [[ $scenario == format_failed ]]; then
        assert test "$status" -eq 91
        assert absent "$trace" 'table-write'
        assert absent "$trace" 'boot-write'
    else
        assert test "$status" -eq 0
        assert before "$trace" 'sector-check' 'resolve'
        assert before "$trace" 'resolve' 'table-write'
        [[ $scenario == matching ]] && assert absent "$trace" 'format'
        [[ $scenario == format_allowed ]] && assert before "$trace" 'format' 'table-write'
    fi
done
printf 'Prewrite order: %s checks, %s failures\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
