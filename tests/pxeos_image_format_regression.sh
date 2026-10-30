#!/usr/bin/env bash
# Ordinary files and executable adapters only; never touches a real disk/NAS.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib=$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib
checkin=$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin
for f in rootpxe_normalize_compression_level rootpxe_validate_pigz_compression; do eval "$(sed -n "/^$f() *{/,/^}/p" "$checkin")"; done
for f in rootpxe_effective_img_format rootpxe_validate_runtime_img_format; do eval "$(sed -n "/^$f() *{/,/^}/p" "$lib/funcs.sh")"; done
[[ $(rootpxe_normalize_compression_level 0) == 0 ]]
for level in {1..9}; do [[ $(rootpxe_normalize_compression_level "$level") == -"$level" ]]; done
for level in -1 -9 10 22 1.5 ''; do ! rootpxe_normalize_compression_level "$level" >/dev/null; done
for imgFormat in 0 5; do
 rootpxe_validate_runtime_img_format
 for level in 0 -1 -9; do rootpxe_validate_pigz_compression "$level" "$imgFormat"; done
done
for imgFormat in 1 2 3 4 6 invalid ''; do ! rootpxe_validate_runtime_img_format; done
printf 'PASS: two image formats and zero compression contract\n'
tmp=$(mktemp -d /tmp/rootpxe-image-format.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
for f in uploadFormat rootpxe_wait_for_writer writeImage rootpxe_safe_relative_path; do eval "$(sed -n "/^$f() *{/,/^}/p" "$lib/funcs.sh")"; done
for f in rootpxe_storage_read_file; do eval "$(sed -n "/^$f() *{/,/^}/p" "$lib/storage-io.sh")"; done
. "$lib/restore-preflight.sh"
mkdir "$tmp/bin"
# GNU gzip is a real gzip codec adapter when pigz is not installed. Partclone
# is deliberately a byte-copy mock; no filesystem image/block device is used.
printf '#!/bin/bash\nprintf "gzip\\n" >>"$CODEC_TRACE"\nexec /usr/bin/gzip "$@"\n' >"$tmp/bin/pigz"
printf '#!/bin/bash\nprintf "zstd\\n" >>"$CODEC_TRACE"\nexec /usr/bin/zstdmt -T2 "$@"\n' >"$tmp/bin/zstdmt"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" CODEC_TRACE="$tmp/codec.trace"
handleError(){ printf '%s\n' "$*" >&2; exit 97; }
rootpxe_console_message(){ :; }
rootpxe_require_unused_target_disks(){ :; }
rootpxe_partclone_progress_start(){ rootpxe_partclone_progress_term=dumb; rootpxe_partclone_progress_args=(); rootpxe_partclone_progress_stderr_target=$tmp/stderr; }
rootpxe_partclone_progress_wait(){ :; }
rootpxe_partclone_progress_abort(){ :; }
rootpxe_storage_exec(){ [[ $1 == read && $3 == - ]] || return 98; cat -- "$2"; }
partclone.restore(){ local dest=''; while (( $# )); do if [[ $1 == -O ]]; then dest=$2; shift 2; else shift; fi; done; cat >"$dest"; }
head -c 209715207 /dev/urandom >"$tmp/input"
source_sha256=$(sha256sum "$tmp/input"); source_sha256=${source_sha256%% *}
printf 'SOURCE: bytes=209715207 sha256=%s\n' "$source_sha256"
for imgFormat in 0 5; do
 for level in {0..9}; do
  PIGZ_COMP=$(rootpxe_normalize_compression_level "$level")
  rootpxe_storage_workspace=$tmp/work
  mkdir -p "$rootpxe_storage_workspace/image"
  img=$rootpxe_storage_workspace/image storage=fixture rootpxe_capture_direct=yes
  file=$img/d1p1.img fifo=$tmp/input.fifo writer_pids=()
  : >"$CODEC_TRACE"
  uploadFormat "$fifo" "$file"
  cat "$tmp/input" >"$fifo"
  rootpxe_wait_for_writer "$rootpxe_last_writer_pid"
  [[ -f $file.000 && ! -e $file.001 ]]
  mv "$file.000" "$file"
  rootpxe_validate_artifact_fragments "$file"
  writeImage "$file" "$tmp/output"
  cmp "$tmp/input" "$tmp/output"
  restored_sha256=$(sha256sum "$tmp/output"); restored_sha256=${restored_sha256%% *}
  [[ $restored_sha256 == "$source_sha256" ]]
  if [[ $PIGZ_COMP == 0 ]]; then
   [[ ! -s $CODEC_TRACE && $(stat -c %s "$file") == 209715207 ]]
  elif [[ $imgFormat == 0 ]]; then
   [[ $(cat "$CODEC_TRACE") == $'gzip\ngzip' ]]
  else [[ $(cat "$CODEC_TRACE") == $'zstd\nzstd' ]]
  fi
  printf 'PASS: format=%s level=%s >200MiB one file, exact restore, codec selection sha256=%s\n' "$imgFormat" "$level" "$restored_sha256"
  rm -rf "$rootpxe_storage_workspace" "$fifo" "$tmp/output"
 done
done
# Retired formats and invalid levels stop before any FIFO or child starts.
for imgFormat in 1 2 3 4 6; do
 if ( uploadFormat "$tmp/invalid.fifo" "$tmp/invalid.img" ); then exit 1; fi
 [[ ! -e $tmp/invalid.fifo ]]
done
imgFormat=0 PIGZ_COMP=-10
if ( uploadFormat "$tmp/invalid.fifo" "$tmp/invalid.img" ); then exit 1; fi
[[ ! -e $tmp/invalid.fifo ]]
# The DD entry must finalize the same BASE consumed by exact-path restore.
grep -Fq 'mv "${imgpart}.000" "$imgpart"' "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
! grep -Eq 'write-split|splitBytes|split -a 3|compgen -G|sys\.img\.\*' "$lib/funcs.sh" "$lib/storage-io.sh" "$root/Buildroot/package/rootpxe-storage-io/src/storage_fs.c"
