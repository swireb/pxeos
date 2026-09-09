#!/usr/bin/env bash
# Contract for the real deployment entrypoints: selected Linux system-identity
# validation precedes hostname writes, and private initialization material is
# fetched before the post-restore initializer runs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="${ROOTPXE_FUNCS:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
body() { sed -n "/^$1() {\$/,/^}\$/p" "$2"; }
line_of() { (grep -nF "$1" || true) | head -n1 | cut -d: -f1; }

hostname=$(body rootpxe_apply_linux_hostname_for_disk "$funcs")
host_pre=$(printf '%s\n' "$hostname" | line_of 'rootpxe_deployment_identity_linux_system_preflight "$mountpoint"')
host_write=$(printf '%s\n' "$hostname" | line_of "printf '%s\\n' \"\$hostName\" >\"\$hostname_path\"")
[[ $host_pre =~ ^[0-9]+$ && $host_write =~ ^[0-9]+$ && $host_pre -lt $host_write ]] || fail 'Linux system preflight does not precede hostname write'
printf '%s\n' "$hostname" | grep -Fq 'REASON=${preflight_reason} RC=${preflight_rc}' || fail 'Linux system preflight failure reason is not reported'

complete=$(body completeTasking "$funcs")
private=$(printf '%s\n' "$complete" | line_of 'rootpxe_deployment_identity_request_private')
initializer=$(printf '%s\n' "$complete" | line_of 'rootpxe_apply_hostname_for_disk "$hd"')
[[ $private =~ ^[0-9]+$ && $initializer =~ ^[0-9]+$ && $private -lt $initializer ]] || fail 'private initialization configuration is not fetched before initializer'

printf 'PASS: PXEOS identity initialization preflight-order regression\n'
