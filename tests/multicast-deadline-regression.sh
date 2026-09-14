#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
. "$lib"
TEST_JQ=${TEST_JQ:-jq}
TEST_JQ=$(command -v "$TEST_JQ") || exit 1
jq(){ command "$TEST_JQ" "$@"; }
req="$tmp/request"
printf '{}' >"$req"
rootpxe_api=http://mock/
rootpxe_multicast_operation_deadline=$((SECONDS+1))
curl() {
  local out= next=0 arg
  printf '%s\n' "$*" >"$tmp/curl.args"
  for arg in "$@"; do
    ((next)) && { out=$arg; break; }
    [[ $arg == -o ]] && next=1
  done
  printf '{}' >"$out"
  printf 200
}
rootpxe_multicast_http_post status "$req"
grep -Fq -- '--max-time 1' "$tmp/curl.args"
grep -Fq -- '--connect-timeout 1' "$tmp/curl.args"
echo 'PASS: multicast outer deadline regression'
