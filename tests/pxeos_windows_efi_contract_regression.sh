#!/usr/bin/env bash
# Exercises the production Windows manifest and phase wrapper against the real
# EFI parser/stager.  ROOTPXE_EFI_TEST changes only efivarfs mount probing.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"
src="$root/Buildroot/package/rootpxe-offline-identities/src"
cc=${CC:-cc}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/result-log" "$tmp/esp/EFI/Microsoft/Boot" "$tmp/state-root/Boot" "$tmp/efivars"
: >"$tmp/esp/EFI/Microsoft/Boot/bootmgfw.efi"
: >"$tmp/state-root/Boot/BCD"

cat >"$tmp/efi-driver.c" <<'EOF'
#include "efi-identities.h"
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static int hx(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c - 'A' + 10; }
static void p32(unsigned char *p, uint32_t v) { int i; for (i = 0; i < 4; i++) { p[i] = (unsigned char)v; v >>= 8; } }
static void p64(unsigned char *p, uint64_t v) { int i; for (i = 0; i < 8; i++) { p[i] = (unsigned char)v; v >>= 8; } }
static void guid(const char *s, unsigned char *o) { unsigned char b[16]; int i, k = 0; for (i = 0; s[i]; ) { if (s[i] == '-') { i++; continue; } b[k++] = (unsigned char)((hx(s[i]) << 4) | hx(s[i + 1])); i += 2; } o[0] = b[3]; o[1] = b[2]; o[2] = b[1]; o[3] = b[0]; o[4] = b[5]; o[5] = b[4]; o[6] = b[7]; o[7] = b[6]; memcpy(o + 8, b + 8, 8); }
static int fixture(const char *kind, const char *path) { unsigned char b[60] = {0}; int fd; size_t off = 12; b[0] = 7; b[4] = 1; p32(b + 8, 46); b[off] = 4; b[off + 1] = 1; p32(b + off + 2, 42); p32(b + off + 4, 1); p64(b + off + 8, 8); p64(b + off + 16, 8); if (!strcmp(kind, "mbr")) { p32(b + off + 24, 0xf1234567U); b[off + 40] = 1; b[off + 41] = 1; } else { guid("12345678-9abc-def0-1122-334455667788", b + off + 24); b[off + 40] = 2; b[off + 41] = 2; } b[54] = 0x7f; b[55] = 0xff; p32(b + 56, 4); fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600); return fd < 0 || write(fd, b, sizeof(b)) != (ssize_t)sizeof(b) || close(fd); }
int main(int argc, char **argv) { if (argc == 4 && !strcmp(argv[1], "fixture")) return fixture(argv[2], argv[3]); if (argc >= 2 && !strcmp(argv[1], "efi-repair")) return rootpxe_efi_main(argc - 1, argv + 1); return rootpxe_efi_main(argc, argv); }
EOF

"$cc" -std=c11 -D_FILE_OFFSET_BITS=64 -DROOTPXE_EFI_TEST -Wall -Wextra -Werror -Wformat=2 \
    -I"$src" $(pkg-config --cflags json-c) "$src/efi-identities.c" "$tmp/efi-driver.c" \
    -o "$tmp/bin/efi-native" $(pkg-config --libs json-c)

"$tmp/bin/efi-native" fixture gpt "$tmp/efivars/Boot0001-8be4df61-93ca-11d2-aa0d-00e098032b8c"
"$tmp/bin/efi-native" fixture mbr "$tmp/efivars/Boot0002-8be4df61-93ca-11d2-aa0d-00e098032b8c"
cat >"$tmp/bin/rootpxe-offline-identities" <<'EOF'
#!/usr/bin/env bash
phase= result=
args=("$@")
while (($#)); do
    [[ $1 == --phase ]] && { phase=$2; shift 2; continue; }
    [[ $1 == --result ]] && { result=$2; shift 2; continue; }
    shift
done
"$ROOTPXE_EFI_NATIVE" "${args[@]}"
rc=$?
[[ -n $phase && -n $result && -f $result ]] && cp "$result" "$ROOTPXE_EFI_RESULT_LOG/$phase.json"
exit "$rc"
EOF
chmod +x "$tmp/bin/rootpxe-offline-identities"

cat >"$tmp/plan.json" <<'EOF'
{"plan":{"version":1,"planId":"windows-efi-contract","topology":{"disks":[{"targetDevice":"/dev/gpt0","targetBinding":"gpt0","sourceDiskNumber":1,"partitionTable":"gpt","oldDiskId":"11111111-2222-3333-4444-555555555555","partitions":[{"targetDevice":"/dev/gpt0p1","number":1,"oldPartitionId":"12345678-9abc-def0-1122-334455667788"}]},{"targetDevice":"/dev/mbr0","targetBinding":"mbr0","sourceDiskNumber":2,"partitionTable":"mbr","oldDiskId":"f1234567","partitions":[{"targetDevice":"/dev/mbr0p1","number":1,"oldPartitionId":"f1234567:1"}]}]},"disks":[{"targetDevice":"/dev/gpt0","partitionTable":"gpt","diskGuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","partitions":[{"targetDevice":"/dev/gpt0p1","partitionGuid":"87654321-cba9-0fed-8877-665544332211"}]},{"targetDevice":"/dev/mbr0","partitionTable":"mbr","diskSignature":"0000000a","partitions":[{"targetDevice":"/dev/mbr0p1"}]}]},"planHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","attempt":1}
EOF
cat >"$tmp/partition-inventory.json" <<'EOF'
{"version":1,"disks":[{"number":1,"logicalSectorBytes":512,"partitions":[{"number":1,"startSectors":8,"originalSectors":8,"role":"efi","typeGuid":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"}]},{"number":2,"logicalSectorBytes":512,"partitions":[{"number":1,"startSectors":8,"originalSectors":8,"role":"data","typeGuid":"0x07"}]}]}
EOF

export ROOTPXE_EFI_NATIVE="$tmp/bin/efi-native" ROOTPXE_EFI_RESULT_LOG="$tmp/result-log"
# Only the current Cygwin host needs this compatibility wrapper: its available
# jq is a native Windows executable and cannot open Cygwin POSIX file paths.
# A normal Linux or Cygwin jq is kept unchanged.
if ! jq -e . "$tmp/plan.json" >/dev/null 2>&1; then
    command -v cygpath >/dev/null 2>&1 || fail 'jq cannot read the fixture plan and no Cygwin path converter is available'
    export ROOTPXE_REAL_JQ="$(command -v jq)"
    cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
# Cygwin does not rewrite POSIX input-file arguments for the native Windows jq.
null_input=0
for arg in "$@"; do [[ $arg != --* && $arg == -* && $arg == *n* ]] && null_input=1; done
args=()
for arg in "$@"; do
    if [[ $null_input == 0 && -f $arg ]]; then args+=("$(cygpath -w "$arg")"); else args+=("$arg"); fi
done
set -o pipefail
"$ROOTPXE_REAL_JQ" "${args[@]}" | tr -d '\r'
EOF
    chmod +x "$tmp/bin/jq"
fi
export PATH="$tmp/bin:$PATH"
. "$lib"
rootpxe_deployment_identity_windows_root="$tmp/state-root"
rootpxe_deployment_identity_windows_mount_records=(
    "/dev/gpt0p1"$'\x1f'"$tmp/esp"$'\x1f'vfat
    "/dev/mbr0p1"$'\x1f'"$tmp/state-root"$'\x1f'ntfs
)
rootpxe_deployment_identity_windows_bcd=("$tmp/state-root/Boot/BCD")
rootpxe_deployment_identity_windows_xml=()
rootpxe_deployment_identity_plan_file="$tmp/plan.json"
rootpxe_deployment_identity_efi_var_fs="$tmp/efivars"
partitionInventoryFile="$tmp/partition-inventory.json"
imgType=mpa
# The fixture freezes the ESP tuple from its mpa inventory; mounting and ESP
# discovery are outside this contract and remain represented by controlled maps.
rootpxe_deployment_identity_source_esp_targets() { printf '1\t1\n'; }
rootpxe_deployment_identity_target_partition_geometry() { printf '512 8192 8192\n'; }

rootpxe_deployment_identity_windows_manifest || fail 'production Windows manifest generation failed'
jq -e --arg root "$tmp/state-root" --arg varfs "$tmp/efivars" '
    .windowsRoot == $root and .stateRoot == $root and .efiVarFs == $varfs and
    (.volumes | length) == 2 and .volumes[0].partitionNumber == 1 and
    .volumes[1].partitionTable == "mbr"' "$rootpxe_deployment_identity_windows_manifest_file" >/dev/null ||
    fail 'production Windows manifest missed the EFI state-root contract'

jq 'del(.stateRoot)' "$rootpxe_deployment_identity_windows_manifest_file" >"$tmp/missing-state-root.json"
if "$tmp/bin/efi-native" --manifest "$tmp/missing-state-root.json" --plan "$tmp/plan.json" --result "$tmp/missing-result.json" --phase preflight >/dev/null 2>&1; then
    fail 'native EFI parser accepted a Windows manifest without stateRoot'
fi

rootpxe_deployment_identity_windows_efi_phase preflight || fail 'native Windows EFI preflight failed'
rootpxe_deployment_identity_windows_efi_phase preflight || fail 'same-plan native Windows EFI preflight retry failed'
rootpxe_deployment_identity_windows_efi_phase apply || fail 'native Windows EFI apply failed'
jq -e '.version == 1 and .efi.available == true and (.efi.updated | type) == "number" and .efi.verified == false' "$tmp/result-log/apply.json" >/dev/null ||
    fail 'native EFI apply result was not accepted with verified=false'
rootpxe_deployment_identity_windows_efi_phase verify || fail 'native Windows EFI verify failed'
rootpxe_deployment_identity_windows_efi_phase apply || fail 'same-plan native Windows EFI apply retry failed'
rootpxe_deployment_identity_windows_efi_phase verify || fail 'same-plan native Windows EFI verify retry failed'

dd if=/dev/zero of="$tmp/efivars/Boot0001-8be4df61-93ca-11d2-aa0d-00e098032b8c" bs=1 count=1 conv=notrunc status=none
if rootpxe_deployment_identity_windows_efi_phase verify >/dev/null 2>&1; then
    fail 'Windows EFI phase accepted a failed native verify result'
fi

stage="$tmp/state-root/.rootpxe-offline-identities/windows-efi-contract/efi"
[[ -f $stage/manifest.json && -f $stage/plan.json && -f $stage/0.cand && -f $stage/1.cand ]] ||
    fail 'native EFI preflight did not preserve the three-phase stage under stateRoot'
printf 'PASS: production Windows manifest stateRoot contract and native EFI lifecycle\n'
