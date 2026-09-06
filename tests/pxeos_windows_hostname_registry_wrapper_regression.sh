#!/usr/bin/env bash
# Exercise the production registry wrapper against a real hivex SYSTEM hive.
set -euo pipefail

tool=${ROOTPXE_WINDOWS_HOSTNAME_TOOL:-}
minimal=${ROOTPXE_HIVEX_MINIMAL:-}
reged=${ROOTPXE_REGED:-}
root=$(cd "$(dirname "$0")/.." && pwd)
native_test="$root/tests/pxeos_windows_hostname_native_regression.sh"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -x $tool && -f $minimal && -x $reged ]] || fail 'set ROOTPXE_WINDOWS_HOSTNAME_TOOL, ROOTPXE_HIVEX_MINIMAL and ROOTPXE_REGED'
[[ ! -e /ntfs ]] || fail '/ntfs already exists; refusing to touch a real mount'

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp" /ntfs; }
trap cleanup EXIT

# Reuse the native test's real hive fixture without duplicating its C source.
fixture_source="$tmp/fixture.c"
sed -n '/^cat >"\$fixture_source" <<'\''EOF'\''$/,/^EOF$/ { /^cat >"\$fixture_source"/d; /^EOF$/d; p; }' "$native_test" >"$fixture_source"
[[ -s $fixture_source ]] || fail 'could not extract native hive fixture'
cc=${CC:-cc}
"$cc" -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror ${CPPFLAGS:-} $(pkg-config --cflags hivex) -o "$tmp/fixture" "$fixture_source" ${LDFLAGS:-} $(pkg-config --libs hivex)
mkdir -p /ntfs/Windows/System32/config "$tmp/bin"
"$tmp/fixture" "$minimal" /ntfs/Windows/System32/config/SYSTEM
ln -s "$tool" "$tmp/bin/rootpxe-offline-identities"
ln -s "$reged" "$tmp/bin/reged"
PATH="$tmp/bin:$PATH"

# Extract the production function verbatim so this regression does not source
# PXEOS boot-time dependencies that do not exist on the build host.
awk '/^rootpxe_change_hostname_registry\(\)/ {copy=1} copy {print} copy && /^}$/ {exit}' "$funcs" >"$tmp/registry-wrapper.sh"
[[ -s $tmp/registry-wrapper.sh ]] || fail 'could not extract production registry wrapper'
source "$tmp/registry-wrapper.sh"
changeHostname=true
hostName=AFTER
rootpxe_change_hostname_registry /dev/mock || fail 'production registry wrapper failed'
rootpxe-offline-identities windows-hostname-verify /ntfs/Windows/System32/config/SYSTEM AFTER || fail 'production wrapper did not persist all control sets'

printf 'PASS: production Windows hostname registry wrapper regression\n'
