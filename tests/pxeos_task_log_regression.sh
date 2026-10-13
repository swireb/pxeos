#!/usr/bin/env bash
# 只使用普通文件、命令替身及私有 FIFO，不访问块设备。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
. "$root/tests/task-log-test-support.sh"
tmp=$(mktemp -d /tmp/pxeos-task-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# 导入函数定义而不执行 funcs 的内核参数与业务启动代码。
task_log_test_load_helpers "$funcs"
for name in rootpxe_task_log_initialize rootpxe_task_log_valid rootpxe_task_log_append rootpxe_run_logged_mutation; do
    declare -F "$name" >/dev/null || fail "missing $name"
done
checks=0
check(){ checks=$((checks+1)); "$@" || fail "$*"; }
rootpxe_task_log_file="$tmp/environment.log"; export rootpxe_task_log_file
rootpxe_task_log_initialized=yes; export rootpxe_task_log_initialized
rootpxe_task_log_initialize
log=$(rootpxe_task_log_path)
check test "$log" != "$tmp/environment.log"
check test -f "$log"
check test ! -L "$log"
check test "$(stat -c %a "$log")" = 600
rootpxe_task_log_append 'first diagnostic'
# 再次导入只保留可信当前 shell 状态，不清空日志。
eval "$(sed -n '/^rootpxe_task_log_initialize() {/,/^}/p' "$funcs")"
check grep -Fq 'first diagnostic' "$log"
old_log=$log; old_identity=$(stat -c '%d:%i' "$log"); rootpxe_task_log_initialize; log=$(rootpxe_task_log_path)
check test "$log" = "$old_log"
check test "$(stat -c '%d:%i' "$log")" != "$old_identity"
check bash -c '! grep -Fq "first diagnostic" "$1"' _ "$log"
# Source-only definitions preserve context; an exec attempt explicitly starts
# a new trusted file, rather than accepting any inherited scalar marker.
for name in $(declare -F | awk '{print $3}' | grep -E '^rootpxe_(task_|run_logged|redact|utf8|bound_callback)'); do declare -f "$name"; done >"$tmp/helpers"
before_source=$log; . "$tmp/helpers"
check test "$(rootpxe_task_log_path)" = "$before_source"
declare -f rootpxe_log_directory rootpxe_log_type_valid rootpxe_log_new_file rootpxe_log_pin_valid rootpxe_log_pin_release rootpxe_log_pin_readonly rootpxe_log_pin_register >"$tmp/paths"
printf '\ntask_log_test_emulate_pin_flags\n' >>"$tmp/paths"
child_log=$(rootpxe_task_log_state=forged bash -c '. "$1"; . "$2"; . "$3"; rootpxe_task_log_initialize; rootpxe_task_log_path' _ "$root/tests/task-log-test-support.sh" "$tmp/paths" "$tmp/helpers")
check test "$child_log" = "$log"
check test -f "$child_log"
rootpxe_task_log_initialize
( unset rootpxe_task_log_state; rootpxe_task_console_failure ERROR 'Independent failure' ) >"$tmp/fallback"
check grep -Fq "Task log: $tmp/log/pxeos-task.log" "$tmp/fallback"
rootpxe_task_log_initialize
task_token=very-secret-task-token; password=very-secret-password
rootpxe_task_log_append 'bare very-secret-task-token very-secret-password token=unknown-secret {"password":"json-secret","executionToken":"json-token"}'
check bash -c '! grep -Eq "very-secret|unknown-secret|json-secret|json-token" "$1"' _ "$log"
rootpxe_task_log_append "password='space secret value' https://fake.invalid/?token=query-secret&ok=1"$'\n''{"password":"escaped\"quote-secret","token":"escaped\\slash-secret"}'
check bash -c '! grep -Eq "space secret|query-secret|quote-secret|slash-secret" "$1"' _ "$log"
execution_token='known\nsecret-fragment'
rootpxe_task_log_append '{"password":"first\nsecond"} bare known\nsecret-fragment\nArgs Passed: hidden-argv-fragment'
check bash -c '! grep -Eq "first|second|secret-fragment|hidden-argv-fragment" "$1"' _ "$log"
newline_callback=$(rootpxe_bound_callback_message '{"password":"first\nsecond"} bare known\nsecret-fragment\nArgs Passed: hidden-argv-fragment')
check bash -c '[[ $1 != *first* && $1 != *second* && $1 != *secret-fragment* && $1 != *hidden-argv-fragment* ]]' _ "$newline_callback"
unset execution_token
for count in 65001 65535; do
    printf -v boundary '%0*d' "$count" 0
    printf '%s' "$boundary" | rootpxe_task_log_stream fake /dev/vg/root
    check grep -Fq TRUNCATED "$log"
done
utf8=$(printf '中%.0s' {1..22000})
rootpxe_task_log_append "$utf8"
check test "$(wc -c <"$log")" -lt 400000
# Byte slicing must never retain an incomplete UTF-8 sequence.
check test "$(rootpxe_utf8_safe_prefix "$utf8" 65000 | wc -c)" -eq 64998
printf '%s' "$utf8" | rootpxe_task_log_stream fake /dev/vg/root
check grep -Fq TRUNCATED "$log"
printf '%s\nLAST_NATIVE_ERROR\n' "$boundary" | rootpxe_task_log_stream fake /dev/vg/root
check grep -Fq LAST_NATIVE_ERROR "$log"
check test "$(rootpxe_utf8_safe_tail "$utf8" 64000 | wc -c)" -eq 63999
rootpxe_task_console_failure ERROR 'First cause CODE=FAKE_FAIL\nSecond cause token=hidden' >"$tmp/console"
check test "$(grep -o 'CODE=FAKE_FAIL' "$tmp/console" | wc -l)" -eq 1
check bash -c '! grep -Fq "Second cause" "$1"' _ "$tmp/console"
check grep -Fq 'Second cause token=[REDACTED]' "$log"
rootpxe_task_console_failure ERROR 'Native error CODE=ARGS_SAFE\nNative detail remains\n   Args Passed: fake-argv-secret --private something' >"$tmp/argv-console"
check bash -c '! grep -Fq "fake-argv-secret" "$1" "$2"' _ "$log" "$tmp/argv-console"
check grep -Fq 'Native detail remains' "$log"
check grep -Fq 'CODE=ARGS_SAFE' "$tmp/argv-console"
safe_callback=$(rootpxe_bound_callback_message 'Native error CODE=ARGS_SAFE\nArgs Passed: callback-argv-secret')
check bash -c '[[ $1 != *callback-argv-secret* && $1 == *CODE=ARGS_SAFE* ]]' _ "$safe_callback"
# A failed logger must never masquerade as a retained diagnostic.
TASK_LOG_TEST_LOCK_BUSY=yes
rc=0; rootpxe_task_log_append locked || rc=$?
check test "$rc" -ne 0
rootpxe_task_log_notice >"$tmp/unavailable"
check grep -Fq unavailable "$tmp/unavailable"
TASK_LOG_TEST_LOCK_BUSY=no
native(){ printf 'blocks files UUID diagnostic\n'; printf 'native failure detail\n' >&2; return "${native_rc:-0}"; }
TASK_LOG_TEST_LOCK_BUSY=yes
native_rc=7; rc=0; rootpxe_run_logged_mutation fake /dev/vg/root native >"$tmp/locked-native" 2>&1 || rc=$?
check test "$rc" -eq 7
TASK_LOG_TEST_LOCK_BUSY=no
native_rc=0; rootpxe_run_logged_mutation lvextend /dev/vg/root native >"$tmp/native.out" 2>&1
if [[ -s $tmp/native.out ]]; then cat "$tmp/native.out" >&2; fail native-success-console-noise; fi
checks=$((checks+1))
check grep -Fq 'native failure detail' "$log"
native_rc=7; rc=0; rootpxe_run_logged_mutation lvextend /dev/vg/root native >"$tmp/native-fail.out" 2>&1 || rc=$?
check test "$rc" -eq 7
native_changes_job() { native_parent_changed=yes; sleep 0.01 & local native_worker=$!; wait "$native_worker"; printf 'LAST_BACKGROUND_NATIVE_ERROR\n'; return 7; }
rc=0; rootpxe_run_logged_mutation fake /dev/vg/root native_changes_job >"$tmp/native-job.out" 2>&1 || rc=$?
check test "$rc" -eq 7
check test "$native_parent_changed" = yes
check grep -q LAST_BACKGROUND_NATIVE_ERROR "$log"
check bash -c '! grep -Eq "not a child|Task log: unavailable" "$1"' _ "$tmp/native-job.out"
# Raw allocation/read failure is diagnostic-only; approved native still runs.
saved_raw=$(declare -f rootpxe_log_raw_file)
rootpxe_log_raw_file(){ return 1; }
native_rc=7; rc=0; rootpxe_run_logged_mutation fake /dev/vg/root native >"$tmp/fd-open-failure" 2>&1 || rc=$?
check test "$rc" -eq 7
check grep -Fq 'Task log: unavailable' "$tmp/fd-open-failure"
eval "$saved_raw"
saved_snapshot=$(declare -f rootpxe_log_snapshot)
rootpxe_log_snapshot(){ return 1; }
rc=0; rootpxe_run_logged_mutation fake /dev/vg/root native >"$tmp/fd-close-failure" 2>&1 || rc=$?
check test "$rc" -eq 7
check grep -Fq 'Task log: unavailable' "$tmp/fd-close-failure"
eval "$saved_snapshot"
native_rc=1; rc=0; rootpxe_run_logged_mutation e2fsck /dev/vg/root native >"$tmp/fsck.out" 2>&1 || rc=$?
check test "$rc" -eq 1
# 非包装查询与镜像字节不改变。
check test "$(printf query-data)" = query-data
printf '\000\001\377image' >"$tmp/image"; cat "$tmp/image" >"$tmp/image-copy"
check cmp -s "$tmp/image" "$tmp/image-copy"
large=$(printf '%070000d' 0); rootpxe_task_log_append "$large"
check grep -Fq TRUNCATED "$log"
for ((i=0;i<70;i++)); do rootpxe_task_log_append "$large"; done
rootpxe_task_log_append 'LATEST ERROR CODE=LATEST_FAIL TARGET=/dev/vg/root'
check test "$(wc -c <"$log")" -le 4194304
check grep -Fq 'LATEST ERROR CODE=LATEST_FAIL' "$log"
callback=$(rootpxe_bound_callback_message "$(printf '%0270000d' 0)")
check test "$(printf '%s' "$callback" | wc -c)" -le 262144
check bash -c '[[ $1 == *"TRUNCATED: Task log:"* ]]' _ "$callback"
# 替换成 symlink 不得继续写，也不能伪报真实路径。
printf sentinel >"$tmp/other"; rm "$log"; ln -s "$tmp/other" "$log"
[[ -L $log ]] || printf 'NOTE: emulated symlink tests replacement inode rejection, not native Linux symlinks.\n' >&2
rc=0; rootpxe_task_log_valid || rc=$?
check test "$rc" -ne 0
rootpxe_task_log_append ignored >/dev/null 2>&1 || true
check test "$(cat "$tmp/other")" = sentinel
rm -f "$log" "$old_log" "$child_log"
printf 'Task log: %s checks, 0 failures\n' "$checks"
