#!/bin/bash
# JSON checkin and storage-mount regression.  It uses real jq plus temporary
# fixtures and command mocks only; no endpoint, disk, mount, or storage server
# is touched.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
jq_bin="${JQ_BIN:-jq}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [[ $jq_bin != */* && $jq_bin != *\\* ]]; then
    jq_bin=$(command -v -- "$jq_bin") || fail "需要真实 jq；请通过 JQ_BIN 指定可执行文件"
fi
[[ -x $jq_bin || $jq_bin == *.exe ]] || fail "JQ_BIN 不是可执行文件: $jq_bin"
"$jq_bin" --version >/dev/null 2>&1 || fail "需要真实 jq；请通过 JQ_BIN 指定可执行文件"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^rootpxe_json_get_string\(\)/ { on=1 } /^checkin_rootpxe\(\)/ { on=0 } on { print }' "$checkin" >"$tmp/checkin-json.sh"
awk '/^rootpxe_validate_smb_export\(\)/ { on=1 } /^rootpxe_storage_path\(\)/ { on=0 } on { print }' "$funcs" >"$tmp/smb-validation.sh"

# The production script resolves jq through PATH.  This test provides a
# one-command PATH wrapper without replacing jq's behavior.
mkdir "$tmp/bin"
cat >"$tmp/bin/jq" <<EOF
#!/bin/bash
exec "$jq_bin" "\$@"
EOF
chmod +x "$tmp/bin/jq"
PATH="$tmp/bin:$PATH"
export PATH

# shellcheck source=/dev/null
. "$tmp/smb-validation.sh"
# shellcheck source=/dev/null
. "$tmp/checkin-json.sh"

flat_smb='{"taskId":42,"type":"capture","pxeType":"up","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"shutdown":false,"changeHostname":false,"storage":"192.0.2.10:share/images","protocol":"smb","storageip":"192.0.2.10","exportPath":"share/images","smbUsername":"test-user","smbPassword":"pa%ss\\word","smbDomain":"WORKGROUP"}'
rootpxe_apply_json_checkin "$flat_smb" || fail '平铺 SMB JSON 被拒绝'
[[ $protocol == smb ]] || fail "平铺 protocol 解析错误: ${protocol@Q}"
[[ $storage_server == 192.0.2.10 ]] || fail "平铺 server 解析错误: ${storage_server@Q}"
[[ $storage_export == share/images && -z ${storage_share:-} ]] || fail '平铺 SMB 必须仅保留完整相对 exportPath'
[[ $smb_password == 'pa%ss\word' ]] || fail 'SMB 密码中的 % 或反斜线被改变'
[[ $shutdown == false && $changeHostname == false ]] || fail 'JSON false 被当作缺失'
export -p | grep -q 'smb_\(username\|password\|domain\)' && fail 'SMB 凭据不得导出到子进程环境'

for smb_export in _share share-name; do
    allowed_smb="{\"protocol\":\"smb\",\"storageip\":\"192.0.2.10\",\"exportPath\":\"$smb_export\",\"smbUsername\":\"test-user\",\"smbPassword\":\"test-pass\"}"
    rootpxe_apply_json_checkin "$allowed_smb" || fail "合法 SMB exportPath 被拒绝: $smb_export"
    [[ $storage_export == "$smb_export" ]] || fail "合法 SMB exportPath 被改变: $smb_export"
done

conflicting_storage='{"protocol":"smb","storageip":"192.0.2.10","exportPath":"flat-share/images","smbUsername":"flat-user","smbPassword":"flat-pass","storage":{"protocol":"nfs","server":"192.0.2.99","export":"/nested-nfs","smb":{"username":"nested-user","password":"nested-pass"}}}'
rootpxe_apply_json_checkin "$conflicting_storage" || fail '顶层 SMB 与嵌套 NFS 冲突响应被拒绝'
[[ $protocol == smb && $storage_server == 192.0.2.10 && $storage_export == flat-share/images && $smb_username == flat-user && $smb_password == flat-pass ]] || fail '顶层 SMB 必须覆盖嵌套 NFS 和嵌套凭据'

rootpxe_apply_json_checkin '{"wait":true,"message":"queued","retryAfterSec":5}' || fail '排队 JSON 被拒绝'
[[ $waitFlag == 1 && -z $protocol && -z $storage_server && -z $storage_export && -z $smb_password ]] || fail '排队响应保留了前次存储或 SMB 凭据状态'

nested_nfs='{"taskId":43,"type":"deploy","pxeType":"down","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"shutdown":0,"storage":{"protocol":"nfs","server":"192.0.2.11","export":"/dept/images"}}'
rootpxe_apply_json_checkin "$nested_nfs" || fail '嵌套 NFS JSON 被拒绝'
[[ $protocol == nfs && $storage_server == 192.0.2.11 && $storage_export == /dept/images ]] || fail '嵌套 NFS 字段解析错误'
[[ $shutdown == 0 ]] || fail 'JSON 0 被当作缺失'

flat_nfs='{"taskId":44,"type":"deploy","pxeType":"down","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"storage":"192.0.2.12:/dept/images","protocol":"nfs","storageip":"192.0.2.12","exportPath":"/dept/images"}'
rootpxe_apply_json_checkin "$flat_nfs" || fail '平铺 NFS JSON 被拒绝'
[[ $protocol == nfs && $storage_server == 192.0.2.12 && $storage_export == /dept/images ]] || fail '平铺 NFS 字段解析错误'

nested_smb='{"taskId":45,"type":"capture","pxeType":"up","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"storage":{"protocol":"smb","server":"192.0.2.13","share":"/canonical-share","smb":{"username":"nested-user","password":"nested-pass"}}}'
rootpxe_apply_json_checkin "$nested_smb" && fail '嵌套 SMB JSON 不得兼容'

flat_share_smb='{"taskId":46,"type":"capture","pxeType":"up","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"protocol":"smb","storageip":"192.0.2.14","exportPath":"wire-share","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$flat_share_smb" || fail '单层 SMB share 被拒绝'
[[ $storage_export == wire-share ]] || fail '单层 SMB share 被改变'

leading_slash_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"/share","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$leading_slash_smb" && fail '带前导斜杠的 SMB exportPath 不得接受'

unc_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"//server/share","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$unc_smb" && fail 'UNC SMB exportPath 不得接受'

dot_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":".","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$dot_smb" && fail '点 SMB exportPath 不得接受'

traversal_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"share/../images","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$traversal_smb" && fail '遍历 SMB exportPath 不得接受'

empty_segment_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"share//images","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$empty_segment_smb" && fail '空段 SMB exportPath 不得接受'

trailing_slash_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"share/images/","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$trailing_slash_smb" && fail '尾随斜杠 SMB exportPath 不得接受'

whitespace_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"share name","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$whitespace_smb" && fail '含空白的 SMB exportPath 不得接受'

dangerous_smb='{"protocol":"smb","storageip":"192.0.2.14","exportPath":"share$bad","smbUsername":"wire-user","smbPassword":"wire-pass"}'
rootpxe_apply_json_checkin "$dangerous_smb" && fail '含危险字符的 SMB exportPath 不得接受'

invalid_nfs_path='{"protocol":"nfs","storageip":"192.0.2.16","exportPath":"relative/path"}'
rootpxe_apply_json_checkin "$invalid_nfs_path" && fail '相对 NFS export 不得接受'

missing_server='{"protocol":"nfs","exportPath":"/dept/images"}'
rootpxe_apply_json_checkin "$missing_server" && fail '缺少存储服务器不得接受'

missing_smb_credentials='{"protocol":"smb","storageip":"192.0.2.17","exportPath":"share"}'
rootpxe_apply_json_checkin "$missing_smb_credentials" && fail '缺少 SMB 凭据不得接受'

missing_protocol='{"storage":"192.0.2.10:storage","storageip":"192.0.2.10","exportPath":"/storage"}'
rootpxe_apply_json_checkin "$missing_protocol" && fail '缺少协议的 JSON 不得默认 NFS'

unknown_protocol='{"storage":{"protocol":"ftp","server":"192.0.2.10","export":"/storage"}}'
rootpxe_apply_json_checkin "$unknown_protocol" && fail '未知协议的 JSON 不得被接受'

# The legacy shell response still shares the same post-parse storage checks.
# Run checkin_rootpxe from a path-rewritten fixture, with curl/dmidecode mocked.
mkdir -p "$tmp/legacy-bin"
cat >"$tmp/legacy-bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n200\n' "${MOCK_CHECKIN_BODY:?}"
EOF
cat >"$tmp/legacy-bin/dmidecode" <<'EOF'
#!/bin/bash
printf '%s\n' '00000000-0000-0000-0000-000000000000'
EOF
chmod +x "$tmp/legacy-bin/curl" "$tmp/legacy-bin/dmidecode"
: >"$tmp/proc-cmdline"
sed -e 's|^\. /usr/share/pxeos/lib/partition-funcs.sh$|:|' \
    -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" \
    "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/legacy-funcs.sh"
cat >"$tmp/legacy-runtime.sh" <<EOF
ismajordebug=0
. "$tmp/legacy-funcs.sh"
clearScreen() { :; }
displayBanner() { :; }
debugPause() { :; }
verifyNetworkConnection() { :; }
determineOS() { :; }
dots() { :; }
handleError() { return 97; }
EOF
sed -e "s|^\. /usr/share/pxeos/lib/funcs.sh$|. \"$tmp/legacy-runtime.sh\"|" \
    -e "s|/tmp/pxeos.shutdown|$tmp/pxeos.shutdown|g" \
    -e "s|/proc/cmdline|$tmp/proc-cmdline|g" \
    "$checkin" >"$tmp/legacy-checkin.sh"
legacy_body=$(cat <<'EOF'
taskid=47
osid=9
img_format=5
pigz_comp=-6
shutdown=0
type_b64=Y2FwdHVyZQ==
pxe_type_b64=dXA=
img_b64=aW1hZ2VzL2RlbW8=
img_type_b64=cmF3
img_partition_type_b64=YWxs
storageip_b64=MTkyLjAuMi4yMA==
protocol_b64=bmZz
export_path_b64=L2xlZ2FjeQ==
execution_token_b64=MDEyMzQ1Njc4OWFiY2RlZg==
EOF
)
# shellcheck source=/dev/null
capone=1; web='http://mock/'; taskid=47; task_token=0123456789abcdef; mac=001122334455; mc=''; chkdsk=0; deployed=''
PATH="$tmp/legacy-bin:$PATH"
export PATH MOCK_CHECKIN_BODY="$legacy_body"
# shellcheck source=/dev/null
. "$tmp/legacy-checkin.sh"
# This Git Bash build rejects the production token-regex upper bound, which is
# unrelated to legacy field parsing.  Keep the fixture focused on the parser
# and post-parse storage validation rather than its already-covered identity
# gate.
rootpxe_require_task_context() { [[ -n ${task_token:-} ]]; }
# Keep the credential helper in the fixture and make any unexpected SMB
# creation visible. The legacy positive case below is NFS-only.
rootpxe_prepare_smb_credentials() {
    if [[ $protocol == smb ]]; then
        : >"$tmp/legacy-smb-credential-attempt"
        [[ -n ${smb_username:-} && -n ${smb_password:-} ]] || return 1
        printf 'username=%s\npassword=%s\n' "$smb_username" "$smb_password" >"$tmp/json.credentials"
        smb_credentials_file="$tmp/json.credentials"; export smb_credentials_file
        rootpxe_clear_smb_plaintext
        return 0
    fi
    rootpxe_clear_smb_plaintext
    return 0
}

json_checkin_body='{"taskId":49,"executionToken":"0123456789abcdef","type":"capture","pxeType":"up","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"shutdown":false,"storage":"192.0.2.20:share/images","protocol":"smb","storageip":"192.0.2.20","exportPath":"share/images","smbUsername":"json-user","smbPassword":"json-pass"}'
protocol=''; storage_server=''; storage_export=''; storageip=''; export_path=''; smb_username=''; smb_password=''; smb_domain=''
rm -f "$tmp/legacy-smb-credential-attempt" "$tmp/json.credentials"
MOCK_CHECKIN_BODY="$json_checkin_body"
export MOCK_CHECKIN_BODY
json_checkin_rc=0
checkin_rootpxe || json_checkin_rc=$?
trap 'rm -rf "$tmp"' EXIT INT TERM
[[ $json_checkin_rc -eq 0 && $protocol == smb && $storage_export == share/images && -f $tmp/json.credentials && -z ${smb_password:-} ]] || fail '完整 JSON SMB checkin 未保持路径或未安全创建凭据'
rootpxe_cleanup_smb_credentials
rm -f "$tmp/legacy-smb-credential-attempt"
MOCK_CHECKIN_BODY="$legacy_body"
export MOCK_CHECKIN_BODY

protocol=''; storage_server=''; storage_export=''; storage_share=''; storageip=''; export_path=''
smb_username=''; smb_password=''; smb_domain=''
legacy_checkin_rc=0
checkin_rootpxe || legacy_checkin_rc=$?
# checkin_rootpxe installs its runtime session-cleanup trap.  Restore the
# fixture cleanup even when the mocked legacy response is rejected.
trap 'rm -rf "$tmp"' EXIT INT TERM
[[ $legacy_checkin_rc -eq 0 ]] || fail 'legacy checkin 响应被拒绝'
[[ $protocol == nfs && $storage_server == 192.0.2.20 && $storage_export == /legacy ]] || fail 'legacy NFS 协议或 export 解析错误'
[[ ! -e $tmp/legacy-smb-credential-attempt ]] || fail 'legacy NFS 不得创建 SMB 凭据'

legacy_smb_body=$(cat <<'EOF'
taskid=48
osid=9
img_format=5
pigz_comp=-6
shutdown=0
type_b64=Y2FwdHVyZQ==
pxe_type_b64=dXA=
img_b64=aW1hZ2VzL2RlbW8=
img_type_b64=cmF3
img_partition_type_b64=YWxs
storageip_b64=MTkyLjAuMi4yMA==
protocol_b64=c21i
export_path_b64=L3NoYXJl
smb_username_b64=bGVnYWN5LXVzZXI=
smb_password_b64=bGVnYWN5LXBhc3M=
execution_token_b64=MDEyMzQ1Njc4OWFiY2RlZg==
EOF
)
protocol=''; storage_server=''; storage_export=''; storageip=''; export_path=''; smb_username=''; smb_password=''; smb_domain=''
rm -f "$tmp/legacy-smb-credential-attempt"
MOCK_CHECKIN_BODY="$legacy_smb_body"
export MOCK_CHECKIN_BODY
legacy_smb_rc=0
checkin_rootpxe || legacy_smb_rc=$?
trap 'rm -rf "$tmp"' EXIT INT TERM
[[ $legacy_smb_rc -ne 0 && ! -e $tmp/legacy-smb-credential-attempt ]] || fail 'legacy SMB 必须在凭据创建前拒绝'

# Run the mount script from a path-rewritten fixture.  The mock records argv,
# so this proves SMB is not silently sent through NFS and does not pin vers/sec.
mkdir -p "$tmp/mount-bin" "$tmp/storage"
cat >"$tmp/mount-bin/umount" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$tmp/mount-bin/mount.cifs" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >"${MOCK_CIFS_ARGS:?}"
EOF
cat >"$tmp/mount-bin/mount" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >"${MOCK_NFS_ARGS:?}"
EOF
chmod +x "$tmp/mount-bin/umount" "$tmp/mount-bin/mount.cifs" "$tmp/mount-bin/mount"
cat >"$tmp/mount-funcs.sh" <<'EOF'
dots() { :; }
debugPause() { :; }
handleError() { exit 97; }
rootpxe_cleanup_smb_credentials() { rm -f -- "${smb_credentials_file:-}"; smb_credentials_file=''; }
rootpxe_prepare_storage_layout() { return 0; }
EOF
awk '/^rootpxe_validate_smb_export\(\)/ { on=1 } /^rootpxe_storage_path\(\)/ { on=0 } on { print }' \
    "$funcs" >"$tmp/mount-smb-validation.sh"
printf '. "%s"\n' "$tmp/mount-smb-validation.sh" >>"$tmp/mount-funcs.sh"
sed -e "1c\\. \"$tmp/mount-funcs.sh\"" \
    -e "s|/tmp/mount-output|$tmp/mount-output|g" \
    -e "s|/storage|$tmp/storage|g" \
    "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.mount" >"$tmp/pxeos.mount"
: >"$tmp/mount.credentials"
PATH="$tmp/mount-bin:$PATH" \
MOCK_CIFS_ARGS="$tmp/cifs.args" MOCK_NFS_ARGS="$tmp/nfs.args" \
protocol=smb storage_server=192.0.2.20 storage_export=share/images smb_credentials_file="$tmp/mount.credentials" type=up capone=0 \
bash "$tmp/pxeos.mount" || fail 'SMB mount fixture failed'
mapfile -d '' -t cifs_args <"$tmp/cifs.args"
[[ ${cifs_args[0]} == '//192.0.2.20/share/images' && ${cifs_args[1]} == "$tmp/storage" ]] || fail 'SMB mount argv 未使用完整 share/subdir'
[[ ${cifs_args[*]} != *vers=* && ${cifs_args[*]} != *sec=* ]] || fail 'SMB mount 不得固定 vers/sec 协商参数'
[[ ! -e $tmp/nfs.args && ! -e $tmp/mount.credentials ]] || fail 'SMB 分支误走 NFS 或未清理凭据'

: >"$tmp/leading-slash.credentials"
set +e
PATH="$tmp/mount-bin:$PATH" MOCK_CIFS_ARGS="$tmp/cifs-leading-slash.args" MOCK_NFS_ARGS="$tmp/nfs-leading-slash.args" \
protocol=smb storage_server=192.0.2.20 storage_export=/share smb_credentials_file="$tmp/leading-slash.credentials" type=up capone=0 bash "$tmp/pxeos.mount" >/dev/null 2>&1
leading_slash_smb_rc=$?
set -e
[[ $leading_slash_smb_rc -eq 97 && ! -e $tmp/cifs-leading-slash.args && ! -e $tmp/leading-slash.credentials ]] || fail '带前导斜杠 SMB mount 必须拒绝、不调用挂载并清理凭据'

set +e
PATH="$tmp/mount-bin:$PATH" MOCK_CIFS_ARGS="$tmp/cifs-missing.args" MOCK_NFS_ARGS="$tmp/nfs-missing.args" \
protocol='' storage_server=192.0.2.21 storage_export=/legacy type=up capone=0 bash "$tmp/pxeos.mount" >/dev/null 2>&1
missing_protocol_rc=$?
set -e
[[ $missing_protocol_rc -eq 97 && ! -e $tmp/nfs-missing.args ]] || fail '非 Capone 缺协议不得猜测 NFS'

PATH="$tmp/mount-bin:$PATH" MOCK_CIFS_ARGS="$tmp/cifs-capone.args" MOCK_NFS_ARGS="$tmp/nfs-capone.args" \
protocol='' storage_server=192.0.2.22 storage_export=/legacy type=up capone=1 bash "$tmp/pxeos.mount" || fail 'Capone NFS 兼容分支失败'
mapfile -d '' -t nfs_args <"$tmp/nfs-capone.args"
[[ ${nfs_args[2]} == '192.0.2.22:/legacy' && ${nfs_args[3]} == "$tmp/storage" ]] || fail 'Capone NFS 未使用显式 server/export'

printf 'PASS: PXEOS real-jq JSON checkin regression\n'
