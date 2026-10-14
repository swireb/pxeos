#!/bin/bash
# 主进程状态来自 systemd；采样失败不重写为 success。
rootpxe_result_stat() { /usr/bin/stat -c '%u:%g:%a:%h' -- "$1"; }
rootpxe_result_is_link() { [[ -L $1 ]]; }
rootpxe_result_make_directory() { /usr/bin/mkdir -m 700 -- "$1"; }

rootpxe_result_check_path() {
    local path=$1 kind=$2 exact_mode=${3:-} node=$1 info uid gid mode links
    [[ $path == /* && $path != *'/../'* && $path != *'/./'* && $path != *'//'* && $path != */.. && $path != */. ]] || return 1
    [[ $kind == file && -f $path || $kind == directory && -d $path ]] || return 1
    while :; do
        ! rootpxe_result_is_link "$node" || return 1
        info=$(rootpxe_result_stat "$node") || return 1
        IFS=: read -r uid gid mode links <<<"$info"
        [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
        if [[ $node == "$path" ]]; then
            [[ -z $exact_mode || $mode == "$exact_mode" ]] || return 1
            [[ $kind != file || $links == 1 ]] || return 1
        fi
        [[ $node != / ]] || break
        node=${node%/*}; [[ -n $node ]] || node=/
    done
}

rootpxe_result_check_tool() {
    local path=$1 resolved node=$1 info uid gid mode links
    [[ -x $path ]] || return 1
    while :; do
        if rootpxe_result_is_link "$node"; then
            info=$(rootpxe_result_stat "$node") || return 1
            [[ $info == 0:0:* ]] || return 1
        else
            [[ -d $node || $node == "$path" && -f $node ]] || return 1
            info=$(rootpxe_result_stat "$node") || return 1
            IFS=: read -r uid gid mode links <<<"$info"
            [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
        [[ $node != / ]] || break
        node=${node%/*}; [[ -n $node ]] || node=/
    done
    resolved=$(/usr/bin/readlink -e -- "$path") || return 1
    rootpxe_result_check_path "$resolved" file
}

rootpxe_result_check_destination() {
    local directory=$1 log="$1/startup.log" marker
    if [[ ! -e $directory ]] && ! rootpxe_result_is_link "$directory"; then
        rootpxe_result_check_path "${directory%/*}" directory || return 1
        rootpxe_result_make_directory "$directory" || return 1
    fi
    rootpxe_result_check_path "$directory" directory 700 || return 1
    if [[ -e $log ]] || rootpxe_result_is_link "$log"; then
        rootpxe_result_check_path "$log" file 600 || return 1
        IFS= read -r -n 64 marker <"$log" || return 1
        [[ $marker == ROOTPXE_STARTUP_RESULT_V1 ]] || return 1
    fi
}

rootpxe_result_scalar() {
    if [[ ${1:-} =~ ^[a-zA-Z0-9_.:-]{1,64}$ ]]; then printf '%s' "$1"; else printf unavailable; fi
}

rootpxe_result_hash() {
    rootpxe_result_check_path "$1" file 700 || return 1
    rootpxe_result_check_tool /usr/bin/sha256sum || return 1
    /usr/bin/timeout --signal=TERM --kill-after=1s 1s /usr/bin/sha256sum -- "$1"
}

rootpxe_result_journal_query() {
    rootpxe_result_check_tool /usr/bin/journalctl || return 1
    /usr/bin/timeout --signal=TERM --kill-after=1s 2s /usr/bin/journalctl \
        --no-pager --quiet -n 200 -o short-iso "_SYSTEMD_INVOCATION_ID=$1"
}

rootpxe_result_cleanup() {
    local file
    for file in "${rootpxe_result_temp:-}" "${rootpxe_result_sample:-}"; do
        [[ -z $file ]] || /usr/bin/rm -f -- "$file"
    done
    rootpxe_result_temp= rootpxe_result_sample=
}

rootpxe_result_publish() {
    local directory=$1 size
    size=$(/usr/bin/stat -c %s -- "$rootpxe_result_temp") || return 1
    [[ $size =~ ^[0-9]+$ && $size -le 4194304 ]] &&
        rootpxe_result_check_path "$rootpxe_result_temp" file 600 &&
        rootpxe_result_check_destination "$directory" &&
        /usr/bin/mv -fT -- "$rootpxe_result_temp" "$directory/startup.log" || return 1
    rootpxe_result_temp=
}

rootpxe_result_write_log() {
    local directory=$1 script=$2 max=4194304 reserve=256 hash=unavailable hash_rc journal_rc=skipped capture_rc=0 truncated=0 size sample_size budget
    rootpxe_result_check_destination "$directory" || {
        printf 'rootpxe-startup: 拒绝不安全或非受管的结果日志路径\n' >&2; return 1;
    }
    rootpxe_result_temp=$(/usr/bin/mktemp "$directory/.startup.log.XXXXXX") || return 1
    {
        printf 'ROOTPXE_STARTUP_RESULT_V1\ntime_unix=%(%s)T\n' -1
        printf 'service_result=%s\n' "$(rootpxe_result_scalar "${SERVICE_RESULT:-}")"
        printf 'exit_code=%s\n' "$(rootpxe_result_scalar "${EXIT_CODE:-}")"
        printf 'exit_status=%s\n' "$(rootpxe_result_scalar "${EXIT_STATUS:-}")"
        printf 'invocation_id=%s\n' "$(rootpxe_result_scalar "${INVOCATION_ID:-}")"
    } >"$rootpxe_result_temp" || { rootpxe_result_cleanup; return 1; }
    # 先原子发布状态头；收集详情期间即使被外层 deadline 终止，也已有本次主进程状态。
    rootpxe_result_publish "$directory" || { rootpxe_result_cleanup; return 1; }
    rootpxe_result_temp=$(/usr/bin/mktemp "$directory/.startup.log.XXXXXX") || return 1
    rootpxe_result_sample=$(/usr/bin/mktemp "$directory/.startup.log.XXXXXX") || { rootpxe_result_cleanup; return 1; }
    /usr/bin/head -c 4096 -- "$directory/startup.log" >"$rootpxe_result_temp" || { rootpxe_result_cleanup; return 1; }
    # Hash 也直接写受限普通文件，不等待后台继承 FD 的 EOF。
    ( set +o posix; ulimit -f 1 || exit 1; rootpxe_result_hash "$script" >"$rootpxe_result_sample" )
    hash_rc=$?
    if [[ $hash_rc == 0 ]]; then
        IFS= read -r -n 64 hash <"$rootpxe_result_sample" || true
        [[ $hash =~ ^[a-fA-F0-9]{64}$ ]] || hash=unavailable
    fi
    printf 'script_sha256=%s\nhash_query_exit=%s\n--- journal: current invocation, last 200 records ---\n' "$hash" "$hash_rc" >>"$rootpxe_result_temp" || { rootpxe_result_cleanup; return 1; }
    if [[ ${INVOCATION_ID:-} =~ ^[a-fA-F0-9]{32}$ ]]; then
        # 即使内核拒绝设限，也不能把上一步的 hash 输出误当成 journal 样本。
        : >"$rootpxe_result_sample" || { rootpxe_result_cleanup; return 1; }
        # -f 的 1024 字节块仅限制 journal 收集子 shell，绝不限制用户业务文件。
        ( set +o posix; ulimit -f 4096 || exit 1; rootpxe_result_journal_query "$INVOCATION_ID" >"$rootpxe_result_sample" )
        journal_rc=$?
        size=$(/usr/bin/stat -c %s -- "$rootpxe_result_temp") || { rootpxe_result_cleanup; return 1; }
        [[ $size =~ ^[0-9]+$ && $size -lt $((max-reserve)) ]] || { rootpxe_result_cleanup; return 1; }
        budget=$((max-size-reserve))
        sample_size=$(/usr/bin/stat -c %s -- "$rootpxe_result_sample") || { rootpxe_result_cleanup; return 1; }
        [[ $sample_size =~ ^[0-9]+$ ]] || { rootpxe_result_cleanup; return 1; }
        # 153 为 Linux SIGXFSZ 的 shell 退出码；0/1 只表示字节/收集容量截断。
        [[ $sample_size -le $budget && $journal_rc != 153 ]] || truncated=1
        /usr/bin/head -c "$budget" -- "$rootpxe_result_sample" >>"$rootpxe_result_temp"
        capture_rc=$?
    fi
    printf '\njournal_query_exit=%s\njournal_capture_exit=%s\njournal_truncated=%s\n' "$journal_rc" "$capture_rc" "$truncated" >>"$rootpxe_result_temp" || { rootpxe_result_cleanup; return 1; }
    [[ $capture_rc == 0 ]] && rootpxe_result_publish "$directory" || {
            rootpxe_result_cleanup; printf 'rootpxe-startup: 结果日志原子写入失败\n' >&2; return 1;
        }
    rootpxe_result_cleanup
    if [[ $journal_rc != 0 && $journal_rc != skipped || $hash_rc != 0 ]]; then
        printf 'rootpxe-startup: 已保留主进程状态；hash=%s journal=%s\n' "$hash_rc" "$journal_rc" >&2
    fi
}

rootpxe_result_main() {
    local tool
    [[ $EUID == 0 ]] && rootpxe_result_check_path /etc/rootpxe/startup-result.sh file 700 || {
        printf 'rootpxe-startup: 不安全的结果收尾程序\n' >&2; return 1;
    }
    rootpxe_result_check_path /usr/bin/readlink file || return 1
    for tool in /usr/bin/stat /usr/bin/timeout /usr/bin/head /usr/bin/mktemp /usr/bin/mkdir /usr/bin/mv /usr/bin/rm; do
        rootpxe_result_check_tool "$tool" || { printf 'rootpxe-startup: 不安全或缺失的收尾工具\n' >&2; return 1; }
    done
    rootpxe_result_write_log /var/log/rootpxe /etc/rootpxe/startup.sh || {
        printf 'rootpxe-startup: 结果收尾未完成，主进程状态未被覆盖\n' >&2; return 1;
    }
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    # 清理对象只能来自本进程的 mktemp，绝不接受继承的环境路径。
    rootpxe_result_temp= rootpxe_result_sample=
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C
    umask 077
    trap rootpxe_result_cleanup EXIT
    trap 'exit 143' HUP INT TERM
    rootpxe_result_main
    exit "$?"
fi
