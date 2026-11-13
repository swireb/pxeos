#!/usr/bin/env bash
# Run extracted capture metadata functions with ordinary files and command stubs.
set -euo pipefail
if [[ ${PXEOS_STARTUP_TEST_ISOLATED:-} != 1 ]]; then
    exec /usr/bin/bash "$(dirname -- "${BASH_SOURCE[0]}")/run-startup-regression.sh" "${0##*/}" "$@"
fi
[[ $0 == /pxeos/tests/pxeos_capture_metadata_test.sh && ! -e /sys && ! -w /proc/sysrq-trigger ]] || exit 125

root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for function in saveGRUB savePartitionTablesAndBootLoaders; do
    definition=$(sed -n "/^${function}() {$/,/^}$/p" "$funcs")
    [[ $definition == "$function() {"$'\n'* && $definition == *$'\n}' ]] || fail 'function boundary missing'
    eval "$definition"
done

# These names always resolve to shell stubs; the sandbox exposes no block device.
flock() { [[ $1 == "$tmp/source" ]] || exit 92; shift; "$@"; }
sfdisk() {
    [[ $2 == "$tmp/source" ]] || exit 92
    [[ $1 == -l ]] && return 0
    [[ $1 == -d ]] || exit 92
    local number=0
    [[ ! -f $tmp/dump-count ]] || read -r number <"$tmp/dump-count"
    number=$((number+1)); printf '%s\n' "$number" >"$tmp/dump-count"
    [[ $failure != dump-first || $number != 1 ]] || return 17
    [[ $failure != dump-last || $number != 2 ]] || return 18
    [[ $failure != invalid-count ]] || { printf 'label: dos\n'; return 0; }
    printf '%s : start= %s, size= 8192, type=83\n' "$tmp/source1" "$start_sector"
}
dd() {
    local argument output='' count=''
    for argument in "$@"; do
        case "$argument" in
            "if=$tmp/source"|bs=512) ;;
            of=*) output=${argument#of=} ;;
            count=*) count=${argument#count=} ;;
            *) exit 92 ;;
        esac
    done
    if [[ -z $output ]]; then
        [[ $failure != probe-read ]] || return 19
        [[ $grub == yes ]] && printf 'GRUB fixture\n'
        return 0
    fi
    [[ $output == "$tmp/image/boot" && $count =~ ^[1-9][0-9]*$ ]] || return 20
    [[ $failure != copy ]] || return 21
    printf '%s\n' "$count" >"$tmp/copied-count"
    printf 'boot fixture\n' >"$output"
}
touch() {
    [[ $# == 1 && $1 == "$tmp/image/grub" ]] || exit 92
    [[ $failure != marker ]] || return 22
    : >"$1"
}
sgdisk() {
    [[ $* == "-b $tmp/image/d1.mbr $tmp/source" ]] || exit 92
    [[ $failure != gpt ]] || return 23
    printf 'gpt fixture\n' >"$tmp/image/d1.mbr"
}
handleError() { printf 'HANDLE_ERROR:%s\n' "$*"; exit 91; }
hasGPT() { hasgpt=$gpt; }
runPartprobe() { :; }
dots() { :; }
debugPause() { :; }
saveAllEBRs() { fail 'unexpected extended partition branch'; }
MBRFileName() { mbrfilename="$tmp/image/boot"; }
hasGrubFileName() { hasgrubfilename="$tmp/image/grub"; }
sfdiskPartitionFileName() { sfdiskoriginalpartitionfilename="$tmp/image/table"; }

run_case() {
    gpt=$1; failure=$2; grub=$3; start_sector=$4
    rm -rf -- "$tmp/image"
    mkdir "$tmp/image"
    : >"$tmp/source"
    rm -f -- "$tmp/dump-count" "$tmp/copied-count"
    local status=0
    (
        # Production does not enable errexit/nounset. Explicit checks, rather
        # than the test runner's options, must stop a failed capture.
        set +eu
        savePartitionTablesAndBootLoaders "$tmp/source" 1 "$tmp/image" 50 all
        printf 'CONTINUED\n'
    ) >"$tmp/result" 2>&1 || status=$?
    if [[ $failure == none ]]; then
        [[ $status == 0 ]] && grep -qx CONTINUED "$tmp/result" || fail "normal capture failed: gpt=$gpt"
        local expected=$start_sector actual
        (( expected <= 2048 )) || expected=2048
        [[ $expected != 8 && $expected != 63 ]] || expected=1
        read -r actual <"$tmp/copied-count"
        [[ $actual == "$expected" ]] || fail 'boot copy sector limit changed'
    else
        [[ $status == 91 ]] || fail "metadata failure was ignored: gpt=$gpt failure=$failure status=$status"
        ! grep -Eq '^(Done|CONTINUED)$' "$tmp/result" || fail 'failed metadata reported success'
    fi
}

for gpt in 0 1; do
    for failure in dump-first invalid-count probe-read copy marker dump-last; do
        run_case "$gpt" "$failure" yes 2048
    done
    run_case "$gpt" none no 2048
    run_case "$gpt" none yes 4096
    run_case "$gpt" none yes 63
    run_case "$gpt" none yes 8
done
run_case 1 gpt no 2048
printf 'PASS: capture metadata failures stop before success or partition capture (21 cases)\n'
