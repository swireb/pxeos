#!/usr/bin/env bash
# The HostKey and root public-key checks must read one bounded sshd_config
# Include chain. This fixture deliberately uses nested, quoted, multi-pattern
# Includes; older one-level parsers reject the valid Red Hat layout.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="${ROOTPXE_IDENTITY_LIB:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

. "$lib"

rootpxe_deployment_identity_ssh_split_line 'Include /etc/ssh/one\ file.conf'
[[ ${#rootpxe_deployment_identity_ssh_fields[@]} == 2 && ${rootpxe_deployment_identity_ssh_fields[1]} == '/etc/ssh/one file.conf' ]] || fail 'single backslash escape was not parsed'

rocky="$tmp/rocky"
mkdir -p "$rocky/etc/ssh/sshd_config.d" "$rocky/etc/crypto-policies/back-ends" "$rocky/etc/ssh/policy"
printf 'ID=rocky\nID_LIKE="rhel fedora"\n' >"$rocky/etc/os-release"
cat >"$rocky/etc/ssh/sshd_config" <<'EOF'
Include "/etc/ssh/sshd_config.d/10-base.conf" /etc/ssh/sshd_config.d/20-*.conf
EOF
cat >"$rocky/etc/ssh/sshd_config.d/10-base.conf" <<'EOF'
AuthorizedKeysFile .ssh/authorized_keys
Include "/etc/crypto-policies/back-ends/opensshserver.config"
HostKey /etc/ssh/ssh_host_rsa_key
EOF
# This is the normal generated policy Include: it is intentionally empty.
: >"$rocky/etc/crypto-policies/back-ends/opensshserver.config"
cat >"$rocky/etc/ssh/sshd_config.d/20-hostkeys.conf" <<'EOF'
Include "/etc/ssh/policy/hostkeys.conf"
EOF
cat >"$rocky/etc/ssh/policy/hostkeys.conf" <<'EOF'
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
AuthorizedKeysFile "/root/.ssh/authorized_keys"
EOF

rootpxe_deployment_identity_collect_ssh_host_keys "$rocky" || fail 'nested quoted Include chain was rejected for HostKey selection'
[[ ${rootpxe_deployment_identity_ssh_keys[*]} == 'ecdsa ed25519 rsa' ]] || fail 'nested Include chain did not select the three standard HostKeys'
[[ $(rootpxe_deployment_identity_root_authorized_keys_relative "$rocky") == .ssh/authorized_keys ]] || fail 'same Include chain did not prove /root/.ssh/authorized_keys is active'

rm -f "$rocky/etc/crypto-policies/back-ends/opensshserver.config"
rootpxe_deployment_identity_collect_ssh_host_keys "$rocky" || fail 'missing optional Include was not treated as empty'
: >"$rocky/etc/crypto-policies/back-ends/opensshserver.config"

cat >"$rocky/etc/ssh/policy/hostkeys.conf" <<'EOF'
AuthorizedKeysFile /root/.ssh/not-authorized_keys
EOF
# OpenSSH uses the first value.  A later noncanonical entry must not override
# the verified first canonical one.
[[ $(rootpxe_deployment_identity_root_authorized_keys_relative "$rocky") == .ssh/authorized_keys ]] || fail 'first AuthorizedKeysFile semantics changed'
cat >"$rocky/etc/ssh/sshd_config.d/10-base.conf" <<'EOF'
AuthorizedKeysFile /root/.ssh/not-authorized_keys
HostKey /etc/ssh/ssh_host_rsa_key
EOF
if rootpxe_deployment_identity_root_authorized_keys_relative "$rocky" >/dev/null; then fail 'first noncanonical root AuthorizedKeysFile was accepted'; fi
cat >"$rocky/etc/ssh/sshd_config.d/10-base.conf" <<'EOF'
AuthorizedKeysFile .ssh/authorized_keys
Include "/etc/crypto-policies/back-ends/opensshserver.config"
HostKey /etc/ssh/ssh_host_rsa_key
EOF

cat >"$rocky/etc/ssh/policy/hostkeys.conf" <<'EOF'
Match User root
AuthorizedKeysFile .ssh/authorized_keys
EOF
if rootpxe_deployment_identity_root_authorized_keys_relative "$rocky" >/dev/null; then fail 'Match block was accepted for root public keys'; fi
rootpxe_deployment_identity_collect_ssh_host_keys "$rocky" || fail 'HostKey-only initialization was blocked by an unrelated Match login block'

cat >"$rocky/etc/ssh/policy/hostkeys.conf" <<'EOF'
Include ../../outside.conf
EOF
if rootpxe_deployment_identity_collect_ssh_host_keys "$rocky"; then
    fail 'relative Include escape was accepted'
fi

printf 'PASS: PXEOS SSH config parser regression\n'
