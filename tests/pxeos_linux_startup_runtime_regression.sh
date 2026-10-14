#!/usr/bin/env bash
# 仅使用临时夹具与函数 mock；不查询本机 systemd、不执行部署脚本。
set -euo pipefail
export PATH=/usr/bin:/bin
# Git Bash 默认可能复制 -s 的目标；严格创建链接才能验证真实链接拒绝。
export MSYS=winsymlinks:nativestrict
root=$(cd "$(dirname "$0")/.." && pwd)
templates="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/linux-startup-templates"
tmp=$(mktemp -d /tmp/pxeos-startup-runtime.XXXXXX)
owned_pids=()
cleanup() {
    local pid
    for pid in "${owned_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    [[ $tmp == /tmp/pxeos-startup-runtime.* && -d $tmp && ! -L $tmp && -O $tmp ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
for file in rootpxe-startup.service startup-runner.sh startup-result.sh; do
    [[ -f $templates/$file ]] || fail "missing-template:$file"
done
unit="$templates/rootpxe-startup.service"
for line in \
    'Type=simple' 'User=root' 'Group=root' 'Restart=no' \
    'RuntimeMaxSec=300' 'TimeoutStopSec=10' 'KillMode=control-group' \
    'StandardOutput=journal' 'StandardError=journal' \
    'LogRateLimitIntervalSec=30s' 'LogRateLimitBurst=100' \
    'RequiresMountsFor=/etc/rootpxe /usr /var/log/rootpxe' \
    'After=local-fs.target' 'WantedBy=multi-user.target' \
    'UnsetEnvironment=BASH_ENV ENV SHELLOPTS BASHOPTS CDPATH GLOBIGNORE LD_PRELOAD LD_LIBRARY_PATH' \
    'ExecStart=/bin/bash --noprofile --norc /etc/rootpxe/startup-runner.sh' \
    'ExecStopPost=-/usr/bin/timeout --signal=TERM --kill-after=1s 8s /bin/bash --noprofile --norc /etc/rootpxe/startup-result.sh'; do
    [[ $(grep -Fxc "$line" "$unit") == 1 ]] || fail "unit-contract:$line"
done
if grep -Eq 'network-online|LimitFSIZE|Restart=(always|on-failure)|Type=oneshot|RequiredBy=' "$unit"; then
    fail unexpected-unit-dependency
fi
pass unit-contract

runner_entry=$(awk '/^if .*BASH_SOURCE/{entry=1} entry{print}' "$templates/startup-runner.sh")
result_entry=$(awk '/^if .*BASH_SOURCE/{entry=1} entry{print}' "$templates/startup-result.sh")
[[ $runner_entry == *'rootpxe_startup_query_file= rootpxe_startup_loaded='*'trap rootpxe_startup_query_cleanup EXIT'* ]] || fail inherited-query-cleanup-path
[[ $result_entry == *'rootpxe_result_temp= rootpxe_result_sample='*'trap rootpxe_result_cleanup EXIT'* ]] || fail inherited-result-cleanup-path
pass inherited-cleanup-paths-ignored

source "$templates/startup-runner.sh"
source "$templates/startup-result.sh"
# 本地 Git Bash 无 RLIMIT_FSIZE；Linux 运行时仍使用实际内核限制，失败即拒绝。
if ! ( builtin ulimit -f 8 ) 2>/dev/null; then
    ulimit() { [[ $1 == -f && ( $2 == 1 || $2 == 8 || $2 == 4096 ) ]]; }
    rootpxe_result_make_directory() { /usr/bin/mkdir -- "$1"; }
    printf 'NOTE: host RLIMIT_FSIZE unavailable; collection-limit parameters mocked\n'
fi
grep -Fqx 'rootpxe_startup_is_link() { [[ -L $1 ]]; }' "$templates/startup-runner.sh" || fail runner-link-predicate
grep -Fqx 'rootpxe_result_is_link() { [[ -L $1 ]]; }' "$templates/startup-result.sh" || fail result-link-predicate
grep -Fq '5s /usr/bin/systemctl show' "$templates/startup-runner.sh" || fail query-time-bound
grep -Fq -- '--property=Type,KillMode,Restart,User,Group,StandardOutput,StandardError,RuntimeMaxUSec,TimeoutStopUSec,LogRateLimitIntervalUSec,LogRateLimitBurst,FragmentPath' "$templates/startup-runner.sh" || fail loaded-property-query
grep -Fq -- '--no-pager --quiet -n 200 -o short-iso "_SYSTEMD_INVOCATION_ID=$1"' "$templates/startup-result.sh" || fail current-invocation-only-query
grep -Fq '2s /usr/bin/journalctl' "$templates/startup-result.sh" || fail journal-time-bound
snapshot=$'Type=simple\nKillMode=control-group\nRestart=no\nUser=root\nGroup=root\nStandardOutput=journal\nStandardError=journal\nRuntimeMaxUSec=5min\nTimeoutStopUSec=10s\nLogRateLimitIntervalUSec=30s\nLogRateLimitBurst=100\nFragmentPath=/etc/systemd/system/rootpxe-startup.service'
rootpxe_startup_validate_loaded "$snapshot" || fail loaded-properties
for replacement in 'RuntimeMaxUSec=300s' 'RuntimeMaxUSec=300000000us' 'RuntimeMaxUSec=300000000'; do
    rootpxe_startup_validate_loaded "${snapshot/RuntimeMaxUSec=5min/$replacement}" || fail exact-time-value
done
for key in Type KillMode Restart User Group StandardOutput StandardError RuntimeMaxUSec TimeoutStopUSec LogRateLimitIntervalUSec LogRateLimitBurst FragmentPath; do
    bad=$(printf '%s\n' "$snapshot" | sed "/^$key=/d")
    if rootpxe_startup_validate_loaded "$bad"; then fail "missing-property:$key"; fi
done
for bad in \
    "${snapshot/Type=simple/Type=oneshot}" \
    "${snapshot/User=root/User=admin}" \
    "${snapshot/Group=root/Group=admin}" \
    "${snapshot/StandardOutput=journal/StandardOutput=file}" \
    "${snapshot/StandardError=journal/StandardError=append}" \
    "${snapshot/RuntimeMaxUSec=5min/RuntimeMaxUSec=infinity}" \
    "${snapshot/TimeoutStopUSec=10s/TimeoutStopUSec=11s}" \
    "${snapshot/LogRateLimitIntervalUSec=30s/LogRateLimitIntervalUSec=0}" \
    "${snapshot/LogRateLimitBurst=100/LogRateLimitBurst=0}" \
    "${snapshot/FragmentPath=\/etc\/systemd\/system\/rootpxe-startup.service/FragmentPath=\/usr\/lib\/systemd\/system\/rootpxe-startup.service}" \
    "$snapshot"$'\nUser=root' "$snapshot"$'\nUnknown=1' \
    "$snapshot"$'\nUser=' "$snapshot"$'\nmalformed'; do
    if rootpxe_startup_validate_loaded "$bad"; then fail rejected-property-snapshot; fi
done
pass loaded-properties-fail-closed

# Windows 夹具不能模拟 Linux root 所有权；仅 mock stat 元数据，链接和对象类型使用真实文件系统。
mock_path= mock_uid=0 mock_gid=0 mock_mode= mock_links=1 mock_link=
fixture_stat() {
    local path=$1 mode=700 uid=0 gid=0 links=1
    if [[ -d $path ]]; then
        mode=755
        [[ $path != "$tmp/logs" && $path != "$tmp/first-logs" ]] || mode=700
    elif [[ $path == */startup.log || $path == */.startup.log.* ]]; then mode=600
    fi
    if [[ $path == "$mock_path" ]]; then uid=$mock_uid; gid=$mock_gid; mode=${mock_mode:-$mode}; links=$mock_links; fi
    printf '%s:%s:%s:%s\n' "$uid" "$gid" "$mode" "$links"
}
rootpxe_startup_stat() { fixture_stat "$1"; }
rootpxe_result_stat() { fixture_stat "$1"; }
printf 'NOTE: Linux root uid/gid/mode metadata mocked; fixture files are real\n'
mkdir "$tmp/safe"
printf 'fixture\n' >"$tmp/safe/script.sh"
rootpxe_startup_check_path "$tmp/safe/script.sh" file 700 || fail safe-root-file
mock_path="$tmp/safe/script.sh" mock_uid=1000
if rootpxe_startup_check_path "$tmp/safe/script.sh" file 700; then fail foreign-owner; fi
mock_uid=0 mock_mode=722
if rootpxe_startup_check_path "$tmp/safe/script.sh" file 700; then fail writable-script; fi
mock_mode=700 mock_links=2
if rootpxe_startup_check_path "$tmp/safe/script.sh" file 700; then fail hardlinked-script; fi
mock_path="$tmp/safe" mock_mode=777 mock_links=1
if rootpxe_startup_check_path "$tmp/safe/script.sh" file 700; then fail writable-parent; fi
mock_path= mock_mode=
native_links=true
if ! ln -s script.sh "$tmp/safe/link.sh" 2>/dev/null; then
    native_links=false
    printf 'link fixture\n' >"$tmp/safe/link.sh"
    rootpxe_startup_is_link() { [[ -L $1 || $1 == "${mock_link:-}" ]]; }
    rootpxe_result_is_link() { [[ -L $1 || $1 == "${mock_link:-}" ]]; }
    mock_link="$tmp/safe/link.sh"
    printf 'NOTE: host symlink privilege unavailable; link metadata mocked\n'
fi
if rootpxe_startup_check_path "$tmp/safe/link.sh" file 700; then fail symlink-script; fi
if [[ $native_links == true ]]; then ln -s safe "$tmp/linked-parent";
else mkdir "$tmp/linked-parent"; printf 'fixture\n' >"$tmp/linked-parent/script.sh"; mock_link="$tmp/linked-parent"; fi
if rootpxe_startup_check_path "$tmp/linked-parent/script.sh" file 700; then fail symlink-parent; fi
mock_link=
pass owner-mode-link-contract

rootpxe_startup_systemctl_show() { printf '%s\n' "$snapshot"; }
rootpxe_startup_query "$tmp" || fail finite-property-file
rootpxe_startup_validate_loaded "$rootpxe_startup_loaded" || fail file-property-content
rootpxe_startup_systemctl_show() { printf '%5000s' x; }
if rootpxe_startup_query "$tmp"; then fail oversized-property-output; fi
rootpxe_startup_systemctl_show() { head -c 16000 /dev/zero | tr '\0' x; }
if rootpxe_startup_query "$tmp"; then fail property-file-limit; fi
saved_limit=$(declare -f ulimit || true)
ulimit() { return 1; }
if rootpxe_startup_query "$tmp"; then fail failed-resource-limit-accepted; fi
unset -f ulimit
[[ -z $saved_limit ]] || eval "$saved_limit"
rootpxe_startup_systemctl_show() {
    ( printf '%s\n' "$BASHPID" >"$tmp/query-held-pid"; sleep 8 ) &
    printf '%s\n' "$snapshot"
}
started=$SECONDS
rootpxe_startup_query "$tmp" || fail property-held-background-fd
[[ $((SECONDS-started)) -le 2 && -f $tmp/query-held-pid ]] || fail property-background-fd-blocked
owned_pids+=("$(<"$tmp/query-held-pid")")
[[ -z $(find "$tmp" -maxdepth 1 -name 'rootpxe-startup-query.*' -print) ]] || fail query-temp-leaked
pass property-file-size-and-background-fd-bounds

real_exec=$(declare -f rootpxe_startup_exec)
eval "${real_exec/rootpxe_startup_exec/rootpxe_startup_real_exec}"
rootpxe_startup_is_root() { return 0; }
rootpxe_startup_check_installed() { return 0; }
rootpxe_startup_query() { rootpxe_startup_loaded=$snapshot; return "${query_rc:-0}"; }
rootpxe_startup_exec() { printf started >"$tmp/started"; return 37; }
query_rc=124
if rootpxe_startup_main; then fail query-timeout-accepted; fi
[[ ! -e $tmp/started ]] || fail timeout-started-script
query_rc=1
if rootpxe_startup_main; then fail query-failure-accepted; fi
query_rc=0
set +e
rootpxe_startup_main
run_rc=$?
set -e
[[ $run_rc == 37 && -f $tmp/started ]] || fail main-exit-code
printf '%s\n' \
    '[[ $PATH == /usr/sbin:/usr/bin:/sbin:/bin && $LANG == C ]] || exit 91' \
    '[[ -z ${PXEOS_TASK_TOKEN+x}${STORAGE_PASSWORD+x}${INVOCATION_ID+x}${HOME+x}${BASH_ENV+x} ]] || exit 92' \
    'exit 37' >"$tmp/environment-fixture.sh"
set +e
( export PXEOS_TASK_TOKEN=fixture-token STORAGE_PASSWORD=fixture-secret INVOCATION_ID=old HOME=/old/dev; rootpxe_startup_real_exec "$tmp/environment-fixture.sh" )
run_rc=$?
set -e
[[ $run_rc == 37 ]] || fail clean-environment-or-user-exit-code
pass bounded-gate-clean-environment-real-exit

mkdir "$tmp/logs"
rootpxe_result_hash() { printf '%064d\n' 0; }
rootpxe_result_journal_query() {
    [[ $1 == 0123456789abcdef0123456789abcdef ]] || return 91
    grep -Fqx service_result=exit-code "$tmp/logs/startup.log" || return 92
    printf '%s\n' current-invocation-only
}
export SERVICE_RESULT=exit-code EXIT_CODE=exited EXIT_STATUS=37 INVOCATION_ID=0123456789abcdef0123456789abcdef
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail safe-empty-log-directory
log="$tmp/logs/startup.log"
[[ $(head -n1 "$log") == ROOTPXE_STARTUP_RESULT_V1 ]] || fail managed-log-marker
grep -Fqx service_result=exit-code "$log" || fail main-result-preserved
grep -Fqx exit_status=37 "$log" || fail exit-status-preserved
grep -Fqx current-invocation-only "$log" || fail current-invocation-sample
grep -Fqx journal_truncated=0 "$log" || fail small-sample-marked-truncated
[[ $(stat -c %s "$log") -le 4194304 ]] || fail initial-log-size
rootpxe_result_write_log "$tmp/first-logs" "$tmp/safe/script.sh" || fail first-log-directory-creation
pass status-head-and-managed-log

SERVICE_RESULT=timeout EXIT_CODE=killed EXIT_STATUS=TERM
rootpxe_result_journal_query() { return 124; }
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail journal-timeout-result
grep -Fqx service_result=timeout "$log" || fail timeout-reported-success
grep -Fqx exit_status=TERM "$log" || fail timeout-status-overwritten
grep -Fqx journal_query_exit=124 "$log" || fail journal-timeout-diagnostic
rootpxe_result_journal_query() { return 1; }
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail journal-failure-result
grep -Fqx journal_query_exit=1 "$log" || fail journal-failure-diagnostic
rootpxe_result_journal_query() { return 153; }
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail journal-file-overflow-result
grep -Fqx journal_query_exit=153 "$log" || fail file-overflow-diagnostic
grep -Fqx journal_truncated=1 "$log" || fail file-overflow-not-marked-truncated
rootpxe_result_hash() { return 124; }
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail hash-timeout-result
grep -Fqx script_sha256=unavailable "$log" || fail fabricated-hash
grep -Fqx hash_query_exit=124 "$log" || fail hash-timeout-diagnostic
grep -Fqx service_result=timeout "$log" || fail hash-error-overwrote-main-status
rootpxe_result_hash() { printf '%064d\n' 0; }
INVOCATION_ID=invalid
rootpxe_result_journal_query() { fail invalid-invocation-queried; }
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail invalid-invocation-result
grep -Fqx journal_query_exit=skipped "$log" || fail invalid-invocation-skip
INVOCATION_ID=0123456789abcdef0123456789abcdef
pass timeout-journal-failure-and-invalid-invocation

real_publish=$(declare -f rootpxe_result_publish)
eval "${real_publish/rootpxe_result_publish/rootpxe_result_real_publish}"
publish_calls=0
rootpxe_result_publish() {
    publish_calls=$((publish_calls+1))
    [[ $publish_calls == 1 ]] || return 1
    rootpxe_result_real_publish "$@"
}
rootpxe_result_journal_query() { return 0; }
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail failed-detail-write-accepted; fi
grep -Fqx service_result=timeout "$log" || fail missing-first-atomic-status-head
grep -Fqx exit_status=TERM "$log" || fail overwritten-first-status-head
if grep -Fq script_sha256= "$log"; then fail fabricated-details-after-interruption; fi
eval "$real_publish"
pass status-head-survives-detail-publish-failure

for text_mode in no-newline long-line; do
    rootpxe_result_journal_query() {
        head -c 6000000 /dev/zero | tr '\0' x
        [[ $text_mode == no-newline ]] || printf '\n'
    }
    rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail "large-journal:$text_mode"
    [[ $(stat -c %s "$log") -le 4194304 ]] || fail "byte-cap:$text_mode"
    grep -Fqx service_result=timeout "$log" || fail "lost-status-head:$text_mode"
    grep -Fqx journal_capture_exit=0 "$log" || fail "lost-bounded-tail:$text_mode"
    grep -Fqx journal_truncated=1 "$log" || fail "missing-byte-truncation-marker:$text_mode"
done
pass byte-cap-for-long-line-and-no-newline

rootpxe_result_journal_query() {
    ( printf '%s\n' "$BASHPID" >"$tmp/held-pid"; sleep 8 ) &
    printf '%s\n' held-background-fd
}
started=$SECONDS
rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh" || fail held-background-fd-result
elapsed=$((SECONDS-started))
[[ $elapsed -le 5 && -f $tmp/held-pid ]] || fail background-fd-blocked
owned_pids+=("$(<"$tmp/held-pid")")
grep -Fqx journal_capture_exit=0 "$log" || fail regular-file-background-fd-diagnostic
pass background-fd-does-not-wait-for-eof

original=$(sha256sum "$log")
mock_path="$log" mock_uid=1000
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail foreign-log-overwritten; fi
[[ $(sha256sum "$log") == "$original" ]] || fail foreign-log-mutated
mock_uid=0 mock_mode=644
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail foreign-log-mode; fi
mock_mode=600 mock_links=2
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail hardlinked-log; fi
mock_path="$tmp/logs" mock_mode=755 mock_links=1
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail unsafe-log-directory; fi
mock_path= mock_mode=
printf 'FOREIGN\n' >"$log"
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail unmarked-log-overwritten; fi
[[ $(<"$log") == FOREIGN ]] || fail foreign-log-content-mutated
rm "$log"
if [[ $native_links == true ]]; then ln -s ../safe/script.sh "$log";
else printf 'link fixture\n' >"$log"; mock_link="$log"; fi
if rootpxe_result_write_log "$tmp/logs" "$tmp/safe/script.sh"; then fail symlink-log-overwritten; fi
rootpxe_result_is_link "$log" && [[ $(<"$tmp/safe/script.sh") == fixture ]] || fail symlink-target-mutated
[[ -z $(find "$tmp/logs" -maxdepth 1 -name '.startup.log.*' -print) ]] || fail temporary-log-leaked
pass foreign-log-owner-mode-marker-link-refusal
printf 'Linux startup runtime: PASS\n'
