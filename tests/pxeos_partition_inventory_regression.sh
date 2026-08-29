#!/usr/bin/env bash
# Uses the installed jq and only temporary command stubs; no host disk is read.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "real jq required"
mkdir -p "$tmp/bin" "$tmp/capture"
cat >"$tmp/bin/blockdev" <<'EOF'
#!/usr/bin/env bash
case "$1:$2" in
  --getss:*) echo 512;; --getpbsz:*) echo 512;;
  --getsize64:/dev/nvme0n1) echo 1073741824;; --getsize64:/dev/sda) echo 536870912;;
  *) exit 1;; esac
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case "$last:$2" in
  /dev/nvme0n1p1:TYPE) echo vfat;; /dev/nvme0n1p1:UUID) echo efi-uuid;; /dev/nvme0n1p1:PARTUUID) echo efi-partuuid;;
  /dev/sda1:TYPE) echo xfs;; /dev/sda1:UUID) echo data-uuid;; /dev/sda1:PARTUUID) echo data-partuuid;;
esac
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
: >"$tmp/proc-cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0; . "$tmp/funcs.sh"
getPartitions() { case "$1" in /dev/nvme0n1) parts='/dev/nvme0n1p1';; /dev/sda) parts='/dev/sda1';; *) parts='';; esac; }
cat >"$tmp/capture/d1.partitions" <<'EOF'
label: gpt
device: /dev/nvme0n1
unit: sectors
sector-size: 512
/dev/nvme0n1p1 : start=        2048, size=     1024000, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
EOF
rootpxe_build_partition_inventory "$tmp/capture" mps /dev/nvme0n1 "" || fail mps
jq -e '.version == 1 and (.disks|length)==1 and .disks[0].partitions[0].fs == "vfat" and .disks[0].partitions[0].uuid == "efi-uuid"' "$rootpxe_partition_inventory_file" >/dev/null || fail mps-facts
# This exercises the real jq invocation in the n schema builder with no LVM
# rawfile supplied, which previously compiled `$lvm` as an undefined variable.
cp "$tmp/capture/d1.partitions" "$tmp/capture/d1.minimum.partitions"
: >"$tmp/capture/d1p1.img"
rootpxe_build_original_schema /dev/nvme0n1 "$tmp/capture" || fail n-schema-real-jq
jq -e '.partitionTable == "gpt" and .partitions[0].fs == "vfat"' "$rootpxe_original_schema_file" >/dev/null || fail n-schema-facts
# Exercise the production LVM layout resolver with the real jq binary too.
# The separate LVM suite intentionally replaces jq to focus on command-flow
# failures, so it cannot detect jq syntax or result-shape regressions here.
cat >"$tmp/lvm-schema.json" <<'EOF'
{"version":2,"logicalSectorBytes":512,"lvm":{"version":2,"pvs":[{"partitionNumber":1,"uuid":"pv-1","vgUuid":"vg-1","originalBytes":268435456,"minBytes":67108864,"peStartBytes":1048576,"artifact":"d1.pv.meta","vgConfigArtifact":"d1.vg.cfg"}],"vgs":[{"name":"vg0","uuid":"vg-1","extentBytes":4194304,"pvPartitionNumbers":[1],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root","layout":"linear","originalBytes":67108864,"minBytes":67108864,"fs":"ext4","role":"data","resizable":true,"artifact":"d1.lv.img"}]}]}}
EOF
printf '%s\n' '{"lvm":[{"pvPartitionNumber":1,"freeSpacePolicy":"preserveOriginal","volumes":[{"uuid":"lv-root","mode":"original"}]}]}' >"$tmp/lvm-layout.json"
printf '%s\n' '[{"number":1,"resolvedSectors":524288}]' >"$tmp/lvm-partitions.json"
rootpxe_validate_lvm_deployment_layout "$tmp/lvm-schema.json" "$tmp/lvm-layout.json" "$tmp/lvm-partitions.json" || fail lvm-layout-real-jq
jq -e '.volumes|type == "array" and length == 1 and .[0].resolvedBytes == 67108864' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail lvm-layout-result-shape
cat >"$tmp/capture/d2.partitions" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
sector-size: 512
/dev/sda1 : start=        2048, size=      524288, type=83
EOF
rootpxe_build_partition_inventory "$tmp/capture" mpa /dev/nvme0n1 "/dev/nvme0n1 /dev/sda" || fail mpa
jq -e '[.disks[].number] == [1,2] and .disks[0].partitionTable == "gpt" and .disks[1].partitionTable == "mbr"' "$rootpxe_partition_inventory_file" >/dev/null || fail mpa-order
rm -f "$tmp/capture/d1.partitions"
rootpxe_build_partition_inventory "$tmp/capture" dd /dev/nvme0n1 "" || fail dd
jq -e '.disks[0].partitionTable == "none" and (.disks[0].partitions|length)==0' "$rootpxe_partition_inventory_file" >/dev/null || fail dd-none
cat >"$tmp/capture/d1.partitions" <<'EOF'
label: gpt
device: /dev/nvme0n1
unit: sectors
sector-size: 512
EOF
rootpxe_build_partition_inventory "$tmp/capture" dd /dev/nvme0n1 "" || fail dd-empty-gpt
jq -e '.disks[0].partitionTable == "gpt" and (.disks[0].partitions|length)==0' "$rootpxe_partition_inventory_file" >/dev/null || fail dd-empty-gpt-facts
sed 's/^label: gpt$/label: dos/' "$tmp/capture/d1.partitions" >"$tmp/capture/d1.partitions.mbr"
mv "$tmp/capture/d1.partitions.mbr" "$tmp/capture/d1.partitions"
rootpxe_build_partition_inventory "$tmp/capture" dd /dev/nvme0n1 "" || fail dd-empty-mbr
jq -e '.disks[0].partitionTable == "mbr" and (.disks[0].partitions|length)==0' "$rootpxe_partition_inventory_file" >/dev/null || fail dd-empty-mbr-facts
# Run imgcomplete itself with only its callback/finalisation collaborators
# mocked.  Every successful capture type must submit the inventory, while n
# is the only one that additionally produces editable schema metadata.
for image_type in n mps mpa dd; do
  callback="$tmp/finish-$image_type.args"
  export callback
  type=up imgType="$image_type" hd=/dev/nvme0n1 disks='/dev/nvme0n1 /dev/sda' \
    taskid=42 task_token=token mac=aa:bb:cc:dd:ee:ff web=https://rootpxe.invalid/ \
    env -u rootpxe_original_schema_file -u rootpxe_partition_inventory_file bash -s -- "$overlay/bin/pxeos.imgcomplete" "$tmp" <<'EOF'
script=$1; test_tmp=$2
dmidecode() { printf '%s\n' test-uuid; }
rootpxe_require_task_context() { :; }
rootpxe_stage() { :; }
rootpxe_finalize_capture() { rootpxe_final_capture_path="$test_tmp/capture"; capture_size_bytes=8; }
rootpxe_build_partition_inventory() { rootpxe_partition_inventory_file="$test_tmp/inventory-${imgType}"; printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mock","partitionTable":"none","originalDiskBytes":1,"logicalSectorBytes":1,"physicalSectorBytes":1,"partitions":[]}]}' >"$rootpxe_partition_inventory_file"; }
rootpxe_build_original_schema() { rootpxe_original_schema_file="$test_tmp/schema-${imgType}"; printf '%s\n' '{"version":1}' >"$rootpxe_original_schema_file"; }
rootpxe_clear_capture_marker() { :; }
rootpxe_cleanup_task_json() { :; }
rootpxe_console_message() { :; }
dots() { :; }
debugPause() { :; }
curl() { printf '%s\n' "$@" >"$callback"; printf '%s\n' '{"success":true}'; }
# shellcheck disable=SC1090
. "$script"
EOF
  grep -Fq 'partitionInventory={"version":1' "$callback" || fail "imgcomplete-$image_type-inventory"
  if [[ $image_type == n ]]; then
    grep -Fq 'originalSchema={"version":1}' "$callback" || fail imgcomplete-n-schema
  elif grep -Fq 'originalSchema=' "$callback"; then
    fail "imgcomplete-$image_type-fixed-schema"
  fi
done
echo 'PASS: PXEOS partition inventory regression'
