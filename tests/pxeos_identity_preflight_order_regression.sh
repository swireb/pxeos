#!/usr/bin/env bash
# Contract for the real deployment entrypoints: all selected Linux identity
# checks must run before hostname or storage identifier writes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="${ROOTPXE_FUNCS:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh}"
identity="${ROOTPXE_IDENTITY_LIB:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
body() { sed -n "/^$1() {\$/,/^}\$/p" "$2"; }
line_of() { (grep -nF "$1" || true) | head -n1 | cut -d: -f1; }

hostname=$(body rootpxe_apply_linux_hostname_for_disk "$funcs")
host_pre=$(printf '%s\n' "$hostname" | line_of 'rootpxe_deployment_identity_linux_system_preflight "$mountpoint"')
host_write=$(printf '%s\n' "$hostname" | line_of "printf '%s\\n' \"\$hostName\" >\"\$hostname_path\"")
[[ $host_pre =~ ^[0-9]+$ && $host_write =~ ^[0-9]+$ && $host_pre -lt $host_write ]] || fail 'hostname entry does not preflight before hostname write'

complete=$(body completeTasking "$funcs")
private=$(printf '%s\n' "$complete" | line_of 'rootpxe_deployment_identity_request_private')
storage=$(printf '%s\n' "$complete" | line_of 'rootpxe_deployment_identity_linux_storage_preflight "$hd"')
[[ $private =~ ^[0-9]+$ && $storage =~ ^[0-9]+$ && $private -lt $storage ]] || fail 'private initialization was not fetched before Linux UUID preflight'

storage_body=$(body rootpxe_deployment_identity_linux_storage_preflight "$identity")
identity_pre=$(printf '%s\n' "$storage_body" | line_of 'rootpxe_deployment_identity_linux_system_preflight "$root"')
boot_probe=$(printf '%s\n' "$storage_body" | line_of 'rootpxe_deployment_identity_mount_linux_boot_filesystems "$root"')
[[ $identity_pre =~ ^[0-9]+$ && $boot_probe =~ ^[0-9]+$ && $identity_pre -lt $boot_probe ]] || fail 'storage preflight does not validate selected identity before UUID mutation path'
printf 'PASS: PXEOS identity preflight entry-order regression\n'
