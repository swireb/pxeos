#!/bin/bash
# 由目标 systemd 执行；不消费 PXEOS manifest 或平台环境变量。
rootpxe_startup_stat() { /usr/bin/stat -c '%u:%g:%a:%h' -- "$1"; }
rootpxe_startup_is_root() { [[ $EUID == 0 ]]; }
rootpxe_startup_is_link() { [[ -L $1 ]]; }

rootpxe_startup_check_path() {
    local path=$1 kind=$2 exact_mode=${3:-} node=$1 info uid gid mode links
    [[ $path == /* && $path != *'/../'* && $path != *'/./'* && $path != *'//'* && $path != */.. && $path != */. ]] || return 1
    [[ $kind == file && -f $path || $kind == directory && -d $path ]] || return 1
    while :; do
        ! rootpxe_startup_is_link "$node" || return 1
        info=$(rootpxe_startup_stat "$node") || return 1
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

rootpxe_startup_check_tool() {
    local path=$1 resolved node=$1 info uid gid mode links
    [[ -x $path ]] || return 1
    # /bin 可为 root 所有的 usr-merge 链接；其最终目标和原路径每个组件均须安全。
    while :; do
        if rootpxe_startup_is_link "$node"; then
            info=$(rootpxe_startup_stat "$node") || return 1
            [[ $info == 0:0:* ]] || return 1
        else
            [[ -d $node || $node == "$path" && -f $node ]] || return 1
            info=$(rootpxe_startup_stat "$node") || return 1
            IFS=: read -r uid gid mode links <<<"$info"
            [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
        [[ $node != / ]] || break
        node=${node%/*}; [[ -n $node ]] || node=/
    done
    resolved=$(/usr/bin/readlink -e -- "$path") || return 1
    rootpxe_startup_check_path "$resolved" file
}

rootpxe_startup_check_installed() {
    local tool
    rootpxe_startup_check_path /etc/rootpxe/startup-runner.sh file 700 &&
    rootpxe_startup_check_path /etc/rootpxe/startup-result.sh file 700 &&
    rootpxe_startup_check_path /etc/rootpxe/startup.sh file 700 &&
    rootpxe_startup_check_path /etc/systemd/system/rootpxe-startup.service file 644 &&
    rootpxe_startup_check_path /usr/bin/readlink file || return 1
    for tool in /bin/bash /usr/bin/stat /usr/bin/timeout /usr/bin/systemctl /usr/bin/env /usr/bin/head /usr/bin/mktemp /usr/bin/rm; do
        rootpxe_startup_check_tool "$tool" || return 1
    done
}

rootpxe_startup_systemctl_show() {
    /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C \
        /usr/bin/timeout --signal=TERM --kill-after=1s 5s /usr/bin/systemctl show \
        --no-pager --property=Type,KillMode,Restart,User,Group,StandardOutput,StandardError,RuntimeMaxUSec,TimeoutStopUSec,LogRateLimitIntervalUSec,LogRateLimitBurst,FragmentPath \
        rootpxe-startup.service
}

rootpxe_startup_query_cleanup() {
    [[ -z ${rootpxe_startup_query_file:-} ]] || /usr/bin/rm -f -- "$rootpxe_startup_query_file"
    rootpxe_startup_query_file=
}

rootpxe_startup_query() {
    local directory=${1:-/run} rc
    rootpxe_startup_loaded=
    rootpxe_startup_check_path "$directory" directory || return 1
    rootpxe_startup_query_file=$(/usr/bin/mktemp "$directory/rootpxe-startup-query.XXXXXX") || return 1
    # 非 POSIX Bash 的 -f 单位为 1024 字节。限制仅作用于属性收集子 shell。
    ( set +o posix; ulimit -f 8 || exit 1; rootpxe_startup_systemctl_show >"$rootpxe_startup_query_file" )
    rc=$?
    if [[ $rc == 0 ]]; then
        # 普通文件有界读取不等待持有输出 FD 的后台进程关闭。
        IFS= read -r -N 4097 rootpxe_startup_loaded <"$rootpxe_startup_query_file" || true
        [[ ${#rootpxe_startup_loaded} -le 4096 ]] || rc=1
    fi
    rootpxe_startup_query_cleanup
    return "$rc"
}

rootpxe_startup_validate_loaded() {
    local snapshot=$1 line key value seen='|' count=0
    [[ -n $snapshot && ${#snapshot} -le 4096 ]] || return 1
    while IFS= read -r line; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}
        [[ $seen != *"|$key|"* ]] || return 1
        case "$key:$value" in
            Type:simple|KillMode:control-group|Restart:no|User:root|Group:root|StandardOutput:journal|StandardError:journal|LogRateLimitBurst:100|FragmentPath:/etc/systemd/system/rootpxe-startup.service) ;;
            RuntimeMaxUSec:5min|RuntimeMaxUSec:300s|RuntimeMaxUSec:300000000us|RuntimeMaxUSec:300000000) ;;
            TimeoutStopUSec:10s|TimeoutStopUSec:10000000us|TimeoutStopUSec:10000000) ;;
            LogRateLimitIntervalUSec:30s|LogRateLimitIntervalUSec:30000000us|LogRateLimitIntervalUSec:30000000) ;;
            *) return 1 ;;
        esac
        seen+="$key|"; count=$((count+1))
    done <<<"${snapshot%$'\n'}"
    [[ $count == 12 ]]
}

rootpxe_startup_exec() {
    exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C \
        /bin/bash --noprofile --norc "$1"
}

rootpxe_startup_main() {
    rootpxe_startup_is_root && rootpxe_startup_check_installed || {
        printf 'rootpxe-startup: 不安全的启动文件、父路径或工具\n' >&2; return 78;
    }
    rootpxe_startup_query && rootpxe_startup_validate_loaded "$rootpxe_startup_loaded" || {
        printf 'rootpxe-startup: 目标 systemd 加载属性不满足受管运行约束\n' >&2; return 78;
    }
    rootpxe_startup_exec /etc/rootpxe/startup.sh
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    # 清理对象只能来自本进程的 mktemp，绝不接受继承的环境路径。
    rootpxe_startup_query_file= rootpxe_startup_loaded=
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C
    umask 077
    trap rootpxe_startup_query_cleanup EXIT
    trap 'exit 143' HUP INT TERM
    rootpxe_startup_main
    exit "$?"
fi
