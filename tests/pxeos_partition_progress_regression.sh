#!/usr/bin/env bash
# 分区进度离线回归：只抽取遥测辅助函数并以临时目录模拟块设备，绝不写真实磁盘。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
reporter="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.statusreporter"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got=$1 expected=$2)"; }
# The reporter's live capture updates must not masquerade as upload completion;
# only completeTasking emits the latter after artifacts have finished.
grep -Fq 'up|[Uu][Pp]) prog_stage=capture ;;' "$reporter" || fail 'capture reporter stage is incorrect'
! grep -Fq 'up|[Uu][Pp]) prog_stage=upload_complete ;;' "$reporter" || fail 'live capture still reports upload_complete'
grep -Fq 'rootpxe_progress_heartbeat_active_item' "$reporter" || fail 'active v2 heartbeat is missing'
grep -Fq '(.sequence=(.sequence+1))' "$reporter" || fail 'heartbeat must advance only the active item sequence'
grep -Fq '[[ -n ${active_key:-} && -r $snapshot_file ]] || return 1' "$reporter" || fail 'inactive snapshots must not send a synthetic heartbeat'

# Keep the test isolated although the production helpers intentionally use the
# fixed PXEOS runtime paths.  The extracted body is otherwise byte-for-byte.
awk '/^rootpxe_partition_progress_initialize_runtime\(\)/ { copy=1 } /^REG_LOCAL_MACHINE_XP=/ { exit } copy { print }' "$funcs" |
    sed -e "s#/tmp/pxeos.partition-progress.json#$tmp/snapshot.json#g" \
        -e "s#/tmp/pxeos.partition-progress.events#$tmp/events#g" \
        -e 's/{16,512}/+/g' >"$tmp/progress-functions.sh"
# shellcheck source=/dev/null
. "$tmp/progress-functions.sh"

getPartitions() { parts='/dev/vda1 /dev/vda2'; }
getPartitionNumber() {
    case $1 in /dev/vda1) part_number=1 ;; /dev/vda2) part_number=2 ;; *) return 1 ;; esac
}
blockdev() {
    [[ $1 == --getsize64 ]] || return 1
    case $2 in /dev/vda1) printf '999\n' ;; /dev/vda2) printf '9999\n' ;; *) return 1 ;; esac
}
blkid() {
    case "${*: -1}" in /dev/vda1) printf 'ext4\n' ;; /dev/vda2) printf 'swap\n' ;; *) return 1 ;; esac
}

rootpxe_partition_progress_enabled=yes
progress_attempt=1
taskid=9
rootpxe_partition_progress_initialize_runtime
cat >"$tmp/schema.json" <<'EOF'
{"logicalSectorBytes":512,"partitions":[{"number":1,"originalSectors":2,"fs":"ext4","role":"data"},{"number":2,"originalSectors":99,"fs":"swap","role":"swap"}]}
EOF
originalSchemaFile="$tmp/schema.json"
parts=outer_parts
part_number=77
rootpxe_partition_progress_plan_disk /dev/vda 1
assert_eq "$parts" outer_parts 'plan_disk must not leak getPartitions globals into the imaging flow'
assert_eq "$(jq -r '.items|length' "$tmp/snapshot.json")" 2 'physical plan must include every partition'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.weightBytes' "$tmp/snapshot.json")" 1024 'plan must retain source schema weight after target growth'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.kind' "$tmp/snapshot.json")" swap 'swap must be represented as metadata'
imgPartitionType=1
rootpxe_partition_progress_plan_disk /dev/vda 1
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.status' "$tmp/snapshot.json")" skipped 'unselected partitions must not remain pending in the immutable plan'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.message' "$tmp/snapshot.json")" '未选择此分区' 'unselected partitions need an explicit reason'
imgPartitionType=all
# The immutable n schema is authoritative on an empty deployment target.  Swap
# has no payload and therefore must not contribute target-size weight.
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.filesystem' "$tmp/snapshot.json")" swap 'schema swap filesystem must not depend on target blkid'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.kind' "$tmp/snapshot.json")" swap 'schema swap must use metadata item kind'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.weightBytes' "$tmp/snapshot.json")" 0 'schema swap must not count as payload weight'

# Capture has no trustworthy pre-capture image metadata.  Even if a stale
# image path/schema exists, the source block devices supply both identity and
# capacity; 1 GiB and 99 GiB must not collapse to equal weights.
mkdir -p "$tmp/stale-image"
printf '2 stale-swap\n' >"$tmp/stale-image/d1.original.swapuuids"
cat >"$tmp/stale-image/d1.partitions" <<'EOF'
label: dos
sector-size: 512
/dev/old1 : start=2048, size=4, type=82
/dev/old2 : start=4096, size=4, type=82
EOF
cat >"$tmp/stale-schema.json" <<'EOF'
{"logicalSectorBytes":512,"partitions":[{"number":1,"originalSectors":4,"fs":"swap","role":"swap"},{"number":2,"originalSectors":4,"fs":"swap","role":"swap"}]}
EOF
imagePath="$tmp/stale-image"; originalSchemaFile="$tmp/stale-schema.json"; type=up; imgType=n
getPartitions() { parts='/dev/source1 /dev/source2'; }
getPartitionNumber() { case $1 in /dev/source1) part_number=1 ;; /dev/source2) part_number=2 ;; *) return 1 ;; esac; }
blockdev() { [[ $1 == --getsize64 ]] || return 1; case $2 in /dev/source1) printf '1073741824\n' ;; /dev/source2) printf '106300440576\n' ;; *) return 1 ;; esac; }
blkid() { case "${*: -1}" in /dev/source1) printf 'ext4\n' ;; /dev/source2) printf 'xfs\n' ;; *) return 1 ;; esac; }
getPartType() { parttype=83; }
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disk /dev/source 1
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.weightBytes' "$tmp/snapshot.json")" 1073741824 'capture plan must weight the current 1GiB source partition'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.weightBytes' "$tmp/snapshot.json")" 106300440576 'capture plan must weight the current 99GiB source partition'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.filesystem' "$tmp/snapshot.json")" ext4 'capture plan must ignore stale schema filesystem'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.kind' "$tmp/snapshot.json")" partition 'capture plan must ignore stale swap UUID metadata'

# MPA does not carry one all-disk n schema.  Its captured per-disk partition
# tables and swap UUID lists are the reliable source on an empty target; target
# block sizes and target blkid must not classify the plan.
mkdir -p "$tmp/mpa-image"
cat >"$tmp/mpa-image/d1.partitions" <<'EOF'
label: dos
sector-size: 512
/dev/vda1 : start=2048, size=20, type=83
/dev/vda2 : start=4096, size=10, type=82
EOF
cat >"$tmp/mpa-image/d2.partitions" <<'EOF'
label: dos
sector-size: 512
/dev/vdb1 : start=2048, size=30, type=83
/dev/vdb2 : start=4096, size=5, type=82
EOF
printf '2 swap-one\n' >"$tmp/mpa-image/d1.original.swapuuids"
printf '2 swap-two\n' >"$tmp/mpa-image/d2.original.swapuuids"
imagePath="$tmp/mpa-image"; type=down; imgType=mpa; originalSchemaFile=''
getPartitions() { case $1 in /dev/vda) parts='/dev/vda1 /dev/vda2' ;; /dev/vdb) parts='/dev/vdb1 /dev/vdb2' ;; *) return 1 ;; esac; }
getPartitionNumber() { part_number=${1##*[!0-9]}; }
blockdev() { [[ $1 == --getsize64 ]] && { printf '999999\n'; return 0; }; return 1; }
blkid() { printf 'ext4\n'; }
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disks /dev/vda /dev/vdb
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.weightBytes' "$tmp/snapshot.json")" 10240 'MPA plan must retain d1 source partition bytes'
assert_eq "$(jq -r '.items[]|select(.key=="d2:p1")|.weightBytes' "$tmp/snapshot.json")" 15360 'MPA plan must retain d2 source partition bytes'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|.kind' "$tmp/snapshot.json")" swap 'MPA d1 swap UUID metadata must classify swap'
assert_eq "$(jq -r '.items[]|select(.key=="d2:p2")|.weightBytes' "$tmp/snapshot.json")" 0 'MPA swap must not use target size as weight'

# Extended/EBR containers and MBR-only work are never payloads.  They must be
# explicit terminal skips so a successful task cannot retain a pending parent.
cat >"$tmp/schema.json" <<'EOF'
{"logicalSectorBytes":512,"partitions":[{"number":1,"originalSectors":40,"role":"extended_container","kind":"extended","fs":""},{"number":5,"originalSectors":20,"role":"data","kind":"logical","fs":"ext4"}]}
EOF
imagePath=''; type=down; imgType=n; originalSchemaFile="$tmp/schema.json"
getPartitions() { parts='/dev/vda1 /dev/vda5'; }
getPartitionNumber() { part_number=${1##*[!0-9]}; }
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disk /dev/vda 1
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.kind' "$tmp/snapshot.json")" container 'extended parent must be a container'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.status' "$tmp/snapshot.json")" skipped 'extended parent must be explicitly skipped'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.weightBytes' "$tmp/snapshot.json")" 0 'extended parent must not contribute payload weight'
imgPartitionType=mbr
rootpxe_partition_progress_plan_disk /dev/vda 1
assert_eq "$(jq '[.items[].status == "skipped"]|all' "$tmp/snapshot.json")" true 'MBR-only plan must explicitly skip all payload items'
imgPartitionType=all
cat >"$tmp/schema.json" <<'EOF'
{"logicalSectorBytes":512,"partitions":[{"number":1,"originalSectors":2,"fs":"ext4","role":"data"},{"number":2,"originalSectors":99,"fs":"swap","role":"swap"}]}
EOF
imagePath=''; type=up; imgType=n; originalSchemaFile="$tmp/schema.json"
getPartitions() { parts='/dev/vda1 /dev/vda2'; }
getPartitionNumber() { case $1 in /dev/vda1) part_number=1 ;; /dev/vda2) part_number=2 ;; *) return 1 ;; esac; }
blockdev() { [[ $1 == --getsize64 ]] || return 1; case $2 in /dev/vda1) printf '999\n' ;; /dev/vda2) printf '9999\n' ;; *) return 1 ;; esac; }
blkid() { case "${*: -1}" in /dev/vda1) printf 'ext4\n' ;; /dev/vda2) printf 'swap\n' ;; *) return 1 ;; esac; }
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disk /dev/vda 1

# A child shell is used by LVM capture.  Sequence state must remain monotonic
# across it, otherwise current/clear events can be applied out of order.
rootpxe_partition_progress_item d1:p1 preparing 0 '准备'
( rootpxe_partition_progress_item d1:p2 completed - '交换元数据完成' )
rootpxe_partition_progress_item d1:p1 completed 100 '完成'
mapfile -t event_names < <(find "$tmp/events" -maxdepth 1 -name 'event-*.json' -printf '%f\n' | LC_ALL=C sort)
assert_eq "${event_names[*]}" 'event-0000000001.json event-0000000002.json event-0000000003.json' 'event sequence must remain monotonic across child shells'
assert_eq "$(jq -r '.percent == null' "$tmp/events/event-0000000002.json")" true 'swap event must not invent a percentage'

# Flush only consumes queued state after the reporter has stopped.  curl is a
# test stub; telemetry delivery failure/success is never allowed to gate work.
test_curl_args="$tmp/curl.args"
curl() { printf '%s\n' "$*" >>"$test_curl_args"; return 0; }
task_token=0123456789abcdef
mac=00:11:22:33:44:55
pxeapi=https://server/service/pxeos/
type=up
rootpxe_partition_progress_flush
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.status' "$tmp/snapshot.json")" completed 'flush must preserve final partition completion'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p2")|has("progress")' "$tmp/snapshot.json")" false 'swap snapshot must not show a fake percentage'
assert_eq "$(grep -Fc 'progressProtocol=2' "$test_curl_args")" 4 'flush must report each queued milestone plus the final snapshot'
# A stalled telemetry request must not turn a large pending event queue into a
# multi-minute task completion delay.  Simulate a first request consuming seven
# seconds; the remaining milestones are merged locally and one final snapshot
# gets the remaining seven-second budget.
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disk /dev/vda 1
rootpxe_partition_progress_item d1:p1 preparing 0 '准备'
rootpxe_partition_progress_item d1:p1 running 50 '写入'
rootpxe_partition_progress_item d1:p1 completed 100 '完成'
flush_timeouts="$tmp/flush-timeouts"
flush_date_counter="$tmp/flush-date-counter"
printf '0\n' >"$flush_date_counter"
date() {
    local calls
    calls=$(cat "$flush_date_counter")
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$flush_date_counter"
    case $calls in
        1|2) printf '0\n' ;;
        *) printf '8\n' ;;
    esac
}
rootpxe_partition_progress_send_snapshot() { printf '%s\n' "${2:-}" >>"$flush_timeouts"; }
rootpxe_partition_progress_flush
unset -f date
assert_eq "$(wc -l <"$flush_timeouts")" 2 'flush must reserve its final telemetry budget after a slow milestone'
assert_eq "$(tr '\n' ' ' <"$flush_timeouts")" '7 7 ' 'flush must bound milestone and final snapshot timeouts within fifteen seconds'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.status' "$tmp/snapshot.json")" completed 'timed flush must still merge later milestone states locally'

# Exercise the actual deployment swap hook: only a captured UUID member that
# makeSwapSystem has rebuilt is recorded as completed without a percentage.
awk '/^makeAllSwapSystems\(\)/ { copy=1 } /^rootpxe_find_windows_system_partition\(\)/ { exit } copy { print }' "$funcs" >"$tmp/make-swap.sh"
# shellcheck source=/dev/null
. "$tmp/make-swap.sh"
printf '2 swap-uuid\n' >"$tmp/d1.swap"
swapUUIDFileName() { swapuuidfilename="$tmp/d1.swap"; }
getPartitions() { parts='/dev/vda2'; }
getPartitionNumber() { part_number=2; }
makeSwapSystem() { return 0; }
runPartprobe() { return 0; }
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disk /dev/vda 1
makeAllSwapSystems /dev/vda 1 "$tmp" all
swap_event=$(find "$tmp/events" -name 'event-*.json' -print -quit)
assert_eq "$(jq -r '.status' "$swap_event")" completed 'makeAllSwapSystems must complete the actual swap item'
assert_eq "$(jq -r '.percent == null' "$swap_event")" true 'actual swap rebuild must remain metadata-only'
# Exercise the capture swap branch itself.  A successful helper call is not
# enough: completion requires a UUID record written for this partition.
awk '/^savePartition\(\)/ { copy=1 } /^restorePartition\(\)/ { exit } copy { print }' "$funcs" >"$tmp/save-partition.sh"
# shellcheck source=/dev/null
. "$tmp/save-partition.sh"
rootpxe_console_message() { return 0; }
debugPause() { return 0; }
last_item_event() {
    local event result=''
    for event in "$tmp/events"/event-*.json; do
        [[ -f $event ]] || continue
        [[ $(jq -r '.event // ""' "$event") == item ]] && result=$event
    done
    printf '%s\n' "$result"
}
getPartType() { parttype=83; }
fsTypeSetting() { fstype=swap; }
swapUUIDFileName() { swapuuidfilename="$tmp/capture.swap"; }
getPartitionNumber() { part_number=2; }
rootpxe_partition_progress_initialize_runtime
saveSwapUUID() { printf '2 saved-uuid\n' >>"$1"; }
savePartition /dev/vda2 1 "$tmp" all
capture_swap_event=$(last_item_event)
assert_eq "$(jq -r '.status' "$capture_swap_event")" completed 'saved swap UUID must report completed metadata'
assert_eq "$(jq -r '.percent == null' "$capture_swap_event")" true 'saved swap UUID must not have a percentage'
rootpxe_partition_progress_initialize_runtime
rm -f "$tmp/capture.swap"
saveSwapUUID() { return 0; }
savePartition /dev/vda2 1 "$tmp" all
capture_swap_event=$(last_item_event)
assert_eq "$(jq -r '.status' "$capture_swap_event")" failed 'missing UUID record must not report capture metadata as completed'
rootpxe_partition_progress_initialize_runtime
saveSwapUUID() { return 1; }
savePartition /dev/vda2 1 "$tmp" all
capture_swap_event=$(last_item_event)
assert_eq "$(jq -r '.status' "$capture_swap_event")" failed 'failed UUID write must not report capture metadata as completed'

# savePartition delegates an LVM PV directly to its dedicated lifecycle.  It
# must not emit the generic partition preparing=0 sample for a container.
rootpxe_partition_progress_initialize_runtime
fsTypeSetting() { fstype=lvm; }
getPartType() { parttype=8e; }
getPartitionNumber() { part_number=1; }
rootpxe_lvm_is_pv_partition() { return 0; }
handleError() { return 1; }
rootpxe_capture_lvm_volumes() {
    rootpxe_partition_progress_item 'd1:p1' preparing - '准备抓取 LVM 物理卷'
    rootpxe_partition_progress_item 'd1:p1' running - '正在抓取 LVM 逻辑卷'
    rootpxe_partition_progress_item 'd1:p1' completed - 'LVM 物理卷及逻辑卷抓取完成'
}
savePartition /dev/vda1 1 "$tmp" all
lvm_save_event=$(last_item_event)
assert_eq "$(jq -r '.percent == null' "$lvm_save_event")" true 'LVM container save entry must not report a generic 0 percent'
lvm_pv_lifecycle=$(
    for event in "$tmp/events"/event-*.json; do
        [[ -f $event ]] || continue
        jq -r 'select(.event == "item" and .key == "d1:p1") | [.status, (if .percent == null then "null" else (.percent|tostring) end)] | @tsv' "$event"
    done
)
lvm_pv_lifecycle=${lvm_pv_lifecycle//$'\r'/}
assert_eq "$lvm_pv_lifecycle" $'preparing\tnull\nrunning\tnull\ncompleted\tnull' 'LVM PV must emit the complete null-percent lifecycle'

# LVM filesystem facts must be collected in a short, reversible activation
# window before planning.  These source LVs begin inactive; both are activated,
# probed, deactivated, and only then published with an FS column.
awk '/^rootpxe_lvm_prepare_capture_lv_facts\(\)/ { copy=1 } /^rootpxe_xfs_capture_preflight\(\)/ { exit } copy { print }' "$funcs" >"$tmp/lvm-fs-prepare.sh"
# shellcheck source=/dev/null
. "$tmp/lvm-fs-prepare.sh"
rootpxe_lvm_lv_facts_file="$tmp/lvm-source-facts"
rootpxe_lvm_vg_name=vg0
rootpxe_lvm_vg_uuid=vg-1
rootpxe_lvm_active=yes
printf 'root|lv-root|/dev/vg0/root|1073741824\nswap|lv-swap|/dev/vg0/swap|106300440576\n' >"$rootpxe_lvm_lv_facts_file"
lvm_prepare_trace="$tmp/lvm-prepare-trace"
rootpxe_lvm_json_jq() { jq "$@"; }
lvm_prepare_reset_facts() { printf 'root|lv-root|/dev/vg0/root|1073741824\nswap|lv-swap|/dev/vg0/swap|106300440576\n' >"$rootpxe_lvm_lv_facts_file"; : >"$lvm_prepare_trace"; }
lvs() {
    printf '{"report":[{"lv":[{"lv_uuid":"lv-root","lv_path":"/dev/vg0/root","lv_active":"%s"},{"lv_uuid":"lv-swap","lv_path":"/dev/vg0/swap","lv_active":"%s"}' "${PREP_ROOT_STATE:-inactive}" "${PREP_SWAP_STATE:-inactive}"
    [[ ${PREP_DUPLICATE:-no} != yes ]] || printf ',{"lv_uuid":"lv-root","lv_path":"/dev/vg0/root-copy","lv_active":"inactive"}'
    printf ']}]}\n'
}
lvchange() { printf '%s\n' "$*" >>"$lvm_prepare_trace"; [[ ${PREP_LVCHANGE_FAIL:-} == "${1:-}" ]] && return 1; [[ ${PREP_LVCHANGE_SIGNAL:-no} == yes && ${1:-} == -ay ]] && kill -TERM "$BASHPID"; return 0; }
blkid() { [[ ${PREP_BLKID_FAIL:-no} != yes ]] || return 1; case "${*: -1}" in /dev/vg0/root) printf 'ext4\n' ;; /dev/vg0/swap) printf 'swap\n' ;; *) return 1 ;; esac; }
lvm_prepare_reset_facts
rootpxe_lvm_prepare_capture_lv_facts
assert_eq "$(awk -F'|' '$2=="lv-root" {print $5}' "$rootpxe_lvm_lv_facts_file")" ext4 'inactive data LV must publish trusted filesystem facts'
assert_eq "$(awk -F'|' '$2=="lv-swap" {print $5}' "$rootpxe_lvm_lv_facts_file")" swap 'inactive swap LV must publish trusted filesystem facts'
assert_eq "$(grep -c -- '-ay' "$lvm_prepare_trace")" 2 'only initially inactive LVs must be activated'
assert_eq "$(grep -c -- '-an' "$lvm_prepare_trace")" 2 'only prepared inactive LVs must be deactivated'

# Already active volumes stay active; a partial state only toggles the inactive
# member.  Neither form may change a successful five-field publication.
lvm_prepare_reset_facts
PREP_ROOT_STATE=active PREP_SWAP_STATE=active rootpxe_lvm_prepare_capture_lv_facts
assert_eq "$(wc -l <"$lvm_prepare_trace")" 0 'all-active LV facts must not change activation state'
lvm_prepare_reset_facts
PREP_ROOT_STATE=inactive PREP_SWAP_STATE=active rootpxe_lvm_prepare_capture_lv_facts
assert_eq "$(grep -c -- '-ay' "$lvm_prepare_trace")" 1 'partial LV state must activate only the inactive member'
assert_eq "$(grep -c -- '-an' "$lvm_prepare_trace")" 1 'partial LV state must deactivate only the member activated here'

# Any preparation failure leaves the original four-field facts untouched and
# does not leak a partial plan input.  Cleanup failure is equally fatal.
lvm_prepare_reset_facts
PREP_BLKID_FAIL=yes rootpxe_lvm_prepare_capture_lv_facts && fail 'filesystem probe failure must reject LVM plan preparation'
unset PREP_BLKID_FAIL
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'probe failure must not publish partial facts'

lvm_prepare_reset_facts
PREP_DUPLICATE=yes rootpxe_lvm_prepare_capture_lv_facts && fail 'duplicate queried LV UUID must reject LVM plan preparation'
unset PREP_DUPLICATE
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'duplicate queried LV UUID must not publish partial facts'
lvm_prepare_reset_facts
printf 'root-copy|lv-root|/dev/vg0/root-copy|1073741824\n' >>"$rootpxe_lvm_lv_facts_file"
rootpxe_lvm_prepare_capture_lv_facts && fail 'duplicate source LV UUID must reject LVM plan preparation'
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'duplicate source LV UUID must not publish partial facts'
lvm_prepare_reset_facts
PREP_LVCHANGE_FAIL=-ay rootpxe_lvm_prepare_capture_lv_facts && fail 'activation failure must reject LVM plan preparation'
unset PREP_LVCHANGE_FAIL
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'activation failure must not publish partial facts'

lvm_prepare_reset_facts
PREP_LVCHANGE_SIGNAL=yes rootpxe_lvm_prepare_capture_lv_facts && fail 'activation signal must reject LVM plan preparation'
unset PREP_LVCHANGE_SIGNAL
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'signal cleanup must not publish partial facts'
grep -Eq '^-an /dev/vg0/(root|swap)$' "$lvm_prepare_trace" || fail 'signal cleanup must deactivate a prepared LV'
awk '$1 == "-an" && $2 !~ /^\/dev\/vg0\/(root|swap)$/ { exit 1 }' "$lvm_prepare_trace" || fail 'signal cleanup must not deactivate an unrelated LV'
lvm_prepare_reset_facts
PREP_LVCHANGE_FAIL=-an rootpxe_lvm_prepare_capture_lv_facts && fail 'cleanup failure must reject LVM plan preparation'
unset PREP_LVCHANGE_FAIL
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'cleanup failure must not publish facts'
lvm_prepare_reset_facts
mv() { return 1; }
PREP_ROOT_STATE=active PREP_SWAP_STATE=active rootpxe_lvm_prepare_capture_lv_facts && fail 'facts publish failure must reject LVM plan preparation'
unset -f mv
assert_eq "$(awk -F'|' 'NR==1 {print NF}' "$rootpxe_lvm_lv_facts_file")" 4 'facts publish failure must retain original facts'

# A plan consumes only the prepared filesystem records: both source LV sizes
# remain distinct, while swap stays a zero-weight metadata leaf.
lvm_prepare_reset_facts
PREP_ROOT_STATE=active PREP_SWAP_STATE=active rootpxe_lvm_prepare_capture_lv_facts
rootpxe_lvm_pv_path=/dev/vda1; rootpxe_lvm_pv_number=1; rootpxe_lvm_active=yes
rootpxe_resolved_lvm_layout_file=''; type=down
getPartitions() { parts='/dev/vda1'; }
getPartitionNumber() { part_number=1; }
rootpxe_partition_progress_initialize_runtime
rootpxe_partition_progress_plan_disk /dev/vda 1
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1:lv:lv-root")|.weightBytes' "$tmp/snapshot.json")" 1073741824 'prepared data LV must retain 1GiB source weight'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1:lv:lv-swap")|.weightBytes' "$tmp/snapshot.json")" 0 'prepared swap LV must not have payload weight'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1:lv:lv-swap")|.filesystem' "$tmp/snapshot.json")" swap 'plan must consume prepared swap filesystem fact'

# Capture must refuse to publish a plan containing only an LVM PV container.
# Missing, empty, or malformed five-field facts leave an existing snapshot
# untouched, so a previous complete plan cannot be overwritten by a bad retry.
assert_capture_lvm_facts_rejected() {
    local label="$1" facts="$2"
    printf '{"sentinel":"complete-plan"}\n' >"$tmp/snapshot.json"
    rootpxe_lvm_lv_facts_file="$facts"
    if rootpxe_partition_progress_plan_disk /dev/vda 1; then fail "$label must reject capture LVM plan"; fi
    assert_eq "$(cat "$tmp/snapshot.json")" '{"sentinel":"complete-plan"}' "$label must preserve prior snapshot"
}
assert_capture_lvm_facts_rejected missing "$tmp/missing-lvm-facts"
: >"$tmp/empty-lvm-facts"
assert_capture_lvm_facts_rejected empty "$tmp/empty-lvm-facts"
printf 'root|lv-root|/dev/vg0/root|1073741824|btrfs\n' >"$tmp/invalid-lvm-facts"
assert_capture_lvm_facts_rejected invalid "$tmp/invalid-lvm-facts"
rootpxe_lvm_lv_facts_file="$tmp/lvm-source-facts"
lvm_prepare_reset_facts
PREP_ROOT_STATE=active PREP_SWAP_STATE=active rootpxe_lvm_prepare_capture_lv_facts

# With trusted source facts, plan serialization is telemetry only.  The capture
# call shape below matches pxeos.upload: malformed facts enter handleError, but
# item/final JSON or atomic publish failures keep imaging alive and preserve a
# prior complete snapshot.
real_jq=$(command -v jq)
jq() {
    case "${PLAN_JQ_FAIL:-}:${1:-}" in
        lv-items:-c)
            for jq_arg in "$@"; do [[ $jq_arg != *parentKey* ]] || return 1; done
            ;;
        final-json:-cn) return 1 ;;
    esac
    command "$real_jq" "$@"
}
capture_plan_handle_error=''
handleError() { capture_plan_handle_error="$1"; return 1; }
capture_plan_stage() { rootpxe_partition_progress_plan_disk /dev/vda 1 || handleError 'LVM_PROGRESS_PLAN_FAILED'; }
assert_capture_plan_telemetry_best_effort() {
    local label="$1" mode="$2"
    printf '{"sentinel":"complete-plan"}\n' >"$tmp/snapshot.json"
    capture_plan_handle_error=''
    if ! PLAN_JQ_FAIL="$mode" capture_plan_stage; then fail "$label telemetry failure must not stop capture"; fi
    assert_eq "$capture_plan_handle_error" '' "$label telemetry failure must not call handleError"
    assert_eq "$(cat "$tmp/snapshot.json")" '{"sentinel":"complete-plan"}' "$label telemetry failure must preserve prior snapshot"
}
assert_capture_plan_telemetry_best_effort lv-items lv-items
assert_capture_plan_telemetry_best_effort final-json final-json
plan_snapshot_file="$tmp/snapshot.json"
mv() { [[ ${2:-} == "$plan_snapshot_file" ]] && return 1; command mv "$@"; }
assert_capture_plan_telemetry_best_effort atomic-publish none
unset -f mv jq
rootpxe_lvm_lv_facts_file="$tmp/missing-lvm-facts"
capture_plan_handle_error=''
if capture_plan_stage; then fail 'missing source facts must stop capture'; fi
assert_eq "$capture_plan_handle_error" LVM_PROGRESS_PLAN_FAILED 'missing source facts must enter capture handleError'
rootpxe_lvm_lv_facts_file="$tmp/lvm-source-facts"
lvm_prepare_reset_facts
PREP_ROOT_STATE=active PREP_SWAP_STATE=active rootpxe_lvm_prepare_capture_lv_facts

# LVM has one PV container and leaf logical volumes.  The container carries no
# weight, while each LV carries its captured source size and parent relation.
rootpxe_partition_progress_initialize_runtime
getPartitionNumber() {
    case $1 in /dev/vda1) part_number=1 ;; /dev/vda2) part_number=2 ;; *) return 1 ;; esac
}
cat >"$tmp/lvm.json" <<'EOF'
{"pv":{"partitionNumber":1},"vg":{"name":"vg0"},"volumes":[{"name":"root","uuid":"root-uuid","fs":"xfs","originalBytes":1000},{"name":"swap","uuid":"swap-uuid","fs":"swap","originalBytes":200}]}
EOF
rootpxe_resolved_lvm_layout_file="$tmp/lvm.json"
unset originalSchemaFile rootpxe_lvm_active rootpxe_lvm_lv_facts_file
type=down
getPartitions() { parts='/dev/vda1'; }
rootpxe_partition_progress_plan_disk /dev/vda 1
assert_eq "$(jq -r '.items|length' "$tmp/snapshot.json")" 3 'LVM plan must contain one container plus two leaf volumes'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1")|.weightBytes' "$tmp/snapshot.json")" 0 'PV container must not be weighted twice'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1:lv:root-uuid")|.parentKey' "$tmp/snapshot.json")" d1:p1 'LV must remain attached to its PV partition'
assert_eq "$(jq -r '.items[]|select(.key=="d1:p1:lv:swap-uuid")|.kind' "$tmp/snapshot.json")" swap 'swap LV must remain metadata only'

# Without the advertised v2 capability helpers must not create local state;
# old servers continue through their existing v1 status reporter path.
rm -f "$tmp/snapshot.json"
rootpxe_partition_progress_enabled=no
rootpxe_partition_progress_initialize_runtime
[[ ! -e "$tmp/snapshot.json" ]] || fail 'v2 disabled must not create a snapshot'
printf 'PASS: PXEOS partition progress regression\n'
