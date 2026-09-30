#!/usr/bin/env bash
# Verify that the Sysprep destination is discovered without trusting a fixed
# casing, and rejects links or case-folding ambiguity before any XML write.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
funcs=${PXEOS_FUNCS:-"$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"; }
expect_link_failure() {
    local link="$1" root_path="$2"
    if [[ -L $link ]]; then
        expect_fail rootpxe_resolve_windows_sysprep_unattend_path "$root_path"
    else
        printf 'SKIP: symlink semantics unavailable for %s\n' "$link" >&2
    fi
}

awk '/^rootpxe_resolve_casefold_directory\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >"$tmp/functions.sh"
awk '/^rootpxe_resolve_windows_sysprep_unattend_path\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >>"$tmp/functions.sh"
source "$tmp/functions.sh"

make_tree() {
    local name="$1" windows="$2" system32="$3" sysprep="$4"
    mkdir -p "$tmp/$name/$windows/$system32/$sysprep"
    printf '%s\n' "$tmp/$name"
}

normal=$(make_tree normal Windows System32 Sysprep)
assert_eq "$(rootpxe_resolve_windows_sysprep_unattend_path "$normal")" "$normal/Windows/System32/Sysprep/unattend.xml"

lower=$(make_tree lower windows system32 sysprep)
assert_eq "$(rootpxe_resolve_windows_sysprep_unattend_path "$lower")" "$lower/windows/system32/sysprep/unattend.xml"

mixed=$(make_tree mixed wInDoWs sYsTeM32 sYsPrEp)
printf '<unattend/>\n' >"$mixed/wInDoWs/sYsTeM32/sYsPrEp/UNATTEND.XML"
assert_eq "$(rootpxe_resolve_windows_sysprep_unattend_path "$mixed")" "$mixed/wInDoWs/sYsTeM32/sYsPrEp/UNATTEND.XML"

expect_fail rootpxe_resolve_windows_sysprep_unattend_path "$tmp/missing"
mkdir -p "$tmp/relative-root/Windows/System32/Sysprep"
(
    cd "$tmp"
    expect_fail rootpxe_resolve_windows_sysprep_unattend_path relative-root
)
ln -s "$normal" "$tmp/root-link"
expect_link_failure "$tmp/root-link" "$tmp/root-link"

link_windows="$tmp/link-windows"
mkdir "$link_windows"
ln -s "$normal/Windows" "$link_windows/Windows"
expect_link_failure "$link_windows/Windows" "$link_windows"

link_system32="$tmp/link-system32"
mkdir -p "$link_system32/Windows"
ln -s "$normal/Windows/System32" "$link_system32/Windows/System32"
expect_link_failure "$link_system32/Windows/System32" "$link_system32"

link_sysprep="$tmp/link-sysprep"
mkdir -p "$link_sysprep/Windows/System32"
ln -s "$normal/Windows/System32/Sysprep" "$link_sysprep/Windows/System32/Sysprep"
expect_link_failure "$link_sysprep/Windows/System32/Sysprep" "$link_sysprep"

dangling="$tmp/dangling"
mkdir -p "$dangling"
if ln -s "$tmp/not-present" "$dangling/windows" 2>/dev/null; then
    expect_link_failure "$dangling/windows" "$dangling"
else
    printf 'SKIP: dangling symlink creation unavailable\n' >&2
fi

existing_link=$(make_tree existing-link Windows System32 Sysprep)
if ln -s "$tmp/not-present" "$existing_link/Windows/System32/Sysprep/UNATTEND.XML" 2>/dev/null; then
    expect_link_failure "$existing_link/Windows/System32/Sysprep/UNATTEND.XML" "$existing_link"
else
    printf 'SKIP: existing-file symlink creation unavailable\n' >&2
fi

existing_dir=$(make_tree existing-dir Windows System32 Sysprep)
mkdir "$existing_dir/Windows/System32/Sysprep/unattend.xml"
expect_fail rootpxe_resolve_windows_sysprep_unattend_path "$existing_dir"

duplicate_dir=$(make_tree duplicate-dir Windows System32 Sysprep)
if mkdir "$duplicate_dir/Windows/System32/sysprep" 2>/dev/null; then
    expect_fail rootpxe_resolve_windows_sysprep_unattend_path "$duplicate_dir"
else
    printf 'SKIP: case-fold duplicate directory requires a case-sensitive filesystem\n' >&2
fi

duplicate_file=$(make_tree duplicate-file Windows System32 Sysprep)
printf x >"$duplicate_file/Windows/System32/Sysprep/unattend.xml"
if ( set -C; : >"$duplicate_file/Windows/System32/Sysprep/UNATTEND.XML" ) 2>/dev/null; then
    expect_fail rootpxe_resolve_windows_sysprep_unattend_path "$duplicate_file"
else
    printf 'SKIP: case-fold duplicate file requires a case-sensitive filesystem\n' >&2
fi

printf 'PASS: PXEOS Sysprep path regression\n'
