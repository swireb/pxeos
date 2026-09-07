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
printf 'old-private-key\n' >"$target/etc/ssh/ssh_host_ed25519_key"
printf 'old-public-key\n' >"$target/etc/ssh/ssh_host_ed25519_key.pub"
printf 'SELINUX=enforcing\n' >"$target/etc/selinux/config"
policy="$tmp/policy.json"; plan="$tmp/plan.json"; private="$tmp/private.json"
printf '%s\n' '{"version":1,"systemIdentity":{"machineId":true,"sshHostKeys":true,"sshLoginPublicKeys":true,"rootPassword":true}}' >"$policy"
printf '%s\n' '{"plan":{"version":1,"planId":"plan-1"},"planHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$plan"
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
[[ -e $target/etc/ssh/ssh_host_ed25519_key ]] || fail 'SSH host key changed before complete selected preflight'
[[ ! -e $target/.autorelabel ]] || fail 'SELinux marker was created before complete selected preflight'
[[ $(cat "$target/etc/shadow") == "$shadow_before" ]] || fail 'shadow changed before complete selected preflight'

# A fully valid selected set must pass the same preflight without writing.
mkdir -p "$target/usr/lib/systemd/system"
: >"$target/usr/lib/systemd/system/selinux-autorelabel-mark.service"
mkdir -p "$target/root/.ssh"
printf '%s\n%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7yE5q7MdhqWNsZnKZqRppDi0n0QzQnQbE0SgP5Gux5 old-comment' 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCkeptblob kept-key' >"$target/root/.ssh/authorized_keys"
rootpxe_deployment_identity_linux_system_preflight "$target" || fail 'complete valid selected identity set was rejected by preflight'
[[ $(cat "$target/etc/machine-id") == old-machine-id && $(cat "$target/etc/shadow") == "$shadow_before" ]] || fail 'successful preflight modified target files'
apply_output="$tmp/identity-apply.log"
rootpxe_deployment_identity_linux_system_in_root "$target" >"$apply_output" 2>&1 || fail 'first-boot reset identity operation failed'
! grep -Fq '$6$salt$hash' "$apply_output" || fail 'identity apply output leaked the password hash'
[[ ! -s $target/etc/machine-id && ! -s $target/var/lib/dbus/machine-id ]] || fail 'machine-id was not cleared for first boot'
[[ ! -e $target/etc/ssh/ssh_host_ed25519_key && ! -e $target/etc/ssh/ssh_host_ed25519_key.pub ]] || fail 'SSH host keys were not removed for first boot'
[[ -f $target/etc/ssh/sshd_config ]] || fail 'SSH configuration was modified'
authorized="$target/root/.ssh/authorized_keys"
[[ -f $authorized && ! -L $authorized ]] || fail 'authorized_keys was not written as a regular target file'
[[ $(awk '$2=="AAAAC3NzaC1lZDI1NTE5AAAAIE7yE5q7MdhqWNsZnKZqRppDi0n0QzQnQbE0SgP5Gux5" {count++} END {print count+0}' "$authorized") == 1 ]] || fail 'authorized_keys did not deduplicate an existing key blob'
grep -Fq 'kept-key' "$authorized" || fail 'authorized_keys did not preserve an existing unrelated key'
awk -F: -v expected='$6$salt$hash' '$1=="root" && $2==expected && NF==9 && $4==2 && $5==3 && $6==4 && $7==5 && $8==6 && $9==7 {ok=1} END {exit ok?0:1}' "$target/etc/shadow" || fail 'shadow password hash or aging fields were not updated safely'
if [[ $(uname -s) == MINGW* ]]; then
    printf 'SKIP: Git Bash on NTFS cannot verify Linux owner/mode metadata; production applies chown 0:0 and chmod 0700/0600.\n'
else
    [[ $(stat -c '%u:%g %a' "$target/root/.ssh") == '0:0 700' && $(stat -c '%u:%g %a' "$authorized") == '0:0 600' ]] || fail 'authorized_keys ownership or mode is unsafe'
fi
shadow_after=$(cat "$target/etc/shadow"); authorized_after=$(cat "$authorized")
rootpxe_deployment_identity_linux_system_in_root "$target" || fail 'first-boot reset retry was not idempotent'
[[ $(cat "$target/etc/shadow") == "$shadow_after" && $(cat "$authorized") == "$authorized_after" ]] || fail 'frozen login initialization retry was not idempotent'

# A non-regular host-key match must fail before any selected target write. The
# same assertion covers a symlink when the host filesystem supports it.
printf 'must-not-change\n' >"$target/etc/machine-id"
mkdir "$target/etc/ssh/ssh_host_directory_key"
if rootpxe_deployment_identity_linux_system_preflight "$target"; then fail 'non-regular SSH host key was accepted'; fi
[[ $(cat "$target/etc/machine-id") == must-not-change ]] || fail 'unsafe host key preflight wrote target state'
rmdir "$target/etc/ssh/ssh_host_directory_key"
ln -s /tmp/not-target "$target/etc/ssh/ssh_host_unsafe_key" 2>/dev/null || true
if [[ -L $target/etc/ssh/ssh_host_unsafe_key ]]; then
    if rootpxe_deployment_identity_linux_system_preflight "$target"; then fail 'symlink SSH host key was accepted'; fi
    [[ $(cat "$target/etc/machine-id") == must-not-change ]] || fail 'symlink host key preflight wrote target state'
    rm "$target/etc/ssh/ssh_host_unsafe_key"
else
    printf 'SKIP: host filesystem cannot create SSH key symlink fixture\n'
fi

# A missing /etc/machine-id is a normal first-boot image state: create an
# empty target-local file atomically rather than rejecting the deployment.
missing="$tmp/missing"; mkdir -p "$missing/etc" "$missing/var/lib/dbus"
rootpxe_deployment_identity_clear_machine_id "$missing" || fail 'missing machine-id was rejected'
[[ -f $missing/etc/machine-id && ! -s $missing/etc/machine-id && ! -L $missing/etc/machine-id ]] || fail 'missing machine-id was not safely created empty'

# The standard compatibility links remain links; clearing their safe target
# removes the old identity without following an arbitrary target.
linked="$tmp/linked"; mkdir -p "$linked/etc" "$linked/var/lib/dbus"
printf 'old-linked-id\n' >"$linked/var/lib/dbus/machine-id"
ln -s ../var/lib/dbus/machine-id "$linked/etc/machine-id"
if [[ -L $linked/etc/machine-id ]]; then
    rootpxe_deployment_identity_clear_machine_id "$linked" || fail 'standard /etc machine-id link was rejected'
    [[ ! -s $linked/var/lib/dbus/machine-id ]] || fail 'standard /etc link did not clear its target'
    dbus_linked="$tmp/dbus-linked"; mkdir -p "$dbus_linked/etc" "$dbus_linked/var/lib/dbus"
    printf 'old-dbus-link-id\n' >"$dbus_linked/etc/machine-id"
    ln -s ../../../etc/machine-id "$dbus_linked/var/lib/dbus/machine-id"
    rootpxe_deployment_identity_clear_machine_id "$dbus_linked" || fail 'standard dbus machine-id link was rejected'
    [[ ! -s $dbus_linked/etc/machine-id && -L $dbus_linked/var/lib/dbus/machine-id ]] || fail 'standard dbus link retained old identity'
    unsafe="$tmp/unsafe"; mkdir -p "$unsafe/etc"; ln -s /tmp/not-target "$unsafe/etc/machine-id"
    if rootpxe_deployment_identity_clear_machine_id "$unsafe"; then fail 'unsafe machine-id link was accepted'; fi
else
    printf 'SKIP: host filesystem cannot create symbolic links\n'
fi
printf 'PASS: PXEOS Linux identity preflight regression\n'
