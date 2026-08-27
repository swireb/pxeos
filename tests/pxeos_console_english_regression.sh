#!/usr/bin/env bash
# Static console-output contract; it neither boots PXEOS nor touches disks or network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
runtime_files=(
    "$overlay/bin/pxeos.checkin"
    "$overlay/bin/pxeos.download"
    "$overlay/etc/init.d/S99pxeos"
    "$overlay/usr/share/pxeos/lib/funcs.sh"
)

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 is missing expected console output: $2"; }

# Check static echo source lines only. Dynamic variables are deliberately out
# of scope: their contents are server-provided and cannot be proven ASCII here.
set +e
LC_ALL=C awk '
    /^[[:space:]]*#/ { next }
    /echo/ && /[^ -~\t]/ { print FILENAME ":" FNR ":" $0; invalid = 1 }
    END { exit invalid ? 1 : 0 }
' "${runtime_files[@]}"
scan_status=$?
set -e
case "$scan_status" in
    0) ;;
    1) fail 'static runtime echo output must use ASCII text' ;;
    *) fail "console output scanner failed (exit $scan_status)" ;;
esac

must_have "$overlay/bin/pxeos.checkin" 'Check-in not confirmed; SSH is available. Retrying in 5 seconds.'
must_have "$overlay/bin/pxeos.checkin" 'Task aborted or withdrawn; stopping PXEOS.'
must_have "$overlay/bin/pxeos.download" 'Task aborted or deleted; stopping PXEOS.'
must_have "$overlay/etc/init.d/S99pxeos" 'SSH is available; running configured failure action: $failure_action'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Disk permission not confirmed; SSH is available. Retrying in 5 seconds.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Error report failed; SSH is available. Retrying in 5 seconds.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Error report not confirmed; SSH is available. Retrying in 5 seconds.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Error reported; task needs attention. SSH is available. Select Retry in the UI to resume.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Wait timed out; running configured action: $action'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Retry requested; resuming original task.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Task deleted or aborted; stopping PXEOS.'

echo 'PASS: PXEOS runtime console output is English'
