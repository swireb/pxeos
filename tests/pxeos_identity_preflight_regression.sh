#!/usr/bin/env bash
# Every selected Linux identity operation must be validated before the first
# target write.  A missing SELinux relabel mechanism is deliberately a late
# prerequisite so this catches machine-id, key, credential and marker writes.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="${ROOTPXE_IDENTITY_LIB:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$lib"

target="$tmp/target"
mkdir -p "$target/etc/ssh" "$target/etc/selinux" "$target/var/lib/dbus" "$target/root"
printf 'old-machine-id\n' >"$target/etc/machine-id"
printf 'old-dbus-id\n' >"$target/var/lib/dbus/machine-id"
printf 'root:x:0:0:root:/root:/bin/bash\n' >"$target/etc/passwd"
printf 'root:$6$old$oldhash:1:2:3:4:5:6:7\n' >"$target/etc/shadow"
printf 'ID=rocky\nID_LIKE="rhel fedora"\n' >"$target/etc/os-release"
printf 'HostKey /etc/ssh/ssh_host_ed25519_key\nAuthorizedKeysFile .ssh/authorized_keys\n' >"$target/etc/ssh/sshd_config"
printf 'SELINUX=enforcing\n' >"$target/etc/selinux/config"
policy="$tmp/policy.json"; plan="$tmp/plan.json"; private="$tmp/private.json"
printf '%s\n' '{"version":1,"systemIdentity":{"machineId":true,"sshHostKeys":true,"sshLoginPublicKeys":true,"rootPassword":true}}' >"$policy"
printf '%s\n' '{"plan":{"systemIdentity":{"machineId":"0123456789abcdef0123456789abcdef"}},"planHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$plan"
printf '%s\n' '{"version":1,"sshLoginPublicKeys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7yE5q7MdhqWNsZnKZqRppDi0n0QzQnQbE0SgP5Gux5 root"],"rootPasswordHash":"$6$salt$hash","unattendXml":""}' >"$private"

deploymentIdentityPolicyFile="$policy"
rootpxe_deployment_identity_plan_file="$plan"
rootpxe_deployment_initialization_private_file="$private"
osid=50
shadow_before=$(cat "$target/etc/shadow")
if rootpxe_deployment_identity_linux_system_in_root "$target"; then fail 'identity unexpectedly succeeded without a SELinux relabel mechanism'; fi
[[ $(cat "$target/etc/machine-id") == old-machine-id ]] || fail 'machine-id changed before complete selected preflight'
[[ $(cat "$target/var/lib/dbus/machine-id") == old-dbus-id ]] || fail 'dbus machine-id changed before complete selected preflight'
[[ ! -e $target/var/lib/rootpxe ]] || fail 'identity marker directory was created before complete selected preflight'
[[ ! -e $target/root/.ssh ]] || fail 'authorized_keys directory was created before complete selected preflight'
[[ ! -e $target/etc/ssh/ssh_host_ed25519_key ]] || fail 'SSH host key was created before complete selected preflight'
[[ ! -e $target/.autorelabel ]] || fail 'SELinux marker was created before complete selected preflight'
[[ $(cat "$target/etc/shadow") == "$shadow_before" ]] || fail 'shadow changed before complete selected preflight'

# A fully valid selected set must pass the same preflight without writing.
mkdir -p "$target/usr/lib/systemd/system"
: >"$target/usr/lib/systemd/system/selinux-autorelabel-mark.service"
rootpxe_deployment_identity_linux_system_preflight "$target" || fail 'complete valid selected identity set was rejected by preflight'
[[ $(cat "$target/etc/machine-id") == old-machine-id && $(cat "$target/etc/shadow") == "$shadow_before" ]] || fail 'successful preflight modified target files'
printf 'PASS: PXEOS Linux identity preflight regression\n'
