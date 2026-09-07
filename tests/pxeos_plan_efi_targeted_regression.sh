#!/usr/bin/env bash
# Focused contracts extracted from pxeos_deployment_identity_regression.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

. "$lib"

# The plan service receives a typed representation which omits empty optional
# fields.  It must still bind the same normalized topology returned by it.
deploymentIdentityPolicyFile="$tmp/policy"
printf '%s\n' '{"version":1,"randomizeStorageIdentifiers":false,"systemIdentity":{"machineId":true}}' >"$deploymentIdentityPolicyFile"
taskid=17; task_token=redacted; mac=001122334455; progress_attempt=3; pxeapi=https://example.invalid/
rootpxe_deployment_identity_target_binding() { printf 'wwn:target\n'; }
canonical=$(rootpxe_deployment_identity_canonicalize_topology <<'JSON'
{"disks":[{"targetDevice":"/dev/mock0","targetBinding":"wwn:target","partitions":[{"targetDevice":"/dev/mock0p1","number":1,"logicalVolumes":[],"originalFilesystemUuid":""}]}]}
JSON
) || fail 'topology canonicalization failed'
jq -e '.disks[0].partitions[0] | ((has("logicalVolumes") | not) and (has("originalFilesystemUuid") | not))' <<<"$canonical" >/dev/null || fail 'empty topology fields were not canonicalized'
curl() {
    local request='' argument response
    while (($#)); do
        [[ $1 == --data-binary ]] && { request=$2; break; }
        shift
    done
    response=$(jq -c '.topology' <<<"$request") || return 1
    jq -cn --argjson topology "$response" '{attempt:3,plan:{version:1,planId:"plan-1",topology:$topology},planHash:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    printf '\n200\n'
}
rootpxe_deployment_identity_request_plan /dev/mock0 || fail 'typed plan response rejected normalized topology'
jq -e '.attempt == 3 and .plan.topology.disks[0].targetBinding == "wwn:target"' "$rootpxe_deployment_identity_plan_file" >/dev/null || fail 'typed plan response lost the bound topology'
rm -f -- "$rootpxe_deployment_identity_plan_file"

# Keep the existing EFI preflight response contract: unavailable firmware is
# acceptable only when a boot fallback is present; malformed responses fail.
rootpxe_deployment_identity_plan_file="$tmp/efi-plan.json"
printf '%s\n' '{"plan":{"planId":"efi-plan"}}' >"$rootpxe_deployment_identity_plan_file"
efi_root="$tmp/root"; mkdir -p "$efi_root/.rootpxe-offline-identities/efi-plan/efi" "$tmp/efivars"
rootpxe_deployment_identity_linux_efi_manifest_file="$efi_root/.rootpxe-offline-identities/efi-plan/efi/manifest.json"
printf '%s\n' '{}' >"$rootpxe_deployment_identity_linux_efi_manifest_file"
rootpxe_deployment_identity_efi_var_fs="$tmp/efivars"
rootpxe_deployment_identity_linux_efi_fallback_present() { [[ ${ROOTPXE_TEST_EFI_FALLBACK:-0} == 1 ]]; }
rootpxe-offline-identities() {
    local result='' phase=''
    while (($#)); do
        [[ $1 == --result ]] && { result=$2; shift 2; continue; }
        [[ $1 == --phase ]] && { phase=$2; shift 2; continue; }
        shift
    done
    [[ $phase == preflight && -n $result ]] || return 1
    case ${ROOTPXE_TEST_EFI_RESULT:-unavailable} in
        unavailable) printf '%s\n' '{"version":1,"efi":{"available":false,"matched":0,"updated":0,"verified":false}}' >"$result" ;;
        malformed) printf '%s\n' '{"version":1,"efi":{"available":false}}' >"$result" ;;
        *) return 1 ;;
    esac
}
ROOTPXE_TEST_EFI_FALLBACK=1 rootpxe_deployment_identity_linux_efi_phase "$efi_root" preflight || fail 'unavailable EFI with fallback rejected'
if ROOTPXE_TEST_EFI_FALLBACK=0 rootpxe_deployment_identity_linux_efi_phase "$efi_root" preflight; then fail 'unavailable EFI without fallback accepted'; fi
if ROOTPXE_TEST_EFI_RESULT=malformed ROOTPXE_TEST_EFI_FALLBACK=1 rootpxe_deployment_identity_linux_efi_phase "$efi_root" preflight; then fail 'malformed unavailable EFI response accepted'; fi

printf 'PASS: PXEOS plan and EFI targeted regression\n'
