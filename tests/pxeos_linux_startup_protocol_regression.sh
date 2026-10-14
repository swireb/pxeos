#!/usr/bin/env bash
# 仅本地协议 fixture；不调用网络、真实磁盘、目标 systemd 或用户正文。
set -euo pipefail
case $(uname -s) in MINGW*|MSYS*) jq(){ command jq -b "$@"; };; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
awk '/^rootpxe_json_get_string\(\)/{on=1} /^checkin_rootpxe\(\)/{on=0} on{print}' "${CHECKIN_SOURCE:-$overlay/bin/pxeos.checkin}" >"$tmp/parser"
awk '/^rootpxe_run_deploy_script\(\)/{on=1} /^# LVM is deliberately narrow/{on=0} on{print}' "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/executor"
. "$tmp/parser"
. "$tmp/executor"
case $(uname -s) in
    MINGW*|MSYS*)
        rootpxe_deploy_script_identity(){
            local device inode owner links
            IFS=: read -r device inode owner links < <(stat -c '%d:%i:%u:%h' -- "$1")
            printf '%s:%s:%s:700:%s\n' "$device" "$inode" "$owner" "$links"
        }
        printf 'NOTE: private script 0700 metadata mocked on Windows\n';;
esac
printf sentinel >"$tmp/sentinel"
preDeployScriptFile="$tmp/sentinel"; postDeployScriptFile="$tmp/sentinel"; postDeployScriptExecution=unknown
rootpxe_clear_json_deploy_scripts
[[ -f $tmp/sentinel && $(<"$tmp/sentinel") == sentinel ]] || fail '继承路径在checkin清理时被删除'
postDeployScriptFile="$tmp/sentinel"; postDeployScriptExecution=unknown; taskType=deploy; osid=50
rootpxe_run_post_deploy_script && fail '非法mode被执行'
[[ -f $tmp/sentinel ]] || fail '非法mode清理删除了外部文件'
unregistered=$(mktemp /tmp/rootpxe-post-deploy.XXXXXX)
printf sentinel >"$unregistered"; chmod 700 "$unregistered"
rootpxe_release_deploy_script_file "$unregistered"
[[ -f $unregistered ]] || fail '仅有前缀未登记文件被删除'
command rm "$unregistered"
registered=$(mktemp /tmp/rootpxe-post-deploy.XXXXXX)
printf owned >"$registered"; chmod 700 "$registered"
rootpxe_register_deploy_script_file "$registered"
( rootpxe_release_deploy_script_file "$registered" )
[[ -f $registered ]] || fail '子进程继承登记误删除父进程文件'
export -p | grep -q 'rootpxe_deploy_script_\\(files\\|owner_pid\\)' && fail '私有登记被导出'
mv "$registered" "$tmp/registered-original"
printf foreign >"$registered"; chmod 700 "$registered"
rootpxe_release_deploy_script_file "$registered"
[[ $(<"$registered") == foreign ]] || fail 'inode替换后被登记清理删除'
command rm "$registered"
script=$'printf unsafe > /must-not-run\n'
hash=$(printf '%s' "$script" | sha256sum); hash=${hash%% *}
payload=$(jq -cn --arg script "$script" --arg hash "$hash" '{type:"deploy",osid:50,preDeployScript:"",preDeployScriptSha256:"",postDeployScript:$script,postDeployScriptSha256:$hash,postDeployScriptExecution:"linux-systemd-v1"}')
taskType=deploy; osid=50
rootpxe_apply_json_deploy_scripts "$payload" || fail '现代 Linux 载荷被拒绝'
[[ ${postDeployScriptExecution:-} == linux-systemd-v1 && -f ${postDeployScriptFile:-} ]] || fail '明确执行模式未保存'
for filter in 'del(.postDeployScriptExecution)' '.postDeployScriptExecution="unknown"' '.postDeployScriptExecution=3' 'del(.postDeployScript)' 'del(.postDeployScriptSha256)' '.postDeployScriptSha256=("0"*64)'; do
    bad=$(jq "$filter" <<<"$payload")
    rootpxe_apply_json_deploy_scripts "$bad" && fail "非法后置载荷被接受: $filter"
    [[ -z ${postDeployScriptFile:-} && -z ${postDeployScriptExecution:-} ]] || fail '失败残留正文或执行模式'
done
for os in 0 1 2 4 5 6 7 8 9 10 11 51 99; do
    osid=$os
    bad=$(jq --argjson os "$os" '.osid=$os' <<<"$payload")
    rootpxe_apply_json_deploy_scripts "$bad" && fail "非 Linux 后置被接受: $os"
    pre_only=$(jq 'del(.postDeployScript,.postDeployScriptSha256,.postDeployScriptExecution)' <<<"$bad")
    rootpxe_apply_json_deploy_scripts "$pre_only" || fail "非 Linux 正常前置被拒: $os"
done
osid=50; taskType=capture
rootpxe_apply_json_deploy_scripts "$payload" && fail '捕获携带合法后置被接受'
pre_payload=$(jq --arg script "$script" --arg hash "$hash" 'del(.postDeployScript,.postDeployScriptSha256,.postDeployScriptExecution) | .type="capture" | .preDeployScript=$script | .preDeployScriptSha256=$hash' <<<"$payload")
rootpxe_apply_json_deploy_scripts "$pre_payload" && fail '捕获携带合法前置被接受'
taskType=deploy
empty=$(jq '.postDeployScript="" | .postDeployScriptSha256=""' <<<"$payload")
rootpxe_apply_json_deploy_scripts "$empty" || fail 'Linux 空配置受管停用策略被拒'
[[ ${postDeployScriptExecution:-} == linux-systemd-v1 && -z ${postDeployScriptFile:-} ]] || fail '空配置丢失现代停用语义'
rootpxe_clear_json_deploy_scripts
[[ -z ${postDeployScriptExecution:-} ]] || fail '清理保留跨任务模式'
rootpxe_stage(){ :; }
rootpxe_console_message(){ :; }
rootpxe_install_linux_startup_for_disk(){
    [[ $1 == /dev/fixture && $2 == "$postDeployScriptFile" && $3 == "$postDeployScriptSha256" ]] || return 1
    cp "$2" "$tmp/injected"
}
rootpxe_install_linux_startup_for_targets(){ rootpxe_install_linux_startup_for_disk "$3" "$1" "$2"; }
hd=/dev/fixture; disks=/dev/fixture; taskid=42
marker="$tmp/must-not-run"
printf 'printf unsafe > "%s"\n' "$marker" >"$tmp/post"
postDeployScriptFile=$(mktemp /tmp/rootpxe-post-deploy.XXXXXX)
cp "$tmp/post" "$postDeployScriptFile"; chmod 700 "$postDeployScriptFile"
postDeployScriptSha256=$(sha256sum "$postDeployScriptFile"); postDeployScriptSha256=${postDeployScriptSha256%% *}
rootpxe_register_deploy_script_file "$postDeployScriptFile"
post_private="$postDeployScriptFile"
postDeployScriptExecution=linux-systemd-v1
rootpxe_run_post_deploy_script || fail '离线注入入口失败'
[[ -f $tmp/injected && ! -e $marker && ! -e $post_private ]] || fail '后置正文即时执行或未清理'
# 前置始终由 PXEOS Bash 执行，目标类别不改变解释器。
for osid in 50 9 8 99; do
    printf '[[ -z ${task_token+x} ]] && printf pre > "%s"\n' "$tmp/pre-marker" >"$tmp/pre"
    preDeployScriptFile=$(mktemp /tmp/rootpxe-pre-deploy.XXXXXX)
    cp "$tmp/pre" "$preDeployScriptFile"; chmod 700 "$preDeployScriptFile"
    preDeployScriptSha256=$(sha256sum "$preDeployScriptFile"); preDeployScriptSha256=${preDeployScriptSha256%% *}
    rootpxe_register_deploy_script_file "$preDeployScriptFile"
    task_token=secret
    rootpxe_run_pre_deploy_script || fail "前置 Bash 行为改变: $osid"
    [[ $(<"$tmp/pre-marker") == pre ]] || fail '前置未执行'
done
rootpxe_deployment_identity_linux_capabilities_installed(){ return 1; }
rootpxe_deployment_identity_windows_hostname_capability_installed(){ return 1; }
rootpxe_deployment_identity_windows_sysprep_capability_installed(){ return 1; }
rootpxe_multicast_runtime_ready(){ return 1; }
taskid=42; task_token=fixture-token; lmac=00:11:22:33:44:55
rootpxe_write_checkin_json_payload "$tmp/request" || fail 'checkin 请求构建失败'
jq -e '.postDeployScriptCapability=="linux-systemd-v1"' "$tmp/request" >/dev/null || fail '未声明客户端能力'
grep -q 'postDeployScriptCapability=linux-systemd-v1' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail 'disk-permit 未声明能力'
for arch in x64 x86 arm64; do
    for package in LIBSELINUX LIBSEPOL ATTR PCRE2; do
        grep -qx "BR2_PACKAGE_$package=y" "$root/configs/fs$arch.config" || fail "$arch 缺可信标签依赖声明 $package"
    done
done
printf 'PASS: Linux startup protocol 8 groups\n'
