#!/usr/bin/env bash
# Offline audit regression: only ordinary temporary files and shell mocks.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
build="$root/build.sh"
usb="$root/create-usb-image.sh"
realtek="$root/KernelPackages/drivers/net/ethernet/realtek/Makefile"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Split fragments must be sorted independently of compgen's enumeration.
grep -Fq 'LC_ALL=C sort' "$funcs" || fail 'split fragments lack deterministic C sort'
# mpa capture selection is the only fixed image branch allowed to bind by facts.
grep -Fq '"x$imgType" == "xmpa" && "x$type" == "xdown"' "$funcs" || fail 'mpa deploy binding branch missing'
grep -Fq 'rootpxe_prepare_capture_output_path' "$funcs" || fail 'nested capture output safety gate missing'
grep -Fq 'BCD.rootpxe-new' "$funcs" || fail 'BCD replacement is not staged'
grep -Fq 'rootpxe_build_apply_patch_once' "$build" || fail 'build patch idempotence helper missing'
grep -Fq '"$PROJECT_DIRECTORY/Buildroot/"' "$build" || fail 'Buildroot source input is not anchored to project directory'
grep -Fq 'return 1' "$build" || fail 'build artifact failure cannot propagate'
grep -Fq 'CONFIG_R8127' "$realtek" || fail 'R8127 make target missing'
grep -Fq -- '--boot-assets' "$usb" || fail 'USB assets option missing'
grep -Fq 'memtest.bin' "$usb" || fail 'USB asset contract missing memtest'
grep -Fq 'file -b --mime-type' "$usb" || fail 'USB asset validation missing'

# Exercise the real selectors with regular-file paths and command mocks only.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
sed -e 's|^\. /usr/share/pxeos/lib/partition-funcs.sh$|:|' -e 's|^\. /usr/share/pxeos/lib/restore-preflight.sh$|:|' -e 's|^\. /usr/share/pxeos/lib/capture-recovery.sh$|:|' "$funcs" >"$tmp/funcs.sh"
cp "$(dirname "$funcs")/partclone-progress.sh" "$tmp/partclone-progress.sh"
set +u; source "$tmp/funcs.sh"; set -u
lsblk() { printf '%s\n' '/dev/mock-b 2G' '/dev/mock-a 1G'; }
imgType=mpa; type=up; fdrive=''; largesize=''; getHardDisk
[[ $disks == '/dev/mock-b /dev/mock-a' && $hd == /dev/mock-b ]] || fail 'mpa capture did not retain every enumerated disk'
mkdir -p "$tmp/capture"
rootpxe_prepare_capture_output_path "$tmp/capture" "$tmp/capture/images/foo" || fail 'nested capture output path rejected'
[[ -d $tmp/capture/images ]] || fail 'nested capture output parent was not created'
rootpxe_prepare_capture_output_path "$tmp/capture" "$tmp/escape/foo" && fail 'capture output escaped staging root'

# Bash 5.2 compgen output is mocked deliberately out of order; writeImage must
# still hand the reader fragments in deterministic C-locale order.
mkdir -p "$tmp/split"; : >"$tmp/split/f.000"; : >"$tmp/split/f.001"; : >"$tmp/split/f.010"
split_args="$tmp/split.args"
compgen() { [[ $1 == -G ]] || return 1; printf '%s\n' "$tmp/split/f.010" "$tmp/split/f.000" "$tmp/split/f.001"; }
cat() { if [[ ${1:-} == -- ]]; then shift; printf '%s\n' "$@" >"$split_args"; printf payload; else command cat "$@"; fi; }
rootpxe_validate_runtime_img_format() { return 0; }; rootpxe_partclone_progress_start() { return 0; }; rootpxe_partclone_progress_wait() { return 0; }
rootpxe_console_message() { :; }; zstdmt() { command cat; }; partclone.restore() { command cat >/dev/null; }
imgFormat=5; imgLegacy=''; imgFormat=5; storage=mock; img=image
rootpxe_partclone_progress_term=xterm; rootpxe_partclone_progress_args=(); rootpxe_partclone_progress_stderr_target="$tmp/partclone.err"
rm -f /tmp/pigz1; writeImage "$tmp/split/f.*" /dev/mock no; rm -f /tmp/pigz1
[[ $(<"$split_args") == $"$tmp/split/f.000"$'\n'"$tmp/split/f.001"$'\n'"$tmp/split/f.010" ]] || fail 'unordered compgen fragments were not sorted'

# USB validation must fail before its first destructive image command.
mkdir -p "$tmp/mock-bin" "$tmp/assets"
cat >"$tmp/mock-bin/dd" <<'EOF'
#!/usr/bin/env bash
touch "${ROOTPXE_USB_DD_CALLED:?}"
EOF
chmod +x "$tmp/mock-bin/dd"
ROOTPXE_USB_DD_CALLED="$tmp/dd-called" PATH="$tmp/mock-bin:$PATH" "$usb" https://release.invalid --boot-assets "$tmp/assets" >/dev/null 2>&1 && fail 'missing boot assets accepted'
[[ ! -e $tmp/dd-called ]] || fail 'missing boot assets reached dd'
for asset in memdisk memtest.bin ipxe.krn ipxe.efi; do printf 'not html but invalid efi\n' >"$tmp/assets/$asset"; done
ROOTPXE_USB_DD_CALLED="$tmp/dd-called" PATH="$tmp/mock-bin:$PATH" "$usb" https://release.invalid --boot-assets "$tmp/assets" >/dev/null 2>&1 && fail 'invalid EFI accepted'
[[ ! -e $tmp/dd-called ]] || fail 'invalid EFI reached dd'
ROOTPXE_USB_DD_CALLED="$tmp/dd-called" PATH="$tmp/mock-bin:$PATH" "$usb" https://release.invalid --boot-assets >/dev/null 2>&1 && fail 'missing --boot-assets value accepted'
[[ ! -e $tmp/dd-called ]] || fail 'missing --boot-assets value reached dd'

# The extracted build helper must leave an already-applied patch unchanged and
# reject a conflicting patch without performing a reverse application.
eval "$(sed -n '/^rootpxe_build_apply_patch_once()/,/^}/p' "$build")"
mkdir -p "$tmp/patch-tree"; printf 'old\n' >"$tmp/patch-tree/value"
cat >"$tmp/once.patch" <<'EOF'
--- a/value
+++ b/value
@@ -1 +1 @@
-old
+new
EOF
(cd "$tmp/patch-tree" && rootpxe_build_apply_patch_once "$tmp/once.patch" && rootpxe_build_apply_patch_once "$tmp/once.patch") || fail 'idempotent patch helper failed'
[[ $(<"$tmp/patch-tree/value") == new ]] || fail 'second patch call reversed content'
printf 'other\n' >"$tmp/patch-tree/value"
(cd "$tmp/patch-tree" && rootpxe_build_apply_patch_once "$tmp/once.patch") && fail 'conflicting patch was accepted'
[[ $(<"$tmp/patch-tree/value") == other ]] || fail 'conflicting patch changed content'

# BCD stage/copy/rename failures retain the original ordinary file.
bcdroot="$tmp/bcdstore"; mkdir -p "$bcdroot/Boot"; printf 'old-bcd' >"$bcdroot/Boot/BCD"; printf 'new-bcd' >"$tmp/template-bcd"
sed -e 's|^\. /usr/share/pxeos/lib/partition-funcs.sh$|:|' -e 's|^\. /usr/share/pxeos/lib/restore-preflight.sh$|:|' -e 's|^\. /usr/share/pxeos/lib/capture-recovery.sh$|:|' -e "s|/bcdstore|$bcdroot|g" -e "s|/usr/share/pxeos/BCD|$tmp/template-bcd|g" "$funcs" >"$tmp/bcd-funcs.sh"
cp "$(dirname "$funcs")/partclone-progress.sh" "$tmp/partclone-progress.sh"
set +u; source "$tmp/bcd-funcs.sh"; set -u
osid=7; fsTypeSetting() { fstype=ntfs; }; ntfs-3g() { :; }; umount() { :; }; dots() { :; }; debugPause() { :; }; handleError() { return 1; }
cp() { return 1; }; fixWin7boot /dev/mock || :; [[ $(<"$bcdroot/Boot/BCD") == old-bcd ]] || fail 'BCD copy failure changed original'; unset -f cp
mv() { [[ $2 == "$bcdroot/Boot/BCD" ]] && return 1; command mv "$@"; }; fixWin7boot /dev/mock || :; [[ $(<"$bcdroot/Boot/BCD") == old-bcd ]] || fail 'BCD rename failure changed original'; unset -f mv

# Extract and invoke the real filesystem build function with all preparation
# collaborators mocked.  Missing output and sha256 failure must both return.
(
    set +e
    eval "$(sed -n '122,294p' "$build")"
    PROJECT_DIRECTORY="$tmp/empty-project"; buildPath="$tmp/build-output"; mkdir -p "$PROJECT_DIRECTORY" "$buildPath/fssourcex64/package" "$buildPath/fssourcex64/output/images"; : >"$buildPath/fssourcex64/package/Config.in"; : >"$buildPath/fssourcex64/.config"; : >"$buildPath/fssourcex64/.packConfDone"
    dots() { :; }; rsync() { :; }; sed() { :; }; make() { :; }
    BUILDROOT_VERSION=mock; verbose=y; confirm=n; fsDownloadOnly=n; cd "$buildPath"
    if buildFilesystem x64; then exit 1; fi
    printf payload >"$buildPath/fssourcex64/output/images/rootfs.ext2.xz"
    sha256sum() { return 1; }
    cd "$buildPath"; if buildFilesystem x64; then exit 1; fi
    exit 0
) || fail 'build artifact copy/hash failure returned success'
printf 'PASS: PXEOS audit static contracts\n'
