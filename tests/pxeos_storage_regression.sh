#!/bin/bash
# 静态回归契约：不依赖真实存储，防止 PXEOS 重新引入已修复的危险模式。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.smb-validation.sh"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 缺少 $2"; }
must_not_have() { ! grep -RInE -- "$2" "$1" >/dev/null || fail "$1 包含禁止模式 $2"; }
must_not_have_literal() { ! grep -RInF -- "$2" "$1" >/dev/null || fail "$1 包含禁止文本 $2"; }

must_not_have "$overlay" '/images'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'eval[[:space:]]'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'source[[:space:]]+/tmp/hinfo'
must_not_have "$overlay" 'vers=|sec='
must_have "$overlay/bin/pxeos.mount" 'mount.cifs "//${storage_server}/${storage_export}" /storage'
must_have "$overlay/bin/pxeos.checkin" 'Invalid SMB export path'
must_have "$overlay/bin/pxeos.checkin" 'SMB requires a JSON checkin response'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_validate_smb_export'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'smb_username_b64'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'smb_password_b64'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'smb_domain_b64'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'curl -Lksf'
must_have "$overlay/bin/pxeos.checkin" "-w \$'\\n%{http_code}'"
must_have "$overlay/bin/pxeos.checkin" '[[ $http_code =~ ^4[0-9][0-9]$ ]]'
must_have "$overlay/bin/pxeos.checkin" '[INFO]  Task aborted or withdrawn. Stopping PXEOS.'
must_have "$overlay/bin/pxeos.checkin" '[WARN]  Check-in not confirmed. Retrying in 5s.'
must_have "$overlay/bin/pxeos.checkin" 'exit "$checkin_rc"'
must_have "$overlay/bin/pxeos.mount" '${storage_export}" /storage'
awk '/^rootpxe_validate_smb_export\(\)/ { on=1 } /^rootpxe_storage_path\(\)/ { on=0 } on { print }' \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp.smb-validation.sh"
# shellcheck source=/dev/null
. "$tmp.smb-validation.sh"
rm -f "$tmp.smb-validation.sh"
for export_path in _share share-name share/images; do
    [[ $(rootpxe_validate_smb_export "$export_path") == "$export_path" ]] || fail "合法 SMB export 被拒绝: $export_path"
done
for export_path in '' /share share/ share//images share/../images //server/share . .. 'share name' 'share$bad' 'share?' 'share\\images' 'share:images'; do
    rootpxe_validate_smb_export "$export_path" >/dev/null && fail "非法 SMB export 被接受: $export_path"
done
[[ /storage == /* ]] || fail 'NFS export path 必须接受绝对路径'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_prepare_storage_layout'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '/storage/postinitscripts/hook.sh'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '/storage/postdeployscripts/hook.sh'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'for pid in "${writer_pids[@]}"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_wait_for_writer'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '( set -o pipefail;'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'CAPTURE_PIPELINE_FAILED'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'RESTORE_PIPELINE_FAILED'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'task_token'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'value=${value//+_+/ }'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'line=${line#export }'
must_not_have "$overlay/bin/pxeos" '\. /tmp/hinfo.txt'
must_have "$overlay/bin/pxeos.imgcomplete" '--connect-timeout'
must_have "$overlay/bin/pxeos.checkin" 'message_b64'
must_have "$overlay/bin/pxeos.checkin" 'error_b64'
must_have "$overlay/bin/pxeos.checkin" 'retry_after_sec'
must_have "$overlay/bin/pxeos.inventory" 'token=$task_token'
must_have "$overlay/bin/pxeos.checkin" 'taskid|osid|img_format|shutdown|api_version)'
must_have "$overlay/bin/pxeos.checkin" 'pigz_comp)'
must_have "$overlay/bin/pxeos.checkin" 'Invalid numeric checkin field: pigz_comp'
for value in -6 0 6; do [[ $value =~ ^-?[0-9]+$ ]] || fail "合法 pigz_comp 被拒绝: $value"; done
for value in --6 +6 6.0 abc ''; do [[ ! $value =~ ^-?[0-9]+$ ]] || fail "非法 pigz_comp 被接受: $value"; done
for config in "$root/configs/fsx64.config" "$root/configs/fsx86.config" "$root/configs/fsarm64.config"; do
    must_have "$config" 'BR2_TARGET_ENABLE_ROOT_LOGIN=y'
    must_have "$config" 'BR2_TARGET_GENERIC_ROOT_PASSWD="pxeos"'
    must_not_have "$config" '# BR2_TARGET_ENABLE_ROOT_LOGIN is not set'
done
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_clear_smb_plaintext'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'unset smb_username smb_password smb_domain'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_clear_capture_marker'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_request_disk_permit'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_wait_for_disk_permit'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_error_wait_for_retry'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '"${api}disk-permit"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '"${api}error"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '"${api}task-status"'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'task-status?taskId='
must_have "$overlay/bin/pxeos.upload" 'rootpxe_wait_for_disk_permit'
must_have "$overlay/bin/pxeos.download" 'rootpxe_wait_for_disk_permit'
must_not_have_literal "$overlay/bin/pxeos.upload" 'rootpxe_request_disk_permit || handleError'
must_not_have_literal "$overlay/bin/pxeos.download" 'rootpxe_request_disk_permit || handleError'
must_have "$overlay/etc/init.d/S99pxeos" '/tmp/pxeos.failure_action'
printf 'PASS: PXEOS storage regression contract\n'
