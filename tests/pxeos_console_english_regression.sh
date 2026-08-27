#!/usr/bin/env bash
# Static fixed-console-message contract; it neither boots PXEOS nor touches disks or network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
runtime_files=(
    "$overlay/bin/pxeos.checkin"
    "$overlay/bin/pxeos.download"
    "$overlay/etc/init.d/S99pxeos"
    "$overlay/usr/share/pxeos/lib/funcs.sh"
)

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 is missing expected console output: $2"; }
must_not_have() { ! grep -Fq -- "$2" "$1" || fail "$1 contains obsolete console output: $2"; }
must_fit() { [[ ${#1} -le 80 ]] || fail "console line exceeds 80 columns: $1"; }

# Check fixed echo/printf source lines only. Dynamic variable contents are out
# of scope: this contract verifies static messages, not arbitrary runtime data.
set +e
LC_ALL=C awk '
    /^[[:space:]]*#/ { next }
    {
        if (printf_block) {
            if ($0 ~ /[^ -~\t]/) { print FILENAME ":" FNR ":" $0; invalid = 1 }
            if ($0 !~ /\\[[:space:]]*$/) { printf_block = 0 }
            next
        }
        if ($0 ~ /echo|printf[[:space:]]/) {
            if ($0 ~ /[^ -~\t]/) { print FILENAME ":" FNR ":" $0; invalid = 1 }
            if ($0 ~ /printf[[:space:]].*\\[[:space:]]*$/) { printf_block = 1 }
        }
    }
    END { exit invalid ? 1 : 0 }
' "${runtime_files[@]}"
scan_status=$?
set -e
case "$scan_status" in
    0) ;;
    1) fail 'static fixed console messages must use ASCII text' ;;
    *) fail "console output scanner failed (exit $scan_status)" ;;
esac

# Extract only the three display helpers.  The mocks below prove that a
# no-newline dots() progress row is terminated before both handlers render;
# no PXEOS top-level code, disk command, network request, or real wait runs.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^dots\(\)/ { copy = 1 } /^# Enables write caching/ { exit } copy' "$funcs" >"$tmp/dots.sh"
awk '/^handleError\(\)/ { copy = 1 } /^# Re-reads the partition table/ { exit } copy' "$funcs" >"$tmp/handlers.sh"

set +e
(
    initversion=test-init
    isdebug=""
    cat() { [[ $1 == /proc/cmdline ]] && { printf 'mock_cmdline=1\n'; return; }; command cat "$@"; }
    rootpxe_require_task_context() { return 1; }
    rootpxe_error_wait_for_retry() { printf 'unexpected retry callback\n' >&2; return 99; }
    usleep() { printf 'usleep:%s\n' "$1"; }
    debugPause() { printf 'debug-pause\n'; }
    . "$tmp/dots.sh"
    . "$tmp/handlers.sh"
    dots 'Mounting File System'
    handleError $'Mock failure details\nMock failure detail line two' ''
) >"$tmp/error.out" 2>&1
error_status=$?
set -e
[[ $error_status -eq 1 ]] || fail "handleError exit policy changed: $error_status"
[[ $(sed -n '2p' "$tmp/error.out") == '[ERROR] Operation failed.' ]] || fail 'handleError must start on a new ERROR line after dots'
grep -Fqx '[INFO]  Init version: test-init' "$tmp/error.out" || fail 'handleError init version format'
grep -Fqx '[INFO]  Error details:' "$tmp/error.out" || fail 'handleError error-details section'
grep -Fqx '        Mock failure details' "$tmp/error.out" || fail 'handleError must preserve and indent error detail'
grep -Fqx '        Mock failure detail line two' "$tmp/error.out" || fail 'handleError must preserve multiline error detail'
awk '
    $0 == "        Mock failure detail line two" {
        getline
        if ($0 != "") exit 1
        getline
        if ($0 != "[INFO]  Kernel variables and settings:") exit 1
        found = 1
    }
    END { exit found ? 0 : 1 }
' "$tmp/error.out" || fail 'handleError must separate error details from kernel diagnostics'
grep -Fqx '[INFO]  Kernel variables and settings:' "$tmp/error.out" || fail 'handleError diagnostics section'
grep -Fqx '        mock_cmdline=1' "$tmp/error.out" || fail 'handleError must preserve and indent cmdline diagnostics'
grep -Fqx '[WARN]  System will reboot in 60s.' "$tmp/error.out" || fail 'handleError reboot notice'
grep -Fqx 'usleep:60000000' "$tmp/error.out" || fail 'handleError retry wait changed'
! grep -Fq '###' "$tmp/error.out" || fail 'handleError must not render hash decoration'

set +e
(
    initversion=test-init
    isdebug=""
    cat() { [[ $1 == /proc/cmdline ]] && { printf 'mock_cmdline=1\n'; return; }; command cat "$@"; }
    rootpxe_require_task_context() { return 0; }
    rootpxe_error_wait_for_retry() { printf 'retry-callback:%s:%s\n' "$1" "$2"; return 2; }
    usleep() { printf 'unexpected-usleep:%s\n' "$1"; }
    debugPause() { printf 'unexpected-debug-pause\n'; }
    . "$tmp/dots.sh"
    . "$tmp/handlers.sh"
    handleError 'Mock task failure' ''
) >"$tmp/task-context.out" 2>&1
task_context_status=$?
set -e
[[ $task_context_status -eq 2 ]] || fail "handleError task-context exit policy changed: $task_context_status"
grep -Fqx 'retry-callback:Mock task failure:PXEOS_ERROR' "$tmp/task-context.out" || fail 'handleError retry callback contract'
! grep -Fq 'unexpected-usleep' "$tmp/task-context.out" || fail 'handleError task context must not enter fallback wait'

(
    usleep() { printf 'usleep:%s\n' "$1"; }
    debugPause() { printf 'debug-pause\n'; }
    . "$tmp/dots.sh"
    . "$tmp/handlers.sh"
    dots 'Mounting File System'
    handleWarning 'Mock warning details'
) >"$tmp/warning.out" 2>&1
[[ $(sed -n '2p' "$tmp/warning.out") == '[WARN]  Operation warning.' ]] || fail 'handleWarning must start on a new WARN line after dots'
grep -Fqx '[INFO]  Warning details:' "$tmp/warning.out" || fail 'handleWarning details section'
grep -Fqx '        Mock warning details' "$tmp/warning.out" || fail 'handleWarning must preserve and indent warning detail'
grep -Fqx '[INFO]  Continuing in 60s.' "$tmp/warning.out" || fail 'handleWarning continuation notice'
grep -Fqx 'usleep:60000000' "$tmp/warning.out" || fail 'handleWarning wait changed'
grep -Fqx 'debug-pause' "$tmp/warning.out" || fail 'handleWarning debug pause changed'
! grep -Fq '###' "$tmp/warning.out" || fail 'handleWarning must not render hash decoration'

must_have "$overlay/bin/pxeos.checkin" '[WARN]  Check-in not confirmed. Retrying in 5s.'
must_have "$overlay/bin/pxeos.checkin" '[INFO]  SSH is available for troubleshooting.'
must_have "$overlay/bin/pxeos.checkin" '[INFO]  Task aborted or withdrawn. Stopping PXEOS.'
must_have "$overlay/bin/pxeos.checkin" '[INFO]  Checking in with RootPXE.'
must_have "$overlay/bin/pxeos.checkin" "printf '[INFO]  %s\\n' \"\$waitMsg\""
must_have "$overlay/bin/pxeos.checkin" "printf '[INFO]  Retrying in %ss.\\n' \"\$retryAfterSec\""
must_have "$overlay/bin/pxeos.checkin" '[INFO]  Check-in completed.'
must_not_have "$overlay/bin/pxeos.checkin" 'dots "Check in (RootPXE)"'
must_not_have "$overlay/bin/pxeos.checkin" 'dots "$waitMsg"'
must_not_have "$overlay/bin/pxeos.checkin" 'echo "Done"'
must_have "$overlay/bin/pxeos.download" '[INFO]  Task aborted or deleted. Stopping PXEOS.'
must_have "$overlay/etc/init.d/S99pxeos" '[INFO]  Task completed. Powering off.'
must_have "$overlay/etc/init.d/S99pxeos" '[INFO]  Task completed. Rebooting.'
must_have "$overlay/etc/init.d/S99pxeos" '[WARN]  Task exited with code: $rc.'
must_have "$overlay/etc/init.d/S99pxeos" '[INFO]  Running configured failure action: $failure_action.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Disk permission not confirmed. Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Error report failed. Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Error report not confirmed. Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[ERROR] Task paused. Error reported to RootPXE.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[INFO]  Select Retry in the web UI to resume.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[INFO]  Timeout: ${wait}s. Timeout action: $action.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Wait timed out. Timeout action: $action.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[INFO]  Retry requested. Resuming task.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[INFO]  Task deleted or aborted. Stopping PXEOS.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[ERROR] Operation failed.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Operation warning.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  System will reboot in 60s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[INFO]  Continuing in 60s.'

for line in \
    '[WARN]  Check-in not confirmed. Retrying in 5s.' \
    '[INFO]  Checking in with RootPXE.' \
    '[INFO]  Retrying in 999s.' \
    '[INFO]  Check-in completed.' \
    '[INFO]  SSH is available for troubleshooting.' \
    '[INFO]  Task aborted or withdrawn. Stopping PXEOS.' \
    '[INFO]  Task aborted or deleted. Stopping PXEOS.' \
    '[INFO]  Task completed. Powering off.' \
    '[INFO]  Task completed. Rebooting.' \
    '[WARN]  Task exited with code: 255.' \
    '[INFO]  Running configured failure action: shutdown.' \
    '[WARN]  Disk permission not confirmed. Retrying in 5s.' \
    '[WARN]  Error report failed. Retrying in 5s.' \
    '[WARN]  Error report not confirmed. Retrying in 5s.' \
    '[ERROR] Task paused. Error reported to RootPXE.' \
    '[ERROR] Operation failed.' \
    '[WARN]  Operation warning.' \
    '[INFO]  Init version: test-init' \
    '[WARN]  System will reboot in 60s.' \
    '[INFO]  Continuing in 60s.' \
    '[INFO]  Select Retry in the web UI to resume.' \
    '[INFO]  Timeout: 3600s. Timeout action: shutdown.' \
    '[WARN]  Wait timed out. Timeout action: shutdown.' \
    '[INFO]  Retry requested. Resuming task.' \
    '[INFO]  Task deleted or aborted. Stopping PXEOS.'; do
    must_fit "$line"
done

if [[ ${PXEOS_CONSOLE_TEST_SHOW_SAMPLE:-} == 1 ]]; then
    printf '%s\n' 'SAMPLE: dots to error diagnostics'
    sed -n '1,12p' "$tmp/error.out"
fi

echo 'PASS: PXEOS fixed console messages are standardized ASCII'
