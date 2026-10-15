#!/usr/bin/env bash
# 冻结身份计划、Windows私有XML、NoCloud离线注入与回执的真实入口顺序。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sed -n '/^completeTasking() {/,/^}/p' "$lib/funcs.sh" >"$tmp/complete"
before(){ local a b; a=$(grep -nF "$1" "$tmp/complete" | head -n1 | cut -d: -f1); b=$(grep -nF "$2" "$tmp/complete" | head -n1 | cut -d: -f1); [[ $a -lt $b ]]; }
before rootpxe_deployment_identity_request_private rootpxe_apply_hostname_for_disk || fail 'Windows XML follows initialization'
before rootpxe_apply_cloud_init rootpxe_deployment_identity_report_result || fail 'receipt precedes NoCloud installation'
grep -Fq 'rootpxe_verify_disk_permit_binding' "$lib/cloud-init.sh" || fail 'injection lacks permit guard'
! grep -Eq 'preDeployScript|postDeployScript|rootpxe_run_.*deploy_script|rootpxe_apply_linux_hostname|machineId|sshHostKeys|sshLoginPublicKeys|rootPassword' "$lib/funcs.sh" "$lib/deployment-identity.sh" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin" || fail 'retired runtime contract remains'
[[ ! -e $lib/linux-startup.sh && ! -d $lib/linux-startup-templates ]] || fail 'retired startup assets remain'
printf 'PASS: identity/NoCloud ordering and obsolete runtime absence\n'
