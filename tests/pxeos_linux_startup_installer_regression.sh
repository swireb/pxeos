#!/usr/bin/env bash
# 本地文件与命令 fixture；mount/LVM/SELinux 均 mock，不接触真实磁盘。
set -euo pipefail
export MSYS=winsymlinks:nativestrict
root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp="$(mktemp -d /tmp/pxeos-startup-installer.XXXXXX)"
trap '[[ $tmp == /tmp/pxeos-startup-installer.* && -d $tmp && ! -L $tmp ]] && rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
[[ -f $lib/linux-startup.sh ]] || fail 'missing-linux-startup-installer'
. "$lib/linux-startup.sh"
fixture="$tmp/target"; mkdir -p "$fixture"
declare -A metadata=()
rootpxe_startup_stat(){
    local mode links
    [[ -z ${metadata[$1]:-} ]] || { printf '%s\n' "${metadata[$1]}"; return; }
    case $1 in
        */startup.manifest|*/old.startup.manifest|*/startup.transaction) mode=600;;
        */startup.sh|*/startup-runner.sh|*/startup-result.sh|*/old.startup.sh|*/old.startup-runner.sh|*/old.startup-result.sh) mode=700;;
        */rootpxe-startup.service|*/old.rootpxe-startup.service) mode=644;;
        */.startup-new.*) mode=700;;
        */rootpxe) mode=700;;
        *) [[ -d $1 ]] && mode=755 || mode=755;;
    esac
    links=1
    printf '0:0:%s:%s\n' "$mode" "$links"
}
rootpxe_startup_is_root(){ return 0; }
case $(uname -s) in
    MINGW*|MSYS*)
        # Windows UID/mode 的业务分支通过上面的明确 metadata mock 检查。
        chown(){ :; }
        mkdir(){ local -a args=(); while (( $# )); do if [[ $1 == -m ]]; then shift 2; else args+=("$1"); shift; fi; done; command mkdir "${args[@]}"; }
        chmod(){ command chmod "$@" 2>/dev/null || true; }
        rootpxe_startup_executable(){ [[ -f $1 ]]; }
        jq(){ MSYS2_ARG_CONV_EXCL='/etc/' command jq -b "$@"; }
        rootpxe_startup_readlink(){
            local value
            value=$(command readlink -- "$1") || return 1
            case $1 in */rootpxe-startup.service|*/old.enable|*/.rootpxe-startup-link.*)
                [[ $value != *rootpxe-startup.service ]] || value=../rootpxe-startup.service;;
            esac
            printf '%s\n' "$value"
        }
        printf 'NOTE: UID/mode/links/managed-link-move mocked on Windows; target-link resolution native\n'
        ;;
esac
rootpxe_startup_templates="$lib/linux-startup-templates"
rootpxe_startup_target_selinux(){ rootpxe_startup_selinux_contexts=; }
empty_root="$tmp/empty-target"; mkdir -p "$empty_root/etc"
rootpxe_startup_install_at_root "$empty_root" '' '' || fail '空配置原部署被新能力拒绝'
[[ ! -e $empty_root/etc/rootpxe && ! -e $empty_root/etc/systemd ]] || fail '无受管hook的空配置不应写入目录'
pass 'empty 无受管hook真正无写入'
make_target(){
    mkdir -p "$fixture/etc/systemd/system/multi-user.target.wants" "$fixture/usr/bin" "$fixture/usr/lib/systemd"
    printf marker >"$fixture/usr/lib/os-release"
    printf marker >"$fixture/usr/lib/systemd/systemd"
    chmod 755 "$fixture/usr/lib/systemd/systemd"
    for tool in bash systemctl timeout stat readlink env head mktemp rm date sha256sum journalctl mv chmod mkdir; do printf fixture >"$fixture/usr/bin/$tool"; chmod 755 "$fixture/usr/bin/$tool"; done
    ln -s usr/bin "$fixture/bin"
    mkdir "$fixture/sbin"
    ln -s /usr/lib/systemd/systemd "$fixture/sbin/init"
    ln -s ../usr/lib/os-release "$fixture/etc/os-release"
}
make_target
[[ $(rootpxe_startup_resolve_target "$fixture" /bin/bash file) == "$fixture/usr/bin/bash" ]] || fail 'usr-merge 路径未正确解析'
[[ $(rootpxe_startup_resolve_target "$fixture" /sbin/init file) == "$fixture/usr/lib/systemd/systemd" ]] || fail '目标内绝对链接未正确解析'
ln -s ../../escape "$fixture/etc/escape"
rootpxe_startup_resolve_target "$fixture" /etc/escape file && fail '根外链接被接受'
rm "$fixture/etc/escape"
ln -s loop "$fixture/etc/loop"
rootpxe_startup_resolve_target "$fixture" /etc/loop file && fail '循环链接被接受'
rm "$fixture/etc/loop"
pass '目标内有限链接解析'
printf 'printf must-not-run\n' >"$tmp/body"
hash=$(sha256sum "$tmp/body"); hash=${hash%% *}
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" || fail "首次注入失败: ${rootpxe_startup_error:-unknown}"
[[ -f $fixture/etc/rootpxe/startup.manifest ]] || fail '受管清单缺失'
cmp "$tmp/body" "$fixture/etc/rootpxe/startup.sh" || fail '正文改变'
[[ $(rootpxe_startup_readlink "$fixture/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service") == ../rootpxe-startup.service ]] || fail '启用链接非固定相对目标'
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" || fail '重复部署失败'
pass '首次与重复部署精确字节及清单'
# 发布/清空中断必须恢复原文件，enable最后恢复；提交后清理可重试。
old_hash=$(rootpxe_startup_hash "$fixture/etc/rootpxe/startup.sh")
printf 'printf next-version\n' >"$tmp/next-body"
next_hash=$(rootpxe_startup_hash "$tmp/next-body")
rootpxe_startup_move(){
    if [[ ${fail_move:-} == yes && $2 == "$fixture/etc/rootpxe/startup.sh" ]]; then fail_move=no; return 1; fi
    command mv "$@"
}
fail_move=yes
rootpxe_startup_install_at_root "$fixture" "$tmp/next-body" "$next_hash" && fail '发布失败被当作成功'
[[ $(rootpxe_startup_hash "$fixture/etc/rootpxe/startup.sh") == "$old_hash" ]] || fail '发布失败未恢复原字节'
rootpxe_startup_verify_manifest "$fixture" || fail '回滚未恢复完整旧清单/链接'
[[ ! -e $fixture/etc/rootpxe/startup.transaction ]] || fail '成功回滚遗留事务'
rootpxe_startup_move(){ command mv -n -- "$1" "$2"; }
pass '发布中断完整恢复'
printf foreign >>"$fixture/etc/rootpxe/startup.sh"
rootpxe_startup_install_at_root "$fixture" '' '' && fail '篡改的受管文件被删除'
cp "$tmp/body" "$fixture/etc/rootpxe/startup.sh"
metadata["$fixture/etc/rootpxe/startup.sh"]=1:0:700:1
rootpxe_startup_install_at_root "$fixture" '' '' && fail '错误属主被清理'
unset 'metadata[$fixture/etc/rootpxe/startup.sh]'
metadata["$fixture/etc/rootpxe/startup.sh"]=0:0:777:1
rootpxe_startup_install_at_root "$fixture" '' '' && fail '错误权限被清理'
unset 'metadata[$fixture/etc/rootpxe/startup.sh]'
rootpxe_startup_install_at_root "$fixture" '' '' || fail '空配置停用失败'
[[ ! -e $fixture/etc/rootpxe/startup.sh && ! -e $fixture/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service ]] || fail '停用遗留入口'
[[ -d $fixture/etc/rootpxe ]] || fail '不应递归删除受管目录'
pass '空配置仅清理已核验受管对象'
printf foreign >"$fixture/etc/rootpxe/startup.sh"
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" && fail '同名 foreign 被覆盖'
[[ $(<"$fixture/etc/rootpxe/startup.sh") == foreign ]] || fail 'foreign 已损坏'
rm "$fixture/etc/rootpxe/startup.sh"
ln -s "$tmp/body" "$fixture/etc/rootpxe/startup.sh"
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" && fail '写路径 symlink 被接受'
rm "$fixture/etc/rootpxe/startup.sh"
mkdir "$fixture/etc/systemd/system/rootpxe-startup.service.d"
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" && fail 'foreign drop-in 被接受'
rmdir "$fixture/etc/systemd/system/rootpxe-startup.service.d"
pass 'foreign、symlink 与 drop-in 拒绝'
mv "$fixture/usr/bin/bash" "$fixture/usr/bin/bash.absent"
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" && fail '缺 Bash 非空被接受'
rootpxe_startup_install_at_root "$fixture" '' '' || fail '无受管入口时空配置不应要求 Bash'
mv "$fixture/usr/bin/bash.absent" "$fixture/usr/bin/bash"
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$(printf '0%.0s' {1..64})" && fail '错误摘要被接受'
pass '非空能力与摘要门禁'
# 标签流程用明确预期路径与值模拟可信 PXEOS 工具，不执行目标工具。
rootpxe_startup_target_selinux(){ rootpxe_startup_selinux_contexts="$tmp/contexts"; }
printf context >"$tmp/contexts"
rootpxe_startup_label_tools_ready(){ return 0; }
declare -A labels=()
rootpxe_startup_expected_label(){ printf 'system_u:object_r:etc_t:s0\n'; }
rootpxe_startup_write_label(){ labels["$1"]=$2; }
rootpxe_startup_read_label(){ printf '%s\n' "${labels[$1]:-}"; }
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" || fail '精确标签写入与读回失败'
rootpxe_startup_read_label(){ printf wrong; }
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" && fail '标签读回不一致被接受'
rootpxe_startup_label_tools_ready(){ return 1; }
rootpxe_startup_install_at_root "$fixture" "$tmp/body" "$hash" && fail 'SELinux 标签工具缺失被接受'
pass 'SELinux 精确标签与能力失败闭合'
# 文件系统/激活所有权在 mock 中留证，绝不真的 mount 或 vgchange。
rootpxe_verify_disk_permit_binding(){ [[ $1 == /dev/fixture && $2 == deploy_write ]]; }
rootpxe_linux_root_fstype_supported(){ [[ $1 =~ ^(ext4|xfs|btrfs)$ ]]; }
rootpxe_find_linux_root_filesystem(){ printf '%s\n' "$fixture_candidate"; }
rootpxe_linux_activate_vg_if_needed(){ printf '%s\n' "$activate"; }
rootpxe_linux_cleanup_selected_vg(){ printf 'vg:%s:%s:%s\n' "$1" "$2" "$3" >>"$tmp/events"; }
rootpxe_startup_mount_target(){ rootpxe_startup_mounted_root="$fixture"; rootpxe_startup_root_owned=$owned; }
rootpxe_startup_mount_usr(){ rootpxe_startup_usr_owned=no; }
rootpxe_startup_install_at_root(){ printf 'installed:%s\n' "$1" >>"$tmp/events"; }
umount(){ printf 'umount:%s\n' "$1" >>"$tmp/events"; }
rootpxe_startup_probe_workspace_remove(){ [[ $1 == /tmp/rootpxe-startup-mount.* && -d $1 && ! -L $1 ]] && rmdir -- "$1"; }
taskType=deploy; osid=50; postDeployScriptExecution=linux-systemd-v1
for fixture_candidate in '/dev/fixture1|ext4|||' '/dev/vg/root|xfs|vg|vg-uuid|' '/dev/fixture1|btrfs|||256'; do
    for owned in yes no; do
        : >"$tmp/events"; activate=no
        [[ $fixture_candidate != *vg-uuid* ]] || activate=yes
        rootpxe_install_linux_startup_for_disk /dev/fixture "$tmp/body" "$hash" || fail '挂载安装衔接失败'
        grep -q "installed:$fixture" "$tmp/events" || fail '未向目标根安装'
        if [[ $owned == yes ]]; then grep -q "umount:$fixture" "$tmp/events" || fail '自有 mount 未清理'; else grep -q '^umount:' "$tmp/events" && fail '借用 mount 被卸载'; fi
        if [[ $fixture_candidate == *vg-uuid* ]]; then grep -q 'vg:vg:vg-uuid:yes' "$tmp/events" || fail '激活 VG 所有权丢失'; fi
    done
done
pass '普通、LVM、Btrfs 与借用 mount 所有权'
rootpxe_find_linux_root_filesystem(){ return 21; }
rootpxe_install_linux_startup_for_disk /dev/fixture '' '' && fail '空配置根歧义被忽略'
pass '空配置根不唯一待处理'
