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
grep -Fq 'Ethernet/network PCI devices:' "$tmp/output" || fail missing-pci-section
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
grep -Fq 'lspci is not installed.' "$tmp/output-no-lspci" || fail missing-lspci-fallback
printf 'PASS: PXEOS network diagnostics regression\n'
)
# ===== 原脚本结束：tests/pxeos_network_regression.sh =====

# ===== PXEOS 运行时英文控制台文本回归 =====
(
# 该检查只在开发回归中运行。它枚举 overlay 内的实际 Shell 入口，保留
# heredoc 内容、剥离真实 Shell 注释，并拒绝所有剩余的中日韩统一表意文字。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while IFS= read -r -d '' file; do
    case "$file" in
        *.sh|*/bin/pxeos*|*/etc/init.d/S*|*/etc/init.d/K*) printf '%s\n' "$file" ;;
        *)
            if LC_ALL=C grep -Iq . "$file"; then
                first_line=$(head -n 1 "$file" 2>/dev/null || :)
                [[ $first_line == \#!*sh* || $first_line == \#!*bash* ]] && printf '%s\n' "$file"
            fi
            ;;
    esac
done < <(find "$overlay" -type f -print0) >"$tmp/runtime-files"
[[ -s $tmp/runtime-files ]] || fail '未找到 PXEOS 运行时 Shell 脚本'

# AWK keeps heredoc bodies intact because they may be printed at runtime. For
# ordinary code it removes only # comments outside single/double quotes, so
# translated comments remain allowed while quoted runtime text is inspected.
xargs -d '\n' awk '
function emit_code(line,    i,ch,out,single,double,escaped) {
    out = ""; single = 0; double = 0; escaped = 0
    for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        if (escaped) { out = out ch; escaped = 0; continue }
        if (ch == "\\" && !single) { out = out ch; escaped = 1; continue }
        if (ch == "\x27" && !double) { single = !single; out = out ch; continue }
        if (ch == "\"") { if (!single) double = !double; out = out ch; continue }
        if (ch == "#" && !single && !double) break
        out = out ch
    }
    print FILENAME ":" FNR ":" out
}
function begin_heredoc(line,    token) {
    if (!match(line, /<<-?[[:space:]]*[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?/)) return
    token = substr(line, RSTART, RLENGTH)
    heredoc_tabs = (substr(token, 3, 1) == "-")
    sub(/^<<-?[[:space:]]*/, "", token)
    gsub(/[\x27"]/, "", token)
    heredoc = token
}
{
    if (heredoc != "") {
        compare = $0
        if (heredoc_tabs) sub(/^\t+/, "", compare)
        print FILENAME ":" FNR ":" $0
        if (compare == heredoc) heredoc = ""
        next
    }
    emit_code($0)
    begin_heredoc($0)
}
' <"$tmp/runtime-files" >"$tmp/runtime-code"

set +e
LC_ALL=C grep -nP '\p{Han}' "$tmp/runtime-code"
cjk_status=$?
set -e
case $cjk_status in
    1) ;;
    0) fail 'PXEOS 运行时 Shell 文本包含非英文 CJK 字符' ;;
    *) fail "PXEOS 运行时文本扫描失败（grep exit $cjk_status）" ;;
esac
printf 'PASS: PXEOS runtime console text is English\n'
)
# ===== PXEOS 运行时英文控制台文本回归结束 =====

# ===== PXEOS 启动网络与 SSH 服务控制台回归 =====
(
# 启动脚本测试只替换 PATH 中的命令，并在临时目录中保存 DHCP/服务日志；
# 不会操作宿主机网络、守护进程或 SSH 主机密钥。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
network="$overlay/etc/init.d/S40network"
cron="$overlay/etc/init.d/S50crond"
sshd="$overlay/etc/init.d/S50sshd"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/mock" "$tmp/etc/network" "$tmp/ssh"

cat >"$tmp/mock/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'link show eth0'*) printf '2: eth0: <BROADCAST,UP> mtu 1500\n    link/ether aa:bb:cc:dd:ee:ff\n' ;;
  *'-4 -o addr show dev eth0 scope global'*) printf '2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0\n' ;;
  *) exit 0 ;;
esac
EOF
cat >"$tmp/mock/udhcpc" <<'EOF'
#!/usr/bin/env bash
printf 'udhcpc: started, v1.37.0\nudhcpc: broadcasting discover\n'
exit "${PXEOS_DHCP_RC:-0}"
EOF
cat >"$tmp/mock/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/mock/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
[[ ${PXEOS_KEYGEN_SILENT:-0} == 1 ]] || printf 'ssh-keygen: generating new host keys\n'
exit "${PXEOS_KEYGEN_RC:-0}"
EOF
cat >"$tmp/mock/start-stop-daemon" <<'EOF'
#!/usr/bin/env bash
printf 'Starting service: raw daemon output\n'
[[ -n ${PXEOS_SERVICE_CALLS:-} ]] && printf '%s\n' "$*" >>"$PXEOS_SERVICE_CALLS"
case " $* " in
  *' --stop '*) exit "${PXEOS_STOP_RC:-${PXEOS_SERVICE_RC:-0}}" ;;
esac
exit "${PXEOS_SERVICE_RC:-0}"
EOF
chmod +x "$tmp/mock"/*

printf 'mac=aa:bb:cc:dd:ee:ff pxeapi=https://example.invalid/service/\n' >"$tmp/cmdline"
sed \
  -e "s|</proc/cmdline|<\"$tmp/cmdline\"|" \
  -e "s|/etc/network/interfaces|$tmp/etc/network/interfaces|g" \
  -e "s|/sbin/ip|$tmp/mock/ip|g" \
  -e "s|/sbin/udhcpc|$tmp/mock/udhcpc|g" \
  -e "s|/tmp/pxeos-dhcp-|$tmp/dhcp-|g" \
  -e 's|read p_ifaces <<< .*|p_ifaces=eth0|' \
  -e 's|read o_ifaces <<< .*|o_ifaces=|' \
  -e 's|linkstate=$(/bin/cat /sys/class/net/$iface/carrier)|linkstate=1|' \
  -e 's|sleep [0-9][0-9]*|:|g' \
  -e 's|read -r -t 60|:|' \
  "$network" >"$tmp/S40network"

PATH="$tmp/mock:$PATH" bash "$tmp/S40network" >"$tmp/network-success.out" 2>&1
grep -Eq '^\[INFO\]  Starting interface eth0 and waiting for link\.+Done$' "$tmp/network-success.out" || fail '网络启动缺少统一接口状态行'
grep -Eq '^\[INFO\]  Acquiring DHCP lease on eth0\.+Done$' "$tmp/network-success.out" || fail 'DHCP 缺少统一完成状态行'
grep -Fqx '[INFO]  IPv4 address: 192.0.2.10/24.' "$tmp/network-success.out" || fail 'DHCP 缺少 IPv4 结果行'
! grep -Fq 'udhcpc: started' "$tmp/network-success.out" || fail '控制台泄露原始 udhcpc 输出'
! grep -Fq 'broadcasting discover' "$tmp/network-success.out" || fail '控制台泄露 DHCP 协商噪声'
grep -Fq 'udhcpc: started' "$tmp/dhcp-eth0.log" || fail 'DHCP 原始日志未保存'

set +e
PXEOS_DHCP_RC=42 PATH="$tmp/mock:$PATH" bash "$tmp/S40network" >"$tmp/network-failure.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "DHCP 失败路径退出码: $rc"
grep -Eq '^\[INFO\]  Acquiring DHCP lease on eth0\.+Failed \(exit 42\)$' "$tmp/network-failure.out" || fail 'DHCP 失败未保留原始返回码'
grep -Fq 'Details: ' "$tmp/network-failure.out" || fail 'DHCP 失败未指向诊断日志'
grep -Fq 'udhcpc: started' "$tmp/dhcp-eth0.log" || fail 'DHCP 失败日志未保存'

for script in "$cron" "$sshd"; do
    [[ -f $script ]] || fail "缺少启动服务覆盖脚本: $script"
done
sed \
  -e "s|/usr/bin/ssh-keygen|$tmp/mock/ssh-keygen|g" \
  -e "s|/etc/ssh|$tmp/ssh|g" \
  -e "s|/var/run|$tmp/run|g" \
  -e "s|/tmp/pxeos-sshd-|$tmp/sshd-|g" \
  "$sshd" >"$tmp/S50sshd"
sed \
  -e "s|/var/run|$tmp/run|g" \
  -e "s|/tmp/pxeos-crond-|$tmp/crond-|g" \
  "$cron" >"$tmp/S50crond"
chmod +x "$tmp/S50sshd" "$tmp/S50crond"
mkdir -p "$tmp/run"

PATH="$tmp/mock:$PATH" bash "$tmp/S50crond" start >"$tmp/cron-success.out" 2>&1
grep -Eq '^\[INFO\]  Starting cron service\.+Done$' "$tmp/cron-success.out" || fail 'Cron 缺少统一完成状态行'
! grep -Fq 'Starting service: raw daemon output' "$tmp/cron-success.out" || fail 'Cron 控制台泄露服务原始输出'
grep -Fq 'Starting service: raw daemon output' "$tmp/crond-start.log" || fail 'Cron 服务日志未保存'

PATH="$tmp/mock:$PATH" bash "$tmp/S50sshd" start >"$tmp/sshd-success.out" 2>&1
grep -Eq '^\[INFO\]  Generating SSH host keys\.+Done$' "$tmp/sshd-success.out" || fail 'SSH 缺少统一密钥生成状态行'
grep -Eq '^\[INFO\]  Starting SSH service\.+Done$' "$tmp/sshd-success.out" || fail 'SSH 缺少统一服务完成状态行'
! grep -Fq 'ssh-keygen: generating' "$tmp/sshd-success.out" || fail 'SSH 控制台泄露密钥生成原始输出'
! grep -Fq 'Starting service: raw daemon output' "$tmp/sshd-success.out" || fail 'SSH 控制台泄露服务原始输出'
grep -Fq 'ssh-keygen: generating' "$tmp/sshd-keygen.log" || fail 'SSH 密钥生成日志未保存'
grep -Fq 'Starting service: raw daemon output' "$tmp/sshd-start.log" || fail 'SSH 服务日志未保存'

PXEOS_KEYGEN_SILENT=1 PATH="$tmp/mock:$PATH" bash "$tmp/S50sshd" start >"$tmp/sshd-existing-keys.out" 2>&1
! grep -Fq 'Generating SSH host keys' "$tmp/sshd-existing-keys.out" || fail '已有 SSH 主机密钥仍显示生成状态'
grep -Eq '^\[INFO\]  Starting SSH service\.+Done$' "$tmp/sshd-existing-keys.out" || fail '已有 SSH 主机密钥时 SSH 服务未启动'

set +e
PXEOS_SERVICE_RC=23 PATH="$tmp/mock:$PATH" bash "$tmp/S50crond" start >"$tmp/cron-failure.out" 2>&1
rc=$?
set -e
[[ $rc -eq 23 ]] || fail "Cron 失败返回码被吞掉: $rc"
grep -Eq '^\[INFO\]  Starting cron service\.+Failed \(exit 23\)$' "$tmp/cron-failure.out" || fail 'Cron 失败未保留服务返回码'

set +e
PXEOS_SERVICE_RC=255 PATH="$tmp/mock:$PATH" bash "$tmp/S50crond" start >"$tmp/cron-failure-255.out" 2>&1
rc=$?
set -e
[[ $rc -eq 255 ]] || fail "Cron 最大失败码被吞掉: $rc"
grep -Eq '^\[INFO\]  Starting cron service\.+Failed \(exit 255\)$' "$tmp/cron-failure-255.out" || fail 'Cron 最大失败码未按单行显示'

printf 'stale pid\n' >"$tmp/run/crond.pid"
set +e
PXEOS_STOP_RC=27 PATH="$tmp/mock:$PATH" bash "$tmp/S50crond" stop >"$tmp/cron-stop-failure.out" 2>&1
rc=$?
set -e
[[ $rc -eq 27 ]] || fail "Cron stop 未保留原返回码: $rc"
[[ ! -e $tmp/run/crond.pid ]] || fail 'Cron stop 失败后未清理 PID 文件'
grep -Eq '^\[INFO\]  Stopping cron service\.+Failed \(exit 27\)$' "$tmp/cron-stop-failure.out" || fail 'Cron stop 失败未按单行显示'

: >"$tmp/service-calls.log"
PXEOS_STOP_RC=27 PXEOS_SERVICE_CALLS="$tmp/service-calls.log" PATH="$tmp/mock:$PATH" \
    bash "$tmp/S50crond" restart >"$tmp/cron-restart.out" 2>&1
grep -Fq -- '--stop' "$tmp/service-calls.log" || fail 'Cron restart 未调用 stop'
grep -Fq -- '--start' "$tmp/service-calls.log" || fail 'Cron restart 在 stop 失败后未调用 start'

: >"$tmp/service-calls.log"
PXEOS_STOP_RC=27 PXEOS_SERVICE_CALLS="$tmp/service-calls.log" PATH="$tmp/mock:$PATH" \
    bash "$tmp/S50sshd" restart >"$tmp/sshd-restart.out" 2>&1
grep -Fq -- '--stop' "$tmp/service-calls.log" || fail 'SSH restart 未调用 stop'
grep -Fq -- '--start' "$tmp/service-calls.log" || fail 'SSH restart 在 stop 失败后未调用 start'

set +e
PXEOS_KEYGEN_RC=31 PATH="$tmp/mock:$PATH" bash "$tmp/S50sshd" start >"$tmp/sshd-keygen-failure.out" 2>&1
rc=$?
set -e
[[ $rc -eq 31 ]] || fail "SSH 密钥生成失败返回码被吞掉: $rc"
grep -Eq '^\[INFO\]  Generating SSH host keys\.+Failed \(exit 31\)$' "$tmp/sshd-keygen-failure.out" || fail 'SSH 密钥失败未保留返回码'

set +e
PXEOS_SERVICE_RC=24 PATH="$tmp/mock:$PATH" bash "$tmp/S50sshd" start >"$tmp/sshd-service-failure.out" 2>&1
rc=$?
set -e
[[ $rc -eq 24 ]] || fail "SSH 服务失败返回码被吞掉: $rc"
grep -Eq '^\[INFO\]  Starting SSH service\.+Failed \(exit 24\)$' "$tmp/sshd-service-failure.out" || fail 'SSH 服务失败未保留返回码'

for output in "$tmp/network-success.out" "$tmp/network-failure.out" "$tmp/cron-success.out" "$tmp/sshd-success.out" "$tmp/sshd-existing-keys.out" "$tmp/cron-failure.out" "$tmp/cron-failure-255.out" "$tmp/cron-stop-failure.out" "$tmp/cron-restart.out" "$tmp/sshd-restart.out" "$tmp/sshd-keygen-failure.out" "$tmp/sshd-service-failure.out"; do
    LC_ALL=C grep -Eq '[^ -~]' "$output" && fail "启动控制台输出包含非 ASCII 文本: $output"
    while IFS= read -r line; do
        [[ ${#line} -le 80 ]] || fail "启动控制台输出超过 80 列: $line"
    done <"$output"
done
printf 'PASS: PXEOS startup console regression\n'
)
# ===== PXEOS 启动网络与 SSH 服务控制台回归结束 =====

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
must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message INFO 'Task aborted or withdrawn. Stopping PXEOS.'"
must_have "$overlay/bin/pxeos.checkin" "rootpxe_console_message WARN 'Check-in not confirmed. Retrying in 5s.'"
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
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" '/storage/backup'
must_not_have_literal "$overlay" '/storage/postinitscripts'
must_not_have_literal "$overlay" '/storage/postdeployscripts'
must_not_have_literal "$overlay" 'rootpxe_run_postinit'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_run_pre_deploy_script'
must_have "$overlay/usr/share/pxeos/lib/funcs.sh" 'rootpxe_run_post_deploy_script'
must_have "$overlay/bin/pxeos.checkin" 'preDeployScript'
must_have "$overlay/bin/pxeos.checkin" 'preDeployScriptSha256'
must_have "$overlay/bin/pxeos.checkin" 'postDeployScript'
must_have "$overlay/bin/pxeos.checkin" 'postDeployScriptSha256'
must_have "$overlay/bin/pxeos.checkin" 'captureBackupName'
must_have "$overlay/bin/pxeos.checkin" 'chmod 700 "$script_file"'
awk '/^rootpxe_run_deploy_script\(\)/ { on=1 } /^# LVM v2/ { on=0 } on { print }' "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp.deploy-scripts.sh"
must_not_have "$tmp.deploy-scripts.sh" 'source[[:space:]]'
must_not_have "$tmp.deploy-scripts.sh" 'eval[[:space:]]'
rm -f "$tmp.deploy-scripts.sh"
legacy_field='inject'"Script"
legacy_stage='injecting'"_script"
must_not_have_literal "$overlay" "$legacy_field"
must_not_have_literal "$overlay" "$legacy_stage"
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
grep -Fqx '[INFO]  Mode: SSH debug.' "$tmp/has-ip.out" || fail '缺少 SSH 调试模式说明'
grep -Fqx '[INFO]  Interface: eth0 (192.0.2.10/24).' "$tmp/has-ip.out" || fail '缺少接口和 CIDR'
grep -Fqx '[INFO]  SSH command: ssh root@192.0.2.10' "$tmp/has-ip.out" || fail '缺少 SSH 连接提示'
LC_ALL=C grep -Eq '[^ -~]' "$tmp/has-ip.out" && fail 'SSH 调试输出包含非 ASCII 字符'
while IFS= read -r line; do
    [[ -z $line ]] && continue
    [[ ${#line} -le 80 ]] || fail "SSH 调试输出超过 80 列: $line"
done <"$tmp/has-ip.out"
! grep -Fq 'secret-os' "$tmp/has-ip.out" || fail '泄露任务变量'
! grep -Fq 'secret-token' "$tmp/has-ip.out" || fail '泄露任务令牌'
! grep -Fq 'token:password' "$tmp/has-ip.out" || fail '泄露接口凭据'

set +e
PXEOS_DEBUG_IP_MODE=no-ip bash "$tmp/pxeos.debug" >"$tmp/no-ip.out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "无 IPv4 时调试模式退出码: $rc"
grep -Fqx '[WARN]  No global IPv4 address is available for SSH.' "$tmp/no-ip.out" || fail '无 IPv4 时缺少明确警告'
grep -Fqx '[INFO]  Check network configuration, DHCP status, and cable connectivity.' "$tmp/no-ip.out" || fail '无 IPv4 时缺少本地排查提示'
LC_ALL=C grep -Eq '[^ -~]' "$tmp/no-ip.out" && fail '无 IPv4 调试输出包含非 ASCII 字符'
expected_banner=$'+------------------------------------------------------------------------------+\n|                                PXEOS Runtime                                 |\n+------------------------------------------------------------------------------+'
[[ $(head -n 3 "$tmp/has-ip.out") == "$expected_banner" ]] || fail '调试模式横幅布局不正确'

for forbidden in determineOS getHardDisk debugPause pxeos.mount pxeos.checkin task_token pxeapi exportpath capturepath postinitpath; do
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
