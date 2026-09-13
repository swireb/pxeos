#!/usr/bin/env bash
# PXEOS uses eudev with SysV init.  The upstream event-autoactivation rule
# invokes systemd-run, which cannot exist in the runtime image.  Keep ordinary
# LVM udev synchronisation, but assert that the systemd-only rule is removed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
patch_file="$root/patch/filesystem/lvm2-udev-sync.patch"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 missing: $2"; }
must_not_have() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

# LVM command-side udev synchronisation remains enabled.  Only the event rule
# whose upstream implementation delegates to systemd-run is removed for
# non-systemd images.
must_have "$patch_file" 'LVM2_CONF_OPTS += --enable-udev_rules --enable-udev_sync'
must_have "$patch_file" 'ifneq ($(BR2_INIT_SYSTEMD),y)'
must_have "$patch_file" 'define LVM2_REMOVE_SYSTEMD_UDEV_AUTOACTIVATION'
must_have "$patch_file" '$(TARGET_DIR)/usr/lib/udev/rules.d/69-dm-lvm.rules'
must_have "$patch_file" 'LVM2_POST_INSTALL_TARGET_HOOKS += LVM2_REMOVE_SYSTEMD_UDEV_AUTOACTIVATION'
must_not_have "$patch_file" 'systemd-run'
must_have "$funcs" 'rootpxe_activate_lvm_vg()'
must_have "$funcs" 'vgchange -ay --select "vg_uuid=$vg_uuid" "$vg_name"'

# Check that the patch remains applicable to the Buildroot LVM2 makefile
# fragment it changes, and that it leaves the normal udev rule option intact.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/package/lvm2"
cat >"$tmp/package/lvm2/lvm2.mk" <<'EOF'
ifeq ($(BR2_PACKAGE_HAS_UDEV),y)
LVM2_CONF_OPTS += --enable-udev_rules
endif
EOF
(cd "$tmp" && patch --batch --forward -p1 <"$patch_file") >/dev/null || fail 'patch did not apply to LVM2 makefile contract'
must_have "$tmp/package/lvm2/lvm2.mk" 'LVM2_CONF_OPTS += --enable-udev_rules --enable-udev_sync'
must_have "$tmp/package/lvm2/lvm2.mk" 'ifneq ($(BR2_INIT_SYSTEMD),y)'
must_have "$tmp/package/lvm2/lvm2.mk" 'LVM2_POST_INSTALL_TARGET_HOOKS += LVM2_REMOVE_SYSTEMD_UDEV_AUTOACTIVATION'

printf 'pxeos LVM udev rule regression: PASS\n'
