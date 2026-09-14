#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; return 1; }
check(){ grep -Fxq -- "$2" "$1" || fail "$1 missing $2"; }
verify() {
  local fixture=$1 ui_arch fs_config kernel_config
  declare -A fs=( [x86_64]=fsx64.config [i386]=fsx86.config [arm64]=fsarm64.config )
  declare -A kernel=( [x86_64]=kernelx64.config [i386]=kernelx86.config [arm64]=kernelarm64.config )
  for ui_arch in x86_64 i386 arm64; do
    fs_config="$fixture/configs/${fs[$ui_arch]}"
    kernel_config="$fixture/configs/${kernel[$ui_arch]}"
    check "$fs_config" BR2_PACKAGE_UDPCAST=y || return 1
    check "$fs_config" BR2_PACKAGE_UDPCAST_RECEIVER=y || return 1
    check "$fs_config" BR2_PACKAGE_JQ=y || return 1
    check "$fs_config" BR2_PACKAGE_LIBCURL=y || return 1
    check "$fs_config" BR2_PACKAGE_LIBCURL_CURL=y || return 1
    check "$fs_config" '# BR2_PACKAGE_CURL is not set' || return 1
    check "$kernel_config" CONFIG_IP_MULTICAST=y || return 1
  done
  grep -Fq 'ARCHITECTURES=("x64" "x86" "arm64")' "$fixture/build.sh" || fail 'build architecture order changed' || return 1
  grep -Fq 'make ARCH=i486' "$fixture/build.sh" || fail 'i386 build mapping missing' || return 1
  grep -Fq 'make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-' "$fixture/build.sh" || fail 'arm64 build mapping missing' || return 1
}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
base="$tmp/base"
mkdir -p "$base/configs"
cp "$root"/configs/fs*.config "$root"/configs/kernel*.config "$base/configs/"
cp "$root/build.sh" "$base/build.sh"
verify "$base" || { echo FAIL:baseline; exit 1; }
negative() {
  local name=$1 file=$2 from=$3 to=$4
  cp -a "$base" "$tmp/$name"
  sed -i "0,/$from/{s/$from/$to/}" "$tmp/$name/$file"
  if verify "$tmp/$name" >/dev/null 2>&1; then echo "FAIL: negative $name accepted"; exit 1; fi
}
negative receiver configs/fsx64.config BR2_PACKAGE_UDPCAST_RECEIVER=y '# BR2_PACKAGE_UDPCAST_RECEIVER is not set'
negative jq configs/fsx86.config BR2_PACKAGE_JQ=y '# BR2_PACKAGE_JQ is not set'
negative libcurl configs/fsarm64.config BR2_PACKAGE_LIBCURL_CURL=y '# BR2_PACKAGE_LIBCURL_CURL is not set'
negative multicast configs/kernelx64.config CONFIG_IP_MULTICAST=y '# CONFIG_IP_MULTICAST is not set'
negative legacy configs/fsx64.config '# BR2_PACKAGE_CURL is not set' BR2_PACKAGE_CURL=y
negative x64_mapping build.sh 'ARCHITECTURES=("x64" "x86" "arm64")' 'ARCHITECTURES=("x86" "x64" "arm64")'
echo 'PASS: PXEOS multicast architecture configuration regression'
