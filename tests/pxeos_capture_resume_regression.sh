#!/usr/bin/env bash
# Current metadata validation and capture permits. Published generations are
# recovered only by storage-io.sh receipts, never by a marker discovered here.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/task-http-test-support.sh"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rootpxe-capture-metadata-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
storage="$tmp/storage"; mkdir -p "$storage/images"
sed -n '/^rootpxe_safe_relative_path() {$/,/^}$/p' "$lib/funcs.sh" >"$tmp/safe-path.sh"
. "$tmp/safe-path.sh"
. "$lib/restore-preflight.sh"
. "$lib/capture-recovery.sh"
make_published() {
    local dir="$1" kind="$2"
    mkdir -p "$dir"
    if [[ $kind == n ]]; then
        printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mock","partitionTable":"mbr","originalDiskBytes":16777216,"logicalSectorBytes":512,"physicalSectorBytes":512,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"typeGuid":"83","fs":"ext4"}]}]}' >"$dir/.rootpxe-partition-inventory.json"
        printf '%s\n' '{"version":2,"partitionTable":"mbr","originalDiskBytes":16777216,"logicalSectorBytes":512,"physicalSectorBytes":512,"minDeployBytes":16777216,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"minSectors":4096,"kind":"primary","role":"data","fs":"ext4","artifact":"d1p1.img"}]}' >"$dir/.rootpxe-original-schema.json"
        printf 'label: dos\n/dev/mock1 : start=        2048, size=        4096, type=83\n' >"$dir/d1.partitions"
        truncate -s 1048576 "$dir/d1.mbr"
        printf payload >"$dir/d1p1.img"
    else
        printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mock","partitionTable":"none","originalDiskBytes":1,"logicalSectorBytes":1,"physicalSectorBytes":1,"partitions":[]}]}' >"$dir/.rootpxe-partition-inventory.json"
        printf payload >"$dir/${img}"
    fi
}
taskid=77 type=up img=n-image imgType=n; export taskid type img imgType
make_published "$storage/n-image" n
rootpxe_capture_publish_metadata "$storage/n-image" n || { echo 'FAIL: complete n metadata rejected' >&2; exit 1; }
private_inventory=$(mktemp "${TMPDIR:-/tmp}/rootpxe-capture-metadata.XXXXXX")
private_schema=$(mktemp "${TMPDIR:-/tmp}/rootpxe-capture-metadata.XXXXXX")
cp "$storage/n-image/.rootpxe-partition-inventory.json" "$private_inventory"
cp "$storage/n-image/.rootpxe-original-schema.json" "$private_schema"
chmod 600 "$private_inventory" "$private_schema"
rootpxe_partition_inventory_file=$private_inventory rootpxe_original_schema_file=$private_schema
rootpxe_capture_resume_cleanup
[[ ! -e $private_inventory && ! -e $private_schema && -f "$storage/n-image/.rootpxe-partition-inventory.json" && -f "$storage/n-image/.rootpxe-original-schema.json" ]] || { echo 'FAIL: private cleanup changed retained metadata' >&2; exit 1; }
printf foreign >"$tmp/unknown-metadata"
rootpxe_partition_inventory_file="$tmp/unknown-metadata"
rootpxe_capture_resume_cleanup
[[ -f $tmp/unknown-metadata ]] || { echo 'FAIL: unknown metadata removed' >&2; exit 1; }
taskid=88 type=up img=raw.img imgType=dd; export taskid type img imgType
make_published "$storage/raw.img" dd
rootpxe_capture_publish_metadata "$storage/raw.img" dd || { echo 'FAIL: dd without d1.partitions rejected' >&2; exit 1; }
taskid=89 type=up img=mps-one imgType=mps imgPartitionType=1; export taskid type img imgType imgPartitionType
mkdir -p "$storage/mps-one"
printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mock","partitionTable":"mbr","originalDiskBytes":4096,"logicalSectorBytes":512,"physicalSectorBytes":512,"partitions":[{"number":1,"startSectors":1,"originalSectors":1,"typeGuid":"83","fs":"ext4"},{"number":2,"startSectors":2,"originalSectors":1,"typeGuid":"83","fs":"ext4"}]}]}' >"$storage/mps-one/.rootpxe-partition-inventory.json"
printf 'label: dos\n/dev/mock1 : start=           1, size=           1, type=83\n/dev/mock2 : start=           2, size=           1, type=83\n' >"$storage/mps-one/d1.partitions"
truncate -s 512 "$storage/mps-one/d1.mbr"
printf payload >"$storage/mps-one/d1p1.img"
rootpxe_capture_publish_metadata "$storage/mps-one" mps || { echo 'FAIL: selected mps payload must resume without uncaptured partitions' >&2; exit 1; }
imgPartitionType=all
rootpxe_capture_publish_metadata "$storage/mps-one" mps && { echo 'FAIL: all-scope mps accepted a missing uncaptured payload' >&2; exit 1; }
imgPartitionType=1
mkdir -p "$storage/missing"; printf payload >"$storage/missing/payload.img"
rootpxe_capture_publish_metadata "$storage/missing" mps && { echo 'FAIL: missing metadata accepted' >&2; exit 1; }
img=invalid; make_published "$storage/invalid" mps
printf '{}\n' >"$storage/invalid/.rootpxe-partition-inventory.json"
rootpxe_capture_publish_metadata "$storage/invalid" mps && { echo 'FAIL: malformed inventory accepted' >&2; exit 1; }
[[ -f $storage/invalid/payload.img || -f $storage/invalid/invalid ]] || { echo 'FAIL: rejected metadata changed payload' >&2; exit 1; }
upload="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
# Permit dispatch is isolated from block-device inspection in this fixture;
# production target-use rejection is covered by its dedicated regression.
rootpxe_require_unused_target_disks() { return 0; }
export -f rootpxe_require_unused_target_disks
grep -Fq 'rootpxe_wait_for_disk_permit "$capture_target_id" capture_read_write' "$upload" || { echo 'FAIL: single-disk capture must retain the legacy permit endpoint' >&2; exit 1; }
grep -Fq 'rootpxe_wait_for_disk_permit_batch "${permit_args[@]}"' "$upload" || { echo 'FAIL: mpa capture must use the batch permit endpoint' >&2; exit 1; }
permit_wrapper="$tmp/permit-wrapper.sh"
awk '/^# Do not clear staging or probe a writable source filesystem/ { copy=1 } copy && /^prepareUploadLocation / { exit } copy { print }' "$upload" | sed "s|/tmp/pxeos.failure_action|$tmp/failure_action|" >"$permit_wrapper"
[[ -s $permit_wrapper ]] || { echo 'FAIL: capture permit dispatch missing' >&2; exit 1; }
single_events="$tmp/single-permit-events.log"
(
    imgType=n hd=/dev/single
    rootpxe_disk_stable_identity() { printf 'single-id\n'; }
    rootpxe_wait_for_disk_permit() { printf 'single-wait:%s:%s\n' "$1" "$2"; }
    rootpxe_record_disk_permit_binding() { printf 'record:%s:%s:%s\n' "$1" "$2" "$3"; }
    rootpxe_wait_for_disk_permit_batch() { echo 'FAIL: single used batch'; return 1; }
    handleError() { echo "FAIL: $*"; return 1; }
    . "$permit_wrapper"
) >"$single_events"
[[ $(cat "$single_events") == $'single-wait:single-id:capture_read_write\nrecord:/dev/single:single-id:capture_read_write' ]] || { cat "$single_events" >&2; echo 'FAIL: single permit ordering changed' >&2; exit 1; }
batch_events="$tmp/batch-permit-events.log"
(
    imgType=mpa rootpxe_capture_disks=(/dev/one /dev/two)
    rootpxe_disk_stable_identity() { printf '%s-id\n' "${1##*/}"; }
    rootpxe_record_disk_permit_binding() { printf 'record:%s:%s:%s\n' "$1" "$2" "$3"; }
    rootpxe_wait_for_disk_permit() { echo 'FAIL: mpa used single'; return 1; }
    rootpxe_wait_for_disk_permit_batch() { printf 'batch:%s,%s,%s,%s\n' "$1" "$2" "$3" "$4"; }
    handleError() { echo "FAIL: $*"; return 1; }
    . "$permit_wrapper"
) >"$batch_events"
[[ $(cat "$batch_events") == $'record:/dev/one:one-id:capture_read_write\nrecord:/dev/two:two-id:capture_read_write\nbatch:one-id,capture_read_write,two-id,capture_read_write' ]] || { cat "$batch_events" >&2; echo 'FAIL: mpa batch permit ordering changed' >&2; exit 1; }
rm -f "$tmp/failure_action"
cancel_runner="$tmp/cancel-permit.sh"
cat >"$cancel_runner" <<EOF
#!/usr/bin/env bash
set -e
imgType=n; hd=/dev/cancel
rootpxe_disk_stable_identity() { printf 'cancel-id\\n'; }
rootpxe_wait_for_disk_permit() { return 10; }
rootpxe_record_disk_permit_binding() { echo 'FAIL: canceled task recorded permit'; return 1; }
rootpxe_wait_for_disk_permit_batch() { return 1; }
handleError() { echo "FAIL: \$*"; return 1; }
. "$permit_wrapper"
EOF
if bash "$cancel_runner"; then
    echo 'FAIL: canceled single permit continued' >&2
    exit 1
else
    permit_cancel_rc=$?
fi
[[ $permit_cancel_rc -eq 2 && $(cat "$tmp/failure_action") == reboot ]] || { echo 'FAIL: cancel permit did not retain reboot exit semantics' >&2; exit 1; }
cat >"$cancel_runner" <<EOF
#!/usr/bin/env bash
set -e
imgType=n; hd=/dev/attention
rootpxe_disk_stable_identity() { printf 'attention-id\\n'; }
rootpxe_wait_for_disk_permit() { return 20; }
rootpxe_record_disk_permit_binding() { echo 'FAIL: attention task recorded permit'; return 1; }
rootpxe_wait_for_disk_permit_batch() { return 1; }
handleError() { echo "FAIL: \$*"; return 1; }
. "$permit_wrapper"
EOF
if bash "$cancel_runner"; then
    echo 'FAIL: attention single permit continued' >&2
    exit 1
else
    permit_attention_rc=$?
fi
[[ $permit_attention_rc -eq 2 ]] || { echo 'FAIL: attention permit did not exit 2' >&2; exit 1; }
mpa_case="$tmp/mpa-case.sh"
awk '/^        mpa\)/ { copy=1 } copy && /^        dd\)/ { exit } copy { print }' "$upload" >"$mpa_case"
[[ -s $mpa_case ]] || { echo 'FAIL: mpa capture body missing' >&2; exit 1; }
mpa_events="$tmp/mpa-events.log"
(
    imgType=mpa imagePath="$tmp/mpa-output" osid=0 imgPartitionType=0
    mkdir -p "$imagePath"
    rootpxe_capture_disks=(/dev/disk-b /dev/disk-a)
    rootpxe_verify_disk_permit_binding() { printf 'verify:%s\n' "$1"; }
    getPartitions() { case "$1" in /dev/disk-b) parts=part-b;; /dev/disk-a) parts=part-a;; *) return 1;; esac; }
    blockdev() { printf '4096\n'; }
    savePartitionTablesAndBootLoaders() { printf 'table:%s:%s\n' "$1" "$2"; }
    savePartition() { printf 'part:%s:%s\n' "$1" "$2"; }
    runPartprobe() { :; }
    isBitlockedPartition() { :; }
    rootpxe_console_message() { :; }
	rootpxe_partition_progress_plan_disks() { :; }
    debugPause() { :; }
    { printf 'case "$imgType" in\n'; cat "$mpa_case"; printf 'esac\n'; } >"$tmp/mpa-wrapper.sh"
    . "$tmp/mpa-wrapper.sh"
) >"$mpa_events"
[[ $(cat "$mpa_events") == $'verify:/dev/disk-b\ntable:/dev/disk-b:1\npart:part-b:1\nverify:/dev/disk-a\ntable:/dev/disk-a:2\npart:part-a:2' ]] || { cat "$mpa_events" >&2; echo 'FAIL: mpa capture disk numbering changed' >&2; exit 1; }
inventory_function="$tmp/inventory-function.sh"
awk '/^rootpxe_build_partition_inventory\(\)/ { copy=1 } copy { print } copy && $0 == "}" { exit }' "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh" >"$inventory_function"
[[ -s $inventory_function ]] || { echo 'FAIL: mpa inventory function missing' >&2; exit 1; }
(
    . "$inventory_function"
    rootpxe_verify_disk_permit_binding() { [[ $2 == capture_read_write ]]; }
    rootpxe_build_partition_inventory_disk() { printf '{"number":%s,"sourceDevice":"%s","partitionTable":"none","originalDiskBytes":1,"logicalSectorBytes":1,"physicalSectorBytes":1,"partitions":[]}\n' "$3" "$1"; }
    getPartitions() { case "$1" in /dev/disk-b) parts=part-b;; /dev/disk-a) parts=part-a;; *) return 1;; esac; }
    rootpxe_build_partition_inventory "$tmp/mpa-inventory" mpa ignored '/dev/disk-b /dev/disk-a'
    jq -e '[.disks[].number] == [1,2]' "$rootpxe_partition_inventory_file" >/dev/null || exit 1
    getPartitions() { case "$1" in /dev/disk-b) parts=part-b;; /dev/disk-a) parts='';; *) return 1;; esac; }
    if rootpxe_build_partition_inventory "$tmp/mpa-inventory" mpa ignored '/dev/disk-b /dev/disk-a'; then
        echo 'FAIL: changed mpa source disk was silently skipped' >&2
        exit 1
    fi
    rm -f -- "$rootpxe_partition_inventory_file"
)
echo 'PASS: capture recovery regression'
