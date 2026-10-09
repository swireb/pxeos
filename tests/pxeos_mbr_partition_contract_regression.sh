#!/usr/bin/env bash
# Pure JSON contract for the DOS partition-number and 32-bit LBA barrier.
# It never invokes blockdev, sfdisk, or any disk writer.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_ok() { "$@" || fail "expected success: $*"; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

: >"$tmp/cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" \
    -e "s|</proc/cmdline|<\"$tmp/cmdline\"|" \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
ismajordebug=0
# shellcheck disable=SC1090
. "$tmp/funcs.sh"

cat >"$tmp/v1-valid.json" <<'JSON'
{"version":1,"partitionTable":"mbr","partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"typeGuid":"83"}]}
JSON
expect_ok rootpxe_validate_partition_lba_contract mbr "$tmp/v1-valid.json" originalSectors

jq '.partitions[0].number=61' "$tmp/v1-valid.json" >"$tmp/v1-61.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v1-61.json" originalSectors
jq '.partitions[0].typeGuid="0x0f"' "$tmp/v1-valid.json" >"$tmp/v1-extended.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v1-extended.json" originalSectors
jq '.partitions[0].number=5' "$tmp/v1-valid.json" >"$tmp/v1-logical-number.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v1-logical-number.json" originalSectors

# The MBR cap is inclusive: 56 continuous logical entries occupy 5..60.
jq -n '{version:2,partitionTable:"mbr",partitions:(
 [{number:4,kind:"extended",startSectors:2048,originalSectors:999999,typeGuid:"0x0f"}] +
 [range(5;61) | {number:.,kind:"logical",parentNumber:4,startSectors:(10000 + (. - 5) * 100),originalSectors:50,typeGuid:"83"}]
)}' >"$tmp/v2-valid.json"
expect_ok rootpxe_validate_partition_lba_contract mbr "$tmp/v2-valid.json" originalSectors
jq '(.partitions[] | select(.number == 60).number)=61' "$tmp/v2-valid.json" >"$tmp/v2-61.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-61.json" originalSectors
jq '(.partitions[0].typeGuid)="83"' "$tmp/v2-valid.json" >"$tmp/v2-kind-type-mismatch.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-kind-type-mismatch.json" originalSectors
jq '(.partitions[] | select(.number == 5).parentNumber)=1' "$tmp/v2-valid.json" >"$tmp/v2-parent-mismatch.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-parent-mismatch.json" originalSectors
jq '(.partitions[] | select(.number == 5).startSectors)=4294967295 | (.partitions[] | select(.number == 5).originalSectors)=2' "$tmp/v2-valid.json" >"$tmp/v2-lba-overflow.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-lba-overflow.json" originalSectors
# Linux assigns logical numbers from 5 consecutively along the EBR chain.
jq '.partitions |= [.[0], .[2]]' "$tmp/v2-valid.json" >"$tmp/v2-six-only.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-six-only.json" originalSectors
jq '.partitions |= [.[0], .[1], .[3]]' "$tmp/v2-valid.json" >"$tmp/v2-five-seven.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-five-seven.json" originalSectors

jq -n '{version:2,partitionTable:"gpt",partitions:[range(1;129)|{number:.,startSectors:4294967296,originalSectors:1}]}' >"$tmp/gpt-128.json"
expect_ok rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-128.json" originalSectors
jq '.partitions[0].originalSectors=4294967296' "$tmp/gpt-128.json" >"$tmp/gpt-large-extent.json"
expect_ok rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-large-extent.json" originalSectors
jq '.partitionTable="mbr" | .partitions=[{number:1,startSectors:1,originalSectors:4294967296,typeGuid:"83"}]' "$tmp/gpt-large-extent.json" >"$tmp/mbr-large-extent.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/mbr-large-extent.json" originalSectors
jq '.partitions[0].kind="logical"' "$tmp/gpt-128.json" >"$tmp/gpt-logical.json"
expect_fail rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-logical.json" originalSectors
jq '.partitions[0].typeGuid="0x0f"' "$tmp/gpt-128.json" >"$tmp/gpt-extended-type.json"
expect_fail rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-extended-type.json" originalSectors
jq '.partitions += [{number:129,startSectors:1,originalSectors:1}]' "$tmp/gpt-128.json" >"$tmp/gpt-129.json"
expect_fail rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-129.json" originalSectors

# The layout writer passes a resolved partition array, not the schema object.
# Both input shapes must reach the identical MBR/GPT identity and LBA gate.
jq '.partitions | map(.resolvedSectors = .originalSectors)' "$tmp/v2-valid.json" >"$tmp/v2-resolved-array.json"
expect_ok rootpxe_validate_partition_lba_contract mbr "$tmp/v2-resolved-array.json" resolvedSectors
jq '.partitions | map(.resolvedSectors = .originalSectors)' "$tmp/gpt-large-extent.json" >"$tmp/gpt-resolved-array.json"
expect_ok rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-resolved-array.json" resolvedSectors
jq '.[-1].number=61' "$tmp/v2-resolved-array.json" >"$tmp/v2-resolved-61.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-resolved-61.json" resolvedSectors
jq '. + [.[0]]' "$tmp/v2-resolved-array.json" >"$tmp/v2-resolved-duplicate.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-resolved-duplicate.json" resolvedSectors
jq 'map(if .number == 5 then .kind="unsupported" else . end)' "$tmp/v2-resolved-array.json" >"$tmp/v2-resolved-kind.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/v2-resolved-kind.json" resolvedSectors
jq '.[0].typeGuid="0x0f"' "$tmp/gpt-resolved-array.json" >"$tmp/gpt-resolved-extended.json"
expect_fail rootpxe_validate_partition_lba_contract gpt "$tmp/gpt-resolved-extended.json" resolvedSectors
printf '%s\n' '[]' >"$tmp/resolved-empty.json"
printf '%s\n' '42' >"$tmp/resolved-scalar.json"
printf '%s\n' '{"items":[]}' >"$tmp/resolved-wrong-object.json"
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/resolved-empty.json" resolvedSectors
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/resolved-scalar.json" resolvedSectors
expect_fail rootpxe_validate_partition_lba_contract mbr "$tmp/resolved-wrong-object.json" resolvedSectors

echo 'PASS: PXEOS MBR/GPT partition contract regression'
