#!/usr/bin/env bash
# Offline VCS/VCSA snapshots only: no TTY, disk, PXE, or network is used.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/partclone-progress.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got=$1 expected=$2)"; }

export ROOTPXE_PROGRESS_STATUS_FILE="$tmp/status.pxeos"
export ROOTPXE_PARTCLONE_VT_DEV_ROOT="$tmp/dev"
export ROOTPXE_PARTCLONE_VT_TEST_ALLOW_REGULAR=yes
export ROOTPXE_PARTCLONE_VT_TERMINFO_ROOTS="$tmp/terminfo"
mkdir -p "$ROOTPXE_PARTCLONE_VT_DEV_ROOT"
mkdir -p "$ROOTPXE_PARTCLONE_VT_TERMINFO_ROOTS/l"
: >"$ROOTPXE_PARTCLONE_VT_TERMINFO_ROOTS/l/linux"

# Linux VCS exposes glyph bytes, not UTF-8.  CP437 vertical borders exercise
# byte-oriented row slicing while the percent begins at official column 52.
row() { printf '\263%-78s\263' "$1"; }
progress_row() { printf '\263%50s%-28s\263' '' "$1"; }
snapshot() {
    # vcsa: rows, columns, cursor-x, cursor-y. vcs is cells only.
    printf '\030\120\000\000' >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcsa7"
    snapshot_vcs "$1" "$2"
}
snapshot_vcs() {
    {
        row ''; row ''
        row "$1"; progress_row "$2"
        for _ in $(seq 5 24); do row ''; done
    } >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcs7"
}
bitmap_snapshot() {
    printf '\030\120\000\000' >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcsa7"
    {
        row ''; row ''
        row 'Calculating Bitmap Process:'; progress_row '100.00%'
        row ''
        row 'Total Block Process:'; progress_row '100.00%'
        for _ in $(seq 8 24); do row ''; done
    } >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcs7"
}
: >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/tty7"
# shellcheck source=/dev/null
. "$lib"

clear_called=no
rootpxe_partclone_vt_clear_target() {
    clear_called=yes
    snapshot '' ''
}

# The previous operation's completed screen must be cleared before this
# operation's observer starts.  The fixture uses a clear stub because writes
# to a regular fake tty cannot alter its separate fake vcs device.
snapshot 'Data Block Process:' '100.00%'
# Resolve the caller's fd2 through a fake proc tree without the test-only
# FD2_TARGET override.  This protects against resolving readlink's /dev/null.
export ROOTPXE_PARTCLONE_PROC_ROOT="$tmp/proc"
caller_pid=$BASHPID
readlink() {
    [[ $1 == "$ROOTPXE_PARTCLONE_PROC_ROOT/$caller_pid/fd/2" ]] || return 1
    printf '/dev/tty7\n'
}
unset ROOTPXE_PARTCLONE_FD2_TARGET
rootpxe_partclone_progress_initialize
rootpxe_partclone_progress_prepare "$tmp/caller-fd.fifo" || fail 'caller-fd VT prepare failed'
assert_eq "$rootpxe_partclone_progress_mode" gui 'caller fd2 target must choose GUI without override'
rootpxe_partclone_progress_abort || fail 'caller-fd GUI cleanup failed'
unset -f readlink
unset ROOTPXE_PARTCLONE_PROC_ROOT

export ROOTPXE_PARTCLONE_FD2_TARGET=/dev/tty7
rootpxe_partclone_progress_initialize
run=$rootpxe_partclone_progress_run_id
rootpxe_partclone_progress_prepare "$tmp/progress.fifo" || fail 'VT prepare failed'
assert_eq "$rootpxe_partclone_progress_mode" gui 'numeric VT must choose official GUI mode'
assert_eq "${rootpxe_partclone_progress_args[*]}" -N 'GUI call must receive official -N'
assert_eq "$rootpxe_partclone_progress_stderr_target" "$ROOTPXE_PARTCLONE_VT_DEV_ROOT/tty7" 'GUI stderr must remain bound to fd2 VT'
assert_eq "$rootpxe_partclone_progress_term" linux 'GUI must force TERM=linux'
assert_eq "$clear_called" yes 'GUI prepare must clear its selected VT before sampling'
rootpxe_partclone_progress_start_collector
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 100)" 0 'cleared old 100 must not leak into the new operation'
rootpxe_partclone_progress_wait || fail 'cleared-screen observer wait failed'

# A data-block sample written after prepare belongs to this generation.
rootpxe_partclone_progress_prepare "$tmp/progress.fifo" || fail 'VT prepare failed'
snapshot 'Data Block Process:' '42.50%'
rootpxe_partclone_progress_start_collector
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 42 'Data Block Process next row must update progress'
rootpxe_partclone_progress_wait || fail 'GUI observer wait failed'

# A fresh generation clears a previous 100; bitmap and total-block screens
# may not turn it back into copy progress.
rootpxe_partclone_progress_prepare "$tmp/progress.fifo" || fail 'bitmap prepare failed'
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 100)" 0 'new operation must clear prior 100 before GUI data arrives'
bitmap_snapshot
rootpxe_partclone_progress_start_collector
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 0 'bitmap/total screen must not be sampled'
rootpxe_partclone_progress_wait || fail 'bitmap observer wait failed'

# Only a single valid percentage on the Data Block row is accepted.
rootpxe_partclone_progress_prepare "$tmp/invalid-pct.fifo" || fail 'invalid-pct prepare failed'
snapshot 'Data Block Process:' '142.00%'
rootpxe_partclone_progress_start_collector
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 0 '142 percent must not yield a suffix progress value'
rootpxe_partclone_progress_wait || fail 'invalid-pct observer wait failed'
rootpxe_partclone_progress_prepare "$tmp/invalid-pct.fifo" || fail 'invalid-pct prepare failed'
snapshot 'Data Block Process:' '1000.00%'
rootpxe_partclone_progress_start_collector
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 0 '1000 percent must not yield a suffix progress value'
rootpxe_partclone_progress_wait || fail 'invalid-pct observer wait failed'

# A transient short VCS read or an invalid resize never reports progress, and
# the same observer resumes when a complete, valid snapshot returns.
rootpxe_partclone_progress_prepare "$tmp/transient.fifo" || fail 'transient prepare failed'
rootpxe_partclone_progress_start_collector
: >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcs7"
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 0 'short VCS snapshot must not report progress'
printf '\026\120\000\000' >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcsa7"
snapshot_vcs 'Data Block Process:' '42.50%'
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 0 'invalid VCSA dimensions must not report progress'
printf '\030\120\000\000' >"$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcsa7"
sleep 0.7
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 42 'observer must resume after a complete valid snapshot'
rootpxe_partclone_progress_wait || fail 'transient observer wait failed'

# A data row containing more than one percentage is not an official progress
# row and must not select either value.
rootpxe_partclone_progress_prepare "$tmp/duplicate-pct.fifo" || fail 'duplicate-pct prepare failed'
snapshot 'Data Block Process:' '42.00% 43.00%'
rootpxe_partclone_progress_start_collector
sleep 0.2
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 0 'multiple percentages must be rejected'
rootpxe_partclone_progress_wait || fail 'duplicate-pct observer wait failed'

# /dev/console is eligible only when both kernel active files name the same
# numeric VT.  A serial console indication must remain in text mode.
printf 'tty7\n' >"$tmp/tty0-active"
printf 'tty7\n' >"$tmp/console-active"
export ROOTPXE_PARTCLONE_VT_ACTIVE_FILE="$tmp/tty0-active"
export ROOTPXE_PARTCLONE_VT_CONSOLE_ACTIVE_FILE="$tmp/console-active"
export ROOTPXE_PARTCLONE_FD2_TARGET=/dev/console
rootpxe_partclone_progress_prepare "$tmp/console.fifo" || fail 'console VT prepare failed'
assert_eq "$rootpxe_partclone_progress_mode" gui 'matching console active VT must choose GUI'
assert_eq "$rootpxe_partclone_progress_stderr_target" "$ROOTPXE_PARTCLONE_VT_DEV_ROOT/tty7" 'console must bind the resolved numeric VT'
rootpxe_partclone_progress_abort || fail 'console GUI cleanup failed'
printf 'ttyS0\n' >"$tmp/console-active"
rootpxe_partclone_progress_prepare "$tmp/serial.fifo" || fail 'serial fallback prepare failed'
assert_eq "$rootpxe_partclone_progress_mode" text 'serial console must not select a VT'
rootpxe_partclone_progress_abort || fail 'serial fallback cleanup failed'
unset ROOTPXE_PARTCLONE_VT_ACTIVE_FILE ROOTPXE_PARTCLONE_VT_CONSOLE_ACTIVE_FILE

# A VCS device read failure is surfaced by wait; it cannot be mistaken for a
# successful clone outcome by the caller.
export ROOTPXE_PARTCLONE_FD2_TARGET=/dev/tty7
snapshot '' ''
rootpxe_partclone_progress_prepare "$tmp/read-failure.fifo" || fail 'read-failure prepare failed'
rootpxe_partclone_progress_start_collector
rm -f "$ROOTPXE_PARTCLONE_VT_DEV_ROOT/vcs7"
sleep 0.2
if rootpxe_partclone_progress_wait; then
    fail 'VCS observer read failure must propagate'
fi
snapshot '' ''

# An unbound non-VT fd never receives -N and retains the current text adapter.
export ROOTPXE_PARTCLONE_FD2_TARGET=/dev/pts/7
rootpxe_partclone_progress_prepare "$tmp/text.fifo" || fail 'text fallback prepare failed'
assert_eq "$rootpxe_partclone_progress_mode" text 'pts must fall back to text mode'
assert_eq "${#rootpxe_partclone_progress_args[@]}" 0 'text fallback must not pass -N'
assert_eq "$rootpxe_partclone_progress_stderr_target" "$tmp/text.fifo" 'text fallback must feed its existing decoder FIFO'
rootpxe_partclone_progress_abort || fail 'text fallback cleanup failed'

printf 'PASS: PXEOS official ncurses VT progress regression\n'
