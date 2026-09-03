#!/usr/bin/env bash
# Offline regression for the official Partclone text-mode stderr adapter.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/partclone-progress.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got=$1 expected=$2)"; }

export ROOTPXE_PROGRESS_STATUS_FILE="$tmp/status.pxeos"
# shellcheck source=/dev/null
. "$lib"

rootpxe_partclone_progress_initialize
run=$rootpxe_partclone_progress_run_id
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 77)" 0 'run initialization must explicitly reset progress'

# The historical wrapper accepts an omitted FIFO path.  Under nounset it must
# retain that optional-call contract, and abort must clean only its own reader.
rootpxe_partclone_progress_start
[[ -p ${rootpxe_partclone_progress_fifo:-} ]] || fail 'default progress FIFO was not prepared'
rootpxe_partclone_progress_abort || fail 'default progress FIFO cleanup failed'
pass 'optional progress FIFO path remains supported'

# The official IO form is split by CR and contains ANSI cursor control in its
# second row.  Only its Completed field is copy progress.
fifo="$tmp/progress.fifo"
rootpxe_partclone_progress_start "$fifo"
printf '\033[2KElapsed: 00:00:03, Remaining: 00:00:04, Completed:  42.50%%,   1.00MB/s,\rCurrent block:        123, Total block:       1000, Complete:  12.30%%\033[A\r' >"$fifo"
rootpxe_partclone_progress_wait || fail 'official IO decoder failed'
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 42 'IO Completed percentage must be sampled across CR/ANSI fragments'
pass 'official IO sample is parsed'

# Keep the writer open after its first CR-terminated update.  The reporter
# must see that update before EOF; a block-buffered `tr` adapter would fail.
rootpxe_partclone_progress_start "$fifo"
( printf 'Elapsed: 00:00:05, Remaining: 00:00:05, Completed:  55.00%%,   1.00MB/s,\r'; sleep 2 ) >"$fifo" &
writer_pid=$!
live_pct=0
for _ in {1..10}; do
    live_pct=$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)
    [[ $live_pct == 55 ]] && break
    sleep 0.1
done
assert_eq "$live_pct" 55 'progress must publish before the stderr writer closes'
kill -0 "$writer_pid" 2>/dev/null || fail 'live progress writer closed before the assertion'
wait "$writer_pid"
rootpxe_partclone_progress_wait || fail 'asynchronous IO decoder failed'
pass 'official IO progress is live before EOF'

# Bitmap output also says Completed, but has neither the data speed form nor
# Rate.  It must not replace the copied-data percentage.
rootpxe_partclone_progress_start "$fifo"
printf 'Elapsed: 00:00:04, Remaining: 00:00:03, Completed:  99.00%%\r' >"$fifo"
rootpxe_partclone_progress_wait || fail 'bitmap decoder failed'
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 42)" 0 'new operation must be explicit zero until a data sample arrives'
pass 'bitmap progress is ignored'

# Official done output changes the speed label to Rate and permits 100.  The
# caller still owns success through its producer/writer exit codes.
rootpxe_partclone_progress_start "$fifo"
printf 'Elapsed: 00:00:10, Remaining: 00:00:00, Completed: 100.00%%, Rate:   2.00MB/s,\rCurrent block:       1000, Total block:       1000, Complete: 100.00%%\r' >"$fifo"
rootpxe_partclone_progress_wait || fail 'final decoder failed'
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 0)" 100 'official done Rate form must publish 100'
pass 'official done sample is parsed'

# An empty/truncated read never resets a reporter's last known value, while a
# fresh task/run cannot consume an old retry's record.
: >"$ROOTPXE_PROGRESS_STATUS_FILE"
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 100)" 100 'no new status must retain reporter progress'
printf 'PXEOS_PROGRESS_V1|old-run|9|12|partclone_progress\n' >"$ROOTPXE_PROGRESS_STATUS_FILE"
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$run" 100)" 100 'foreign run must not leak retry progress'
pass 'empty and stale status are isolated'

# Partimage remains on its historical stderr file format.  Its percentage is
# read independently and cannot be mistaken for a Partclone V1 record.
printf 'Partimage status: 73.50%%\ntrailer\n' >"$ROOTPXE_PROGRESS_STATUS_FILE"
assert_eq "$(rootpxe_partimage_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" 0)" 73 'legacy Partimage percentage must remain readable'
: >"$ROOTPXE_PROGRESS_STATUS_FILE"
assert_eq "$(rootpxe_partimage_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" 73)" 73 'empty Partimage sample must retain progress'
pass 'legacy Partimage progress remains separate'

printf 'PASS: Partclone official progress regression\n'
