#!/usr/bin/env bash
# Offline regression for the official Partclone text-mode stderr adapter.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/partclone-progress.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
. <(sed "s|/tmp/log|$tmp/log|g" "$(dirname "$lib")/log-paths.sh")

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

# Snapshot persistence is only telemetry: a write error must not turn a
# successful Partclone reader/producer/writer pipeline into a failed task.
ROOTPXE_PROGRESS_STATUS_FILE="$tmp/missing/status.pxeos"
if ! rootpxe_partclone_progress_write 99 partclone_progress; then
    fail 'telemetry status-file write must be best effort'
fi
pass 'telemetry write failure does not fail the imaging pipeline'

# A disappeared console must not stop draining Partclone stderr: returning
# early would back-pressure the producer and falsely fail the capture.
ROOTPXE_PROGRESS_STATUS_FILE="$tmp/console-failure.status"
rootpxe_partclone_progress_initialize
console_run=$rootpxe_partclone_progress_run_id
console_fifo="$tmp/console-failure.fifo"
mkfifo "$console_fifo"
( printf 'Elapsed: 00:00:03, Remaining: 00:00:04, Completed:  42.50%%,   1.00MB/s,\r' >"$console_fifo" ) &
console_writer=$!
rootpxe_partclone_progress_decode "$console_fifo" 2>/dev/full || fail 'decoder must continue when console stderr is unavailable'
wait "$console_writer" || fail 'console-failure fixture writer was back-pressured'
assert_eq "$(rootpxe_partclone_progress_next_pct "$ROOTPXE_PROGRESS_STATUS_FILE" "$console_run" 0)" 42 'decoder must retain samples after console failure'
pass 'console failure remains a non-blocking telemetry fault'

# Text statistics stay private, while a failed sink cannot stop FIFO drainage.
rootpxe_task_log_append() { printf '%s\n' "$*" >>"$tmp/diagnostic"; return "${LOG_SINK_RC:-0}"; }
eval "$(sed -n '/^rootpxe_utf8_safe_prefix() {/,/^}/p' "${lib%/*}/funcs.sh")"
eval "$(sed -n '/^rootpxe_utf8_safe_tail() {/,/^}/p' "${lib%/*}/funcs.sh")"
eval "$(sed -n '/^rootpxe_redact_diagnostic() {/,/^}/p' "${lib%/*}/funcs.sh")"
mkfifo "$tmp/log-failure.fifo"
( printf 'Filesystem statistics: blocks files UUID\nFatal native detail\nElapsed: 00:00:01, Remaining: 00:00:00, Completed:  61.00%%, Rate: 1.00MB/s,\r' >"$tmp/log-failure.fifo" ) &
log_writer=$!
LOG_SINK_RC=1 rootpxe_partclone_progress_decode "$tmp/log-failure.fifo" 2>"$tmp/text-console" || fail failed-log-sink-changed-decoder-status
wait "$log_writer" || fail failed-log-sink-backpressured-writer
grep -Fq 'Copy progress: 61%' "$tmp/text-console" || fail concise-progress-missing
! grep -Eq 'Filesystem statistics|Fatal native detail|Rate:|Elapsed:' "$tmp/text-console" || fail text-console-noise-leaked
grep -Fq 'Fatal native detail' "$tmp/diagnostic" || fail text-diagnostic-not-retained
grep -Fq 'Task log: unavailable' "$tmp/text-console" || fail failed-log-sink-location-missing
pass 'text is concise and a failed log sink still drains diagnostics'
mkfifo "$tmp/tail.fifo"
( for ((i=0;i<70;i++)); do printf '%01000d\n' 0; done; printf 'LAST_PARTCLONE_ERROR\n' ) >"$tmp/tail.fifo" &
tail_writer=$!
rootpxe_partclone_progress_decode "$tmp/tail.fifo" 2>"$tmp/tail-console" || fail tail-decoder-status
wait "$tail_writer" || fail tail-writer-status
grep -Fq LAST_PARTCLONE_ERROR "$tmp/diagnostic" || fail tail-error-not-retained
grep -Fq TRUNCATED "$tmp/diagnostic" || fail tail-truncation-marker-missing
pass 'bounded Partclone diagnostics retain the last failure'
mkfifo "$tmp/secret.fifo"
( printf 'token="'; printf '%070000d' 0; printf 'SECRET_TAIL"\nLAST_SECRET_ERROR\n'; ) >"$tmp/secret.fifo" &
secret_writer=$!
rootpxe_partclone_progress_decode "$tmp/secret.fifo" 2>"$tmp/secret-console" || fail secret-decoder-status
wait "$secret_writer" || fail secret-writer-status
! grep -q SECRET_TAIL "$tmp/diagnostic" || fail sliced-secret-leaked
grep -q LAST_SECRET_ERROR "$tmp/diagnostic" || fail last-secret-error-lost
mkfifo "$tmp/utf8.fifo"
( printf '中%.0s' {1..2000}; printf '\nLAST_UTF8_ERROR\n' ) >"$tmp/utf8.fifo" &
utf8_writer=$!
rootpxe_partclone_progress_decode "$tmp/utf8.fifo" 2>"$tmp/utf8-console" || fail utf8-decoder-status
wait "$utf8_writer" || fail utf8-writer-status
! grep -q '^中' "$tmp/diagnostic" || fail overlong-utf8-line-not-omitted
grep -Fq 'overlong Partclone diagnostic omitted' "$tmp/diagnostic" || fail utf8-omission-marker-missing
grep -Fq LAST_UTF8_ERROR "$tmp/diagnostic" || fail last-utf8-error-missing
pass 'overlong UTF-8 text lines are safely omitted and the last error remains'

printf 'PASS: Partclone official progress regression\n'
