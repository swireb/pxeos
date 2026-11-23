#!/usr/bin/env bash
# Real jq resolver and real sfdisk on temporary ordinary files only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="${PXEOS_FUNCS:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh}"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"; rm -f -- "${rootpxe_resolved_layout_file:-}"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for name in rootpxe_validate_partition_lba_contract rootpxe_validate_deployment_layout rootpxe_canonical_json_hash rootpxe_register_derived_layout_file rootpxe_gpt_backup_sectors rootpxe_apply_deployment_layout rootpxe_sfdisk_layout_fingerprint; do
    eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$funcs")"
done
rootpxe_lvm_json_jq(){ command jq "$@"; }
# LVM executor has separate integration coverage; this suite pins physical geometry.
rootpxe_validate_lvm_deployment_layout(){ return 0; }
blockdev(){ case "$1" in --getsize64) echo "$fixture_target_bytes";; --getss) echo 512;; --rereadpt) :;; *) return 1;; esac; }
reset_schema(){
    local table=${1:-gpt} version=${2:-1}
    jq -n --arg table "$table" --argjson version "$version" '{version:$version,partitionTable:$table,originalDiskBytes:1000000000000,minDeployBytes:1000000000000,logicalSectorBytes:512,physicalSectorBytes:512,partitions:[{number:1,startSectors:2048,originalSectors:585937500,minSectors:585937500,fs:"ext4",role:"data",resizable:true}]} | if $version==2 then .partitions[0] += {kind:"primary",typeGuid:(if $table=="mbr" then "0x83" else "0FC63DAF-8483-4772-8E79-3D69D8477DE4" end)} else . end' >"$tmp/schema"
    schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema"); schemaRevision=1
    jq -n --arg hash "$schemaHash" '{version:1,schemaHash:$hash,partitions:[{number:1,mode:"original"}]}' >"$tmp/layout"
}
resolve(){ rm -f -- "${rootpxe_resolved_layout_file:-}"; rootpxe_validate_deployment_layout /dev/mock "$tmp/schema" "$tmp/layout" "${1:-}"; }
for table in gpt mbr; do for version in 1 2; do
    reset_schema "$table" "$version"
    original_hash=$schemaHash; cp "$tmp/schema" "$tmp/unchanged-schema"; cp "$tmp/layout" "$tmp/unchanged-layout"
    for fixture_target_bytes in 500000000000 1000000000000 2000000000000; do
        resolve || fail "$table-v$version-target-$fixture_target_bytes"
        jq -e '.[0].startSectors==2048 and .[0].resolvedSectors==585937500' "$rootpxe_resolved_layout_file" >/dev/null || fail original-position-or-size
        [[ $rootpxe_deployment_layout_changed == no ]] || fail original-layout-marked-adjusted
    done
    cmp "$tmp/schema" "$tmp/unchanged-schema" && cmp "$tmp/layout" "$tmp/unchanged-layout" || fail metadata-mutated
    [[ $(rootpxe_canonical_json_hash "$tmp/schema") == "$original_hash" ]] || fail schema-hash-mutated
done; done
printf 'PASS: old v1/v2 GPT/MBR metadata and original geometry on smaller/equal/larger disks\n'
reset_schema
end=$((2048+585937500))
fixture_target_bytes=$(((end+33)*512)); resolve || fail exact-gpt-backup-fit
fixture_target_bytes=$(((end+32)*512)); if resolve >/dev/null 2>&1; then fail insufficient-gpt-backup; fi
reset_schema mbr 2
fixture_target_bytes=$((end*512)); resolve || fail exact-mbr-fit
fixture_target_bytes=$(((end-1)*512)); if resolve >/dev/null 2>&1; then fail partition-overflow; fi
reset_schema
jq '.partitions += [.partitions[0] + {number:2,startSectors:1757812500,originalSectors:2048,minSectors:2048}]' "$tmp/schema" >"$tmp/next"; mv "$tmp/next" "$tmp/schema"
schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema")
jq --arg hash "$schemaHash" '.schemaHash=$hash | .partitions += [{number:2,mode:"original"}]' "$tmp/layout" >"$tmp/next"; mv "$tmp/next" "$tmp/layout"
fixture_target_bytes=500000000000; if resolve >/dev/null 2>&1; then fail distant-tail-partition; fi
reset_schema
for mode in fixed remaining; do
    jq --arg mode "$mode" '.partitions[0] = {number:1,mode:$mode} + (if $mode=="fixed" then {fixedBytes:350000000000} else {} end)' "$tmp/layout" >"$tmp/next"; mv "$tmp/next" "$tmp/layout"
    fixture_target_bytes=500000000000; resolve || fail "$mode-small-disk"
    jq -e '.[0].resolvedSectors>=.[0].originalSectors' "$rootpxe_resolved_layout_file" >/dev/null || fail partition-shrink
done
jq '.partitions[0]={number:1,mode:"fixed",fixedBytes:250000000000}' "$tmp/layout" >"$tmp/next"; mv "$tmp/next" "$tmp/layout"
if resolve >/dev/null 2>&1; then fail fixed-shrink; fi
printf 'PASS: partition end/backup boundaries, distant tail and grow-only custom layouts\n'
cat >"$tmp/schema" <<'SCHEMA'
{"version":2,"partitionTable":"mbr","originalDiskBytes":1000000000000,"minDeployBytes":1000000000000,"logicalSectorBytes":512,"physicalSectorBytes":512,"partitions":[
{"number":1,"kind":"primary","typeGuid":"0x83","startSectors":2048,"originalSectors":1000,"minSectors":1000,"role":"data","fs":"ext4","resizable":true},
{"number":2,"kind":"extended","typeGuid":"0x0f","startSectors":4096,"originalSectors":8192,"minSectors":8192,"role":"extended_container","resizable":false,"logicalNumbers":[5,6],"ebrReservedSectors":2},
{"number":5,"kind":"logical","typeGuid":"0x83","parentNumber":2,"startSectors":4098,"originalSectors":1000,"minSectors":1000,"role":"data","fs":"ext4","resizable":true},
{"number":6,"kind":"logical","typeGuid":"0x83","parentNumber":2,"startSectors":6146,"originalSectors":1000,"minSectors":1000,"role":"data","fs":"ext4","resizable":true}]}
SCHEMA
schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema")
jq -n --arg hash "$schemaHash" '{schemaHash:$hash,partitions:[{number:1,mode:"original"},{number:2,mode:"derived"},{number:5,mode:"original"},{number:6,mode:"original"}]}' >"$tmp/layout"
fixture_target_bytes=$((12288*512)); resolve || fail original-mbr-extended-tail-exact-fit
jq -e --slurpfile schema "$tmp/schema" 'map(del(.resolvedSectors))==$schema[0].partitions and all(.[]; .resolvedSectors==.originalSectors)' "$rootpxe_resolved_layout_file" >/dev/null || fail original-mbr-extended-ebr-geometry-mutated
fixture_target_bytes=$((10000*512)); if resolve >/dev/null 2>&1; then fail original-mbr-container-tail-exceeds-target; fi
printf 'PASS: original MBR extended container/EBR exact fit and retained tail overflow rejection\n'

# End-to-end table writer: only sfdisk is real, and its operand is always a
# newly-created ordinary file. No block device, mount, or kernel reread occurs.
real_sfdisk=$(command -v sfdisk) || fail sfdisk-required
rootpxe_cleanup_deployment_partition_file(){ :; }
rootpxe_require_unused_target_disks(){ :; }
rootpxe_layout_apply_failed(){ printf 'writer rejected: %s\n' "$*" >&2; return 1; }
rootpxe_layout_readback_failed(){ printf 'readback rejected: %s\n' "$*" >&2; return 1; }
rootpxe_log_raw_file(){ rootpxe_log_raw_path=$(mktemp "$tmp/raw.XXXXXX"); }
rootpxe_log_publish(){ :; }
udevadm(){ :; }
flock(){
    [[ $1 == /dev/mock && $2 == sfdisk ]] || fail unexpected-writer
    if [[ $3 == -d ]]; then
        "$real_sfdisk" -d "$tmp/disk" | sed "s|$tmp/disk|/dev/mock|g"
    else
        [[ -f $tmp/disk && ! -b $tmp/disk ]] || fail ordinary-file-required
        cat >"$tmp/written-template"
        "$real_sfdisk" --no-reread --no-tell-kernel "$tmp/disk" <"$tmp/written-template" >>"$tmp/native-sfdisk.log" 2>&1
    fi
}
for number in 2 9 10 128; do
    printf '/dev/source%s : start=2048, size=1000\n' "$number" >"$tmp/entry-count-template"
    [[ $(rootpxe_gpt_backup_sectors "$tmp/entry-count-template" 512) == 33 ]] || fail "default-entry-count-number-$number"
    [[ $(rootpxe_gpt_backup_sectors "$tmp/entry-count-template" 4096) == 5 ]] || fail "default-4kn-entry-count-number-$number"
    printf 'table-length: 512\n' >>"$tmp/entry-count-template"
    [[ $(rootpxe_gpt_backup_sectors "$tmp/entry-count-template" 512) == 129 ]] || fail "explicit-entry-count-number-$number"
    [[ $(rootpxe_gpt_backup_sectors "$tmp/entry-count-template" 4096) == 17 ]] || fail "explicit-4kn-entry-count-number-$number"
done
for entries in 128 512; do
  for fixture_partition_sectors in 1000 10000; do
    reset_schema
    # Small fixture retains first usable LBA=2048 but only metadata-minimum
    # space at the end, proving first-lba is not a tail reservation.
    jq --argjson sectors "$fixture_partition_sectors" '.partitions[0].originalSectors=$sectors | .partitions[0].minSectors=$sectors' "$tmp/schema" >"$tmp/next"; mv "$tmp/next" "$tmp/schema"
    schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema"); jq --arg hash "$schemaHash" '.schemaHash=$hash' "$tmp/layout" >"$tmp/next"; mv "$tmp/next" "$tmp/layout"
    backup=$(((entries*128+511)/512+1)); fixture_target_bytes=$(((2048+fixture_partition_sectors+backup)*512))
    cat >"$tmp/template" <<TABLE
label: gpt
label-id: 11111111-2222-3333-4444-555555555555
device: /dev/source
unit: sectors
sector-size: 512
first-lba: 2048
last-lba: 1953124966
TABLE
    [[ $entries == 128 ]] || echo "table-length: $entries" >>"$tmp/template"
    echo "/dev/source1 : start=2048, size=$fixture_partition_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name=\"data\"" >>"$tmp/template"
    cp "$tmp/template" "$tmp/unchanged-template"
    resolve "$tmp/template" || fail "gpt-$entries-template-exact-fit"
    fixture_target_bytes=$((fixture_target_bytes-512)); if resolve "$tmp/template" >/dev/null 2>&1; then fail "gpt-$entries-template-one-sector-short"; fi
    fixture_target_bytes=$((fixture_target_bytes+512)); resolve "$tmp/template" || fail template-resolve-again
    truncate -s "$fixture_target_bytes" "$tmp/disk"
    rootpxe_apply_deployment_layout /dev/mock "$tmp/template" || fail "native-gpt-$entries-writer"
    "$real_sfdisk" --json "$tmp/disk" >"$tmp/readback"
    jq -e --argjson last "$((2048+fixture_partition_sectors-1))" --argjson size "$fixture_partition_sectors" '.partitiontable.lastlba==$last and (.partitiontable.id|ascii_downcase)=="11111111-2222-3333-4444-555555555555" and .partitiontable.partitions[0].start==2048 and .partitiontable.partitions[0].size==$size and (.partitiontable.partitions[0].uuid|ascii_downcase)=="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"' "$tmp/readback" >/dev/null || fail "native-gpt-$entries-identity-or-range"
    cmp "$tmp/template" "$tmp/unchanged-template" || fail source-template-mutated
    sed 's/first-lba: 2048/first-lba: 2049/' "$tmp/template" >"$tmp/bad-template"
    if resolve "$tmp/bad-template" >/dev/null 2>&1; then fail partition-precedes-first-usable-lba; fi
    # A second partition catches awk string-vs-number comparisons when the
    # highest partition number is used to choose the default table length.
    half=$((fixture_partition_sectors/2))
    jq --argjson half "$half" '.partitions[0].originalSectors=$half | .partitions[0].minSectors=$half | .partitions += [.partitions[0] + {number:2,startSectors:(2048+$half)}]' "$tmp/schema" >"$tmp/next"; mv "$tmp/next" "$tmp/schema"
    schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema")
    jq --arg hash "$schemaHash" '.schemaHash=$hash | .partitions += [{number:2,mode:"original"}]' "$tmp/layout" >"$tmp/next"; mv "$tmp/next" "$tmp/layout"
    sed "s/size=$fixture_partition_sectors,/size=$half,/" "$tmp/template" >"$tmp/next"; mv "$tmp/next" "$tmp/template"
    printf '/dev/source2 : start=%s, size=%s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF, name="data2"\n' "$((2048+half))" "$half" >>"$tmp/template"
    resolve "$tmp/template" || fail "two-partition-$entries-template"
    rootpxe_apply_deployment_layout /dev/mock "$tmp/template" || fail "native-two-partition-$entries-writer"
    "$real_sfdisk" --json "$tmp/disk" >"$tmp/readback"
    jq -e --argjson last "$((2048+fixture_partition_sectors-1))" --argjson half "$half" '.partitiontable.lastlba==$last and (.partitiontable.partitions|length)==2 and .partitiontable.partitions[0].size==$half and .partitiontable.partitions[1].start==(2048+$half) and .partitiontable.partitions[1].size==$half and (.partitiontable.partitions[1].uuid|ascii_downcase)=="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"' "$tmp/readback" >/dev/null || fail "native-two-partition-$entries-readback"
  done
done
printf 'PASS: real sfdisk ordinary-file GPT 128/512-entry exact fit, identity and usable LBA readback\n'
# Explicit undersized table-length must be rejected, never silently enlarged.
sed 's/table-length: 512/table-length: 0/' "$tmp/template" >"$tmp/bad-template"
if resolve "$tmp/bad-template" >/dev/null 2>&1; then fail malformed-table-length; fi
sed 's/table-length: 512/table-length: 1/' "$tmp/template" >"$tmp/bad-template"
jq '.partitions=[.partitions[1]]' "$tmp/schema" >"$tmp/next"; mv "$tmp/next" "$tmp/schema"
schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema"); jq --arg hash "$schemaHash" '.schemaHash=$hash | .partitions=[{number:2,mode:"original"}]' "$tmp/layout" >"$tmp/next"; mv "$tmp/next" "$tmp/layout"
if resolve "$tmp/bad-template" >/dev/null 2>&1; then fail table-length-cannot-cover-number; fi
printf 'PASS: malformed and undersized explicit GPT table-length rejected\n'

# A GPT image whose first partition begins far into the source disk (e.g. 100MiB)
# must cap custom tail alignment reservation at 1MiB instead of wasting 100MiB at
# the tail, while real sfdisk writes and reads back cleanly on the smaller disk.
jq -n '{version:1,partitionTable:"gpt",originalDiskBytes:2147483648,minDeployBytes:2147483648,logicalSectorBytes:512,physicalSectorBytes:512,partitions:[{number:1,startSectors:204800,originalSectors:2048,minSectors:2048,fs:"ext4",role:"data",resizable:true}]}' >"$tmp/schema"
schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema"); schemaRevision=1
cat >"$tmp/template" <<'TABLE'
label: gpt
label-id: 11111111-2222-3333-4444-555555555555
device: /dev/source
unit: sectors
sector-size: 512
first-lba: 34
last-lba: 4194270
/dev/source1 : start=204800, size=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name="data"
TABLE
fixture_target_bytes=$((120 * 1024 * 1024))
for mode in fixed remaining; do
    jq -n --arg hash "$schemaHash" --arg mode "$mode" '{version:1,schemaHash:$hash,partitions:[{number:1,mode:$mode} + (if $mode=="fixed" then {fixedBytes:10485760} else {} end)]}' >"$tmp/layout"
    resolve "$tmp/template" || fail "large-front-gpt-$mode-small-disk"
    truncate -s "$fixture_target_bytes" "$tmp/disk"
    rootpxe_apply_deployment_layout /dev/mock "$tmp/template" || fail "large-front-gpt-$mode-apply"
done
# Out-of-order partition numbers (p3 physically before p2) must preserve source order.
jq -n '{version:1,partitionTable:"gpt",originalDiskBytes:2147483648,minDeployBytes:2147483648,logicalSectorBytes:512,physicalSectorBytes:512,partitions:[{number:1,startSectors:2048,originalSectors:2048,minSectors:2048,fs:"ext4",role:"data",resizable:false},{number:2,startSectors:8192,originalSectors:2048,minSectors:2048,fs:"ext4",role:"data",resizable:false},{number:3,startSectors:4096,originalSectors:2048,minSectors:2048,fs:"ext4",role:"data",resizable:true}]}' >"$tmp/schema"
schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema")
jq -n --arg hash "$schemaHash" '{version:1,schemaHash:$hash,partitions:[{number:1,mode:"original"},{number:2,mode:"original"},{number:3,mode:"remaining"}]}' >"$tmp/layout"
cat >"$tmp/template" <<'TABLE'
label: gpt
label-id: 11111111-2222-3333-4444-555555555555
device: /dev/source
unit: sectors
sector-size: 512
first-lba: 34
last-lba: 4194270
/dev/source1 : start=2048, size=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-BBBB-CCCC-DDDD-111111111111, name="p1"
/dev/source2 : start=8192, size=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-BBBB-CCCC-DDDD-222222222222, name="p2"
/dev/source3 : start=4096, size=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-BBBB-CCCC-DDDD-333333333333, name="p3"
TABLE
fixture_target_bytes=$((20 * 1024 * 1024))
resolve "$tmp/template" || fail out-of-order-gpt-remaining-resolve
jq -e '([.[]|select(.number==1)][0].startSectors == 2048) and ([.[]|select(.number==3)][0].startSectors == 4096) and ([.[]|select(.number==3)][0].resolvedSectors > 2048) and ([.[]|select(.number==2)][0].startSectors > [.[]|select(.number==3)][0].startSectors)' "$rootpxe_resolved_layout_file" >/dev/null || fail out-of-order-gpt-physical-order
printf 'PASS: capped GPT tail reservation and physical order preservation for out-of-order partitions\n'

# Verify makeSwapSystem (MBR 0x82) and restoreUUIDInformation (POSIX awk).
part_funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/partition-funcs.sh"
for name in makeSwapSystem restoreUUIDInformation; do
    eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$part_funcs")"
done
(
    swap_trace="$tmp/swap.trace"; : >"$swap_trace"
    printf '%s\n' '2 22222222-2222-2222-2222-222222222222' >"$tmp/swapuuids"
    printf '%s\n' '/dev/mock2 : start=2048, size=1024, type=0x82' >"$tmp/mbr.sfdisk"
    getDiskFromPartition(){ disk=/dev/mock; }
    getPartitionNumber(){ part_number=${1##*mock}; }
    hasGPT(){ hasgpt=0; }
    flock(){ cat "$tmp/mbr.sfdisk"; }
    dots(){ :; }; debugPause(){ :; }
    mkswap(){ printf 'mkswap:%s\n' "$*" >>"$swap_trace"; }
    makeSwapSystem "$tmp/swapuuids" /dev/mock2 || fail mbr-hex82-swap
    grep -Fqx 'mkswap:-U 22222222-2222-2222-2222-222222222222 /dev/mock2' "$swap_trace" || fail mbr-hex82-swap-did-not-run
)
(
    sgdisk_trace="$tmp/sgdisk.trace"; : >"$sgdisk_trace"
    cat >"$tmp/gpt.sfdisk" <<'SF'
label: gpt
label-id: DDDDDDDD-1111-2222-3333-444444444444
/dev/mock1 : start=2048, size=1024, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=11111111-AAAA-BBBB-CCCC-000000000001
/dev/mock10 : start=4096, size=1024, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-AAAA-BBBB-CCCC-000000000010
SF
    hasGPT(){ hasgpt=1; }
    getPartitions(){ parts='/dev/mock1 /dev/mock10'; }
    partitionIsSwap(){ is_swap=0; }
    getPartitionNumber(){ part_number=${1##*mock}; }
    dots(){ :; }; debugPause(){ :; }; handleWarning(){ fail "unexpected-warning:$*"; }
    sgdisk(){ printf 'sgdisk:%s\n' "$*" >>"$sgdisk_trace"; }
    udevadm(){ printf 'udevadm:%s\n' "$*" >>"$sgdisk_trace"; }
    restoreUUIDInformation /dev/mock "$tmp/gpt.sfdisk" 1 "$tmp" || fail posix-awk-restore-uuid
    grep -Fqx 'sgdisk:-U dddddddd-1111-2222-3333-444444444444 /dev/mock' "$sgdisk_trace" || fail gpt-disk-uuid-missing
    grep -Fqx 'sgdisk:-t 1:c12a7328-f81f-11d2-ba4b-00a0c93ec93b /dev/mock' "$sgdisk_trace" || fail gpt-p1-type-missing
    grep -Fqx 'sgdisk:-u 1:11111111-aaaa-bbbb-cccc-000000000001 /dev/mock' "$sgdisk_trace" || fail gpt-p1-uuid-missing
    grep -Fqx 'sgdisk:-u 10:11111111-aaaa-bbbb-cccc-000000000010 /dev/mock' "$sgdisk_trace" || fail gpt-p10-uuid-missing
    grep -Fq 'udevadm:settle' "$sgdisk_trace" || fail gpt-restore-uuid-no-settle
)
printf 'PASS: MBR hex swap type 0x82 and POSIX awk restoreUUIDInformation\n'
