#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
if grep -En '/tmp/(tmpoutput\.txt|output\.txt|e2fsck\.txt|resize2fs\.txt|btfrslog\.txt|btrfslog\.txt|resize\.f2fs\.txt|pxeosfatgrow[^ /]*\.txt|xfslog\.txt|sgdisk-gl\.err|cmdlist)' "$funcs"; then
    printf 'FAIL: legacy diagnostic path\n' >&2; exit 1
fi
! grep -qE '/tmp/rootpxe-linux-(mount|vgchange)-output' "$funcs"
count=$(sed -n '/^rootpxe_log_type_valid() {/,/^}/p' "$overlay/usr/share/pxeos/lib/log-paths.sh" | grep 'return 0' | tr '|' '\n' | wc -l)
[[ $count == 25 ]]
grep -q 'rootpxe_partclone_progress_args=.*-L' "$overlay/usr/share/pxeos/lib/partclone-progress.sh"
! grep -q -- '--log=/clamavscan/pxeos/log/log.txt' "$overlay/bin/pxeos.av"
printf 'Fixed diagnostic contract: PASS\n'
