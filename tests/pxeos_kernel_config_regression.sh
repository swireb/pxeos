#!/usr/bin/env bash
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
