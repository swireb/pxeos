#!/usr/bin/env bash
# 合并后的 PXEOS 回归测试；每个原脚本在独立子 shell 中运行。
set -euo pipefail

# ===== 原脚本：tests/pxeos_build_download_regression.sh =====
(
# Offline regression coverage for archive download safety and dependency checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/download_helpers.sh"
failures=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

expect_success() {
    "$@" || fail "命令应成功：$*"
}

expect_failure() {
    if "$@"; then
        fail "命令应失败：$*"
    fi
}

assert_file() {
    [[ -f $1 ]] || fail "缺少文件：$1"
}

assert_no_temp_files() {
    local archive=$1
    if compgen -G "${archive}.tmp.*" >/dev/null; then
        fail "遗留临时下载文件：${archive}.tmp.*"
    fi
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pxeos build download.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
MOCK_BIN="$WORK_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
export PATH="$MOCK_BIN:$PATH"
export REAL_GREP="$(command -v grep)"
export MOCK_WGET_LOG="$WORK_DIR/wget.log"
export MOCK_WGET_COUNT="$WORK_DIR/wget.count"

cat >"$MOCK_BIN/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
printf '%s\n' "$@" >>"$MOCK_WGET_LOG"
while [[ $# -gt 0 ]]; do
    case $1 in
        -O) output=$2; shift 2 ;;
        *) url=$1; shift ;;
    esac
done
count=0
[[ -f $MOCK_WGET_COUNT ]] && count="$(cat "$MOCK_WGET_COUNT")"
count=$((count + 1))
printf '%s' "$count" >"$MOCK_WGET_COUNT"
case ${MOCK_WGET_MODE:-success} in
    success) cp "$MOCK_ARCHIVE" "$output" ;;
    invalid) printf 'not an xz archive' >"$output" ;;
    fail) printf 'mock connection refused\n' >&2; exit 4 ;;
    primary-fail) if [[ $url == *primary* ]]; then printf 'mock primary failed\n' >&2; exit 5; fi; cp "$MOCK_ARCHIVE" "$output" ;;
    *) printf 'unknown mock mode\n' >&2; exit 64 ;;
esac
EOF
chmod +x "$MOCK_BIN/wget"

cat >"$MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/sleep"

cat >"$MOCK_BIN/grep" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == '^ID=' && ${2:-} == '/etc/os-release' ]]; then
    printf 'ID=ubuntu\n'
    exit 0
fi
exec "$REAL_GREP" "$@"
EOF
chmod +x "$MOCK_BIN/grep"

source "$HELPER"

SAMPLE_DIR="$WORK_DIR/sample"
mkdir -p "$SAMPLE_DIR"
printf 'PXEOS regression payload\n' >"$SAMPLE_DIR/payload.txt"
export MOCK_ARCHIVE="$WORK_DIR/sample.tar.xz"
tar -C "$SAMPLE_DIR" -cJf "$MOCK_ARCHIVE" payload.txt

archive="$WORK_DIR/path with spaces/linux.tar.xz"
mkdir -p "$(dirname "$archive")"

# Valid cache is reused without starting wget.
cp "$MOCK_ARCHIVE" "$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=fail
expect_success download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz'
[[ ! -s $MOCK_WGET_LOG ]] || fail '有效缓存不应调用 wget'

# A normal download works in a path containing spaces.
rm -f "$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=success
expect_success download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz'
assert_file "$archive"
tar -tJf "$archive" >/dev/null || fail '成功下载的缓存应为有效 tar.xz'
assert_no_temp_files "$archive"

# The first source can fail and the fallback source can supply the archive.
rm -f "$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=primary-fail
expect_success download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz' 'https://fallback.invalid/archive.tar.xz'
grep -Fqx 'https://primary.invalid/archive.tar.xz' "$MOCK_WGET_LOG" || fail '未尝试首选源'
grep -Fqx 'https://fallback.invalid/archive.tar.xz' "$MOCK_WGET_LOG" || fail '首选源失败后未尝试备用源'
assert_file "$archive"
assert_no_temp_files "$archive"

# A failed source leaves neither a final partial file nor a temp file; wget receives three attempts.
rm -f "$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=fail
expect_failure download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz'
[[ ! -e $archive ]] || fail '所有下载失败后不应保留正式半包'
assert_no_temp_files "$archive"
grep -Fqx -- '--tries=3' "$MOCK_WGET_LOG" || fail 'wget 应配置三次尝试'

# A directory cannot be mistaken for a downloaded archive target.
directory_target="$WORK_DIR/archive-directory"
mkdir "$directory_target"
: >"$MOCK_WGET_LOG"
expect_failure download_tar_xz "$directory_target" 'https://primary.invalid/archive.tar.xz'
[[ ! -s $MOCK_WGET_LOG ]] || fail '目录目标不应启动 wget'

# An invalid existing cache is retained until a verified replacement is ready.
printf 'old invalid cache' >"$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=success
expect_success download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz'
tar -tJf "$archive" >/dev/null || fail '坏缓存未被有效新归档替换'
assert_no_temp_files "$archive"

# A failed replacement must retain the previous invalid cache for diagnosis.
printf 'old invalid cache' >"$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=fail
expect_failure download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz'
[[ "$(cat "$archive")" == 'old invalid cache' ]] || fail '下载失败不应删除既有坏缓存'
assert_no_temp_files "$archive"

# A successful wget that writes corrupt content is rejected and cannot become the cache.
rm -f "$archive"
: >"$MOCK_WGET_LOG"
: >"$MOCK_WGET_COUNT"
export MOCK_WGET_MODE=invalid
expect_failure download_tar_xz "$archive" 'https://primary.invalid/archive.tar.xz'
[[ ! -e $archive ]] || fail '损坏下载不应成为正式缓存'
assert_no_temp_files "$archive"

# The retry policy is passed to wget for connection refusal and retryable HTTP responses.
grep -Fqx -- '--retry-connrefused' "$MOCK_WGET_LOG" || fail '缺少连接拒绝重试策略'
grep -Fqx -- '--retry-on-http-error=429,500,502,503,504' "$MOCK_WGET_LOG" || fail '缺少 HTTP 重试状态策略'

# Dependency checks consume one package query, match names exactly, and surface query errors.
cat >"$MOCK_BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${MOCK_DPKG_MODE:-installed} == fail ]]; then
    printf 'mock dpkg query failed\n' >&2
    exit 42
fi
for number in $(seq 1 2000); do
    printf 'installed\tnoise-package-%s:amd64\n' "$number"
done
while IFS= read -r package; do
    printf 'installed\t%s:amd64\n' "$package"
done <<'PACKAGES'
wget
tar
git
make
flex
bison
gcc-aarch64-linux-gnu
cpio
file
rsync
patch
unzip
bzip2
findutils
autoconf
libtool
libelf-dev
xz-utils
libncurses-dev
PACKAGES
if [[ ${MOCK_DPKG_RC_AUTOPOINT:-no} == yes ]]; then
    printf 'config-files\tautopoint:amd64\n'
else
    printf 'installed\tautopoint:amd64\n'
fi
printf 'installed\tgcc-12:amd64\n'
printf 'installed\tg++-12:amd64\n'
if [[ ${MOCK_DPKG_EXACT_CXX:-yes} == yes ]]; then
    printf 'installed\tg++:amd64\n'
fi
EOF
chmod +x "$MOCK_BIN/dpkg-query"

source "$ROOT_DIR/dependencies.sh"
export MOCK_DPKG_MODE=installed
export MOCK_DPKG_EXACT_CXX=yes
export MOCK_DPKG_RC_AUTOPOINT=no
if ! checkDependencies >"$WORK_DIR/deps.out" 2>"$WORK_DIR/deps.err"; then
    fail '大输出依赖查询不应因 pipefail 或 Broken pipe 失败'
fi
grep -Fq 'gcc' "$WORK_DIR/deps.out" || fail 'gcc-12 不应视为 gcc 已安装'
grep -Fq ' g++' "$WORK_DIR/deps.out" && fail 'g++:amd64 应视为 g++ 已安装'
grep -Fq 'Broken pipe' "$WORK_DIR/deps.err" && fail '依赖检查不应产生 Broken pipe'

export MOCK_DPKG_EXACT_CXX=no
expect_success checkDependencies >"$WORK_DIR/deps-lookalike.out" 2>"$WORK_DIR/deps-lookalike.err"
grep -Fq 'g++' "$WORK_DIR/deps-lookalike.out" || fail 'g++-12 不应视为 g++ 已安装'

export MOCK_DPKG_EXACT_CXX=yes
export MOCK_DPKG_RC_AUTOPOINT=yes
expect_success checkDependencies >"$WORK_DIR/deps-rc.out" 2>"$WORK_DIR/deps-rc.err"
grep -Fq 'autopoint' "$WORK_DIR/deps-rc.out" || fail 'config-files 状态不应视为已安装'

export MOCK_DPKG_MODE=fail
if checkDependencies >"$WORK_DIR/deps-query.out" 2>"$WORK_DIR/deps-query.err"; then
    fail '包查询失败必须失败，不能误判为全部已安装'
fi
grep -Fq 'mock dpkg query failed' "$WORK_DIR/deps-query.err" || fail '包查询错误应保留真实 stderr'

cat >"$MOCK_BIN/pkg-install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$MOCK_INSTALL_LOG"
if [[ ${MOCK_INSTALL_MODE:-success} == fail ]]; then
    printf 'mock installer failed\n' >&2
    exit 23
fi
EOF
chmod +x "$MOCK_BIN/pkg-install"
export MOCK_INSTALL_LOG="$WORK_DIR/install.log"
missing_packages=(gcc 'g++')
package_manager=(pkg-install)
export MOCK_INSTALL_MODE=success
expect_success installDependencies y
[[ "$(tr '\n' ' ' <"$MOCK_INSTALL_LOG")" == 'gcc g++ ' ]] || fail '安装命令只能接收缺失包清单'
export MOCK_INSTALL_MODE=fail
expect_failure installDependencies y

# build.sh must stop before any source-preparation function after dependency failure.
cat >"$MOCK_BIN/tar" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$MOCK_TAR_LOG"
exit 66
EOF
chmod +x "$MOCK_BIN/tar"
export MOCK_TAR_LOG="$WORK_DIR/tar.log"
: >"$MOCK_WGET_LOG"
: >"$MOCK_TAR_LOG"
export MOCK_DPKG_MODE=fail
expect_failure "$ROOT_DIR/build.sh" --fs-download-only -a x64
[[ ! -s $MOCK_WGET_LOG ]] || fail '依赖查询失败后不应开始源码下载'
[[ ! -s $MOCK_TAR_LOG ]] || fail '依赖查询失败后不应开始源码解压'

if [[ $failures -ne 0 ]]; then
    exit 1
fi
printf 'PASS: PXEOS 下载与依赖检测回归。\n'
)
# ===== 原脚本结束：tests/pxeos_build_download_regression.sh =====

# ===== 原脚本：tests/pxeos_kernel_config_regression.sh =====
(
# Static contract for the PXEOS kernel/Buildroot configuration.  It intentionally
# does not download sources or invoke a kernel build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

expect_line() {
    local file=$1 line=$2
    grep -Fqx "$line" "$file" || fail "$file 缺少：$line"
}

run_qemu_smoke() {
    local qemu image initrd log status
    qemu="$(command -v qemu-system-aarch64 || true)"
    image="$ROOT_DIR/dist/arm_Image"
    initrd="$ROOT_DIR/dist/arm_init.cpio.gz"
    if [[ -z "$qemu" || ! -f "$image" || ! -f "$initrd" ]]; then
        printf 'SKIP: QEMU ARM64 冒烟需要 qemu-system-aarch64、dist/arm_Image 和 dist/arm_init.cpio.gz。\n'
        return 0
    fi
    log="$(mktemp)"
    set +e
    timeout 45s "$qemu" -M virt -cpu cortex-a57 -m 1024 -nographic \
        -netdev user,id=pxeosnet0 -device virtio-net-pci,netdev=pxeosnet0 \
        -kernel "$image" -initrd "$initrd" -append 'console=ttyAMA0' >"$log" 2>&1
    status=$?
    set -e
    if ! grep -Eq 'Booting Linux|Linux version' "$log"; then
        cat "$log" >&2
        rm -f "$log"
        fail 'QEMU 未输出 ARM64 Linux 启动标识'
        return
    fi
    if ! grep -Eq 'Run /init as init process|Run /init as init process \([^)]*\)' "$log"; then
        cat "$log" >&2
        rm -f "$log"
        fail 'QEMU 未证明 gzip initramfs 已解包并执行 /init'
        return
    fi
    if ! grep -Eq 'Starting .+ interface and waiting for the link to come up|PXEOS network diagnostics|No network interfaces found|Failed to get an IP via DHCP' "$log"; then
        cat "$log" >&2
        rm -f "$log"
        fail 'QEMU 未到达可识别的 S40network 输出'
        return
    fi
    rm -f "$log"
    [[ $status -eq 0 || $status -eq 124 ]] || fail "QEMU 异常退出：$status"
    printf 'PASS: QEMU ARM64 initrd 冒烟。\n'
}

verify_arm64_initrd_format() {
    local initrd magic
    initrd="$ROOT_DIR/dist/arm_init.cpio.gz"
    if [[ ! -f "$initrd" ]]; then
        printf 'SKIP: ARM64 initrd 格式检查需要 dist/arm_init.cpio.gz。\n'
        return 0
    fi
    gzip -t "$initrd" || { fail 'ARM64 initrd 不是有效 gzip 数据'; return; }
    magic="$(gzip -cd "$initrd" | head -c 6 || true)"
    [[ "$magic" == '070701' || "$magic" == '070702' ]] || fail 'ARM64 initrd gzip 内容不是 newc/crc cpio'
    [[ $failures -eq 0 ]] && printf 'PASS: ARM64 gzip cpio initrd 格式。\n'
}

case "${1:-}" in
    '') ;;
    --help) printf 'Usage: %s [--arm64-initrd|--qemu]\n' "$0"; exit 0 ;;
    --arm64-initrd) verify_arm64_initrd_format; [[ $failures -eq 0 ]] && exit 0 || exit 1 ;;
    --qemu) verify_arm64_initrd_format; run_qemu_smoke; [[ $failures -eq 0 ]] && exit 0 || exit 1 ;;
    *) printf 'Usage: %s [--arm64-initrd|--qemu]\n' "$0" >&2; exit 2 ;;
esac

expect_line "$ROOT_DIR/build.sh" "[[ -z \$KERNEL_VERSION ]] && KERNEL_VERSION='6.18.38'"
for fs in fsx86.config fsx64.config fsarm64.config; do
    expect_line "$ROOT_DIR/configs/$fs" 'BR2_DEFAULT_KERNEL_VERSION="6.18.38"'
    expect_line "$ROOT_DIR/configs/$fs" 'BR2_DEFAULT_KERNEL_HEADERS="6.18.38"'
    expect_line "$ROOT_DIR/configs/$fs" 'BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18=y'
    expect_line "$ROOT_DIR/configs/$fs" '# BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_12 is not set'
    for minor in 13 14 15 16 17 18; do
        expect_line "$ROOT_DIR/configs/$fs" "BR2_TOOLCHAIN_HEADERS_AT_LEAST_6_${minor}=y"
    done
    expect_line "$ROOT_DIR/configs/$fs" 'BR2_TOOLCHAIN_HEADERS_AT_LEAST="6.18"'
done
expect_line "$ROOT_DIR/configs/fsarm64.config" 'BR2_TARGET_ROOTFS_CPIO=y'
expect_line "$ROOT_DIR/configs/fsarm64.config" 'BR2_TARGET_ROOTFS_CPIO_GZIP=y'
expect_line "$ROOT_DIR/build.sh" '            compiledfile="../fssource$arch/output/images/rootfs.cpio.gz"'
expect_line "$ROOT_DIR/build.sh" "            initfile='arm_init.cpio.gz'"
for arch in x86 x64; do
    expect_line "$ROOT_DIR/configs/fs${arch}.config" 'BR2_TARGET_ROOTFS_EXT2=y'
    expect_line "$ROOT_DIR/configs/fs${arch}.config" 'BR2_TARGET_ROOTFS_EXT2_XZ=y'
done
expect_line "$ROOT_DIR/build.sh" '            compiledfile="../fssource$arch/output/images/rootfs.ext2.xz"'

for arch in x86 x64 arm64; do
    config="$ROOT_DIR/configs/kernel${arch}.config"
    expect_line "$config" '# CONFIG_MODULES is not set'
    expect_line "$config" 'CONFIG_R8169=y'
    for driver in R8125 R8126 R8127 R8168; do
        expect_line "$config" "# CONFIG_${driver} is not set"
    done
    expect_line "$config" 'CONFIG_PCIEASPM=y'
    expect_line "$config" 'CONFIG_PCIEASPM_DEFAULT=y'
    expect_line "$config" '# CONFIG_PCIEASPM_POWERSAVE is not set'
    expect_line "$config" '# CONFIG_PCIEASPM_POWER_SUPERSAVE is not set'
    expect_line "$config" '# CONFIG_PCIEASPM_PERFORMANCE is not set'
done

for arch in x86 x64; do
    config="$ROOT_DIR/configs/kernel${arch}.config"
    expect_line "$config" 'CONFIG_RD_XZ=y'
    expect_line "$config" 'CONFIG_DECOMPRESS_XZ=y'
done

for arch in x86 x64; do
    expect_line "$ROOT_DIR/configs/kernel${arch}.config" 'CONFIG_PCI_MMCONFIG=y'
done

arm="$ROOT_DIR/configs/kernelarm64.config"
for line in \
    'CONFIG_RD_GZIP=y' 'CONFIG_DECOMPRESS_GZIP=y' \
    'CONFIG_ARCH_BCM=y' 'CONFIG_ARCH_BCM2835=y' 'CONFIG_ACPI=y' \
    'CONFIG_PCI_HOST_GENERIC=y' 'CONFIG_PCIE_BRCMSTB=y' \
    'CONFIG_RASPBERRYPI_FIRMWARE=y' 'CONFIG_BCMGENET=y' \
    'CONFIG_SERIAL_AMBA_PL011=y' 'CONFIG_SERIAL_AMBA_PL011_CONSOLE=y' \
    'CONFIG_DMADEVICES=y'; do
    expect_line "$arm" "$line"
done

if [[ $failures -ne 0 ]]; then
    exit 1
fi
printf 'PASS: PXEOS 内核与 ARM64 配置契约。\n'
)
# ===== 原脚本结束：tests/pxeos_kernel_config_regression.sh =====
