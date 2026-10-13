#!/usr/bin/env bash
# Marker-only cleanup; no VG, payload or block-device operation is executed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-lvm-child-trap.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
rootpxe_task_log_initialize
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for kind in return exit; do
    for expected in 0 7; do
        marker="$tmp/cleanup-$kind-$expected"
        (
            trap 'printf "OUTER_CLEANUP\n" >>"$marker"' EXIT HUP INT TERM
            before=$(trap -p EXIT HUP INT TERM)
            pvs(){ printf 'QUERY_JSON\n'; if [[ $kind == exit ]]; then exit "$expected"; fi; return "$expected"; }
            rc=0; rootpxe_lvm_native pvs >"$tmp/native-$kind-$expected" || rc=$?
            [[ $rc == "$expected" ]] || fail child-rc
            [[ $(trap -p EXIT HUP INT TERM) == "$before" ]] || fail parent-trap-changed
            [[ ! -e $marker ]] || fail premature-outer-cleanup
            rootpxe_task_log_valid || fail parent-pin-invalid
        )
        [[ $(wc -l <"$marker") == 1 ]] || fail parent-cleanup-count
    done
done
printf 'LVM child trap: PASS\n'
