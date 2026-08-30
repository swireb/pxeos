#!/usr/bin/env bash
# 合并后的 PXEOS 回归测试；每个原脚本在独立子 shell 中运行。
set -euo pipefail

# ===== 原脚本：tests/pxeos_checkin_json_regression.sh =====
(
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
awk '/^rootpxe_validate_capture_backup_name\(\)/ { on=1 } /^rootpxe_capture_paths_overlap\(\)/ { on=0 } on { print }' "$funcs" >"$tmp/capture-backup-name.sh"

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
. "$tmp/capture-backup-name.sh"
# shellcheck source=/dev/null
. "$tmp/checkin-json.sh"

flat_smb='{"taskId":42,"type":"capture","pxeType":"up","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"shutdown":false,"changeHostname":false,"captureBackupName":"demo-backup-20260830T104527123Z","storage":"192.0.2.10:share/images","protocol":"smb","storageip":"192.0.2.10","exportPath":"share/images","smbUsername":"test-user","smbPassword":"pa%ss\\word","smbDomain":"WORKGROUP"}'
rootpxe_apply_json_checkin "$flat_smb" || fail '平铺 SMB JSON 被拒绝'
[[ $protocol == smb ]] || fail "平铺 protocol 解析错误: ${protocol@Q}"
[[ $storage_server == 192.0.2.10 ]] || fail "平铺 server 解析错误: ${storage_server@Q}"
[[ $storage_export == share/images && -z ${storage_share:-} ]] || fail '平铺 SMB 必须仅保留完整相对 exportPath'
[[ $smb_password == 'pa%ss\word' ]] || fail 'SMB 密码中的 % 或反斜线被改变'
[[ $shutdown == false && $changeHostname == false ]] || fail 'JSON false 被当作缺失'
export -p | grep -q 'smb_\(username\|password\|domain\)' && fail 'SMB 凭据不得导出到子进程环境'
[[ $captureBackupName == demo-backup-20260830T104527123Z ]] || fail 'capture backup name 未从认证 JSON 保留'
unicode_backup_name='Rocky中文-backup-20260830T104527123Z'
unicode_capture=$(jq --arg name "$unicode_backup_name" '.captureBackupName=$name' <<<"$flat_smb")
rootpxe_apply_json_checkin "$unicode_capture" || fail 'UTF-8 capture backup name 被认证 JSON 拒绝'
[[ $captureBackupName == "$unicode_backup_name" ]] || fail 'UTF-8 capture backup name 未原样保留'
too_long_backup_name=$(printf 'a%.0s' {1..256})
too_long_capture=$(jq --arg name "$too_long_backup_name" '.captureBackupName=$name' <<<"$flat_smb")
rootpxe_apply_json_checkin "$too_long_capture" && fail '超过 255 UTF-8 字节的备份名称被接受'
unset unicode_backup_name unicode_capture too_long_backup_name too_long_capture

# Two deploy scripts are authenticated independently. Both must retain exact
# multiline bytes in separate 0700 files; capture and legacy never receive
# either field.
pre_script=$'printf "%s\\n" pre\n'
post_script=$'printf "%s\\n" post\n'
pre_expected_file="$tmp/pre.expected"; post_expected_file="$tmp/post.expected"
jq -nj --arg script "$pre_script" '$script' >"$pre_expected_file"
jq -nj --arg script "$post_script" '$script' >"$post_expected_file"
pre_hash=$(sha256sum "$pre_expected_file" | awk '{print $1}')
post_hash=$(sha256sum "$post_expected_file" | awk '{print $1}')
deploy_with_scripts=$(jq -cn --arg pre "$pre_script" --arg pre_hash "$pre_hash" --arg post "$post_script" --arg post_hash "$post_hash" '{taskId:45,type:"deploy",pxeType:"down",img:"images/demo",imgType:"raw",imgPartitionType:"all",osid:50,imgFormat:5,compressionLevel:6,shutdown:false,protocol:"nfs",storageip:"192.0.2.13",exportPath:"/dept/images",preDeployScript:$pre,preDeployScriptSha256:$pre_hash,postDeployScript:$post,postDeployScriptSha256:$post_hash}')
rootpxe_apply_json_checkin "$deploy_with_scripts" || fail '认证部署双脚本 JSON 被拒绝'
[[ -f ${preDeployScriptFile:-} && ! -L $preDeployScriptFile && -f ${postDeployScriptFile:-} && ! -L $postDeployScriptFile ]] || fail '部署脚本未保存到独立临时文件'
cmp -s "$pre_expected_file" "$preDeployScriptFile" && [[ $preDeployScriptSha256 == "$pre_hash" ]] || fail '部署前脚本正文或 SHA256 被改变'
cmp -s "$post_expected_file" "$postDeployScriptFile" && [[ $postDeployScriptSha256 == "$post_hash" ]] || fail '部署后脚本正文或 SHA256 被改变'
rm -f -- "$preDeployScriptFile" "$postDeployScriptFile"; unset preDeployScriptFile preDeployScriptSha256 postDeployScriptFile postDeployScriptSha256
missing_pre_hash=$(jq 'del(.preDeployScriptSha256)' <<<"$deploy_with_scripts")
missing_post_hash=$(jq 'del(.postDeployScriptSha256)' <<<"$deploy_with_scripts")
nonstring_pre=$(jq '.preDeployScript=42' <<<"$deploy_with_scripts")
nonstring_post_hash=$(jq '.postDeployScriptSha256=42' <<<"$deploy_with_scripts")
empty_both=$(jq '.preDeployScript="" | .preDeployScriptSha256="" | .postDeployScript="" | .postDeployScriptSha256=""' <<<"$deploy_with_scripts")
rootpxe_apply_json_checkin "$missing_pre_hash" && fail '缺少部署前脚本摘要被接受'
rootpxe_apply_json_checkin "$missing_post_hash" && fail '缺少部署后脚本摘要被接受'
rootpxe_apply_json_checkin "$nonstring_pre" && fail '非文本部署前脚本被接受'
rootpxe_apply_json_checkin "$nonstring_post_hash" && fail '非文本部署后脚本摘要被接受'
rootpxe_apply_json_checkin "$empty_both" || fail '空部署脚本对被拒绝'
[[ -z ${preDeployScriptFile:-} && -z ${postDeployScriptFile:-} ]] || fail '空部署脚本仍创建临时文件'
bad_hash=$(printf '0%.0s' {1..64})
bad_pre_hash=$(jq --arg hash "$bad_hash" '.preDeployScriptSha256=$hash' <<<"$deploy_with_scripts")
bad_post_hash=$(jq --arg hash "$bad_hash" '.postDeployScriptSha256=$hash' <<<"$deploy_with_scripts")
rootpxe_apply_json_checkin "$bad_pre_hash" && fail '错误部署前脚本摘要被接受'
rootpxe_apply_json_checkin "$bad_post_hash" && fail '错误部署后脚本摘要被接受'
jq() {
    case "$*" in
        *'has($field)'*) printf 'true\n' ;;
        *'type == "string"'*) return 0 ;;
        *utf8bytelength*) printf '65537\n' ;;
        *) return 1 ;;
    esac
}
rootpxe_apply_json_deploy_script '{}' preDeployScript preDeployScriptSha256 preDeployScriptFile preDeployScriptSha256 pre-deploy && fail '超过 64 KiB 的部署前脚本被接受'
rootpxe_apply_json_deploy_script '{}' postDeployScript postDeployScriptSha256 postDeployScriptFile postDeployScriptSha256 post-deploy && fail '超过 64 KiB 的部署后脚本被接受'
unset -f jq
capture_with_script=$(jq '.preDeployScript="echo unsafe" | .preDeployScriptSha256="0000000000000000000000000000000000000000000000000000000000000000"' <<<"$flat_smb")
rootpxe_apply_json_checkin "$capture_with_script" && fail 'capture JSON 部署前脚本字段被接受'
capture_with_script=$(jq '.postDeployScript="echo unsafe" | .postDeployScriptSha256="0000000000000000000000000000000000000000000000000000000000000000"' <<<"$flat_smb")
rootpxe_apply_json_checkin "$capture_with_script" && fail 'capture JSON 部署后脚本字段被接受'
unset pre_expected_file post_expected_file missing_pre_hash missing_post_hash nonstring_pre nonstring_post_hash empty_both bad_hash bad_pre_hash bad_post_hash capture_with_script

# Both scripts run only in clean child environments and always delete their
# independent temporary files.
(
awk '/^rootpxe_run_deploy_script\(\)/ { on=1 } /^# LVM v2/ { on=0 } on { print }' "$funcs" >"$tmp/deploy-scripts-run.sh"
. "$tmp/deploy-scripts-run.sh"
mkdir -p "$tmp/deploy-script-image"
pre_exec="$tmp/pre-exec.sh"; post_exec="$tmp/post-exec.sh"
cat >"$pre_exec" <<'EOF'
printf '%s|%s|%s|%s|%s\n' "$ROOTPXE_TASK_ID" "$ROOTPXE_IMAGE_PATH" "$ROOTPXE_TARGET_DISK" "$ROOTPXE_HOSTNAME" "$ROOTPXE_OS_ID" >"$ROOTPXE_IMAGE_PATH/pre.trace"
[[ -z ${task_token+x} ]]
EOF
cat >"$post_exec" <<'EOF'
printf '%s|%s|%s|%s|%s\n' "$ROOTPXE_TASK_ID" "$ROOTPXE_IMAGE_PATH" "$ROOTPXE_TARGET_DISK" "$ROOTPXE_HOSTNAME" "$ROOTPXE_OS_ID" >"$ROOTPXE_IMAGE_PATH/post.trace"
[[ -z ${task_token+x} ]]
EOF
taskid=45; task_token=must-not-reach-script; imagePath="$tmp/deploy-script-image"; hd=/dev/mockdisk; hostName=demo-host; osid=50
preDeployScriptFile="$pre_exec"; preDeployScriptSha256=$(sha256sum "$pre_exec" | awk '{print $1}')
postDeployScriptFile="$post_exec"; postDeployScriptSha256=$(sha256sum "$post_exec" | awk '{print $1}')
rootpxe_stage() { :; }
rootpxe_console_message() { :; }
rootpxe_run_pre_deploy_script || fail '部署前脚本执行失败'
rootpxe_run_post_deploy_script || fail '部署后脚本执行失败'
[[ $(<"$tmp/deploy-script-image/pre.trace") == "45|$tmp/deploy-script-image|/dev/mockdisk|demo-host|50" ]] || fail '部署前脚本未获得受限环境变量'
[[ $(<"$tmp/deploy-script-image/post.trace") == "45|$tmp/deploy-script-image|/dev/mockdisk|demo-host|50" ]] || fail '部署后脚本未获得受限环境变量'
[[ ! -e $pre_exec && ! -e $post_exec && -z ${preDeployScriptFile:-} && -z ${postDeployScriptFile:-} ]] || fail '部署脚本成功后未清理临时文件'
post_fail="$tmp/post-fail.sh"
printf 'exit 7\n' >"$post_fail"
postDeployScriptFile="$post_fail"; postDeployScriptSha256=$(sha256sum "$post_fail" | awk '{print $1}')
rootpxe_run_post_deploy_script && fail '失败的部署后脚本被误报成功'
[[ ${rootpxe_deploy_script_error:-} == script_execution_failed && ! -e $post_fail ]] || fail '失败的部署后脚本未清理或未标记失败'
unset pre_exec post_exec post_fail
)

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

json_checkin_body='{"taskId":49,"executionToken":"0123456789abcdef","type":"capture","pxeType":"up","img":"images/demo","imgType":"raw","imgPartitionType":"all","osid":9,"imgFormat":5,"compressionLevel":6,"shutdown":false,"captureBackupName":"demo-backup-20260830T104527123Z","storage":"192.0.2.20:share/images","protocol":"smb","storageip":"192.0.2.20","exportPath":"share/images","smbUsername":"json-user","smbPassword":"json-pass"}'
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
preDeployScriptFile="$tmp/inherited-pre-script"; preDeployScriptSha256=$(printf '0%.0s' {1..64})
postDeployScriptFile="$tmp/inherited-post-script"; postDeployScriptSha256=$(printf '1%.0s' {1..64})
legacy_checkin_rc=0
checkin_rootpxe || legacy_checkin_rc=$?
# checkin_rootpxe installs its runtime session-cleanup trap.  Restore the
# fixture cleanup even when the mocked legacy response is rejected.
trap 'rm -rf "$tmp"' EXIT INT TERM
[[ $legacy_checkin_rc -eq 0 ]] || fail 'legacy checkin 响应被拒绝'
[[ $protocol == nfs && $storage_server == 192.0.2.20 && $storage_export == /legacy ]] || fail 'legacy NFS 协议或 export 解析错误'
[[ -z ${preDeployScriptFile:-} && -z ${preDeployScriptSha256:-} && -z ${postDeployScriptFile:-} && -z ${postDeployScriptSha256:-} ]] || fail 'legacy checkin must not retain deploy scripts'
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

awk '/^rootpxe_error_response_reason\(\)/ { on=1 } /^rootpxe_directory_size_bytes\(\)/ { on=0 } on { print }' "$funcs" \
    | sed "s|/tmp/pxeos.failure_action|$tmp/pxeos.failure_action|g" >"$tmp/error-stage.sh"
rootpxe_require_task_context() { return 0; }
rootpxe_console_message() { :; }
sleep() { :; }
test_error_stage_field() {
    local message="$1" expected_stage="${2:-}" trace="$tmp/error-stage.trace" calls_file="$tmp/error-stage.calls" calls
    : >"$trace"
    printf '0\n' >"$calls_file"
    curl() {
        calls=$(<"$calls_file")
        calls=$((calls + 1))
        printf '%s\n' "$calls" >"$calls_file"
        printf '%s\n' "$@" >>"$trace"
        if [[ $calls -eq 1 ]]; then
            printf '%s\n' '{"accepted":true,"waitSec":60,"failureAction":"reboot"}' 200
        else
            printf '%s\n' '{"status":"deleted"}'
        fi
    }
    taskid=77; task_token=0123456789abcdef; mac=001122334455; pxeapi='http://mock/service/'
    rootpxe_error_wait_for_retry "$message" TEST_ERROR || [[ $? -eq 2 ]] || fail 'error retry fixture did not pause safely'
    if [[ -n $expected_stage ]]; then
        grep -Fqx "stage=$expected_stage" "$trace" || fail 'safe resume stage was not submitted as an independent form field'
    else
        ! grep -Fq 'stage=' "$trace" || fail 'unsafe or ambiguous resume stage was submitted'
    fi
}
. "$tmp/error-stage.sh"
test_error_stage_field 'PXEOS_STAGE=post_deploy_script CODE=POST_DEPLOY_SCRIPT_FAILED' post_deploy_script
test_error_stage_field 'PXEOS_STAGE=customizing_hostname CODE=HOSTNAME_FAILED' customizing_hostname
test_error_stage_field 'PXEOS_STAGE=untrusted CODE=FAIL' ''
test_error_stage_field 'PXEOS_STAGE=pre_deploy_script CODE=PRE_DEPLOY_SCRIPT_FAILED' ''
test_error_stage_field 'PXEOS_STAGE=post_deploy_script PXEOS_STAGE=untrusted CODE=FAIL' ''
test_error_stage_field $'PXEOS_STAGE=post_deploy_script\nPXEOS_STAGE=customizing_hostname CODE=FAIL' ''

# A server rejection must expose only the HTTP status and its controlled error
# field.  Full payloads can contain request correlation data and must never be
# rendered on the PXEOS console.
error_report_output="$tmp/error-report-diagnostic.out"
error_report_calls="$tmp/error-report-diagnostic.calls"
printf '0\n' >"$error_report_calls"
rootpxe_console_message() { printf '[%s]  %s\n' "$1" "$2" >>"$error_report_output"; }
curl() {
    calls=$(<"$error_report_calls")
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$error_report_calls"
    case $calls in
        1) printf '%s\n' '{"accepted":false,"error":"server rejected","token":"server-secret","detail":"hidden"}' 409 ;;
        2) printf '%s\n' '{"accepted":true,"waitSec":60,"failureAction":"reboot"}' 200 ;;
        *) printf '%s\n' '{"status":"deleted"}' ;;
    esac
}
taskid=77; task_token=0123456789abcdef; mac=001122334455; pxeapi='http://mock/service/'
set +e
rootpxe_error_wait_for_retry 'capture failed' TEST_ERROR >>"$error_report_output" 2>&1
error_report_status=$?
set -e
[[ $error_report_status -eq 2 ]] || fail 'error diagnostic fixture did not pause safely'
grep -Fqx '[WARN]  Error report rejected (HTTP 409): server rejected. Retrying in 5s.' "$error_report_output" \
    || fail 'error report rejection must include the HTTP status and controlled error'
! grep -Fq 'server-secret' "$error_report_output" || fail 'error report response leaked a sensitive server field'
! grep -Fq 'hidden' "$error_report_output" || fail 'error report response leaked an uncontrolled server field'
unset -f curl
unset -f curl sleep rootpxe_require_task_context rootpxe_console_message test_error_stage_field

printf 'PASS: PXEOS real-jq JSON checkin regression\n'
)
# ===== 原脚本结束：tests/pxeos_checkin_json_regression.sh =====

# ===== 原脚本：tests/pxeos_business_regression.sh =====
(
# Only temporary mocks are used; no host disk or network is touched.
set -euo pipefail
root=$(cd $(dirname $0)/.. && pwd)
overlay=$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay
funcs=$overlay/usr/share/pxeos/lib/funcs.sh
checkin=$overlay/bin/pxeos.checkin
download=$overlay/bin/pxeos.download
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -Fq rootpxe_normalize_compression_level "$checkin" || fail parser
grep -Fq rootpxe_find_windows_system_partition "$funcs" || fail selector
grep -Fq 'rootpxe_apply_hostname_for_disk "$hd"' "$funcs" || fail complete-hostname-dispatch
grep -Fq RESUME_TARGET_IDENTITY_UNAVAILABLE "$download" || fail resume
# 单盘可调整布局必须在申请磁盘许可、擦盘和最终 sfdisk 写入之前先校验
# 真实目标容量；避免小于捕获盘的目标盘被触及。
pre_layout_validation_line=$(grep -n 'pre_permit_validation_failed' "$download" | head -n 1 | cut -d: -f1)
permit_line=$(grep -n 'rootpxe_wait_for_disk_permit "$rootpxe_planned_target_id"' "$download" | head -n 1 | cut -d: -f1)
prepare_line=$(grep -n 'Skipping partition layout: single-partition restore.' "$download" | head -n 1 | cut -d: -f1)
apply_layout_line=$(grep -n 'rootpxe_apply_deployment_layout' "$download" | head -n 1 | cut -d: -f1)
[[ $pre_layout_validation_line =~ ^[1-9][0-9]*$ && $permit_line =~ ^[1-9][0-9]*$ && $prepare_line =~ ^[1-9][0-9]*$ && $apply_layout_line =~ ^[1-9][0-9]*$ && $pre_layout_validation_line -lt $permit_line && $permit_line -lt $prepare_line && $prepare_line -lt $apply_layout_line ]] || fail layout-capacity-validation-must-precede-permit-and-write
grep -Fq 'CODE=${rootpxe_layout_apply_code:-LAYOUT_APPLY_FAILED}' "$download" || fail layout-apply-must-report-real-stage-code
! grep -Fq 'CODE=LAYOUT_READBACK_FAILED REASON=sfdisk_layout_mismatch' "$download" || fail layout-apply-must-not-misreport-all-failures-as-readback

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p $tmp/mock $tmp/ntfs
REAL_JQ=$(command -v jq) || fail '需要真实 jq 来验证部署分区表重写'
export REAL_JQ
: >$tmp/jq-args
export JQ_ARGS_LOG=$tmp/jq-args
cat >$tmp/mock/jq <<'EOF'
#!/usr/bin/env bash
if [[ ${MODE:-} == layout_apply ]]; then
  exec "${REAL_JQ:?}" "$@"
fi
case "$*" in
  *'-cS '*)
    for last; do :; done
    cat "$last"
    exit 0 ;;
  *'--rawfile rows'*)
    if [[ ${SCHEMA_KIND:-} == mbr-v2 ]]; then
      echo '{"version":2,"partitionTable":"mbr","originalDiskBytes":102400000,"logicalSectorBytes":512,"physicalSectorBytes":512,"minDeployBytes":3145728,"partitions":[{"number":1,"startSectors":2048,"originalSectors":8192,"minSectors":3976,"typeGuid":"0x5","flags":[],"role":"extended_container","resizable":false,"fs":"","uuid":"","partuuid":"","artifact":"","kind":"extended","logicalNumbers":[5,6],"ebrReservedSectors":2},{"number":5,"startSectors":2050,"originalSectors":2048,"minSectors":2048,"typeGuid":"0x83","flags":[],"role":"data","resizable":true,"fs":"ntfs","uuid":"swap-uuid","partuuid":"swap-partuuid","artifact":"d1p5.img","kind":"logical","parentNumber":1},{"number":6,"startSectors":5000,"originalSectors":1024,"minSectors":1024,"typeGuid":"0x82","flags":[],"role":"swap","resizable":false,"fs":"swap","uuid":"swap-uuid","partuuid":"swap-partuuid","artifact":"","kind":"logical","parentNumber":1}]}'
    elif [[ $BLKTYPE == swap ]]; then echo '{"version":1,"partitionTable":"mbr","originalDiskBytes":102400000,"logicalSectorBytes":512,"physicalSectorBytes":512,"minDeployBytes":1572864,"partitions":[{"number":2,"startSectors":2048,"originalSectors":1024,"minSectors":1024,"typeGuid":"82","flags":[],"role":"swap","resizable":false,"fs":"swap","uuid":"swap-uuid","partuuid":"swap-partuuid","artifact":""}]}' ; else echo '{}' ; fi
    exit 0 ;;
  *'-n '*) echo "$*" >>$JQ_ARGS_LOG; echo '[]'; exit 0 ;;
  *'type == "object"'*) exit 0 ;;
  *'.deploymentLayout != null'*|*'.originalSchema != null'*) exit 1 ;;
  *'role == "other"'*) exit 0 ;;
  *'.wait'*) echo false ;;
  *'.message'*) echo ok ;;
  *'retryAfterSec'*) echo 5 ;;
  *'.error'*) exit 0 ;;
  *'taskId'*) echo 42 ;;
  *'executionToken'*) echo token ;;
  *'.type'*) echo deploy ;;
  *'pxeType'*) echo down ;;
  *'.mac'*) echo 00:11:22:33:44:55 ;;
  *'imagePath'*) echo images/demo ;;
  *'imgType'*) echo n ;;
  *'imgPartitionType'*) echo all ;;
  *'.osid'*) echo 9 ;;
  *'imgFormat'*) echo 5 ;;
  *'compressionLevel'*) echo $COMP ;;
  *'.shutdown'*) echo 0 ;;
  *'.storage.protocol'*) echo smb ;;
  *'.storage.server'*) echo server ;;
  *'.storage.export'*|*'.storage.share'*) echo storage ;;
  *'smb.username'*) echo user ;;
  *'smb.password'*) echo password ;;
  *'smb.domain'*) echo WORKGROUP ;;
  *'hostName'*) echo PXEHOST ;;
  *'changeHostname'*) echo true ;;
  *'resumeStage'*) echo customizing_hostname ;;
  *'schemaRevision'*) echo 2 ;;
  *'.schemaHash // empty'*) echo $SCHEMAHASH ;;
  *'schemaHash'*) echo hash ;;
  *'.logicalSectorBytes'*) echo $SCHEMA_SECTOR ;;
  *'.originalDiskBytes'*) echo ${SCHEMA_ORIGINAL:-102400000} ;;
  *) cat ;;
esac
EOF
cat >$tmp/mock/blockdev <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --getss) echo ${TEST_SECTOR:-512} ;;
  --getpbsz) echo 512 ;;
  --getsize64)
    [[ ${MODE:-} == layout_apply ]] && echo ${TARGET_BYTES:-409600000} || echo 102400000
    ;;
  --rereadpt)
    if [[ -n ${LAYOUT_PARTPROBE_TRACE:-} ]]; then
        printf 'rereadpt:%s\n' "$2" >>"$LAYOUT_PARTPROBE_TRACE"
        attempts=$(wc -l <"$LAYOUT_PARTPROBE_TRACE")
        [[ $attempts -le ${LAYOUT_PARTPROBE_FAILS:-0} ]] && exit 1
    fi
    exit ${LAYOUT_PARTPROBE_STATUS:-0}
    ;;
  *) exit 1 ;;
esac
EOF
cat >$tmp/mock/udevadm <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == settle ]] || exit 1
exit ${LAYOUT_UDEVADM_STATUS:-0}
EOF
cat >$tmp/mock/sleep <<'EOF'
#!/usr/bin/env bash
printf 'sleep:%s\n' "$1" >>"$LAYOUT_SLEEP_TRACE"
EOF
cat >$tmp/mock/flock <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat >$tmp/mock/sfdisk <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -d ]]; then
    shift
    case ${LAYOUT_SFDISK_MODE:-canonical} in
        dump_fail) printf 'mock sfdisk dump failure\n' >&2; exit 43 ;;
        canonical)
            sed -E \
                -e '/^label-id:/ s/[A-F]/\L&/g' \
                -e '/start=/ s/(type|uuid)=([0-9A-F-]+)/\1=\L\2/g' \
                "$LAYOUT_APPLIED"
            ;;
        header_geometry) sed 's/^device: .*/device: \/dev\/wrong/' "$LAYOUT_APPLIED" ;;
        partition_numbers) sed '/p2 : start=/d; /sda2 : start=/d' "$LAYOUT_APPLIED" ;;
        partition_geometry) sed -E '0,/size=[[:space:]]*[0-9]+/s//size=        1023/' "$LAYOUT_APPLIED" ;;
        semantic_identity) sed 's/name="root data"/name="wrong partition"/' "$LAYOUT_APPLIED" ;;
        *) exit 44 ;;
    esac
    exit 0
fi
[[ -z ${LAYOUT_SFDISK_ARGS:-} ]] || printf '%s\n' "$*" >>"$LAYOUT_SFDISK_ARGS"
case ${LAYOUT_SFDISK_MODE:-canonical} in
    write_fail) printf 'mock sfdisk write failure\n' >&2; exit 42 ;;
esac
cat >"$LAYOUT_APPLIED"
EOF
cat >$tmp/mock/blkid <<'EOF'
#!/usr/bin/env bash
for last; do :; done
if [[ ${MODE:-} == linux_lvm && $last == /dev/vg0/root ]]; then
    case " $* " in *' TYPE '*) echo ext4 ;; esac
    exit 0
fi
case " $* " in *' TYPE '*) echo "$BLKTYPE" ;; *' UUID '*) echo swap-uuid ;; *' PARTUUID '*) echo swap-partuuid ;; esac
EOF
cat >$tmp/mock/ntfs-3g <<'EOF'
#!/usr/bin/env bash
part=$3
mount=$4
rm -rf "$mount"
mkdir -p "$mount"
if [[ ($MODE == unique && $part == /dev/mock2) || $MODE == ambiguous || (($MODE == hostname_xml || $MODE == hostname_absent || $MODE == hostname_invalid) && $part == /dev/mock2) ]]; then
    mkdir -p "$mount/Windows/System32/config"
    : >"$mount/Windows/System32/config/SYSTEM"
fi
if [[ $MODE == hostname_xml || $MODE == hostname_invalid ]]; then
    mkdir -p "$mount/Windows/System32/Sysprep"
    if [[ $MODE == hostname_invalid ]]; then
        printf '<unattend>invalid' >"$mount/Windows/System32/Sysprep/unattend.xml"
    else
        printf '<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup"><ComputerName>OLD</ComputerName></component></settings></unattend>' >"$mount/Windows/System32/Sysprep/unattend.xml"
    fi
fi
EOF
cat >$tmp/mock/umount <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >$tmp/mock/mount <<'EOF'
#!/usr/bin/env bash
device=${@: -2:1}
mount=${!#}
printf '%s\n' "$*" >>$MOUNT_TRACE
rm -rf "$mount"
mkdir -p "$mount"
make_linux_root() {
    mkdir -p "$mount/etc" "$mount/usr/lib"
    printf 'PXE-OLD\n' >"$mount/etc/hostname"
    printf '127.0.1.1 PXE-OLD old.example\n10.0.0.1 PXE-OLD.example\n# PXE-OLD comment\n' >"$mount/etc/hosts"
    printf 'NAME=mock\n' >"$mount/etc/os-release"
}
case ${MODE:-} in
    linux_ext|linux_readback_fail|linux_symlink)
        [[ $device == /dev/mockroot ]] && make_linux_root
        ;;
    linux_new_hostname)
        [[ $device == /dev/mockroot ]] && { make_linux_root; rm -f "$mount/etc/hostname"; }
        ;;
    linux_relative_osrelease)
        [[ $device == /dev/mockroot ]] && { make_linux_root; rm -f "$mount/etc/os-release"; printf 'NAME=mock\n' >"$mount/usr/lib/os-release"; ln -s ../usr/lib/os-release "$mount/etc/os-release"; }
        ;;
    linux_lvm)
        [[ $device == /dev/vg0/root ]] && make_linux_root
        ;;
    linux_multiple)
        [[ $device == /dev/mockroot || $device == /dev/mockroot2 ]] && make_linux_root
        ;;
esac
if [[ ${MODE:-} == linux_symlink && -d $mount/etc ]]; then
    rm -f "$mount/etc/hostname"
    ln -s /etc/hostname "$mount/etc/hostname"
fi
EOF
cat >$tmp/mock/pvs <<'EOF'
#!/usr/bin/env bash
if [[ ${MODE:-} == linux_lvm || ${MODE:-} == linux_lvm_all_active || ${MODE:-} == linux_lvm_mixed ]]; then
    case " $* " in
        *'pv_name,vg_uuid'*) printf ' /dev/mockpv vg-uuid-0\n' ;;
        *) printf ' /dev/mockpv vg0 vg-uuid-0\n' ;;
    esac
elif [[ ${MODE:-} == linux_lvm_external ]]; then
    case " $* " in
        *'pv_name,vg_uuid'*) printf ' /dev/mockpv vg-uuid-0\n /dev/externalpv vg-uuid-0\n' ;;
        *) printf ' /dev/mockpv vg0 vg-uuid-0\n /dev/externalpv vg0 vg-uuid-0\n' ;;
    esac
fi
EOF
cat >$tmp/mock/lvs <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *'lv_active'*)
        case ${MODE:-} in
            linux_lvm_all_active) printf ' active\n active\n' ;;
            linux_lvm_mixed) printf ' active\n inactive\n' ;;
            *) printf ' inactive\n inactive\n' ;;
        esac
        ;;
    *'lv_path'*) [[ ${MODE:-} == linux_lvm ]] && printf ' /dev/vg0/root\n' ;;
esac
EOF
cat >$tmp/mock/vgchange <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>$LVM_TRACE
EOF
cat >$tmp/mock/cat <<'EOF'
#!/usr/bin/env bash
if [[ ${MODE:-} == linux_readback_fail && $# -eq 1 && $1 == */linuxroot/etc/hostname ]]; then
    printf 'WRONG\n'
    exit 0
fi
exec /bin/cat "$@"
EOF
cat >$tmp/mock/chmod <<'EOF'
#!/usr/bin/env bash
printf 'chmod:%s\n' "$*" >>$HOSTMODE_TRACE
EOF
cat >$tmp/mock/chown <<'EOF'
#!/usr/bin/env bash
printf 'chown:%s\n' "$*" >>$HOSTMODE_TRACE
EOF
cat >$tmp/mock/xmlstarlet <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' count('* )
    [[ ${MODE:-} == hostname_invalid ]] && exit 1
    echo 1 ;;
  *' string('* )
    for last; do :; done
    grep -Fq PXEHOST "$last" && echo PXEHOST ;;
  *' ed '*)
    for last; do :; done
    printf '<updated>PXEHOST</updated>' >"$last" ;;
  *) exit 1 ;;
esac
EOF
chmod +x $tmp/mock/*
sed -e "s|^\. /usr/share/pxeos/lib/partition-funcs.sh|. \"$overlay/usr/share/pxeos/lib/partition-funcs.sh\"|" -e "s|</proc/cmdline|<$tmp/cmdline|" -e "s|/ntfs/|$tmp/ntfs/|g" -e "s| /ntfs\([ ;)]\)| $tmp/ntfs\1|g" -e "s|mountpoint=/linuxroot|mountpoint=$tmp/linuxroot|g" -e "s|/linuxroot/|$tmp/linuxroot/|g" -e "s| /linuxroot\([ ;)]\)| $tmp/linuxroot\1|g" $funcs >$tmp/funcs.sh
: >$tmp/cmdline
: >$tmp/mount-trace
MOUNT_TRACE=$tmp/mount-trace; export MOUNT_TRACE
: >$tmp/hostmode-trace
HOSTMODE_TRACE=$tmp/hostmode-trace; export HOSTMODE_TRACE
export PATH=$tmp/mock:$PATH
ismajordebug=0
isdebug=0
. $tmp/funcs.sh
rootpxe_require_task_context() { return 0; }
rootpxe_require_identity() { return 0; }

# n no longer has a legacy deployment path.  The required snapshot files are
# checked before disk permission and the old table/fill preparation is never
# reached; mps remains on its historical preparation branch.
layout_contract_dir=$tmp/n-layout-contract; mkdir -p $layout_contract_dir
printf 'label: gpt\n' >$layout_contract_dir/d1.partitions
printf '{"partitionTable":"gpt","partitions":[{"startSectors":8}]}\n' >$layout_contract_dir/schema.json
printf '{"partitions":[]}\n' >$layout_contract_dir/layout.json
rootpxe_require_single_disk_layout_metadata "$layout_contract_dir/d1.partitions" "$layout_contract_dir/schema.json" "$layout_contract_dir/layout.json" || fail n-layout-metadata-present
rm -f $layout_contract_dir/d1.partitions
rootpxe_require_single_disk_layout_metadata "$layout_contract_dir/d1.partitions" "$layout_contract_dir/schema.json" "$layout_contract_dir/layout.json" && fail n-layout-partition-table-missing-must-reject
[[ $rootpxe_layout_metadata_reason == partition_table_missing ]] || fail n-layout-partition-table-missing-reason
printf 'label: gpt\n' >$layout_contract_dir/d1.partitions
rm -f $layout_contract_dir/schema.json
rootpxe_require_single_disk_layout_metadata "$layout_contract_dir/d1.partitions" "$layout_contract_dir/schema.json" "$layout_contract_dir/layout.json" && fail n-layout-original-schema-missing-must-reject
[[ $rootpxe_layout_metadata_reason == original_schema_missing ]] || fail n-layout-original-schema-missing-reason
printf '{"partitionTable":"gpt","partitions":[{"startSectors":8}]}\n' >$layout_contract_dir/schema.json
rm -f $layout_contract_dir/layout.json
rootpxe_require_single_disk_layout_metadata "$layout_contract_dir/d1.partitions" "$layout_contract_dir/schema.json" "$layout_contract_dir/layout.json" && fail n-layout-metadata-missing-must-reject
[[ $rootpxe_layout_metadata_reason == deployment_layout_missing ]] || fail n-layout-metadata-reason
printf '{"partitions":[]}\n' >$layout_contract_dir/layout.json

# The final sfdisk write owns the partition table.  Only the first 440-byte
# boot-code region may be restored afterwards; partition entries and GPT/MBR
# metadata must remain the target-specific layout just applied.
printf 'A%.0s' {1..512} >$layout_contract_dir/d1.grub.mbr
printf 'B%.0s' {1..512} >$layout_contract_dir/target-disk
MODE=layout_apply; export MODE
rootpxe_restore_deployment_boot_code "$layout_contract_dir/target-disk" 1 "$layout_contract_dir" "$layout_contract_dir/schema.json" || fail n-layout-boot-code
head -c 440 $layout_contract_dir/target-disk | tr -d A | grep -q . && fail n-layout-boot-code-prefix
tail -c +441 $layout_contract_dir/target-disk | tr -d B | grep -q . && fail n-layout-boot-code-must-not-overwrite-partition-table

# GPT dN.mbr is an sgdisk backup, not raw boot code.  Without the separate
# dN.grub.mbr artifact, deployment must leave the target's protective MBR and
# GPT metadata untouched.
rm -f $layout_contract_dir/d1.grub.mbr
printf 'C%.0s' {1..512} >$layout_contract_dir/d1.mbr
printf 'B%.0s' {1..512} >$layout_contract_dir/target-disk
rootpxe_restore_deployment_boot_code "$layout_contract_dir/target-disk" 1 "$layout_contract_dir" "$layout_contract_dir/schema.json" || fail n-layout-gpt-backup-must-skip
tr -d B <$layout_contract_dir/target-disk | grep -q . && fail n-layout-gpt-backup-must-not-write

# DOS/MBR dN.mbr is a raw capture.  Restore its boot-code bytes while keeping
# the final sfdisk partition entries and signature (bytes 440-511) untouched.
printf '{"partitionTable":"mbr","partitions":[{"startSectors":8}]}\n' >$layout_contract_dir/schema.json
printf 'C%.0s' {1..512} >$layout_contract_dir/d1.mbr
printf 'B%.0s' {1..512} >$layout_contract_dir/target-disk
rootpxe_restore_deployment_boot_code "$layout_contract_dir/target-disk" 1 "$layout_contract_dir" "$layout_contract_dir/schema.json" || fail n-layout-mbr-boot-code
head -c 440 $layout_contract_dir/target-disk | tr -d C | grep -q . && fail n-layout-mbr-boot-code-prefix
tail -c +441 $layout_contract_dir/target-disk | tr -d B | grep -q . && fail n-layout-mbr-boot-code-must-not-overwrite-partition-table

# A captured DOS GRUB marker permits restoring only the embedding area between
# the final MBR and the first partition; it must not spill into final partition
# data or the 440-511 byte partition-table/signature region.
printf '{"partitionTable":"mbr","partitions":[{"startSectors":16}]}\n' >$layout_contract_dir/schema.json
: >$layout_contract_dir/d1.has_grub
printf 'C%.0s' {1..8192} >$layout_contract_dir/d1.mbr
printf 'B%.0s' {1..16384} >$layout_contract_dir/target-disk
rootpxe_restore_deployment_boot_code "$layout_contract_dir/target-disk" 1 "$layout_contract_dir" "$layout_contract_dir/schema.json" || fail n-layout-mbr-grub-embedding
head -c 440 $layout_contract_dir/target-disk | tr -d C | grep -q . && fail n-layout-mbr-grub-prefix
dd if=$layout_contract_dir/target-disk bs=1 skip=440 count=72 2>/dev/null | tr -d B | grep -q . && fail n-layout-mbr-grub-must-preserve-partition-table
dd if=$layout_contract_dir/target-disk bs=1 skip=512 count=7680 2>/dev/null | tr -d C | grep -q . && fail n-layout-mbr-grub-embedding-area
tail -c +8193 $layout_contract_dir/target-disk | tr -d B | grep -q . && fail n-layout-mbr-grub-must-not-overwrite-first-partition
rm -f $layout_contract_dir/d1.has_grub
unset MODE

awk '/^preparePartitions\(\)/ { on=1 } /^putDataBack\(\)/ { on=0 } on { print }' "$download" >$tmp/download-prepare.sh
. $tmp/download-prepare.sh
PREPARE_TRACE=$tmp/prepare-trace; : >$PREPARE_TRACE; export PREPARE_TRACE
rootpxe_console_message() { printf 'console:%s\n' "$2" >>$PREPARE_TRACE; }
prepareResizeDownloadPartitions() { printf 'legacy-resize\n' >>$PREPARE_TRACE; }
restorePartitionTablesAndBootLoaders() { printf 'legacy-table\n' >>$PREPARE_TRACE; }
runPartprobe() { printf 'partprobe\n' >>$PREPARE_TRACE; }
imgType=n; hd=/dev/mock; imagePath=$layout_contract_dir; osid=50; imgPartitionType=all
preparePartitions || fail n-layout-prepare
grep -Eq 'legacy-resize|legacy-table|partprobe' $PREPARE_TRACE && fail n-layout-must-not-run-legacy-partition-flow
: >$PREPARE_TRACE
imgType=mps; global_gptcheck=no
preparePartitions || fail mps-prepare
grep -Fqx legacy-table $PREPARE_TRACE || fail mps-legacy-partition-flow-must-remain
# Restore later mocks used by the broader business regression.
runPartprobe() { :; }
# The backend hashes the exact bytes of jq -cS output without its terminal
# newline. Pin a known canonical JSON value so an accidental printf newline
# changes this test's hash rather than silently drifting the task contract.
printf '{"a":1,"b":2}\n' >$tmp/canonical-schema.json
[[ $(rootpxe_canonical_json_hash $tmp/canonical-schema.json) == 43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777 ]] || fail canonical-schema-hash
awk '/^rootpxe_json_get_string\(/{on=1} /^checkin_rootpxe\(/{on=0} on' $checkin >$tmp/json.sh
. $tmp/json.sh
# JSON parser behavior is covered by pxeos_checkin_json_regression.sh with a
# real jq and real fixtures.  This broader disk-flow suite keeps jq mocked.
[[ $(rootpxe_normalize_compression_level 6) == -6 ]] || fail positive-compression
[[ $(rootpxe_normalize_compression_level -7) == -7 ]] || fail negative-compression
rootpxe_normalize_compression_level 23 >/dev/null && fail compression-range
rootpxe_validate_pigz_compression -10 2 && fail gzip-range

# The selected volume must have the fixed SYSTEM hive; an NTFS recovery
# partition occurring first is intentionally skipped.
getPartitions() { parts='/dev/mock1 /dev/mock2'; }
fsTypeSetting() { fstype=ntfs; }
MODE=unique; export MODE
[[ $(rootpxe_find_windows_system_partition /dev/mock) == /dev/mock2 ]] || fail recovery-before-windows
MODE=ambiguous; export MODE
rootpxe_find_windows_system_partition /dev/mock && fail ambiguous-windows

# Windows customization must update only the fixed Sysprep file.  Registry is
# a fallback solely when that file is absent; malformed XML must not fall back.
rootpxe_stage() { printf '%s\n' "$*" >>$tmp/hostname-stage; }
rootpxe_change_hostname_registry() { printf '%s\n' "$1" >>$tmp/registry; }
: >$tmp/registry
MODE=hostname_xml; export MODE
changeHostname=true; hostName=PXEHOST
rootpxe_apply_windows_hostname /dev/mock2 || fail unattend-update
grep -Fq PXEHOST $tmp/ntfs/Windows/System32/Sysprep/unattend.xml || fail unattend-readback
[[ ! -s $tmp/registry ]] || fail unattend-registry-fallback
MODE=hostname_absent; export MODE
rootpxe_apply_windows_hostname /dev/mock2 || fail registry-fallback
grep -Fqx /dev/mock2 $tmp/registry || fail registry-not-called
MODE=hostname_xml; export MODE
osid=9
rootpxe_apply_hostname_for_disk /dev/mock2 || fail windows-dispatch
registry_count=$(wc -l <$tmp/registry)
MODE=hostname_invalid; export MODE
set +e
(
    handleError() { exit 97; }
    rootpxe_apply_windows_hostname /dev/mock2
)
invalid_rc=$?
set -e
[[ $invalid_rc -eq 97 ]] || fail invalid-unattend-result
[[ $(wc -l <$tmp/registry) -eq $registry_count ]] || fail invalid-unattend-registry-fallback

# Linux uses the same deployment hostname contract, but discovers the one
# actual root filesystem rather than selecting a largest/first partition.
rootpxe_stage() { :; }
getPartitions() { parts='/dev/mockboot /dev/mockroot'; }
fsTypeSetting() {
    case $1 in
        /dev/mockboot) fstype=vfat ;;
        /dev/mockroot|/dev/mockroot2) fstype=ext4 ;;
        /dev/mockpv) fstype=LVM2_member ;;
        *) fstype=unknown ;;
    esac
}
: >$tmp/lvm-trace
LVM_TRACE=$tmp/lvm-trace; export LVM_TRACE
changeHostname=true; hostName=linux-node; osid=50
MODE=linux_ext; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-ext-hostname
grep -Fqx linux-node $tmp/linuxroot/etc/hostname || fail linux-hostname-write
grep -Fq '127.0.1.1 linux-node old.example' $tmp/linuxroot/etc/hosts || fail linux-hosts-token-replace
grep -Fq '10.0.0.1 PXE-OLD.example' $tmp/linuxroot/etc/hosts || fail linux-hosts-substring
grep -Fq '# PXE-OLD comment' $tmp/linuxroot/etc/hosts || fail linux-hosts-comment
[[ ! -s $tmp/lvm-trace ]] || fail linux-ordinary-vg-activation
[[ ! -s $tmp/hostmode-trace ]] || fail linux-existing-hostname-mode

: >$tmp/hostmode-trace
previous_umask=$(umask)
umask 077
MODE=linux_new_hostname; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-new-hostname
umask "$previous_umask"
grep -Fq "chmod:0644 $tmp/linuxroot/etc/hostname" $tmp/hostmode-trace || fail linux-new-hostname-mode
grep -Fq "chown:root:root $tmp/linuxroot/etc/hostname" $tmp/hostmode-trace || fail linux-new-hostname-owner

: >$tmp/mount-trace
fsTypeSetting() {
    case $1 in
        /dev/mockboot) fstype=vfat ;;
        /dev/mockroot) fstype=xfs ;;
        /dev/mockroot2) fstype=ext4 ;;
        /dev/mockpv) fstype=LVM2_member ;;
        *) fstype=unknown ;;
    esac
}
MODE=linux_ext; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-xfs-hostname
grep -Fq -- '-o ro,nouuid' $tmp/mount-trace || fail linux-xfs-readonly-nouuid
grep -Fq -- '-o rw,nouuid' $tmp/mount-trace || fail linux-xfs-readwrite-nouuid
fsTypeSetting() {
    case $1 in
        /dev/mockboot) fstype=vfat ;;
        /dev/mockroot|/dev/mockroot2) fstype=ext4 ;;
        /dev/mockpv) fstype=LVM2_member ;;
        *) fstype=unknown ;;
    esac
}

MODE=linux_relative_osrelease; export MODE
[[ $(rootpxe_find_linux_root_filesystem /dev/mockdisk) == /dev/mockroot'|'ext4'|'* ]] || fail linux-relative-osrelease

getPartitions() { parts='/dev/mockpv'; }
MODE=linux_lvm; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-lvm-hostname
grep -Fqx linux-node $tmp/linuxroot/etc/hostname || fail linux-lvm-write
[[ $(grep -Fc -- '-ay' $tmp/lvm-trace) -eq 2 ]] || fail linux-lvm-reactivate
[[ $(grep -Fc -- '-an' $tmp/lvm-trace) -eq 2 ]] || fail linux-lvm-cleanup

: >$tmp/lvm-trace
MODE=linux_lvm_all_active; export MODE
[[ $(rootpxe_linux_activate_vg_if_needed /dev/mockdisk vg0 vg-uuid-0) == no ]] || fail linux-lvm-all-active
[[ ! -s $tmp/lvm-trace ]] || fail linux-lvm-all-active-mutate
MODE=linux_lvm_mixed; export MODE
rootpxe_linux_activate_vg_if_needed /dev/mockdisk vg0 vg-uuid-0 && fail linux-lvm-mixed
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-lvm-mixed-root
[[ $? -eq 23 ]] || fail linux-lvm-mixed-root-code

getPartitions() { parts='/dev/mockroot /dev/mockroot2'; }
MODE=linux_multiple; export MODE
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-multiple-root
[[ $? -eq 21 ]] || fail linux-multiple-root-code
getPartitions() { parts='/dev/mockboot'; }
MODE=linux_none; export MODE
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-no-root
[[ $? -eq 20 ]] || fail linux-no-root-code

getPartitions() { parts='/dev/mockroot'; }
MODE=linux_readback_fail; export MODE
set +e
(
    handleError() { exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_readback_rc=$?
set -e
[[ $linux_readback_rc -eq 97 ]] || fail linux-readback-result

MODE=linux_symlink; export MODE
set +e
(
    handleError() { exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_symlink_rc=$?
set -e
[[ $linux_symlink_rc -eq 97 ]] || fail linux-symlink-result

getPartitions() { parts='/dev/mockpv'; }
MODE=linux_lvm_external; export MODE
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-external-vg
[[ $? -eq 22 ]] || fail linux-external-vg-code

set +e
(
    handleError() { printf '%s\n' "$1" >$tmp/linux-lvm-attention; exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_cross_disk_rc=$?
set -e
[[ $linux_cross_disk_rc -eq 97 ]] || fail linux-external-vg-attention-result
grep -Fqx 'PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_CROSS_DISK_LVM' $tmp/linux-lvm-attention || fail linux-external-vg-attention

MODE=linux_lvm_mixed; export MODE
set +e
(
    handleError() { printf '%s\n' "$1" >$tmp/linux-lvm-attention; exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_activation_rc=$?
set -e
[[ $linux_activation_rc -eq 97 ]] || fail linux-lvm-activation-attention-result
grep -Fqx 'PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_LVM_ACTIVATION_FAILED' $tmp/linux-lvm-attention || fail linux-lvm-activation-attention

# DOS extended/logical layouts generate Schema v2: the EBR container is a
# derived metadata record with no artifact, while logical image payloads keep
# their parent link.  A primary swap has no d1pN.img by design, but still
# produces a protected non-resizable fact.
logical=$tmp/logical; mkdir -p $logical; : >$logical/d1p5.img; : >$logical/d1p6.img
printf 'label: dos\n/dev/mock1 : start=2048, size=8192, type=5\n/dev/mock5 : start=2050, size=2048, type=83\n/dev/mock6 : start=5000, size=1024, type=82\n' >$logical/d1.partitions
BLKTYPE=ntfs; SCHEMA_KIND=mbr-v2; export BLKTYPE SCHEMA_KIND
rootpxe_build_original_schema /dev/mock $logical || fail mbr-logical-schema-v2
grep -Fq '"version":2' $rootpxe_original_schema_file || fail mbr-logical-schema-version
grep -Fq '"role":"extended_container"' $rootpxe_original_schema_file || fail mbr-container-role
grep -Fq '"kind":"logical"' $rootpxe_original_schema_file || fail mbr-logical-kind
grep -Fq '"parentNumber":1' $rootpxe_original_schema_file || fail mbr-logical-parent
grep -Fq '"ebrReservedSectors":2' $rootpxe_original_schema_file || fail mbr-ebr-reservation
grep -Fq '"typeGuid":"0x5"' $rootpxe_original_schema_file || fail mbr-type-normalization
grep -Fq '"typeGuid":"0x83"' $rootpxe_original_schema_file || fail mbr-logical-type-normalization
grep -Fq '"artifact":""' $rootpxe_original_schema_file || fail mbr-container-artifact
grep -Fq '"minSectors":3976' $rootpxe_original_schema_file || fail mbr-container-minimum
node -e 'const e=2048,l=[{s:2050,m:2048},{s:5000,m:1024}];if(Math.max(...l.map(p=>p.s+p.m-e))!==3976)process.exit(1)' || fail mbr-container-minimum-oracle
grep -Fq '(.startSectors + .minSectors - $part.startSectors)' $funcs || fail mbr-container-minimum-builder
grep -Fq '"lvm"' $rootpxe_original_schema_file && fail mbr-v2-empty-lvm-must-be-omitted
node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1]));const e=s.partitions.find(p=>p.kind==="extended"),l=s.partitions.find(p=>p.kind==="logical");if(!e||!l||"parentNumber" in e||!("ebrReservedSectors" in e)||"ebrReservedSectors" in l||"logicalNumbers" in l)process.exit(1)' "$rootpxe_original_schema_file" || fail mbr-v2-field-boundaries
grep -Fq 'extended container must be derived' $funcs || fail mbr-derived-layout-guard
grep -Fq 'derived extended geometry invalid' $funcs || fail mbr-derived-layout-geometry

badlogical=$tmp/badlogical; mkdir -p $badlogical; : >$badlogical/d1p5.img
printf 'label: dos\n/dev/mock5 : start=4096, size=1024, type=83\n' >$badlogical/d1.partitions
rootpxe_build_original_schema /dev/mock $badlogical && fail mbr-logical-without-parent-schema
unset SCHEMA_KIND

# An extended partition is EBR metadata only.  Even if a stale d1p1.img was
# left in storage, capture must not enqueue a writer and restore must not feed
# it to writeImage.  The EBR marker itself remains available to the legacy
# EBR restore path.
container=$tmp/container; mkdir -p $container; : >$container/d1p1.img
CONTAINER_TRACE=$tmp/container-trace; : >$CONTAINER_TRACE; export CONTAINER_TRACE
getPartitionNumber() { part_number=1; }
getPartType() { parttype=0x85; }
fsTypeSetting() { fstype=ntfs; }
EBRFileName() { ebrfilename="$1/d${2}p${3}.ebr"; }
uploadFormat() { printf 'capture-writer\n' >>$CONTAINER_TRACE; return 1; }
getDiskFromPartition() { disk=/dev/mock; }
runPartprobe() { printf 'partprobe\n' >>$CONTAINER_TRACE; }
writeImage() { printf 'restore-payload\n' >>$CONTAINER_TRACE; return 1; }
imgPartitionType=all; imgType=n; imgFormat=5; osid=50
savePartition /dev/mock1 1 $container all
[[ -f $container/d1p1.ebr ]] || fail extended-capture-ebr-marker
grep -Fq capture-writer $CONTAINER_TRACE && fail extended-capture-stale-payload
restorePartition /dev/mock1 1 $container 0
grep -Fq restore-payload $CONTAINER_TRACE && fail extended-restore-stale-payload
grep -Fq partprobe $CONTAINER_TRACE || fail extended-restore-ebr-path

swapdir=$tmp/swap; mkdir -p $swapdir
printf 'label: dos\n/dev/mock2 : start=2048, size=1024, type=82\n' >$swapdir/d1.partitions
BLKTYPE=swap; export BLKTYPE
rootpxe_build_original_schema /dev/mock $swapdir || fail primary-swap-schema
grep -Fq '"role":"swap"' $rootpxe_original_schema_file || fail swap-role
grep -Fq '"artifact":""' $rootpxe_original_schema_file || fail swap-artifact

# 每个真实物理分区都可保存扩容策略；extended 容器仍仅可由逻辑分区
# 派生。默认布局由后端保留给普通 data 分区的 remaining 策略。
grep -Fq '== "0xef"' $funcs || fail mbr-efi
grep -Fq '== "0x27"' $funcs || fail mbr-recovery
grep -Fq 'original size violated' $funcs || fail grow-only-layout
grep -Fq 'target_bytes >= original_disk_bytes' $funcs || fail target-original-capacity-guard
grep -Fq 'align_down(($available-$used);$alignment)' $funcs || fail remaining-floor
node -e 'const a=512,r=Math.floor((7000-3500)/a)*a;if(r!==3072||r%a)process.exit(1)' || fail remaining-oracle

# Layout target capacity is converted through bytes into source Schema sectors:
# a 102400000-byte 4Kn target remains 200000 512-byte Schema sectors.
schema=$tmp/schema; layoutfile=$tmp/layout
printf '{"logicalSectorBytes":512,"originalDiskBytes":102400000}\n' >$schema; printf '{}\n' >$layoutfile
SCHEMA_SECTOR=512; SCHEMA_ORIGINAL=102400000
SCHEMAHASH=$(rootpxe_canonical_json_hash $schema)
TEST_SECTOR=4096
export SCHEMA_SECTOR SCHEMAHASH TEST_SECTOR
: >$tmp/jq-args
schemaRevision=1; schemaHash=$SCHEMAHASH
rootpxe_validate_deployment_layout /dev/mock $schema $layoutfile || fail target-byte-conversion
grep -Fq -- '--argjson target 200000' $tmp/jq-args || fail target-byte-sector-count

# The runtime jq resolver receives v2 MBR layout snapshots before permit.  In
# this host-only suite jq is mocked, so inspect the actual resolver program
# passed to jq and independently pin the EBR-derived extent arithmetic.
mbr_schema=$tmp/mbr-layout-schema
mbr_layout=$tmp/mbr-layout
printf '{"version":2,"partitionTable":"mbr","logicalSectorBytes":512,"originalDiskBytes":102400000,"partitions":[{"number":1,"kind":"extended","startSectors":2048,"originalSectors":8192,"ebrReservedSectors":2},{"number":5,"kind":"logical","parentNumber":1,"startSectors":2050,"originalSectors":2048,"minSectors":1024,"resizable":true,"role":"data"}]}' >$mbr_schema
SCHEMAHASH=$(rootpxe_canonical_json_hash $mbr_schema)
printf '{"schemaHash":"%s","partitions":[{"number":1,"mode":"derived"},{"number":5,"mode":"original"}]}' "$SCHEMAHASH" >$mbr_layout
schemaHash=$SCHEMAHASH; schemaRevision=1; SCHEMA_SECTOR=512; TEST_SECTOR=512
: >$tmp/jq-args
rootpxe_validate_deployment_layout /dev/mock $mbr_schema $mbr_layout || fail mbr-derived-layout-prepermit
grep -Fq 'extended container must be derived' $tmp/jq-args || fail mbr-derived-layout-jq-program
node -e 'const logical=[{start:4098,size:2048},{start:8192,size:1024}],ebr=2,start=Math.min(...logical.map(p=>p.start))-ebr,end=Math.max(...logical.map(p=>p.start+p.size));if(start!==4096||end-start!==5120)process.exit(1)' || fail mbr-derived-layout-oracle
TEST_SECTOR=4096; export TEST_SECTOR

# 用真实 jq 执行解析器：目标容量在部署时才已知。100GB 源镜像到
# 101/200/300GB 等更大目标均可解析，且每个叶子分区不小于原始大小；
# 小于原始盘的目标和缩小 fixed 分区在写盘前拒绝。
grow_schema=$tmp/grow-schema; grow_layout=$tmp/grow-layout
cat >$grow_schema <<'EOF'
{"version":1,"partitionTable":"gpt","originalDiskBytes":100000000,"logicalSectorBytes":512,"physicalSectorBytes":512,"minDeployBytes":50000000,"partitions":[{"number":1,"startSectors":2048,"originalSectors":90112,"minSectors":40000,"role":"efi","resizable":false},{"number":2,"startSectors":92160,"originalSectors":90112,"minSectors":30000,"role":"recovery","resizable":false}]}
EOF
MODE=layout_apply; export MODE
SCHEMAHASH=$(rootpxe_canonical_json_hash $grow_schema)
schemaHash=$SCHEMAHASH; schemaRevision=1
for TARGET_BYTES in 101000192 200000000 300000256; do
  export TARGET_BYTES
  printf '{"version":1,"schemaHash":"%s","partitions":[{"number":1,"mode":"original"},{"number":2,"mode":"remaining"}]}' "$SCHEMAHASH" >$grow_layout
  rootpxe_validate_deployment_layout /dev/mock $grow_schema $grow_layout || fail grow-only-target-$TARGET_BYTES
  "$REAL_JQ" -e 'all(.[]; .resolvedSectors >= .originalSectors)' "$rootpxe_resolved_layout_file" >/dev/null || fail grow-only-leaf-$TARGET_BYTES
done
TARGET_BYTES=99999999; export TARGET_BYTES
rootpxe_validate_deployment_layout /dev/mock $grow_schema $grow_layout >/dev/null 2>&1 && fail smaller-than-original-prewrite
TARGET_BYTES=200000000; export TARGET_BYTES
printf '{"version":1,"schemaHash":"%s","partitions":[{"number":1,"mode":"fixed","fixedBytes":46080000},{"number":2,"mode":"remaining"}]}' "$SCHEMAHASH" >$grow_layout
rootpxe_validate_deployment_layout /dev/mock $grow_schema $grow_layout >/dev/null 2>&1 && fail fixed-shrink-prewrite
unset TARGET_BYTES MODE

# Sector mismatch is rejected before disk permit unless NVMe read-only LBAF
# discovery succeeds.  This never runs nvme format.
printf 'sector-size: 512\n' >$tmp/sector.partitions
rootpxe_disk_stable_identity() { echo disk-id; }
rootpxe_nvme_find_metadata_free_lbaf() { return 1; }
rootpxe_plan_deploy_disk_operation /dev/sda $tmp/sector.partitions && fail nonnvme-mismatch-permit
rootpxe_plan_deploy_disk_operation /dev/nvme0n1 $tmp/sector.partitions && fail nvme-no-lbaf-permit
rootpxe_nvme_find_metadata_free_lbaf() { echo 3; }
rootpxe_plan_deploy_disk_operation /dev/nvme0n1 $tmp/sector.partitions || fail nvme-lbaf-plan
[[ $rootpxe_planned_disk_operation == nvme_format+deploy_write ]] || fail nvme-operation

# Deployment layout data is captured with the source disk's path and GPT
# usable-LBA bound.  A resolved layout for a larger target must be rewritten
# before sfdisk sees it: preserving /dev/nvme0n1pN or the smaller source
# last-lba rejects an NVMe-to-SATA restore even though the resolved sectors
# are valid on the target.
layout_template=$tmp/layout-template.partitions
layout_plan=$tmp/layout-plan.json
cat >$layout_template <<'EOF'
label: gpt
label-id: 81130EC9-8E47-47FD-8D5B-6FA8078753A4
device: /dev/nvme0n1
unit: sectors
first-lba: 34
last-lba: 99966
sector-size: 512

/dev/nvme0n1p1 : start=        2048, size=        1024, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=5F821F97-A35F-434F-AA4F-D91D4AB56347, name="EFI System Partition", attrs="LegacyBIOSBootable"
/dev/nvme0n1p2 : start=        3072, size=       90000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=60B6F988-1027-4E49-8C08-4544B6F427CB, name="root data"
EOF
cat >$layout_plan <<'EOF'
[
  {"number":1,"startSectors":2048,"resolvedSectors":1024},
  {"number":2,"startSectors":3072,"resolvedSectors":796895}
]
EOF
rootpxe_resolved_layout_file=$layout_plan
layout_applied=$tmp/layout-applied.partitions
LAYOUT_APPLIED=$layout_applied; export LAYOUT_APPLIED
layout_apply_assert_table() {
    local disk="$1" table="$2" first=34 last=799966 expected_p1 expected_p2
    [[ -s $table && $disk == "$LAYOUT_EXPECT_DISK" ]] || return 1
    if [[ $disk == *[0-9] ]]; then expected_p1="${disk}p1"; expected_p2="${disk}p2"; else expected_p1="${disk}1"; expected_p2="${disk}2"; fi
    grep -Fqx "device: $disk" "$table" || return 1
    grep -Fq "$expected_p1 : start=" "$table" || return 1
    grep -Fq "$expected_p2 : start=" "$table" || return 1
    if grep -Fqx 'label: dos' "$table"; then
        grep -Fqx 'label-id: 0x7f1a2b3c' "$table" || return 1
        grep -Fq 'type=7, bootable' "$table" || return 1
        grep -Fq 'type=83' "$table" || return 1
        return 0
    fi
    grep -Fqx "first-lba: $first" "$table" || return 1
    grep -Fqx "last-lba: $last" "$table" || return 1
    grep -Fq 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=5F821F97-A35F-434F-AA4F-D91D4AB56347, name="EFI System Partition", attrs="LegacyBIOSBootable"' "$table" || return 1
    grep -Fq 'type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=60B6F988-1027-4E49-8C08-4544B6F427CB, name="root data"' "$table" || return 1
    awk -v last="$last" '
      /start=/ {
        split($0,a,","); st=a[1]; sub(/.*start=[[:space:]]*/,"",st)
        sz=a[2]; sub(/.*size=[[:space:]]*/,"",sz)
        if (st !~ /^[0-9]+$/ || sz !~ /^[1-9][0-9]*$/ || st + sz - 1 > last) exit 1
      }
    ' "$table"
}
MODE=layout_apply; export MODE
TEST_SECTOR=512; export TEST_SECTOR
LAYOUT_SFDISK_MODE=canonical; export LAYOUT_SFDISK_MODE
LAYOUT_SFDISK_ARGS=$tmp/layout-sfdisk-args; export LAYOUT_SFDISK_ARGS
LAYOUT_PARTPROBE_TRACE=$tmp/layout-partprobe-trace; export LAYOUT_PARTPROBE_TRACE
LAYOUT_SLEEP_TRACE=$tmp/layout-sleep-trace; export LAYOUT_SLEEP_TRACE
LAYOUT_EXPECT_DISK=/dev/sda
rootpxe_apply_deployment_layout /dev/sda $layout_template || fail layout-apply-nvme-to-sata
layout_apply_assert_table /dev/sda "$layout_applied" || fail layout-apply-nvme-to-sata-rewritten-table
grep -Fqx -- '--no-reread --no-tell-kernel /dev/sda' "$LAYOUT_SFDISK_ARGS" || fail layout-sfdisk-write-must-disable-implicit-kernel-reread
LAYOUT_EXPECT_DISK=/dev/nvme0n1
rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template || fail layout-apply-nvme-suffix
layout_apply_assert_table /dev/nvme0n1 "$layout_applied" || fail layout-apply-nvme-suffix-rewritten-table
: >"$LAYOUT_PARTPROBE_TRACE"
: >"$LAYOUT_SLEEP_TRACE"
LAYOUT_PARTPROBE_FAILS=2; export LAYOUT_PARTPROBE_FAILS
rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template || fail layout-partprobe-transient-failure-must-recover
[[ $(wc -l <"$LAYOUT_PARTPROBE_TRACE") -eq 3 ]] || fail layout-partprobe-must-retry-three-times
[[ $(wc -l <"$LAYOUT_SLEEP_TRACE") -eq 2 ]] || fail layout-partprobe-retries-must-use-bounded-delay
unset LAYOUT_PARTPROBE_FAILS
: >"$LAYOUT_PARTPROBE_TRACE"
: >"$LAYOUT_SLEEP_TRACE"
LAYOUT_PARTPROBE_FAILS=5; export LAYOUT_PARTPROBE_FAILS
rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template && fail layout-partprobe-exhaustion-must-reject
[[ $rootpxe_layout_apply_code == PARTPROBE_FAILED && $rootpxe_layout_apply_reason == partition_table_reread_failed && -r $rootpxe_layout_diagnostics_file ]] || fail layout-partprobe-exhaustion-category
[[ $(wc -l <"$LAYOUT_PARTPROBE_TRACE") -eq 5 ]] || fail layout-partprobe-must-stop-at-five-attempts
[[ $(wc -l <"$LAYOUT_SLEEP_TRACE") -eq 4 ]] || fail layout-partprobe-exhaustion-delay-bound
unset LAYOUT_PARTPROBE_FAILS
for layout_variant in header_geometry partition_numbers partition_geometry semantic_identity; do
    LAYOUT_SFDISK_MODE=$layout_variant
    rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template && fail "layout-readback-$layout_variant-must-reject"
    [[ $rootpxe_layout_apply_code == LAYOUT_READBACK_FAILED && $rootpxe_layout_apply_reason == sfdisk_$layout_variant ]] || fail "layout-readback-$layout_variant-category"
done
LAYOUT_SFDISK_MODE=write_fail
rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template && fail layout-sfdisk-write-failure-must-reject
[[ $rootpxe_layout_apply_code == SFDISK_WRITE_FAILED && $rootpxe_layout_apply_reason == sfdisk_write_failed && -r $rootpxe_layout_diagnostics_file ]] || fail layout-sfdisk-write-failure-category
grep -Fqx 'mock sfdisk write failure' "$rootpxe_layout_diagnostics_file" || fail layout-sfdisk-write-failure-diagnostics
LAYOUT_PARTPROBE_STATUS=1; export LAYOUT_PARTPROBE_STATUS
LAYOUT_SFDISK_MODE=canonical
rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template && fail layout-partprobe-failure-must-reject
[[ $rootpxe_layout_apply_code == PARTPROBE_FAILED && $rootpxe_layout_apply_reason == partition_table_reread_failed && -r $rootpxe_layout_diagnostics_file ]] || fail layout-partprobe-failure-category
unset LAYOUT_PARTPROBE_STATUS
LAYOUT_SFDISK_MODE=dump_fail
rootpxe_apply_deployment_layout /dev/nvme0n1 $layout_template && fail layout-sfdisk-dump-failure-must-reject
[[ $rootpxe_layout_apply_code == SFDISK_DUMP_FAILED && $rootpxe_layout_apply_reason == sfdisk_dump_failed && -r $rootpxe_layout_diagnostics_file ]] || fail layout-sfdisk-dump-failure-category
LAYOUT_SFDISK_MODE=canonical
mbr_layout_template=$tmp/mbr-layout-template.partitions
mbr_layout_plan=$tmp/mbr-layout-plan.json
cat >$mbr_layout_template <<'EOF'
label: dos
label-id: 0x7f1a2b3c
device: /dev/nvme0n1
unit: sectors
sector-size: 512

/dev/nvme0n1p1 : start=        2048, size=       40960, type=7, bootable
/dev/nvme0n1p2 : start=       43008, size=      756992, type=83
EOF
cat >$mbr_layout_plan <<'EOF'
[
  {"number":1,"startSectors":2048,"resolvedSectors":40960},
  {"number":2,"startSectors":43008,"resolvedSectors":756992}
]
EOF
rootpxe_resolved_layout_file=$mbr_layout_plan
LAYOUT_EXPECT_DISK=/dev/sda
rootpxe_apply_deployment_layout /dev/sda $mbr_layout_template || fail layout-apply-mbr-nvme-to-sata
LAYOUT_EXPECT_DISK=/dev/nvme0n1
rootpxe_apply_deployment_layout /dev/nvme0n1 $mbr_layout_template || fail layout-apply-mbr-nvme-suffix
rootpxe_resolved_layout_file=$layout_plan
unset MODE LAYOUT_EXPECT_DISK LAYOUT_SFDISK_MODE LAYOUT_APPLIED LAYOUT_SFDISK_ARGS LAYOUT_PARTPROBE_TRACE LAYOUT_SLEEP_TRACE

# Windows NTFS 恢复后，活动部署布局只允许实际扩大的物理分区绕过
# 捕获时 fixed 列表；同一布局内保持原始大小的恢复/EFI 等分区仍须
# 被抑制。历史无布局路径则对两者都保持原有抑制。
EXPAND_TRACE=$tmp/expand-trace; : >$EXPAND_TRACE; export EXPAND_TRACE
sfdiskOriginalPartitionFileName() { :; }
getValidRestorePartitions() { restoreparts='/dev/mock1 /dev/mock2'; }
getPartitionNumber() { part_number=${1##*mock}; }
tmpEBRFileName() { :; }
restorePartition() { :; }
restoreEBR() { :; }
expandPartition() { printf '%s|%s\n' "$1" "$2" >>$EXPAND_TRACE; }
restoreUUIDInformation() { :; }
makeAllSwapSystems() { :; }
expansion_schema=$tmp/expansion-schema.json
expansion_plan=$tmp/expansion-plan.json
cat >$expansion_schema <<'EOF'
{"version":2,"partitionTable":"mbr","originalDiskBytes":100000000,"logicalSectorBytes":512,"partitions":[{"number":1,"kind":"primary","originalSectors":1024},{"number":2,"kind":"primary","originalSectors":1024},{"number":3,"kind":"extended","originalSectors":2048}]}
EOF
cat >$expansion_plan <<'EOF'
[{"number":1,"resolvedSectors":2048},{"number":2,"resolvedSectors":1024},{"number":3,"resolvedSectors":4096}]
EOF
imgType=n; osid=0; fixed_size_partitions=1:2:3
originalSchemaFile=$expansion_schema
rootpxe_resolved_layout_file=$expansion_plan
MODE=layout_apply; export MODE
performRestore /dev/mock $tmp all 0 || fail active-layout-restore
grep -Fqx '/dev/mock1|2:3' $EXPAND_TRACE || fail active-layout-expanded-must-expand-ntfs
grep -Fqx '/dev/mock2|2:3' $EXPAND_TRACE || fail active-layout-original-must-remain-fixed
: >$EXPAND_TRACE
unset rootpxe_resolved_layout_file originalSchemaFile MODE
performRestore /dev/mock $tmp all 0 || fail legacy-restore
grep -Fqx '/dev/mock1|1:2:3' $EXPAND_TRACE || fail legacy-first-fixed-list-must-remain
grep -Fqx '/dev/mock2|1:2:3' $EXPAND_TRACE || fail legacy-second-fixed-list-must-remain

# Resume is deliberately before layout validation and must not reinvoke image
# restoration after a hostname or post-deploy-script attention retry. Execute the
# tail with failing mocks for all prohibited operations, not merely a grep.
resume_script=$tmp/resume.sh
awk '/^findHDDInfo$/{on=1} on' $download | sed -e "s|/bin/pxeos.imgcomplete|$tmp/pxeos.imgcomplete|g" >$resume_script
cat >$tmp/pxeos.imgcomplete <<'EOF'
printf '%s\n' complete >>$RESUME_TRACE
EOF
chmod +x $tmp/pxeos.imgcomplete
: >$tmp/resume-trace
RESUME_TRACE=$tmp/resume-trace; export RESUME_TRACE
findHDDInfo() { hd=/dev/mock2; printf '%s\n' find >>$RESUME_TRACE; }
rootpxe_disk_stable_identity() { echo resume-disk-id; }
rootpxe_wait_for_disk_permit() { printf 'permit:%s:%s\n' "$1" "$2" >>$RESUME_TRACE; }
rootpxe_stage() { printf 'stage:%s\n' "$*" >>$RESUME_TRACE; }
rootpxe_apply_hostname_for_disk() { printf 'hostname:%s:%s\n' "$osid" "$1" >>$RESUME_TRACE; }
rootpxe_run_pre_deploy_script() { printf '%s\n' UNEXPECTED:pre >>$RESUME_TRACE; return 1; }
rootpxe_run_post_deploy_script() { printf '%s\n' post >>$RESUME_TRACE; }
rootpxe_validate_deployment_layout() { fail resume-layout; }
rootpxe_apply_deployment_layout() { fail resume-layout-apply; }
rootpxe_plan_deploy_disk_operation() { fail resume-nvme-plan; }
preparePartitions() { fail resume-partition; }
putDataBack() { fail resume-restore; }
resumeStage=customizing_hostname
changeHostname=true
osid=50
imagePath=$tmp/image
imgType=n
imgPartitionType=all
nombr=0
(
    . $resume_script
) || fail resume-execution
grep -Fqx permit:resume-disk-id:deploy_write $tmp/resume-trace || fail resume-permit
grep -Fqx hostname:50:/dev/mock2 $tmp/resume-trace || fail resume-hostname
grep -Fqx post $tmp/resume-trace || fail resume-post
grep -Fqx complete $tmp/resume-trace || fail resume-complete

: >$tmp/resume-post-trace
RESUME_TRACE=$tmp/resume-post-trace; export RESUME_TRACE
rootpxe_apply_hostname_for_disk() { fail resume-post-must-not-repeat-hostname; }
resumeStage=post_deploy_script
changeHostname=false
(
    . $resume_script
) || fail resume-post-execution
grep -Fqx permit:resume-disk-id:deploy_write $tmp/resume-post-trace || fail resume-post-permit
grep -Fqx post $tmp/resume-post-trace || fail resume-post-script
grep -Fqx complete $tmp/resume-post-trace || fail resume-post-complete
! grep -Fq UNEXPECTED:pre $tmp/resume-post-trace || fail resume-post-ran-pre

# Keep the ordering assertion as a cheap guard against accidental future
# movement of the early resume branch.
resume=$(grep -n RESUME_TARGET_IDENTITY_UNAVAILABLE $download | cut -d: -f1)
layout=$(grep -n pre_permit_validation_failed $download | cut -d: -f1)
[[ $resume -lt $layout ]] || fail resume-order
pre_safe=$(grep -n "resumeStage:-} == pre_deploy_script" $download || true)
[[ -z $pre_safe ]] || fail pre-deploy-stage-must-not-bypass-imaging
permit=$(grep -n "rootpxe_wait_for_disk_permit \"\$rootpxe_planned_target_id\"" $download | cut -d: -f1)
pre=$(grep -n "rootpxe_run_pre_deploy_script" $download | tail -n1 | cut -d: -f1)
prepare=$(grep -n "preparePartitions" $download | tail -n1 | cut -d: -f1)
[[ $permit -lt $pre && $pre -lt $prepare ]] || fail pre-deploy-script-order
echo 'PASS: PXEOS business regression contract'
)
# ===== 原脚本结束：tests/pxeos_business_regression.sh =====

# ===== 原脚本：tests/pxeos_console_english_regression.sh =====
(
# Static fixed-console-message contract; it neither boots PXEOS nor touches disks or network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
# PXEOS uses extensionless runtime scripts in bin and init.d.  Collect only
# text files that explicitly identify as sh/bash scripts, so binary artifacts
# and metadata records are never inspected as console sources.
mapfile -d '' -t runtime_candidates < <(
    find "$overlay/bin" "$overlay/etc/init.d" "$overlay/usr/share/pxeos" \
        -type f -print0 | LC_ALL=C sort -z
)
runtime_files=()
for runtime_candidate in "${runtime_candidates[@]}"; do
    IFS= read -r runtime_shebang <"$runtime_candidate" || true
    case $runtime_shebang in
        '#!'*bash*|'#!'*'/sh'*) runtime_files+=("$runtime_candidate") ;;
    esac
done
[[ ${#runtime_files[@]} -gt 0 ]] || { printf 'FAIL: no PXEOS runtime scripts found\n' >&2; exit 1; }
for required_runtime in pxeos.upload pxeos.av pxeos.man.reg pxeos.debug S99pxeos funcs.sh; do
    printf '%s\n' "${runtime_files[@]}" | grep -Eq "/${required_runtime}$" \
        || { printf 'FAIL: runtime shebang scan missed %s\n' "$required_runtime" >&2; exit 1; }
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 is missing expected console output: $2"; }
must_not_have() { ! grep -Fq -- "$2" "$1" || fail "$1 contains obsolete console output: $2"; }
must_fit() { [[ ${#1} -le 80 ]] || fail "console line exceeds 80 columns: $1"; }

# Check every runtime shell script.  Dynamic values and redirected protocol
# records are outside this contract; fixed output must remain ASCII so the
# console font can render it.  Comments are intentionally excluded.
set +e
LC_ALL=C awk '
    /^[[:space:]]*#/ { next }
    {
        if (printf_block) {
            if ($0 ~ /[^ -~\t]/) { print FILENAME ":" FNR ":" $0; invalid = 1 }
            if ($0 !~ /\\[[:space:]]*$/) { printf_block = 0 }
            next
        }
        if ($0 ~ /(^|[[:space:];])(echo|printf|rootpxe_console_message|rootpxe_console_prompt|dots|handleError|handleWarning|debugEcho|majorDebugEcho|pxeos_network_message|pxeos_network_prompt)[[:space:]]/) {
            if ($0 ~ /[^ -~\t]/) { print FILENAME ":" FNR ":" $0; invalid = 1 }
            if ($0 ~ /printf[[:space:]].*\\[[:space:]]*$/) { printf_block = 1 }
        }
    }
    END { exit invalid ? 1 : 0 }
' "${runtime_files[@]}"
scan_status=$?
set -e
case "$scan_status" in
    0) ;;
    1) fail 'static fixed console messages must use ASCII text' ;;
    *) fail "console output scanner failed (exit $scan_status)" ;;
esac

# Legacy decorative output bypasses the level/body convention.  Completion
# tokens are intentionally not covered here because they are the inline result
# of `dots` progress rows; all standalone fixed messages must use a formatter.
set +e
awk '
    /^[[:space:]]*#/ { next }
    /(^|[[:space:];])(echo|printf|rootpxe_console_message|rootpxe_console_prompt|dots|handleError|handleWarning|debugEcho|majorDebugEcho|pxeos_network_message|pxeos_network_prompt)[[:space:]]/ &&
    ($0 ~ /["\047] \*/ || $0 ~ /["\047]WARNING:/) {
        print FILENAME ":" FNR ":" $0
        invalid = 1
    }
    /echo[[:space:]]+-n[[:space:]]+["\047][[:alpha:]]/ && $0 !~ />/ {
        print FILENAME ":" FNR ":" $0
        invalid = 1
    }
    END { exit invalid ? 1 : 0 }
' "${runtime_files[@]}"
legacy_status=$?
set -e
[[ $legacy_status -eq 0 ]] || fail 'standalone PXEOS console messages must use levelled output'

# Extract only the display helpers.  The mocks below prove that completed
# messages have a level/body column and that inline progress remains aligned;
# no PXEOS top-level code, disk command, network request, or real wait runs.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^rootpxe_console_message\(\)/ { copy = 1 } /^# Appends dots/ { exit } copy' "$funcs" >"$tmp/console.sh"
awk '/^dots\(\)/ { copy = 1 } /^# Enables write caching/ { exit } copy' "$funcs" >"$tmp/dots.sh"
awk '/^handleError\(\)/ { copy = 1 } /^# Re-reads the partition table/ { exit } copy' "$funcs" >"$tmp/handlers.sh"
awk '/^displayBanner\(\)/ { copy = 1 } /^# Gets all system mac addresses except for loopback/ { exit } copy' "$funcs" >"$tmp/banner.sh"
awk '/^pxeos_init_message\(\)/ { copy = 1 } /^# SSH/ { exit } copy' "$overlay/etc/init.d/S99pxeos" >"$tmp/init-console.sh"
awk '/^display_registration_response\(\)/ { copy = 1 } /^disks=/{ exit } copy' "$overlay/bin/pxeos.auto.reg" >"$tmp/auto-registration-response.sh"
awk '/^display_registration_response\(\)/ { copy = 1 } /^disks=/{ exit } copy' "$overlay/bin/pxeos.man.reg" >"$tmp/manual-registration-response.sh"
[[ -s $tmp/console.sh ]] || fail 'console formatter was not extracted'
[[ -s $tmp/banner.sh ]] || fail 'console banner was not extracted'
[[ -s $tmp/init-console.sh ]] || fail 'init console formatter was not extracted'
[[ -s $tmp/auto-registration-response.sh ]] || fail 'automatic registration response formatter was not extracted'
[[ -s $tmp/manual-registration-response.sh ]] || fail 'manual registration response formatter was not extracted'

(
    . "$tmp/init-console.sh"
    pxeos_init_message WARN 'Init formatter test.'
) >"$tmp/init-console.out"
[[ $(cat "$tmp/init-console.out") == '[WARN]  Init formatter test.' ]] || fail 'init console formatter must match the common level/body layout'
must_fit "$(cat "$tmp/init-console.out")"

(
    . "$tmp/console.sh"
    . "$tmp/auto-registration-response.sh"
    display_registration_response $'#!ok\nregistered'
) >"$tmp/auto-registration-response.out"
grep -Fqx '[INFO]  Server response: #!ok' "$tmp/auto-registration-response.out" || fail 'automatic registration must render the first response line safely'
grep -Fqx '[INFO]  Server response: registered' "$tmp/auto-registration-response.out" || fail 'automatic registration must render every response line safely'

(
    . "$tmp/console.sh"
    . "$tmp/manual-registration-response.sh"
    display_registration_response WARN $'name in use\nchoose another'
) >"$tmp/manual-registration-response.out"
grep -Fqx '[WARN]  Server response: name in use' "$tmp/manual-registration-response.out" || fail 'manual registration warning must render the first response line safely'
grep -Fqx '[WARN]  Server response: choose another' "$tmp/manual-registration-response.out" || fail 'manual registration warning must render every response line safely'

(
    . "$tmp/console.sh"
    rootpxe_console_prompt WARN 'Confirm test prompt: '
) >"$tmp/prompt.out"
[[ $(cat "$tmp/prompt.out") == '[WARN]  Confirm test prompt: ' ]] || fail 'interactive prompt must keep the level/body column'
must_fit "$(cat "$tmp/prompt.out")"

(
    initversion=test-init
    pxeapi=https://example.invalid/service/
    curl() { printf 'test-version\n'; }
    . "$tmp/console.sh"
    . "$tmp/banner.sh"
    displayBanner
) >"$tmp/banner.out"
grep -Fqx '   ===  ██████╗  ██╗  ██╗ ███████╗  ██████╗  ███████╗   ===' "$tmp/banner.out" \
    || fail 'normal banner is missing the PXEOS logo'
grep -Fqx '   ==================== PXEOS Runtime =====================' "$tmp/banner.out" \
    || fail 'normal banner is missing the PXEOS runtime title'
while IFS= read -r line; do
    must_fit "$line"
done <"$tmp/banner.out"
grep -Fqx '[INFO]  Version: test-version' "$tmp/banner.out" || fail 'normal banner version must use INFO layout'
grep -Fqx '[INFO]  Init version: test-init' "$tmp/banner.out" || fail 'normal banner init version must use INFO layout'

set +e
(
    initversion=test-init
    isdebug=""
    cat() { [[ $1 == /proc/cmdline ]] && { printf 'mock_cmdline=1\n'; return; }; command cat "$@"; }
    rootpxe_require_task_context() { return 1; }
    rootpxe_error_wait_for_retry() { printf 'unexpected retry callback\n' >&2; return 99; }
    usleep() { printf 'usleep:%s\n' "$1"; }
    debugPause() { printf 'debug-pause\n'; }
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    . "$tmp/handlers.sh"
    dots 'Mounting File System'
    handleError $'Mock failure details\nMock failure detail line two' ''
) >"$tmp/error.out" 2>&1
error_status=$?
set -e
[[ $error_status -eq 1 ]] || fail "handleError exit policy changed: $error_status"
[[ $(sed -n '2p' "$tmp/error.out") == '[ERROR] Operation failed.' ]] || fail 'handleError must start on a new ERROR line after dots'
grep -Fqx '[INFO]  Init version: test-init' "$tmp/error.out" || fail 'handleError init version format'
grep -Fqx '[INFO]  Error details:' "$tmp/error.out" || fail 'handleError error-details section'
grep -Fqx '        Mock failure details' "$tmp/error.out" || fail 'handleError must preserve and indent error detail'
grep -Fqx '        Mock failure detail line two' "$tmp/error.out" || fail 'handleError must preserve multiline error detail'
awk '
    $0 == "        Mock failure detail line two" {
        getline
        if ($0 != "") exit 1
        getline
        if ($0 != "[INFO]  Kernel variables and settings:") exit 1
        found = 1
    }
    END { exit found ? 0 : 1 }
' "$tmp/error.out" || fail 'handleError must separate error details from kernel diagnostics'
grep -Fqx '[INFO]  Kernel variables and settings:' "$tmp/error.out" || fail 'handleError diagnostics section'
grep -Fqx '        mock_cmdline=1' "$tmp/error.out" || fail 'handleError must preserve and indent cmdline diagnostics'
grep -Fqx '[WARN]  System will reboot in 60s.' "$tmp/error.out" || fail 'handleError reboot notice'
grep -Fqx 'usleep:60000000' "$tmp/error.out" || fail 'handleError retry wait changed'
! grep -Fq '###' "$tmp/error.out" || fail 'handleError must not render hash decoration'

set +e
(
    initversion=test-init
    isdebug=""
    cat() { [[ $1 == /proc/cmdline ]] && { printf 'mock_cmdline=1\n'; return; }; command cat "$@"; }
    rootpxe_require_task_context() { return 0; }
    rootpxe_error_wait_for_retry() { printf 'retry-callback:%s:%s\n' "$1" "$2"; return 2; }
    usleep() { printf 'unexpected-usleep:%s\n' "$1"; }
    debugPause() { printf 'unexpected-debug-pause\n'; }
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    . "$tmp/handlers.sh"
    handleError 'Mock task failure' ''
) >"$tmp/task-context.out" 2>&1
task_context_status=$?
set -e
[[ $task_context_status -eq 2 ]] || fail "handleError task-context exit policy changed: $task_context_status"
grep -Fqx 'retry-callback:Mock task failure:PXEOS_ERROR' "$tmp/task-context.out" || fail 'handleError retry callback contract'
! grep -Fq 'unexpected-usleep' "$tmp/task-context.out" || fail 'handleError task context must not enter fallback wait'

(
    usleep() { printf 'usleep:%s\n' "$1"; }
    debugPause() { printf 'debug-pause\n'; }
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    . "$tmp/handlers.sh"
    dots 'Mounting File System'
    handleWarning 'Mock warning details'
) >"$tmp/warning.out" 2>&1
[[ $(sed -n '2p' "$tmp/warning.out") == '[WARN]  Operation warning.' ]] || fail 'handleWarning must start on a new WARN line after dots'
grep -Fqx '[INFO]  Warning details:' "$tmp/warning.out" || fail 'handleWarning details section'
grep -Fqx '        Mock warning details' "$tmp/warning.out" || fail 'handleWarning must preserve and indent warning detail'
grep -Fqx '[INFO]  Continuing in 60s.' "$tmp/warning.out" || fail 'handleWarning continuation notice'
grep -Fqx 'usleep:60000000' "$tmp/warning.out" || fail 'handleWarning wait changed'
grep -Fqx 'debug-pause' "$tmp/warning.out" || fail 'handleWarning debug pause changed'
! grep -Fq '###' "$tmp/warning.out" || fail 'handleWarning must not render hash decoration'

long_message=$(printf 'x%.0s' {1..145})
(
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    dots 'Mounting File System'
    printf 'Done\n'
    rootpxe_console_message INFO 'Next task message'
) >"$tmp/progress.out"
progress_line=$(sed -n '1p' "$tmp/progress.out")
[[ $progress_line == '[INFO]  Mounting File System'*Done ]] || fail 'dots progress and Done no longer share one line'
must_fit "$progress_line"
[[ $(sed -n '2p' "$tmp/progress.out") == '[INFO]  Next task message' ]] || fail 'next log message did not start on its own levelled line'

(
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    dots "$long_message"
    printf '\n'
    rootpxe_console_message ERROR 'Progress failed safely'
) >"$tmp/long-dots-error.out"
while IFS= read -r line; do
    must_fit "$line"
done <"$tmp/long-dots-error.out"
[[ $(tail -n 1 "$tmp/long-dots-error.out") == '[ERROR] Progress failed safely' ]] || fail 'error did not start after unfinished long progress line'

(
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    dots 'Updating Database'
    printf 'Skipped\n'
    rootpxe_console_message INFO 'Database update skipped: no task ID.'
) >"$tmp/short-result.out"
while IFS= read -r line; do
    must_fit "$line"
done <"$tmp/short-result.out"
[[ $(sed -n '1p' "$tmp/short-result.out") == '[INFO]  Updating Database'*Skipped ]] || fail 'short skipped result no longer shares its dots line'
[[ $(sed -n '2p' "$tmp/short-result.out") == '[INFO]  Database update skipped: no task ID.' ]] || fail 'short result explanation is missing'

(
    . "$tmp/console.sh"
    rootpxe_console_message INFO "$long_message"
) >"$tmp/long.out"
[[ $(wc -l <"$tmp/long.out") -eq 3 ]] || fail 'long message was not safely wrapped'
while IFS= read -r line; do
    [[ $line == '[INFO]  '* ]] || fail "long message lost INFO/body column: $line"
    must_fit "$line"
done <"$tmp/long.out"

must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message WARN 'Check-in not confirmed. Retrying in 5s.'"
must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message INFO 'SSH is available for troubleshooting.'"
must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message INFO 'Task aborted or withdrawn. Stopping PXEOS.'"
must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message INFO 'Checking in with RootPXE.'"
must_have "$overlay/bin/pxeos.checkin" 'rootpxe_console_message INFO "$waitMsg"'
must_have "$overlay/bin/pxeos.checkin" 'rootpxe_console_message INFO "Retrying in ${retryAfterSec}s."'
must_have "$overlay/bin/pxeos.checkin" 'rootpxe_console_message INFO "Storage protocol: ${protocol^^}"'
must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message INFO 'Check-in completed.'"
must_not_have "$overlay/bin/pxeos.checkin" 'dots "Check in (RootPXE)"'
must_not_have "$overlay/bin/pxeos.checkin" 'dots "$waitMsg"'
must_not_have "$overlay/bin/pxeos.checkin" 'echo "Done"'
must_have "$overlay/bin/pxeos.upload" "rootpxe_console_message INFO 'Preparing to send image file to server.'"
must_have "$overlay/bin/pxeos.upload" 'rootpxe_console_message INFO "Using image: $img."'
must_have "$overlay/bin/pxeos.upload" "rootpxe_console_message INFO 'Capturing image with Partclone.'"
must_not_have "$overlay/bin/pxeos.upload" 'echo " * Preparing to send image file to server"'
must_have "$overlay/bin/pxeos.download" 'rootpxe_console_message INFO "Using image: $img."'
must_have "$overlay/bin/pxeos.download" "rootpxe_console_message INFO 'Preparing partition layout.'"
must_not_have "$overlay/bin/pxeos.download" 'echo " * Preparing Partition layout"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_console_message INFO "Using disk device: $hd."'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_console_message WARN "No partitions found for disk device: $disk."'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_console_message INFO "Using disk devices: $disks."'
must_have "$overlay/bin/pxeos.download" "rootpxe_console_message INFO 'Task aborted or deleted. Stopping PXEOS.'"
must_have "$overlay/bin/pxeos.download" "rootpxe_console_message WARN 'Disk permit wait was interrupted. Retrying in 5s.'"
must_have "$overlay/etc/init.d/S99pxeos" 'pxeos_init_message INFO '\''Task completed. Powering off.'\'''
must_have "$overlay/etc/init.d/S99pxeos" 'pxeos_init_message INFO '\''Task completed. Rebooting.'\'''
must_have "$overlay/etc/init.d/S99pxeos" 'pxeos_init_message WARN "Task exited with code: $rc."'
must_have "$overlay/etc/init.d/S99pxeos" 'pxeos_init_message INFO "Running configured failure action: $failure_action."'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Disk permission not confirmed. Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Error report failed. Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Error report not confirmed (HTTP $http_status). Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Error report rejected (HTTP $http_status): $response_reason. Retrying in 5s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" "rootpxe_console_message ERROR 'Task paused. Error reported to RootPXE.'"
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" "rootpxe_console_message INFO 'Select Retry in the web UI to resume.'"
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_console_message INFO "Timeout: ${wait}s. Timeout action: $action."'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_console_message WARN "Wait timed out. Timeout action: $action."'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" "rootpxe_console_message INFO 'Retry requested. Resuming task.'"
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" "rootpxe_console_message INFO 'Task deleted or aborted. Stopping PXEOS.'"
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[ERROR] Operation failed.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  Operation warning.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[WARN]  System will reboot in 60s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '[INFO]  Continuing in 60s.'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Disk permit response is invalid. Check the server protocol and task binding.'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" '磁盘操作许可响应无效'
must_have "$overlay/bin/pxeos.debug" "pxeos_debug_message INFO 'Mode: SSH debug.'"
must_have "$overlay/bin/pxeos.debug" "pxeos_debug_message WARN 'No global IPv4 address is available for SSH.'"
must_have "$overlay/etc/init.d/S40network" 'pxeos_network_message INFO "PXEOS network diagnostics:"'
must_have "$overlay/etc/init.d/S40network" 'pxeos_network_prompt INFO "Press Enter to continue."'
must_have "$overlay/bin/pxeos.sysinfo" 'PS3="[INFO]  Select an option: "'
must_have "$overlay/etc/init.d/K40network" "printf '%-7s %s\\n' '[INFO]' \"Stopping interface \$iface.\""
must_have "$overlay/bin/pxeos.sysinfo" "rootpxe_console_message WARN 'Hardware compatibility checks failed.'"
must_not_have "$overlay/bin/pxeos.sysinfo" 'FOG'
must_not_have "$overlay/bin/pxeos.sysinfo" '####'
must_not_have "$overlay/bin/pxeos.inventory" '+---------------------------+'
must_not_have "$overlay/bin/pxeos.sysinfo" '=================================================='
must_not_have "$overlay/bin/pxeos.sysinfo" "System MAC Address'"
must_have "$overlay/bin/pxeos.inventory" "inventory_section 'System information'"
must_have "$overlay/bin/pxeos.inventory" 'rootpxe_console_message INFO "$label: $value"'
must_have "$overlay/bin/pxeos.sysinfo" "rootpxe_console_message INFO 'Network information:'"
must_have "$overlay/bin/pxeos.sysinfo" 'rootpxe_console_message INFO "Network: $blNicOk."'
must_have "$overlay/bin/pxeos.sysinfo" 'rootpxe_console_message INFO "Disk device: $blHddOk."'
must_have "$overlay/bin/pxeos.sysinfo" 'rootpxe_console_message INFO "System MAC address: $mac"'
must_have "$overlay/bin/pxeos.auto.reg" 'rootpxe_console_message INFO "Server response: $response_line"'
must_have "$overlay/bin/pxeos.man.reg" 'rootpxe_console_message "$level" "Server response: $response_line"'
must_have "$overlay/bin/pxeos.man.reg" 'display_registration_response WARN "$res"'
must_have "$overlay/bin/pxeos.man.reg" 'display_registration_response INFO "$res"'
must_have "$overlay/bin/pxeos.man.reg" 'rootpxe_console_message INFO "$line"'
must_not_have "$overlay/bin/pxeos.auto.reg" 'echo "$res"'
must_not_have "$overlay/bin/pxeos.man.reg" 'echo "$res"'
must_not_have "$overlay/bin/pxeos.man.reg" 'echo $line'
must_not_have "$overlay/bin/pxeos.auto.reg" 'Host registration completed.'
must_not_have "$overlay/bin/pxeos.man.reg" 'Host registration completed.'
must_have "$overlay/bin/pxeos.surfacetest" 'dots "Locating disk devices"'
must_have "$overlay/bin/pxeos.surfacetest" 'dots "Checking in"'
must_have "$overlay/bin/pxeos.photorec" 'dots "Creating file system mount point"'
must_have "$overlay/bin/pxeos.checkmount" 'dots "Checking mounted file system"'
must_have "$overlay/bin/pxeos.checkmountdrivesize" 'dots "Checking server disk space"'
must_have "$overlay/bin/pxeos.chntpw" 'dots "Mounting Windows file system"'
must_have "$overlay/bin/pxeos.chpass" 'dots "Creating chntpw mount point"'
must_have "$overlay/bin/pxeos.chpass" 'dots "Using disk device"'
! grep -F 'rootpxe_console_message' "$overlay/usr/share/pxeos/lib/funcs.sh" | grep -Fq 'ROOTPXE' \
    || fail 'script environment variable leaked into console output'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Hard Disk'
must_not_have "$overlay/bin/pxeos.upload" 'Using Image'
must_not_have "$overlay/bin/pxeos.download" 'Using Image'
must_not_have "$overlay/bin/pxeos.download" 'Preparing Partition layout'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_console_prompt INFO "${*:-Press Enter to continue.}"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" "rootpxe_console_message WARN 'XFS partition cannot be expanded.'"
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Failed, XFS partition cannot be expanded'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" "rootpxe_console_message WARN 'Cleared a corrupted partition table.'"
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'Done, but cleared corrupted partition.'
must_have "$overlay/bin/pxeos.nonimgcomplete" "rootpxe_console_message INFO 'Database update skipped: no task ID.'"
must_not_have "$overlay/bin/pxeos.nonimgcomplete" 'Skipped (no taskid)'
grep -B1 -F "rootpxe_console_message WARN 'XFS partition cannot be expanded.'" "$overlay/usr/share/pxeos/lib/funcs.sh" | grep -Fq 'echo "Skipped"' || fail 'XFS dots result must remain short'
grep -B1 -F "rootpxe_console_message WARN 'Cleared a corrupted partition table.'" "$overlay/usr/share/pxeos/lib/funcs.sh" | grep -Fq 'echo "Done"' || fail 'corrupted-table dots result must remain short'
grep -B1 -F "rootpxe_console_message INFO 'Database update skipped: no task ID.'" "$overlay/bin/pxeos.nonimgcomplete" | grep -Fq 'echo "Skipped"' || fail 'no-task-id dots result must remain short'
must_fit '[INFO]  Stopping interface eth0.'
must_have "$overlay/bin/pxeos.imgcomplete" "rootpxe_console_message INFO 'Task complete.'"
must_have "$overlay/bin/pxeos.nonimgcomplete" "rootpxe_console_message INFO 'Task complete.'"

for line in \
    '[WARN]  Check-in not confirmed. Retrying in 5s.' \
    '[INFO]  Checking in with RootPXE.' \
    '[INFO]  Retrying in 999s.' \
    '[INFO]  Check-in completed.' \
    '[INFO]  SSH is available for troubleshooting.' \
    '[INFO]  Task aborted or withdrawn. Stopping PXEOS.' \
    '[INFO]  Task aborted or deleted. Stopping PXEOS.' \
    '[INFO]  Task completed. Powering off.' \
    '[INFO]  Task completed. Rebooting.' \
    '[WARN]  Task exited with code: 255.' \
    '[INFO]  Running configured failure action: shutdown.' \
    '[WARN]  Disk permission not confirmed. Retrying in 5s.' \
    '[WARN]  Error report failed. Retrying in 5s.' \
    '[WARN]  Error report not confirmed (HTTP 500). Retrying in 5s.' \
    '[WARN]  Error report rejected (HTTP 409): server rejected. Retrying in 5s.' \
    '[ERROR] Task paused. Error reported to RootPXE.' \
    '[ERROR] Operation failed.' \
    '[WARN]  Operation warning.' \
    '[INFO]  Init version: test-init' \
    '[WARN]  System will reboot in 60s.' \
    '[INFO]  Continuing in 60s.' \
    '[INFO]  Select Retry in the web UI to resume.' \
    '[INFO]  Timeout: 3600s. Timeout action: shutdown.' \
    '[WARN]  Wait timed out. Timeout action: shutdown.' \
    '[INFO]  Retry requested. Resuming task.' \
    '[INFO]  Task deleted or aborted. Stopping PXEOS.'; do
    must_fit "$line"
done

if [[ ${PXEOS_CONSOLE_TEST_SHOW_SAMPLE:-} == 1 ]]; then
    printf '%s\n' 'SAMPLE: dots to error diagnostics'
    sed -n '1,12p' "$tmp/error.out"
fi

echo 'PASS: PXEOS fixed console messages are standardized ASCII'
)
# ===== 原脚本结束：tests/pxeos_console_english_regression.sh =====
