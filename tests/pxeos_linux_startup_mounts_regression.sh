#!/usr/bin/env bash
# 仅设备描述、mount/LVM命令 mock；无真实挂载/卷组激活或用户正文执行。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/linux-startup.sh"
tmp="$(mktemp -d /tmp/pxeos-startup-mount-fixture.XXXXXX)"
trap '[[ $tmp == /tmp/pxeos-startup-mount-fixture.* && -d $tmp && ! -L $tmp ]] && rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
declare -A roots=()
rootpxe_verify_disk_permit_binding(){ [[ $1 == /dev/d1 || $1 == /dev/d2 ]] && [[ $2 == deploy_write ]]; }
rootpxe_find_linux_root_filesystem(){
    local found="${roots[$1]:-data}"
    [[ $found != data ]] || return 20
    [[ $found != error ]] || return 23
    printf '%s\n' "$found"
}
rootpxe_startup_probe_workspace_remove(){ [[ -d $1/probe ]] && rmdir "$1/probe"; rmdir "$1"; }
rootpxe_install_linux_startup_for_disk(){ printf '%s|%s\n' "$1" "$4" >>"$tmp/writes"; }
taskType=deploy; osid=50; postDeployScriptExecution=linux-systemd-v1
for selected in /dev/d1 /dev/d2; do
    roots=(); roots[$selected]="$selected-p1|ext4|||"; : >"$tmp/writes"
    rootpxe_install_linux_startup_for_targets '' '' /dev/d1 /dev/d2 || fail 'root+数据盘被拒绝'
    [[ $(wc -l <"$tmp/writes") -eq 1 && $(<"$tmp/writes") == "$selected|$selected-p1|ext4|||" ]] || fail '未仅对唯一root安装'
done
roots[/dev/d1]='/dev/d1p1|ext4|||'; roots[/dev/d2]='/dev/d2p1|ext4|||'; : >"$tmp/writes"
rootpxe_install_linux_startup_for_targets '' '' /dev/d1 /dev/d2 && fail '两个root被接受'
[[ ! -s $tmp/writes ]] || fail '发现歧义前已经写入'
roots=(); : >"$tmp/writes"
rootpxe_install_linux_startup_for_targets '' '' /dev/d1 /dev/d2 && fail '零root被接受'
[[ ! -s $tmp/writes ]] || fail '零root仍写入'
roots[/dev/d1]='/dev/d1p1|ext4|||'; roots[/dev/d2]=error
rootpxe_install_linux_startup_for_targets '' '' /dev/d1 /dev/d2 && fail '探测错误被当作数据盘忽略'
[[ ! -s $tmp/writes ]] || fail '探测错误前发生写入'
printf 'PASS: multi-disk unique Linux root 5 scenarios\n'
rootpxe_startup_probe_disk=/dev/d1
mkdir -p "$tmp/probe-root/etc"
rootpxe_startup_mount_usr(){ return 0; }
rootpxe_startup_cleanup_usr(){ return 1; }
rootpxe_startup_probe_root_marker "$tmp/probe-root" && fail 'usr清理失败被当成功'
rc=0; rootpxe_startup_probe_root_marker "$tmp/probe-root" || rc=$?
[[ $rc == 2 ]] || fail 'usr/VG清理错误被当作缺root marker'
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
awk '/^rootpxe_linux_probe_root_candidate\(\)/{on=1} /^rootpxe_linux_validate_vg_target_pvs\(\)/{on=0} on{print}' "$funcs" >"$tmp/probe-functions"
. "$tmp/probe-functions"
rootpxe_linux_root_fstype_supported(){ return 0; }
rootpxe_linux_mount_options(){ printf ro; }
rootpxe_run_logged_typed_native(){ return 0; }
mountpoint(){ return 1; }
umount(){ printf '%s\n' "$1" >>"$tmp/unmounts"; }
rootpxe_linux_probe_mountpoint="$tmp/probe-root"
rc=0; rootpxe_linux_probe_root_candidate /dev/d1p1 ext4 || rc=$?
[[ $rc == 3 && -s $tmp/unmounts ]] || fail '私有探测清理失败未传播成probe error'
printf 'PASS: private probe cleanup failures are not data disks\n'
rootpxe_run_logged_typed_native(){ return 1; }
for fs in ext4 xfs; do
    rc=0; rootpxe_linux_probe_root_candidate /dev/d1p1 "$fs" || rc=$?
    [[ $rc == 3 ]] || fail "$fs 私有probe mount失败被当数据盘"
done
printf 'PASS: ext4/xfs failed probes fail closed\n'
(
    . "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/linux-startup.sh"
    rootpxe_linux_cleanup_selected_vg(){ [[ $1 != vg || $3 != yes ]]; }
    rootpxe_startup_usr_owned=no; rootpxe_startup_usr_vg_name=vg; rootpxe_startup_usr_vg_uuid=vg-uuid; rootpxe_startup_usr_vg_owned=yes
    rootpxe_startup_cleanup_usr && fail 'usr自有VG清理失败误报成功'
    rootpxe_find_linux_root_filesystem(){ printf '/dev/vg/root|ext4|vg|vg-uuid|\n'; }
    rootpxe_linux_activate_vg_if_needed(){ printf yes; }
    rootpxe_startup_mount_target(){ rootpxe_startup_mounted_root="$tmp"; rootpxe_startup_root_owned=no; }
    rootpxe_startup_install_at_root(){ return 0; }
    rootpxe_startup_probe_workspace_remove(){ [[ $1 == /tmp/rootpxe-startup-mount.* ]] && command rmdir "$1"; }
    taskType=deploy; osid=50; postDeployScriptExecution=linux-systemd-v1
    rootpxe_install_linux_startup_for_disk /dev/d1 '' '' && fail 'root自有VG清理失败误报部署成功'
    :
)
printf 'PASS: owned usr/root VG cleanup failure propagation\n'
