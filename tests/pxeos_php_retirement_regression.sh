#!/usr/bin/env bash
# Retirement boundary and local-tool fixtures: no network, mount or device I/O.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if grep -RInE '\.php|rootpxe_import_usb_hinfo|/tmp/hinfo\.txt|capone|autoreg' "$overlay"; then
    fail '运行时仍包含旧 PHP 启动、注册或 Capone 分支'
fi
for retired in pxeos.auto.reg pxeos.capone; do
    [[ ! -e $overlay/bin/$retired ]] || fail "废弃脚本仍存在: $retired"
done
[[ ! -e $root/create-usb-image.sh && ! -e $root/.github/workflows/usb.yml && ! -e $root/tests/pxeos_usb_console_regression.sh ]] || fail '产品 USB 制作入口、发布流程或专用回归仍存在'

# Local diagnostics dispatch must not fetch or parse remote host configuration.
# Run the actual dispatcher with only its source path rebased.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/funcs.sh" <<'FUNCS'
mode=${FIXTURE_MODE:-sysinfo} web=https://fixture.invalid/pxe/v1/
pxeos.sysinfo(){ printf 'local sysinfo\n'; }
handleError(){ printf '%s\n' "$*" >&2; exit 94; }
curl(){ printf 'unexpected curl\n' >&2; exit 91; }
FUNCS
sed "s#^\. /usr/share/pxeos/lib/funcs.sh.*#. \"$tmp/funcs.sh\" || exit 1#" "$overlay/bin/pxeos" >"$tmp/dispatcher"
bash "$tmp/dispatcher" >"$tmp/dispatch.out"
grep -Fxq 'local sysinfo' "$tmp/dispatch.out" || fail '本地诊断未执行'
for retired in autoreg capone; do
    rc=0
    FIXTURE_MODE=$retired bash "$tmp/dispatcher" >"$tmp/retired-mode.out" 2>&1 || rc=$?
    [[ $rc == 94 ]] || fail "废弃模式未按未知模式拒绝: $retired"
done

# Surface testing still invokes native badblocks, with the former PHP check-in
# removed. All device and completion functions are fixture stubs.
cat >"$tmp/funcs.sh" <<'FUNCS'
clearScreen(){ :; }
displayBanner(){ :; }
dots(){ :; }
debugPause(){ :; }
getHardDisk(){ disks=/dev/mock-local; }
handleError(){ printf '%s\n' "$*" >&2; exit 92; }
usleep(){ :; }
badblocks(){ printf 'badblocks:%s\n' "$*"; }
rootpxe_console_prompt(){ :; }
curl(){ printf 'unexpected curl\n' >&2; exit 93; }
FUNCS
sed -e "s#^\. /usr/share/pxeos/lib/funcs.sh.*#. \"$tmp/funcs.sh\" || exit 1#" -e 's|^\. /bin/pxeos.nonimgcomplete|printf "local complete\\n"|' "$overlay/bin/pxeos.surfacetest" >"$tmp/surface"
printf '\n' | bash "$tmp/surface" >"$tmp/surface.out"
grep -Fxq 'badblocks:-sv /dev/mock-local' "$tmp/surface.out" || fail '本地 badblocks 能力丢失'
grep -Fxq 'local complete' "$tmp/surface.out" || fail '本地检测未完成'

# Kernel arguments keep their non-executing allowlist, and the old bypass flag
# can no longer enter it. Normal task check-in remains mandatory.
eval "$(sed -n '/^rootpxe_kernel_key_allowed()/,/^}/p' "$overlay/usr/share/pxeos/lib/funcs.sh")"
! rootpxe_kernel_key_allowed capone || fail '废弃旁路参数仍被接受'
! rootpxe_kernel_key_allowed boottype || fail '已删除 USB 启动参数仍被接受'
rootpxe_kernel_key_allowed task_token || fail '正常 Go 任务参数丢失'
grep -Fq 'checkin_rootpxe' "$overlay/bin/pxeos.checkin" || fail '正常 Go checkin 被删除'
grep -Fq 'exit "$checkin_rc"' "$overlay/bin/pxeos.checkin" || fail 'checkin 失败不再阻止任务'
awk '/^checkin_rootpxe$/ { copy=1 } copy { print }' "$overlay/bin/pxeos.checkin" >"$tmp/checkin-tail"
[[ -s $tmp/checkin-tail ]] || fail '正常 checkin 调用入口缺失'
rc=0
(capone=1; checkin_rootpxe(){ return 42; }; . "$tmp/checkin-tail") >"$tmp/checkin.out" 2>&1 || rc=$?
[[ $rc == 42 ]] || fail '旧环境参数绕过 checkin 失败终止'
printf 'PASS: PHP retirement and local-tool boundaries\n'
