#!/usr/bin/env bash
# Offline restore-artifact preflight regression.  It only creates ordinary
# fixture files and calls the pure preflight module; no block device is used.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
module="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/restore-preflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_ok() { "$@" || fail "expected success: $*"; }
expect_fail() {
    set +e
    "$@" >/dev/null 2>&1
    local status=$?
    set -e
    [[ $status -ne 0 ]] || fail "expected failure: $*"
}
file() { mkdir -p "$(dirname "$1")"; printf 'payload\n' >"$1"; }
bootfile() { printf '%*s' "$2" '' | tr ' ' x >"$1"; }
table() { printf 'label: %s\n/dev/mock1 : start=        2048, size=        4096, type=%s\n' "$2" "$3" >"$1"; }

. "$module"

# A plain artifact and a contiguous split artifact are both valid, but sparse,
# mixed, empty, or non-regular artifacts must fail before a writer is reached.
file "$tmp/plain.img"
expect_ok rootpxe_validate_artifact_fragments "$tmp/plain.img"
rm "$tmp/plain.img"
file "$tmp/plain.img.000"
file "$tmp/plain.img.001"
expect_ok rootpxe_validate_artifact_fragments "$tmp/plain.img"
rm "$tmp/plain.img.001"
file "$tmp/plain.img.002"
expect_fail rootpxe_validate_artifact_fragments "$tmp/plain.img"
rm -f "$tmp/plain.img.000" "$tmp/plain.img.002"
file "$tmp/plain.img"
file "$tmp/plain.img.000"
expect_fail rootpxe_validate_artifact_fragments "$tmp/plain.img"

[[ $(rootpxe_preflight_normalized_type 0x05) == 5 ]] || fail 'MBR 0x05 was not normalized'
[[ $(rootpxe_preflight_normalized_type 05) == 5 ]] || fail 'MBR 05 was not normalized'
expect_ok rootpxe_preflight_extended_type 0x0f
printf 'label: dos\n/dev/nvme0n1p7 : start=        2048, size=        4096, type=83\n' >"$tmp/nvme.partitions"
[[ $(rootpxe_preflight_table_rows "$tmp/nvme.partitions") == '7|2048|4096|83' ]] || fail 'NVMe partition number was not extracted'
printf 'label: dos\n/dev/mock1 : start=        2048, size=        4096, type=83\n/dev/mock2 : start=          -1, size=        4096, type=83\n' >"$tmp/bad.partitions"
expect_fail rootpxe_preflight_table_rows "$tmp/bad.partitions"

n="$tmp/n"
mkdir "$n"
cat >"$n/schema.json" <<'JSON'
{"version":2,"partitionTable":"mbr","logicalSectorBytes":512,"originalDiskBytes":16777216,"partitions":[
 {"number":1,"kind":"primary","startSectors":8,"role":"data","fs":"ext4","artifact":"d1p1.img"},
 {"number":2,"kind":"primary","startSectors":16,"role":"swap","fs":"swap","artifact":""},
 {"number":3,"kind":"extended","startSectors":32,"role":"extended_container","fs":"","artifact":""}]}
JSON
file "$n/d1p1.img"
table "$n/d1.partitions" dos 83
bootfile "$n/d1.mbr" 512
expect_ok rootpxe_validate_restore_artifacts "$n" n all "$n/schema.json"
expect_ok rootpxe_validate_restore_artifacts "$n" n 1 "$n/schema.json"
expect_ok rootpxe_validate_restore_artifacts "$n" n 2 "$n/schema.json"
expect_ok rootpxe_validate_restore_artifacts "$n" n 3 "$n/schema.json"
rm "$n/d1p1.img"
expect_fail rootpxe_validate_restore_artifacts "$n" n all "$n/schema.json"
expect_fail rootpxe_validate_restore_artifacts "$n" n 1 "$n/schema.json"
file "$n/d1p1.img.000"
file "$n/d1p1.img.002"
expect_fail rootpxe_validate_restore_artifacts "$n" n all "$n/schema.json"
rm -f "$n/d1p1.img.000" "$n/d1p1.img.002"
file "$n/d1p1.img"
rm "$n/d1.mbr"
expect_fail rootpxe_validate_restore_artifacts "$n" n all "$n/schema.json"
bootfile "$n/d1.mbr" 512
printf 'short\n' >"$n/d1.mbr"
expect_fail rootpxe_validate_restore_artifacts "$n" n all "$n/schema.json"
bootfile "$n/d1.mbr" 512

# Keep parsing strict even when a production caller has not enabled pipefail:
# the second expected payload must still be checked after a valid first one.
cat >"$n/two-payload-schema.json" <<'JSON'
{"version":2,"partitionTable":"mbr","logicalSectorBytes":512,"partitions":[{"number":1,"startSectors":8,"role":"data","fs":"ext4","artifact":"d1p1.img"},{"number":2,"startSectors":16,"role":"data","fs":"ext4","artifact":"d1p2.img"}]}
JSON
set +o pipefail
expect_fail rootpxe_validate_restore_artifacts "$n" n all "$n/two-payload-schema.json"
set -o pipefail

# A schema LVM PV is not a raw payload exception: its PV metadata, VG config,
# and every non-swap LV image are required.
cat >"$n/lvm-schema.json" <<'JSON'
{"version":2,"partitionTable":"mbr","logicalSectorBytes":512,"originalDiskBytes":16777216,"partitions":[{"number":1,"startSectors":8,"role":"lvm_pv","fs":"LVM2_member","artifact":""}],"lvm":{"version":1,"captureMode":"per_lv","resizePolicy":"grow_only","pvs":[{"partitionNumber":1,"uuid":"pv-1","vgUuid":"vg-1","originalBytes":1048576,"minBytes":1048576,"peStartBytes":512,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"}],"vgs":[{"name":"vg0","uuid":"vg-1","extentBytes":4096,"pvPartitionNumbers":[1],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root","layout":"linear","originalBytes":4096,"minBytes":4096,"fs":"ext4","role":"data","resizable":true,"artifact":"d1p1.lvm.lv.root.img"},{"name":"swap","uuid":"lv-swap","layout":"linear","originalBytes":4096,"minBytes":4096,"fs":"swap","role":"swap","resizable":false,"artifact":"","swapUuid":"swap-1"}]}]}}
JSON
file "$n/d1p1.lvm.pv.meta"
file "$n/d1p1.lvm.vg.cfg"
file "$n/d1p1.lvm.lv.root.img"
expect_ok rootpxe_validate_restore_artifacts "$n" n all "$n/lvm-schema.json"
rm "$n/d1p1.lvm.vg.cfg"
expect_fail rootpxe_validate_restore_artifacts "$n" n all "$n/lvm-schema.json"
file "$n/d1p1.lvm.vg.cfg"

# Fixed images with inventory must not downgrade malformed inventory to legacy
# files.  Valid inventory drives the exact disk facts and payload set.
mpa="$tmp/mpa"
mkdir "$mpa"
cat >"$mpa/.rootpxe-partition-inventory.json" <<'JSON'
{"version":1,"disks":[
 {"number":1,"partitionTable":"mbr","originalDiskBytes":1000,"logicalSectorBytes":512,"physicalSectorBytes":512,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"typeGuid":"83","fs":"ext4"}]},
 {"number":2,"partitionTable":"gpt","originalDiskBytes":2000,"logicalSectorBytes":512,"physicalSectorBytes":512,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"typeGuid":"0FC63DAF","fs":"xfs"}]}]}
JSON
table "$mpa/d1.partitions" dos 83
table "$mpa/d2.partitions" gpt 0FC63DAF
file "$mpa/d1.mbr"
file "$mpa/d2.mbr"
file "$mpa/d1p1.img"
file "$mpa/d2p1.img"
file "$mpa/d1.has_grub"
expect_ok rootpxe_validate_restore_artifacts "$mpa" mpa all
rm "$mpa/d1.has_grub"
expect_ok rootpxe_validate_restore_artifacts "$mpa" mpa 1
facts=$(rootpxe_fixed_restore_disk_facts "$mpa") || fail 'complete mpa facts failed'
[[ $facts == $'1|1000\n2|2000' ]] || fail "unexpected mpa facts: $facts"
imgType=mpa
expect_ok rootpxe_validate_fixed_image_lvm_inventory "$mpa"
rm "$mpa/d2p1.img"
expect_fail rootpxe_validate_restore_artifacts "$mpa" mpa all
file "$mpa/d2p1.img"
printf '{bad json\n' >"$mpa/.rootpxe-partition-inventory.json"
file "$mpa/d1.size"
file "$mpa/d2.size"
set +o pipefail
expect_fail rootpxe_validate_restore_artifacts "$mpa" mpa all
expect_fail rootpxe_fixed_restore_disk_facts "$mpa"
expect_fail rootpxe_preflight_table_rows "$tmp/bad.partitions"
set -o pipefail

# A historical mpa has no inventory but does have every continuous dN.size
# record.  A historical mps deliberately has no d1.size and remains valid.
legacy="$tmp/legacy"
mkdir "$legacy"
printf '1:1000\n' >"$legacy/d1.size"
table "$legacy/d1.partitions" dos 83
file "$legacy/d1.mbr"
file "$legacy/d1p1.img"
expect_ok rootpxe_validate_restore_artifacts "$legacy" mpa all
[[ $(rootpxe_fixed_restore_disk_facts "$legacy") == '1|1000' ]] || fail 'legacy mpa facts mismatch'
table "$legacy/d3.partitions" dos 83
printf '3:3000\n' >"$legacy/d3.size"
expect_fail rootpxe_validate_restore_artifacts "$legacy" mpa all
rm "$legacy/d3.partitions" "$legacy/d3.size"
imgType=mpa
expect_ok rootpxe_validate_fixed_image_lvm_inventory "$legacy"
rm "$legacy/d1.size"
expect_fail rootpxe_validate_restore_artifacts "$legacy" mpa all
expect_fail rootpxe_fixed_restore_disk_facts "$legacy"
imgType=mps
expect_ok rootpxe_validate_restore_artifacts "$legacy" mps all
expect_ok rootpxe_validate_fixed_image_lvm_inventory "$legacy"
expect_fail rootpxe_fixed_restore_disk_facts "$legacy"
rm "$legacy/d1.mbr"
expect_fail rootpxe_validate_restore_artifacts "$legacy" mps mbr

# Legacy Windows GPT/FAT facts are explicitly non-LVM, while unrecognized
# table types remain fail-closed in the fixed-image LVM gate.
winlegacy="$tmp/winlegacy"
mkdir "$winlegacy"
printf '1:1000\n' >"$winlegacy/d1.size"
table "$winlegacy/d1.partitions" gpt C12A7328-F81F-11D2-BA4B-00A0C93EC93B
file "$winlegacy/d1.mbr"
file "$winlegacy/d1p1.img"
imgType=mpa
expect_ok rootpxe_validate_fixed_image_lvm_inventory "$winlegacy"
expect_ok rootpxe_validate_restore_artifacts "$winlegacy" mpa all

# Whole-disk dd permits an intentionally unpartitioned capture, so only its
# selected overall payload is required.
dd="$tmp/dd"
mkdir "$dd"
file "$dd/raw.img"
img=raw.img
expect_ok rootpxe_validate_restore_artifacts "$dd" dd all
rm "$dd/raw.img"
expect_fail rootpxe_validate_restore_artifacts "$dd" dd all

# This harness sources only the module and all validation above operates on
# temporary regular-file fixtures; it has no block-device argument or writer.
printf 'PASS: restore preflight rejects incomplete artifacts before disk writes\n'
