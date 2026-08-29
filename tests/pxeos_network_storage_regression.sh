#!/usr/bin/env bash
# 合并后的 PXEOS 回归测试；每个原脚本在独立子 shell 中运行。
set -euo pipefail

# ===== 原脚本：tests/pxeos_network_regression.sh =====
(
# Network failure diagnostics use only temporary PATH mocks; no host NIC,
# DHCP client, reboot, credential or network request is touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
network="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/etc/init.d/S40network"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/mock" "$tmp/etc/network" "$tmp/lib"
printf 'export initversion=20990101\n' >"$tmp/lib/funcs.sh"

cat >"$tmp/mock/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'link show eth0'*) printf '2: eth0: <BROADCAST,UP> mtu 1500\n    link/ether aa:bb:cc:dd:ee:ff\n' ;;
  *'-br link'*) printf 'eth0             UP             aa:bb:cc:dd:ee:ff\n' ;;
  *'-br addr'*) printf 'eth0             UP             192.0.2.10/24\n' ;;
  *) exit 0 ;;
esac
EOF
cat >"$tmp/mock/udhcpc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$tmp/mock/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$tmp/mock/uname" <<'EOF'
#!/usr/bin/env bash
printf 'test-kernel-9.9\n'
EOF
cat >"$tmp/mock/lspci" <<'EOF'
#!/usr/bin/env bash
printf '00:19.0 Ethernet controller: Test NIC\n'
EOF
chmod +x "$tmp/mock"/*

printf 'mac=aa:bb:cc:dd:ee:ff pxeapi=https://token:password@example.invalid/service/ isdebug=yes\n' >"$tmp/cmdline"
sed \
  -e "s|</proc/cmdline|<\"$tmp/cmdline\"|" \
  -e "s|/etc/network/interfaces|$tmp/etc/network/interfaces|g" \
  -e "s|/usr/share/pxeos/lib/funcs.sh|$tmp/lib/funcs.sh|" \
  -e "s|/sbin/ip|$tmp/mock/ip|g" \
  -e "s|/sbin/udhcpc|$tmp/mock/udhcpc|g" \
  -e 's|read p_ifaces <<< .*|p_ifaces=eth0|' \
  -e 's|read o_ifaces <<< .*|o_ifaces=|' \
  -e 's|linkstate=$(/bin/cat /sys/class/net/$iface/carrier)|linkstate=1|' \
  -e 's|sleep [0-9][0-9]*|:|g' \
  -e 's|read -t 60|:|' \
  "$network" >"$tmp/S40network"

set +e
PATH="$tmp/mock:$PATH" bash "$tmp/S40network" >"$tmp/output" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "failure path exit code: $rc"
grep -Fq 'PXEOS network diagnostics' "$tmp/output" || fail missing-diagnostic-banner
grep -Fq 'Kernel: test-kernel-9.9' "$tmp/output" || fail missing-kernel-version
grep -Fq 'PXEOS init version: 20990101' "$tmp/output" || fail missing-init-version
grep -Fq 'Ethernet/Network PCI devices:' "$tmp/output" || fail missing-pci-section
grep -Fq 'Interfaces:' "$tmp/output" || fail missing-interface-section
grep -Fq 'Test NIC' "$tmp/output" || fail missing-pci-fact
! grep -Fq 'token:password' "$tmp/output" || fail leaked-api-credential
! grep -Fq 'https://token:' "$tmp/output" || fail leaked-api-url
! grep -Fq 'pxeapi=' "$tmp/output" || fail leaked-cmdline
[[ $(grep -Fc 'PXEOS network diagnostics' "$tmp/output") -eq 1 ]] || fail duplicated-diagnostic-banner

# lspci is optional in reduced PXEOS builds; the failure path must remain
# useful and must not turn the diagnostic itself into a startup failure.
rm -f "$tmp/mock/lspci"
set +e
PATH="$tmp/mock:$PATH" bash "$tmp/S40network" >"$tmp/output-no-lspci" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "missing-lspci failure path exit code: $rc"
grep -Fq 'unavailable (lspci not installed)' "$tmp/output-no-lspci" || fail missing-lspci-fallback
printf 'PASS: PXEOS network diagnostics regression\n'
)
# ===== 原脚本结束：tests/pxeos_network_regression.sh =====

# ===== 原脚本：tests/pxeos_storage_regression.sh =====
(
# 静态回归契约：不依赖真实存储，防止 PXEOS 重新引入已修复的危险模式。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.smb-validation.sh"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 缺少 $2"; }
must_not_have() { ! grep -RInE -- "$2" "$1" >/dev/null || fail "$1 包含禁止模式 $2"; }
must_not_have_literal() { ! grep -RInF -- "$2" "$1" >/dev/null || fail "$1 包含禁止文本 $2"; }

must_not_have "$overlay" '/images'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'eval[[:space:]]'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'source[[:space:]]+/tmp/hinfo'
must_not_have "$overlay" 'vers=|sec='
must_have "$overlay/bin/pxeos.mount" 'mount.cifs "//${storage_server}/${storage_export}" /storage'
must_have "$overlay/bin/pxeos.checkin" 'Invalid SMB export path'
must_have "$overlay/bin/pxeos.checkin" 'SMB requires a JSON checkin response'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_validate_smb_export'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'smb_username_b64'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'smb_password_b64'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'smb_domain_b64'
must_not_have_literal "$overlay/bin/pxeos.checkin" 'curl -Lksf'
must_have "$overlay/bin/pxeos.checkin" "-w \$'\\n%{http_code}'"
must_have "$overlay/bin/pxeos.checkin" '[[ $http_code =~ ^4[0-9][0-9]$ ]]'
must_have "$overlay/bin/pxeos.checkin" '[INFO]  Task aborted or withdrawn. Stopping PXEOS.'
must_have "$overlay/bin/pxeos.checkin" '[WARN]  Check-in not confirmed. Retrying in 5s.'
must_have "$overlay/bin/pxeos.checkin" 'exit "$checkin_rc"'
must_have "$overlay/bin/pxeos.mount" '${storage_export}" /storage'
awk '/^rootpxe_validate_smb_export\(\)/ { on=1 } /^rootpxe_storage_path\(\)/ { on=0 } on { print }' \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp.smb-validation.sh"
# shellcheck source=/dev/null
. "$tmp.smb-validation.sh"
rm -f "$tmp.smb-validation.sh"
for export_path in _share share-name share/images; do
    [[ $(rootpxe_validate_smb_export "$export_path") == "$export_path" ]] || fail "合法 SMB export 被拒绝: $export_path"
done
for export_path in '' /share share/ share//images share/../images //server/share . .. 'share name' 'share$bad' 'share?' 'share\\images' 'share:images'; do
    rootpxe_validate_smb_export "$export_path" >/dev/null && fail "非法 SMB export 被接受: $export_path"
done
[[ /storage == /* ]] || fail 'NFS export path 必须接受绝对路径'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_prepare_storage_layout'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '/storage/postinitscripts/hook.sh'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '/storage/postdeployscripts/hook.sh'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'for pid in "${writer_pids[@]}"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_wait_for_writer'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '( set -o pipefail;'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'CAPTURE_PIPELINE_FAILED'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'RESTORE_PIPELINE_FAILED'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'task_token'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'value=${value//+_+/ }'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'line=${line#export }'
must_not_have "$overlay/bin/pxeos" '\. /tmp/hinfo.txt'
must_have "$overlay/bin/pxeos.imgcomplete" '--connect-timeout'
must_have "$overlay/bin/pxeos.checkin" 'message_b64'
must_have "$overlay/bin/pxeos.checkin" 'error_b64'
must_have "$overlay/bin/pxeos.checkin" 'retry_after_sec'
must_have "$overlay/bin/pxeos.inventory" 'token=$task_token'
must_have "$overlay/bin/pxeos.checkin" 'taskid|osid|img_format|shutdown|api_version)'
must_have "$overlay/bin/pxeos.checkin" 'pigz_comp)'
must_have "$overlay/bin/pxeos.checkin" 'Invalid numeric checkin field: pigz_comp'
for value in -6 0 6; do [[ $value =~ ^-?[0-9]+$ ]] || fail "合法 pigz_comp 被拒绝: $value"; done
for value in --6 +6 6.0 abc ''; do [[ ! $value =~ ^-?[0-9]+$ ]] || fail "非法 pigz_comp 被接受: $value"; done
for config in "$root/configs/fsx64.config" "$root/configs/fsx86.config" "$root/configs/fsarm64.config"; do
    must_have "$config" 'BR2_TARGET_ENABLE_ROOT_LOGIN=y'
    must_have "$config" 'BR2_TARGET_GENERIC_ROOT_PASSWD="pxeos"'
    must_not_have "$config" '# BR2_TARGET_ENABLE_ROOT_LOGIN is not set'
done
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_clear_smb_plaintext'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'unset smb_username smb_password smb_domain'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_clear_capture_marker'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_request_disk_permit'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_wait_for_disk_permit'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_error_wait_for_retry'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '"${api}disk-permit"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '"${api}error"'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '"${api}task-status"'
must_not_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'task-status?taskId='
must_have "$overlay/bin/pxeos.upload" 'rootpxe_wait_for_disk_permit'
must_have "$overlay/bin/pxeos.download" 'rootpxe_wait_for_disk_permit'
must_not_have_literal "$overlay/bin/pxeos.upload" 'rootpxe_request_disk_permit || handleError'
must_not_have_literal "$overlay/bin/pxeos.download" 'rootpxe_request_disk_permit || handleError'
must_have "$overlay/etc/init.d/S99pxeos" '/tmp/pxeos.failure_action'
printf 'PASS: PXEOS storage regression contract\n'
)
# ===== 原脚本结束：tests/pxeos_storage_regression.sh =====

# ===== PXEOS SSH 调试模式回归 =====
(
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
debug="$overlay/bin/pxeos.debug"
s99="$overlay/etc/init.d/S99pxeos"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/mock"

cat >"$tmp/mock/ip" <<'EOF'
#!/usr/bin/env bash
case "${PXEOS_DEBUG_IP_MODE:-has-ip}" in
  has-ip) printf '2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0\n' ;;
  no-ip) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/mock/ip"

sed "s|/sbin/ip|$tmp/mock/ip|g" "$debug" >"$tmp/pxeos.debug"
chmod +x "$tmp/pxeos.debug"

set +e
PXEOS_DEBUG_IP_MODE=has-ip \
    osid=secret-os task_token=secret-token pxeapi=https://token:password@example.invalid \
    bash "$tmp/pxeos.debug" >"$tmp/has-ip.out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "有 IPv4 时调试模式退出码: $rc"
grep -Fq 'PXEOS SSH 调试模式' "$tmp/has-ip.out" || fail '缺少 SSH 调试模式说明'
grep -Fq 'eth0: 192.0.2.10/24' "$tmp/has-ip.out" || fail '缺少接口和 CIDR'
grep -Fq 'ssh root@192.0.2.10' "$tmp/has-ip.out" || fail '缺少 SSH 连接提示'
! grep -Fq 'secret-os' "$tmp/has-ip.out" || fail '泄露任务变量'
! grep -Fq 'secret-token' "$tmp/has-ip.out" || fail '泄露任务令牌'
! grep -Fq 'token:password' "$tmp/has-ip.out" || fail '泄露接口凭据'

set +e
PXEOS_DEBUG_IP_MODE=no-ip bash "$tmp/pxeos.debug" >"$tmp/no-ip.out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "无 IPv4 时调试模式退出码: $rc"
grep -Fq '未检测到可用于 SSH 的全局 IPv4 地址' "$tmp/no-ip.out" || fail '无 IPv4 时缺少明确警告'
grep -Fq '请在本地控制台检查网络配置' "$tmp/no-ip.out" || fail '无 IPv4 时缺少本地排查提示'

for forbidden in determineOS getHardDisk debugPause pxeos.mount pxeos.checkin task_token pxeapi storage exportpath capturepath postinitpath; do
    ! grep -Fq -- "$forbidden" "$debug" || fail "调试脚本包含禁止任务或磁盘入口: $forbidden"
done
grep -Fq 'pxeos.debug' "$s99" || fail 'S99 未进入调试脚本'
! awk '/\[Yy\]\[Ee\]\[Ss\]\|\[Yy\]\)/, /^[[:space:]]*;;/ { print }' "$s99" | grep -Eq '(^|[[:space:]])pxeos([[:space:]]|$)|reboot|poweroff' || fail 'S99 调试分支进入正常任务或电源路径'

for command in mdadm pxeos pxeos.debug poweroff reboot sleep loadkeys; do
    cat >"$tmp/mock/$command" <<'EOF'
#!/usr/bin/env bash
printf '%s:%s\n' "$(basename "$0")" "$*" >>"$PXEOS_S99_LOG"
case "$(basename "$0")" in
  pxeos) exit "${PXEOS_S99_PXEOS_RC:-0}" ;;
esac
EOF
    chmod +x "$tmp/mock/$command"
done

sed \
    -e "s|/tmp/pxeos.shutdown|$tmp/pxeos.shutdown|g" \
    -e "s|/tmp/pxeos.failure_action|$tmp/pxeos.failure_action|g" \
    "$s99" >"$tmp/S99pxeos"
chmod +x "$tmp/S99pxeos"

: >"$tmp/debug-s99.log"
PXEOS_S99_LOG="$tmp/debug-s99.log" PATH="$tmp/mock:$PATH" \
    mdraid=true isdebug=yes bash "$tmp/S99pxeos"
[[ $(<"$tmp/debug-s99.log") == 'pxeos.debug:' ]] || fail '调试模式执行了 RAID、正常任务或电源操作'

run_normal_s99() {
    local name="$1"
    local pxeos_rc="$2"
    local shutdown_value="$3"
    local failure_action="$4"
    local log="$tmp/$name.log"
    : >"$log"
    rm -f "$tmp/pxeos.shutdown" "$tmp/pxeos.failure_action"
    [[ -n $shutdown_value ]] && printf '%s\n' "$shutdown_value" >"$tmp/pxeos.shutdown"
    [[ -n $failure_action ]] && printf '%s\n' "$failure_action" >"$tmp/pxeos.failure_action"
    PXEOS_S99_LOG="$log" PXEOS_S99_PXEOS_RC="$pxeos_rc" PATH="$tmp/mock:$PATH" \
        mdraid=true isdebug='' shutdown=0 bash "$tmp/S99pxeos" >/dev/null
    printf '%s\n' "$log"
}

normal_log=$(run_normal_s99 normal-success-reboot 0 '' '')
expected=$'mdadm:--auto-detect\nmdadm:--assemble --scan\nmdadm:--incremental --run --scan\npxeos:\nsleep:5\nreboot:-f'
[[ $(<"$normal_log") == "$expected" ]] || fail '普通成功路径未保留 RAID、任务和重启顺序'
normal_log=$(run_normal_s99 normal-success-poweroff 0 1 '')
grep -Fxq 'poweroff:' "$normal_log" || fail '普通成功关机路径改变'
normal_log=$(run_normal_s99 normal-failure-reboot 9 '' '')
grep -Fxq 'reboot:-f' "$normal_log" || fail '普通失败重启路径改变'
normal_log=$(run_normal_s99 normal-failure-poweroff 9 '' shutdown)
grep -Fxq 'poweroff:' "$normal_log" || fail '普通失败关机路径改变'
printf 'PASS: PXEOS SSH debug mode regression\n'
)
# ===== PXEOS SSH 调试模式回归结束 =====
