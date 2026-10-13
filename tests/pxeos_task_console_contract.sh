#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
failures=0; checks=0
assert(){ checks=$((checks+1)); "$@" || { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures+1)); }; }
before(){ local a b; a=$(grep -nF "$2" "$1" | head -n1 | cut -d: -f1); b=$(grep -nF "$3" "$1" | head -n1 | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]; }
for entry in pxeos.download pxeos.upload; do
    assert before "$overlay/bin/$entry" 'rootpxe_task_log_initialize' '. /bin/pxeos.checkin'
done
assert grep -Fq 'mount -t xfs -o rw,nouuid "/dev/$vg/$lv_name" "$xfs_mount"' "$funcs"
assert bash -c '! sed -n "/^handleError() {/,/^}/p" "$1" | grep -Eq "Error details:|Kernel variables and settings:"' _ "$funcs"
assert bash -c '! sed -n "/^rootpxe_partclone_progress_decode() {/,/^}/p" "$1" | grep -Fq "printf '\''%s'\'' \"\$char\" >&2"' _ "$overlay/usr/share/pxeos/lib/partclone-progress.sh"
for tool in pvcreate vgcfgrestore pvresize lvextend e2fsck resize2fs mkswap xfs_growfs; do
    assert grep -Eq "rootpxe_run_logged_mutation.* $tool( |$)" "$funcs"
done
printf 'Task console: %s checks, %s failures\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
