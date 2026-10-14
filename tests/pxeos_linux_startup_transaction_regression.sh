#!/usr/bin/env bash
# 当前新功能事务故障fixture；不运行目标脚本/systemd或访问真实磁盘。
set -euo pipefail
export MSYS=winsymlinks:nativestrict
root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
. "$lib/linux-startup.sh"
tmp="$(mktemp -d /tmp/pxeos-startup-transaction.XXXXXX)"
trap '[[ $tmp == /tmp/pxeos-startup-transaction.* && -d $tmp && ! -L $tmp ]] && rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
rootpxe_startup_is_root(){ return 0; }
rootpxe_startup_stat(){
    local name="${1##*/}" mode=755
    name="${name#old.}"
    case $name in startup.sh|startup-runner.sh|startup-result.sh) mode=700;; startup.manifest|startup.transaction) mode=600;; rootpxe-startup.service) mode=644;; rootpxe|.startup-new.*) mode=700;; esac
    printf '0:0:%s:1\n' "$mode"
}
rootpxe_startup_check_capabilities(){ return 0; } # 仅测试事务；实际静态能力由installer suite覆盖。
rootpxe_startup_target_selinux(){ rootpxe_startup_selinux_contexts=; }
case $(uname -s) in
    MINGW*|MSYS*)
        jq(){ MSYS2_ARG_CONV_EXCL='/etc/' command jq -b "$@"; }
        chown(){ :; }
        chmod(){ command chmod "$@" 2>/dev/null || true; }
        mkdir(){ local -a args=(); while (( $# )); do if [[ $1 == -m ]]; then shift 2; else args+=("$1"); shift; fi; done; command mkdir "${args[@]}"; }
        rootpxe_startup_readlink(){
            local value
            value=$(command readlink -- "$1") || return 1
            case $1 in */rootpxe-startup.service|*/old.enable|*/.rootpxe-startup-link.*) [[ $value != *rootpxe-startup.service ]] || value=../rootpxe-startup.service;; esac
            printf '%s\n' "$value"
        }
        printf 'NOTE: POSIX metadata/link-move mocked on Windows; byte/hash/inode operations native\n';;
esac
printf 'printf old-version\n' >"$tmp/old"
printf 'printf new-version\n' >"$tmp/new"
old_hash=$(rootpxe_startup_hash "$tmp/old"); new_hash=$(rootpxe_startup_hash "$tmp/new")
# 注入包装只引用当前fixture固定名称，不消费外部cleanup环境。
fault_move="" fault_label=no fault_read=no fault_rm=no fault_rmdir="" inject_foreign=no
rootpxe_startup_move(){
    if [[ -n $fault_move && $2 == *"$fault_move" && $1 != */old.* ]]; then
        fault_move=""
        if [[ $inject_foreign == yes ]]; then printf preserved >"$fixture/etc/rootpxe/foreign"; fi
        return 1
    fi
    command mv -n -- "$1" "$2"
}
rootpxe_startup_label_path(){
    [[ -z ${rootpxe_startup_selinux_contexts:-} ]] || fail '恢复借用了另一根或继承的SELinux策略'
    if [[ $fault_label == yes && $1 == "$fixture/etc/rootpxe/startup.sh" ]]; then fault_label=no; return 1; fi
}
# 保留真实file_matches检查；只在明确发布的新字节上注入一次读回失败。
original_match=$(declare -f rootpxe_startup_file_matches)
eval "${original_match/rootpxe_startup_file_matches/rootpxe_startup_transaction_real_match}"
rootpxe_startup_file_matches(){
    if [[ $fault_read == yes && $1 == "$fixture/etc/rootpxe/startup.sh" && $(rootpxe_startup_hash "$1") == "$new_hash" ]]; then fault_read=no; return 1; fi
    rootpxe_startup_transaction_real_match "$@"
}
rm(){
    local last="${!#}"
    if [[ $fault_rm == yes && $last == */old.startup.sh ]]; then fault_rm=no; return 1; fi
    command rm "$@"
}
rmdir(){
    local last="${!#}"
    if [[ -n $fault_rmdir && $last == "$fixture$fault_rmdir" ]]; then fault_rmdir=""; return 1; fi
    command rmdir "$@"
}
fixture="$tmp/update"; mkdir -p "$fixture/etc"
rootpxe_startup_install_at_root "$fixture" "$tmp/old" "$old_hash" || fail initial-transaction-install
for point in move-unit move-manifest move-enable label readback; do
    case $point in
        move-unit) fault_move=/etc/systemd/system/rootpxe-startup.service;;
        move-manifest) fault_move=/etc/rootpxe/startup.manifest;;
        move-enable) fault_move=/multi-user.target.wants/rootpxe-startup.service;;
        label) fault_label=yes;;
        readback) fault_read=yes;;
    esac
    rootpxe_startup_install_at_root "$fixture" "$tmp/new" "$new_hash" && fail "故障被误报成功:$point"
    [[ $(rootpxe_startup_hash "$fixture/etc/rootpxe/startup.sh") == "$old_hash" ]] || fail "原字节未恢复:$point"
    rootpxe_startup_verify_manifest "$fixture" || fail "完整旧入口未恢复:$point"
    [[ ! -e $fixture/etc/rootpxe/startup.transaction ]] || fail "完整回滚未释放事务:$point"
done
pass '逐步unit/manifest/enable发布、label和读回故障回滚'
fault_move=old.rootpxe-startup.service
rootpxe_startup_install_at_root "$fixture" '' '' && fail 'clear中途故障误报成功'
rootpxe_startup_verify_manifest "$fixture" || fail 'clear中断未完整恢复'
pass '清空中断完整恢复'
fault_rm=yes
rootpxe_startup_install_at_root "$fixture" "$tmp/new" "$new_hash" && fail '已提交清理失败误报成功'
[[ $(jq -r '.state' "$fixture/etc/rootpxe/startup.transaction") == committed ]] || fail '已提交状态丢失'
rootpxe_startup_verify_manifest "$fixture" || fail '已提交结果错误地回滚'
rootpxe_startup_selinux_contexts="$tmp/other-root-policy"
rootpxe_startup_transaction_recover "$fixture" || fail '已提交清理不能重试'
[[ ! -e $fixture/etc/rootpxe/startup.transaction ]] || fail '已提交清理事务未释放'
pass 'rm失败保留committed并核验清理重试'
for point in system-directory foreign-child root-directory; do
    fixture="$tmp/$point"; mkdir -p "$fixture/etc"
    fault_move=/etc/rootpxe/startup.sh
    case $point in
        system-directory) fault_rmdir=/etc/systemd/system/multi-user.target.wants;;
        foreign-child) inject_foreign=yes;;
        root-directory) fault_rmdir=/etc/rootpxe;;
    esac
    rootpxe_startup_install_at_root "$fixture" "$tmp/new" "$new_hash" && fail "首次失败误报成功:$point"
    inject_foreign=no
    [[ -f $fixture/etc/rootpxe/startup.transaction && $(jq -r '.state' "$fixture/etc/rootpxe/startup.transaction") == restored ]] || fail "未保留恢复清理证据:$point"
    [[ ! -e $fixture/etc/rootpxe/startup.sh ]] || fail "首次失败遗留正文:$point"
    if [[ $point == foreign-child ]]; then
        rootpxe_startup_transaction_recover "$fixture" && fail 'foreign子项应保留证据待处理'
        [[ $(<"$fixture/etc/rootpxe/foreign") == preserved ]] || fail 'foreign子项被删除'
        command rm "$fixture/etc/rootpxe/foreign" # 模拟管理员只处理本测试自造的哨兵。
    fi
    rootpxe_startup_selinux_contexts="$tmp/untrusted-policy"
    rootpxe_startup_transaction_recover "$fixture" || fail "清理不能安全重试:$point"
    [[ ! -e $fixture/etc/rootpxe && ! -e $fixture/etc/systemd ]] || fail "本次空目录未清理:$point"
done
pass 'systemd目录rmdir、foreign子项、最终rootpxe rmdir失败重试'
# 不消费任意事务字段或未知stage目录，也不删除伪造引用的哨兵。
fixture="$tmp/damaged"; mkdir -p "$fixture/etc/rootpxe"
printf sentinel >"$tmp/sentinel"
printf '{"version":1,"state":"unknown","stage":"/tmp/sentinel"}\n' >"$fixture/etc/rootpxe/startup.transaction"
rootpxe_startup_transaction_recover "$fixture" && fail '损坏或未知事务被接受'
[[ $(<"$tmp/sentinel") == sentinel && -f $fixture/etc/rootpxe/startup.transaction ]] || fail '损坏事务误删外部路径或证据'
pass '未知/损坏记录fail-closed且保留证据'
