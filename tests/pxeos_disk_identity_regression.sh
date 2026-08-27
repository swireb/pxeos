#!/usr/bin/env bash
# Offline stable-disk-identity contract.  It extracts only identity and NVMe
# binding helpers, replacing udev, hashing and block probing with local mocks.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_status() {
    local expected="$1" actual
    shift
    set +e
    "$@" >"$tmp/out" 2>&1
    actual=$?
    set -e
    [[ $actual -eq $expected ]] || fail "expected status $expected, got $actual: $(<"$tmp/out")"
}

awk '/^rootpxe_disk_stable_identity\(\)/ { copy = 1 } /^rootpxe_nvme_permit_matches\(\)/ { exit } copy' "$funcs" >"$tmp/identity.sh"
awk '/^rootpxe_nvme_permit_matches\(\)/ { copy = 1 } /^rootpxe_nvme_find_metadata_free_lbaf\(\)/ { exit } copy' "$funcs" >"$tmp/permit-match.sh"
awk '/^rootpxe_nvme_wait_for_reenumeration\(\)/ { copy = 1 } /^rootpxe_nvme_reformat_to_sector_size\(\)/ { exit } copy' "$funcs" >"$tmp/reenumerate.sh"
[[ -s $tmp/identity.sh && -s $tmp/permit-match.sh && -s $tmp/reenumerate.sh ]] || fail 'identity helpers were not extracted'

identity_property=''
identity_udev_status=0
identity_hash_status=0
udevadm() {
    [[ $1 == info ]] || return 1
    [[ $identity_udev_status -eq 0 ]] || return "$identity_udev_status"
    printf '%s\n' "$identity_property"
}
sha256sum() {
    [[ $identity_hash_status -eq 0 ]] || return "$identity_hash_status"
    command sha256sum "$@"
}
. "$tmp/identity.sh"
. "$tmp/permit-match.sh"
. "$tmp/reenumerate.sh"

identity_for() {
    identity_property="$1"
    identity_udev_status=0
    identity_hash_status=0
    rootpxe_disk_stable_identity /dev/mockdisk
}

legal='wwn-0x5000c500a1b2c3d4'
[[ $(identity_for "ID_WWN=$legal") == "$legal" ]] || fail 'legal backend-compatible ID_WWN must remain unchanged'
legal_128=$(printf 'a%.0s' {1..128})
[[ $(identity_for "ID_SERIAL=$legal_128") == "$legal_128" ]] || fail 'legal 128-character ID_SERIAL must remain unchanged'
[[ $(identity_for $'ID_WWN=\nID_SERIAL=serial-42') == serial-42 ]] || fail 'empty preferred property must fall through to non-empty ID_SERIAL'
[[ $(identity_for $'ID_SERIAL=serial-first\nID_WWN=wwn-later') == serial-first ]] || fail 'first non-empty ID_SERIAL must keep existing udev output selection order'

for raw in 'serial with spaces' 'serial/with/slashes' 'serial=with=equals' 'disk-编号' "$(printf 'x%.0s' {1..129})" 'sha256:looks-like-an-encoded-id'; do
    first=$(identity_for "ID_WWN=$raw") || fail "invalid ID did not produce a hash: $raw"
    second=$(identity_for "ID_WWN=$raw") || fail "invalid ID was not stable: $raw"
    [[ $first =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid ID did not produce sha256 namespace: $raw"
    [[ $first == "$second" ]] || fail "same raw ID did not produce same stable identity: $raw"
    [[ $first != "$raw" ]] || fail "reserved sha256 prefix or invalid raw ID was returned verbatim: $raw"
done

space_hash=$(identity_for 'ID_WWN=serial with spaces')
slash_hash=$(identity_for 'ID_WWN=serial/with/slashes')
equals_hash=$(identity_for 'ID_WWN=serial=with=equals')
[[ $space_hash != "$slash_hash" && $space_hash != "$equals_hash" && $slash_hash != "$equals_hash" ]] || fail 'different raw IDs collided after normalization'
[[ $(identity_for 'ID_WWN=serial=one') != "$(identity_for 'ID_WWN=serial=two')" ]] || fail 'values after equals were truncated before hashing'
[[ $(identity_for 'ID_WWN= serial') != "$(identity_for 'ID_WWN=serial')" ]] || fail 'leading whitespace was trimmed before hashing'
[[ $(identity_for 'ID_WWN=serial ') != "$(identity_for 'ID_WWN=serial')" ]] || fail 'trailing whitespace was trimmed before hashing'
unsafe_digest=$(identity_for 'ID_WWN=another/unsafe/id')
[[ $(identity_for "ID_WWN=$unsafe_digest") != "$unsafe_digest" ]] || fail 'raw value in sha256 namespace was not hashed again'

expect_status 1 identity_for $'ID_WWN=   \nID_SERIAL=\t'
expect_status 1 identity_for ''
expect_status 1 identity_for 'ID_MODEL=missing-stable-property'
identity_property='ID_WWN=serial-42'
identity_udev_status=7
identity_hash_status=0
expect_status 1 rootpxe_disk_stable_identity /dev/mockdisk
identity_property='ID_WWN=serial with spaces'
identity_udev_status=0
identity_hash_status=7
expect_status 1 rootpxe_disk_stable_identity /dev/mockdisk

# Re-enumeration and NVMe permit checks must compare the normalized identity,
# never a raw udev value or a device path.
expected=$(identity_for 'ID_WWN=nvme serial/with slash')
rootpxe_disk_permit_granted=yes
rootpxe_disk_permit_target_id="$expected"
rootpxe_disk_permit_operation=nvme_format+deploy_write
rootpxe_nvme_permit_matches "$expected" || fail 'normalized target ID did not match permit binding'
! rootpxe_nvme_permit_matches 'nvme serial/with slash' || fail 'raw target ID bypassed normalized permit binding'

PXEOS_NVME_REENUM_DEVICE=/dev/mocknvme
PXEOS_NVME_REENUM_TIMEOUT_SEC=0
blockdev() { [[ $1 == --getss ]] && { printf '512\n'; return 0; }; return 1; }
sleep() { :; }
identity_property='ID_WWN=nvme serial/with slash'
identity_udev_status=0
identity_hash_status=0
rootpxe_nvme_wait_for_reenumeration "$expected" 512 || fail 'same normalized ID was not re-identified after NVMe re-enumeration'
[[ ${rootpxe_nvme_reformatted_disk:-} == /dev/mocknvme ]] || fail 're-enumeration selected unexpected disk path'
identity_property='ID_WWN=other serial/with slash'
unset rootpxe_nvme_reformatted_disk
expect_status 1 rootpxe_nvme_wait_for_reenumeration "$expected" 512

echo 'PASS: disk IDs preserve valid values and hash incompatible values before strict permit binding'
