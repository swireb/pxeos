#!/usr/bin/env bash
# Only mock Partclone setup; no cloning tool, TTY, image or device is executed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-partclone-optional-log.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
. <(sed "s|/tmp/log|$tmp/log|g" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/log-paths.sh")
export ROOTPXE_PROGRESS_STATUS_FILE="$tmp/status"
. "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/partclone-progress.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rootpxe_partclone_vt_number_from_stderr(){ return 1; }
rootpxe_log_raw_file(){ return 1; }
rc=0; rootpxe_partclone_progress_prepare "$tmp/progress.fifo" >"$tmp/notice" 2>&1 || rc=$?
[[ $rc == 0 ]] || fail optional-raw-prevented-clone
[[ ${rootpxe_partclone_progress_args[*]} == '-L /dev/null' ]] || fail fallback-argv
[[ -p $tmp/progress.fifo && $rootpxe_partclone_progress_mode == text ]] || fail lost-text-progress
grep -q unavailable "$tmp/notice" || fail missing-notice
rootpxe_partclone_progress_abort
[[ ! -e $tmp/progress.fifo ]] || fail fifo-cleanup
# A path returned by a mock allocator but with unreadable identity is not owned
# by Partclone and must not be removed merely because the path is populated.
printf SENTINEL >"$tmp/foreign"
rootpxe_log_raw_file(){ rootpxe_log_raw_path="$tmp/foreign"; }
real_stat=$(type -P stat)
stat(){ [[ $* != *"$tmp/foreign"* ]] || return 7; "$real_stat" "$@"; }
rc=0; rootpxe_partclone_progress_prepare "$tmp/identity.fifo" >"$tmp/identity-notice" 2>&1 || rc=$?
[[ $rc == 0 && ${rootpxe_partclone_progress_args[*]} == '-L /dev/null' ]] || fail identity-fallback
rootpxe_partclone_progress_abort
[[ $(cat "$tmp/foreign") == SENTINEL ]] || fail removed-unverified-raw
rootpxe_log_raw_file(){ return 1; }
rootpxe_partclone_vt_number_from_stderr(){ printf '7\n'; }
rootpxe_partclone_vt_device_is_usable(){ return 0; }
rootpxe_partclone_vt_linux_terminfo_available(){ return 0; }
rootpxe_partclone_vt_dimensions(){ printf '24 80\n'; }
rootpxe_partclone_vt_clear_target(){ return 0; }
rootpxe_partclone_progress_prepare "$tmp/gui.fifo" >"$tmp/gui-notice" 2>&1
[[ $rootpxe_partclone_progress_mode == gui && ${rootpxe_partclone_progress_args[*]} == '-N -L /dev/null' ]] || fail lost-gui-fallback
[[ ! -e $tmp/gui.fifo && $rootpxe_partclone_progress_term == linux ]] || fail changed-gui-routing
rootpxe_partclone_progress_abort
printf 'Partclone optional log: PASS\n'
