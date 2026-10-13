#!/usr/bin/env bash
# Only this test's private directory is substituted into production definitions.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
. "$root/tests/task-log-test-support.sh"
tmp=$(mktemp -d /tmp/pxeos-fixed-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f $lib/log-paths.sh ]] || fail missing-log-path-helper
sed "s|/tmp/log|$tmp/log|g" "$lib/log-paths.sh" >"$tmp/paths"
. "$tmp/paths"
task_log_test_load_helpers "$lib/funcs.sh"
checks=0
check(){ checks=$((checks+1)); "$@" || fail "$*"; }
rootpxe_task_log_initialize
log=$(rootpxe_task_log_path)
check test "$log" = "$tmp/log/pxeos-task.log"
check test "$(stat -c %a "$tmp/log")" = 700
check test "$(stat -c %a "$log")" = 600
rootpxe_task_log_append OLD_ATTEMPT
old_id=$(stat -c '%d:%i' "$log")
exec 8>>"$log"
rootpxe_task_log_initialize
check test "$(rootpxe_task_log_path)" = "$log"
check test "$(stat -c '%d:%i' "$log")" != "$old_id"
printf OLD_FD >&8
exec 8>&-
check bash -c '! grep -q OLD "$1"' _ "$log"
rootpxe_task_log_append NEW_ATTEMPT
. "$tmp/paths"
check grep -q NEW_ATTEMPT "$log"
# Replace the path after the locked FD check but before cap truncation.
# The old inode must be truncated; the new attempt must remain untouched.
real_wc=$(type -P wc)
wc() {
    if [[ $* == -c && ${replace_during_size:-no} == yes ]]; then
        # Model a pathname rollover independently of the cooperative log
        # directory lock; this proves the cap writes the opened old inode.
        replacement=$(umask 077; mktemp "$tmp/log/.race.XXXXXX")
        chmod 600 "$replacement"
        printf NEW_INODE_SENTINEL >"$replacement"
        command mv -f -T "$replacement" "$log"
        printf 4194304
    else "$real_wc" "$@"; fi
}
replace_during_size=yes
rootpxe_task_log_append OLD_COLLECTOR
replace_during_size=no
check test "$(cat "$log")" = NEW_INODE_SENTINEL
unset -f wc
rootpxe_task_log_initialize
# A stale process state cannot reopen and append to the new attempt.
rootpxe_task_log_state[identity]="$old_id:600"
rc=0; rootpxe_task_log_append STALE || rc=$?
check test "$rc" -ne 0
check bash -c '! grep -q STALE "$1"' _ "$log"
rootpxe_task_log_initialize
task_token=KNOWN_SECRET_ACROSS_BOUNDARY
printf -v noise '%065490d' 0
printf '%s token="%s"\nLAST_NATIVE_ERROR\n' "$noise" "$task_token" | rootpxe_task_log_stream native /dev/mock
check grep -q LAST_NATIVE_ERROR "$log"
check bash -c '! grep -q SECRET_ACROSS_BOUNDARY "$1"' _ "$log"
rootpxe_log_raw_file; raw=$rootpxe_log_raw_path
printf 'password="%ssecret-tail"\nLAST_TYPED_ERROR\n' "$noise" >"$raw"
rootpxe_log_publish ntfsresize.log "$raw" ntfs
check grep -q LAST_TYPED_ERROR "$tmp/log/ntfsresize.log"
check bash -c '! grep -q secret-tail "$1"' _ "$tmp/log/ntfsresize.log"
check grep -q TRUNCATED "$tmp/log/ntfsresize.log"
# A prior task's raw completion must not replace a current type log.
mkfifo "$tmp/release-stale"
( read -r release <"$tmp/release-stale"; rootpxe_log_publish ntfsresize.log "$raw" stale ) >"$tmp/stale.out" 2>&1 & stale=$!
rootpxe_task_log_initialize
rootpxe_log_new_file ntfsresize.log
printf CURRENT_TYPED >"$tmp/log/ntfsresize.log"
printf 'release\n' >"$tmp/release-stale"
rc=0; wait "$stale" || rc=$?
check test "$rc" -ne 0
check test "$(cat "$tmp/log/ntfsresize.log")" = CURRENT_TYPED
saved_snapshot=$(declare -f rootpxe_log_snapshot)
rootpxe_log_snapshot(){ [[ $1 != "$raw" ]] || return 7; }
rc=0; rootpxe_log_publish ntfsresize.log "$raw" read_failed yes || rc=$?
check test "$rc" -ne 0
eval "$saved_snapshot"
rm "$raw"
# At rename time a directory target must not receive the staging file.
real_mv=$(type -P mv)
mv(){ mkdir "$tmp/log/resize2fs.log"; "$real_mv" "$@"; }
rc=0; rootpxe_log_new_file resize2fs.log >"$tmp/rename.out" 2>&1 || rc=$?
check test "$rc" -ne 0
check test "$(find "$tmp/log/resize2fs.log" -type f | wc -l)" -eq 0
unset -f mv
rmdir "$tmp/log/resize2fs.log"
saved_stat=$(declare -f stat || true)
if [[ -n $saved_stat ]]; then eval "${saved_stat/stat ()/rootpxe_fixed_real_stat ()}"; else rootpxe_fixed_real_stat(){ command stat "$@"; }; fi
stat(){
    local result
    result=$(rootpxe_fixed_real_stat "$@") || return $?
    if [[ $* == *'%d:%i:%a'*" $tmp/log" ]]; then result=${result%:*}:755; fi
    printf '%s\n' "$result"
}
rc=0; rootpxe_task_log_initialize || rc=$?
check test "$rc" -ne 0
if [[ -n $saved_stat ]]; then eval "$saved_stat"; else unset -f stat; fi
unset -f rootpxe_fixed_real_stat
rootpxe_task_log_initialize
# This case checks unsafe directory shape, not Linux unlink semantics. NTFS
# cannot rename the directory while this test owns an open child file handle.
rootpxe_task_log_release_pin
mv "$tmp/log" "$tmp/saved"
printf sentinel >"$tmp/log"
rc=0; rootpxe_task_log_initialize || rc=$?
check test "$rc" -ne 0
check test "$(cat "$tmp/log")" = sentinel
rm "$tmp/log"; mv "$tmp/saved" "$tmp/log"
printf sentinel >"$tmp/other"
rm "$log"; ln -s "$tmp/other" "$log"
native_link=no; [[ ! -L $log ]] || native_link=yes
rc=0; rootpxe_task_log_initialize || rc=$?
if [[ $native_link == yes ]]; then check test "$rc" -ne 0; else printf 'NOTE: MSYS symlink copy cannot prove native symlink refusal.\n' >&2; fi
check test "$(cat "$tmp/other")" = sentinel
printf 'Fixed log: %s checks, 0 failures\n' "$checks"
