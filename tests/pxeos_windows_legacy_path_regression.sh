#!/usr/bin/env bash
# Local fixtures for legacy BCD replacement and SAM lookup; no disks/mounts.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for name in rootpxe_resolve_casefold_directory rootpxe_resolve_casefold_file getSAMLoc fixWin7boot; do
    awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$funcs" |
        sed -e "s|/ntfs|$tmp/ntfs|g" -e "s|/bcdstore|$tmp/bcdstore|g" -e "s|/usr/share/pxeos/BCD|$tmp/template-bcd|g" >>"$tmp/functions.sh"
done
source "$tmp/functions.sh"

if [[ ${1:-all} != bcd ]]; then
    for variant in Windows/System32/config/SAM windows/system32/config/sam wInDoWs/sYsTeM32/cOnFiG/sAm; do
        rm -rf -- "$tmp/ntfs"
        mkdir -p "$tmp/ntfs/${variant%/*}"
        touch "$tmp/ntfs/$variant"
        sam=STALE
        getSAMLoc || fail "SAM lookup rejected $variant"
        [[ $sam == "$tmp/ntfs/$variant" ]] || fail "SAM path case lost: $variant"
    done
    rm "$tmp/ntfs/$variant"
    getSAMLoc || :
    [[ -z $sam ]] || fail stale-SAM-after-missing-hive
    ln -s "$tmp/functions.sh" "$tmp/ntfs/$variant"
    getSAMLoc || :
    [[ -z $sam ]] || fail symlink-SAM-accepted
    rm "$tmp/ntfs/$variant"
    touch "$tmp/ntfs/$variant" "${tmp}/ntfs/${variant%/*}/SAM"
    getSAMLoc || :
    [[ -z $sam ]] || fail ambiguous-SAM-accepted
    printf 'PASS: SAM casefold paths and stale-value cleanup\n'
fi

if [[ ${1:-all} != sam ]]; then
    osid=7
    fsTypeSetting(){ fstype=ntfs; }
    dots(){ :; }
    debugPause(){ :; }
    handleError(){ return 1; }
    rootpxe_run_logged_typed_native(){ shift 2; "$@"; }
    ntfs-3g(){ return 0; }
    umount(){ return 0; }
    printf 'replacement-bcd' >"$tmp/template-bcd"
    for variant in Boot/BCD boot/bcd bOoT/bCd; do
        rm -rf -- "$tmp/bcdstore"
        mkdir -p "$tmp/bcdstore/${variant%/*}"
        printf 'original-bcd' >"$tmp/bcdstore/$variant"
        fixWin7boot /dev/fake >/dev/null || fail "BCD replacement rejected $variant"
        [[ $(cat "$tmp/bcdstore/$variant") == replacement-bcd ]] || fail "BCD replacement skipped $variant"
        [[ $(cat "$tmp/bcdstore/${variant%/*}/BCD.bak") == original-bcd ]] || fail "BCD backup lost original for $variant"
        [[ $(find "$tmp/bcdstore/${variant%/*}" -maxdepth 1 -type f -iname bcd | wc -l) -eq 1 ]] || fail duplicate-BCD-created
    done
    # Missing, ambiguous and symlink inputs must never become replacement targets.
    rm "$tmp/bcdstore/$variant"
    fixWin7boot /dev/fake >/dev/null || :
    [[ ! -e "$tmp/bcdstore/$variant" ]] || fail missing-BCD-fabricated
    ln -s "$tmp/template-bcd" "$tmp/bcdstore/$variant"
    fixWin7boot /dev/fake >/dev/null || :
    [[ -L "$tmp/bcdstore/$variant" ]] || fail symlink-BCD-replaced
    rm "$tmp/bcdstore/$variant"
    printf 'one' >"$tmp/bcdstore/$variant"
    printf 'two' >"$tmp/bcdstore/${variant%/*}/BCD"
    fixWin7boot /dev/fake >/dev/null || :
    [[ $(cat "$tmp/bcdstore/$variant") == one && $(cat "$tmp/bcdstore/${variant%/*}/BCD") == two ]] || fail ambiguous-BCD-replaced
    printf 'PASS: legacy BCD casefold paths and replacement targets\n'
fi
