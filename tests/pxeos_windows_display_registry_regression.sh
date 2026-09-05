#!/usr/bin/env bash
# Regressions for read-only chntpw/reged MountedDevices exports.  Fixtures are
# ordinary text only; this test neither opens a registry hive nor block device.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
module="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/windows-display-registry.sh"
fixtures="$root/tests/fixtures/windows-display-registry"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() {
    set +e
    "$@" >"$tmp/stdout" 2>"$tmp/stderr"
    local status=$?
    set -e
    [[ $status -ne 0 ]] || fail "expected failure: $*"
    [[ ! -s $tmp/stdout ]] || fail "failure produced partial stdout: $*"
}

. "$module"
command -v jq >/dev/null 2>&1 || fail 'real jq required'

# chntpw writes CRLF and wraps binary values as comma-plus-backslash continuations.
awk '{ printf "%s\r\n", $0 }' "$fixtures/valid-mbr-gpt.reg" >"$tmp/valid-crlf.reg"
rootpxe_display_windows_parse_reg "$tmp/valid-crlf.reg" >"$tmp/valid.json" || fail 'valid reged export rejected'
jq -e '
  type == "array" and length == 2 and
  (map(select(.driveLetter == "C:" and .volumeId == "123456789abcdef000112233")) | length) == 1 and
  (map(select(.driveLetter == "D:" and .volumeId == "444d494f3a49443a00112233445566778899aabbccddeeff")) | length) == 1
' "$tmp/valid.json" >/dev/null || fail 'MBR/GPT identity bytes or drive letter were changed'

rootpxe_display_windows_parse_reg "$fixtures/empty-mounted-devices.reg" >"$tmp/empty.json" || fail 'empty MountedDevices rejected'
[[ $(cat "$tmp/empty.json") == '[]' ]] || fail 'empty MountedDevices did not produce []'

rootpxe_display_windows_parse_reg "$fixtures/other-section-only.reg" >"$tmp/other.json" || fail 'unrelated section rejected'
[[ $(cat "$tmp/other.json") == '[]' ]] || fail 'unrelated section was read as MountedDevices'

expect_fail rootpxe_display_windows_parse_reg "$fixtures/missing-mounted-devices.reg"
expect_fail rootpxe_display_windows_parse_reg "$fixtures/duplicate-drive.reg"
expect_fail rootpxe_display_windows_parse_reg "$fixtures/malformed-hex.reg"

printf 'PASS: windows display registry regression\n'
