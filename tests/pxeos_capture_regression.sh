#!/usr/bin/env bash
# 合并后的 PXEOS 回归测试；每个原脚本在独立子 shell 中运行。
set -euo pipefail

# 当前发布/对象/恢复矩阵位于 pxeos_storage_controller_test.py；不再测试已退役的MAC暂存和shell锁。


# ===== 原脚本：tests/pxeos_pipeline_regression.sh =====
(
# 受控回归：验证 capture/restore/完成回调的失败不能被 shell 流水线掩盖。
# 所有外部命令均由临时 PATH mock 提供；绝不访问真实磁盘或网络。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/tests/task-http-test-support.sh"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
progress_lib="$overlay/usr/share/pxeos/lib/partclone-progress.sh"
imgcomplete="$overlay/bin/pxeos.imgcomplete"
tmp="$(mktemp -d)"
. "$root/tests/storage-test-support.sh"
ROOTPXE_PROGRESS_STATUS_FILE="$tmp/status.pxeos"
export ROOTPXE_PROGRESS_STATUS_FILE
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got=$1 want=$2)"; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
count_file="${MOCK_CURL_COUNT:?}"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
if [ -n "${MOCK_CURL_ARGS:-}" ]; then printf '%s\n' "$*" > "$MOCK_CURL_ARGS"; fi
if [ "${MOCK_CURL_MODE:-transient}" = attention ]; then
    printf '%s\n' ' { "success" : false, "status" : "attention", "error" : "捕获分区清单结构无效" }'
    exit 0
fi
if [ "$count" -eq 1 ]; then
    printf '%s\n' 'transient finish error' >&2
    exit 7
fi
printf '%s\n' '{"success":true}'
EOF
cat > "$tmp/bin/dmidecode" <<'EOF'
#!/bin/sh
printf '%s\n' '00000000-0000-0000-0000-000000000000'
EOF
cat > "$tmp/bin/usleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/dmidecode" "$tmp/bin/usleep"

export rootpxe_pipeline_fixture_funcs="$funcs"
export rootpxe_pipeline_fixture_log="$tmp/task-console.log"
cat > "$tmp/bash_env" <<'EOF'
rootpxe_require_task_context() { return 0; }
rootpxe_stage() { return 0; }
rootpxe_finalize_capture() { return 0; }
rootpxe_build_original_schema() { return 0; }
rootpxe_clear_capture_marker() {
    [[ ${MOCK_MARKER_CLEAR_FAIL:-no} == yes ]] && return 1
    : > "${MOCK_MARKER_CLEARED:?}"
}
rootpxe_cleanup_task_json() { : > "${MOCK_JSON_CLEARED:?}"; }
rootpxe_capture_resume_cleanup() { :; }
rootpxe_storage_recover_until_clean() { printf 'recovered\n' >>"${MOCK_JSON_CLEARED:?}.recovery"; }
rootpxe_deployment_identity_policy_enabled() { [[ ${MOCK_IDENTITY:-no} == yes ]]; }
rootpxe_console_message() { printf '%-7s %s\n' "[$1]" "$2"; }
declare -A rootpxe_task_log_state=()
rootpxe_task_log_append() { printf '%s\n' "$1" >>"$rootpxe_pipeline_fixture_log"; }
rootpxe_task_log_notice() { :; }
. "${rootpxe_pipeline_fixture_funcs%/*}/message-format.sh"
for function in rootpxe_task_console_failure rootpxe_redact_diagnostic rootpxe_utf8_safe_prefix; do
    eval "$(sed -n "/^${function}() {$/,/^}$/p" "$rootpxe_pipeline_fixture_funcs")"
done
dots() { :; }
debugPause() { :; }
handleError() { printf 'HANDLE_ERROR:%s\n' "$*" >&2; exit 91; }
EOF

# 红测：在 bash -e 的运行器中，第一次 curl 临时失败必须仍可进入第二次重试。
set +e
PATH="$tmp/bin:$PATH" BASH_ENV="$tmp/bash_env" MOCK_CURL_COUNT="$tmp/curl-count" \
    MOCK_MARKER_CLEARED="$tmp/marker-cleared" MOCK_JSON_CLEARED="$tmp/json-cleared" \
    type=down taskid=1 task_token=secret mac=001122334455 web='http://mock/' \
    bash -e "$imgcomplete" >"$tmp/imgcomplete.out" 2>"$tmp/imgcomplete.err"
imgcomplete_rc=$?
set -e
assert_eq "$imgcomplete_rc" 0 '完成回调临时失败后应重试并成功'
assert_eq "$(cat "$tmp/curl-count")" 2 '完成回调应执行两次 curl'
[[ -f "$tmp/marker-cleared" && -f "$tmp/json-cleared" ]] || fail '成功后必须执行安全清理'
pass 'finish retry survives bash errexit'

# Deployment finish is accepted only when it proves the frozen plan and
# current execution attempt that already produced the identity result.
identity_plan="$tmp/identity-plan.json"
printf '%s\n' '{"plan":{"planId":"plan-finish"},"planHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$identity_plan"
PATH="$tmp/bin:$PATH" BASH_ENV="$tmp/bash_env" MOCK_IDENTITY=yes MOCK_CURL_COUNT="$tmp/identity-curl-count" MOCK_CURL_ARGS="$tmp/identity-curl-args" \
    MOCK_MARKER_CLEARED="$tmp/identity-marker-cleared" MOCK_JSON_CLEARED="$tmp/identity-json-cleared" \
    type=down taskid=1 task_token=secret mac=001122334455 web='http://mock/' progress_attempt=3 rootpxe_deployment_identity_plan_file="$identity_plan" \
    bash -e "$imgcomplete" >"$tmp/identity-finish.out" 2>"$tmp/identity-finish.err"
grep -Fq 'planId=plan-finish' "$tmp/identity-curl-args" || fail 'identity finish omitted planId'
grep -Fq 'planHash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/identity-curl-args" || fail 'identity finish omitted planHash'
grep -Fq 'attempt=3' "$tmp/identity-curl-args" || fail 'identity finish omitted attempt'
pass 'identity finish binds frozen plan and attempt'

# 红测：服务端已将任务转为 attention 时，完成回调不能继续重试并掩盖首个错误。
set +e
PATH="$tmp/bin:$PATH" BASH_ENV="$tmp/bash_env" MOCK_CURL_MODE=attention MOCK_CURL_COUNT="$tmp/attention-curl-count" \
    MOCK_MARKER_CLEARED="$tmp/attention-marker-cleared" MOCK_JSON_CLEARED="$tmp/attention-json-cleared" \
    type=down taskid=1 task_token=secret mac=001122334455 web='http://mock/' \
    bash -e "$imgcomplete" >"$tmp/attention.out" 2>"$tmp/attention.err"
attention_rc=$?
set -e
assert_eq "$attention_rc" 91 '服务端 attention 必须立刻进入故障等待，不能继续 finish 重试'
assert_eq "$(cat "$tmp/attention-curl-count")" 1 '服务端 attention 后不得再次请求 finish'
grep -Fqx '[ERROR] RootPXE rejected the finish callback.' "$tmp/attention.out" || fail '必须输出稳定的完成回调错误'
! grep -Fq '捕获分区清单结构无效' "$tmp/attention.out" || fail '不得输出服务端动态错误文本'
grep -Fq 'PXEOS_STAGE=finish_notify CODE=FINISH_REJECTED' "$tmp/attention.err" || fail 'attention 必须交给统一故障等待处理'
[[ ! -e $tmp/attention-marker-cleared && ! -e $tmp/attention-json-cleared ]] || fail 'attention 时不得清理 capture marker 或任务上下文'
! grep -Fq '[INFO]  Task complete.' "$tmp/attention.out" || fail 'attention 时不得误报 Task complete'
pass 'finish attention response stops retry and preserves the original error'

# finish 已被服务端确认后，marker 的保守清理失败只能留下告警，不能把已完成
# 的业务任务重新报告为失败或让终端显示提前完成。
printf '1' >"$tmp/marker-warning-curl-count"
set +e
PATH="$tmp/bin:$PATH" BASH_ENV="$tmp/bash_env" MOCK_CURL_COUNT="$tmp/marker-warning-curl-count" \
    MOCK_MARKER_CLEARED="$tmp/marker-warning-cleared" MOCK_JSON_CLEARED="$tmp/marker-warning-json-cleared" \
    MOCK_MARKER_CLEAR_FAIL=yes type=down taskid=1 task_token=secret mac=001122334455 web='http://mock/' \
    bash -e "$imgcomplete" >"$tmp/marker-warning.out" 2>"$tmp/marker-warning.err"
marker_warning_rc=$?
set -e
if [[ $marker_warning_rc != 0 ]]; then tail -n 5 "$tmp/marker-warning.err" >&2; fi
assert_eq "$marker_warning_rc" 0 'finish 确认后的 marker 清理失败不得变成业务失败'
grep -Fq 'CODE=CAPTURE_MARKER_CLEAR_FAILED' "$tmp/task-console.log" || fail 'marker 清理失败必须保留原始稳定告警码'
grep -Fq '[WARN]  Storage cleanup is not confirmed. Retrying the original execution.' "$tmp/marker-warning.out" || { cat "$tmp/marker-warning.out" >&2; fail 'marker 清理失败必须输出短告警'; }
grep -Fxq 'Done' "$tmp/marker-warning.out" || fail 'finish 成功状态行必须在 marker 告警前结束'
grep -Fqx '[INFO]  Task complete.' "$tmp/marker-warning.out" || fail 'Task complete 必须在 finish 确认流程结束后输出'
done_line=$(grep -n -m1 -x 'Done' "$tmp/marker-warning.out" | cut -d: -f1)
warning_line=$(grep -n -m1 -F '[WARN]  Storage cleanup is not confirmed. Retrying the original execution.' "$tmp/marker-warning.out" | cut -d: -f1)
complete_line=$(grep -n -m1 -F '[INFO]  Task complete.' "$tmp/marker-warning.out" | cut -d: -f1)
[[ $done_line =~ ^[1-9][0-9]*$ && $warning_line =~ ^[1-9][0-9]*$ && $complete_line =~ ^[1-9][0-9]*$ && $done_line -lt $warning_line && $warning_line -lt $complete_line ]] || fail 'finish状态、marker告警和Task Complete的输出顺序错误'
[[ ! -e $tmp/marker-warning-cleared && -f $tmp/marker-warning-json-cleared ]] || fail 'marker 失败应保留 marker 并仍清理任务上下文'
[[ -f $tmp/marker-warning-json-cleared.recovery ]] || fail 'finish确认后的清理失败未沿原执行恢复'
pass 'finish-confirmed cleanup failure recovers the original execution before completion'

# capture 的压缩器失败时，后台 writer 的 wait 必须返回失败，不能被 split 的成功掩盖。
cat > "$tmp/bin/nproc" <<'EOF'
#!/bin/sh
printf '%s\n' 2
EOF
cat > "$tmp/bin/pigz" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 7
EOF
cat > "$tmp/bin/split" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
chmod +x "$tmp/bin/nproc" "$tmp/bin/pigz" "$tmp/bin/split"

sed \
    -e 's|^rootpxe_source_core_library partition-funcs.sh.*|:|' \
    -e 's|^rootpxe_source_core_library restore-preflight.sh.*|:|' \
    -e 's|^rootpxe_source_core_library capture-recovery.sh.*|:|' \
    -e 's|^rootpxe_source_core_library deployment-identity.sh.*|:|' \
    "$funcs" > "$tmp/funcs.sh"
cp "$progress_lib" "$tmp/partclone-progress.sh"
cp "$overlay/usr/share/pxeos/lib/capture-direct.sh" "$tmp/capture-direct.sh"
cp "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/task-http.sh" "$tmp/task-http.sh"
cp "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/cloud-init.sh" "$tmp/cloud-init.sh"
cp "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/linux-hostname.sh" "$tmp/linux-hostname.sh"
sed "s|/tmp/log|$tmp/log|g" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/log-paths.sh" >"$tmp/log-paths.sh"
printf '\nif declare -F task_log_test_emulate_pin_flags >/dev/null; then task_log_test_emulate_pin_flags; fi\n' >>"$tmp/log-paths.sh"
for rootpxe_test_funcs_copy in "$tmp/funcs.sh" "$tmp/legacy-funcs.sh"; do
    [[ ! -f $rootpxe_test_funcs_copy ]] || sed -i -e "s|/tmp/log|$tmp/log|g" -e "s|^rootpxe_log_paths_lib=.*|rootpxe_log_paths_lib=$tmp/log-paths.sh|" "$rootpxe_test_funcs_copy"
done
. "$root/tests/task-log-test-support.sh"
set +u
PATH="$tmp/bin:$PATH"
source "$tmp/funcs.sh" 2>/dev/null
storage_test_pipeline_boundaries
set -u
imgFormat=0
PIGZ_COMP=-6
writer_pids=()
fifo="$tmp/capture.fifo"
uploadFormat "$fifo" "$tmp/image"
printf 'payload' > "$fifo"
set +e
rootpxe_wait_for_writer "$rootpxe_last_writer_pid"
writer_rc=$?
set -e
[[ $writer_rc -ne 0 ]] || fail 'capture writer 的压缩失败不能被 split 成功掩盖'
pass 'capture writer pipeline failure is observable'

# 格式 2 的进度 FIFO/状态准备失败或 writer 准备失败必须发生在任何
# Partclone、压缩或分片子进程之前；不能仅杀掉一个 pipeline 父 shell。
cat > "$tmp/bin/partclone.extfs" <<'EOF'
#!/bin/sh
: "${MOCK_CLONE_STARTED:?}"
: > "$MOCK_CLONE_STARTED"
exit 0
EOF
cat > "$tmp/bin/pigz" <<'EOF'
#!/bin/sh
: "${MOCK_COMPRESSOR_STARTED:?}"
: > "$MOCK_COMPRESSOR_STARTED"
exit 0
EOF
cat > "$tmp/bin/split" <<'EOF'
#!/bin/sh
: "${MOCK_SPLIT_STARTED:?}"
: > "$MOCK_SPLIT_STARTED"
exit 0
EOF
chmod +x "$tmp/bin/partclone.extfs" "$tmp/bin/pigz" "$tmp/bin/split"
export MOCK_ERROR_FILE="$tmp/capture-prepare-error" MOCK_CLONE_STARTED="$tmp/clone-started" MOCK_COMPRESSOR_STARTED="$tmp/compressor-started" MOCK_SPLIT_STARTED="$tmp/split-started"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 97; }
    getPartitionNumber() { part_number=1; }
    fsTypeSetting() { fstype=extfs; }
    getPartType() { parttype=0x83; }
    debugPause() { :; }
    uploadFormat() { return 1; }
    ROOTPXE_PROGRESS_STATUS_FILE="$tmp/capture-prepare-progress"
    export ROOTPXE_PROGRESS_STATUS_FILE
    imgPartitionType=all
    storage=mock
    img=image
    imgFormat=0
    PIGZ_COMP=-6
    writer_pids=()
    mkdir -p "$tmp/capture-image"
    savePartition /dev/mockp1 1 "$tmp/capture-image"
)
prepare_rc=$?
set -e
assert_eq "$prepare_rc" 97 'capture writer 准备失败必须升级为任务失败'
[[ ! -e "$MOCK_CLONE_STARTED" && ! -e "$MOCK_COMPRESSOR_STARTED" && ! -e "$MOCK_SPLIT_STARTED" ]] || fail 'capture writer 准备失败后不得启动 clone/compressor/split'
grep -Fq 'PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_SETUP_FAILED' "$tmp/capture-prepare-error" || fail 'capture writer 准备失败必须使用稳定错误码'
pass 'capture prepare failure starts no pipeline subprocess'

# 进度状态文件持久化失败只是遥测故障：真实 clone/writer 仍必须完成。
cat > "$tmp/bin/partclone.extfs" <<'EOF'
#!/bin/sh
fifo=''
previous=''
for arg in "$@"; do
    [ "$previous" = '-O' ] && fifo="$arg"
    previous="$arg"
done
: "${MOCK_CLONE_STARTED:?}"
: > "$MOCK_CLONE_STARTED"
printf 'payload' > "$fifo"
exit 0
EOF
chmod +x "$tmp/bin/partclone.extfs"
export MOCK_CLONE_STARTED="$tmp/telemetry-clone-started" MOCK_UPLOAD_FORMAT_CALLED="$tmp/upload-format-called"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    handleError() { printf '%s\n' "$1" > "$tmp/capture-telemetry-error"; exit 98; }
    getPartitionNumber() { part_number=1; }
    fsTypeSetting() { fstype=extfs; }
    getPartType() { parttype=0x83; }
    debugPause() { :; }
    uploadFormat() {
        : > "$MOCK_UPLOAD_FORMAT_CALLED"
        rm -f "$1"; mkfifo "$1"
        cat "$1" > "$2.000" &
        rootpxe_last_writer_pid=$!
        writer_pids=("$rootpxe_last_writer_pid")
    }
    ROOTPXE_PROGRESS_STATUS_FILE="$tmp/no-such-progress-dir/status.pxeos"
    export ROOTPXE_PROGRESS_STATUS_FILE
    imgPartitionType=all
    storage=mock
    img=image
    imgFormat=0
    PIGZ_COMP=-6
    writer_pids=()
    mkdir -p "$tmp/capture-image"
    savePartition /dev/mockp1 1 "$tmp/capture-image"
)
progress_telemetry_rc=$?
set -e
assert_eq "$progress_telemetry_rc" 0 'progress telemetry persistence failure must not fail capture'
[[ -e "$MOCK_UPLOAD_FORMAT_CALLED" && -e "$MOCK_CLONE_STARTED" && -f "$tmp/capture-image/d1p1.img" ]] || fail 'telemetry failure must not skip the real capture pipeline'
[[ ! -e "$tmp/capture-telemetry-error" ]] || fail 'telemetry persistence failure must not call handleError'
pass 'progress telemetry failure keeps capture writer and producer successful'

# savePartition 必须在移动产物、进入下一分区前同步等待 writer；其失败会进入
# RootPXE attention，而不是落到最终 imgcomplete 成功回调。
cat > "$tmp/bin/partclone.extfs" <<'EOF'
#!/bin/sh
fifo=''
previous=''
for arg in "$@"; do
    [ "$previous" = '-O' ] && fifo="$arg"
    previous="$arg"
done
printf 'Elapsed: 00:00:01, Remaining: 00:00:01, Completed:  42.00%%,   1.00MB/s,\r' >&2
printf 'payload' > "$fifo"
exit 0
EOF
cat > "$tmp/bin/pigz" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 7
EOF
cat > "$tmp/bin/split" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
chmod +x "$tmp/bin/partclone.extfs" "$tmp/bin/pigz" "$tmp/bin/split"
export MOCK_ERROR_FILE="$tmp/capture-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 91; }
    getPartitionNumber() { part_number=1; }
    fsTypeSetting() { fstype=extfs; }
    getPartType() { parttype=0x83; }
    debugPause() { :; }
    imgPartitionType=all
    storage=mock
    img=image
    imgFormat=0
    PIGZ_COMP=-6
    ROOTPXE_PROGRESS_STATUS_FILE="$tmp/capture-progress"
    export ROOTPXE_PROGRESS_STATUS_FILE
    writer_pids=()
    mkdir -p "$tmp/capture-image"
    savePartition /dev/mockp1 1 "$tmp/capture-image"
) 
save_rc=$?
set -e
assert_eq "$save_rc" 91 'savePartition 必须将 writer 失败升级为任务失败'
grep -Fq 'PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_FAILED' "$tmp/capture-error" || fail 'capture writer 失败必须携带稳定 stage/code'
grep -Fq '|42|partclone_progress' "$tmp/capture-progress" || fail 'capture fake Partclone stderr 必须在 writer 失败前被采集'
pass 'savePartition blocks capture success on writer failure'

# restore 中 decoder 非零、partclone 恰好返回 0 时，pipefail 仍必须阻止写盘流程继续。
cat > "$tmp/bin/zstdmt" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 9
EOF
cat > "$tmp/bin/partclone.restore" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
chmod +x "$tmp/bin/zstdmt" "$tmp/bin/partclone.restore"
printf 'image' > "$tmp/restore-image"
rm -f /tmp/pigz1
export MOCK_ERROR_FILE="$tmp/restore-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    rootpxe_require_unused_target_disks() { :; } # 恢复 writer 使用模拟设备。
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 92; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/restore-image" /dev/mockp1
) 
restore_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$restore_rc" 92 'restore decoder 失败必须升级为任务失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_PIPELINE_FAILED' "$tmp/restore-error" || fail 'restore 失败必须携带稳定 stage/code'
pass 'restore decoder failure is not masked by partclone success'

export MOCK_ERROR_FILE="$tmp/split-no-match-error"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 95; }
    rootpxe_require_unused_target_disks() { :; }
    ROOTPXE_PROGRESS_STATUS_FILE="$tmp/split-no-match-progress"
    export ROOTPXE_PROGRESS_STATUS_FILE
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/missing*" /dev/mockp1
)
split_missing_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_missing_rc" 95 '无匹配 split glob 必须在写盘前失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE' "$tmp/split-no-match-error" || fail '无匹配 split glob 必须使用稳定错误码'
[[ ! -e "$tmp/split-no-match-progress" ]] || fail '无匹配 split glob 不得启动进度 decoder'
pass 'split image glob rejects no-match safely'

mkdir -p "$tmp/split/not-an-image.img.000"
export MOCK_ERROR_FILE="$tmp/split-directory-error"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 96; }
    rootpxe_require_unused_target_disks() { :; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/not-an-image.img*" /dev/mockp1
)
split_directory_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_directory_rc" 96 'split glob 命中目录必须在写盘前失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE' "$tmp/split-directory-error" || fail 'split glob 目录必须使用稳定错误码'
pass 'split image glob rejects directories safely'

upload_script="$(<"$overlay/bin/pxeos.upload")"
[[ $upload_script != *'mkfifo /tmp/pigz1'* ]] || fail '原始磁盘 capture 不得忽略独立 FIFO 建立失败'
pass 'raw capture delegates FIFO creation to checked uploadFormat'

# 镜像文件读取进程在后台失败也必须被 wait；不能因为下游刚好返回 0 而成功。
cat > "$tmp/bin/cat" <<'EOF'
#!/bin/sh
exit 11
EOF
cat > "$tmp/bin/zstdmt" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/cat" "$tmp/bin/zstdmt"
rm -f /tmp/pigz1
export MOCK_ERROR_FILE="$tmp/restore-source-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    storage_test_pipeline_boundaries
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 93; }
    rootpxe_require_unused_target_disks() { :; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    cat() { return 11; }
    writeImage "$tmp/restore-image" /dev/mockp1
)
restore_source_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$restore_source_rc" 93 'restore 后台镜像读取失败必须升级为任务失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_FAILED' "$tmp/restore-source-error" || fail 'restore source 失败必须携带稳定 stage/code'
pass 'restore source failure is not masked by downstream success'

printf 'PASS: PXEOS pipeline regression\n'
)
# ===== 原脚本结束：tests/pxeos_pipeline_regression.sh =====

# ===== 单盘可调整镜像的源盘恢复与 extfs 检查 =====
(
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/tests/task-http-test-support.sh"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
upload="$overlay/bin/pxeos.upload"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

awk '/^rootpxe_e2fsck_preflight\(\)/ { copy = 1 } /^rootpxe_error_wait_for_retry\(\)/ { copy = 0 } copy' "$funcs" >"$tmp/e2fsck-helper.sh"
[[ -s $tmp/e2fsck-helper.sh ]] || fail 'extfs preflight helper was not extracted'

e2fsck_trace="$tmp/e2fsck.trace"
e2fsck() {
    local result
    result=${E2FSCK_RESULTS%%,*}
    if [[ $E2FSCK_RESULTS == *,* ]]; then
        E2FSCK_RESULTS=${E2FSCK_RESULTS#*,}
    else
        E2FSCK_RESULTS=''
    fi
    printf '%s\n' "$result" >>"$e2fsck_trace"
    printf 'mock e2fsck exit %s\n' "$result"
    return "$result"
}
. "$tmp/e2fsck-helper.sh"

: >"$e2fsck_trace"
E2FSCK_RESULTS=0
rootpxe_e2fsck_preflight /dev/mockp1 "$tmp/e2fsck.out" || fail 'clean extfs preflight failed'
[[ $(cat "$e2fsck_trace") == 0 ]] || fail 'clean extfs preflight should run once'

: >"$e2fsck_trace"
E2FSCK_RESULTS=1,0
rootpxe_e2fsck_preflight /dev/mockp1 "$tmp/e2fsck.out" || fail 'journal recovery followed by a clean preflight failed'
[[ $(tr '\n' ',' <"$e2fsck_trace") == '1,0,' ]] || fail 'journal recovery must be rechecked exactly once'

: >"$e2fsck_trace"
E2FSCK_RESULTS=1,4
set +e
rootpxe_e2fsck_preflight /dev/mockp1 "$tmp/e2fsck.out"
preflight_status=$?
set -e
[[ $preflight_status -eq 4 ]] || fail 'uncorrected extfs must retain its e2fsck exit code'
[[ $(tr '\n' ',' <"$e2fsck_trace") == '1,4,' ]] || fail 'failed journal recheck must not be retried indefinitely'

: >"$e2fsck_trace"
E2FSCK_RESULTS=8
set +e
rootpxe_e2fsck_preflight /dev/mockp1 "$tmp/e2fsck.out"
preflight_status=$?
set -e
[[ $preflight_status -eq 8 ]] || fail 'serious extfs errors must not be accepted'
[[ $(cat "$e2fsck_trace") == 8 ]] || fail 'serious extfs errors must not be rechecked as corrected'
pass 'extfs preflight only accepts a clean recheck after journal recovery'

 # n 类型只保存捕获源盘的原始布局，绝不为源盘恢复创建额外表文件。
 n_capture=$(awk '/^rootpxe_capture_single_disk\(\)/ { copy = 1 } /^beginUpload\(\)/ { copy = 0 } copy' "$upload")
 grep -Fq 'savePartitionTablesAndBootLoaders "$hd" 1 "$imagePath" "$osid" "$imgPartitionType"' <<<"$n_capture" || fail 'n capture must save d1.partitions as the original layout'
 for forbidden in shrinkPartition movePartition restoreOriginalPartitions d1.minimum.partitions d1.shrunken.partitions rootpxe_capture_recovery; do
     ! grep -Fq "$forbidden" <<<"$n_capture" || fail "n capture must not mutate the source disk: $forbidden"
 done
 ! grep -Fq 'rootpxe_capture_recovery' "$upload" || fail 'n capture must not include source recovery helpers'
pass 'n capture preserves the source layout and only writes d1.partitions'

# The outer capture phase and its GPT table-save substep both emit status.
# `dots` deliberately leaves its result on the current line, so a nested dots
# call must first terminate the outer phase rather than concatenating both
# labels and then printing two independent Done results.
capture_console=$(
    rootpxe_verify_disk_permit_binding() { :; }
    runPartprobe() { :; }
    getPartitions() { parts=/dev/mockp1; }
    rootpxe_partition_progress_plan_disk() { :; }
    isBitlockedPartition() { :; }
    savePartition() { :; }
    dots() { printf '[INFO]  %s' "$*"; }
    rootpxe_console_message() { printf '[%s]  %s\n' "$1" "$2"; }
    savePartitionTablesAndBootLoaders() { dots 'Saving Partition Tables (GPT)'; echo 'Done'; }
    debugPause() { :; }
    eval "$n_capture"
    hd=/dev/mock imagePath=/tmp/mock-image osid=50 imgPartitionType=all
    rootpxe_capture_single_disk
)
mapfile -t capture_console_lines <<<"$capture_console"
[[ ${#capture_console_lines[@]} -eq 3 ]] || fail 'partition table capture status was concatenated or completed twice'
[[ ${capture_console_lines[0]} == '[INFO]  Saving original partition table.' ]] || fail 'outer partition table status must occupy its own line'
[[ ${capture_console_lines[1]} == '[INFO]  Saving Partition Tables (GPT)Done' ]] || fail 'nested GPT status must own the only inline completion result'
[[ ${capture_console_lines[2]} == '[INFO]  Processing disk device: /dev/mock.' ]] || fail 'partition table completion must not offset the next capture status'
pass 'partition table capture status lines do not nest dots'

# Type/scope/format/LVM cross-contract: fixed image types may select a
# partition subset, while n/dd are always all-disk scopes; Partimage is never
# a new capture writer and fixed LVM raw capture is rejected before permit.
grep -Fq 'rootpxe_validate_image_contract || handleError "PXEOS_STAGE=capture CODE=IMAGE_CONTRACT_INVALID' "$upload" || fail 'capture must validate type scope and format before work'
grep -Fq 'imgType:-} == mps' "$upload" || fail 'mps capture must have an explicit LVM rejection path'
grep -Fq 'imgType:-} == mpa' "$upload" || fail 'mpa capture must have an explicit LVM rejection path'
grep -Fq 'rootpxe_disk_has_lvm_pv' "$upload" || fail 'fixed capture must inspect LVM PV signatures'
grep -Fq 'imgFormat:-} == 0 || ${imgFormat:-} == 5' "$funcs" || fail 'capture contract must reject Partimage format 1'
grep -Fq 'case "${imgPartitionType:-}" in all|mbr|[1-9]|10)' "$funcs" || fail 'capture contract must enumerate fixed-image partition scopes'
for legacy_lvm_helper in getLVM getVolumeGroup changeVolumeGroup getLogicalVolumes getLGDevice; do
    ! grep -Eq "^${legacy_lvm_helper}\\(\\)" "$funcs" || fail "obsolete LVM helper remains: $legacy_lvm_helper"
done
pass 'image type scope format and LVM capture contract'
)
# ===== 单盘可调整镜像的捕获布局检查结束 =====
