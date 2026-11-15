#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
probe="$overlay/bin/pxeos-storage-probe"
[[ -f $probe ]] || { echo '缺少延后加载存储驱动的入口' >&2; exit 1; }
[[ ${PXEOS_STARTUP_TEST_ISOLATED:-} == 1 && ! -e /sys && ! -e /run/systemd/private ]] || exit 125

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/{mock,run,lib/modules/test-kernel,etc,sys/bus/pci/devices/a,sys/bus/pci/devices/b}
sed -e "s|/run/pxeos-storage|$tmp/run/pxeos-storage|g" \
    -e "s|/etc/pxeos-storage-kernel|$tmp/etc/pxeos-storage-kernel|g" \
    -e "s|/lib/modules|$tmp/lib/modules|g" \
    -e "s|/sys/bus|$tmp/sys/bus|g" \
    -e "s|/sys/class/block|$tmp/sys/class/block|g" \
    -e 's|^wait_seconds=30$|wait_seconds=1|' "$probe" >"$tmp/pxeos-storage-probe"
chmod +x "$tmp/pxeos-storage-probe"
export PATH="$tmp/mock:$tmp:$PATH"
export PXEOS_TEST_DIR="$tmp"
printf 'test-kernel\n' >"$tmp/etc/pxeos-storage-kernel"
printf 'test:a\n' >"$tmp/sys/bus/pci/devices/a/modalias"
printf 'test:b\n' >"$tmp/sys/bus/pci/devices/b/modalias"
ln -s /storage-driver "$tmp/sys/bus/pci/devices/a/driver"
printf 'ahci\nlibata\nata_piix\npata_legacy\n' >"$tmp/lib/modules/test-kernel/pxeos-storage.modules"
touch "$tmp/lib/modules/test-kernel/modules.dep.bin" "$tmp/lib/modules/test-kernel/modules.alias.bin"
mkdir -p "$tmp/sys/class/block" "$tmp/sys/devices/pci/block/sda" "$tmp/sys/virtual/block/md0"
mkdir -p "$tmp/sys/devices/pci/block/sdb" "$tmp/sys/devices/pci/block/nvme0n1"
ln -s "$tmp/sys/devices/pci/block/sda" "$tmp/sys/class/block/sda"
ln -s "$tmp/sys/devices/pci/block/sdb" "$tmp/sys/class/block/sdb"
ln -s "$tmp/sys/devices/pci/block/nvme0n1" "$tmp/sys/class/block/nvme0n1"
ln -s "$tmp/sys/virtual/block/md0" "$tmp/sys/class/block/md0"
printf '8:0\n' >"$tmp/sys/class/block/sda/dev"
printf '11\n' >"$tmp/sys/class/block/sda/diskseq"
printf '8:16\n' >"$tmp/sys/class/block/sdb/dev"
printf '21\n' >"$tmp/sys/class/block/sdb/diskseq"
printf '1000\n' >"$tmp/sys/class/block/sda/size"
printf '1000\n' >"$tmp/sys/class/block/sdb/size"
printf '259:0\n' >"$tmp/sys/class/block/nvme0n1/dev"
printf '31\n' >"$tmp/sys/class/block/nvme0n1/diskseq"
printf '4000\n' >"$tmp/sys/class/block/nvme0n1/size"

cat >"$tmp/mock/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'test-kernel\n'
MOCK
cat >"$tmp/mock/cat" <<'MOCK'
#!/usr/bin/env bash
if [[ ${PXEOS_TEST_MODALIAS_FAILURE:-} == yes &&
      ${*: -1} == "$PXEOS_TEST_DIR/sys/bus/pci/devices/a/modalias" ]]; then
    printf 'test:a'
    printf 'Input/output error\n' >&2
    exit 1
fi
exec /usr/bin/cat "$@"
MOCK
cat >"$tmp/mock/modprobe" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    '-R test:a') printf 'ata_piix\nahci\n';;
    '-R test:b') exit 1;;
    libata|ahci|ata_piix)
        printf '%s\n' "$*" >>"$PXEOS_TEST_DIR/loaded"
        if [[ ${PXEOS_TEST_BLOCK:-} == yes && $1 == ahci ]]; then
            while [[ ! -e $PXEOS_TEST_DIR/resume ]]; do sleep .05; done
        fi
        [[ ${PXEOS_TEST_LOAD_FAILURE:-} != "$1" ]]
        ;;
    *) printf 'unexpected modprobe: %s\n' "$*" >&2; exit 2;;
esac
MOCK
cat >"$tmp/mock/udevadm" <<'MOCK'
#!/usr/bin/env bash
[[ $1 == settle && ${PXEOS_TEST_SETTLE_FAILURE:-} != yes ]]
MOCK
cat >"$tmp/mock/dmesg" <<'MOCK'
#!/usr/bin/env bash
printf 'ata3: SATA link down (SStatus 0 SControl 300)\n'
if [[ -n ${PXEOS_TEST_ATA_FAILURE:-} ]]; then
    printf '%s\n' "$PXEOS_TEST_ATA_FAILURE"
fi
MOCK
chmod +x "$tmp/mock/"*

new_boot() { rm -rf -- "$tmp/run/pxeos-storage"; rm -f -- "$tmp/loaded" "$tmp/resume"; }
expect_failure() {
    local reason="$1"
    if pxeos-storage-probe wait >"$tmp/result" 2>&1; then
        printf '预期存储门拒绝，实际放行：%s\n' "$reason" >&2
        exit 1
    fi
    grep -Fqi "$reason" "$tmp/result"
}

case ${1:-} in
    empty-alias)
        mkdir -p "$tmp/sys/bus/acpi/devices/ACPI0004:01"
        : >"$tmp/sys/bus/acpi/devices/ACPI0004:01/modalias"
        ;;
    unterminated-alias)
        printf 'test:a' >"$tmp/sys/bus/pci/devices/a/modalias"
        ;;
    *) ;;
esac

pxeos-storage-probe start
pxeos-storage-probe wait
[[ $(<"$tmp/loaded") == $'ahci\nlibata\nata_piix' ]]
printf '12\n' >"$tmp/sys/class/block/sda/diskseq"
expect_failure 'physical disk set changed'
printf '11\n' >"$tmp/sys/class/block/sda/diskseq"
mv "$tmp/sys/class/block/sda" "$tmp/sda"
expect_failure 'physical disk set changed'
mv "$tmp/sda" "$tmp/sys/class/block/sda"
printf '0\n' >"$tmp/sys/class/block/sda/size"
expect_failure 'physical disk set changed'
printf '1000\n' >"$tmp/sys/class/block/sda/size"
PXEOS_TEST_ATA_FAILURE='ata2.00: disable device' expect_failure 'disable device'

# Exercise production automatic selection with two ordinary fixture disks.
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
source <(sed -n '/^getHardDisk() {/,/^}/p; /^rootpxe_select_hard_disks() {/,/^}/p' "$funcs")
lsblk() {
    printf 'enumerate\n' >>"$tmp/selection.trace"
    if [[ ${change_during_selection:-no} == yes ]]; then
        mv "$tmp/sys/class/block/sda" "$tmp/sda"
        printf '/dev/sdb 20G\n'
    elif [[ $1 == -dpno ]]; then
        printf '/dev/sda 80G\n/dev/sdb 20G\n/dev/nvme0n1 200G\n'
    fi
}
set_disk_for_write() {
    getHardDisk || return $?
    printf 'write:%s\n' "$hd" >>"$tmp/selection.trace"
}
imgType=n; type=down; fdrive=''; largesize=''
set_disk_for_write
[[ $(cat "$tmp/selection.trace") == $'enumerate\nwrite:/dev/sda' ]]
pxeos-storage-probe check
if [[ ${1:-} == empty-alias || ${1:-} == unterminated-alias ]]; then
    printf 'PASS: %s loads AHCI and selects the expected disk.\n' "$1"
    exit 0
fi
blockdev() {
    [[ $1 == --getsize64 ]] || return 1
    case $2 in /dev/nvme0n1) echo 200000;; /dev/sda) echo 80000;; /dev/sdb) echo 20000;; esac
}
largesize=yes getHardDisk
[[ $hd == /dev/nvme0n1 ]]
source <(sed -n '/^normalize() {/,/^}/p; /^resolve_path() {/,/^}/p' "$funcs")
trim() { printf '%s' "${1:-}"; }
blkid() { return 1; }
rootpxe_console_message() { :; }
isdebug=''
fdrive=/dev/sda,/dev/sdb
getHardDisk
[[ $hd == /dev/sda && $disks == '/dev/sda /dev/sdb' ]]
for fdrive in /dev/missing,/dev/sdb /dev/sda,/dev/missing; do
    rc=0
    getHardDisk || rc=$?
    [[ $rc -eq 75 && -z $hd && -z $disks ]]
done
fdrive=''
: >"$tmp/selection.trace"
mv "$tmp/sys/class/block/sda" "$tmp/sda"
rc=0
set_disk_for_write || rc=$?
[[ $rc -eq 75 && ! -s $tmp/selection.trace && -z $hd && -z $disks ]]
mv "$tmp/sda" "$tmp/sys/class/block/sda"
rc=0
change_during_selection=yes set_disk_for_write || rc=$?
[[ $rc -eq 75 && $(cat "$tmp/selection.trace") == enumerate && -z $hd && -z $disks ]]
mv "$tmp/sda" "$tmp/sys/class/block/sda"

new_boot
PXEOS_TEST_MODALIAS_FAILURE=yes pxeos-storage-probe start
for action in wait check; do
    rc=0
    pxeos-storage-probe "$action" >"$tmp/result" 2>&1 || rc=$?
    [[ $rc -eq 75 ]]
    grep -Fq 'Unable to read the storage driver matching information' "$tmp/result"
    grep -Fq '/sys/bus/pci/devices/a/modalias' "$tmp/result"
done
[[ ! -e $tmp/loaded ]]
: >"$tmp/selection.trace"
hd=/dev/sda
disks='/dev/sda /dev/sdb'
rc=0
set_disk_for_write || rc=$?
[[ $rc -eq 75 && ! -s $tmp/selection.trace && -z $hd && -z $disks ]]

new_boot
PXEOS_TEST_BLOCK=yes timeout 1 pxeos-storage-probe start
expect_failure 'timed out'
pxeos-storage-probe start
touch "$tmp/resume"
pxeos-storage-probe wait
[[ $(<"$tmp/loaded") == $'ahci\nlibata\nata_piix' ]]

new_boot
PXEOS_TEST_BLOCK=yes timeout 1 pxeos-storage-probe start
rc=0
PXEOS_TEST_ATA_FAILURE=$'ata1: EH pending after 5 tries, giving up\nata2: reset failed, giving up' \
    pxeos-storage-probe wait >"$tmp/result" 2>&1 || rc=$?
touch "$tmp/resume"
pxeos-storage-probe wait
if [[ $rc -ne 75 || $(<"$tmp/result") != 'ATA error recovery failed: ata1: EH pending after 5 tries, giving up' ]]; then
    printf '探测超时未返回首条明确 ATA 错误：%s\n' "$(<"$tmp/result")" >&2
    exit 1
fi

new_boot
rm "$tmp/sys/bus/pci/devices/a/driver"
pxeos-storage-probe start
expect_failure 'No driver bound'
ln -s /storage-driver "$tmp/sys/bus/pci/devices/a/driver"

new_boot
PXEOS_TEST_LOAD_FAILURE=ahci pxeos-storage-probe start
expect_failure 'ahci'

new_boot
PXEOS_TEST_SETTLE_FAILURE=yes pxeos-storage-probe start
expect_failure 'udev'

for diagnostic in 'ata2: EH pending after 5 tries, giving up' \
    'ata2: reset failed, giving up' 'ata2.00: disable device'; do
    new_boot
    PXEOS_TEST_ATA_FAILURE="$diagnostic" pxeos-storage-probe start
    expect_failure "$diagnostic"
done

new_boot
printf 'old-kernel\n' >"$tmp/etc/pxeos-storage-kernel"
pxeos-storage-probe start
expect_failure 'kernel version'
[[ ! -e $tmp/loaded ]]

new_boot
rm "$tmp/etc/pxeos-storage-kernel"
pxeos-storage-probe start
expect_failure 'missing'
[[ ! -e $tmp/loaded ]]

bash "$0" empty-alias
bash "$0" unterminated-alias
printf 'PASS: PXEOS 延后探测、异常拦截及晚完成后重试。\n'
