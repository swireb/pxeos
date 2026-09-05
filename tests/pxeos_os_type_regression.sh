#!/usr/bin/env bash
# PXEOS 只保留系统 ID 到内部诊断名称的稳定映射；可选系统集合由服务端控制。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got=${1@Q} expected=${2@Q})"; }

# Isolate determineOS so this contract test has no disk, network, or PXEOS
# runtime dependencies.
awk '/^determineOS\(\)/ { capture=1 } /^sec2string\(\)/ { capture=0 } capture { print }' "$funcs" >"$tmp/determine-os.sh"
handleError() { fail "$*"; }
# shellcheck source=/dev/null
. "$tmp/determine-os.sh"

assert_os() {
    local osid="$1" expected_name="$2" expected_mbr="$3" expected_part2_start="${4:-}"
    unset osname mbrfile defaultpart2start
    determineOS "$osid"
    assert_eq "${osname:-}" "$expected_name" "OS ID $osid 的内部名称错误"
    assert_eq "${mbrfile:-}" "$expected_mbr" "OS ID $osid 的 MBR 契约被改变"
    assert_eq "${defaultpart2start:-}" "$expected_part2_start" "OS ID $osid 的默认第二分区起点被改变"
}

assert_os 2 'Windows Vista / Server 2008' '/usr/share/pxeos/mbr/vista.mbr'
assert_os 5 'Windows 7 / Server 2008 R2' '/usr/share/pxeos/mbr/win7.mbr' '206848s'
assert_os 6 'Windows 8 / Server 2012' '/usr/share/pxeos/mbr/win8.mbr' '718848s'
assert_os 7 'Windows 8.1 / Server 2012 R2' '/usr/share/pxeos/mbr/win8.mbr' '718848s'
assert_os 8 'Apple Mac OS' ''
assert_os 9 'Windows 10 / Server 2016、2019、2022' ''
assert_os 10 'Windows 11 / Server 2025' ''
assert_os 50 'Linux' ''
assert_os 99 'Other' ''

pass '有效系统 ID 的 PXEOS 内部名称与服务端分组一致'
