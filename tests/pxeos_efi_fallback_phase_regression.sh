#!/usr/bin/env bash
# Linux EFI repair accepts the removable-media loader only for the exact
# no-NVRAM-repair result, and only when the helper itself succeeds.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/root/.rootpxe-offline-identities/plan/efi" "$tmp/esp/EFI/BOOT" "$tmp/efivars"
plan="$tmp/plan.json"
manifest="$tmp/root/.rootpxe-offline-identities/plan/efi/manifest.json"
printf '%s\n' '{"plan":{"planId":"plan"}}' >"$plan"
printf '%s\n' "{\"version\":1,\"stateRoot\":\"$tmp/root\",\"volumes\":[{}]}" >"$manifest"

cat >"$tmp/bin/rootpxe-offline-identities" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
phase= result=
while (($#)); do
  case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --result) result="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $phase && -n $result ]] || exit 2
case "${ROOTPXE_EFI_CASE:-unavailable}" in
  unavailable) printf '%s\n' '{"version":1,"efi":{"available":false,"matched":0,"updated":0,"verified":false}}' >"$result" ;;
  nonzero-match) printf '%s\n' '{"version":1,"efi":{"available":false,"matched":1,"updated":0,"verified":false}}' >"$result" ;;
  malformed) printf '%s\n' '{"version":1,"efi":{"available":false}}' >"$result" ;;
  available) printf '%s\n' '{"version":1,"efi":{"available":true,"matched":1,"updated":1,"verified":true}}' >"$result" ;;
  fail) exit 17 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/rootpxe-offline-identities"
export PATH="$tmp/bin:$PATH"

. "$lib"
rootpxe_deployment_identity_plan_file="$plan"
rootpxe_deployment_identity_linux_efi_manifest_file="$manifest"
rootpxe_deployment_identity_efi_var_fs="$tmp/efivars"
rootpxe_deployment_identity_linux_efi_esp_mounts() { printf '%s\n' "$tmp/esp"; }
fallback=$(rootpxe_deployment_identity_linux_efi_fallback_name)
: >"$tmp/esp/EFI/BOOT/$fallback"

# This is the deployment failure reproduced from pxeos2: no NVRAM record is
# repairable, but a verified standard fallback loader is already on the ESP.
ROOTPXE_EFI_CASE=unavailable rootpxe_deployment_identity_linux_efi_phase "$tmp/root" apply || fail 'fallback unavailable result was rejected during apply'
ROOTPXE_EFI_CASE=unavailable rootpxe_deployment_identity_linux_efi_phase "$tmp/root" verify || fail 'fallback unavailable result was rejected during verify'

rm -f "$tmp/esp/EFI/BOOT/$fallback"
if ROOTPXE_EFI_CASE=unavailable rootpxe_deployment_identity_linux_efi_phase "$tmp/root" apply; then fail 'apply accepted unavailable result without fallback'; fi
if ROOTPXE_EFI_CASE=unavailable rootpxe_deployment_identity_linux_efi_phase "$tmp/root" verify; then fail 'verify accepted unavailable result without fallback'; fi
: >"$tmp/esp/EFI/BOOT/$fallback"
for case_name in nonzero-match malformed fail; do
  if ROOTPXE_EFI_CASE="$case_name" rootpxe_deployment_identity_linux_efi_phase "$tmp/root" apply; then fail "apply accepted $case_name result"; fi
  if ROOTPXE_EFI_CASE="$case_name" rootpxe_deployment_identity_linux_efi_phase "$tmp/root" verify; then fail "verify accepted $case_name result"; fi
done
for phase in apply verify; do
  ROOTPXE_EFI_CASE=available rootpxe_deployment_identity_linux_efi_phase "$tmp/root" "$phase" || fail "available result failed during $phase"
done

printf 'PASS: PXEOS EFI fallback apply/verify regression\n'
