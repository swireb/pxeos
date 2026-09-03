#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/capture-recovery.sh"
preflight="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/restore-preflight.sh"
[[ -r $lib ]] || { echo 'FAIL: capture recovery library missing' >&2; exit 1; }
[[ -r $preflight ]] || { echo 'FAIL: restore preflight library missing' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rootpxe-capture-resume.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
storage="$tmp/storage"; mkdir -p "$storage/images"
rootpxe_safe_relative_path() { [[ -n $1 && $1 != /* && $1 != */ && $1 != *..* ]] && printf '%s\n' "$1"; }
rootpxe_storage_path() { printf '%s/%s\n' "$storage" "$1"; }
rootpxe_capture_marker_matches_task() { [[ -f $1 && ! -L $1 && $(cat "$1") == "$2" ]]; }
rootpxe_directory_size_bytes() { find "$1" -type f ! -name .rootpxe-capture-taskid -printf '%s\n' | awk '{s+=$1} END{print s}'; }
rootpxe_capture_set_final_path() { rootpxe_capture_marker_matches_task "$1/.rootpxe-capture-taskid" "$taskid" || return 1; capture_size_bytes=$(rootpxe_directory_size_bytes "$1"); rootpxe_final_capture_path=$1; export capture_size_bytes rootpxe_final_capture_path; }
. "$preflight"
. "$lib"
make_published() {
    local dir="$1" kind="$2"
    mkdir -p "$dir"
    printf '%s\n' "$taskid" >"$dir/.rootpxe-capture-taskid"
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
rootpxe_capture_resume_published || { echo 'FAIL: same task n resume' >&2; exit 1; }
[[ ${rootpxe_capture_resume_published:-} == 1 && -f $rootpxe_partition_inventory_file && -f $rootpxe_original_schema_file ]] || { echo 'FAIL: private metadata handoff' >&2; exit 1; }
mode=$(stat -c %a "$rootpxe_partition_inventory_file")
if [[ $(uname -s) == MINGW* ]]; then
    echo 'SKIP: Git Bash on NTFS cannot verify POSIX 0600 mode; production keeps chmod 600.'
else
    [[ $mode == 600 ]] || { echo 'FAIL: private metadata mode' >&2; exit 1; }
fi
imgcomplete="$tmp/pxeos.imgcomplete"
sed "s|/usr/share/pxeos/lib/capture-recovery.sh|$lib|" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.imgcomplete" >"$imgcomplete"
resume_events="$tmp/resume-events.log"
(
    rootpxe_capture_resume_published=1
    type=up imgType=n imagePath="$rootpxe_final_capture_path" taskid="$taskid" task_token=masked mac=mock web=http://mock/ pxeapi=http://mock/ capture_size_bytes=9
    rootpxe_stage() { echo "stage:$*"; }
    rootpxe_require_task_context() { return 0; }
    rootpxe_build_partition_inventory() { echo 'FAIL: resumed imgcomplete rebuilt inventory'; return 91; }
    rootpxe_build_original_schema() { echo 'FAIL: resumed imgcomplete rebuilt schema'; return 92; }
    rootpxe_capture_publish_metadata() { echo 'FAIL: resumed imgcomplete republished metadata'; return 93; }
    rootpxe_finalize_capture() { echo 'FAIL: resumed imgcomplete finalized again'; return 94; }
    rootpxe_clear_capture_marker() { :; }
    rootpxe_cleanup_task_json() { :; }
    rootpxe_console_message() { :; }
    dots() { :; }
    debugPause() { :; }
    dmidecode() { printf 'mock-uuid\n'; }
    curl() { printf '{"success":true}\n'; }
    . "$imgcomplete"
) >"$resume_events"
! grep -Fq 'FAIL: resumed imgcomplete' "$resume_events" || { cat "$resume_events" >&2; exit 1; }
rootpxe_capture_resume_cleanup
[[ -f "$storage/n-image/.rootpxe-partition-inventory.json" && -f "$storage/n-image/.rootpxe-original-schema.json" && ! -e ${rootpxe_partition_inventory_file:-} ]] || { echo 'FAIL: cleanup removed sidecar or retained tmp' >&2; exit 1; }
taskid=88 type=up img=raw.img imgType=dd; export taskid type img imgType
make_published "$storage/raw.img" dd
rootpxe_capture_resume_published || { echo 'FAIL: dd without d1.partitions must resume' >&2; exit 1; }
rootpxe_capture_resume_cleanup
taskid=89 type=up img=mps-one imgType=mps imgPartitionType=1; export taskid type img imgType imgPartitionType
mkdir -p "$storage/mps-one"
printf '%s\n' "$taskid" >"$storage/mps-one/.rootpxe-capture-taskid"
printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mock","partitionTable":"mbr","originalDiskBytes":4096,"logicalSectorBytes":512,"physicalSectorBytes":512,"partitions":[{"number":1,"startSectors":1,"originalSectors":1,"typeGuid":"83","fs":"ext4"},{"number":2,"startSectors":2,"originalSectors":1,"typeGuid":"83","fs":"ext4"}]}]}' >"$storage/mps-one/.rootpxe-partition-inventory.json"
printf 'label: dos\n/dev/mock1 : start=           1, size=           1, type=83\n/dev/mock2 : start=           2, size=           1, type=83\n' >"$storage/mps-one/d1.partitions"
printf payload >"$storage/mps-one/d1.mbr"
printf payload >"$storage/mps-one/d1p1.img"
rootpxe_capture_resume_published || { echo 'FAIL: selected mps payload must resume without uncaptured partitions' >&2; exit 1; }
rootpxe_capture_resume_cleanup
imgPartitionType=all
rootpxe_capture_publish_metadata "$storage/mps-one" mps && { echo 'FAIL: all-scope mps accepted a missing uncaptured payload' >&2; exit 1; }
imgPartitionType=1
taskid=99 type=up img=missing imgType=mps; export taskid type img imgType
mkdir -p "$storage/missing"; printf '%s\n' "$taskid" >"$storage/missing/.rootpxe-capture-taskid"; printf payload >"$storage/missing/payload.img"
rootpxe_capture_resume_published && { echo 'FAIL: missing metadata resumed' >&2; exit 1; }
[[ ${rootpxe_capture_resume_error_code:-} == CAPTURE_PUBLISHED_METADATA_MISSING && -f $storage/missing/.rootpxe-capture-taskid ]] || { echo 'FAIL: missing metadata was not retained' >&2; exit 1; }
taskid=101 type=up img=invalid imgType=mps; export taskid type img imgType
make_published "$storage/invalid" mps
printf '%s\n' '{}' >"$storage/invalid/.rootpxe-partition-inventory.json"
rootpxe_capture_resume_published && { echo 'FAIL: malformed inventory resumed' >&2; exit 1; }
[[ ${rootpxe_capture_resume_error_code:-} == CAPTURE_PUBLISHED_METADATA_MISSING && -f $storage/invalid/.rootpxe-capture-taskid ]] || { echo 'FAIL: malformed metadata was not retained' >&2; exit 1; }
taskid=100 type=up img=foreign imgType=mps; export taskid type img imgType
make_published "$storage/foreign" mps; printf 'other\n' >"$storage/foreign/.rootpxe-capture-taskid"
rootpxe_capture_resume_published && { echo 'FAIL: foreign marker resumed' >&2; exit 1; }
[[ ${rootpxe_capture_resume_error_code:-} == CAPTURE_PUBLISHED_MARKER_FOREIGN && -f $storage/foreign/.rootpxe-capture-taskid ]] || { echo 'FAIL: foreign marker changed' >&2; exit 1; }
upload="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
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
