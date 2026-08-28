#!/bin/bash
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
    backup="$ROOTPXE_TEST_STORAGE/images/.repeat.rootpxe-capture-backup-3"
    mkdir -p "$source" "$(dirname "$target")"
    printf 'new-image\n' >"$source/d1p1.img"
    printf '3\n' >"$source/.rootpxe-capture-taskid"
    type=up
    taskid=3
    task_token='test-token-0123456789'
    mac='00:11:22:33:44:55'
    macWinSafe=001122334455
    img='images/repeat'
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

# 红测：合法重捕获必须将旧版本完整保留在同父级备份，并发布新版本。
setup_fixture
mkdir -p "$target"
printf 'old-image\n' >"$target/d1p1.img"
rootpxe_finalize_capture || fail '合法重复 capture 被安全收尾拒绝'
assert_file_text "$target/d1p1.img" 'new-image' '新 capture 未发布为正式镜像'
assert_file_text "$backup/d1p1.img" 'old-image' '旧镜像未保留为同父级备份'
assert_file_text "$target/.rootpxe-capture-taskid" '3' '已发布镜像未保留当前任务标记'
[[ ! -e $source ]] || fail '发布成功后 staging source 仍存在'
pass 'recapture replaces by backup and publish'

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
