#!/usr/bin/env bash
# 合并后的 PXEOS 回归测试；每个原脚本在独立子 shell 中运行。
set -euo pipefail

# ===== 原脚本：tests/pxeos_capture_finalize_regression.sh =====
(
# 受控回归：重复 capture 的发布收尾只能在临时树中替换目录。
# 所有 SMB/rename 故障由 shell mock 注入；绝不访问真实 /storage、磁盘或网络。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_file_text() { [[ -f $1 && $(<"$1") == "$2" ]] || fail "$3"; }

# The production library has fixed /storage paths.  Substitute only in a
# temporary test copy so the exercised functions use an isolated filesystem.
sed \
    -e 's|^\. /usr/share/pxeos/lib/partition-funcs.sh$|:|' \
    -e 's|/storage|${ROOTPXE_TEST_STORAGE}|g' \
    "$funcs" >"$tmp/funcs.sh"

setup_fixture() {
    ROOTPXE_TEST_STORAGE="$tmp/storage"
    export ROOTPXE_TEST_STORAGE
    rm -rf "$ROOTPXE_TEST_STORAGE"
    source="$ROOTPXE_TEST_STORAGE/dev/001122334455"
    target="$ROOTPXE_TEST_STORAGE/images/repeat"
    backup="$ROOTPXE_TEST_STORAGE/backup/repeat-backup-20260830T104527123Z"
    mkdir -p "$source" "$(dirname "$target")" "$ROOTPXE_TEST_STORAGE/backup"
    printf 'new-image\n' >"$source/d1p1.img"
    printf '3\n' >"$source/.rootpxe-capture-taskid"
    type=up
    taskid=3
    task_token='test-token-0123456789'
    mac='00:11:22:33:44:55'
    macWinSafe=001122334455
    img='images/repeat'
    captureBackupName='repeat-backup-20260830T104527123Z'
    unset rootpxe_finalize_capture_error_reason rootpxe_finalize_capture_error_code
}

set +u
source "$tmp/funcs.sh" 2>/dev/null
set -u
# This regression supplies isolated normalized context; task-context parsing is
# exercised by its dedicated PXEOS checkin/runtime tests.
rootpxe_require_task_context() { return 0; }

# First capture remains a direct non-merging publish and has no backup.
setup_fixture
rootpxe_finalize_capture || fail '首次 capture 未能安全发布'
assert_file_text "$target/d1p1.img" 'new-image' '首次 capture 未发布新镜像'
[[ ! -e $backup ]] || fail '首次 capture 不应创建旧镜像备份'
pass 'first capture publishes without backup'

# 红测：合法重捕获必须将旧版本完整保留到可见的统一备份目录，并发布新版本。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
rootpxe_finalize_capture || fail '合法重复 capture 被安全收尾拒绝'
assert_file_text "$target/d1p1.img" 'new-image' '新 capture 未发布为正式镜像'
assert_file_text "$backup/d1p1.img" 'old-image' '旧镜像未保留到统一备份目录'
assert_file_text "$target/.rootpxe-capture-taskid" '3' '已发布镜像未保留当前任务标记'
[[ ! -e $source ]] || fail '发布成功后 staging source 仍存在'
pass 'recapture replaces by backup and publish'

# 服务端允许 UTF-8 镜像名称；PXEOS 必须将可见中文备份名原样作为单层目录。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
captureBackupName='Rocky中文-backup-20260830T104527123Z'
backup="$ROOTPXE_TEST_STORAGE/backup/$captureBackupName"
rootpxe_finalize_capture || fail 'UTF-8 备份名称被安全收尾拒绝'
assert_file_text "$backup/d1p1.img" 'old-image' 'UTF-8 备份名称未保留旧镜像'
pass 'UTF-8 visible backup name is accepted'

# 备份名称由服务端固化为单级目录名。PXEOS 不得拼接任务 ID、接受隐藏
# 目录或路径穿越，也不得在没有旧镜像的首次捕获中创建备份目录。
setup_fixture
long_backup_name=$(printf 'a%.0s' {1..256})
[[ $backup == "$ROOTPXE_TEST_STORAGE/backup/repeat-backup-20260830T104527123Z" ]] || fail '备份名称不是服务端下发的可见名称'
[[ ! -e "$ROOTPXE_TEST_STORAGE/images/.repeat.rootpxe-capture-backup-3" ]] || fail '旧隐藏备份目录不应出现'
for invalid_backup_name in '' . .. '.hidden-backup' '../escape' 'nested/name' 'nested\\name' $'line\nbreak' "$long_backup_name"; do
    setup_fixture
    mkdir -p "$target"
    printf 'old-image\n' >"$target/d1p1.img"
    captureBackupName="$invalid_backup_name"
    rootpxe_finalize_capture && fail "危险备份名称被接受: $invalid_backup_name"
    [[ ${rootpxe_finalize_capture_error_reason:-} == invalid_backup_name ]] || fail '危险备份名称未返回稳定原因'
done
unset long_backup_name
pass 'server-provided visible backup name is fail-closed'

# Rebuild the published state after the invalid-name cases, which deliberately
# leave their staging directories untouched.
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
rootpxe_finalize_capture || fail '回归幂等状态未能建立'

# 发布已经完成时，仅同任务 marker 可幂等确认；不允许再触碰备份。
rootpxe_finalize_capture || fail '同任务已发布镜像未能幂等确认'
assert_file_text "$target/d1p1.img" 'new-image' '幂等确认改变了已发布镜像'
assert_file_text "$backup/d1p1.img" 'old-image' '幂等确认改变了旧镜像备份'
pass 'same task publication is idempotent'

# 目标上的任何 marker 都代表未确认的发布，不能被下一次 capture 覆盖。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
printf '2\n' >"$target/.rootpxe-capture-taskid"
rootpxe_finalize_capture && fail 'foreign target marker 被错误覆盖'
[[ ${rootpxe_finalize_capture_error_reason:-} == target_marker_present ]] || fail 'foreign target marker 未返回稳定原因'
assert_file_text "$target/d1p1.img" 'old-image' 'foreign target marker 场景修改了旧镜像'
assert_file_text "$source/d1p1.img" 'new-image' 'foreign target marker 场景修改了新 source'
pass 'foreign target marker is rejected'

# 同任务 target marker 也不是可替换的旧版本；只有 source 不存在时才允许幂等。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
printf '3\n' >"$target/.rootpxe-capture-taskid"
rootpxe_finalize_capture && fail '未确认同任务 target marker 被错误覆盖'
[[ ${rootpxe_finalize_capture_error_reason:-} == target_marker_present ]] || fail '同任务 target marker 未返回稳定原因'
pass 'unacknowledged same-task target is not replaced'

# 模拟 SMB 第一次 rename 失败：既有目标与 staging source 都不能改变。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
mv() {
    if [[ $1 == -T && $2 == "$target" && $3 == "$backup" ]]; then
        return 70
    fi
    command mv "$@"
}
rootpxe_finalize_capture && fail '模拟 SMB 备份失败被误报成功'
[[ ${rootpxe_finalize_capture_error_reason:-} == backup_move_failed ]] || fail 'SMB 备份失败未返回稳定原因'
assert_file_text "$target/d1p1.img" 'old-image' 'SMB 备份失败后旧目标被改变'
assert_file_text "$source/d1p1.img" 'new-image' 'SMB 备份失败后新 source 被改变'
unset -f mv
pass 'SMB backup failure preserves both images'

# 模拟 SMB 第二次 rename 失败：旧目标必须回滚，新 source 必须保留。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
mv() {
    if [[ $1 == -T && $2 == "$source" && $3 == "$target" ]]; then
        return 70
    fi
    command mv "$@"
}
rootpxe_finalize_capture && fail '模拟 SMB 发布失败被误报成功'
[[ ${rootpxe_finalize_capture_error_reason:-} == publish_failed_rolled_back ]] || fail 'SMB 发布失败未返回回滚原因'
assert_file_text "$target/d1p1.img" 'old-image' 'SMB 发布失败后旧目标未回滚'
assert_file_text "$source/d1p1.img" 'new-image' 'SMB 发布失败后新 source 未保留'
[[ ! -e $backup ]] || fail '成功回滚后不应遗留备份目录'
unset -f mv
pass 'SMB publish failure rolls back old target'

# 若发布与回滚都失败，不能删除 source 或 backup，也不能伪造成功。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
mv() {
    if [[ $1 == -T && $2 == "$source" && $3 == "$target" ]]; then
        return 70
    fi
    if [[ $1 == -T && $2 == "$backup" && $3 == "$target" ]]; then
        return 71
    fi
    command mv "$@"
}
rootpxe_finalize_capture && fail '模拟 SMB 发布和回滚双失败被误报成功'
[[ ${rootpxe_finalize_capture_error_reason:-} == publish_and_rollback_failed ]] || fail 'SMB 双失败未返回稳定原因'
[[ ! -e $target ]] || fail 'SMB 双失败后不应伪造正式目标'
assert_file_text "$source/d1p1.img" 'new-image' 'SMB 双失败后新 source 未保留'
assert_file_text "$backup/d1p1.img" 'old-image' 'SMB 双失败后旧备份未保留'
unset -f mv
pass 'SMB publish and rollback failure is fail-closed'
# 已存在备份表示中断窗口；不得猜测或抢占它。
setup_fixture
mkdir -p "$backup"
printf 'old-image\n' >"$backup/d1p1.img"
rootpxe_finalize_capture && fail '已有备份的中断状态被错误发布'
[[ ${rootpxe_finalize_capture_error_reason:-} == backup_already_exists ]] || fail '已有备份未返回稳定原因'
assert_file_text "$source/d1p1.img" 'new-image' '中断状态修改了新 source'
assert_file_text "$backup/d1p1.img" 'old-image' '中断状态修改了旧备份'
pass 'existing backup is fail-closed'

# 锁不得抢占：并发 finalizer 必须保留双方数据并明确失败。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
mkdir "$ROOTPXE_TEST_STORAGE/images/.repeat.rootpxe-finalize.lock"
rootpxe_finalize_capture && fail '已有 finalizer 锁被错误抢占'
[[ ${rootpxe_finalize_capture_error_reason:-} == finalize_lock_unavailable ]] || fail '锁冲突未返回稳定原因'
assert_file_text "$target/d1p1.img" 'old-image' '锁冲突修改了旧镜像'
assert_file_text "$source/d1p1.img" 'new-image' '锁冲突修改了新 source'
pass 'finalizer lock is fail-closed'

# 词法路径互含与链接均不得进入 rename。此处 source 使用 img=dev，target 是其父目录。
setup_fixture
img='dev'
rootpxe_finalize_capture && fail 'source/target 路径互含未被拒绝'
[[ ${rootpxe_finalize_capture_error_reason:-} == source_target_overlap ]] || fail '路径互含未返回稳定原因'
pass 'source target overlap is rejected'

setup_fixture
rm -rf "$target"
mkdir -p "$(dirname "$target")"
mkdir -p "$tmp/outside"
ln -s "$tmp/outside" "$target"
if [[ -L $target ]]; then
    rootpxe_finalize_capture && fail '符号链接 target 未被拒绝'
    [[ ${rootpxe_finalize_capture_error_reason:-} == unsafe_target_path ]] || fail '符号链接 target 未返回稳定原因'
    pass 'symlink target is rejected'
else
    printf 'SKIP: symlink target requires a POSIX symlink-capable test filesystem\n'
fi

# The source tree, its `/storage/dev` ancestor, and its task marker must each
# reject links. Git Bash on this host may emulate directory links, so never
# count an unobservable link as coverage.
setup_fixture
rm -rf "$source"
mkdir -p "$tmp/outside-source"
ln -s "$tmp/outside-source" "$source"
if [[ -L $source ]]; then
    rootpxe_finalize_capture && fail '符号链接 source 未被拒绝'
    [[ ${rootpxe_finalize_capture_error_reason:-} == unsafe_source_path ]] || fail '符号链接 source 未返回稳定原因'
    pass 'symlink source is rejected'
else
    printf 'SKIP: symlink source requires a POSIX symlink-capable test filesystem\n'
fi

setup_fixture
rm -rf "$ROOTPXE_TEST_STORAGE/dev"
mkdir -p "$tmp/outside-dev"
ln -s "$tmp/outside-dev" "$ROOTPXE_TEST_STORAGE/dev"
if [[ -L $ROOTPXE_TEST_STORAGE/dev ]]; then
    rootpxe_finalize_capture && fail '符号链接 source ancestor 未被拒绝'
    [[ ${rootpxe_finalize_capture_error_reason:-} == unsafe_source_path ]] || fail '符号链接 source ancestor 未返回稳定原因'
    pass 'symlink source ancestor is rejected'
else
    printf 'SKIP: symlink source ancestor requires a POSIX symlink-capable test filesystem\n'
fi

setup_fixture
printf 'marker-target\n' >"$tmp/marker-target"
rm -f "$source/.rootpxe-capture-taskid"
ln -s "$tmp/marker-target" "$source/.rootpxe-capture-taskid"
if [[ -L $source/.rootpxe-capture-taskid ]]; then
    rootpxe_finalize_capture && fail '符号链接 source marker 未被拒绝'
    [[ ${rootpxe_finalize_capture_error_reason:-} == source_marker_invalid ]] || fail '符号链接 source marker 未返回稳定原因'
    pass 'symlink source marker is rejected'
else
    printf 'SKIP: symlink source marker requires a POSIX symlink-capable test filesystem\n'
fi

# Empty staging data cannot replace a valid image even when its task marker is valid.
setup_fixture
rm -f "$source/d1p1.img"
rootpxe_finalize_capture && fail '零大小 capture source 被错误发布'
[[ ${rootpxe_finalize_capture_error_reason:-} == source_payload_invalid ]] || fail '零大小 source 未返回稳定原因'
[[ ! -e $target ]] || fail '零大小 source 创建了正式目标'
pass 'zero-size source is rejected'

# find 即使先输出部分大小，随后失败也不能被命令替换或循环吞掉。
setup_fixture
find() {
    printf '10\n'
    return 1
}
rootpxe_finalize_capture && fail '部分 find 输出后的失败被错误发布'
[[ ${rootpxe_finalize_capture_error_reason:-} == source_payload_invalid ]] || fail 'find 失败未返回 source payload 原因'
[[ ! -e $target ]] || fail 'find 失败后创建了正式目标'
unset -f find
pass 'find failure is propagated before move'

# EXDEV 会让 mv 回退为复制加删除，必须在任何迁移前拒绝。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
stat() {
    if [[ $1 == -c && $2 == %d && $3 == "$source" ]]; then
        printf '999999\n'
        return 0
    fi
    command stat "$@"
}
rootpxe_finalize_capture && fail '跨文件系统 capture 被错误迁移'
[[ ${rootpxe_finalize_capture_error_reason:-} == cross_device_capture_paths ]] || fail '跨文件系统未返回稳定原因'
assert_file_text "$target/d1p1.img" 'old-image' '跨文件系统场景修改了旧镜像'
assert_file_text "$source/d1p1.img" 'new-image' '跨文件系统场景修改了新 source'
unset -f stat
pass 'cross-device finalization is rejected before move'

# finish 成功后只能删除属于当前任务的一个普通 marker，且同一锁保护。
setup_fixture
mkdir -p "$target"
printf 'new-image\n' >"$target/d1p1.img"
printf '3\n' >"$target/.rootpxe-capture-taskid"
mkdir "$ROOTPXE_TEST_STORAGE/images/.repeat.rootpxe-finalize.lock"
rootpxe_clear_capture_marker && fail 'marker 清理抢占了已有 finalizer 锁'
assert_file_text "$target/.rootpxe-capture-taskid" '3' '锁冲突时 marker 被错误清理'
rmdir "$ROOTPXE_TEST_STORAGE/images/.repeat.rootpxe-finalize.lock"
rootpxe_clear_capture_marker || fail '当前任务 marker 未能安全清理'
[[ ! -e $target/.rootpxe-capture-taskid ]] || fail '当前任务 marker 未被清理'

printf '2\n' >"$target/.rootpxe-capture-taskid"
rootpxe_clear_capture_marker && fail 'foreign marker 被错误清理'
assert_file_text "$target/.rootpxe-capture-taskid" '2' 'foreign marker 被删除或改变'
pass 'marker clearing checks ownership and lock'

printf 'PASS: PXEOS capture finalize regression\n'
)
# ===== 原脚本结束：tests/pxeos_capture_finalize_regression.sh =====

# ===== 原脚本：tests/pxeos_pipeline_regression.sh =====
(
# 受控回归：验证 capture/restore/完成回调的失败不能被 shell 流水线掩盖。
# 所有外部命令均由临时 PATH mock 提供；绝不访问真实磁盘或网络。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
imgcomplete="$overlay/bin/pxeos.imgcomplete"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got=$1 want=$2)"; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
count_file="${MOCK_CURL_COUNT:?}"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
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
rootpxe_console_message() { printf '%-7s %s\n' "[$1]" "$2"; }
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
assert_eq "$marker_warning_rc" 0 'finish 确认后的 marker 清理失败不得变成业务失败'
grep -Fq 'CODE=CAPTURE_MARKER_CLEAR_FAILED' "$tmp/marker-warning.out" || fail 'marker 清理失败必须输出稳定告警码'
grep -Fxq 'Done' "$tmp/marker-warning.out" || fail 'finish 成功状态行必须在 marker 告警前结束'
grep -Fqx '[INFO]  Task complete.' "$tmp/marker-warning.out" || fail 'Task complete 必须在 finish 确认流程结束后输出'
done_line=$(grep -n -m1 -x 'Done' "$tmp/marker-warning.out" | cut -d: -f1)
warning_line=$(grep -n -m1 'CODE=CAPTURE_MARKER_CLEAR_FAILED' "$tmp/marker-warning.out" | cut -d: -f1)
complete_line=$(grep -n -m1 -F '[INFO]  Task complete.' "$tmp/marker-warning.out" | cut -d: -f1)
[[ $done_line =~ ^[1-9][0-9]*$ && $warning_line =~ ^[1-9][0-9]*$ && $complete_line =~ ^[1-9][0-9]*$ && $done_line -lt $warning_line && $warning_line -lt $complete_line ]] || fail 'finish状态、marker告警和Task Complete的输出顺序错误'
[[ ! -e $tmp/marker-warning-cleared && -f $tmp/marker-warning-json-cleared ]] || fail 'marker 失败应保留 marker 并仍清理任务上下文'
pass 'finish-confirmed marker cleanup failure is warning-only'

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

sed 's|^\. /usr/share/pxeos/lib/partition-funcs.sh$|:|' "$funcs" > "$tmp/funcs.sh"
set +u
PATH="$tmp/bin:$PATH"
source "$tmp/funcs.sh" 2>/dev/null
set -u
imgFormat=2
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
printf 'payload' > "$fifo"
exit 0
EOF
chmod +x "$tmp/bin/partclone.extfs"
export MOCK_ERROR_FILE="$tmp/capture-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 91; }
    getPartitionNumber() { part_number=1; }
    fsTypeSetting() { fstype=extfs; }
    getPartType() { parttype=0x83; }
    debugPause() { :; }
    imgPartitionType=all
    storage=mock
    img=image
    imgFormat=2
    PIGZ_COMP=-6
    writer_pids=()
    savePartition /dev/mockp1 1 "$tmp/capture-image"
) 
save_rc=$?
set -e
assert_eq "$save_rc" 91 'savePartition 必须将 writer 失败升级为任务失败'
grep -Fq 'PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_FAILED' "$tmp/capture-error" || fail 'capture writer 失败必须携带稳定 stage/code'
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
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 92; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/restore-image" /dev/mockp1 no
) 
restore_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$restore_rc" 92 'restore decoder 失败必须升级为任务失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_PIPELINE_FAILED' "$tmp/restore-error" || fail 'restore 失败必须携带稳定 stage/code'
pass 'restore decoder failure is not masked by partclone success'

# split 格式传入的是 img* glob；恢复时必须按 shell glob 顺序读取全部普通文件，
# 不能把星号当作字面路径，也不能接受无匹配或目录。
mkdir -p "$tmp/split"
printf 'a' > "$tmp/split/d1p1.img.000"
printf 'b' > "$tmp/split/d1p1.img.001"
printf 'c' > "$tmp/split/d1p1.img.010"
cat > "$tmp/bin/cat" <<'EOF'
#!/bin/sh
: "${MOCK_CAT_ARGS:?}"
for source_file in "$@"; do
    printf '%s\n' "$source_file" >> "$MOCK_CAT_ARGS"
    printf '%s\n' payload
done
EOF
cat > "$tmp/bin/zstdmt" <<'EOF'
#!/bin/sh
while IFS= read -r _line; do :; done
exit 0
EOF
cat > "$tmp/bin/partclone.restore" <<'EOF'
#!/bin/sh
while IFS= read -r _line; do :; done
exit 0
EOF
chmod +x "$tmp/bin/cat" "$tmp/bin/zstdmt" "$tmp/bin/partclone.restore"
export MOCK_CAT_ARGS="$tmp/split-cat-args"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    : > "$MOCK_CAT_ARGS"
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 94; }
    cat() {
        local source_file
        for source_file in "$@"; do
            [[ $source_file == -- ]] && continue
            printf '%s\n' "$source_file" >> "$MOCK_CAT_ARGS"
            printf '%s\n' payload
        done
    }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/d1p1.img*" /dev/mockp1 no
)
split_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_rc" 0 'split 镜像 glob 应按顺序恢复'
expected_split_args="$(printf '%s\n' "$tmp/split/d1p1.img.000" "$tmp/split/d1p1.img.001" "$tmp/split/d1p1.img.010")"
actual_split_args="$(<"$MOCK_CAT_ARGS")"
assert_eq "$actual_split_args" "$expected_split_args" 'split 镜像必须保持 shell glob 分片顺序'
pass 'split image glob is expanded safely and in order'

export MOCK_ERROR_FILE="$tmp/split-no-match-error"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 95; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/missing*" /dev/mockp1 no
)
split_missing_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_missing_rc" 95 '无匹配 split glob 必须在写盘前失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE' "$tmp/split-no-match-error" || fail '无匹配 split glob 必须使用稳定错误码'
pass 'split image glob rejects no-match safely'

mkdir -p "$tmp/split/not-an-image.img.000"
export MOCK_ERROR_FILE="$tmp/split-directory-error"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 96; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/not-an-image.img*" /dev/mockp1 no
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
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 93; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    cat() { return 11; }
    writeImage "$tmp/restore-image" /dev/mockp1 no
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

awk '/^rootpxe_capture_recovery_disarm\(\)/ { copy = 1 } /^beginUpload\(\)/ { copy = 0 } copy' "$upload" >"$tmp/capture-recovery.sh"
[[ -s $tmp/capture-recovery.sh ]] || fail 'capture source recovery helpers were not extracted'

recovery_trace="$tmp/capture-recovery.trace"
rootpxe_e2fsck_preflight() { printf 'e2fsck:%s\n' "$1" >>"$recovery_trace"; return 0; }
resize2fs() { printf 'resize2fs:%s\n' "$1" >>"$recovery_trace"; return 0; }
ntfsresize() { printf 'ntfsresize:%s\n' "${*: -1}" >>"$recovery_trace"; return 0; }
ntfsfix() { printf 'ntfsfix:%s\n' "${*: -1}" >>"$recovery_trace"; return 0; }
mount() { printf 'mount:%s\n' "$*" >>"$recovery_trace"; return 0; }
umount() { printf 'umount:%s\n' "$*" >>"$recovery_trace"; return 0; }
btrfs() {
    printf 'btrfs:%s\n' "$*" >>"$recovery_trace"
    [[ ${RECOVERY_BTRFS_FAIL:-0} -eq 0 ]]
}
flock() { printf 'flock:%s\n' "$*" >>"$recovery_trace"; [[ ${RECOVERY_FLOCK_FAIL:-0} -eq 0 ]]; }
udevadm() { printf 'udevadm:%s\n' "$*" >>"$recovery_trace"; return 0; }
blockdev() { printf 'blockdev:%s\n' "$*" >>"$recovery_trace"; return 0; }
fdisk() { printf 'fdisk:%s\n' "$*" >>"$recovery_trace"; return 0; }
rootpxe_console_message() { printf 'console:%s:%s\n' "$1" "$2" >>"$recovery_trace"; }
. "$tmp/capture-recovery.sh"

mkdir -p "$tmp/image"
printf 'label: gpt\n' >"$tmp/image/d1.original.partitions"
: >"$recovery_trace"
rootpxe_capture_recovery_arm /dev/mock "$tmp/image" ''
[[ -r ${rootpxe_capture_recovery_local_table:-} ]] || fail 'capture recovery did not stage a local original partition table'
rm -f "$tmp/image/d1.original.partitions"
rootpxe_capture_note_partition_shrunk /dev/mockp2 extfs
rootpxe_capture_recover_source || fail 'local partition-table copy did not recover an unavailable image-path table'
[[ -z ${rootpxe_capture_recovery_local_table:-} ]] || fail 'successful source recovery did not clean the local partition-table copy'
pass 'capture rollback uses and cleans a local original partition table copy'

printf 'label: gpt\n' >"$tmp/image/d1.original.partitions"
: >"$recovery_trace"
rootpxe_capture_recovery_arm /dev/mock "$tmp/image" ''
rootpxe_capture_note_partition_shrunk /dev/mockp2 extfs
rootpxe_capture_note_partition_shrunk /dev/mockp4 ntfs
rootpxe_capture_recover_source || fail 'capture failure did not restore the source disk'
grep -Fqx 'resize2fs:/dev/mockp2' "$recovery_trace" || fail 'shrunk extfs was not expanded during source recovery'
grep -Fqx 'ntfsresize:/dev/mockp4' "$recovery_trace" || fail 'shrunk NTFS was not expanded during source recovery'
before_recovery_calls=$(wc -l <"$recovery_trace")
rootpxe_capture_recover_source || fail 'disarmed source recovery must be a no-op success'
after_recovery_calls=$(wc -l <"$recovery_trace")
[[ $before_recovery_calls -eq $after_recovery_calls ]] || fail 'source recovery ran more than once'

printf 'label: gpt\n' >"$tmp/image/d1.original.partitions"
rootpxe_capture_recovery_arm /dev/mock "$tmp/image" ''
[[ -r ${rootpxe_capture_recovery_local_table:-} ]] || fail 'normal capture cleanup test did not stage a local table'
rootpxe_capture_recovery_disarm
[[ -z ${rootpxe_capture_recovery_local_table:-} ]] || fail 'normal capture cleanup did not remove the local table'

: >"$recovery_trace"
RECOVERY_FLOCK_FAIL=1
printf 'label: gpt\n' >"$tmp/image/d1.original.partitions"
rootpxe_capture_recovery_arm /dev/mock "$tmp/image" ''
rootpxe_capture_note_partition_shrunk /dev/mockp2 extfs
set +e
rootpxe_capture_recover_source
rollback_status=$?
set -e
[[ $rollback_status -ne 0 ]] || fail 'partition-table restore failure must remain visible'
! grep -Fq 'resize2fs:/dev/mockp2' "$recovery_trace" || fail 'filesystem expansion must not run after failed table recovery'
[[ -z ${rootpxe_capture_recovery_local_table:-} ]] || fail 'failed source recovery did not clean the local partition-table copy'
before_recovery_calls=$(wc -l <"$recovery_trace")
rootpxe_capture_recover_source || fail 'failed rollback must still disarm recursive recovery'
after_recovery_calls=$(wc -l <"$recovery_trace")
[[ $before_recovery_calls -eq $after_recovery_calls ]] || fail 'failed rollback retried recursively'
pass 'capture failures restore shrunk source partitions once and fail closed'

printf 'label: gpt\n' >"$tmp/image/d1.original.partitions"
: >"$recovery_trace"
RECOVERY_FLOCK_FAIL=0
RECOVERY_BTRFS_FAIL=0
rootpxe_capture_recovery_arm /dev/mock "$tmp/image" ''
rootpxe_capture_note_partition_shrunk /dev/mockp5 btrfs
rootpxe_capture_recover_source || fail 'btrfs source recovery failed'
grep -Fq 'mount:-t btrfs /dev/mockp5 ' "$recovery_trace" || fail 'btrfs source recovery did not mount a private recovery directory'
grep -Fq 'btrfs:filesystem resize max ' "$recovery_trace" || fail 'btrfs source recovery did not expand the filesystem'
grep -Fq 'umount:' "$recovery_trace" || fail 'btrfs source recovery did not unmount its recovery directory'

printf 'label: gpt\n' >"$tmp/image/d1.original.partitions"
: >"$recovery_trace"
RECOVERY_BTRFS_FAIL=1
rootpxe_capture_recovery_arm /dev/mock "$tmp/image" ''
rootpxe_capture_note_partition_shrunk /dev/mockp5 btrfs
rootpxe_capture_note_partition_shrunk /dev/mockp4 ntfs
set +e
rootpxe_capture_recover_source
btrfs_recovery_status=$?
set -e
[[ $btrfs_recovery_status -ne 0 ]] || fail 'btrfs expansion failure must fail the overall source recovery'
grep -Fq 'umount:' "$recovery_trace" || fail 'btrfs recovery failure did not unmount the private directory'
grep -Fqx 'ntfsresize:/dev/mockp4' "$recovery_trace" || fail 'source recovery stopped before attempting later partitions'
[[ -z ${rootpxe_capture_recovery_local_table:-} ]] || fail 'btrfs recovery failure did not clean the local partition-table copy'
before_recovery_calls=$(wc -l <"$recovery_trace")
rootpxe_capture_recover_source || fail 'btrfs recovery must disarm after a failure'
after_recovery_calls=$(wc -l <"$recovery_trace")
[[ $before_recovery_calls -eq $after_recovery_calls ]] || fail 'btrfs recovery retried recursively'
pass 'btrfs rollback expands safely and continues after individual failures'

shrink_source="$tmp/shrink-partition.sh"
awk '/^shrinkPartition\(\)/ { copy = 1 } /^# Resets the dirty bits/ { copy = 0 } copy' "$funcs" >"$shrink_source"
expand_source="$tmp/expand-partition.sh"
awk '/^expandPartition\(\)/ { copy = 1 } /^# Shrinks partitions for upload/ { copy = 0 } copy' "$funcs" >"$expand_source"
! grep -Fq 'rootpxe_capture_note_partition_shrunk' "$expand_source" \
    || fail 'normal partition expansion must not register a capture rollback entry'
awk '/^[[:space:]]*btrfs\)/ { btrfs = 1 } btrfs && /rootpxe_capture_note_partition_shrunk/ { found = 1 } END { exit found ? 0 : 1 }' "$shrink_source" \
    || fail 'successful btrfs shrink must register a capture rollback entry'
extfs_shrink_line=$(grep -n 'resize2fs "\$part" -M' "$shrink_source" | head -n 1 | cut -d: -f1)
extfs_note_line=$(awk -v start="$extfs_shrink_line" 'NR > start && /rootpxe_capture_note_partition_shrunk "\$part" "\$fstype"/ { print NR; exit }' "$shrink_source")
extfs_partition_line=$(awk -v start="$extfs_shrink_line" 'NR > start && /resizePartition "\$part" "\$sizeextresize"/ { print NR; exit }' "$shrink_source")
[[ $extfs_shrink_line =~ ^[1-9][0-9]*$ && $extfs_note_line =~ ^[1-9][0-9]*$ && $extfs_partition_line =~ ^[1-9][0-9]*$ \
    && $extfs_shrink_line -lt $extfs_note_line && $extfs_note_line -lt $extfs_partition_line ]] \
    || fail 'extfs source recovery must be armed before partition resize can fail'
ntfs_shrink_line=$(grep -n 'yes | ntfsresize -fs' "$shrink_source" | head -n 1 | cut -d: -f1)
ntfs_note_line=$(awk -v start="$ntfs_shrink_line" 'NR > start && /rootpxe_capture_note_partition_shrunk "\$part" "\$fstype"/ { print NR; exit }' "$shrink_source")
ntfs_partition_line=$(awk -v start="$ntfs_shrink_line" 'NR > start && /resizePartition "\$part"/ { print NR; exit }' "$shrink_source")
[[ $ntfs_shrink_line =~ ^[1-9][0-9]*$ && $ntfs_note_line =~ ^[1-9][0-9]*$ && $ntfs_partition_line =~ ^[1-9][0-9]*$ \
    && $ntfs_shrink_line -lt $ntfs_note_line && $ntfs_note_line -lt $ntfs_partition_line ]] \
    || fail 'NTFS source recovery must be armed before partition resize can fail'
pass 'filesystem shrink failures before partition resize remain recoverable'

awk '/^handleError\(\)/ { copy = 1 } /^# Prints a visible banner describing an issue/ { copy = 0 } copy' "$funcs" >"$tmp/handlers.sh"
recovery_hook_trace="$tmp/recovery-hook.trace"
set +e
(
    initversion=test-init
    isdebug=yes
    rootpxe_capture_recover_source() { printf 'recovery-called\n' >"$recovery_hook_trace"; return 1; }
    rootpxe_require_task_context() { return 1; }
    cat() { [[ $1 == /proc/cmdline ]] && { printf 'mock_cmdline=1\n'; return; }; command cat "$@"; }
    debugPause() { :; }
    . "$tmp/handlers.sh"
    handleError 'ORIGINAL_CAPTURE_FAILURE'
) >"$tmp/handler-recovery.out" 2>&1
handler_status=$?
set -e
[[ $handler_status -eq 1 ]] || fail 'capture error handler exit policy changed'
grep -Fqx 'recovery-called' "$recovery_hook_trace" || fail 'capture recovery was not invoked before error reporting'
grep -Fqx '        ORIGINAL_CAPTURE_FAILURE' "$tmp/handler-recovery.out" || fail 'capture recovery overwrote the original error'
grep -Fqx '        PXEOS_STAGE=capture CODE=SOURCE_LAYOUT_RECOVERY_FAILED REASON=rollback_failed' "$tmp/handler-recovery.out" \
    || fail 'capture recovery failure lacks a stable secondary error'
pass 'capture error handling preserves the original failure after one rollback attempt'

grep -Fq 'rootpxe_capture_recover_source ||' "$funcs" || fail 'handleError must invoke capture source recovery before pausing'
grep -Fq 'SOURCE_LAYOUT_RECOVERY_FAILED' "$funcs" || fail 'source recovery failure must preserve the original error with a stable secondary code'
grep -Fq 'rootpxe_capture_recovery_disarm' "$upload" || fail 'successful capture must disarm source recovery'
)
# ===== 单盘可调整镜像的源盘恢复与 extfs 检查结束 =====
