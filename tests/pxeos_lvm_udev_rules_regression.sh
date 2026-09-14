#!/usr/bin/env bash
# PXEOS uses eudev with SysV init.  The upstream event-autoactivation rule
# invokes systemd-run, which cannot exist in the runtime image.  Keep ordinary
# LVM udev synchronisation, but assert that the systemd-only rule is removed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
patch_file="$root/patch/filesystem/lvm2-udev-sync.patch"
autoactivation_patch="$root/patch/filesystem/lvm2-no-systemd-autoactivation.patch"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
build_script="$root/build.sh"
bad_hook_fixture="$root/tests/fixtures/lvm2-udev-sync-91b1dd3.patch"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 missing: $2"; }
must_not_have() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

# LVM command-side udev synchronisation remains enabled.  Only the event rule
# whose upstream implementation delegates to systemd-run is removed for
# non-systemd images.
must_have "$patch_file" 'LVM2_CONF_OPTS += --enable-udev_rules --enable-udev_sync'
must_have "$patch_file" 'LVM2_DEPENDENCIES += udev'
must_have "$autoactivation_patch" 'ifneq ($(BR2_INIT_SYSTEMD),y)'
must_have "$autoactivation_patch" 'define LVM2_REMOVE_SYSTEMD_UDEV_AUTOACTIVATION'
must_have "$autoactivation_patch" '$(TARGET_DIR)/usr/lib/udev/rules.d/69-dm-lvm.rules'
must_have "$autoactivation_patch" 'LVM2_POST_INSTALL_TARGET_HOOKS += LVM2_REMOVE_SYSTEMD_UDEV_AUTOACTIVATION'
must_have "$autoactivation_patch" $'+\trm -f $(TARGET_DIR)/usr/lib/udev/rules.d/69-dm-lvm.rules'
must_not_have "$autoactivation_patch" $'+\\trm -f'
must_have "$funcs" 'rootpxe_activate_lvm_vg()'
must_have "$funcs" 'vgchange -ay --select "vg_uuid=$vg_uuid" "$vg_name"'
must_have "$build_script" 'rootpxe_build_apply_patch_once()'
must_have "$build_script" 'lvm2-repair-literal-tab-hook.patch'

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
(cd "$tmp" && patch --batch --forward -p1 <"$autoactivation_patch") >/dev/null || fail 'autoactivation patch did not apply after udev-sync patch'
must_have "$tmp/package/lvm2/lvm2.mk" 'LVM2_CONF_OPTS += --enable-udev_rules --enable-udev_sync'
must_have "$tmp/package/lvm2/lvm2.mk" 'ifneq ($(BR2_INIT_SYSTEMD),y)'
must_have "$tmp/package/lvm2/lvm2.mk" 'LVM2_POST_INSTALL_TARGET_HOOKS += LVM2_REMOVE_SYSTEMD_UDEV_AUTOACTIVATION'
grep -Fq $'\trm -f $(TARGET_DIR)/usr/lib/udev/rules.d/69-dm-lvm.rules' "$tmp/package/lvm2/lvm2.mk" || fail 'generated hook recipe is not an actual tab-indented Make recipe'

# A persisted source tree may already carry the stable udev-sync patch.  The
# new independent hook patch must still apply without replaying that hunk.
mkdir -p "$tmp/already-sync/package/lvm2"
cp "$tmp/package/lvm2/lvm2.mk" "$tmp/already-sync/package/lvm2/lvm2.mk"
(cd "$tmp/already-sync" && patch --batch --force --reverse -p1 <"$autoactivation_patch" >/dev/null) || fail 'unable to prepare existing-sync fixture'
(cd "$tmp/already-sync" && patch --batch --forward -p1 <"$autoactivation_patch" >/dev/null) || fail 'autoactivation patch did not apply to existing-sync fixture'

# Exercise the production helpers themselves, not a copy of their patch
# commands.  Each persisted source state must accept the complete production
# sequence twice; unknown patch states still make apply_patch_once fail.
prod="$tmp/production-patch-functions.sh"
awk '/^rootpxe_build_apply_patch_once\(\)/ {on=1} on {print} on && /^}$/ {exit}' "$build_script" >"$prod"
awk '/^rootpxe_build_apply_filesystem_patches\(\)/ {on=1} on {print} on && /^}$/ {exit}' "$build_script" >>"$prod"
[[ -s $prod ]] || fail 'production patch helpers could not be extracted'
project="$tmp/project"; mkdir -p "$project/patch/filesystem"
cp "$patch_file" "$autoactivation_patch" "$root/patch/filesystem/lvm2-repair-literal-tab-hook.patch" "$project/patch/filesystem/"
run_production_sequence() {
    local fixture=$1
    (
        cd "$fixture"
        PROJECT_DIRECTORY="$project"
        dots() { :; }
        . "$prod"
        rootpxe_build_apply_filesystem_patches
        rootpxe_build_apply_filesystem_patches
    )
}
make_pristine() {
    local fixture=$1
    mkdir -p "$fixture/package/lvm2"
    cat >"$fixture/package/lvm2/lvm2.mk" <<'EOF'
ifeq ($(BR2_PACKAGE_HAS_UDEV),y)
LVM2_CONF_OPTS += --enable-udev_rules
endif
EOF
}
make_pristine "$tmp/fresh"
run_production_sequence "$tmp/fresh" || fail 'production sequence rejected pristine fixture'
make_pristine "$tmp/old-sync"
(cd "$tmp/old-sync" && patch --batch --forward -p1 <"$patch_file") >/dev/null
run_production_sequence "$tmp/old-sync" || fail 'production sequence rejected old-sync fixture'
make_pristine "$tmp/complete"
(cd "$tmp/complete" && patch --batch --forward -p1 <"$patch_file" && patch --batch --forward -p1 <"$autoactivation_patch") >/dev/null
run_production_sequence "$tmp/complete" || fail 'production sequence rejected complete fixture'
make_pristine "$tmp/bad-hook"
(cd "$tmp/bad-hook" && patch --batch --forward -p1 <"$bad_hook_fixture") >/dev/null || fail '91b1dd3 bad hook fixture did not apply'
bad_recipe=$(awk '/^\\trm -f \$\(TARGET_DIR\)\/usr\/lib\/udev\/rules\.d\/69-dm-lvm\.rules$/ {print; exit}' "$tmp/bad-hook/package/lvm2/lvm2.mk")
[[ -n $bad_recipe ]] || fail '91b1dd3 fixture lacks literal-tab recipe'
rules="$tmp/target/usr/lib/udev/rules.d"; mkdir -p "$rules"
: >"$rules/10-dm.rules"; : >"$rules/13-dm-disk.rules"; : >"$rules/69-dm-lvm.rules"
bad_recipe=$(printf '%s' "$bad_recipe" | sed "s|\$(TARGET_DIR)|$tmp/target|g")
if bash -c "$bad_recipe"; then fail 'literal-tab production recipe unexpectedly executed'; fi
run_production_sequence "$tmp/bad-hook" || fail 'production sequence rejected known literal-tab fixture'
good_recipe=$(awk '/^\trm -f \$\(TARGET_DIR\)\/usr\/lib\/udev\/rules\.d\/69-dm-lvm\.rules$/ {print; exit}' "$tmp/bad-hook/package/lvm2/lvm2.mk")
[[ -n $good_recipe ]] || fail 'migration did not generate actual-tab recipe'
good_recipe=$(printf '%s' "$good_recipe" | sed "s|\$(TARGET_DIR)|$tmp/target|g")
bash -c "$good_recipe"
[[ ! -e $rules/69-dm-lvm.rules && -e $rules/10-dm.rules && -e $rules/13-dm-disk.rules ]] || fail 'production hook did not remove only 69 rule'

printf 'pxeos LVM udev rule regression: PASS\n'
