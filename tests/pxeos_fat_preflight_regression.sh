#!/usr/bin/env bash
# FAT 预检定向回归：仅提取函数并使用命令替身，不访问真实设备。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d /tmp/pxeos-fat-preflight.XXXXXX)"
case "$tmp" in /tmp/pxeos-fat-preflight.*) ;; *) exit 2 ;; esac
trap 'rm -rf -- "$tmp"' EXIT
failures=0
checks=0
check() {
    checks=$((checks + 1))
    if "$@"; then return 0; fi
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}
for helper in rootpxe_fat_require_unmounted rootpxe_fat_dirty_only_diagnostic rootpxe_fat_growth_preflight; do
    eval "$(sed -n "/^${helper}() {/,/^}/p" "$funcs")"
done
reject_diagnostic() { ! rootpxe_fat_dirty_only_diagnostic "$1"; }

printf '%s\n' \
    'fsck.fat 4.2 (2021-01-31)' \
    'Dirty bit is set. Fs was not properly unmounted and some data may be corrupt.' \
    ' Automatically removing dirty bit.' '' \
    'Leaving filesystem unchanged.' \
    '/dev/mockfat: 13 files, 2312/249364 clusters' >"$tmp/dirty.log"
printf '%s\n' \
    'fsck.fat 4.2 (2021-01-31)' \
    'There are differences between boot sector and its backup.' \
    'This is mostly harmless. Differences: (offset:original/backup)' \
    '  65:01/00' \
    '  Not automatically fixing this.' \
    'Dirty bit is set. Fs was not properly unmounted and some data may be corrupt.' \
    ' Automatically removing dirty bit.' '' \
    'Leaving filesystem unchanged.' \
    '/dev/mockfat: 13 files, 2312/249364 clusters' >"$tmp/boot-dirty.log"
printf '%s\n' \
    'Cannot initialize conversion from codepage 850 to ANSI_X3.4-1968: Invalid argument' \
    'Cannot initialize conversion from ANSI_X3.4-1968 to codepage 850: Invalid argument' \
    'Using internal CP850 conversion table' >"$tmp/cp850.log"
cat "$tmp/cp850.log" "$tmp/boot-dirty.log" >"$tmp/screenshot.log"

check rootpxe_fat_dirty_only_diagnostic "$tmp/dirty.log"
check rootpxe_fat_dirty_only_diagnostic "$tmp/boot-dirty.log"
check rootpxe_fat_dirty_only_diagnostic "$tmp/screenshot.log"
for rejected in other_offset other_value extra_offset corruption missing_dirty partial_group old_version partial_cp850 duplicate_group; do
    case "$rejected" in
        other_offset) sed 's/65:01\/00/66:01\/00/' "$tmp/boot-dirty.log" ;;
        other_value) sed 's/65:01\/00/65:02\/00/' "$tmp/boot-dirty.log" ;;
        extra_offset) sed '/  65:01\/00/a\  66:01/00' "$tmp/boot-dirty.log" ;;
        corruption) cat "$tmp/boot-dirty.log"; printf '%s\n' 'FATs differ but appear to be intact.' '  Using first FAT.' ;;
        missing_dirty) sed '/^Dirty bit is set/d' "$tmp/boot-dirty.log" ;;
        partial_group) sed '/^This is mostly harmless/d' "$tmp/boot-dirty.log" ;;
        old_version) sed 's/fsck.fat 4.2 (2021-01-31)/fsck.fat 4.1 (2017-01-24)/' "$tmp/boot-dirty.log" ;;
        partial_cp850) head -n 1 "$tmp/cp850.log"; cat "$tmp/boot-dirty.log" ;;
        duplicate_group) sed '/^There are differences/p' "$tmp/boot-dirty.log" ;;
    esac >"$tmp/reject-$rejected.log"
    check reject_diagnostic "$tmp/reject-$rejected.log"
done

run_case() (
    local case_name="$1" expected_status="$2" expected_fsck="$3" expected_repair="$4"
    local trace="$tmp/$case_name.trace" log="$tmp/result-$case_name.log" fsck_calls=0 mount_calls=0 status=0
    : >"$trace"
    command() {
        if [[ $1 == -v && ${2:-} == findmnt && $case_name == mount_missing ]]; then return 1; fi
        builtin command "$@"
    }
    findmnt() {
        mount_calls=$(( $(grep -c '^findmnt:' "$trace" || true) + 1 ))
        printf 'findmnt:%s\n' "$*" >>"$trace"
        case "$case_name:$mount_calls" in
            mounted:*|clean_mounted:*|mount_before_repair:2|mount_before_recheck:3) return 0 ;;
            mount_error:*) return 2 ;;
            mount_stderr:*) printf 'findmnt: cannot read mount table\n' >&2; return 1 ;;
        esac
        return 1
    }
    fsck.fat() {
        fsck_calls=$((fsck_calls + 1))
        printf 'fsck:%s\n' "$*" >>"$trace"
        if [[ $1 == -a ]]; then
            [[ $case_name == repair_fail ]] && return 2
            [[ $case_name == repair_zero ]] && return 0
            return 1
        fi
        if [[ $fsck_calls -gt 1 ]]; then
            [[ $case_name == recheck_fail ]] && return 1
            return 0
        fi
        case "$case_name" in
            clean|clean_mounted) printf '%s\n' 'fsck.fat 4.2 (2021-01-31)' '/dev/mockfat: 13 files, 2312/249364 clusters'; return 0 ;;
            structural) cat "$tmp/reject-corruption.log"; return 1 ;;
            other_offset) cat "$tmp/reject-other_offset.log"; return 1 ;;
            fsck_error) return 8 ;;
            dirty_only) cat "$tmp/dirty.log" ;;
            *) cat "$tmp/screenshot.log" ;;
        esac
        return 1
    }
    if rootpxe_fat_growth_preflight /dev/mockfat "$log"; then status=0; else status=$?; fi
    [[ $status -eq $expected_status ]] || { printf 'FAIL: %s status=%s expected=%s\n' "$case_name" "$status" "$expected_status" >&2; return 1; }
    [[ $(grep -c '^fsck:' "$trace" || true) -eq $expected_fsck ]] || { printf 'FAIL: %s unexpected fsck calls\n' "$case_name" >&2; return 1; }
    [[ $(grep -c '^fsck:-a ' "$trace" || true) -eq $expected_repair ]] || { printf 'FAIL: %s unexpected repair calls\n' "$case_name" >&2; return 1; }
    if [[ $case_name != mount_missing ]]; then
        [[ $(head -n 1 "$trace") == findmnt:* ]] || { printf 'FAIL: %s fsck ran before mount check\n' "$case_name" >&2; return 1; }
    fi
)

check run_case clean 0 1 0
check run_case dirty_only 0 3 1
check run_case screenshot 0 3 1
check run_case repair_zero 0 3 1
check run_case mounted 16 0 0
check run_case clean_mounted 16 0 0
check run_case mount_error 16 0 0
check run_case mount_stderr 16 0 0
check run_case mount_missing 16 0 0
check run_case structural 1 1 0
check run_case other_offset 1 1 0
check run_case fsck_error 8 1 0
check run_case repair_fail 2 2 1
check run_case recheck_fail 1 3 1
check run_case mount_before_repair 16 1 0
check run_case mount_before_recheck 16 2 1
printf 'FAT preflight: %s checks, %s failures\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
