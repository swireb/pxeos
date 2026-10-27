#!/usr/bin/env bash
# Fixed ClamAV diagnostic regression.  Production paths stay hard-coded;
# only the helper's private test directory is substituted below.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
av="$overlay/bin/pxeos.av"
lib="$overlay/usr/share/pxeos/lib"
. "$root/tests/task-log-test-support.sh"

tmp=$(mktemp -d /tmp/pxeos-fixed-av-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check(){ "$@" || fail "$*"; }

check test -f "$av"
check test -f "$lib/log-paths.sh"
! grep -q -- '--log=/clamavscan/pxeos/log/log.txt' "$av" || fail legacy-scan-log-path
! grep -q -- '/tmp/mount-output' "$av" || fail legacy-mount-output-path
! grep -q -- '/tmp/clamavscan-mount-output' "$av" || fail legacy-partition-mount-output-path
grep -q -- 'rootpxe_log_publish clamav.log' "$av" || fail fixed-log-publish-missing
grep -q -- 'grep.*FOUND' "$av" || fail found-parser-missing
grep -q -- 'mkdir -p /clamavscan/pxeos/{tmp,infected}' "$av" || fail log-directory-still-created
grep -q -- 'if ! pxeos_av_scan_prepare; then' "$av" || fail raw-missing-abort-branch
grep -q -- 'clamscan -r .*--log=\$scan_log' "$av" || fail scan-log-argv-missing

# Extract only the small production helpers; the main script is never sourced.
for name in pxeos_av_diag_warn pxeos_av_diag_begin pxeos_av_prepare_task_log pxeos_av_diag_reference pxeos_av_scan_prepare pxeos_av_diag_finish pxeos_av_run_logged pxeos_av_found_lines; do
    eval "$(sed -n "/^${name}() *{/,/^}/p" "$av")"
done

# Native behavior must survive a publication failure, with the raw buffer
# removed after each operation.
last_raw=''
rootpxe_log_raw_file() {
    mkdir -p "$tmp/mock-log"
    rootpxe_log_raw_path=$(mktemp "$tmp/mock-log/.raw.XXXXXX")
    chmod 600 "$rootpxe_log_raw_path"
    last_raw=$rootpxe_log_raw_path
}
publish_fail=no
published=''
rootpxe_log_publish() {
    published=$2
    [[ $publish_fail == yes ]] && return 1
    return 0
}
native_called=no
native() { native_called=yes; printf 'MOUNT_DIAGNOSTIC token=mount-secret\n'; return "${native_rc:-0}"; }
rc=0; native_rc=7; pxeos_av_run_logged clamav_mount native || rc=$?
check test "$native_called" = yes
check test "$rc" = 7
check test ! -e "$last_raw"
publish_fail=yes; native_called=no; native_rc=9
rc=0; pxeos_av_run_logged clamav_mount native 2>"$tmp/publish-failure" || rc=$?
check test "$native_called" = yes
check test "$rc" = 9
check grep -q 'unavailable' "$tmp/publish-failure"
check test ! -e "$last_raw"
! grep -q 'mount-secret' "$tmp/publish-failure" || fail raw-leaked-to-console

# Scan parsing is complete and independent from a separate mount diagnostic.
printf 'MOUNT_FAIL token=mount-secret\n' >"$tmp/mount.raw"
printf 'clean\nEICAR FOUND token=scan-secret\nsecond FOUND\n' >"$tmp/scan.raw"
found=$(pxeos_av_found_lines "$tmp/scan.raw")
expected=$(printf 'EICAR FOUND token=scan-secret\nsecond FOUND\n')
check test "$found" = "$expected"
! pxeos_av_found_lines "$tmp/mount.raw" | grep -q FOUND || fail mixed-found-source

# Execute the production post-scan summary. Infected paths remain in the
# private diagnostic log; the removed PHP callback and response file are gone.
! grep -q 'service/av.php\|/tmp/avstat' "$av" || fail retired-php-reporting
rootpxe_console_message() { printf '[%s] %s\n' "$1" "$2"; }
scan_log="$tmp/scan.raw"
summary=$(eval "$(awk '/^        cnt=\$\(pxeos_av_found_lines/ {copy=1} copy && /pxeos_av_diag_finish/ {exit} copy {print}' "$av")")
check test "$summary" = '[INFO] Infected files: 2.'
! grep -q 'scan-secret\|EICAR' <<<"$summary" || fail raw-scan-content-leaked

# Exercise the real fixed-log publisher and the task-level new-file boundary
# in a private substituted directory.
unset -f rootpxe_log_raw_file rootpxe_log_publish
. <(sed "s|/tmp/log|$tmp/log|g" "$lib/log-paths.sh")
pxeos_av_prepare_task_log
check test "$pxeos_av_log_ready" = yes
first_log="$tmp/log/clamav.log"
first_inode=$(stat -c '%d:%i' "$first_log")
native_rc=0; native_called=no; pxeos_av_run_logged av_mount native
check test "$native_called" = yes
check grep -q 'token=\[REDACTED\]' "$first_log"
check grep -q '^OP=av_mount$' "$first_log"
printf 'OLD_AV_MARKER\n' >>"$first_log"
pxeos_av_run_logged av_freshclam native
check grep -q '^OP=av_freshclam$' "$first_log"
pxeos_av_prepare_task_log
second_inode=$(stat -c '%d:%i' "$first_log")
check test "$first_inode" != "$second_inode"
! grep -q OLD_AV_MARKER "$first_log" || fail stale-av-log-content
check test "$(stat -c %a "$first_log")" = 600
if pxeos_av_diag_reference >/dev/null; then fail empty-task-log-reference; fi

# Main scan fixture: success and native failure both publish and clean raw;
# raw-missing aborts before the scan native is invoked.
scan_called=no
scan_native_rc=0
clamscan() {
    scan_called=yes
    printf 'clean\nEICAR FOUND token=scan-secret\n' >"$scan_log"
    return "$scan_native_rc"
}
fixture_error=''
handleError() { fixture_error=$1; return 0; }
fixture_scan_main() {
    local scan_rc
    if ! pxeos_av_scan_prepare; then
        fixture_umount=yes
        return 125
    fi
    scan_log=$pxeos_av_scan_log
    clamscan -r --tempdir="$tmp/scan-tmp" "$action" --log=$scan_log --no-summary --exclude-dir="$tmp/scan-exclude"
    scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        pxeos_av_diag_finish "$pxeos_av_scan_log" "av_scan:exit=$scan_rc" >/dev/null || true
        return "$scan_rc"
    fi
    fixture_found=$(pxeos_av_found_lines "$scan_log")
    pxeos_av_diag_finish "$pxeos_av_scan_log" av_scan:exit=0 >/dev/null || true
}
action=''
fixture_umount=no; scan_called=no; scan_native_rc=0
fixture_scan_main
check test "$scan_called" = yes
check test "$fixture_found" = 'EICAR FOUND token=scan-secret'
check grep -q '^OP=av_scan:exit=0$' "$first_log"
check test "$(pxeos_av_diag_reference)" = " Diagnostic log: $first_log"
check test "$(find "$tmp/log" -name '.raw.*' -print | wc -l)" = 0
fixture_umount=no; scan_called=no; scan_native_rc=23
rc=0; fixture_scan_main || rc=$?
check test "$scan_called" = yes
check test "$rc" = 23
check grep -q '^OP=av_scan:exit=23$' "$first_log"
check test "$(find "$tmp/log" -name '.raw.*' -print | wc -l)" = 0
rootpxe_log_raw_file() { return 1; }
fixture_error=''; fixture_umount=no; scan_called=no; scan_native_rc=0
rc=0; fixture_scan_main || rc=$?
check test "$rc" = 125
check test "$fixture_umount" = yes
check test "$scan_called" = no
check grep -q 'Unable to prepare ClamAV diagnostic log' <<<"$fixture_error"
! grep -q 'Diagnostic log:' <<<"$fixture_error" || fail rawmissing-fake-reference
check test "$(find "$tmp/log" -name '.raw.*' -print | wc -l)" = 0

# A failed publish must not make an otherwise valid leftover fixed file look
# like the latest saved diagnostic.
unset -f rootpxe_log_raw_file rootpxe_log_publish
. <(sed "s|/tmp/log|$tmp/log|g" "$lib/log-paths.sh")
rootpxe_log_publish() { return 1; }
native_rc=0; native_called=no
pxeos_av_run_logged av_publish_failure native 2>"$tmp/publish-failure-latest"
check test "$native_called" = yes
check test "$pxeos_av_log_published" = no
check test -f "$first_log"
if pxeos_av_diag_reference >/dev/null; then fail reference-on-publish-failure; fi

printf 'Fixed AV log: PASS\n'
