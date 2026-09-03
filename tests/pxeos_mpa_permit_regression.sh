#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
download="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.download"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rootpxe-mpa-permit.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Run the downloader's two local dispatch functions without its top-level
# checkin/mount flow.  All destructive commands are replaced by event writers
# to ordinary temp files.
test_funcs="$tmp/funcs.sh"
sed -e '/partition-funcs\.sh/d' -e '/restore-preflight\.sh/d' -e '/capture-recovery\.sh/d' "$funcs" >"$test_funcs"
download_functions="$tmp/download-functions.sh"
awk '/^preparePartitions\(\)/,/^findHDDInfo$/{ if ($0 ~ /^findHDDInfo$/) exit; print }' "$download" >"$download_functions"
set +u; source "$test_funcs"; set -u
source "$download_functions"

events="$tmp/events"
imgType=mpa imagePath="$tmp/image" osid=1 imgPartitionType=all disks='/dev/diskA /dev/diskB' global_gptcheck=
rootpxe_mpa_permit_is_batch=yes
mkdir "$imagePath"
rootpxe_console_message(){ :; }
rootpxe_activate_disk_permit_binding(){ printf 'activate:%s:%s\n' "$1" "$2" >>"$events"; }
restorePartitionTablesAndBootLoaders(){ printf 'table:%s:%s\n' "$1" "$2" >>"$events"; }
runPartprobe(){ printf 'partprobe:%s\n' "$1" >>"$events"; }
preparePartitions
expected_prepare=$'activate:/dev/diskA:deploy_write\ntable:/dev/diskA:1\npartprobe:/dev/diskA\nactivate:/dev/diskB:deploy_write\ntable:/dev/diskB:2\npartprobe:/dev/diskB'
[[ $(<"$events") == "$expected_prepare" ]] || fail prepare-order

: >"$events"
imgType=mpa osid=0 fixed_size_partitions= mc=no
rootpxe_expansion_fixed_partitions(){ :; }
sfdiskOriginalPartitionFileName(){ sfdiskoriginalpartitionfilename="$tmp/table"; }
getValidRestorePartitions(){ restoreparts="${1}p1"; }
getPartitionNumber(){ part_number=1; }
restorePartition(){ printf 'payload:%s\n' "$1" >>"$events"; }
restoreUUIDInformation(){ :; }
makeAllSwapSystems(){ :; }
debugPause(){ :; }
handleError(){ fail "unexpected handleError:$1"; }
performRestore '/dev/diskA /dev/diskB' "$imagePath" all no
expected_restore=$'activate:/dev/diskA:deploy_write\npayload:/dev/diskAp1\nactivate:/dev/diskB:deploy_write\npayload:/dev/diskBp1'
[[ $(<"$events") == "$expected_restore" ]] || fail restore-order

# Source a rewritten ordinary-file copy of the downloader with checkin and
# mount imports removed.  This covers the real top-level ordering: the whole
# target set is planned, atomically permitted and reverified before the hook;
# each subsequent table and payload write activates its own binding.
entry="$tmp/pxeos.download"
entry_stubs="$tmp/entry-stubs.sh"
cat >"$entry_stubs" <<'EOF'
rootpxe_storage_path(){ printf '%s\n' "$tmp/image"; }
rootpxe_validate_fixed_image_lvm_inventory(){ :; }
rootpxe_validate_restore_artifacts(){ printf 'preflight\n' >>"$events"; }
getMACAddresses(){ printf x; }
pxeos.statusreporter(){ :; }
rootpxe_plan_mpa_disk_permits(){ rootpxe_mpa_permit_is_batch=yes; rootpxe_mpa_permit_args=(ID_A deploy_write ID_B deploy_write); printf 'plan\n' >>"$events"; }
rootpxe_wait_for_disk_permit_batch(){ printf 'wait-full-batch\n' >>"$events"; }
rootpxe_verify_disk_permit_binding(){ printf 'verify:%s\n' "$1" >>"$events"; }
rootpxe_activate_disk_permit_binding(){ printf 'activate:%s\n' "$1" >>"$events"; }
rootpxe_run_pre_deploy_script(){ printf 'prehook\n' >>"$events"; }
rootpxe_console_message(){ :; }
rootpxe_stage(){ :; }
restorePartitionTablesAndBootLoaders(){ printf 'table:%s\n' "$1" >>"$events"; }
runPartprobe(){ :; }
getPartitions(){ parts=/dev/diskAp1; }
usleep(){ :; }
performRestore(){ for disk in $1; do printf 'payload:%s\n' "$disk" >>"$events"; done; }
completeTasking(){ printf 'complete\n' >>"$events"; }
handleError(){ fail "entry-handleError:$1"; }
EOF
awk -v funcs="$test_funcs" -v stubs="$entry_stubs" '
  /^\. \/usr\/share\/pxeos\/lib\/funcs\.sh$/ { print ". \"" funcs "\""; print ". \"" stubs "\""; next }
  /^\. \/bin\/pxeos\.(checkin|mount|checkmount|checkimgvar)$/ { print ":"; next }
  /^\. \/bin\/pxeos\.inventory / { print ":"; next }
  /^findHDDInfo$/ { print "hd=/dev/diskA; disks=\"/dev/diskA /dev/diskB\""; next }
  { print }
' "$download" >"$entry"
: >"$events"
(
    set -euo pipefail
    type=down imgType=mpa imgPartitionType=all imgFormat=0 imgLegacy=0
    img=fixture imagePath="$tmp/image" osid=0 mc=no nombr=0 mac=000c2958c550 taskid=1 task_token=0123456789abcdef
    web=https://test/ originalSchemaFile= rootpxe_resolved_lvm_layout_file=
    source "$entry"
)
expected_entry=$'preflight\nplan\nwait-full-batch\nverify:/dev/diskA\nverify:/dev/diskB\nprehook\nactivate:/dev/diskA\ntable:/dev/diskA\nactivate:/dev/diskB\ntable:/dev/diskB\npayload:/dev/diskA\npayload:/dev/diskB\ncomplete'
[[ $(<"$events") == "$expected_entry" ]] || { cat "$events" >&2; fail entry-order; }

printf 'PASS: PXEOS mpa permit regression\n'
