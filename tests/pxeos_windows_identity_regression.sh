#!/usr/bin/env bash
# Host-side native regression. It creates legal synthetic hives by copying
# hivex's upstream minimal image; it does not claim Windows boot validation.
set -euo pipefail

tool=${ROOTPXE_WINDOWS_IDENTITY_TOOL:-/usr/sbin/rootpxe-offline-identities}
minimal=${ROOTPXE_HIVEX_MINIMAL:-}
cc=${CC:-cc}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_fail() {
    if "$@" >/dev/null 2>&1; then
        fail "expected rejection: $*"
    fi
}

[[ -x $tool ]] || fail "missing built tool: $tool"
[[ -n $minimal && -f $minimal ]] ||
    fail 'set ROOTPXE_HIVEX_MINIMAL to hivex upstream images/minimal'

tmp=$(mktemp -d)
if [[ -n ${ROOTPXE_WINDOWS_IDENTITY_KEEP_TMP:-} ]]; then
    trap 'printf "kept synthetic fixture: %s\\n" "$tmp"' EXIT
else
    trap 'rm -rf "$tmp"' EXIT
fi
fixture_tool=$tmp/fixture-tool

"$cc" -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror \
    ${CPPFLAGS:-} \
    $(pkg-config --cflags hivex) \
    -o "$fixture_tool" "$script_dir/pxeos_windows_identity_fixture.c" \
    ${LDFLAGS:-} \
    $(pkg-config --libs hivex)

write_case_files() {
    local root=$1
    local manifest=$2
    local plan=$3
    local planid=$4

    cat >"$manifest" <<EOF
{
  "version": 1,
  "windowsRoot": "$root",
  "volumes": [{
    "mount": "$root",
    "partitionTable": "mbr",
    "diskBinding": "fixture-mbr",
    "partitionNumber": 1,
    "oldDiskId": "f1234567",
    "newDiskId": "0000000a",
    "oldPartitionGuid": "f1234567:1",
    "newPartitionGuid": "",
    "oldOffsetBytes": 4294967312,
    "newOffsetBytes": 8589934624,
    "oldSizeBytes": 4096,
    "newSizeBytes": 8192,
    "oldLogicalSectorBytes": 512,
    "newLogicalSectorBytes": 512
  }, {
    "mount": "$root",
    "partitionTable": "mbr",
    "diskBinding": "fixture-mbr",
    "partitionNumber": 2,
    "oldDiskId": "f1234567",
    "newDiskId": "0000000a",
    "oldPartitionGuid": "f1234567:2",
    "newPartitionGuid": "",
    "oldOffsetBytes": 12288,
    "newOffsetBytes": 16384,
    "oldSizeBytes": 4096,
    "newSizeBytes": 8192,
    "oldLogicalSectorBytes": 512,
    "newLogicalSectorBytes": 512
  }, {
    "mount": "$root",
    "partitionTable": "gpt",
    "diskBinding": "fixture-gpt",
    "partitionNumber": 1,
    "oldDiskId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "newDiskId": "12345678-9abc-def0-1122-334455667788",
    "oldPartitionGuid": "abcdefab-cdef-abcd-efab-cdefabcdefab",
    "newPartitionGuid": "fedcbafe-dcba-fedc-bafe-dcbafedcbafe",
    "oldOffsetBytes": 4294967312,
    "newOffsetBytes": 8589934624,
    "oldSizeBytes": 4096,
    "newSizeBytes": 8192,
    "oldLogicalSectorBytes": 512,
    "newLogicalSectorBytes": 512
  }],
  "bcdStores": ["$root/Boot/BCD"],
  "systemHive": "$root/Windows/System32/config/SYSTEM",
  "reAgentXml": ["$root/Windows/System32/Recovery/ReAgent.xml"]
}
EOF
    cat >"$plan" <<EOF
{
  "attempt": 1,
  "planHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "plan": {
    "version": 1,
    "planId": "$planid",
    "topology": {
      "disks": [{
        "targetDevice": "/dev/fixture-mbr",
        "targetBinding": "fixture-mbr",
        "partitionTable": "mbr",
        "oldDiskId": "f1234567",
        "partitions": [{
          "targetDevice": "/dev/fixture-mbrp1",
          "number": 1,
          "oldPartitionId": "f1234567:1"
        }, {
          "targetDevice": "/dev/fixture-mbrp2",
          "number": 2,
          "oldPartitionId": "f1234567:2"
        }]
      }, {
        "targetDevice": "/dev/fixture-gpt",
        "targetBinding": "fixture-gpt",
        "partitionTable": "gpt",
        "oldDiskId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "partitions": [{
          "targetDevice": "/dev/fixture-gptp1",
          "number": 1,
          "oldPartitionId": "abcdefab-cdef-abcd-efab-cdefabcdefab"
        }]
      }]
    },
    "disks": [{
      "targetDevice": "/dev/fixture-mbr",
      "partitionTable": "mbr",
      "diskSignature": "0000000a",
      "partitions": [{
          "targetDevice": "/dev/fixture-mbrp1"
      }, {
          "targetDevice": "/dev/fixture-mbrp2"
      }]
    }, {
      "targetDevice": "/dev/fixture-gpt",
      "partitionTable": "gpt",
      "diskGuid": "12345678-9abc-def0-1122-334455667788",
      "partitions": [{
        "targetDevice": "/dev/fixture-gptp1",
        "partitionGuid": "fedcbafe-dcba-fedc-bafe-dcbafedcbafe"
      }]
    }]
  }
}
EOF
    chmod 600 "$manifest" "$plan"
}

new_case() {
    local name=$1
    local root=$tmp/$name/root

    mkdir -p "$tmp/$name"
    "$fixture_tool" "$minimal" "$root"
    write_case_files "$root" "$tmp/$name/manifest.json" "$tmp/$name/plan.json" "$name"
}

run_repair() {
    local name=$1
    local phase=$2
    local result=${3:-$phase}

    "$tool" windows-repair \
        --manifest "$tmp/$name/manifest.json" \
        --plan "$tmp/$name/plan.json" \
        --result "$tmp/$name/$result.json" \
        --phase "$phase"
}

"$tool" selftest

new_case full
expect_fail run_repair full verify
run_repair full preflight
sed -i 's/"attempt": 1/"attempt": 2/' "$tmp/full/plan.json"
run_repair full preflight preflight-repeat

# A stage is owned by the complete plan and manifest mapping, not merely its
# planId.  The retry attempt is intentionally excluded so the same task may
# retry its lifecycle after PXEOS increments the attempt counter.
new_case changed-guid
run_repair changed-guid preflight
sed -i 's/fedcbafe-dcba-fedc-bafe-dcbafedcbafe/01234567-89ab-cdef-0123-456789abcdef/g' \
    "$tmp/changed-guid/manifest.json" "$tmp/changed-guid/plan.json"
expect_fail run_repair changed-guid preflight

new_case changed-volumes
run_repair changed-volumes preflight
sed -i '0,/"newSizeBytes": 8192/s//"newSizeBytes": 16384/' \
    "$tmp/changed-volumes/manifest.json"
expect_fail run_repair changed-volumes preflight

new_case changed-hash
run_repair changed-hash preflight
sed -i 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "$tmp/changed-hash/plan.json"
expect_fail run_repair changed-hash preflight

# MBR has no partition GUID.  The backend legally omits it, but a fabricated
# nonempty value must not be accepted as an identity binding.
new_case mbr-fake-partition-guid
sed -i '/"diskSignature": "0000000a"/,+4 s#"targetDevice": "/dev/fixture-mbrp1"#"targetDevice": "/dev/fixture-mbrp1", "partitionGuid": "unexpected"#' \
    "$tmp/mbr-fake-partition-guid/plan.json"
expect_fail run_repair mbr-fake-partition-guid preflight

# A failed edit leaves snapshots behind, but no complete-preflight marker.  It
# must neither be applied nor be accepted as a retryable preflight stage.
new_case partial-preflight
sed -i 's/offset="4294967312"/offset="7"/' \
    "$tmp/partial-preflight/root/Windows/System32/Recovery/ReAgent.xml"
expect_fail run_repair partial-preflight preflight
expect_fail run_repair partial-preflight apply
expect_fail run_repair partial-preflight preflight preflight-repeat

# Root and volume paths are authorization boundaries.  They reject an input
# symlink before canonicalization; a dot component also cannot name a stage.
new_case symlink-root
mv "$tmp/symlink-root/root" "$tmp/symlink-root/physical-root"
ln -s physical-root "$tmp/symlink-root/root"
expect_fail run_repair symlink-root preflight
new_case symlink-volume
ln -s root "$tmp/symlink-volume/volume"
sed -i "s#\"mount\": \"$tmp/symlink-volume/root\"#\"mount\": \"$tmp/symlink-volume/volume\"#g" \
    "$tmp/symlink-volume/manifest.json"
expect_fail run_repair symlink-volume preflight
new_case dot-plan
sed -i 's/"planId": "dot-plan"/"planId": ".."/' "$tmp/dot-plan/plan.json"
expect_fail run_repair dot-plan preflight
new_case stage-link
mkdir -p "$tmp/stage-link/root/.rootpxe-offline-identities" "$tmp/stage-link/outside"
ln -s "$tmp/stage-link/outside" \
    "$tmp/stage-link/root/.rootpxe-offline-identities/stage-link"
expect_fail run_repair stage-link preflight
expect_fail run_repair stage-link apply

# Simulate an interrupted apply after BCD was atomically installed. The same
# plan must recognize that candidate and finish SYSTEM/XML without replaying it.
cp "$tmp/full/root/.rootpxe-offline-identities/full/0.new" "$tmp/full/root/Boot/BCD"
run_repair full apply
run_repair full verify
"$fixture_tool" --verify "$tmp/full/root"
grep -Fq '"storage":false' "$tmp/full/verify.json" || fail 'result overclaims storage'
grep -Fq '"bcd":true' "$tmp/full/verify.json" || fail 'result misses BCD repair'
grep -Fq '"mountedDevices":true' "$tmp/full/verify.json" || fail 'result misses MountedDevices repair'
grep -Fq '"winre":true' "$tmp/full/verify.json" || fail 'result misses WinRE repair'

new_case drift
run_repair drift preflight
printf X >>"$tmp/drift/root/Boot/BCD"
expect_fail run_repair drift apply

# verify is tied to the same normalized manifest and {plan, planHash} input as
# preflight/apply; a wrapper attempt change alone remains acceptable.
new_case verify-drift
run_repair verify-drift preflight
run_repair verify-drift apply
sed -i 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "$tmp/verify-drift/plan.json"
expect_fail run_repair verify-drift verify

printf 'PASS: synthetic hivex BCD/SYSTEM/XML lifecycle regression\n'
