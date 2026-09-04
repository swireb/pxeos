#!/usr/bin/env bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='/dev/'

root="$(cd "$(dirname "$0")/.." && pwd)"
library="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/disk-health.sh"
checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $library ]] || fail 'missing disk health library'
mkdir -p "$tmp/bin"
cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${PXEOS_TIMEOUT_RC:-0} == 0 ]] || exit "$PXEOS_TIMEOUT_RC"
[[ ${1:-} == -k ]] && shift 2
shift
"$@"
EOF
cat >"$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
[[ -z ${PXEOS_LSBLK_ARGS:-} ]] || printf '%s\n' "$*" >>"$PXEOS_LSBLK_ARGS"
cat "$PXEOS_LSBLK_JSON"
EOF
cat >"$tmp/bin/smartctl" <<'EOF'
#!/usr/bin/env bash
device="${!#}"
[[ -z ${PXEOS_TOOL_TRACE:-} ]] || printf 'smartctl:%s\n' "$device" >>"$PXEOS_TOOL_TRACE"
case "$device" in
  /dev/sda|*/Harddisk0/Partition0) cat "$PXEOS_SMART_SDA"; exit "${PXEOS_SMART_SDA_RC:-0}" ;;
  /dev/vda|*/Harddisk2/Partition0) cat "$PXEOS_SMART_SDA"; exit "${PXEOS_SMART_SDA_RC:-0}" ;;
  /dev/sdb|*/Harddisk1/Partition0) cat "$PXEOS_SMART_SDB"; exit "${PXEOS_SMART_SDB_RC:-0}" ;;
  /dev/nvme0n1|*/nvme0n1) cat "$PXEOS_SMART_NVME"; exit "${PXEOS_SMART_NVME_RC:-0}" ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/bin/nvme" <<'EOF'
#!/usr/bin/env bash
[[ -z ${PXEOS_TOOL_TRACE:-} ]] || printf 'nvme:%s\n' "${!#}" >>"$PXEOS_TOOL_TRACE"
cat "$PXEOS_NVME_JSON"
exit "${PXEOS_NVME_RC:-0}"
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PXEOS_CURL_ARGS"
[[ -z ${PXEOS_EVENT_TRACE:-} ]] || printf 'inventory\n' >>"$PXEOS_EVENT_TRACE"
[[ ${PXEOS_CURL_RC:-0} == 0 ]] || exit "$PXEOS_CURL_RC"
printf '{"success":true}\n'
EOF
chmod +x "$tmp/bin"/*

cat >"$tmp/lsblk.json" <<'JSON'
{"blockdevices":[{"path":"/dev/sda","type":"disk","tran":"sata","size":1000},{"path":"/dev/sda1","type":"part","size":900},{"path":"/dev/nbd0","type":"disk","size":1000},{"path":"/dev/sdb","type":"disk","tran":"sas","size":"2000"},{"path":"/dev/nvme0n1","type":"disk","tran":"nvme","size":3000},{"path":"/dev/vda","type":"disk","size":4000},{"path":"/dev/loop0","type":"loop","size":1000},{"path":"/dev/zram0","type":"disk","size":1000},{"path":"/dev/ram0","type":"disk","size":1000},{"path":"/dev/md0","type":"disk","size":1000},{"path":"/dev/dm-0","type":"disk","size":1000},{"path":"/dev/mapper/vg0","type":"disk","size":1000},{"path":"/dev/sr0","type":"disk","size":1000},{"path":"/dev/mmcblk0boot0","type":"disk","size":1000},{"path":"/dev/sdc","type":"disk","tran":"sata","size":0},{"path":"/dev/sda","type":"disk","tran":"sata","size":1000}]}
JSON
cat >"$tmp/smart-sda.json" <<'JSON'
{"model_name":"SATA model","serial_number":"SATA serial","smart_status":{"passed":true},"temperature":{"current":35},"power_on_time":{"hours":123},"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":0}},{"id":197,"raw":{"value":0}},{"id":198,"raw":{"value":0}}]}}
JSON
cat >"$tmp/smart-sdb.json" <<'JSON'
{"model_name":"SAS model","serial_number":"SAS serial","smart_status":{"passed":false},"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":9}}]}}
JSON
cat >"$tmp/smart-nvme.json" <<'JSON'
{"model_name":"NVMe model","serial_number":"NVMe serial","smart_status":{"passed":true}}
JSON
cat >"$tmp/nvme.json" <<'JSON'
{"critical_warning":0,"temperature":305,"avail_spare":91,"percent_used":101,"media_errors":18446744073709551615,"power_on_hours":42}
JSON
cat >"$tmp/sas-warning.json" <<'JSON'
{"scsi_vendor":"SAS","scsi_product":"disk","smart_status":{"passed":true},"scsi_grown_defect_list":0,"scsi_error_counter_log":{"read":{"total_uncorrected_errors":3},"write":{"total_uncorrected_errors":0},"verify":{"total_uncorrected_errors":0}},"scsi_non_medium_error_count":0}
JSON
cat >"$tmp/smart-history.json" <<'JSON'
{"smartctl":{"exit_status":128},"smart_status":{"passed":true}}
JSON
cat >"$tmp/sata-smart-unavailable.json" <<'JSON'
{"smartctl":{"version":[7,5],"exit_status":4},"device":{"name":"/dev/sda","info_name":"/dev/sda [SAT]","type":"sat","protocol":"ATA"},"model_name":"VMware Virtual IDE Hard Drive","serial_number":"00000000000000000001","smart_support":{"available":false}}
JSON
cat >"$tmp/sata-smart-disabled.json" <<'JSON'
{"model_name":"SATA model","smart_support":{"available":true,"enabled":false}}
JSON
cat >"$tmp/sata-smart-no-conclusion.json" <<'JSON'
{"model_name":"SATA model","serial_number":"SATA serial"}
JSON

PATH="$tmp/bin:$PATH" \
PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_SDB_RC=8 \
PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/health.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.version == 1 and (.disks|length) == 4 and [.disks[].device] == ["/dev/sda", "/dev/sdb", "/dev/nvme0n1", "/dev/vda"]' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "sata") | .status == "healthy" and .smartPassed == true and .temperatureC == 35 and .powerOnHours == 123' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "sas") | .status == "failed" and .reallocatedSectors == "9"' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "nvme") | .status == "warning" and .percentageUsed == 101 and .availableSpare == 91 and .mediaErrors == "18446744073709551615"' "$2" >/dev/null
jq -e '.disks[] | select(.device == "/dev/vda") | .transport == "unknown" and .status == "healthy"' "$2" >/dev/null
[[ $(wc -c <"$2") -le 131072 ]]
EOF

# VMware virtual ATA/SATA disks can identify as SATA in lsblk and still omit
# SMART health evidence. They remain unknown with an actionable reason; they
# are never guessed healthy or probed with a forced ATA device type.
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/sata-smart-unavailable.json" PXEOS_SMART_SDA_RC=4 PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/sata-smart-unavailable-health.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown" and .model == "VMware Virtual IDE Hard Drive" and (.message | contains("设备未提供可用的 SMART 支持")) and (.message | contains("SMART 读取失败"))' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/sata-smart-disabled.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/sata-smart-disabled-health.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown" and (.message | contains("SMART 未启用"))' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/sata-smart-no-conclusion.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/sata-smart-no-conclusion-health.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown" and (.message | contains("SMART 未提供健康结论"))' "$2" >/dev/null
EOF

# Missing smartctl, a timeout exit, and an NVMe command failure with usable
# failure evidence must all be represented as unknown/failed records, never a
# false healthy result or a task failure.
mkdir -p "$tmp/no-smart"
cp "$tmp/bin/lsblk" "$tmp/bin/nvme" "$tmp/bin/timeout" "$tmp/no-smart/"
PATH="$tmp/no-smart:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/missing-smart.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown"' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDA_RC=124 PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_SDB_RC=124 PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_SMART_NVME_RC=124 PXEOS_NVME_JSON="$tmp/nvme.json" PXEOS_NVME_RC=124 \
bash -s -- "$library" "$tmp/tool-timed-out.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown" and (.message | contains("SMART 超时"))' "$2" >/dev/null
EOF

cat >"$tmp/nvme-critical.json" <<'JSON'
{"critical_warning":1,"temperature":305}
JSON
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme-critical.json" PXEOS_NVME_RC=2 \
bash -s -- "$library" "$tmp/nvme-nonzero.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "nvme") | .status == "failed" and .criticalWarning == 1' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/budget.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_disk_health_budget_seconds=0
rootpxe_collect_disk_health >"$2"
jq -e '(.disks|length) == 4 and all(.disks[]; .status == "unknown" and (.message | contains("time limit")))' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-history.json" PXEOS_SMART_SDA_RC=128 PXEOS_SMART_SDB="$tmp/sas-warning.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/sas-and-history.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "warning"' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "sas") | .status == "warning" and (.message | contains("SAS 错误计数非零"))' "$2" >/dev/null
EOF

cat >"$tmp/invalid-smart.json" <<'EOF'
not json
EOF
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/invalid-smart.json" PXEOS_SMART_SDB="$tmp/invalid-smart.json" PXEOS_SMART_NVME="$tmp/invalid-smart.json" PXEOS_NVME_JSON="$tmp/invalid-smart.json" \
bash -s -- "$library" "$tmp/unknown.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown" and (.message | type == "string")' "$2" >/dev/null
EOF

for task_type in deploy capture; do
    : >"$tmp/curl-$task_type.args"
    PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" PXEOS_CURL_ARGS="$tmp/curl-$task_type.args" \
    bash -s -- "$library" "$task_type" <<'EOF'
set -euo pipefail
. "$1"
taskType="$2"; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { [[ $taskid == 7 && $task_token == token ]]; }
rootpxe_send_disk_health
EOF
    grep -Fqx -- 'diskHealth={"version":1,"disks"' "$tmp/curl-$task_type.args" && fail 'curl mock unexpectedly split JSON'
    grep -Fq -- 'diskHealth=' "$tmp/curl-$task_type.args" || fail "$task_type did not upload diskHealth"
    grep -Fqx -- 'mac=aa:bb:cc:dd:ee:ff' "$tmp/curl-$task_type.args" || fail "$task_type did not use task MAC"
    tail -n 1 "$tmp/curl-$task_type.args" | grep -Fq '/inventory' || fail "$task_type used wrong endpoint"
done

# A collection or upload failure is informational only.  It cannot introduce
# a task gate for either task type.
for task_type in deploy capture; do
    : >"$tmp/curl-failure-$task_type.args"
    PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" PXEOS_CURL_ARGS="$tmp/curl-failure-$task_type.args" PXEOS_CURL_RC=28 \
    bash -s -- "$library" "$task_type" <<'EOF'
set -euo pipefail
. "$1"
taskType="$2"; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
rootpxe_send_disk_health
task_continued=1
[[ $task_continued == 1 ]]
EOF
done

: >"$tmp/curl-invalid-lsblk.args"
printf 'not json\n' >"$tmp/invalid-lsblk.json"
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/invalid-lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" PXEOS_CURL_ARGS="$tmp/curl-invalid-lsblk.args" \
bash -s -- "$library" <<'EOF'
set -euo pipefail
. "$1"
taskType=deploy; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
if rootpxe_send_disk_health; then
    false
else
    [[ $? -eq 1 ]]
fi
task_continued=1
[[ $task_continued == 1 ]]
EOF
[[ ! -s $tmp/curl-invalid-lsblk.args ]] || fail 'malformed lsblk replaced a prior health report with an empty report'

# Every recognized physical disk is reported in lsblk order.  The task's
# selected source/target must not narrow this snapshot; NBD and other
# pseudo-devices never reach SMART or nvme-cli.
: >"$tmp/tool-trace"
: >"$tmp/lsblk-all.args"
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_LSBLK_ARGS="$tmp/lsblk-all.args" PXEOS_TOOL_TRACE="$tmp/tool-trace" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/all-disks.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health >"$2"
jq -e '(.disks | length) == 4 and [.disks[].device] == ["/dev/sda", "/dev/sdb", "/dev/nvme0n1", "/dev/vda"]' "$2" >/dev/null
jq -e '.disks[] | select(.device == "/dev/nvme0n1") | .transport == "nvme" and .status == "warning"' "$2" >/dev/null
jq -e '.disks[] | select(.device == "/dev/sda") | .transport == "sata" and .status == "healthy"' "$2" >/dev/null
EOF
grep -Fxq 'smartctl:/dev/nvme0n1' "$tmp/tool-trace" || fail 'NVMe was not read'
grep -Fxq 'nvme:/dev/nvme0n1' "$tmp/tool-trace" || fail 'NVMe did not use nvme-cli'
grep -Fxq 'smartctl:/dev/sda' "$tmp/tool-trace" || fail 'SATA disk was not read'
grep -Fxq 'smartctl:/dev/sdb' "$tmp/tool-trace" || fail 'SAS disk was not read'
grep -Fxq 'smartctl:/dev/vda' "$tmp/tool-trace" || fail 'virtual disk without TRAN was not read'
! grep -Fq '/dev/nbd0' "$tmp/tool-trace" || fail 'NBD was read'
! grep -Fq '/dev/mapper/vg0' "$tmp/tool-trace" || fail 'device-mapper was read'
! grep -Fq '/dev/sdc' "$tmp/tool-trace" || fail 'zero-size disk was read'
grep -Fq -- '--bytes' "$tmp/lsblk-all.args" || fail 'lsblk did not request numeric disk sizes'

# The actual post-checkin wrapper turns only a successful empty enumeration
# into the existing task-error path.  The empty snapshot must reach inventory
# before handleError, even when that upload itself fails.
checkin_health_block="$tmp/checkin-health.sh"
awk '/^rootpxe_report_disk_health_after_checkin\(\)/ { copy=1 } copy { print } copy && /^}/ { exit }' "$checkin" >"$checkin_health_block"
[[ -s $checkin_health_block ]] || fail 'post-checkin health wrapper missing'
cat >"$tmp/no-disks.json" <<'JSON'
{"blockdevices":[{"path":"/dev/nbd0","type":"disk","size":1000},{"path":"/dev/sdc","type":"disk","size":0},{"path":"/dev/loop0","type":"loop","size":1000}]}
JSON
: >"$tmp/empty-events"
: >"$tmp/curl-empty.args"
set +e
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/no-disks.json" PXEOS_CURL_ARGS="$tmp/curl-empty.args" PXEOS_EVENT_TRACE="$tmp/empty-events" \
bash -s -- "$library" "$checkin_health_block" "$tmp/empty-events" <<'EOF'
set -euo pipefail
. "$1"
. "$2"
taskType=deploy; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
event_file="$3"
handleError() { printf 'error\n' >>"$event_file"; return 77; }
rootpxe_report_disk_health_after_checkin
EOF
empty_status=$?
set -e
[[ $empty_status -eq 77 ]] || fail 'confirmed no-disk did not enter the task error path'
[[ $(<"$tmp/empty-events") == $'inventory\nerror' ]] || fail 'empty disk report was not uploaded before task error'
grep -Fq -- 'diskHealth={"version":1,"disks":[]}' "$tmp/curl-empty.args" || fail 'empty physical disk report was not uploaded'

: >"$tmp/empty-upload-failure-events"
: >"$tmp/curl-empty-upload-failure.args"
set +e
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/no-disks.json" PXEOS_CURL_ARGS="$tmp/curl-empty-upload-failure.args" PXEOS_EVENT_TRACE="$tmp/empty-upload-failure-events" PXEOS_CURL_RC=28 \
bash -s -- "$library" "$checkin_health_block" "$tmp/empty-upload-failure-events" <<'EOF'
set -euo pipefail
. "$1"
. "$2"
taskType=capture; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
event_file="$3"
handleError() { printf 'error\n' >>"$event_file"; return 77; }
rootpxe_report_disk_health_after_checkin
EOF
empty_upload_failure_status=$?
set -e
[[ $empty_upload_failure_status -eq 77 ]] || fail 'no-disk capture did not fail after health upload failure'
[[ $(<"$tmp/empty-upload-failure-events") == $'inventory\nerror' ]] || fail 'no-disk upload failure did not precede task error'
grep -Fq -- 'diskHealth={"version":1,"disks":[]}' "$tmp/curl-empty-upload-failure.args" || fail 'failed empty-report upload did not attempt the snapshot'

# A failed enumeration remains informational and never masquerades as no disk.
: >"$tmp/invalid-events"
: >"$tmp/curl-invalid-enumeration.args"
set +e
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/invalid-lsblk.json" PXEOS_CURL_ARGS="$tmp/curl-invalid-enumeration.args" PXEOS_EVENT_TRACE="$tmp/invalid-events" \
bash -s -- "$library" "$checkin_health_block" "$tmp/invalid-events" <<'EOF'
set -euo pipefail
. "$1"
. "$2"
taskType=capture; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
event_file="$3"
handleError() { printf 'error\n' >>"$event_file"; return 77; }
rootpxe_report_disk_health_after_checkin
EOF
invalid_status=$?
set -e
[[ $invalid_status -eq 0 ]] || fail 'invalid lsblk incorrectly failed the task'
[[ ! -s $tmp/invalid-events ]] || fail 'invalid lsblk incorrectly called inventory or task error'
[[ ! -s $tmp/curl-invalid-enumeration.args ]] || fail 'invalid lsblk uploaded an empty report'

cat >"$tmp/missing-size-lsblk.json" <<'JSON'
{"blockdevices":[{"path":"/dev/sda","type":"disk"}]}
JSON
cat >"$tmp/malformed-node-lsblk.json" <<'JSON'
{"blockdevices":[{}]}
JSON
for malformed_lsblk in "$tmp/missing-size-lsblk.json" "$tmp/malformed-node-lsblk.json"; do
    : >"$tmp/malformed-events"
    : >"$tmp/curl-malformed.args"
    set +e
    PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$malformed_lsblk" PXEOS_CURL_ARGS="$tmp/curl-malformed.args" PXEOS_EVENT_TRACE="$tmp/malformed-events" \
    bash -s -- "$library" "$checkin_health_block" "$tmp/malformed-events" <<'EOF'
set -euo pipefail
. "$1"
. "$2"
taskType=deploy; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
event_file="$3"
handleError() { printf 'error\n' >>"$event_file"; return 77; }
rootpxe_report_disk_health_after_checkin
EOF
    malformed_status=$?
    set -e
    [[ $malformed_status -eq 0 ]] || fail 'malformed lsblk node incorrectly failed the task'
    [[ ! -s $tmp/malformed-events ]] || fail 'malformed lsblk node incorrectly called inventory or task error'
    [[ ! -s $tmp/curl-malformed.args ]] || fail 'malformed lsblk node uploaded an empty report'
done

# A valid nonempty enumeration whose per-disk serialization fails is not an
# empty host. It must neither upload [] nor enter the task-error path.
: >"$tmp/serialization-events"
: >"$tmp/curl-serialization.args"
set +e
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_CURL_ARGS="$tmp/curl-serialization.args" PXEOS_EVENT_TRACE="$tmp/serialization-events" \
bash -s -- "$library" "$checkin_health_block" "$tmp/serialization-events" <<'EOF'
set -euo pipefail
. "$1"
. "$2"
taskType=capture; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
rootpxe_disk_health_collect_disk() { return 1; }
rootpxe_disk_health_unknown_record() { return 1; }
event_file="$3"
handleError() { printf 'error\n' >>"$event_file"; return 77; }
rootpxe_report_disk_health_after_checkin
EOF
serialization_status=$?
set -e
[[ $serialization_status -eq 0 ]] || fail 'per-disk serialization failure incorrectly failed the task'
[[ ! -s $tmp/serialization-events ]] || fail 'per-disk serialization failure incorrectly called inventory or task error'
[[ ! -s $tmp/curl-serialization.args ]] || fail 'per-disk serialization failure uploaded an empty report'

# The top-level task scripts no longer narrow health reporting after source or
# target selection, so every capture/deploy image type uses the same snapshot.
upload="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
download="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.download"
! grep -Fq 'rootpxe_send_disk_health' "$upload" || fail 'capture still narrows disk health to selected disks'
! grep -Fq 'rootpxe_send_disk_health' "$download" || fail 'deployment still narrows disk health to selected disks'
printf 'PASS: PXEOS disk health regression\n'
