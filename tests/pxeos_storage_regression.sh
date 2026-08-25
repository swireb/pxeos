#!/bin/bash
# 静态回归契约：不依赖真实存储，防止 PXEOS 重新引入已修复的危险模式。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 缺少 $2"; }
must_not_have() { ! grep -RInE -- "$2" "$1" >/dev/null || fail "$1 包含禁止模式 $2"; }

must_not_have "$overlay" '/images'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'eval[[:space:]]'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'source[[:space:]]+/tmp/hinfo'
must_not_have "$overlay" 'vers=|sec='
must_have "$overlay/bin/pxeos.mount" 'mount.cifs "//${storage_server}/${storage_share}" /storage'
must_have "$overlay/bin/pxeos.checkin" 'Invalid SMB share name'
must_have "$overlay/bin/pxeos.mount" '${storage_export}" /storage'
share_pattern='^[A-Za-z0-9][A-Za-z0-9._$ ()-]{0,79}$'
[[ storage =~ $share_pattern ]] || fail '裸 SMB share 必须通过'
[[ ! /storage =~ $share_pattern && ! storage/sub =~ $share_pattern ]] || fail 'SMB 不得接受路径或嵌套 share'
[[ /storage == /* ]] || fail 'NFS export path 必须接受绝对路径'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_prepare_storage_layout'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'wait "${writer_pids[@]}"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'PIPESTATUS'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'task_token'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'value=${value//+_+/ }'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'line=${line#export }'
must_not_have "$overlay/bin/pxeos" '\. /tmp/hinfo.txt'
must_have "$overlay/bin/pxeos.imgcomplete" '--connect-timeout'
must_have "$overlay/bin/pxeos.checkin" 'message_b64'
must_have "$overlay/bin/pxeos.checkin" 'error_b64'
must_have "$overlay/bin/pxeos.checkin" 'retry_after_sec'
must_have "$overlay/bin/pxeos.inventory" 'token=$task_token'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_clear_smb_plaintext'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'unset smb_username smb_password smb_domain'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_clear_capture_marker'
printf 'PASS: PXEOS storage regression contract\n'
