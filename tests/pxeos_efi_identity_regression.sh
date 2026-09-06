#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cc=${CC:-gcc}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$cc" -std=c11 -D_FILE_OFFSET_BITS=64 -DROOTPXE_EFI_TEST -Wall -Wextra -Werror -Wformat=2 \
  -I"$root/Buildroot/package/rootpxe-offline-identities/src" \
  $(pkg-config --cflags json-c) \
  "$root/Buildroot/package/rootpxe-offline-identities/src/efi-identities.c" \
  "$root/tests/pxeos_efi_identity_fixture.c" -o "$tmp/efi-fixture" \
  $(pkg-config --libs json-c)
ROOTPXE_EFI_EXTRA_CASE="$tmp/case" "$tmp/efi-fixture" "$tmp/case"
