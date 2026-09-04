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
[[ ${PXEOS_CURL_RC:-0} == 0 ]] || exit "$PXEOS_CURL_RC"
printf '{"success":true}\n'
EOF
chmod +x "$tmp/bin"/*

cat >"$tmp/lsblk.json" <<'JSON'
{"blockdevices":[{"path":"/dev/sda","type":"disk","tran":"sata"},{"path":"/dev/sdb","type":"disk","tran":"sas"},{"path":"/dev/nvme0n1","type":"disk","tran":"nvme"},{"path":"/dev/vda","type":"disk"},{"path":"/dev/nbd0","type":"disk"},{"path":"/dev/loop0","type":"loop"},{"path":"/dev/zram0","type":"disk"},{"path":"/dev/ram0","type":"disk"},{"path":"/dev/md0","type":"disk"},{"path":"/dev/dm-0","type":"lvm"},{"path":"/dev/sr0","type":"rom"}]}
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

PATH="$tmp/bin:$PATH" \
PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_SDB_RC=8 \
PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/health.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/sda /dev/sdb /dev/nvme0n1 >"$2"
jq -e '.version == 1 and (.disks|length) == 3' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "sata") | .status == "healthy" and .smartPassed == true and .temperatureC == 35 and .powerOnHours == 123' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "sas") | .status == "failed" and .reallocatedSectors == "9"' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "nvme") | .status == "warning" and .percentageUsed == 101 and .availableSpare == 91 and .mediaErrors == "18446744073709551615"' "$2" >/dev/null
jq -e '[.disks[].transport] | index("unknown") | not' "$2" >/dev/null
[[ $(wc -c <"$2") -le 131072 ]]
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
rootpxe_collect_disk_health /dev/sda /dev/sdb /dev/nvme0n1 >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown"' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDA_RC=124 PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_SDB_RC=124 PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_SMART_NVME_RC=124 PXEOS_NVME_JSON="$tmp/nvme.json" PXEOS_NVME_RC=124 \
bash -s -- "$library" "$tmp/tool-timed-out.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/sda /dev/sdb /dev/nvme0n1 >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "unknown" and (.message | contains("timed out"))' "$2" >/dev/null
EOF

cat >"$tmp/nvme-critical.json" <<'JSON'
{"critical_warning":1,"temperature":305}
JSON
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme-critical.json" PXEOS_NVME_RC=2 \
bash -s -- "$library" "$tmp/nvme-nonzero.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/nvme0n1 >"$2"
jq -e '.disks[] | select(.transport == "nvme") | .status == "failed" and .criticalWarning == 1' "$2" >/dev/null
EOF

# A health report must be based on an actual task disk.  Calling the helper
# without one neither queries lsblk nor uploads an empty report that would
# replace a previous task snapshot.
: >"$tmp/curl-empty.args"
: >"$tmp/lsblk-empty.args"
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_LSBLK_ARGS="$tmp/lsblk-empty.args" PXEOS_CURL_ARGS="$tmp/curl-empty.args" \
bash -s -- "$library" <<'EOF'
set -euo pipefail
. "$1"
taskType=deploy; taskid=7; task_token=token; mac='aa:bb:cc:dd:ee:ff'; rootpxe_api='https://example.invalid/service/'
rootpxe_require_task_context() { return 0; }
rootpxe_send_disk_health
EOF
[[ ! -s $tmp/curl-empty.args ]] || fail 'missing task disk uploaded an empty report'
[[ ! -s $tmp/lsblk-empty.args ]] || fail 'missing task disk enumerated disks'

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/budget.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_disk_health_budget_seconds=0
rootpxe_collect_disk_health /dev/sda /dev/sdb /dev/nvme0n1 >"$2"
jq -e '(.disks|length) == 3 and all(.disks[]; .status == "unknown" and (.message | contains("time limit")))' "$2" >/dev/null
EOF

PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/smart-history.json" PXEOS_SMART_SDA_RC=128 PXEOS_SMART_SDB="$tmp/sas-warning.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/sas-and-history.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/sda /dev/sdb /dev/nvme0n1 >"$2"
jq -e '.disks[] | select(.transport == "sata") | .status == "warning"' "$2" >/dev/null
jq -e '.disks[] | select(.transport == "sas") | .status == "warning" and (.message | contains("SAS error counters"))' "$2" >/dev/null
EOF

cat >"$tmp/invalid-smart.json" <<'EOF'
not json
EOF
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_SMART_SDA="$tmp/invalid-smart.json" PXEOS_SMART_SDB="$tmp/invalid-smart.json" PXEOS_SMART_NVME="$tmp/invalid-smart.json" PXEOS_NVME_JSON="$tmp/invalid-smart.json" \
bash -s -- "$library" "$tmp/unknown.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/sda /dev/sdb /dev/nvme0n1 >"$2"
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
rootpxe_send_disk_health /dev/sda /dev/sdb /dev/nvme0n1
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
rootpxe_send_disk_health /dev/sda /dev/sdb /dev/nvme0n1
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
rootpxe_send_disk_health /dev/sda /dev/sdb /dev/nvme0n1
task_continued=1
[[ $task_continued == 1 ]]
EOF
[[ ! -s $tmp/curl-invalid-lsblk.args ]] || fail 'malformed lsblk replaced a prior health report with an empty report'

# Explicit selections work no matter whether the task primary disk is SATA or
# NVMe, and only selected disks are queried.  NBD is deliberately present in
# lsblk above but must remain untouched.
: >"$tmp/tool-trace"
: >"$tmp/lsblk-selected.args"
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_LSBLK_ARGS="$tmp/lsblk-selected.args" PXEOS_TOOL_TRACE="$tmp/tool-trace" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_SMART_SDB="$tmp/smart-sdb.json" PXEOS_SMART_NVME="$tmp/smart-nvme.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/selected.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/nvme0n1 /dev/nvme0n1 /dev/sda >"$2"
jq -e '(.disks | length) == 2 and ([.disks[].device] | sort) == ["/dev/nvme0n1", "/dev/sda"]' "$2" >/dev/null
jq -e '.disks[] | select(.device == "/dev/nvme0n1") | .transport == "nvme" and .status == "warning"' "$2" >/dev/null
jq -e '.disks[] | select(.device == "/dev/sda") | .transport == "sata" and .status == "healthy"' "$2" >/dev/null
EOF
grep -Fxq 'smartctl:/dev/nvme0n1' "$tmp/tool-trace" || fail 'selected NVMe was not read'
grep -Fxq 'nvme:/dev/nvme0n1' "$tmp/tool-trace" || fail 'selected NVMe did not use nvme-cli'
grep -Fxq 'smartctl:/dev/sda' "$tmp/tool-trace" || fail 'selected SATA disk was not read'
! grep -Fq '/dev/sdb' "$tmp/tool-trace" || fail 'unselected SATA/SAS disk was read'
! grep -Fq '/dev/nbd0' "$tmp/tool-trace" || fail 'unselected NBD disk was read'
grep -Fq '/dev/nvme0n1' "$tmp/lsblk-selected.args" || fail 'selected NVMe was not passed to lsblk'
grep -Fq '/dev/sda' "$tmp/lsblk-selected.args" || fail 'selected SATA disk was not passed to lsblk'
! grep -Fq '/dev/nbd0' "$tmp/lsblk-selected.args" || fail 'NBD was passed to lsblk'

# A selected virtual/SCSI disk may omit TRAN.  Scope still comes from the
# task; preserve the existing SMART attempt instead of silently skipping it.
: >"$tmp/unknown-transport-trace"
PATH="$tmp/bin:$PATH" PXEOS_LSBLK_JSON="$tmp/lsblk.json" PXEOS_TOOL_TRACE="$tmp/unknown-transport-trace" PXEOS_SMART_SDA="$tmp/smart-sda.json" PXEOS_NVME_JSON="$tmp/nvme.json" \
bash -s -- "$library" "$tmp/unknown-transport.json" <<'EOF'
set -euo pipefail
. "$1"
rootpxe_collect_disk_health /dev/vda >"$2"
jq -e '(.disks | length) == 1 and .disks[0].device == "/dev/vda" and .disks[0].transport == "unknown" and .disks[0].status == "healthy"' "$2" >/dev/null
EOF
grep -Fxq 'smartctl:/dev/vda' "$tmp/unknown-transport-trace" || fail 'selected unknown-transport disk skipped smartctl'
! grep -Fq 'nvme:/dev/vda' "$tmp/unknown-transport-trace" || fail 'unknown transport incorrectly used nvme-cli'

upload="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
download="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.download"
! grep -Fq 'rootpxe_send_disk_health' "$checkin" || fail 'checkin still reports disk health before disk selection'
grep -Fq 'rootpxe_send_disk_health "${rootpxe_capture_disks[@]}"' "$upload" || fail 'mpa capture does not report filtered source disks'
grep -Fq 'rootpxe_send_disk_health "$hd"' "$upload" || fail 'single capture does not report its source disk'
grep -Fq 'rootpxe_send_disk_health "${rootpxe_task_disks[@]}"' "$download" || fail 'mpa deployment does not report mapped target disks'
grep -Fq 'rootpxe_send_disk_health "$hd"' "$download" || fail 'single deployment does not report its target disk'

# Run the real top-level selection fragments with harmless stubs.  A single
# task must keep using hd even when another disk appears first in the broader
# discovery list; mpa receives only its already mapped/capture-filtered set.
upload_health_block="$tmp/upload-health.sh"
awk '/^findHDDInfo$/ { copy=1 } copy && /^# Do not clear staging/ { exit } copy { print }' "$upload" >"$upload_health_block"
[[ -s $upload_health_block ]] || fail 'capture health selection block missing'
: >"$tmp/upload-health-events"
for selected_type in n N mps dd; do
    case "$selected_type" in n|mps) selected_disk=/dev/sda ;; *) selected_disk=/dev/nvme0n1 ;; esac
    (
        imgType="$selected_type" hd="$selected_disk" disks='/dev/sda /dev/nbd0'
        findHDDInfo(){ :; }
        rootpxe_send_disk_health(){ printf '%s:%s\n' "$imgType" "$*" >>"$tmp/upload-health-events"; return 1; }
        . "$upload_health_block"
        capture_continued=1
        [[ $capture_continued == 1 ]]
    )
done
[[ $(<"$tmp/upload-health-events") == $'n:/dev/sda\nN:/dev/nvme0n1\nmps:/dev/sda\ndd:/dev/nvme0n1' ]] || fail 'single capture did not use hd or health failure gated capture'
: >"$tmp/upload-health-events"
(
    imgType=mpa hd=/dev/sda disks='/dev/sda /dev/nbd0 /dev/nvme0n1'
    findHDDInfo(){ :; }
    getPartitions(){ [[ $1 == /dev/nbd0 ]] && parts= || parts="${1}p1"; }
    rootpxe_send_disk_health(){ printf 'mpa:%s\n' "$*" >>"$tmp/upload-health-events"; }
    . "$upload_health_block"
)
[[ $(<"$tmp/upload-health-events") == 'mpa:/dev/sda /dev/nvme0n1' ]] || fail 'mpa capture included a non-partitioned disk'

download_health_block="$tmp/download-health.sh"
awk '/^findHDDInfo$/ { copy=1 } copy && /^sector_metadata=/ { exit } copy { print }' "$download" >"$download_health_block"
[[ -s $download_health_block ]] || fail 'deployment health selection block missing'
: >"$tmp/download-health-events"
for selected_type in n N mps dd; do
    case "$selected_type" in n|mps) selected_disk=/dev/sda ;; *) selected_disk=/dev/nvme0n1 ;; esac
    (
        imgType="$selected_type" hd="$selected_disk" disks='/dev/sda /dev/nbd0'
        findHDDInfo(){ :; }
        rootpxe_send_disk_health(){ printf '%s:%s\n' "$imgType" "$*" >>"$tmp/download-health-events"; return 1; }
        . "$download_health_block"
        deploy_continued=1
        [[ $deploy_continued == 1 ]]
    )
done
[[ $(<"$tmp/download-health-events") == $'n:/dev/sda\nN:/dev/nvme0n1\nmps:/dev/sda\ndd:/dev/nvme0n1' ]] || fail 'single deployment did not use hd or health failure gated deployment'
: >"$tmp/download-health-events"
(
    imgType=mpa hd=/dev/sdb disks='/dev/sdb /dev/nvme0n1'
    findHDDInfo(){ :; }
    rootpxe_send_disk_health(){ printf 'mpa:%s\n' "$*" >>"$tmp/download-health-events"; }
    . "$download_health_block"
)
[[ $(<"$tmp/download-health-events") == 'mpa:/dev/sdb /dev/nvme0n1' ]] || fail 'mpa deployment did not use mapped target set'
printf 'PASS: PXEOS disk health regression\n'
