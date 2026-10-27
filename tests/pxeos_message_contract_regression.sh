#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
canonical="$root/../../backend/internal/httpapi/pxe_messages.json"
catalog="$overlay/usr/share/pxeos/pxe_messages.json"
formatter="$overlay/usr/share/pxeos/lib/message-format.sh"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
checks=0
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -r $formatter ]] || fail 'missing display formatter'
cmp -s "$canonical" "$catalog" || fail 'client catalog differs from canonical source'
jq -e '. as $root | .version == 1 and ([keys[]] | sort) == ["codes","console","contextReasons","legacyPrefixes","messages","reasons","stages","version"] and all(.stages,.codes,.reasons,.messages; type == "object" and all(.[]; type == "string")) and (.contextReasons|length) == 8 and (.contextReasons|unique|length) == 8 and all(.contextReasons[]; $root.reasons[.]|type == "string") and (.legacyPrefixes|type) == "object" and (.legacyPrefixes|length) > 0 and all(.legacyPrefixes|to_entries[]; (.key|length) > 0 and ($root.codes[.value]|type) == "string") and all(["stages","codes","reasons","messages"][]; . as $section | ($root[$section]|keys) == ($root.console[$section]|keys) and all($root.console[$section][]; type == "string" and length > 0 and length <= 96 and test("^[ -~]+$")))' "$catalog" >/dev/null || fail 'invalid catalog schema or ASCII console coverage'
. "$formatter"
assert_display(){
    local raw="$1" expected="$2" stage="${3:-}" code="${4:-}" actual
    actual=$(rootpxe_display_message "$raw" "$stage" "$code")
    [[ $actual == "$expected" ]] || fail "display mismatch: $actual"
    checks=$((checks+1))
}
assert_display 'PXEOS_STAGE=cloud_init CODE=CLOUD_INIT_INJECTION_FAILED REASON=cloud_init_not_installed' '目标系统未安装Cloud-init'
assert_display 'code=NVME_FORMAT_FAILED reason=format_command_failed' '磁盘格式化命令失败' nvme_format_failed
assert_display 'CODE=FUTURE_ERROR REASON=cloud_init_not_installed' '写入镜像：执行异常' restore
assert_display 'CODE=CLOUD_INIT_INJECTION_FAILED CODE=RESTORE_PIPELINE_FAILED REASON=cloud_init_not_installed' '写入镜像：执行异常' restore
assert_display 'CODE=CLOUD_INIT_INJECTION_FAILED REASON=cloud_init_not_installed REASON=cloud_init_explicitly_disabled' 'Cloud-init 初始化：执行异常' cloud_init
assert_display 'PXEOS_STAGE=restore PXEOS_STAGE=cloud_init CODE=CLOUD_INIT_INJECTION_FAILED' '写入镜像：执行异常' restore
assert_display 'CODE=cloud_init_injection_failed REASON=cloud_init_not_installed' '目标系统未安装Cloud-init' cloud_init
assert_display 'inventory fields=29' '硬件信息已上报' init
assert_display 'progress=0' '写入镜像：进度已更新' restore
assert_display 'PXEOS checkin completed' '客户端连接完成' checkin
assert_display '正在写入 Cloud-init 配置' '正在写入 Cloud-init 配置' cloud_init
assert_display 'unrecognized raw detail' '执行异常'
while IFS= read -r example; do
    assert_display "$(jq -r .raw <<<"$example")" "$(jq -r .summary <<<"$example")" "$(jq -r .stage <<<"$example")" "$(jq -r .code <<<"$example")"
    actual=$(rootpxe_console_summary "$(jq -r .raw <<<"$example")" "$(jq -r .stage <<<"$example")" "$(jq -r .code <<<"$example")")
    [[ $actual == "$(jq -r .consoleSummary <<<"$example")" ]] || fail "shared console summary mismatch: $actual"
    checks=$((checks+1))
done < <(jq -c '.[]' "$root/../../backend/internal/httpapi/pxe_message_examples.json")

# Missing/corrupt resources and jq failure must keep the fault path available.
original_catalog=$rootpxe_message_catalog
rootpxe_message_catalog="$root/no-such-catalog.json"
assert_display 'CODE=CLOUD_INIT_INJECTION_FAILED' '执行异常'
[[ $(rootpxe_console_summary 'CODE=CLOUD_INIT_INJECTION_FAILED') == 'Operation failed; check task log' ]] || fail 'missing catalog console fallback changed'
rootpxe_message_catalog=$original_catalog
jq(){ return 127; }
assert_display 'CODE=CLOUD_INIT_INJECTION_FAILED' '执行异常'
[[ $(rootpxe_console_summary 'CODE=CLOUD_INIT_INJECTION_FAILED') == 'Operation failed; check task log' ]] || fail 'missing jq console fallback changed'
unset -f jq

# Only stable human messages are translated at the stage reporting boundary.
# A diagnostic stage callback must retain its technical metadata unchanged.
eval "$(sed -n '/^rootpxe_stage() {$/,/^}$/p' "$funcs")"
rootpxe_require_task_context(){ return 0; }
taskid=9 task_token=fixture-only mac=001122334455 pxeapi=https://example.invalid/pxe/v1/
callback_message='' callback_stage=''
rootpxe_task_curl(){
    local argument
    for argument in "$@"; do
        case $argument in message=*) callback_message=${argument#message=};; stage=*) callback_stage=${argument#stage=};; esac
    done
}
rootpxe_stage cloud_init 'installing native NoCloud seed'
[[ $callback_stage == cloud_init && $callback_message == '正在写入 Cloud-init 配置' ]] || fail 'stage human message was not translated'
raw_stage='code=NVME_FORMAT_FAILED reason=format_command_failed target_sector=4096'
rootpxe_stage nvme_format_failed "$raw_stage"
[[ $callback_stage == nvme_format_failed && $callback_message == "$raw_stage" ]] || fail 'stage technical metadata changed'

# The console gets a short display; the full redacted diagnostic still goes to
# the task log, and handleError must pass its original safe_str to retry logic.
eval "$(sed -n '/^rootpxe_task_console_failure() {$/,/^}$/p' "$funcs")"
declare -A rootpxe_task_log_state=()
log_detail='' console_detail=''
rootpxe_redact_diagnostic(){ printf '%s' "$1"; }
rootpxe_task_log_append(){ log_detail+="$1"$'\n'; }
rootpxe_console_message(){ console_detail="$2"; }
rootpxe_task_log_notice(){ :; }
rootpxe_utf8_safe_prefix(){ printf '%s' "$1"; }
raw='PXEOS_STAGE=cloud_init CODE=CLOUD_INIT_INJECTION_FAILED REASON=cloud_init_not_installed'
rootpxe_task_console_failure ERROR "$raw"
[[ $log_detail == *"$raw"* ]] || fail 'raw diagnostic was lost from the task log'
[[ $console_detail == 'Cloud-init is not installed' ]] || fail 'console must show short ASCII without raw metadata'
rootpxe_task_console_failure WARN 'Mock warning details'
[[ $console_detail == 'Warning; check task log' ]] || fail 'unknown warning must not claim an operation failed'
[[ $log_detail == *'Mock warning details'* ]] || fail 'raw warning was lost from the task log'
rootpxe_task_console_failure WARN 'PXEOS_STAGE=restore CODE=FUTURE_ERROR'
[[ $console_detail == 'Warning; check task log' ]] || fail 'unknown staged warning must use the warning fallback'
rootpxe_task_console_failure WARN "$raw"
[[ $console_detail == 'Cloud-init is not installed' ]] || fail 'known warning diagnostic must keep its specific summary'
rootpxe_task_console_failure ERROR 'Mock failure details'
[[ $console_detail == 'Operation failed; check task log' ]] || fail 'unknown error fallback changed'

raw_detail='Deployment layout apply failed: SFDISK_WRITE_FAILED (native_failure); diagnostics: /tmp/log/sfdisk-write.log'
display_detail='PXEOS_STAGE=layout_apply CODE=SFDISK_WRITE_FAILED REASON=native_failure'
log_detail=''
rootpxe_task_console_failure ERROR "$raw_detail" "$display_detail"
[[ $console_detail == 'Partition table write failed' ]] || fail 'optional display input was not used'
[[ $log_detail == *"$raw_detail"* && $log_detail != *"$display_detail"* ]] || fail 'display-only diagnostic replaced the original log detail'
unset -f rootpxe_console_summary
rootpxe_task_console_failure WARN 'Mock warning without formatter'
[[ $console_detail == 'Warning; check task log' ]] || fail 'warning fallback must work without the formatter'
rootpxe_task_console_failure ERROR 'Mock error without formatter'
[[ $console_detail == 'Operation failed; check task log' ]] || fail 'error fallback must work without the formatter'
grep -Fq 'rootpxe_error_wait_for_retry "$safe_str" "PXEOS_ERROR" console_shown' "$funcs" || fail 'raw error callback contract changed'
grep -Fq 'stage_count -eq 1 && $stage_invalid -eq 0' "$funcs" || fail 'safe recovery stage whitelist changed'
printf 'PXEOS messages: %s display checks and log/callback contracts passed\n' "$checks"
