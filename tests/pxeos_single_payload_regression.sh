#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib=$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib
tmp=$(mktemp -d /tmp/rootpxe-lvm-volume-audit.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
for f in rootpxe_capture_lvm_volumes_single uploadFormat rootpxe_wait_for_writer rootpxe_safe_relative_path; do eval "$(sed -n "/^$f() *{/,/^}/p" "$lib/funcs.sh")"; done
. "$lib/restore-preflight.sh"
rootpxe_lvm_is_pv_partition(){ :; }
rootpxe_lvm_capture_lv_facts_prepared(){ :; }
rootpxe_lvm_validate_capture_artifact_names(){ :; }
rootpxe_partition_progress_item(){ :; }
rootpxe_partition_progress_current_item(){ :; }
rootpxe_partition_progress_clear_current_item(){ :; }
rootpxe_activate_lvm_vg(){ :; }
rootpxe_partclone_progress_prepare(){ rootpxe_partclone_progress_args=(); rootpxe_partclone_progress_term=dumb; rootpxe_partclone_progress_stderr_target=$tmp/stderr; }
rootpxe_partclone_progress_start_collector(){ :; }
rootpxe_partclone_progress_wait(){ :; }
rootpxe_partclone_progress_abort(){ :; }
rootpxe_console_message(){ :; }
handleError(){ printf 'HANDLE_ERROR %s\n' "$*" >&2; exit 97; }
blkid(){ printf 'ext4\n'; }
rootpxe_lvm_native(){
    case $1 in
        pvdisplay) printf 'PV UUID pv-fixture\n';;
        vgcfgbackup) printf 'vg0 { }\n' >"$3";;
        vgchange) :;;
        *) printf 'UNEXPECTED LVM command %s\n' "$*" >&2; return 99;;
    esac
}
partclone.extfs(){
    local fifo=''
    while (( $# )); do if [[ $1 == -O ]]; then fifo=$2; shift 2; else shift; fi; done
    head -c 209715207 /dev/zero >"$fifo"
}
rootpxe_capture_direct=yes imgFormat=0 PIGZ_COMP=0 writer_pids=()
rootpxe_lvm_active=yes rootpxe_lvm_captured=no
rootpxe_lvm_pv_path=/dev/mockp1 rootpxe_lvm_pv_number=1
rootpxe_lvm_pv_uuid=pv-fixture rootpxe_lvm_vg_uuid=vg-fixture rootpxe_lvm_vg_name=vg0
rootpxe_lvm_pv_bytes=1073741824 rootpxe_lvm_pe_start_bytes=1048576
rootpxe_lvm_vg_extent_bytes=4194304 rootpxe_lvm_vg_free_bytes=0
rootpxe_lvm_lv_facts_file=$tmp/lvs
printf 'root|lv-fixture|/dev/vg0/root|209715207|ext4\n' >"$rootpxe_lvm_lv_facts_file"
mkdir "$tmp/image"
rc=0; rootpxe_capture_lvm_volumes_single "$tmp/image" || rc=$?
printf 'actual_lvm_capture_leaf_rc=%s\n' "$rc"
find "$tmp/image" -type f -printf '%f:%s\n' | LC_ALL=C sort
base=$tmp/image/d1p1.lvm.lv.root.img
rc=0; rootpxe_validate_artifact_fragments "$base" || rc=$?
printf 'published_bytes=%s expected_source_bytes=209715207 missing_bytes=%s preflight_rc=%s\n' "$(stat -c %s "$base")" "$((209715207-$(stat -c %s "$base")))" "$rc"
jq -c '.vgs[].lvs[]|{artifact,originalBytes,minBytes}' "$tmp/image/d1.lvm.schema.json"

[[ $(stat -c %s "$base") == 209715207 && $rc == 0 ]]
printf 'PASS: actual LVM capture leaf preserves >200MiB as one finalized payload\n'
# Exercise the actual DD capture branch, mocking only hardware/progress calls.
eval "$(sed -n '/^beginUpload() {/,/^}/p' "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload")"
eval "$(sed -n '/^rootpxe_prepare_capture_output_path() {/,/^}/p' "$lib/funcs.sh")"
rootpxe_verify_disk_permit_binding(){ :; }
rootpxe_partition_progress_plan_whole_disk(){ :; }
rootpxe_capture_run_producer(){ "$@"; }
sfdisk(){ return 1; }
clearScreen(){ :; }
partclone.imager(){ local fifo=''; while (( $# )); do if [[ $1 == -O ]]; then fifo=$2; shift 2; else shift; fi; done; head -c 1048583 /dev/zero >"$fifo"; }
imgType=dd img=raw.img imagePath=$tmp/dd hd=/dev/mock
mkdir "$imagePath"
beginUpload
[[ -f $imagePath/$img && ! -e $imagePath/$img.000 && $(stat -c %s "$imagePath/$img") == 1048583 ]]
rootpxe_validate_artifact_fragments "$imagePath/$img"
printf 'PASS: actual DD capture branch finalizes exact BASE for restore\n'
