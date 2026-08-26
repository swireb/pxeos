#!/usr/bin/env bash
# Network failure diagnostics use only temporary PATH mocks; no host NIC,
# DHCP client, reboot, credential or network request is touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
network="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/etc/init.d/S40network"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/mock" "$tmp/etc/network" "$tmp/lib"
printf 'export initversion=20990101\n' >"$tmp/lib/funcs.sh"

cat >"$tmp/mock/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'link show eth0'*) printf '2: eth0: <BROADCAST,UP> mtu 1500\n    link/ether aa:bb:cc:dd:ee:ff\n' ;;
  *'-br link'*) printf 'eth0             UP             aa:bb:cc:dd:ee:ff\n' ;;
  *'-br addr'*) printf 'eth0             UP             192.0.2.10/24\n' ;;
  *) exit 0 ;;
esac
EOF
cat >"$tmp/mock/udhcpc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$tmp/mock/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$tmp/mock/uname" <<'EOF'
#!/usr/bin/env bash
printf 'test-kernel-9.9\n'
EOF
cat >"$tmp/mock/lspci" <<'EOF'
#!/usr/bin/env bash
printf '00:19.0 Ethernet controller: Test NIC\n'
EOF
chmod +x "$tmp/mock"/*

printf 'mac=aa:bb:cc:dd:ee:ff pxeapi=https://token:password@example.invalid/service/ isdebug=yes\n' >"$tmp/cmdline"
sed \
  -e "s|</proc/cmdline|<\"$tmp/cmdline\"|" \
  -e "s|/etc/network/interfaces|$tmp/etc/network/interfaces|g" \
  -e "s|/usr/share/pxeos/lib/funcs.sh|$tmp/lib/funcs.sh|" \
  -e "s|/sbin/ip|$tmp/mock/ip|g" \
  -e "s|/sbin/udhcpc|$tmp/mock/udhcpc|g" \
  -e 's|read p_ifaces <<< .*|p_ifaces=eth0|' \
  -e 's|read o_ifaces <<< .*|o_ifaces=|' \
  -e 's|linkstate=$(/bin/cat /sys/class/net/$iface/carrier)|linkstate=1|' \
  -e 's|sleep [0-9][0-9]*|:|g' \
  -e 's|read -t 60|:|' \
  "$network" >"$tmp/S40network"

set +e
PATH="$tmp/mock:$PATH" bash "$tmp/S40network" >"$tmp/output" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "failure path exit code: $rc"
grep -Fq 'PXEOS network diagnostics' "$tmp/output" || fail missing-diagnostic-banner
grep -Fq 'Kernel: test-kernel-9.9' "$tmp/output" || fail missing-kernel-version
grep -Fq 'PXEOS init version: 20990101' "$tmp/output" || fail missing-init-version
grep -Fq 'Ethernet/Network PCI devices:' "$tmp/output" || fail missing-pci-section
grep -Fq 'Interfaces:' "$tmp/output" || fail missing-interface-section
grep -Fq 'Test NIC' "$tmp/output" || fail missing-pci-fact
! grep -Fq 'token:password' "$tmp/output" || fail leaked-api-credential
! grep -Fq 'https://token:' "$tmp/output" || fail leaked-api-url
! grep -Fq 'pxeapi=' "$tmp/output" || fail leaked-cmdline
[[ $(grep -Fc 'PXEOS network diagnostics' "$tmp/output") -eq 1 ]] || fail duplicated-diagnostic-banner

# lspci is optional in reduced PXEOS builds; the failure path must remain
# useful and must not turn the diagnostic itself into a startup failure.
rm -f "$tmp/mock/lspci"
set +e
PATH="$tmp/mock:$PATH" bash "$tmp/S40network" >"$tmp/output-no-lspci" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "missing-lspci failure path exit code: $rc"
grep -Fq 'unavailable (lspci not installed)' "$tmp/output-no-lspci" || fail missing-lspci-fallback
printf 'PASS: PXEOS network diagnostics regression\n'
